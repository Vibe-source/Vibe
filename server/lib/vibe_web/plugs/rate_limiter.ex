defmodule VibeWeb.Plugs.RateLimiter do
  @moduledoc """
  Rate limiting plug to prevent brute force attacks.
  Uses ETS for in-memory rate limiting (resets on server restart).

  For production, consider using Redis-based rate limiting for distributed environments.
  """
  import Plug.Conn
  require Logger

  @behaviour Plug

  # Default limits (can be overridden in opts)
  @default_limits %{
    # 10 attempts per minute for login/register
    auth: {10, 60_000},
    # 300 requests per minute for general API
    api: {300, 60_000},
    # 60 requests per minute for expensive authenticated ops
    strict: {60, 60_000},
    # 600 requests per minute for secret-backed agent ingress
    public_agent: {600, 60_000},
    # 10 per 5 minutes for AI media edits. Each call is a paid third-party
    # generation (~$0.17 an image, ~$1 a 10s video clip), so the strict bucket's
    # 60/min was an unbounded spend surface, not a safety limit.
    ai_media: {10, 300_000}
  }

  def init(opts) do
    # Ensure ETS table exists
    ensure_table_exists()
    opts
  end

  def call(conn, opts) do
    # Ensure table exists at runtime (defensive check)
    ensure_table_exists()

    limit_type = Keyword.get(opts, :type, :api)
    {max_requests, window_ms} = resolve_limits(limit_type)

    identifier = get_identifier(conn)
    bucket = request_bucket(conn.request_path)
    key = {limit_type, bucket, identifier.kind, identifier.value}

    case check_rate_limit(key, max_requests, window_ms) do
      {:ok, remaining, reset_at_ms} ->
        maybe_log_request(
          conn,
          limit_type,
          identifier,
          bucket,
          remaining,
          max_requests,
          window_ms
        )

        attach_rate_limit_headers(conn, max_requests, remaining, reset_at_ms)

      {:error, retry_after_ms, reset_at_ms} ->
        retry_after_seconds = div(retry_after_ms, 1000) + 1

        Logger.warning(
          "[RateLimiter] blocked request " <>
            "type=#{limit_type} method=#{conn.method} bucket=#{bucket} path=#{conn.request_path} " <>
            "identifier_kind=#{identifier.kind} identifier=#{identifier.fingerprint} " <>
            "limit=#{max_requests}/#{window_ms}ms retry_after=#{retry_after_seconds}s"
        )

        conn
        |> attach_rate_limit_headers(max_requests, 0, reset_at_ms)
        |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
        |> put_resp_content_type("application/json")
        |> send_resp(
          429,
          Jason.encode!(%{
            error: "Too many requests",
            retry_after: retry_after_seconds,
            message: "Please slow down. Try again in #{retry_after_seconds} seconds."
          })
        )
        |> halt()
    end
  end

  defp get_identifier(conn) do
    cond do
      user = conn.assigns[:current_user] ->
        identifier(:user, user.id)

      bearer = extract_bearer(conn) ->
        identifier(:bearer_token, bearer)

      secret = extract_agent_secret(conn) ->
        identifier(:agent_secret, secret)

      true ->
        identifier(:ip, forwarded_or_remote_ip(conn))
    end
  end

  defp ensure_table_exists do
    case :ets.whereis(:rate_limiter) do
      :undefined ->
        :ets.new(:rate_limiter, [:set, :public, :named_table, {:read_concurrency, true}])

      _ ->
        :ok
    end
  end

  defp check_rate_limit(key, max_requests, window_ms) do
    now = System.system_time(:millisecond)
    window_start = now - window_ms

    case :ets.lookup(:rate_limiter, key) do
      [] ->
        # First request - allow and record. Guard the table against unbounded
        # growth (a burst of never-before-seen identifiers) by pruning expired
        # keys once it crosses a soft cap. With the XFF fix an attacker can no
        # longer mint distinct identifiers at will, so this only ever trims genuine
        # churn.
        maybe_prune(window_ms)
        :ets.insert(:rate_limiter, {key, [{now, 1}]})
        {:ok, max_requests - 1, now + window_ms}

      [{^key, requests}] ->
        # Filter out old requests outside the window
        recent_requests = Enum.filter(requests, fn {timestamp, _} -> timestamp > window_start end)
        total_count = Enum.reduce(recent_requests, 0, fn {_, count}, acc -> acc + count end)

        if total_count >= max_requests do
          # Rate limited - calculate retry-after
          oldest_in_window =
            recent_requests |> Enum.map(fn {ts, _} -> ts end) |> Enum.min(fn -> now end)

          retry_after = oldest_in_window + window_ms - now
          {:error, max(retry_after, 1000), oldest_in_window + window_ms}
        else
          # Allow and record
          new_requests = [{now, 1} | recent_requests] |> Enum.take(max_requests * 2)
          :ets.insert(:rate_limiter, {key, new_requests})

          reset_at_ms =
            new_requests
            |> Enum.map(fn {timestamp, _} -> timestamp end)
            |> Enum.min(fn -> now end)
            |> Kernel.+(window_ms)

          {:ok, max_requests - total_count - 1, reset_at_ms}
        end
    end
  end

  # Soft ceiling on distinct rate-limit keys. When exceeded, drop every key whose
  # entire window has already elapsed (they would reset to "allowed" anyway), so a
  # transient flood cannot pin memory. Cheap: runs only when the table is large.
  @max_keys_default 200_000
  defp maybe_prune(window_ms) do
    max_keys = parse_positive_env("RATE_LIMIT_MAX_KEYS", @max_keys_default)

    if :ets.info(:rate_limiter, :size) > max_keys do
      cutoff = System.system_time(:millisecond) - window_ms

      # match_delete rows whose newest timestamp is older than the window. Guarded
      # so a matchspec/table hiccup can never take down the request path.
      try do
        :ets.foldl(
          fn {key, requests}, acc ->
            newest = requests |> Enum.map(fn {ts, _} -> ts end) |> Enum.max(fn -> 0 end)
            if newest < cutoff, do: [key | acc], else: acc
          end,
          [],
          :rate_limiter
        )
        |> Enum.each(&:ets.delete(:rate_limiter, &1))
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp resolve_limits(limit_type) do
    {default_max_requests, default_window_ms} =
      Map.get(@default_limits, limit_type, {300, 60_000})

    env_prefix = limit_type |> Atom.to_string() |> String.upcase()

    {
      parse_positive_env("RATE_LIMIT_#{env_prefix}_MAX_REQUESTS", default_max_requests),
      parse_positive_env("RATE_LIMIT_#{env_prefix}_WINDOW_MS", default_window_ms)
    }
  end

  defp parse_positive_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      raw ->
        case Integer.parse(raw) do
          {value, _} when value > 0 -> value
          _ -> default
        end
    end
  end

  defp attach_rate_limit_headers(conn, max_requests, remaining, reset_at_ms) do
    conn
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(max_requests))
    |> put_resp_header("x-ratelimit-remaining", Integer.to_string(max(remaining, 0)))
    |> put_resp_header("x-ratelimit-reset", Integer.to_string(div(reset_at_ms, 1000)))
  end

  defp maybe_log_request(conn, limit_type, identifier, bucket, remaining, max_requests, window_ms) do
    if log_requests?(limit_type, remaining, max_requests) do
      Logger.info(
        "[RateLimiter] request " <>
          "type=#{limit_type} method=#{conn.method} bucket=#{bucket} path=#{conn.request_path} " <>
          "identifier_kind=#{identifier.kind} identifier=#{identifier.fingerprint} " <>
          "remaining=#{remaining} limit=#{max_requests}/#{window_ms}ms"
      )
    end
  end

  defp log_requests?(limit_type, remaining, max_requests) do
    case System.get_env("RATE_LIMIT_LOG_REQUESTS") do
      value when value in ["1", "true", "TRUE", "yes", "YES"] ->
        true

      _ ->
        limit_type in [:strict, :public_agent] and remaining <= max(div(max_requests, 10), 3)
    end
  end

  defp request_bucket("/api/agent/chat"), do: "/api/agent/chat"
  defp request_bucket("/api/agent/chat/sync"), do: "/api/agent/chat/sync"

  defp request_bucket(path) do
    cond do
      String.match?(path, ~r{^/api/agents/[^/]+/invoke$}) ->
        "/api/agents/:identifier/invoke"

      String.match?(path, ~r{^/api/agents/[^/]+/events$}) ->
        "/api/agents/:identifier/events"

      true ->
        path
    end
  end

  # SECURITY: `X-Forwarded-For` is fully client-controlled. A client can PREPEND
  # arbitrary entries; the trusted proxy in front of us (Railway/Cloudflare/etc.)
  # then APPENDS the address it actually saw connect. So the real client is the
  # entry `trusted_hops` from the RIGHT — never `List.first`, which is exactly the
  # spoofable value. Taking the leftmost let an attacker mint unlimited distinct
  # identifiers and sail past the auth rate limit (and grow the ETS table without
  # bound). `TRUSTED_PROXY_HOPS` (default 1) says how many proxies we operate.
  defp forwarded_or_remote_ip(conn) do
    hops = trusted_proxy_hops()
    chain = forwarded_chain(conn)

    cond do
      # hops == 0: no trusted proxy in front of us (e.g. direct/local). XFF is
      # entirely client-controlled here, so it is ignored and we key on the real
      # TCP peer, which cannot be forged.
      hops == 0 ->
        remote_ip(conn)

      # A chain shorter than the number of proxies we operate means the expected
      # proxy-appended entries are not present (XFF stripped, or a direct hit that
      # bypassed the proxy). Don't trust it — fall back to the real peer.
      length(chain) < hops ->
        remote_ip(conn)

      # The real client is the entry `hops` from the RIGHT: our proxies each append
      # once, last-appended is closest to us, and a client can only inject entries
      # to the LEFT of what the trusted proxy appended.
      true ->
        Enum.at(chain, length(chain) - hops) || remote_ip(conn)
    end
  end

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  # Every value across (possibly multiple) X-Forwarded-For headers, left→right,
  # trimmed, blanks dropped.
  defp forwarded_chain(conn) do
    conn
    |> get_req_header("x-forwarded-for")
    |> Enum.join(",")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # How many trusted reverse proxies sit in front of the app. Production behind a
  # single edge (Railway) is 1 (the default). Set 0 for a direct/local deployment
  # so `X-Forwarded-For` is ignored entirely. `parse_positive_env` treats 0 as the
  # fallback, so 0 is read explicitly here.
  defp trusted_proxy_hops do
    case System.get_env("TRUSTED_PROXY_HOPS") do
      nil ->
        1

      raw ->
        case Integer.parse(raw) do
          {n, _} when n >= 0 -> n
          _ -> 1
        end
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      [header | _] ->
        case String.split(header, " ", parts: 2) do
          [scheme, token] when scheme in ["Bearer", "bearer"] -> String.trim(token)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_agent_secret(conn) do
    List.first(get_req_header(conn, "x-vibe-agent-secret")) ||
      List.first(get_req_header(conn, "x-vibe-integration-secret"))
  end

  defp identifier(kind, value) do
    %{
      kind: kind,
      value: value,
      fingerprint: fingerprint(value)
    }
  end

  defp fingerprint(value) do
    value
    |> :erlang.iolist_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
