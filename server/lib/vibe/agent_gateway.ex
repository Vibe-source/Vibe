defmodule Vibe.AgentGateway do
  @moduledoc """
  Signed client from the chat core to the isolated agent-runtime service
  (docs/agent-platform-v1.md §3.1-§3.2). Disabled (no-op) until both
  `VIBE_AGENT_RUNTIME_URL` and `VIBE_INTERNAL_HMAC_KEY` are set.
  """

  require Logger

  alias Vibe.Agent
  alias Vibe.Chat
  alias Vibe.AI.StandaloneAgent

  @service_name "core"

  @doc "URL + signing key both present — the only precondition for any call here."
  def enabled? do
    present?(runtime_url()) and present?(hmac_key())
  end

  @doc "`VIBE_AI_KILL_SWITCH=1` refuses every new dispatch, embedded or isolated."
  def kill_switch?, do: System.get_env("VIBE_AI_KILL_SWITCH") == "1"

  @doc "Env override (`VIBE_AGENT_EXECUTION_MODE`) wins over the agent's own column."
  def execution_mode_for(%Agent{} = agent) do
    case System.get_env("VIBE_AGENT_EXECUTION_MODE") do
      "isolated" -> "isolated"
      "embedded" -> "embedded"
      _ -> agent.execution_mode || "embedded"
    end
  end

  @doc """
  Builds a `RunRequest` from `%{agent:, chat_id:, requester_user_id:, text:, attachments:,
  reply_to_id:, source:, parent_run_id:, idempotency_key:}` and starts a run.
  Returns `{:error, :kill_switch}` / `{:error, :unreachable}` / `{:error, reason}`.
  """
  def start_run(params) when is_map(params) do
    if kill_switch?() do
      {:error, :kill_switch}
    else
      agent = Map.fetch!(params, :agent) |> Vibe.Repo.preload(:agent_user)
      chat_id = Map.fetch!(params, :chat_id)

      body =
        %{
          "idempotencyKey" => params[:idempotency_key],
          "source" => params[:source] || "chat",
          "agentId" => agent.id,
          "agentUserId" => agent.agent_user_id,
          "ownerUserId" => agent.owner_user_id,
          "requesterUserId" => params[:requester_user_id],
          "chatId" => chat_id,
          "chatKind" => Chat.get_room_type(chat_id) || "dm",
          "replyToId" => params[:reply_to_id],
          "parentRunId" => params[:parent_run_id],
          "input" => %{
            "text" => params[:text] || "",
            "attachments" => normalize_attachments(params[:attachments] || [])
          },
          "agentProfile" => agent_profile(agent),
          "context" => %{
            "history" => history_for(agent, chat_id, params[:requester_user_id]),
            "participants" => participants_for(chat_id, agent.agent_user_id)
          },
          "capabilities" => capabilities_for(agent)
        }
        |> compact()

      request(:post, "/internal/v1/runs", body)
    end
  end

  @doc "`POST /internal/v1/runs/:runId/cancel`."
  def cancel(run_id, reason, requested_by_user_id) do
    request(:post, "/internal/v1/runs/#{run_id}/cancel", %{
      "reason" => reason,
      "requestedByUserId" => requested_by_user_id
    })
  end

  @doc "`POST /internal/v1/runs/:runId/decisions` — approve/reject/answer/grant/deny."
  def decision(run_id, params, _opts \\ []) do
    body =
      %{
        "decisionId" => params[:decisionId] || params["decisionId"],
        "kind" => params[:kind] || params["kind"],
        "outcome" => params[:outcome] || params["outcome"],
        "answer" => params[:answer] || params["answer"],
        "actorUserId" => params[:actorUserId] || params["actorUserId"],
        "actionId" => params[:actionId] || params["actionId"]
      }
      |> compact()

    request(:post, "/internal/v1/runs/#{run_id}/decisions", body)
  end

  @doc "`GET /internal/v1/runs/:runId` → `{run, events}`."
  def get_run(run_id), do: request(:get, "/internal/v1/runs/#{run_id}", nil)

  @doc "`POST /internal/v1/agents/:agentId/computer` — ensures a sandboxed computer."
  def ensure_computer(agent_id) do
    request(:post, "/internal/v1/agents/#{agent_id}/computer", %{"action" => "ensure"})
  end

  @doc "`GET /internal/v1/agents/:agentId/computer/preview` — latest screenshot."
  def computer_preview(agent_id) do
    request(:get, "/internal/v1/agents/#{agent_id}/computer/preview", nil)
  end

  @doc "`POST /internal/v1/voice/sessions` — params is `{agentId,userId,chatId,agentProfile}`."
  def voice_session(params), do: request(:post, "/internal/v1/voice/sessions", params)

  @doc "`POST /internal/v1/provider-invoke` — an already-authenticated provider payload."
  def provider_invoke(%Agent{} = agent, payload) when is_map(payload) do
    body = Map.merge(%{"source" => "provider", "agentId" => agent.id}, payload)
    request(:post, "/internal/v1/provider-invoke", body)
  end

  @doc "`GET /internal/v1/healthz`."
  def healthy? do
    match?({:ok, %{"ok" => true}}, request(:get, "/internal/v1/healthz", nil))
  end

  @doc "Same `agentProfile` shape sent in a RunRequest — reused by `/internal/v1/provider-auth`."
  def agent_profile(%Agent{} = agent) do
    %{
      "displayName" => agent.display_name,
      "username" => agent.agent_user && agent.agent_user.username,
      "systemPrompt" => agent.system_prompt,
      "persona" => agent.persona,
      "modelProvider" => agent.model_provider,
      "modelId" => agent.model_id,
      # No per-agent thinking-level column yet; a fixed default until one exists.
      "thinkingLevel" => "medium",
      "enabledTools" => agent.enabled_tools || [],
      "outputModes" => agent.output_modes || [],
      "autonomyMode" => agent.autonomy_mode,
      "approvalRules" => agent.approval_rules || %{},
      "budgets" => %{
        "dailyCents" => agent.cost_budget_daily,
        "monthlyCents" => agent.cost_budget_monthly
      },
      "adminMode" => agent.admin_mode || false
    }
  end

  defp history_for(_agent, _chat_id, nil), do: []

  defp history_for(agent, chat_id, requester_user_id) do
    StandaloneAgent.history_for_runtime(chat_id, requester_user_id, agent.agent_user_id)
  end

  # Names aren't resolved (would be an N+1 per participant); the runtime already
  # has isAgent + userId to cross-reference against context.history.
  defp participants_for(chat_id, agent_user_id) do
    chat_id
    |> Chat.get_participant_ids()
    |> Enum.map(&%{"userId" => &1, "isAgent" => &1 == agent_user_id, "name" => nil})
  end

  # attachment_context_to_attachments/1 (ChatChannel) uses :type "image"|"file"|"voice";
  # the runtime contract uses :kind "image"|"document"|"audio".
  defp normalize_attachments(attachments) do
    Enum.map(attachments, fn a ->
      type = to_string(a[:type] || a["type"] || "file")

      kind =
        case type do
          "image" -> "image"
          "voice" -> "audio"
          "audio" -> "audio"
          _ -> "document"
        end

      %{
        "kind" => kind,
        "url" => a[:url] || a["url"],
        "mime" => a[:mime] || a["mime"],
        "name" => a[:name] || a["name"]
      }
      |> compact()
    end)
  end

  # computer_run/browser_open aren't in Vibe.AI.ToolRegistry yet (unowned this run) —
  # honored here once an agent's enabled_tools actually contains them.
  defp capabilities_for(agent) do
    tools = agent.enabled_tools || []
    computer? = "computer_run" in tools
    browser? = "browser_open" in tools

    %{
      "computer" => computer?,
      "browser" => browser?,
      "network" => if(computer? or browser?, do: "allowlist", else: "none")
    }
  end

  defp request(method, path, body) do
    if enabled?() do
      json_body = if body, do: Jason.encode!(body), else: ""
      headers = build_headers(method, path, json_body)
      url = runtime_url() <> path

      case http_client().(method, url, headers, json_body) do
        {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
          {:ok, decode(resp_body)}

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:http_error, status, decode(resp_body)}}

        {:error, :unreachable} ->
          {:error, :unreachable}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :disabled}
    end
  end

  defp build_headers(method, path, json_body) do
    method_str = method |> Atom.to_string() |> String.upcase()

    case VibeContracts.ServiceAuth.headers(hmac_key(), method_str, path, json_body,
           service: @service_name
         ) do
      {:error, reason} -> raise ArgumentError, "internal auth signing failed: #{inspect(reason)}"
      headers -> headers ++ [{"content-type", "application/json"}]
    end
  end

  defp http_client do
    Application.get_env(:vibe, :agent_gateway_http, &default_http_request/4)
  end

  defp default_http_request(method, url, headers, body) do
    request = Finch.build(method, url, headers, body)

    case Finch.request(request, Vibe.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:ok, %{status: status, body: resp_body}}

      {:error, reason} ->
        Logger.warning("[AgentGateway] request failed url=#{url} reason=#{inspect(reason)}")
        {:error, classify_error(reason)}
    end
  end

  defp classify_error(%Mint.TransportError{reason: reason})
       when reason in [:econnrefused, :closed, :timeout, :nxdomain],
       do: :unreachable

  defp classify_error(_reason), do: :request_failed

  defp decode(body) when is_binary(body) and body != "" do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode(_body), do: %{}

  defp compact(map) when is_map(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end

  defp runtime_url, do: String.trim_trailing(System.get_env("VIBE_AGENT_RUNTIME_URL") || "", "/")
  defp hmac_key, do: System.get_env("VIBE_INTERNAL_HMAC_KEY") || ""
  defp present?(v), do: is_binary(v) and String.trim(v) != ""
end
