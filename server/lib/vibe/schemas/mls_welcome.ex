defmodule Vibe.Schemas.MlsWelcome do
  @moduledoc """
  One MLS Welcome message in transit from the device that created a group to
  the device being added to it.

  The server is an **untrusted relay** for this row. `welcome` and
  `ratchet_tree` are opaque bytes it cannot read and must never try to parse —
  there is nothing here to validate beyond size, and inspecting the contents
  would be both useless and a smell.

  `delivered_at` is set only once the recipient confirms it applied the
  Welcome, not when it is handed out. A Welcome that is fetched but never
  applied (crash, failed join) must stay pending and be retried: losing one
  means losing the ability to read that conversation at all.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "mls_welcomes" do
    belongs_to :recipient_user, Vibe.Accounts.User, foreign_key: :recipient_user_id
    belongs_to :sender_user, Vibe.Accounts.User, foreign_key: :sender_user_id
    field :chat_id, :string
    field :welcome, :binary
    field :ratchet_tree, :binary
    field :delivered_at, :utc_datetime

    timestamps()
  end

  def changeset(mls_welcome, attrs) do
    mls_welcome
    |> cast(attrs, [
      :recipient_user_id,
      :sender_user_id,
      :chat_id,
      :welcome,
      :ratchet_tree,
      :delivered_at
    ])
    |> validate_required([:recipient_user_id, :sender_user_id, :chat_id, :welcome])
  end
end
