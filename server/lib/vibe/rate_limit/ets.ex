defmodule Vibe.RateLimit.ETS do
  @moduledoc """
  Today's node-local ETS rate limiter (sliding window), moved verbatim behind
  `Vibe.RateLimit.Backend` so `VibeWeb.Plugs.RateLimiter` can swap backends.
  """
  @behaviour Vibe.RateLimit.Backend

  @table :rate_limiter

  @impl true
  def hit(key, max_requests, window_ms) do
    ensure_table_exists()
    now = System.system_time(:millisecond)
    window_start = now - window_ms

    case :ets.lookup(@table, key) do
      [] ->
        # First request - allow and record. Guard the table against unbounded
        # growth (a burst of never-before-seen identifiers) by pruning expired
        # keys once it crosses a soft cap.
        maybe_prune(window_ms)
        :ets.insert(@table, {key, [{now, 1}]})
        {:ok, max_requests - 1, now + window_ms}

      [{^key, requests}] ->
        recent_requests = Enum.filter(requests, fn {timestamp, _} -> timestamp > window_start end)
        total_count = Enum.reduce(recent_requests, 0, fn {_, count}, acc -> acc + count end)

        if total_count >= max_requests do
          oldest_in_window =
            recent_requests |> Enum.map(fn {ts, _} -> ts end) |> Enum.min(fn -> now end)

          retry_after = oldest_in_window + window_ms - now
          {:error, max(retry_after, 1000), oldest_in_window + window_ms}
        else
          new_requests = [{now, 1} | recent_requests] |> Enum.take(max_requests * 2)
          :ets.insert(@table, {key, new_requests})

          reset_at_ms =
            new_requests
            |> Enum.map(fn {timestamp, _} -> timestamp end)
            |> Enum.min(fn -> now end)
            |> Kernel.+(window_ms)

          {:ok, max_requests - total_count - 1, reset_at_ms}
        end
    end
  end

  defp ensure_table_exists do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, {:read_concurrency, true}])

      _ ->
        :ok
    end
  end

  # Soft ceiling on distinct rate-limit keys. When exceeded, drop every key whose
  # entire window has already elapsed (they would reset to "allowed" anyway), so a
  # transient flood cannot pin memory.
  @max_keys_default 200_000
  defp maybe_prune(window_ms) do
    max_keys = parse_positive_env("RATE_LIMIT_MAX_KEYS", @max_keys_default)

    if :ets.info(@table, :size) > max_keys do
      cutoff = System.system_time(:millisecond) - window_ms

      try do
        :ets.foldl(
          fn {key, requests}, acc ->
            newest = requests |> Enum.map(fn {ts, _} -> ts end) |> Enum.max(fn -> 0 end)
            if newest < cutoff, do: [key | acc], else: acc
          end,
          [],
          @table
        )
        |> Enum.each(&:ets.delete(@table, &1))
      rescue
        _ -> :ok
      end
    end

    :ok
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
end
