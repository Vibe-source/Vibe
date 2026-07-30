defmodule VibeWeb.Plugs.RateLimiterTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias VibeWeb.Plugs.RateLimiter

  setup do
    _ = RateLimiter.init([])
    :ets.delete_all_objects(:rate_limiter)

    original_hops = System.get_env("TRUSTED_PROXY_HOPS")
    System.delete_env("TRUSTED_PROXY_HOPS")

    on_exit(fn ->
      :ets.delete_all_objects(:rate_limiter)

      if original_hops do
        System.put_env("TRUSTED_PROXY_HOPS", original_hops)
      else
        System.delete_env("TRUSTED_PROXY_HOPS")
      end
    end)
  end

  test "uses trusted right-side X-Forwarded-For entry so spoofed prefixes do not bypass auth limit" do
    allowed =
      for i <- 1..10 do
        conn =
          :post
          |> conn("/api/login", "")
          |> Map.put(:remote_ip, {10, 0, 0, 5})
          |> put_req_header("x-forwarded-for", "198.51.100.#{i}, 203.0.113.9")
          |> RateLimiter.call(type: :auth)

        refute conn.halted
        get_resp_header(conn, "x-ratelimit-remaining") |> List.first()
      end

    assert List.last(allowed) == "0"

    blocked =
      :post
      |> conn("/api/login", "")
      |> Map.put(:remote_ip, {10, 0, 0, 5})
      |> put_req_header("x-forwarded-for", "198.51.100.250, 203.0.113.9")
      |> RateLimiter.call(type: :auth)

    assert blocked.halted
    assert blocked.status == 429
  end
end
