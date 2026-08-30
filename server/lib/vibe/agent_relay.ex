defmodule Vibe.AgentRelay do
  @moduledoc """
  Maps runtime `RunEvent`s (docs/agent-platform-v1.md §3.4) onto the
  `agent-stream` / `agent-approval` / `agent-bridge-ask` / `agent-preview` /
  `agent-run-state` frames iOS already renders for embedded agents.
  """

  require Logger

  alias Vibe.Agent
  alias Vibe.AI.AgentDecisions
  alias Vibe.Chat
  alias Vibe.Repo

  @state_table :agent_run_state

  def handle(%{"kind" => kind, "runId" => run_id, "chatId" => chat_id} = event)
      when is_binary(run_id) and is_binary(chat_id) do
    ensure_table()
    payload = event["payload"] || %{}

    case kind do
      k when k in ["run.queued", "run.started"] ->
        VibeWeb.ChatChannel.broadcast_agent_activity(chat_id, event["agentUserId"], "Thinking...", "running")
        broadcast_stream(event, "running")

      "run.text.delta" ->
        append_text(run_id, payload["text"] || "")
        broadcast_stream(event, "running")

      "run.thinking" ->
        broadcast_stream(event, "running")

      "run.progress" ->
        append_node(run_id, activity_node(payload))
        broadcast_stream(event, "running")

      "run.tool.started" ->
        append_node(run_id, tool_node(payload))
        append_tool_event(run_id, payload)
        broadcast_stream(event, "running")

      "run.tool.completed" ->
        update_tool_node(run_id, payload)
        update_tool_event(run_id, payload)
        broadcast_stream(event, "running")

      "run.approval.requested" ->
        handle_approval(event, "approval")

      "run.permission.requested" ->
        handle_approval(event, "permission")

      "run.approval.resolved" ->
        :ok

      "run.ask" ->
        VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-bridge-ask", %{
          "requestId" => payload["decisionId"],
          "kind" => "ask",
          "provider" => "vibe",
          "runtime" => "isolated",
          "runId" => run_id,
          "chatId" => chat_id,
          "ask" => %{"questions" => payload["questions"] || []}
        })

      "run.preview" ->
        VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-preview", %{
          "chatId" => chat_id,
          "runId" => run_id,
          "agentUserId" => event["agentUserId"],
          "imageBase64" => payload["imageBase64"],
          "mime" => payload["mime"] || "image/jpeg",
          "width" => payload["width"],
          "height" => payload["height"],
          "label" => payload["label"],
          "ts" => event["ts"]
        })

      k when k in ["run.computer.state", "run.computer.control"] ->
        VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-computer", %{
          "chatId" => chat_id,
          "runId" => run_id,
          "agentUserId" => event["agentUserId"],
          "url" => payload["url"],
          "title" => payload["title"],
          "live" => payload["live"],
          "holder" => payload["holder"],
          "ts" => event["ts"]
        })

      "run.handoff" ->
        :ok

      _ ->
        if VibeContracts.RunEvent.terminal?(kind) do
          VibeWeb.ChatChannel.stop_agent_activity(chat_id, event["agentUserId"])
          finish_run(event)
        else
          Logger.warning("[AgentRelay] unhandled RunEvent kind=#{inspect(kind)} runId=#{run_id}")
        end
    end

    :ok
  end

  def handle(other) do
    Logger.warning("[AgentRelay] malformed RunEvent #{inspect(other)}")
    :ok
  end

  defp handle_approval(event, kind) do
    chat_id = event["chatId"]
    run_id = event["runId"]
    payload = event["payload"] || %{}

    agent = Agent |> Repo.get(event["agentId"]) |> then(&(&1 && Repo.preload(&1, :agent_user)))

    if agent do
      params = payload |> Map.put("runId", run_id) |> Map.put("kind", kind)

      case AgentDecisions.create_runtime_decision(agent, chat_id, params) do
        {:ok, %{taskId: task_id, messageId: message_id}} ->
          VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-approval", %{
            "chatId" => chat_id,
            "runId" => run_id,
            "decisionId" => payload["decisionId"],
            "taskId" => task_id,
            "messageId" => message_id,
            "kind" => kind,
            "title" => payload["title"],
            "expiresAt" => payload["expiresAt"]
          })

        {:error, reason} ->
          Logger.error("[AgentRelay] create_runtime_decision failed run=#{run_id} reason=#{inspect(reason)}")
      end
    else
      Logger.error("[AgentRelay] approval for unknown agent run=#{run_id} agentId=#{event["agentId"]}")
    end
  end

  defp broadcast_stream(event, status) do
    chat_id = event["chatId"]
    run_id = event["runId"]
    state = get_state(run_id)

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-stream", %{
      "chatId" => chat_id,
      "streamId" => run_id,
      "userId" => event["agentUserId"],
      "agentUserId" => event["agentUserId"],
      "isAgent" => true,
      "isAgentMessage" => true,
      "text" => state.text,
      "progressNodes" => state.progress_nodes,
      "toolEvents" => state.tool_events,
      "status" => status,
      "runId" => run_id,
      "runtime" => "isolated"
    })
  end

  defp finish_run(event) do
    kind = event["kind"]
    chat_id = event["chatId"]
    run_id = event["runId"]
    payload = event["payload"] || %{}
    state = get_state(run_id)

    base = %{
      "chatId" => chat_id,
      "streamId" => run_id,
      "userId" => event["agentUserId"],
      "agentUserId" => event["agentUserId"],
      "isAgent" => true,
      "isAgentMessage" => true,
      "text" => state.text,
      "progressNodes" => state.progress_nodes,
      "toolEvents" => state.tool_events,
      "status" => "done",
      "runId" => run_id,
      "runtime" => "isolated"
    }

    stream_payload =
      case kind do
        "run.failed" -> Map.put(base, "error", payload["error"] || "Run failed")
        "run.cancelled" -> Map.put(base, "reason", payload["reason"] || "cancelled")
        _ -> base
      end

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-stream", stream_payload)

    status = %{"run.completed" => "completed", "run.cancelled" => "cancelled"} |> Map.get(kind, "failed")

    run_state_payload =
      %{"chatId" => chat_id, "runId" => run_id, "status" => status}
      |> maybe_put_reason(payload["reason"] || payload["error"])

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-run-state", run_state_payload)
    Chat.broadcast_user_chat_event(chat_id, "agent-run-state", run_state_payload)

    clear_state(run_id)
  end

  defp maybe_put_reason(map, nil), do: map
  defp maybe_put_reason(map, reason), do: Map.put(map, "reason", reason)

  # Mirrors Vibe.AI.AgenticEventShape.tool_node/1 / activity_node/1 (both private,
  # and that file isn't owned by any worker this run) so iOS renders identical cards.
  defp tool_node(payload) do
    tool = payload["tool"] || "tool"

    %{
      id: payload["toolCallId"] || "tool:#{tool}",
      label: payload["label"] || tool,
      status: "running",
      depth: 0,
      kind: tool_kind(tool),
      itemType: "tool",
      target: nil,
      tool: tool,
      callId: payload["toolCallId"] || tool,
      eventType: "progress"
    }
  end

  defp activity_node(payload) do
    label = payload["label"] || "Working"

    %{
      id: "activity:#{label}",
      label: label,
      status: payload["status"] || "running",
      depth: 0,
      kind: "task",
      target: nil,
      parentId: nil,
      subagentType: nil
    }
  end

  defp tool_kind(tool) do
    tool = to_string(tool)

    cond do
      tool == "read_url" -> "web"
      String.contains?(tool, "search") -> "web"
      String.contains?(tool, "browser") -> "web"
      String.contains?(tool, "ask_user") -> "question"
      String.contains?(tool, "handoff") -> "agent"
      true -> "tool"
    end
  end

  defp ensure_table do
    case :ets.whereis(@state_table) do
      :undefined -> :ets.new(@state_table, [:set, :public, :named_table, {:read_concurrency, true}])
      _tid -> :ok
    end
  end

  defp get_state(run_id) do
    case :ets.lookup(@state_table, run_id) do
      [{^run_id, state}] -> state
      [] -> %{text: "", progress_nodes: [], tool_events: []}
    end
  end

  defp put_state(run_id, state) do
    :ets.insert(@state_table, {run_id, state})
    state
  end

  defp clear_state(run_id), do: :ets.delete(@state_table, run_id)

  defp append_text(run_id, delta) do
    state = get_state(run_id)
    put_state(run_id, %{state | text: state.text <> delta})
  end

  defp append_node(run_id, node) do
    state = get_state(run_id)
    put_state(run_id, %{state | progress_nodes: state.progress_nodes ++ [node]})
  end

  defp update_tool_node(run_id, payload) do
    state = get_state(run_id)
    call_id = payload["toolCallId"]
    status = payload["status"] || "done"

    updated =
      Enum.map(state.progress_nodes, fn node ->
        if node[:callId] == call_id, do: %{node | status: status}, else: node
      end)

    put_state(run_id, %{state | progress_nodes: updated})
  end

  defp append_tool_event(run_id, payload) do
    state = get_state(run_id)

    entry = %{
      "id" => payload["toolCallId"],
      "tool" => payload["tool"],
      "label" => payload["label"],
      "status" => "running",
      "input" => payload["input"]
    }

    put_state(run_id, %{state | tool_events: state.tool_events ++ [entry]})
  end

  defp update_tool_event(run_id, payload) do
    state = get_state(run_id)
    call_id = payload["toolCallId"]

    updated =
      Enum.map(state.tool_events, fn e ->
        if e["id"] == call_id do
          Map.merge(e, %{"status" => payload["status"] || "done", "summary" => payload["summary"]})
        else
          e
        end
      end)

    put_state(run_id, %{state | tool_events: updated})
  end
end
