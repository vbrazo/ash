defmodule Ash.Test.Actions.CreateTest do
  @moduledoc false
  use ExUnit.Case, async: true

  defmodule Authorized do
    use Ash.Resource,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Test.Authorizer]

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key :id
      attribute(:name, :string)
    end

    actions do
      read(:read)
      create(:create)
      update(:update)
    end
  end

  defmodule Profile do
    @moduledoc false
    use Ash.Resource,
      data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    actions do
      read(:read)
      create(:create)
      update(:update)
    end

    attributes do
      uuid_primary_key :id
      attribute(:bio, :string)
      attribute(:date, :date)
    end

    relationships do
      belongs_to(:author, Ash.Test.Actions.CreateTest.Author)
    end
  end

  defmodule ProfileWithBelongsTo do
    @moduledoc false
    use Ash.Resource,
      data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    actions do
      read(:read)
      create(:create)
      update(:update)
    end

    attributes do
      uuid_primary_key :id
      attribute(:bio, :string)
      attribute(:date, :date)
    end

    relationships do
      belongs_to(:author, Ash.Test.Actions.CreateTest.Author, required?: true)
    end
  end

  defmodule DuplicateName do
    use Ash.Resource.Change

    def change(changeset, _, _) do
      case Ash.Changeset.fetch_change(changeset, :name) do
        :error -> changeset
        {:ok, name} -> Ash.Changeset.change_attribute(changeset, :name, name <> name)
      end
    end
  end

  defmodule Author do
    @moduledoc false
    use Ash.Resource, data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    actions do
      read :read
      create :create, primary?: true

      create :only_allow_name do
        accept([:name])
      end

      create :duplicate_name do
        change {DuplicateName, []}
      end

      update :update
    end

    attributes do
      uuid_primary_key :id
      attribute(:name, :string)
      attribute(:bio, :string)
    end

    relationships do
      has_one(:profile, Profile, destination_field: :author_id)

      has_many(:posts, Ash.Test.Actions.CreateTest.Post, destination_field: :author_id)
    end
  end

  defmodule PostDefaults do
    @moduledoc false
    def garbage2, do: "garbage2"
    def garbage3, do: "garbage3"
  end

  defmodule PostLink do
    @moduledoc false
    use Ash.Resource,
      data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    actions do
      read(:read)

      create(:create)
      update(:update)
    end

    relationships do
      belongs_to(:source_post, Ash.Test.Actions.CreateTest.Post,
        primary_key?: true,
        required?: true
      )

      belongs_to(:destination_post, Ash.Test.Actions.CreateTest.Post,
        primary_key?: true,
        required?: true
      )
    end
  end

  defmodule Post do
    @moduledoc false
    use Ash.Resource, data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    actions do
      read(:read)
      create(:create)
      update(:update)
    end

    attributes do
      uuid_primary_key :id
      attribute(:title, :string, allow_nil?: false)
      attribute(:contents, :string)
      attribute(:tag, :string, default: "garbage")
      attribute(:tag2, :string, default: &PostDefaults.garbage2/0)
      attribute(:tag3, :string, default: {PostDefaults, :garbage3, []})
      attribute(:list_attribute, {:array, :integer})
      attribute(:date, :date)
      attribute(:binary, :binary)
      attribute(:required_with_default, :string, allow_nil?: false, default: "string")
      attribute(:required_boolean_with_default, :boolean, allow_nil?: false, default: false)

      attribute(:list_attribute_with_constraints, {:array, :integer},
        constraints: [
          min_length: 2,
          max_length: 10,
          items: [min: -10, max: 10]
        ]
      )
    end

    relationships do
      belongs_to(:author, Author)

      many_to_many(:related_posts, __MODULE__,
        through: PostLink,
        source_field_on_join_table: :source_post_id,
        destination_field_on_join_table: :destination_post_id
      )
    end
  end

  defmodule GeneratedPkey do
    use Ash.Resource,
      data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    actions do
      read(:read)

      create(:create)
      update(:update)
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule Api do
    @moduledoc false
    use Ash.Api

    resources do
      resource(Author)
      resource(Post)
      resource(Profile)
      resource(ProfileWithBelongsTo)
      resource(PostLink)
      resource(Authorized)
      resource(GeneratedPkey)
    end
  end

  import Ash.Changeset

  describe "simple creates" do
    test "allows creating a record with valid attributes" do
      assert %Post{title: "foo", contents: "bar"} =
               Post
               |> new()
               |> change_attributes(%{
                 title: "foo",
                 contents: "bar",
                 date: Date.utc_today(),
                 binary: <<0, 1, 2, 3, 4, 5>>
               })
               |> Api.create!()
    end

    test "return missing required attribute" do
      {:error, err} =
        Post
        |> new()
        |> change_attributes(%{
          contents: "bar",
          date: Date.utc_today()
        })
        |> Api.create()

      assert %Ash.Error.Invalid{
               class: :invalid,
               errors: [
                 %Ash.Error.Changes.Required{
                   class: :invalid,
                   field: :title
                 }
               ]
             } = err
    end

    test "generated fields are not required" do
      assert %GeneratedPkey{} =
               GeneratedPkey
               |> new()
               |> Api.create!()
    end

    test "constant default values are set properly" do
      assert %Post{tag: "garbage"} =
               Post
               |> new()
               |> change_attribute(:title, "foo")
               |> Api.create!()
    end

    test "constant functions values are set properly" do
      assert %Post{tag2: "garbage2"} =
               Post
               |> new()
               |> change_attribute(:title, "foo")
               |> Api.create!()
    end

    test "constant module/function values are set properly" do
      assert %Post{tag3: "garbage3"} =
               Post
               |> new()
               |> change_attribute(:title, "foo")
               |> Api.create!()
    end

    test "binary values are set properly" do
      assert %Post{binary: <<0, 1, 2>>} =
               Post
               |> new()
               |> change_attribute(:title, "foo")
               |> change_attribute(:binary, <<0, 1, 2>>)
               |> Api.create!()
    end
  end

  describe "accept" do
    test "allows using attributes in the list" do
      Author
      |> new()
      |> change_attribute(:name, "fred")
      |> Api.create!(action: :only_allow_name)
    end

    test "it prevents using attributes not in the list" do
      assert_raise Ash.Error.Invalid, ~r/Invalid value provided for bio: cannot be changed/, fn ->
        Author
        |> new()
        |> change_attribute(:bio, "foo")
        |> Api.create!(action: :only_allow_name)
      end
    end
  end

  describe "changeset" do
    test "changes are run properly" do
      author =
        Author
        |> new(%{name: "fred"})
        |> Api.create!(action: :duplicate_name)

      assert author.name == "fredfred"
    end
  end

  describe "select" do
    test "allows selecting fields on the changeset" do
      author =
        Author
        |> new(%{name: "fred"})
        |> Ash.Changeset.select(:bio)
        |> Api.create!(action: :duplicate_name)

      assert is_nil(author.name)
    end
  end

  describe "creating many to many relationships" do
    test "allows creating with a many_to_many relationship" do
      post2 =
        Post
        |> new()
        |> change_attribute(:title, "title2")
        |> Api.create!()

      post3 =
        Post
        |> new()
        |> change_attribute(:title, "title3")
        |> Api.create!()

      Post
      |> new(%{title: "cannot_be_missing"})
      |> replace_relationship(:related_posts, [post2, post3])
      |> Api.create!()
    end

    test "it updates the join table properly" do
      post2 =
        Post
        |> new()
        |> change_attribute(:title, "title2")
        |> Api.create!()

      post3 =
        Post
        |> new()
        |> change_attribute(:title, "title3")
        |> Api.create!()

      Post
      |> new(%{title: "title4"})
      |> replace_relationship(:related_posts, [post2, post3])
      |> Api.create!()

      assert [_, _] =
               PostLink
               |> Ash.Query.new()
               |> Api.read!()
    end

    test "it responds with the relationship filled in" do
      post2 =
        Post
        |> new()
        |> change_attribute(:title, "title2")
        |> Api.create!()

      post3 =
        Post
        |> new()
        |> change_attribute(:title, "title3")
        |> Api.create!()

      post =
        Post
        |> new(%{title: "cannot_be_missing"})
        |> replace_relationship(:related_posts, [post2, post3])
        |> Api.create!()

      assert Enum.sort(post.related_posts) ==
               Enum.sort([
                 Api.get!(Post, post2.id),
                 Api.get!(Post, post3.id)
               ])
    end
  end

  describe "creating with has_one relationships" do
    test "allows creating with has_one relationship" do
      profile =
        Profile
        |> new()
        |> change_attribute(:bio, "best dude")
        |> Api.create!()

      Author
      |> new()
      |> change_attribute(:name, "fred")
      |> replace_relationship(:profile, profile)
    end

    test "it sets the relationship on the destination record accordingly" do
      profile =
        Profile
        |> new()
        |> change_attribute(:bio, "best dude")
        |> Api.create!()

      author =
        Author
        |> new()
        |> change_attribute(:name, "fred")
        |> replace_relationship(:profile, profile)
        |> Api.create!()

      assert Api.get!(Profile, profile.id).author_id == author.id
    end

    test "it responds with the relationship filled in" do
      profile =
        Profile
        |> new()
        |> change_attribute(:bio, "best dude")
        |> Api.create!()

      author =
        Author
        |> new()
        |> change_attribute(:name, "fred")
        |> replace_relationship(:profile, profile)
        |> Api.create!()

      assert author.profile.author_id == author.id
    end
  end

  describe "creating with a has_many relationship" do
    test "allows creating with a has_many relationship" do
      post =
        Post
        |> new()
        |> change_attribute(:title, "sup")
        |> Api.create!()

      Author
      |> new()
      |> change_attribute(:name, "foobar")
      |> replace_relationship(:posts, [post])
      |> Api.create!()
    end
  end

  describe "creating with belongs_to relationships" do
    test "allows creating with belongs_to relationship" do
      author =
        Author
        |> new()
        |> change_attribute(:bio, "best dude")
        |> Api.create!()

      Post
      |> new()
      |> change_attribute(:title, "foobar")
      |> replace_relationship(:author, author)
      |> Api.create!()
    end

    test "it sets the relationship on the destination record accordingly" do
      author =
        Author
        |> new()
        |> change_attribute(:bio, "best dude")
        |> Api.create!()

      post =
        Post
        |> new()
        |> change_attribute(:title, "foobar")
        |> replace_relationship(:author, author)
        |> Api.create!()

      assert Api.get!(Post, post.id).author_id == author.id
    end

    test "it responds with the relationship field filled in" do
      author =
        Author
        |> new()
        |> change_attribute(:bio, "best dude")
        |> Api.create!()

      post =
        Post
        |> new()
        |> change_attribute(:title, "foobar")
        |> replace_relationship(:author, author)
        |> Api.create!()

      assert post.author_id == author.id
    end

    test "it responds with the relationship filled in" do
      author =
        Author
        |> new()
        |> change_attribute(:bio, "best dude")
        |> Api.create!()

      post =
        Post
        |> new()
        |> change_attribute(:title, "foobar")
        |> replace_relationship(:author, author)
        |> Api.create!()

      assert post.author == author
    end
  end

  describe "creating with required belongs_to relationships" do
    test "allows creating with belongs_to relationship" do
      author =
        Author
        |> new()
        |> change_attribute(:bio, "best dude")
        |> Api.create!()

      ProfileWithBelongsTo
      |> Ash.Changeset.for_create(:create, [author: author], relationships: [author: :replace])
      |> Api.create!()
    end

    test "does not allow creating without the required belongs_to relationship" do
      assert_raise Ash.Error.Invalid, ~r/relationship author is required/, fn ->
        ProfileWithBelongsTo
        |> Ash.Changeset.for_create(:create)
        |> Api.create!()
      end
    end

    test "allows creating with the required belongs_to relationship" do
      author =
        Author
        |> Ash.Changeset.for_create(:create, bio: "best dude")
        |> Api.create!()

      ProfileWithBelongsTo
      |> Ash.Changeset.for_create(:create)
      |> Ash.Changeset.replace_relationship(:author, author)
      |> Api.create!()
    end

    test "allows creating with the required belongs_to relationship with an on_no_match :create" do
      Author
      |> Ash.Changeset.for_create(:create, bio: "best dude")
      |> Api.create!()

      ProfileWithBelongsTo
      |> Ash.Changeset.for_create(:create)
      |> Ash.Changeset.replace_relationship(:author, %{name: "author name"},
        on_no_match: :create,
        on_lookup: :relate,
        on_match: :ignore
      )
      |> Api.create!()
    end
  end

  describe "list type" do
    test "it can store a list" do
      assert Post
             |> new(%{title: "cannot_be_missing"})
             |> change_attribute(:list_attribute, [1, 2, 3, 4])
             |> Api.create!()
    end
  end

  describe "list type constraints" do
    test "it honors min_length" do
      assert_raise Ash.Error.Invalid, ~r/must have 2 or more items/, fn ->
        Post
        |> new()
        |> change_attribute(:list_attribute_with_constraints, [])
        |> Api.create!()
      end
    end

    test "it honors max_length" do
      assert_raise Ash.Error.Invalid, ~r/must have 10 or fewer items/, fn ->
        list = [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]

        Post
        |> new()
        |> change_attribute(:list_attribute_with_constraints, list)
        |> Api.create!()
      end
    end

    test "it honors item constraints" do
      assert_raise Ash.Error.Invalid, ~r/must be less than or equal to 10/, fn ->
        list = [28, 2, 4]

        Post
        |> new()
        |> change_attribute(:list_attribute_with_constraints, list)
        |> Api.create!()
      end
    end
  end

  describe "unauthorized create" do
    test "it does not create the record" do
      start_supervised({Ash.Test.Authorizer, check: :forbidden, strict_check: :continue})

      assert_raise(Ash.Error.Forbidden, fn ->
        Authorized
        |> new()
        |> change_attribute(:name, "foo")
        |> Api.create!(authorize?: true)
      end)

      assert [] = Api.read!(Authorized)
    end
  end
end
