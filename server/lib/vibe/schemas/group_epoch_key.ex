defmodule Vibe.Schemas.GroupEpochKey do
  @moduledoc """
  One group epoch key in transit to one member who is entitled to it.

  The server is an **untrusted relay** here, exactly as it is for
  `Vibe.Schemas.MlsWelcome`. `sealed_key` is the epoch key already encrypted to
  the recipient's own key by the sender's device; the server stores ciphertext,
  hands it to one user, and never has the means to open it.

  ## Why the row records an epoch number in the clear

  It has to. A member who cannot read message history needs to say *which*
  epoch key is missing, and a device rejoining after a reinstall needs to know
  what it already holds without downloading everything. The epoch number is not
  secret — it is a counter that increments on membership change, and it leaks
  only the fact that membership changed, which the participant list already
  says out loud.

  ## Why `delivered_at` is set on acknowledgement, not on fetch

  Same reason as the Welcome relay: a key that is fetched but never installed —
  crash, backgrounded app, failed Keychain write — must stay pending and be
  retried. Marking it delivered when it is merely *sent* converts a transient
  failure into permanently unreadable history.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_epoch_keys" do
    belongs_to :recipient_user, Vibe.Accounts.User, foreign_key: :recipient_user_id
    belongs_to :sender_user, Vibe.Accounts.User, foreign_key: :sender_user_id
    field :chat_id, :string
    field :epoch, :integer
    field :sealed_key, :binary
    field :delivered_at, :utc_datetime

    timestamps()
  end

  def changeset(group_epoch_key, attrs) do
    group_epoch_key
    |> cast(attrs, [
      :recipient_user_id,
      :sender_user_id,
      :chat_id,
      :epoch,
      :sealed_key,
      :delivered_at
    ])
    |> validate_required([:recipient_user_id, :sender_user_id, :chat_id, :epoch, :sealed_key])
    # Epoch 0 is group creation and the counter only ever climbs. A negative
    # epoch is not a valid state, so it is a malformed or hostile client.
    |> validate_number(:epoch, greater_than_or_equal_to: 0)
    # One key per (recipient, chat, epoch). Without this, a sender could post a
    # *second*, different key for an epoch the recipient already installed, and
    # whichever arrived first would decide what that member can read.
    |> unique_constraint([:recipient_user_id, :chat_id, :epoch],
      name: :group_epoch_keys_recipient_chat_epoch_index
    )
  end
end
