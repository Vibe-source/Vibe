defmodule Vibe.Repo.Migrations.AddAgentPreviousSecret do
  use Ecto.Migration

  @moduledoc """
  Rotating an agent secret used to be an instant cutover, which is right when a
  key leaked but breaks every live integration when the rotation was planned.
  These columns hold the outgoing secret for an explicit, bounded grace window
  so both keys verify until it expires.
  """

  def change do
    alter table(:agents) do
      add :previous_secret_hash, :string
      add :previous_secret_expires_at, :utc_datetime
    end
  end
end
