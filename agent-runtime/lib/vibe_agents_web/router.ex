defmodule VibeAgentsWeb.Router do
  use VibeAgentsWeb, :router

  pipeline :internal do
    plug(:accepts, ["json"])
    plug(VibeAgentsWeb.Plugs.InternalServiceAuth)
  end

  pipeline :public_ingress do
    plug(:accepts, ["json"])
    plug(VibeAgentsWeb.Plugs.PublicRateLimit)
    plug(VibeAgentsWeb.Plugs.Idempotency)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/internal/v1", VibeAgentsWeb do
    pipe_through(:internal)

    post("/runs", InternalController, :create_run)
    post("/runs/:run_id/cancel", InternalController, :cancel_run)
    post("/runs/:run_id/decisions", InternalController, :decide)
    get("/runs/:run_id", InternalController, :show_run)
    post("/agents/:agent_id/computer", InternalController, :computer)
    get("/agents/:agent_id/computer/preview", InternalController, :computer_preview)
    post("/agents/:agent_id/computer/session", InternalController, :computer_session)
    delete("/agents/:agent_id/computer/session/:session_id", InternalController, :close_computer_session)
    get("/agents/:agent_id/computer/frame", InternalController, :computer_frame)
    get("/agents/:agent_id/computer/state", InternalController, :computer_state)
    post("/agents/:agent_id/computer/control", InternalController, :computer_control)
    post("/agents/:agent_id/computer/input", InternalController, :computer_input)
    post("/provider-invoke", InternalController, :provider_invoke)
    post("/voice/sessions", InternalController, :voice_sessions)
    get("/healthz", InternalController, :healthz)
  end

  scope "/v1", VibeAgentsWeb do
    pipe_through(:public_ingress)

    post("/agents/:identifier/invoke", ProviderController, :invoke)
    post("/agents/:identifier/events", ProviderController, :events)
    get("/agents/:identifier/card", ProviderController, :card)
    get("/tasks/:task_id", ProviderController, :task)
  end

  scope "/", VibeAgentsWeb do
    pipe_through(:api)

    get("/healthz", HealthController, :healthz)
    get("/readyz", HealthController, :readyz)
  end
end
