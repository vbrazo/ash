defmodule Ash.Query.Aggregate do
  @moduledoc "Represents an aggregated association value"
  defstruct [
    :name,
    :relationship_path,
    :default_value,
    :resource,
    :query,
    :field,
    :kind,
    :type,
    :authorization_filter,
    :load
  ]

  @kinds [:count, :first, :sum]

  @type t :: %__MODULE__{}
  @type kind :: unquote(Enum.reduce(@kinds, &{:|, [], [&1, &2]}))

  require Ash.Query

  @doc false
  def kinds, do: @kinds

  alias Ash.Actions.SideLoad
  alias Ash.Engine.Request
  alias Ash.Error.Query.{NoReadAction, NoSuchRelationship}

  def new(resource, name, kind, relationship, query, field) do
    field_type =
      if field do
        related = Ash.Resource.Info.related(resource, relationship)
        Ash.Resource.Info.attribute(related, field).type
      end

    with :ok <- validate_path(resource, List.wrap(relationship)),
         {:ok, type} <- kind_to_type(kind, field_type),
         {:ok, query} <- validate_query(query) do
      {:ok,
       %__MODULE__{
         name: name,
         resource: resource,
         default_value: default_value(kind),
         relationship_path: List.wrap(relationship),
         field: field,
         kind: kind,
         type: type,
         query: query
       }}
    end
  end

  defp validate_path(_, []), do: :ok

  defp validate_path(resource, [relationship | rest]) do
    case Ash.Resource.Info.relationship(resource, relationship) do
      nil ->
        {:error, NoSuchRelationship.exception(resource: resource, name: relationship)}

      %{type: :many_to_many, through: through, destination: destination} ->
        cond do
          !Ash.Resource.Info.primary_action(through, :read) ->
            {:error, NoReadAction.exception(resource: through, when: "aggregating")}

          !Ash.Resource.Info.primary_action(destination, :read) ->
            {:error, NoReadAction.exception(resource: destination, when: "aggregating")}

          !Ash.DataLayer.data_layer(through) == Ash.DataLayer.data_layer(resource) ->
            {:error, "Cannot cross data layer boundaries when building an aggregate"}

          true ->
            validate_path(destination, rest)
        end

      relationship ->
        cond do
          !Ash.Resource.Info.primary_action(relationship.destination, :read) ->
            NoReadAction.exception(resource: relationship.destination, when: "aggregating")

          !Ash.DataLayer.data_layer(relationship.destination) ==
              Ash.DataLayer.data_layer(resource) ->
            {:error, "Cannot cross data layer boundaries when building an aggregate"}

          true ->
            validate_path(relationship.destination, rest)
        end
    end
  end

  defp default_value(:count), do: 0
  defp default_value(:first), do: nil
  defp default_value(:sum), do: nil

  defp validate_query(nil), do: {:ok, nil}

  defp validate_query(query) do
    cond do
      query.side_load != [] ->
        {:error, "Cannot side load in an aggregate"}

      query.aggregates != %{} ->
        {:error, "Cannot aggregate in an aggregate"}

      not is_nil(query.limit) ->
        {:error, "Cannot limit an aggregate (for now)"}

      not (is_nil(query.offset) || query.offset == 0) ->
        {:error, "Cannot offset an aggregate (for now)"}

      true ->
        {:ok, query}
    end
  end

  @doc false
  def kind_to_type(:count, _field_type), do: {:ok, Ash.Type.Integer}
  def kind_to_type(kind, nil), do: {:error, "Must provide field type for #{kind}"}
  def kind_to_type(kind, field_type) when kind in [:first, :sum], do: {:ok, field_type}
  def kind_to_type(kind, _field_type), do: {:error, "Invalid aggregate kind: #{kind}"}

  def requests(initial_query, can_be_in_query?, authorizing?) do
    initial_query.aggregates
    |> Map.values()
    |> Enum.group_by(&{&1.resource, &1.relationship_path})
    |> Enum.reduce({[], [], []}, fn {{aggregate_resource, relationship_path}, aggregates},
                                    {auth_requests, value_requests, aggregates_in_query} ->
      related = Ash.Resource.Info.related(aggregate_resource, relationship_path)

      relationship =
        Ash.Resource.Info.relationship(
          aggregate_resource,
          List.first(relationship_path)
        )

      {in_query?, reverse_relationship} =
        case SideLoad.reverse_relationship_path(relationship, tl(relationship_path)) do
          :error ->
            {can_be_in_query?, nil}

          {:ok, reverse_relationship} ->
            {can_be_in_query? &&
               any_aggregate_matching_path_used_in_query?(initial_query, relationship_path),
             reverse_relationship}
        end

      auth_request =
        if authorizing? do
          auth_request(related, initial_query, reverse_relationship, relationship_path)
        else
          nil
        end

      new_auth_requests =
        if auth_request do
          [auth_request | auth_requests]
        else
          auth_requests
        end

      if in_query? do
        {new_auth_requests, value_requests, aggregates_in_query ++ aggregates}
      else
        request =
          value_request(
            initial_query,
            related,
            reverse_relationship,
            relationship_path,
            aggregates,
            auth_request,
            aggregate_resource
          )

        {new_auth_requests, [request | value_requests], aggregates_in_query}
      end
    end)
  end

  defp auth_request(related, initial_query, reverse_relationship, relationship_path) do
    Request.new(
      resource: related,
      api: initial_query.api,
      async?: false,
      query: aggregate_query(related, reverse_relationship),
      path: [:aggregate, relationship_path],
      strict_check_only?: true,
      action: Ash.Resource.Info.primary_action(related, :read),
      name: "authorize aggregate: #{Enum.join(relationship_path, ".")}",
      data: []
    )
  end

  defp value_request(
         initial_query,
         related,
         reverse_relationship,
         relationship_path,
         aggregates,
         auth_request,
         aggregate_resource
       ) do
    pkey = Ash.Resource.Info.primary_key(aggregate_resource)

    deps =
      if auth_request do
        [auth_request.path ++ [:authorization_filter], [:data, :data]]
      else
        [[:data, :data]]
      end

    Request.new(
      resource: aggregate_resource,
      api: initial_query.api,
      query: aggregate_query(related, reverse_relationship),
      path: [:aggregate_values, relationship_path],
      action: Ash.Resource.Info.primary_action(aggregate_resource, :read),
      name: "fetch aggregate: #{Enum.join(relationship_path, ".")}",
      data:
        Request.resolve(
          deps,
          fn data ->
            records = get_in(data, [:data, :data])

            if records == [] do
              {:ok, %{}}
            else
              initial_query = Ash.Query.unset(initial_query, [:filter, :sort, :aggregates])

              query =
                case records do
                  [record] ->
                    filter = record |> Map.take(pkey) |> Enum.to_list()

                    Ash.Query.filter(
                      initial_query,
                      ^filter
                    )

                  records ->
                    filter = [or: Enum.map(records, &Map.take(&1, pkey))]

                    Ash.Query.filter(
                      initial_query,
                      ^filter
                    )
                end

              aggregates =
                if auth_request do
                  case get_in(data, [auth_request.path ++ [:authorization_filter]]) do
                    nil ->
                      aggregates

                    filter ->
                      Enum.map(aggregates, fn aggregate ->
                        %{aggregate | query: Ash.Query.filter(aggregate.query, ^filter)}
                      end)
                  end
                else
                  aggregates
                end

              with {:ok, data_layer_query} <- Ash.Query.data_layer_query(query),
                   {:ok, data_layer_query} <-
                     add_data_layer_aggregates(
                       data_layer_query,
                       aggregates,
                       initial_query.resource
                     ),
                   {:ok, results} <-
                     Ash.DataLayer.run_query(
                       data_layer_query,
                       query.resource
                     ) do
                loaded_aggregates =
                  aggregates
                  |> Enum.map(& &1.load)
                  |> Enum.reject(&is_nil/1)

                all_aggregates = Enum.map(aggregates, & &1.name)

                aggregate_values =
                  Enum.reduce(results, %{}, fn result, acc ->
                    loaded_aggregate_values = Map.take(result, loaded_aggregates)

                    all_aggregate_values =
                      result.aggregates
                      |> Kernel.||(%{})
                      |> Map.take(all_aggregates)
                      |> Map.merge(loaded_aggregate_values)

                    Map.put(
                      acc,
                      Map.take(result, pkey),
                      all_aggregate_values
                    )
                  end)

                {:ok, aggregate_values}
              else
                {:error, error} ->
                  {:error, error}
              end
            end
          end
        )
    )
  end

  defp add_data_layer_aggregates(data_layer_query, aggregates, aggregate_resource) do
    Enum.reduce_while(aggregates, {:ok, data_layer_query}, fn aggregate,
                                                              {:ok, data_layer_query} ->
      case Ash.DataLayer.add_aggregate(
             data_layer_query,
             aggregate,
             aggregate_resource
           ) do
        {:ok, data_layer_query} -> {:cont, {:ok, data_layer_query}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp aggregate_query(resource, reverse_relationship) do
    Request.resolve(
      [[:data, :query]],
      fn data ->
        data_query = data.data.query

        if reverse_relationship do
          filter =
            Ash.Filter.put_at_path(
              data_query.filter,
              reverse_relationship
            )

          {:ok, Ash.Query.filter(resource, ^filter)}
        else
          {:ok, data_query}
        end
      end
    )
  end

  defp any_aggregate_matching_path_used_in_query?(query, relationship_path) do
    filter_aggregates =
      if query.filter do
        Ash.Filter.used_aggregates(query.filter)
      else
        []
      end

    if Enum.any?(filter_aggregates, &(&1.relationship_path == relationship_path)) do
      true
    else
      sort_aggregates =
        Enum.flat_map(query.sort, fn {field, _} ->
          case Map.fetch(query.aggregates, field) do
            :error ->
              []

            {:ok, agg} ->
              [agg]
          end
        end)

      Enum.any?(sort_aggregates, &(&1.relationship_path == relationship_path))
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{query: nil} = aggregate, opts) do
      container_doc(
        "#" <> to_string(aggregate.kind) <> "<",
        [Enum.join(aggregate.relationship_path, ".")],
        ">",
        opts,
        fn str, _ -> str end,
        separator: ""
      )
    end

    def inspect(%{query: query} = aggregate, opts) do
      container_doc(
        "#" <> to_string(aggregate.kind) <> "<",
        [
          concat([
            Enum.join(aggregate.relationship_path, "."),
            concat(" from ", to_doc(query, opts))
          ])
        ],
        ">",
        opts,
        fn str, _ -> str end
      )
    end
  end
end
