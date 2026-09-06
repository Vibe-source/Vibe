defmodule Vibe.Repo.Migrations.TeamRunChatIdString do
  use Ecto.Migration

  # chat ids are strings server-wide (messages.chat_id is varchar; legacy chats
  # use short ids like "ccd43b50-2e1"), so a :binary_id column can never store
  # them — durable team registration always crashed into the ETS fallback for
  # legacy chats and every durable TeamRun query on such a chat raised.
  # computer_id gets the same treatment: bridge computer ids are opaque tokens,
  # not guaranteed UUIDs.
  def up do
    execute(
      "ALTER TABLE agent_team_runs ALTER COLUMN chat_id TYPE varchar(255) USING chat_id::text"
    )

    execute(
      "ALTER TABLE agent_team_runs ALTER COLUMN computer_id TYPE varchar(255) USING computer_id::text"
    )
  end

  def down do
    execute("ALTER TABLE agent_team_runs ALTER COLUMN chat_id TYPE uuid USING chat_id::uuid")

    execute(
      "ALTER TABLE agent_team_runs ALTER COLUMN computer_id TYPE uuid USING computer_id::uuid"
    )
  end
end
