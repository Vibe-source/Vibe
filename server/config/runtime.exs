import Config

if System.get_env("PHX_SERVER") do
  config :vibe, VibeWeb.Endpoint, server: true
end

if config_env() == :prod do
  media_cdn_base_url = System.get_env("MEDIA_CDN_BASE_URL")

  # Support DATABASE_URL directly, or construct from SUPABASE_URL + SUPABASE_DB_PASSWORD
  # Support DATABASE_URL directly, or construct from SUPABASE_URL + SUPABASE_DB_PASSWORD
  database_url = System.get_env("DATABASE_URL")

  database_url =
    if is_nil(database_url) do
      # Try to construct from Supabase vars
      supabase_url = System.get_env("SUPABASE_URL")
      supabase_db_password = System.get_env("SUPABASE_DB_PASSWORD")

      if supabase_url && supabase_db_password do
        case Regex.run(~r/https?:\/\/([^.]+)\.supabase\.co/, supabase_url) do
          [_, project_ref] ->
            region = System.get_env("SUPABASE_REGION") || "us-east-1"

            "postgresql://postgres.#{project_ref}:#{URI.encode_www_form(supabase_db_password)}@aws-0-#{region}.pooler.supabase.com:6543/postgres"

          _ ->
            nil
        end
      end
    else
      database_url
    end

  # Fallback if still nil
  database_url =
    if is_nil(database_url) do
      IO.warn("""
      Environment variable DATABASE_URL is missing.
      Application will start but Database operations will fail.
      Set DATABASE_URL or SUPABASE_* vars to fix.
      """)

      "postgres://user:pass@localhost:5432/db_missing"
    else
      database_url
    end

  # Store Supabase credentials for API access (Storage, etc.)
  config :vibe, :supabase,
    url: System.get_env("SUPABASE_URL"),
    key: System.get_env("SUPABASE_KEY"),
    service_key: System.get_env("SUPABASE_SERVICE_KEY"),
    media_cdn_base_url: media_cdn_base_url,
    # Optional: allow different buckets per use-case.
    # If unset, code falls back to its default bucket.
    bucket: System.get_env("SUPABASE_BUCKET"),
    media_bucket: System.get_env("SUPABASE_MEDIA_BUCKET"),
    music_bucket: System.get_env("SUPABASE_MUSIC_BUCKET")

  # Cloudflare R2 credentials (additive path alongside Supabase — see
  # Vibe.R2Storage and Vibe.Storage). Vibe.Storage.backend/0 defaults to
  # :supabase, so setting these alone does not change any existing
  # behaviour; the backend only switches when :vibe, :storage_backend is
  # explicitly set to :r2 elsewhere. R2_PUBLIC_BASE_URL is read here for
  # forward-compat but is not currently used to build any URL — R2 objects
  # are private and are only ever read via short-TTL presigned GETs.
  config :vibe, :r2,
    account_id: System.get_env("R2_ACCOUNT_ID"),
    access_key_id: System.get_env("R2_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("R2_SECRET_ACCESS_KEY"),
    bucket: System.get_env("R2_BUCKET"),
    public_base_url: System.get_env("R2_PUBLIC_BASE_URL")

  # Lemon Squeezy configuration for payments
  config :vibe, :lemon_squeezy,
    api_key: System.get_env("LEMON_SQUEEZY_API_KEY"),
    store_id: System.get_env("LEMON_SQUEEZY_STORE_ID"),
    webhook_secret: System.get_env("LEMON_SQUEEZY_WEBHOOK_SECRET")

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ["true", "1"], do: [:inet6], else: []

  # DB SSL: default is peer verification when a CA bundle is available.
  # Explicit DB_SSL_VERIFY=none still opts out. Unset is no longer treated as "none".
  # Decision table is mirrored by VibeWeb.Endpoint.db_ssl_opts/2 (unit-tested).
  db_ssl_verify = System.get_env("DB_SSL_VERIFY")
  db_cacertfile_env = System.get_env("DB_CACERTFILE")

  default_cacertfile =
    Enum.find(
      [
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/ssl/cert.pem"
      ],
      &File.exists?/1
    )

  db_cacertfile = db_cacertfile_env || default_cacertfile

  db_ssl_verify_norm =
    case db_ssl_verify do
      nil -> nil
      value when is_binary(value) -> String.downcase(String.trim(value))
      _ -> nil
    end

  ssl_opts =
    case db_ssl_verify_norm do
      "none" ->
        [verify: :verify_none]

      _ ->
        if is_binary(db_cacertfile) and String.trim(db_cacertfile) != "" do
          [verify: :verify_peer, cacertfile: db_cacertfile]
        else
          IO.warn(
            "DB SSL peer verification requested (or defaulted) but no CA bundle found; " <>
              "falling back to verify_none. Set DB_CACERTFILE or DB_SSL_VERIFY=none explicitly."
          )

          [verify: :verify_none]
        end
    end

  config :vibe, Vibe.Repo,
    ssl: ssl_opts,
    prepare: :unnamed,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "20"),
    queue_target: 5000,
    queue_interval: 1000,
    timeout: 30_000,
    connect_timeout: 30_000,
    handshake_timeout: 30_000,
    idle_interval: 10_000,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  check_origin =
    case System.get_env("PHX_CHECK_ORIGIN") do
      nil ->
        false

      raw ->
        raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end

  config :vibe, VibeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/plug_cowboy/Plug.Cowboy.html
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    check_origin: check_origin,
    secret_key_base: secret_key_base
end
