defmodule Ash.SatSolver.Csp do
  defmodule Constraint do
    defstruct [:scenario]

    defimpl Csp.Constraint do
      def arguments(constraint), do: Enum.map(constraint.scenario, &abs/1)

      def satisfies?(constraint, assignment) do
        Enum.all?(constraint.scenario, fn clause ->
          requirement = clause > 0
          Map.fetch!(assignment, abs(clause)) == requirement
        end)
      end
    end
  end

  def solve(integers) do
    variables = 1..max_var(integers) |> Enum.to_list()

    %Csp{
      variables: variables,
      domains:
        Enum.into(variables, %{}, fn var ->
          {var, [true, false]}
        end),
      constraints: constraints(integers)
    }
    |> Csp.solve()
    |> case do
      :no_solution ->
        {:error, :unsatisfiable}

      {:solved, assignment} ->
        {:ok, assignment_to_scenario(assignment)}
    end
  end

  defp assignment_to_scenario(assignment) do
    Enum.map(assignment, fn {var, value} ->
      if value do
        var
      else
        -var
      end
    end)
  end

  defp constraints(integers) do
    Enum.map(integers, fn scenario ->
      %Constraint{scenario: scenario}
    end)
  end

  defp max_var(list_of_lists_of_integers) do
    list_of_lists_of_integers
    |> Enum.map(fn list ->
      list
      |> Enum.map(&abs/1)
      |> Enum.max()
    end)
    |> Enum.max()
  end
end
