defmodule Vibe.AI.LocalAgentWorkerTest do
  use ExUnit.Case, async: true

  alias Vibe.AI.LocalAgentWorker

  test "pick_supervisor_lead prefers Claude when it is in the team" do
    codex = %{handle: "codex"}
    claude = %{handle: "claude"}

    assert ^claude = LocalAgentWorker.pick_supervisor_lead([codex, claude])
  end

  test "pick_supervisor_lead preserves the existing fallback order without Claude" do
    grok = %{handle: "grok"}
    codex = %{handle: "codex"}

    assert ^codex = LocalAgentWorker.pick_supervisor_lead([grok, codex])
  end
end
