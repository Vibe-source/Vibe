defmodule VibeAgents.BudgetTest do
  use ExUnit.Case, async: false

  import VibeAgents.Test.Fixtures

  alias VibeAgents.{Budget, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "a run under every ceiling passes" do
    run = insert_run!()
    assert :ok = Budget.check!(run)
  end

  test "the per-run token ceiling raises" do
    run = insert_run!()
    run = %{run | usage: %{"inputTokens" => 400_001, "outputTokens" => 0}}
    assert_raise Budget.ExceededError, fn -> Budget.check!(run) end
  end

  test "daily cents are enforced from the ledger" do
    run = insert_run!(%{"agentProfile" => agent_profile(%{"budgets" => %{"dailyCents" => 1, "monthlyCents" => nil}})})
    assert :ok = Budget.check!(run)
    cost = Budget.record_usage(run, 100_000, 100_000)
    assert cost >= 1
    assert_raise Budget.ExceededError, fn -> Budget.check!(run) end
  end

  test "token estimate is ~4 chars per token" do
    assert Budget.estimate_tokens(String.duplicate("a", 400)) == 100
  end
end
