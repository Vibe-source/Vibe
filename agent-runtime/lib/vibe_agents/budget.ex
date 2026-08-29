defmodule VibeAgents.Budget do
  @moduledoc """
  Per-run token ceiling + per-agent daily/monthly cents, checked before each model call and
  each tool call (spec §3.9). Token counts are the same char/4 estimate the ported LLM loop
  uses for its live "thinking" counter — providers do not return exact counts mid-stream.
  """
  import Ecto.Query
  alias VibeAgents.Repo
  alias VibeAgents.Schemas.AgentUsageLedger

  defmodule ExceededError do
    defexception [:message, :which]
  end

  # Cents per 1,000 tokens {input, output}. Placeholders — update with real billing.
  @rates %{
    {"anthropic", "claude-fable-5"} => {0.5, 2.5},
    {"anthropic", "claude-opus-4-8"} => {1.5, 7.5},
    {"anthropic", "claude-sonnet-5"} => {0.3, 1.5},
    {"anthropic", "claude-haiku-4-5"} => {0.08, 0.4},
    {"openai", "gpt-5.6-sol"} => {1.5, 6.0},
    {"openai", "gpt-5.6-terra"} => {0.3, 1.2},
    {"openai", "gpt-5.6-luna"} => {0.015, 0.06}
  }
  @default_rate {0.3, 1.5}

  @doc "Raises VibeAgents.Budget.ExceededError when a ceiling is already exceeded."
  def check!(run) do
    check_run_tokens!(run)
    check_period!(run, "dailyCents", :day)
    check_period!(run, "monthlyCents", :month)
    :ok
  end

  @doc "Records one round's usage against the run + the daily ledger; returns cost in cents."
  def record_usage(run, input_tokens, output_tokens) do
    cost = cost_cents(run, input_tokens, output_tokens)

    %AgentUsageLedger{}
    |> AgentUsageLedger.changeset(%{
      agent_id: run.agent_id,
      run_id: run.id,
      day: Date.utc_today(),
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cost_cents: cost
    })
    |> Repo.insert()

    cost
  end

  @doc "Rough token count: ~4 chars/token, same heuristic as the streamed thinking counter."
  def estimate_tokens(text) when is_binary(text), do: text |> String.length() |> div(4) |> max(0)
  def estimate_tokens(other), do: other |> inspect() |> estimate_tokens()

  defp check_run_tokens!(run) do
    ceiling = Application.get_env(:vibe_agents, :max_run_tokens, 400_000)
    used = Map.get(run.usage || %{}, "inputTokens", 0) + Map.get(run.usage || %{}, "outputTokens", 0)

    if used > ceiling do
      raise ExceededError, message: "per-run token ceiling exceeded", which: :run_tokens
    end
  end

  defp check_period!(run, budget_key, period) do
    budgets = run.agent_profile["budgets"] || run.agent_profile[:budgets] || %{}

    case budgets[budget_key] do
      cents when is_integer(cents) and cents > 0 ->
        spent = spent_cents(run.agent_id, period)
        if spent >= cents, do: raise(ExceededError, message: "#{period} spend ceiling exceeded", which: period)

      _ ->
        :ok
    end
  end

  defp spent_cents(agent_id, :day) do
    today = Date.utc_today()

    from(l in AgentUsageLedger, where: l.agent_id == ^agent_id and l.day == ^today, select: sum(l.cost_cents))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp spent_cents(agent_id, :month) do
    today = Date.utc_today()
    start_of_month = Date.beginning_of_month(today)

    from(l in AgentUsageLedger,
      where: l.agent_id == ^agent_id and l.day >= ^start_of_month and l.day <= ^today,
      select: sum(l.cost_cents)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp cost_cents(run, input_tokens, output_tokens) do
    provider = run.agent_profile["modelProvider"] || run.agent_profile[:modelProvider] || "anthropic"
    model = run.agent_profile["modelId"] || run.agent_profile[:modelId]
    {in_rate, out_rate} = Map.get(@rates, {provider, model}, @default_rate)
    (input_tokens / 1000 * in_rate + output_tokens / 1000 * out_rate) |> Float.round(4) |> ceil_cents()
  end

  defp ceil_cents(cents) when is_float(cents), do: cents |> Float.ceil() |> trunc()
end
