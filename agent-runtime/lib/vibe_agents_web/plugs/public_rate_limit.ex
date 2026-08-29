defmodule VibeAgentsWeb.Plugs.PublicRateLimit do
  @moduledoc "ETS sliding window for /v1/* provider ingress: 600/min per secret hash or IP."
  import Plug.Conn
  require Logger

  @behaviour Plug
  @table :vibe_agents_public_rate_limit
  @window_ms 60_000
  @max_requests 600

  def init(opts), do: opts

  def call(conn, _opts) do
    ensure_table()
    key = identifier(conn)

    case check(key) do
      :ok ->
        conn

      :limited ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("retry-after", "60")
        |> send_resp(429, Jason.encode!(%{"error" => "rate_limited"}))
        |> halt()
    end
  end

  defp identifier(conn) do
    case secret(conn) do
      nil -> "ip:" <> remote_ip(conn)
      secret -> "secret:" <> hash(secret)
    end
  end

  defp secret(conn) do
    header = fn name -> conn |> get_req_header(name) |> List.first() end

    case header.("x-vibe-agent-secret") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        case header.("authorization") do
          "Bearer " <> token -> token
          _ -> nil
        end
    end
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp remote_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp check(key) do
    now = System.system_time(:millisecond)
    window_start = now - @window_ms

    case :ets.lookup(@table, key) do
      [] ->
        :ets.insert(@table, {key, [now]})
        :ok

      [{^key, timestamps}] ->
        recent = Enum.filter(timestamps, &(&1 > window_start))

        if length(recent) >= @max_requests do
          :limited
        else
          :ets.insert(@table, {key, [now | recent]})
          :ok
        end
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
