defmodule VibeAgents.Broker do
  @moduledoc """
  Deterministic capability broker (spec §3.9). Runs before every tool call and decides
  `:run | {:approval, request} | {:ask, questions} | {:deny, reason}`. Never reads a prompt
  for policy — only `run.agent_profile` (autonomyMode, approvalRules, enabledTools).
  """

  @external_effect_command ~r/\b(mail|sendmail|curl\s+.*-X\s?(POST|PUT|DELETE)|git\s+push|npm\s+publish|rm\s+-rf)\b/i
  @external_effect_action ~r/pay|buy|purchase|checkout|send|submit|delete|publish|confirm\s*order/i
  @credential_hint ~r/password|passwd|2fa|otp|one[\s-]?time\s*code|captcha|verification\s*code|security\s*code/i

  @doc """
  run: %VibeAgents.Schemas.AgentRun{} or a map with agent_profile/agentProfile. `ask_user`
  is NOT special-cased here — it is always `:run`; the tool itself owns the decision row and
  the terminal "waiting_for_user" result (`VibeAgents.Tools.AskUser`), exactly like the core.
  """
  def authorize(run, tool_name, input) when is_binary(tool_name) do
    input = input || %{}

    if tool_name == "request_approval" do
      {:approval, approval_request_from_input(input)}
    else
      authorize_by_risk(run, tool_name, input)
    end
  end

  def authorize(_run, _tool_name, _input), do: {:deny, "unknown tool"}

  @computer_tools ["computer_run", "computer_read_file", "computer_write_file"]
  @browser_tools ["browser_open", "browser_act", "browser_screenshot"]

  @doc """
  Capability a tool needs the run's sandbox for, or nil. Not part of `authorize/3`'s frozen
  return shape — used by `VibeAgents.Tools.Executor` to gate first use with a `run.permission
  .requested` decision (kind "permission") instead of an approval, since §3.9's table has no
  row for it.
  """
  def required_capability(tool_name) when tool_name in @computer_tools, do: "computer"
  def required_capability(tool_name) when tool_name in @browser_tools, do: "browser"
  def required_capability(_tool_name), do: nil

  @doc "Full_auto/safe_auto auto-grant capability use; other modes gate the first call."
  def auto_grant_capability?(run), do: autonomy_mode(run) in ["full_auto", "safe_auto"]

  def permission_request(capability, reason) do
    %{"capability" => capability, "scope" => "run", "reason" => reason}
  end

  defp authorize_by_risk(run, tool_name, input) do
    risk = risk_class(tool_name, input)
    mode = autonomy_mode(run)

    case {risk, mode} do
      {:read, _mode} ->
        :run

      {:credential, _mode} ->
        {:ask, [%{"question" => "This step needs a credential I must not handle myself. What should I do?", "header" => "Credential", "multiSelect" => false, "options" => [%{"label" => "Skip this step"}, %{"label" => "Tell me what to do"}]}]}

      {:write_local, mode} when mode in ["full_auto", "safe_auto"] ->
        :run

      {:write_local, "approval_required"} ->
        {:approval, generic_request(tool_name, input, "write_local")}

      {:write_local, _manual_or_draft} ->
        {:approval, generic_request(tool_name, input, "write_local")}

      {:external_effect, "full_auto"} ->
        if tool_name in allowlisted_tools(run),
          do: :run,
          else: {:approval, generic_request(tool_name, input, "external_effect")}

      {:external_effect, _mode} ->
        {:approval, generic_request(tool_name, input, "external_effect")}
    end
  end

  @doc "Tool → risk class, including the browser_act / computer_run content heuristics."
  def risk_class(tool_name, input \\ %{})

  def risk_class(tool_name, _input)
      when tool_name in ["search_google", "read_url", "computer_read_file", "browser_screenshot", "recall", "ask_user"],
      do: :read

  def risk_class("computer_write_file", _input), do: :write_local
  def risk_class("browser_open", _input), do: :write_local
  def risk_class("handoff_to_agent", _input), do: :write_local
  def risk_class("remember", _input), do: :write_local

  def risk_class("computer_run", input) do
    cmd = input["command"] || input[:command] || input["cmd"] || input[:cmd] || input["code"] || input[:code] || ""
    if Regex.match?(@external_effect_command, to_string(cmd)), do: :external_effect, else: :write_local
  end

  def risk_class("browser_act", input) do
    text = to_string(input["text"] || input[:text] || "")
    selector = to_string(input["selector"] || input[:selector] || "")

    cond do
      Regex.match?(@credential_hint, text) or Regex.match?(@credential_hint, selector) -> :credential
      Regex.match?(@external_effect_action, text) or Regex.match?(@external_effect_action, selector) -> :external_effect
      true -> :write_local
    end
  end

  def risk_class(_tool_name, _input), do: :write_local

  defp autonomy_mode(run) do
    profile(run)["autonomyMode"] || profile(run)[:autonomyMode] || "approval_required"
  end

  defp allowlisted_tools(run) do
    rules = profile(run)["approvalRules"] || profile(run)[:approvalRules] || %{}
    allow = rules["allow"] || rules[:allow] || []
    Enum.map(allow, &to_string/1)
  end

  defp profile(%{agent_profile: profile}) when is_map(profile), do: profile
  defp profile(%{"agent_profile" => profile}) when is_map(profile), do: profile
  defp profile(%{agentProfile: profile}) when is_map(profile), do: profile
  defp profile(_run), do: %{}

  defp generic_request(tool_name, input, risk) do
    %{
      "title" => "Allow #{tool_name}?",
      "detail" => input_preview(input),
      "risk" => risk,
      "actions" => [
        %{"id" => "approve", "label" => "Approve", "style" => "primary", "confirm" => nil},
        %{"id" => "reject", "label" => "Reject", "style" => "destructive", "confirm" => nil}
      ],
      "actionMode" => "single"
    }
  end

  defp approval_request_from_input(input) do
    %{
      "title" => input["title"] || input[:title] || "Approve this action?",
      "detail" => input["detail"] || input[:detail] || "",
      "risk" => input["risk"] || input[:risk] || "external_effect",
      "actions" => [
        %{"id" => "approve", "label" => "Approve", "style" => "primary", "confirm" => nil},
        %{"id" => "reject", "label" => "Reject", "style" => "destructive", "confirm" => nil}
      ],
      "actionMode" => "single"
    }
  end

  defp input_preview(input) do
    input |> Jason.encode!() |> String.slice(0, 300)
  rescue
    _ -> ""
  end
end
