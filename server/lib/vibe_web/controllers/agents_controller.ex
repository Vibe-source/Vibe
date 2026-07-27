defmodule VibeWeb.AgentsController do
  use VibeWeb, :controller
  require Logger

  alias Vibe.AgentCard
  alias Vibe.Agents
  alias Vibe.ProviderContent
  alias Vibe.AI.AgentEventRuntime
  alias Vibe.AI.StandaloneAgent

  @doc """
  Public A2A-compatible agent card for a published agent.

  Lookup matches `invoke/2` (`Agents.get_invoke_target/1`). Only
  `status == "published"` returns 200; missing, draft, disabled, and
  archived agents all return the same 404 so existence is not leaked.
  No auth required — integrator mounts this on the public rate-limited scope.
  """
  def card(conn, %{"identifier" => identifier}) do
    case Agents.get_invoke_target(identifier) do
      %{status: "published"} = agent ->
        base_url = VibeWeb.Endpoint.url()
        json(conn, AgentCard.build(agent, base_url))

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def index(conn, _params) do
    owner_id = conn.assigns.current_user.id
    quota = Agents.quota_for_user(owner_id)

    items =
      owner_id
      |> Agents.list_agents()
      |> Enum.map(&Agents.agent_payload/1)

    json(conn, %{items: items, quota: quota})
  end

  @doc """
  Returns the catalog of tools an agent can be granted.

  `toggleable_tools/0`, not `tools/0`: the full catalog also includes
  always-on runtime/meta tools (agent_management, ask_user, the always-on
  analytics pair) that the native Vibe AI assistant uses to manage agents —
  they're never optional for a standalone agent, so showing them as
  togglable items in its own Tools picker just clutters it with entries
  that look like the built-in assistant's own capabilities leaking in.
  """
  def tool_registry(conn, _params) do
    json(conn, %{items: Vibe.AI.ToolRegistry.toggleable_tools()})
  end

  @doc "Returns the server-authoritative provider and model catalog."
  def model_registry(conn, _params) do
    json(conn, Vibe.AI.ModelRegistry.public_payload())
  end

  @doc """
  Live availability check for an agent handle/username. Pass `username` and,
  when editing an existing agent, `agent_id` so the agent's own current handle
  reads as available.
  """
  def username_available(conn, params) do
    owner_id = conn.assigns.current_user.id
    username = params["username"] || ""

    agent =
      case params["agent_id"] || params["id"] do
        id when is_binary(id) and id != "" -> Agents.get_agent(id, owner_id)
        _ -> nil
      end

    case Agents.username_availability(username, agent) do
      {:ok, normalized} -> json(conn, %{available: true, username: normalized})
      {:error, reason} -> json(conn, %{available: false, reason: to_string(reason)})
    end
  end

  def create(conn, params) do
    owner_id = conn.assigns.current_user.id

    case Agents.create_agent(owner_id, params) do
      {:ok, agent, secret} ->
        json(conn, %{agent: Agents.agent_payload(agent, quota: Agents.quota_for_user(owner_id)), secret: secret})

      {:error, :quota_exceeded} ->
        conn |> put_status(:forbidden) |> json(%{error: "Agent limit reached"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def show(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    case Agents.get_agent(id, owner_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      agent -> json(conn, Agents.agent_payload(agent, quota: Agents.quota_for_user(owner_id)))
    end
  end

  def secret(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, secret} <- Agents.callback_signing_secret(agent) do
      json(conn, %{secret: secret, secretHint: agent.secret_hint})
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, updated} <- Agents.update_agent(agent, Map.delete(params, "id"), owner_id) do
      json(conn, Agents.agent_payload(updated, quota: Agents.quota_for_user(owner_id)))
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def publish(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, updated} <- Agents.publish_agent(agent, owner_id) do
      json(conn, Agents.agent_payload(updated, quota: Agents.quota_for_user(owner_id)))
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def rotate_secret(conn, %{"id" => id} = params) do
    owner_id = conn.assigns.current_user.id
    # نبودِ این پارامتر یعنی ابطالِ فوری — حالتِ «کلیدم لو رفته».
    grace_hours = params["graceHours"] || params["grace_hours"]

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, updated, secret} <-
           Agents.rotate_secret(agent, owner_id, grace_hours: grace_hours) do
      json(conn, %{
        agent: Agents.agent_payload(updated),
        secret: secret,
        previousSecretExpiresAt: updated.previous_secret_expires_at
      })
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      {:error, :invalid_grace_hours} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "graceHours must be a whole number of hours"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def deliveries(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    case Agents.get_agent(id, owner_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      agent -> json(conn, Agents.list_delivery_data(agent))
    end
  end

  def delete(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, _} <- Agents.archive_agent(agent, owner_id) do
      json(conn, %{success: true})
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def invoke(conn, %{"identifier" => identifier} = params) do
    secret = List.first(get_req_header(conn, "x-vibe-agent-secret"))

    Logger.info(
      "[AgentsController] invoke start " <>
        "identifier=#{identifier} method=#{conn.method} path=#{conn.request_path} " <>
        "content_type=#{List.first(get_req_header(conn, "content-type")) || "unknown"} " <>
        "secret_present=#{is_binary(secret)} params_keys=#{inspect(Map.keys(params) |> Enum.sort())}"
    )

    with %{} = agent <- Agents.get_invoke_target(identifier),
         :ok <- ensure_agent_published(agent),
         :ok <- ensure_secret(agent, secret),
         {:ok, params} <- merge_provider_content(params),
         {:ok, result} <- StandaloneAgent.invoke(agent, params),
         {:ok, invocation} <-
           Agents.record_invocation(agent, %{
             source: params["source"] || "external",
             event_id: params["eventId"] || params["event_id"],
             vibe_chat_id: params["vibeChatId"] || params["vibe_chat_id"],
             external_user_id: params["externalUserId"] || params["external_user_id"],
             request_payload: Map.drop(params, ["identifier"]),
             response_payload: result,
           status: "completed"
           }) do
      Logger.info(
        "[AgentsController] invoke success " <>
          "identifier=#{identifier} agent_id=#{agent.id} invocation_id=#{invocation.id} " <>
          "outputs=#{length(Map.get(result, :outputs, Map.get(result, "outputs", [])) || [])}"
      )

      if is_binary(agent.callback_url) and String.trim(agent.callback_url) != "" do
        _ = Agents.create_delivery_event(agent, invocation, "agent.invocation.completed", result)
      end

      json(conn, result |> Map.put(:success, true) |> Map.put(:invocationId, invocation.id))
    else
      nil ->
        Logger.warning("[AgentsController] invoke missing agent identifier=#{identifier}")
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      {:error, :agent_unavailable} ->
        Logger.warning("[AgentsController] invoke unavailable identifier=#{identifier}")
        conn |> put_status(:forbidden) |> json(%{error: "Agent unavailable"})

      {:error, :invalid_secret} ->
        Logger.warning("[AgentsController] invoke invalid secret identifier=#{identifier}")
        conn |> put_status(:unauthorized) |> json(%{error: "Invalid secret"})

      {:error, :chat_not_attached} ->
        Logger.warning("[AgentsController] invoke chat not attached identifier=#{identifier}")
        conn |> put_status(:forbidden) |> json(%{error: "Agent not attached to target chat"})

      {:error, {:invalid_content, reason}} ->
        Logger.warning(
          "[AgentsController] invoke invalid content identifier=#{identifier} reason=#{inspect(reason)}"
        )

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_content", detail: inspect(reason)})

      {:error, reason} ->
        Logger.error("[AgentsController] invoke failed identifier=#{identifier} reason=#{inspect(reason)}")
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  # vibe.content.v1 (docs/provider-content-contract.md): when the body carries a
  # parts envelope, validate it and degrade to the message/attachments shape the
  # invoke pipeline already understands. The envelope's text lanes are
  # authoritative over a bare "message" param (dual-publish). Requests without a
  # content envelope pass through untouched.
  defp merge_provider_content(%{"content" => %{"contract" => _} = content} = params) do
    case ProviderContent.parse(content) do
      {:ok, normalized} ->
        attrs = ProviderContent.to_message_attrs(normalized)
        merged_attachments = List.wrap(params["attachments"]) ++ (attrs["attachments"] || [])

        {:ok,
         params
         |> Map.put("message", attrs["text"])
         |> Map.put("attachments", merged_attachments)
         |> Map.put("providerContent", normalized)}

      {:error, reason} ->
        {:error, {:invalid_content, reason}}
    end
  end

  defp merge_provider_content(params), do: {:ok, params}

  def integrations(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    case Agents.get_agent(id, owner_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      agent ->
        items =
          agent
          |> Agents.list_integrations()
          |> Enum.map(&Agents.integration_payload/1)

        json(conn, %{items: items})
    end
  end

  def create_integration(conn, %{"id" => id} = params) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, integration, secret} <- Agents.create_integration(agent, Map.drop(params, ["id"]), owner_id) do
      json(conn, %{integration: Agents.integration_payload(integration, latest_secret: secret), secret: secret})
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def update_integration(conn, %{"id" => id, "integration_id" => integration_id} = params) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         %{} = integration <- Agents.get_integration(agent, integration_id),
         {:ok, updated} <- Agents.update_integration(integration, Map.drop(params, ["id", "integration_id"]), owner_id) do
      json(conn, %{integration: Agents.integration_payload(updated)})
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Integration not found"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def events(conn, %{"id" => id} = params) do
    owner_id = conn.assigns.current_user.id
    limit = bounded_integer(params["limit"], 200, 1, 500)
    offset = bounded_integer(params["offset"], 0, 0, 100_000)

    case Agents.get_agent(id, owner_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      agent ->
        {events, total} = Agents.list_events(agent, limit: limit, offset: offset)

        json(conn, %{
          items: Enum.map(events, &Agents.event_payload/1),
          total: total,
          limit: limit,
          offset: offset,
          hasMore: offset + length(events) < total
        })
    end
  end

  def threads(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    case Agents.get_agent(id, owner_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      agent ->
        items =
          agent
          |> Agents.list_threads()
          |> Enum.map(&Agents.thread_payload/1)

        json(conn, %{items: items})
    end
  end

  def thread(conn, %{"id" => id, "thread_id" => thread_id}) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         %{} = thread <- Agents.get_thread(agent, thread_id) do
      json(conn, %{thread: Agents.thread_payload(thread, details: true)})
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Thread not found"})
    end
  end

  def approve_task(conn, %{"id" => id, "task_id" => task_id} = params) do
    owner_id = conn.assigns.current_user.id
    note = params["note"]

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, task} <- Agents.approve_task(agent, task_id, owner_id, note),
         {:ok, execution} <- AgentEventRuntime.execute_approved_task(agent, task) do
      json(conn, %{task: Agents.approval_task_payload(task), execution: execution})
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Task not found"})
      {:error, :already_decided} -> conn |> put_status(:unprocessable_entity) |> json(%{error: "Task already decided"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def reject_task(conn, %{"id" => id, "task_id" => task_id} = params) do
    owner_id = conn.assigns.current_user.id
    note = params["note"]

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, task} <- Agents.reject_task(agent, task_id, owner_id, note) do
      json(conn, %{task: Agents.approval_task_payload(task)})
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Task not found"})
      {:error, :already_decided} -> conn |> put_status(:unprocessable_entity) |> json(%{error: "Task already decided"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def ingest_event(conn, params) when is_map(params) do
    identifier = params["identifier"] || conn.path_params["identifier"]
    secret =
      List.first(get_req_header(conn, "x-vibe-agent-secret"))
      || List.first(get_req_header(conn, "x-vibe-integration-secret"))

    Logger.info(
      "[AgentsController] ingest_event start " <>
        "identifier=#{identifier || "missing"} method=#{conn.method} path=#{conn.request_path} " <>
        "content_type=#{List.first(get_req_header(conn, "content-type")) || "unknown"} " <>
        "secret_present=#{is_binary(secret)} raw_body_bytes=#{byte_size(conn.assigns[:raw_body] || "")} " <>
        "params_keys=#{inspect(Map.keys(params) |> Enum.sort())}"
    )

    try do
      with true <- is_binary(identifier),
           %{} = agent <- Agents.get_invoke_target(identifier),
           :ok <- ensure_agent_published(agent),
           {:ok, event_params} <- merge_provider_content(Map.drop(params, ["identifier"])),
           {:ok, result} <- AgentEventRuntime.ingest(agent, event_params, secret: secret) do
        Logger.info(
          "[AgentsController] ingest_event success " <>
            "identifier=#{identifier} agent_id=#{agent.id} result=#{inspect(result)}"
        )

        json(conn, result)
      else
        false ->
          Logger.warning("[AgentsController] ingest_event missing identifier")
          conn |> put_status(:bad_request) |> json(%{error: "Missing agent identifier"})

        nil ->
          Logger.warning("[AgentsController] ingest_event missing agent identifier=#{identifier}")
          conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

        {:error, :agent_unavailable} ->
          Logger.warning("[AgentsController] ingest_event unavailable identifier=#{identifier}")
          conn |> put_status(:forbidden) |> json(%{error: "Agent unavailable"})

        {:error, :invalid_secret} ->
          Logger.warning("[AgentsController] ingest_event invalid secret identifier=#{identifier}")
          conn |> put_status(:unauthorized) |> json(%{error: "Invalid secret"})

        {:error, :chat_not_attached} ->
          Logger.warning("[AgentsController] ingest_event chat not attached identifier=#{identifier}")
          conn |> put_status(:forbidden) |> json(%{error: "Agent not attached to target chat"})

        # همان ردهٔ chat_not_attached است — ردِ مجوز، نه ورودیِ نامعتبر. بدون این
        # بند، اتم خام داخل بدنهٔ ۴۲۲ چاپ می‌شد.
        {:error, :event_trigger_not_enabled} ->
          Logger.warning("[AgentsController] ingest_event trigger not enabled identifier=#{identifier}")

          conn
          |> put_status(:forbidden)
          |> json(%{error: "event_trigger_not_enabled"})

        {:error, :missing_destination_chat} ->
          Logger.warning("[AgentsController] ingest_event missing destination chat identifier=#{identifier}")
          conn |> put_status(:unprocessable_entity) |> json(%{error: "Missing destination chat"})

        {:error, :missing_event_type} ->
          Logger.warning("[AgentsController] ingest_event missing event type identifier=#{identifier}")
          conn |> put_status(:unprocessable_entity) |> json(%{error: "eventType is required"})

        {:error, {:invalid_content, reason}} ->
          Logger.warning(
            "[AgentsController] ingest_event invalid content identifier=#{identifier} reason=#{inspect(reason)}"
          )

          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "invalid_content", detail: inspect(reason)})

        {:error, reason} ->
          Logger.error("[AgentsController] ingest_event failed identifier=#{identifier} reason=#{inspect(reason)}")
          conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
      end
    rescue
      exception ->
        Logger.error(
          "[AgentsController] ingest_event exception " <>
            "identifier=#{identifier || "missing"} exception=#{inspect(exception)} " <>
            "stacktrace=#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        reraise exception, __STACKTRACE__
    end
  end

  defp bounded_integer(value, fallback, minimum, maximum) do
    parsed =
      cond do
        is_integer(value) -> value
        is_binary(value) ->
          case Integer.parse(value) do
            {number, _} -> number
            :error -> fallback
          end

        true ->
          fallback
      end

    parsed
    |> max(minimum)
    |> min(maximum)
  end

  defp ensure_agent_published(%{status: "published"}), do: :ok
  defp ensure_agent_published(_agent), do: {:error, :agent_unavailable}

  defp ensure_secret(agent, secret) do
    if Agents.verify_secret(agent, secret), do: :ok, else: {:error, :invalid_secret}
  end
end
