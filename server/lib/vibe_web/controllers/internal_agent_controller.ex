defmodule VibeWeb.InternalAgentController do
  @moduledoc """
  Runtime → core internal API (docs/agent-platform-v1.md §3.3). Mounted behind
  `VibeWeb.Plugs.InternalServiceAuth` — never exposed publicly through Caddy.
  """

  use VibeWeb, :controller
  require Logger

  alias Vibe.Agent
  alias Vibe.AgentGateway
  alias Vibe.AgentRelay
  alias Vibe.Agents
  alias Vibe.AgentUsage
  alias Vibe.AI.AgentDecisions
  alias Vibe.AI.StandaloneAgent
  alias Vibe.Chat
  alias Vibe.Repo

  @seen_table :agent_run_seen
  @seen_ttl_seconds 3600

  def agent_events(conn, %{"events" => events}) when is_list(events) do
    ensure_seen_table()

    accepted =
      Enum.reduce(events, 0, fn event, acc ->
        with {:ok, validated} <- VibeContracts.RunEvent.validate(event),
             true <- agent_in_chat?(validated["agentUserId"], validated["chatId"]),
             false <- seen?(validated) do
          mark_seen(validated)
          maybe_record_usage(validated)
          AgentRelay.handle(validated)
          acc + 1
        else
          true ->
            acc

          false ->
            Logger.warning("[InternalAgentController] RunEvent for a chat the agent is not in — dropped")
            acc

          {:error, reason} ->
            Logger.warning("[InternalAgentController] invalid RunEvent reason=#{inspect(reason)}")
            acc

          _other ->
            acc
        end
      end)

    json(conn, %{accepted: accepted})
  end

  def agent_events(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "invalid_events"})
  end

  # The runtime is trusted for identity, not for authority: an agent may only post
  # into chats it is a participant of, exactly like the embedded path.
  defp agent_in_chat?(agent_user_id, chat_id) when is_binary(agent_user_id) and is_binary(chat_id) do
    Chat.is_participant?(chat_id, agent_user_id)
  end

  defp agent_in_chat?(_agent_user_id, _chat_id), do: false

  # Meters a completed isolated run. Never raises — usage capture must not drop the event.
  defp maybe_record_usage(%{"kind" => "run.completed"} = event) do
    case Agents.get_agent(event["agentId"]) do
      nil -> :ok
      agent -> AgentUsage.record_run_completed(agent, event)
    end
  rescue
    error ->
      Logger.warning("[InternalAgentController] usage capture failed error=#{Exception.message(error)}")
  end

  defp maybe_record_usage(_event), do: :ok

  @doc "Public A2A card for the runtime's `/v1/agents/:identifier/card` proxy."
  def card(conn, %{"identifier" => identifier}) do
    case Agents.get_invoke_target(identifier) do
      %Agent{status: "published"} = agent ->
        json(conn, Vibe.AgentCard.build(agent, VibeWeb.Endpoint.url()))

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def deliveries(conn, %{"agentId" => agent_id, "chatId" => chat_id} = params) do
    outputs = params["outputs"] || []
    reply_to_id = params["replyToId"]

    case Repo.get(Agent, agent_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "agent_not_found"})

      %Agent{agent_user_id: agent_user_id} = agent ->
        if agent_in_chat?(agent_user_id, chat_id) do
          agent = Repo.preload(agent, :agent_user)

          case StandaloneAgent.deliver_outputs(agent, chat_id, outputs, reply_to_id) do
            {:ok, delivered} -> json(conn, %{deliveries: delivered})
            {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
          end
        else
          conn |> put_status(:forbidden) |> json(%{error: "agent_not_in_chat"})
        end
    end
  end

  def approvals(conn, %{"agentId" => agent_id, "chatId" => chat_id} = params) do
    case Repo.get(Agent, agent_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "agent_not_found"})

      %Agent{agent_user_id: agent_user_id} = agent ->
        if agent_in_chat?(agent_user_id, chat_id) do
          agent = Repo.preload(agent, :agent_user)

          case AgentDecisions.create_runtime_decision(agent, chat_id, params) do
            {:ok, %{taskId: task_id, messageId: message_id}} ->
              json(conn, %{taskId: task_id, messageId: message_id})

            {:error, reason} ->
              conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
          end
        else
          conn |> put_status(:forbidden) |> json(%{error: "agent_not_in_chat"})
        end
    end
  end

  # Never reveal whether the identifier or the secret was wrong.
  def provider_auth(conn, %{"identifier" => identifier, "secret" => secret})
      when is_binary(identifier) and is_binary(secret) do
    with %Agent{status: "published"} = agent <- Agents.get_invoke_target(identifier),
         true <- Agents.verify_secret(agent, secret) do
      agent = Repo.preload(agent, :agent_user)

      json(conn, %{
        agentProfile: AgentGateway.agent_profile(agent),
        agentId: agent.id,
        agentUserId: agent.agent_user_id,
        ownerUserId: agent.owner_user_id,
        defaultChatId: agent.default_destination_chat_id
      })
    else
      _ -> unauthorized(conn)
    end
  end

  def provider_auth(conn, _params), do: unauthorized(conn)

  def handoffs(
        conn,
        %{
          "runId" => run_id,
          "agentId" => agent_id,
          "chatId" => chat_id,
          "toAgentUsername" => target_username
        } = params
      ) do
    note = params["note"] || ""

    with %Agent{} = source_agent <- Repo.get(Agent, agent_id),
         true <- Chat.is_participant?(chat_id, source_agent.agent_user_id),
         %Agent{status: "published"} = target_agent <- Agents.get_agent_by_username(target_username),
         true <- Chat.is_participant?(chat_id, target_agent.agent_user_id) do
      source_agent = Repo.preload(source_agent, :agent_user)
      handoff_text = String.trim("@#{target_username} #{note}")

      outputs = [
        %{"type" => "text", "text" => handoff_text, "metadata" => %{"handoffFromRunId" => run_id}}
      ]

      case StandaloneAgent.deliver_outputs(source_agent, chat_id, outputs, nil) do
        {:ok, [delivery | _]} ->
          _ =
            VibeWeb.ChatChannel.dispatch_agent_mention(chat_id, target_agent,
              text: note,
              parent_run_id: run_id
            )

          json(conn, %{messageId: delivery.messageId, dispatched: true})

        {:ok, []} ->
          json(conn, %{messageId: nil, dispatched: false})

        {:error, _reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "delivery_failed"})
      end
    else
      _ -> conn |> put_status(:forbidden) |> json(%{error: "handoff_not_allowed"})
    end
  end

  def handoffs(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "invalid_handoff"})
  end

  def healthz(conn, _params), do: json(conn, %{ok: true})

  defp unauthorized(conn), do: conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})

  defp ensure_seen_table do
    case :ets.whereis(@seen_table) do
      :undefined -> :ets.new(@seen_table, [:set, :public, :named_table, {:read_concurrency, true}])
      _tid -> :ok
    end
  end

  defp seen?(%{"runId" => run_id, "seq" => seq}) do
    key = {run_id, seq}

    case :ets.lookup(@seen_table, key) do
      [{^key, expires_at}] -> expires_at > System.system_time(:second)
      [] -> false
    end
  end

  defp seen?(_event), do: false

  defp mark_seen(%{"runId" => run_id, "seq" => seq}) do
    key = {run_id, seq}
    :ets.insert(@seen_table, {key, System.system_time(:second) + @seen_ttl_seconds})
  end

  defp mark_seen(_event), do: :ok
end
