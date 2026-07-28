defmodule Vibe.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @apns_prod "https://api.push.apple.com"
  @apns_sandbox "https://api.sandbox.push.apple.com"

  @impl true
  def start(_type, _args) do
    # Create ETS table for rate limiting before starting the endpoint
    # This must happen before any requests can hit the RateLimiter plug
    ensure_ets_table(:rate_limiter)
    # Bearer-token -> user cache; without it every authenticated request pays a
    # full DB round trip just to authenticate (see Vibe.Accounts.TokenCache).
    ensure_ets_table(:auth_token_cache)
    ensure_ets_table(:chat_home_cache)
    ensure_ets_table(:local_agent_worker_ratelimit)
    ensure_ets_table(:local_agent_worker_sessions)
    ensure_ets_table(:agent_bridge_pairings)
    ensure_ets_table(:agent_bridge_requests)
    ensure_ets_table(:agent_bridge_pending_tasks)
    # MCP tool discovery cache — without it every agent turn pays a tools/list
    # round trip to each connected server before the model starts thinking.
    ensure_ets_table(:vibe_mcp_tool_cache)

    children = [
      # Start the Telemetry supervisor
      # VibeWeb.Telemetry,
      # Start the Ecto repository
      Vibe.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: Vibe.PubSub},
      # Start Presence tracking
      VibeWeb.Presence,
      # Start Finch HTTP client for AI APIs
      {Finch, name: Vibe.Finch},
      # APNs requires HTTP/2; keep a dedicated Finch instance so other outbound HTTP is unaffected
      {Finch,
       name: Vibe.APNsFinch,
       pools: %{
         @apns_prod => [protocols: [:http2]],
         @apns_sandbox => [protocols: [:http2]],
         default: [protocols: [:http2]]
       }},
      # Start the Endpoint (http/https)
      VibeWeb.Endpoint,
      # Start the Relay Registry (VibeNet peer relay network)
      Vibe.RelayRegistry,
      # Start the Mesh Fragment Assembler (k-of-n reconstruction)
      Vibe.MeshAssembler,
      # Start the scheduled post scheduler
      # Start the scheduled post scheduler
      Vibe.Scheduler,
      Vibe.AgentDeliveryScheduler,
      Vibe.ChannelAgentScheduler,
      # Start the Story Cleaner
      Vibe.StoryCleaner,
      # Bounded pool for @claude / @codex local agent workers (caps concurrency + cost)
      {Task.Supervisor,
       name: Vibe.AI.WorkerTaskSupervisor, max_children: local_agent_worker_concurrency()},
      # Unlinked pool for in-turn agent tool calls: a raising tool must surface as an
      # error the model can read, never take the whole agent turn down with it.
      {Task.Supervisor, name: Vibe.TaskSupervisor},
      # Zero-token watchdogs for coordinated team runs (one transient GenServer
      # per {chat_id, team_run_id}; docs/team-architecture-v2.md §4)
      {Registry, keys: :unique, name: Vibe.AI.TeamRunRegistry},
      {DynamicSupervisor, name: Vibe.AI.TeamRunMonitorSupervisor, strategy: :one_for_one}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Vibe.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Seed the Claude / Codex agent users so they are searchable and can be
        # DM'd. Idempotent upsert; runs after the Repo is up.
        Task.start(fn -> Vibe.AI.LocalAgentWorker.ensure_agent_users() end)
        {:ok, pid}

      other ->
        other
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    VibeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp local_agent_worker_concurrency do
    case Integer.parse(System.get_env("VIBE_AGENT_WORKER_MAX_CONCURRENCY") || "") do
      {value, _} when value > 0 -> value
      # Default high enough for full group fan-out (claude+codex+grok+agy = 4)
      # plus a couple of concurrent DMs. Was 3 → Agy always got "busy" in 4-agent groups.
      _ -> 8
    end
  end

  defp ensure_ets_table(name) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [:set, :public, :named_table, {:read_concurrency, true}])

      _tid ->
        :ok
    end
  end
end
