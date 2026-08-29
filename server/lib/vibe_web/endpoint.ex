defmodule VibeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :vibe

  # JSON/urlencoded cap. MLS welcome posts carry a base64 ratchet tree up to
  # ~5.5MB encoded (Vibe.Mls @max_ratchet_tree_bytes), so this sits above that.
  @max_json_body_bytes (case Integer.parse(System.get_env("MAX_JSON_BODY_BYTES") || "8000000") do
                          {value, _} when value > 0 -> value
                          _ -> 8_000_000
                        end)

  # Content-Length sanity ceiling across all routes, enforced by BodyLimit
  # before parsing. Multipart uploads get their own cap in the router pipeline.
  @max_upload_body_bytes (case Integer.parse(System.get_env("MAX_UPLOAD_BYTES") || "120000000") do
                             {value, _} when value > 0 -> value
                             _ -> 120_000_000
                           end)

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_vibe_key",
    signing_salt: "VA520x4+"
  ]

  socket("/socket", VibeWeb.UserSocket,
    websocket: [
      # Phoenix only forwards headers whose names start with "x-". Mobile clients
      # send `x-vibe-auth: Bearer <login_token>` (not Authorization) so the token
      # is available here without putting it in the WebSocket URL query string.
      connect_info: [:x_headers]
    ],
    longpoll: false
  )

  # Agent bridge daemon (the user's computer) connects here, authenticated by its
  # bridge_token via `x-vibe-bridge-token: Bearer <bridge_token>`. Outbound-only
  # from the daemon's perspective. Query param `token` remains a fallback.
  socket("/agent-bridge", VibeWeb.AgentBridgeSocket,
    websocket: [connect_info: [:x_headers]],
    longpoll: false
  )

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
    plug(Phoenix.Ecto.CheckRepoStatus, otp_app: :vibe)
  end

  plug(Plug.Static,
    at: "/",
    from: if(code_reloading?, do: :vibe, else: "priv/static"),
    gzip: false,
    only: VibeWeb.static_paths()
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(VibeWeb.Plugs.BodyLimit, max_bytes: @max_upload_body_bytes)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    length: @max_json_body_bytes,
    json_decoder: Phoenix.json_library(),
    body_reader: {VibeWeb.Plugs.RawBodyReader, :read_body, []}
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)

  # CORS Plug
  cors_origins =
    case System.get_env("CORS_ORIGINS") do
      nil ->
        [
          "http://localhost:3000",
          "http://localhost:5173",
          "https://localhost:5173",
          "https://vibe-io-nine.vercel.app",
          ~r/https?:\/\/.*railway\.app$/,
          ~r/https?:\/\/.*ngrok\.io$/,
          ~r/https?:\/\/.*ngrok-free\.app$/
        ]

      raw ->
        raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end

  plug(CORSPlug,
    origin: cors_origins,
    headers: [
      "Authorization",
      "Content-Type",
      "Accept",
      "Origin",
      "User-Agent",
      "DNT",
      "Cache-Control",
      "X-Mx-ReqToken",
      "Keep-Alive",
      "X-Requested-With",
      "If-Modified-Since",
      "ngrok-skip-browser-warning",
      # WebSocket / HTTP clients that prefer header auth over query tokens.
      "x-vibe-auth",
      "x-vibe-bridge-token"
    ]
  )

  plug(VibeWeb.Plugs.SecurityHeaders)
  plug(VibeWeb.Router)

  @doc """
  Production Ecto SSL options from env-style inputs.

  - `verify_env` of `"none"` (case-insensitive) opts out → `verify_none`
  - otherwise (including `nil` / unset) → `verify_peer` when a CA bundle path
    is provided; falls back to `verify_none` only when no CA is available

  Pure helper so unit tests can prove the prod default without booting runtime.exs.
  """
  def db_ssl_opts(verify_env, cacert_ders) do
    verify =
      case verify_env do
        nil -> nil
        value when is_binary(value) -> String.downcase(String.trim(value))
        _ -> nil
      end

    case verify do
      "none" ->
        [verify: :verify_none]

      _ ->
        if is_list(cacert_ders) and cacert_ders != [] do
          [verify: :verify_peer, cacerts: cacert_ders]
        else
          [verify: :verify_none]
        end
    end
  end
end
