defmodule VibeWeb.Router do
  use VibeWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug VibeWeb.Plugs.RateLimiter, type: :api
  end

  pipeline :api_stream do
    plug VibeWeb.Plugs.RateLimiter, type: :api
  end

  pipeline :api_authenticated do
    plug VibeWeb.Plugs.ApiAuth, required: true
  end

  pipeline :file_authenticated do
    plug VibeWeb.Plugs.ApiAuth, required: true
  end

  # SECURITY: Rate limited pipeline for auth endpoints
  pipeline :auth_rate_limited do
    plug :accepts, ["json"]
    plug VibeWeb.Plugs.RateLimiter, type: :auth
  end

  # SECURITY: Strict rate limiting for sensitive operations
  pipeline :strict_rate_limited do
    plug :accepts, ["json"]
    plug VibeWeb.Plugs.RateLimiter, type: :strict
  end

  # AI media editing calls a paid third-party model per request, so it gets its
  # own much tighter bucket rather than sharing the strict one.
  pipeline :ai_media_rate_limited do
    plug :accepts, ["json"]
    plug VibeWeb.Plugs.RateLimiter, type: :ai_media
  end

  # Secret-backed public agent ingress should be rate limited, but not in the tiny strict bucket.
  pipeline :public_agent_rate_limited do
    plug :accepts, ["json"]
    plug VibeWeb.Plugs.RateLimiter, type: :public_agent
  end

  # Multipart bodies are parsed here, not in the endpoint, so only upload routes pay for
  # the ceiling; every other route is capped by the endpoint's JSON limit.
  pipeline :multipart_upload do
    plug Plug.Parsers,
      parsers: [:multipart],
      pass: ["*/*"],
      length: String.to_integer(System.get_env("MAX_UPLOAD_BYTES") || "99000000")
  end

  # Runtime → core service calls (docs/agent-platform-v1.md §3.1). Never exposed via Caddy.
  pipeline :internal do
    plug :accepts, ["json"]
    plug VibeWeb.Plugs.InternalServiceAuth
  end

  # Auth endpoints with rate limiting
  scope "/api", VibeWeb do
    pipe_through :auth_rate_limited

    post "/register", AuthController, :register
    post "/login", AuthController, :login
  end

  scope "/api", VibeWeb do
    pipe_through :api

    # Health & Bootstrap
    get "/health", ApiController, :health
    get "/ready", ApiController, :ready
    get "/ping", ApiController, :ping
    get "/info", ApiController, :info
    get "/servers", ApiController, :servers
    get "/vapid-key", ApiController, :vapid_key
    get "/push/avatar/:user_id", PushAvatarController, :show

    # Platform OAuth browser callback (provider redirects here; no user bearer yet —
    # ownership is bound into the signed `state` token).
    get "/platforms/oauth/:provider/callback", PlatformsController, :oauth_callback

    # Agent bridge daemon redeems a pairing code (no user auth — code-scoped).
    post "/agent-bridge/pair", AgentBridgeController, :pair
    # Scan-to-pair (desktop shows QR, phone scans): daemon starts a request and
    # later claims the token with its device_secret (both unauth, secret-scoped).
    post "/agent-bridge/request", AgentBridgeController, :start_request
    post "/agent-bridge/claim", AgentBridgeController, :claim

    # Multi-account device pairing (Telegram-style add/switch account). A new
    # device starts a code-scoped request and later claims the approved token —
    # both unauth (the requester has no account session yet). Approval is
    # authenticated (below).
    post "/account/devices/pairing", AccountDeviceController, :start_pairing
    post "/account/devices/pairing/:code/claim", AccountDeviceController, :claim_pairing
  end

  scope "/api", VibeWeb do
    pipe_through [:api, :api_authenticated]

    # TURN/ICE credentials for WebRTC calls
    get "/turn-credentials", ApiController, :turn_credentials

    # Rotates a pre-v3 account onto one-way-derived credentials so the raw
    # recovery secret — which also wraps the private key — stops being sent to
    # this server. Authenticated: only a caller who just proved possession of
    # the old secret may rotate it.
    post "/upgrade-identity", AuthController, :upgrade_identity
    post "/auth/logout", AuthController, :logout
    post "/auth/logout-all", AuthController, :logout_all

    # User
    get "/user/:id", UserController, :show
    get "/user/name/:username", UserController, :show_by_name
    get "/user/phone/:phone", UserController, :show_by_phone
    post "/user/contacts/match", UserController, :match_contacts
    post "/user/profile", UserController, :update_profile
    post "/user/delete", UserController, :delete
    post "/user/block", UserController, :block
    post "/user/unblock", UserController, :unblock
    get "/user/blocks/:id", UserController, :list_blocks

    # PreKey
    get "/user/:id/prekey-bundle", EncryptionController, :get_bundle
    post "/user/prekey-bundle", EncryptionController, :upload_bundle

    # MLS KeyPackage/Welcome routes live in the strict-rate-limited scope below.
    # Group epoch keys — channels and groups past the MLS member cap.
    post "/group-keys", MlsController, :post_epoch_keys
    get "/group-keys", MlsController, :pending_epoch_keys
    post "/group-keys/:id/ack", MlsController, :ack_epoch_key

    # Account devices — linked-device management + approving a pending pairing.
    get "/account/devices", AccountDeviceController, :index
    post "/account/devices/current", AccountDeviceController, :register_current
    delete "/account/devices/:id", AccountDeviceController, :delete
    post "/account/devices/pairing/:code/approve", AccountDeviceController, :approve_pairing
    get "/account/sessions", AccountDeviceController, :sessions
    delete "/account/sessions/:id", AccountDeviceController, :delete_session

    get "/settings", SettingsController, :show
    patch "/settings/privacy", SettingsController, :update_privacy
    patch "/settings/notifications", SettingsController, :update_notifications

    # Canonical notification-preferences (camelCase contract, see
    # docs/settings-account-architecture.md). GET returns the full object with
    # defaults; PUT deep-merges provided keys and returns the merged object.
    get "/account/notification-preferences", SettingsController, :index
    put "/account/notification-preferences", SettingsController, :update

    # Chat
    post "/chat", ChatController, :create
    get "/chats/:user_id", ChatController, :index
    get "/chat/:chat_id/messages", ChatController, :messages
    delete "/chat/:chat_id/messages/:message_id", ChatController, :delete_message
    get "/chat/:chat_id/pinned_messages", ChatController, :list_pinned_messages
    post "/chat/:chat_id/messages/:message_id/pin", ChatController, :pin_message
    post "/chat/:chat_id/messages/:message_id/report", ChatController, :report_message
    get "/chat/:chat_id/messages/:message_id/reactions", ChatController, :message_reactions
    delete "/chats/:chat_id", ChatController, :delete
    # Clearing is not deleting: this drops the caller's message history and leaves
    # the chat, its membership and its encryption in place.
    post "/chats/:chat_id/clear", ChatController, :clear_messages

    # Settings
    post "/chat/:chat_id/mute", ChatController, :mute
    post "/chat/:chat_id/pin", ChatController, :pin
    post "/chat/:chat_id/mark-unread", ChatController, :mark_unread
    post "/chat/:chat_id/archive", ChatController, :archive

    # Saved Messages
    get "/saved_messages/:user_id", SavedMessageController, :index
    post "/saved_messages", SavedMessageController, :create
    put "/saved_messages/:original_message_id/reaction", SavedMessageController, :reaction
    delete "/saved_messages/:user_id/:original_message_id", SavedMessageController, :delete

    # Subscription & Plans
    get "/plans", SubscriptionController, :list_plans
    get "/subscription/:user_id", SubscriptionController, :show
    post "/subscription/checkout", SubscriptionController, :create_checkout
    post "/subscription/cancel", SubscriptionController, :cancel

    # Referrals
    get "/referral/code/:user_id", ReferralController, :get_code
    get "/referral/stats/:user_id", ReferralController, :stats
    post "/referral/apply", ReferralController, :apply_code
    post "/referral/verify", ReferralController, :verify

    # Badges
    get "/badges/:user_id", BadgeController, :index

    # Music Streaming (Backend Proxy/Cache)
    get "/music/stream/:video_id", MusicController, :stream
    get "/music/info/:video_id", MusicController, :info

    # Business Settings
    get "/business/settings/:user_id", BusinessController, :show
    post "/business/settings", BusinessController, :update_settings

    # Multi-platform connectors (GitHub OAuth, Excel/Slack/Linear catalog, agent grants)
    get "/platforms/catalog", PlatformsController, :catalog
    get "/platforms/connections", PlatformsController, :index
    get "/platforms/connections/:id", PlatformsController, :show
    post "/platforms/connections/:provider/authorize", PlatformsController, :authorize
    delete "/platforms/connections/:id", PlatformsController, :revoke
    post "/platforms/connections/:id/grants", PlatformsController, :upsert_grant
    delete "/platforms/connections/:id/grants/:grant_id", PlatformsController, :revoke_grant
    get "/platforms/usable", PlatformsController, :usable
    post "/platforms/tools/invoke", PlatformsController, :invoke_tool

    # Standalone Agents
    get "/agents", AgentsController, :index
    get "/agents/model_registry", AgentsController, :model_registry
    get "/agents/tool_registry", AgentsController, :tool_registry
    get "/agents/username_available", AgentsController, :username_available
    get "/agents/usage", AgentsController, :owner_usage
    post "/agents", AgentsController, :create
    get "/agents/:id", AgentsController, :show
    get "/agents/:id/secret", AgentsController, :secret
    put "/agents/:id", AgentsController, :update
    post "/agents/:id/publish", AgentsController, :publish
    post "/agents/:id/secret/rotate", AgentsController, :rotate_secret
    get "/agents/:id/deliveries", AgentsController, :deliveries
    get "/agents/:id/usage", AgentsController, :agent_usage
    get "/agents/:id/routines", AgentsController, :routines
    post "/agents/:id/routines", AgentsController, :create_routine
    put "/agents/:id/routines/:routine_id", AgentsController, :update_routine
    delete "/agents/:id/routines/:routine_id", AgentsController, :delete_routine
    get "/agents/:id/integrations", AgentsController, :integrations
    post "/agents/:id/integrations", AgentsController, :create_integration
    put "/agents/:id/integrations/:integration_id", AgentsController, :update_integration
    get "/agents/:id/events", AgentsController, :events
    get "/agents/:id/threads", AgentsController, :threads
    get "/agents/:id/threads/:thread_id", AgentsController, :thread
    post "/agents/:id/approval_tasks/:task_id/approve", AgentsController, :approve_task
    post "/agents/:id/approval_tasks/:task_id/reject", AgentsController, :reject_task
    # Opaque token claim for sender-declared decision actions (not runbook approve/reject).
    post "/decisions/actions", AgentsController, :respond_decision_action
    # Isolated-runtime surfaces (docs/agent-platform-v1.md §3.7 / §3.2).
    post "/agents/:id/voice/sessions", AgentsController, :voice_session
    get "/agents/:id/computer/preview", AgentsController, :computer_preview
    get "/agents/:id/computer/exec-log", AgentsController, :computer_exec_log
    get "/agents/:id/computer/tree", AgentsController, :computer_tree
    get "/agents/:id/computer/file", AgentsController, :computer_file
    post "/agents/:id/computer/session", AgentsController, :computer_session
    delete "/agents/:id/computer/session/:session_id", AgentsController, :close_computer_session
    delete "/agents/:id", AgentsController, :delete

    # Builder
    get "/vibeagent/session", VibeagentController, :session
    post "/vibeagent/chat", VibeagentController, :chat

    # Stories
    post "/stories", StoryController, :create
    get "/stories/feed/:user_id", StoryController, :feed
    get "/stories/my/:user_id", StoryController, :my_stories
    get "/stories/user/:target_user_id", StoryController, :user_stories
    post "/stories/:story_id/view", StoryController, :view
    get "/stories/:story_id/viewers", StoryController, :viewers
    delete "/stories/:story_id", StoryController, :delete
    put "/stories/:story_id/visibility", StoryController, :update_visibility

    # Groups
    post "/group", GroupController, :create
    put "/group/:id", GroupController, :update
    delete "/group/:id", GroupController, :delete
    post "/group/:id/leave", GroupController, :leave
    post "/group/:id/members", GroupController, :add_members
    put "/group/:id/members/:user_id/role", GroupController, :set_role
    delete "/group/:id/members/:user_id", GroupController, :remove_member

    # Group Agent
    post "/group/:id/agent", GroupAgentController, :create
    get "/group/:id/agent", GroupAgentController, :show
    put "/group/:id/agent", GroupAgentController, :update
    delete "/group/:id/agent", GroupAgentController, :delete
    post "/group/:id/agent/generate_prompt", GroupAgentController, :generate_prompt
    post "/group/:id/agent/chat/sync", GroupAgentController, :chat_sync
    get "/agent/document/:key", GroupAgentController, :download_document
    get "/agent/document/:key/:name", GroupAgentController, :download_document

    # Channels
    post "/channel", ChannelController, :create
    get "/channels", ChannelController, :index
    post "/channel/links/resolve", ChannelController, :resolve_link
    post "/channel/links/join", ChannelController, :join_link
    get "/channel/:id", ChannelController, :show
    put "/channel/:id", ChannelController, :update
    post "/channel/:id/join", ChannelController, :join
    post "/channel/:id/leave", ChannelController, :leave
    get "/channel/:id/analytics", ChannelController, :analytics
    post "/channel/:id/invite-link", ChannelController, :rotate_invite
    post "/channel/:id/invite-links", ChannelController, :create_invite
    get "/channel/:id/join-requests", ChannelController, :join_requests

    post "/channel/:id/join-requests/:request_id/decision",
         ChannelController,
         :decide_join_request

    get "/channel/:id/agents", ChannelController, :agents
    post "/channel/:id/agents", ChannelController, :attach_agent
    put "/channel/:id/agents/:agent_id", ChannelController, :update_agent
    delete "/channel/:id/agents/:agent_id", ChannelController, :detach_agent

    # Scheduled Posts
    post "/channel/:id/schedule", ScheduleController, :create
    get "/channel/:id/schedule", ScheduleController, :list
    delete "/schedule/:id", ScheduleController, :cancel

    # Agent Bridge (pair your own computer to run @claude / @codex locally)
    post "/agent-bridge/pairing", AgentBridgeController, :request_pairing
    # Phone authorizes a scanned desktop pairing request (binds it to this user).
    post "/agent-bridge/authorize", AgentBridgeController, :authorize
    get "/agent-bridge/status", AgentBridgeController, :status
    delete "/agent-bridge", AgentBridgeController, :revoke

    # Share links — turn a pasted @handle or vibegram.io link into something openable.
    get "/links/resolve", LinkController, :resolve

    # Relay → Bridge registration
    get "/packet/bootstrap", BridgeController, :packet_bootstrap
    post "/relay/register-bridge", BridgeController, :register_relay
    get "/relay/resolve-bridge", BridgeController, :resolve_relay_bridge
  end

  scope "/api", VibeWeb do
    pipe_through [:api_stream, :api_authenticated]

    post "/vibeagent/chat/stream", VibeagentController, :chat_stream
  end

  # Media upload — the only route that parses multipart (see :multipart_upload).
  scope "/api", VibeWeb do
    pipe_through [:api, :api_authenticated, :multipart_upload]

    post "/media/upload", MediaController, :upload
  end

  # Agent runtime → core (signed, internal network only; Caddy answers 403 for /internal/*).
  scope "/internal/v1", VibeWeb do
    pipe_through :internal

    post "/agent-events", InternalAgentController, :agent_events
    post "/deliveries", InternalAgentController, :deliveries
    post "/approvals", InternalAgentController, :approvals
    post "/provider-auth", InternalAgentController, :provider_auth
    post "/handoffs", InternalAgentController, :handoffs
    get "/agents/:identifier/card", InternalAgentController, :card
    get "/healthz", InternalAgentController, :healthz
  end

  # High-cost / abuse-prone endpoints (require auth + strict rate limit)
  scope "/api", VibeWeb do
    pipe_through [:strict_rate_limited, :api_authenticated]

    # MLS: a claim burns a one-time KeyPackage, so these sit under the strict bucket.
    # "/count" must stay above ":user_id" or it would match as a user id.
    post "/mls/key-packages", MlsController, :publish
    get "/mls/key-packages/count", MlsController, :count
    get "/mls/key-packages/:user_id", MlsController, :claim
    post "/mls/welcomes", MlsController, :post_welcome
    get "/mls/welcomes", MlsController, :pending_welcomes
    post "/mls/welcomes/:id/ack", MlsController, :ack_welcome
    get "/mls/chats/:chat_id/members", MlsController, :chat_members
    get "/mls/chats/:chat_id/welcome-status", MlsController, :welcome_status

    # AI Agent
    post "/agent/chat", AgentController, :chat  # SSE streaming
    post "/agent/chat/sync", AgentController, :chat_sync  # Non-streaming
    get "/agent/health", AgentController, :health

  end

  # AI media editing — authenticated, on its own paid-call rate limit, multipart bodies.
  scope "/api", VibeWeb do
    pipe_through [:ai_media_rate_limited, :api_authenticated, :multipart_upload]

    post "/ai/edit_image", AIController, :edit_image
    post "/ai/edit_video", AIController, :edit_video
  end

  scope "/api", VibeWeb do
    pipe_through :public_agent_rate_limited

    post "/agents/:identifier/invoke", AgentsController, :invoke
    post "/agents/:identifier/events", AgentsController, :ingest_event

    # Public A2A-compatible discovery card (published agents only; see
    # docs/provider-platform.md).
    get "/agents/:identifier/card", AgentsController, :card
  end

  # Standard well-known discovery path for the same agent card.
  scope "/.well-known", VibeWeb do
    pipe_through :public_agent_rate_limited

    get "/agent-card/:identifier", AgentsController, :card
  end

  # Apple universal links. Served unconditionally; it only starts mattering once the
  # app ships the matching associated-domains entitlement (docs/share-links.md).
  scope "/.well-known", VibeWeb do
    get "/apple-app-site-association", LinkController, :aasa
  end

  scope "/bridge/v1", VibeWeb do
    pipe_through [:api, :api_authenticated]

    get "/bundle", BridgeController, :bundle
    post "/session/open", BridgeController, :open_session
    post "/text/send", BridgeController, :send
    post "/text/poll", BridgeController, :poll
    post "/text/ack", BridgeController, :ack
    post "/home/snapshot", BridgeController, :home_snapshot
    post "/chat/history", BridgeController, :chat_history
    post "/keys/peer", BridgeController, :peer_key
  end

  # Webhooks (no auth required)
  scope "/api", VibeWeb do
    pipe_through :api
    post "/webhooks/lemonsqueezy", WebhookController, :lemon_squeezy
  end

  # Legacy authenticated file routes
  scope "/", VibeWeb do
    pipe_through :file_authenticated
    get "/uploads/agent-docs/:name", GroupAgentController, :download_legacy_document
  end

  # Serve React SPA for all other routes
  scope "/", VibeWeb do
    get "/r/:slug", RoomLinkController, :public
    get "/j/:token", RoomLinkController, :private
    # Telegram-style bare handle: `/<username>` previews the person/agent/channel and
    # jumps into the app. Unknown or reserved segments fall through to the SPA inside
    # the action itself, so this can never shadow a web route.
    get "/:handle", LinkController, :preview
    get "/*path", ApiController, :index
  end
end
