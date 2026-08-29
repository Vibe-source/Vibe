defmodule Vibe.Repo.Migrations.AddMissingIndexes do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Concurrent builds: no DDL transaction, no migration lock, so each index
  # builds without blocking writers. See docs/scale-readiness-data-layer.md
  # and the coredata handoff for which hot queries each one serves.
  def change do
    # Vibe.ChatBridge.fetch_poll_events/2: chat_id IN (...) + inserted_at range,
    # order by inserted_at. The existing (chat_id, timestamp) index is a
    # different column and does not serve this scan.
    create(index(:messages, [:chat_id, :inserted_at], concurrently: true))

    # Chat.list_saved_messages/1 orders by `timestamp` (client ms), not
    # inserted_at — indexed on the column actually queried.
    create(index(:saved_messages, [:user_id, :timestamp], concurrently: true))

    # Chat.list_chats_uncached/2 (the /api/chats hot path) filters user_id +
    # not-deleted on every load. Partial: smaller and preferred by the
    # planner over the existing full user_id index for this predicate.
    create(
      index(:chat_participants, [:user_id],
        concurrently: true,
        where: "deleted IS NOT TRUE",
        name: :chat_participants_user_id_active_index
      )
    )

    # Chat.list_channels/0 (channel discovery) filters type + access_type and
    # orders by inserted_at; only a single-column type index exists today.
    create(index(:chats, [:type, :access_type, :inserted_at], concurrently: true))

    # Vibe.AI.Agent.query_event_inbox/3 filters agent_id + occurred_at range
    # and orders by occurred_at desc; only thread_id/status composites exist.
    create(index(:agent_events, [:agent_id, :occurred_at], concurrently: true))
  end
end
