defmodule Vibe.Repo.Migrations.CreateGroupEpochKeys do
  use Ecto.Migration

  def change do
    create table(:group_epoch_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :recipient_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sender_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :chat_id, :string, null: false
      add :epoch, :integer, null: false
      add :sealed_key, :binary, null: false
      add :delivered_at, :utc_datetime

      timestamps()
    end

    # The only query shape the client issues: "what is still waiting for me?".
    create index(:group_epoch_keys, [:recipient_user_id, :delivered_at])

    # One key per member per epoch, enforced by the database rather than by the
    # application remembering to check. A second, *different* key for an epoch a
    # member already installed is how one sender could split a group into
    # readers and non-readers, so it must be impossible rather than unlikely.
    create unique_index(:group_epoch_keys, [:recipient_user_id, :chat_id, :epoch],
             name: :group_epoch_keys_recipient_chat_epoch_index
           )

    # Backs the per-sender flood cap.
    create index(:group_epoch_keys, [:recipient_user_id, :sender_user_id, :delivered_at])
  end
end
