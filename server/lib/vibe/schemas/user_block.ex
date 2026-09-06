defmodule Vibe.Accounts.UserBlock do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_blocks" do
    # Both columns are uuid in the DB; without :type they default to :id and
    # every query casts a uuid to an integer.
    belongs_to :user, Vibe.Accounts.User, type: :binary_id
    belongs_to :blocked_user, Vibe.Accounts.User, type: :binary_id

    timestamps()
  end

  def changeset(user_block, attrs) do
    user_block
    |> cast(attrs, [:user_id, :blocked_user_id])
    |> validate_required([:user_id, :blocked_user_id])
    |> unique_constraint(:user_id, name: :user_blocks_user_id_blocked_user_id_index)
  end
end
