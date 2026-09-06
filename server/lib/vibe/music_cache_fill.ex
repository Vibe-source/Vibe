defmodule Vibe.MusicCacheFill do
  @moduledoc """
  Single-flight and failure backoff for music cache fills.

  A cache fill is a `yt-dlp` download plus a Supabase upload: seconds of work, one
  subprocess, and a fixed `-o` output path per `video_id`. Two things went wrong
  without this:

  * **Duplicate work.** The client calls `/api/music/info/:id` and then
    `/api/music/stream/:id` a few seconds later. Both missed the cache, so both
    spawned `yt-dlp` writing the *same* temp path — racing each other over one file.
  * **No backoff.** Every failure re-ran the full download *and* a second `yt-dlp`
    for the direct-URL fallback before returning 500 — about 4s of subprocess per
    request. When the extractor is failing for an external reason (YouTube's bot
    check, expired cookies) that repeats for every tap, forever.

  Callers wait on the *same* fill instead of starting another, and a failed id
  short-circuits for `@failure_backoff_ms` so a broken source costs one attempt, not
  one per request. Nothing here caches success — that is the database's job, and a
  row written by any fill is visible to every later request.
  """
  use GenServer

  require Logger

  @failure_backoff_ms :timer.minutes(5)
  @default_timeout :timer.minutes(3)

  defstruct inflight: %{}, refs: %{}, failures: %{}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Run `fun` for `video_id`, at most once at a time.

  Returns whatever `fun` returns. Concurrent callers for the same id share the
  running fill's result. A recent failure is replayed immediately without running
  `fun` at all.
  """
  @spec fill(String.t(), (-> term()), timeout()) :: term()
  def fill(video_id, fun, timeout \\ @default_timeout)
      when is_binary(video_id) and is_function(fun, 0) do
    GenServer.call(__MODULE__, {:fill, video_id, fun}, timeout)
  catch
    :exit, {:timeout, _} ->
      {:error, "Cache fill timed out"}

    :exit, {:noproc, _} ->
      # Not started (tests, or a restart in flight) — never block the request path
      # on this being alive; just do the work inline.
      fun.()
  end

  @doc "Forget a recorded failure so the next request retries immediately."
  def clear_failure(video_id) when is_binary(video_id) do
    GenServer.cast(__MODULE__, {:clear_failure, video_id})
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:fill, video_id, fun}, from, state) do
    cond do
      reason = recent_failure(state, video_id) ->
        Logger.info("[MusicCacheFill] short-circuit #{video_id} — recent failure")
        {:reply, {:error, reason}, state}

      Map.has_key?(state.inflight, video_id) ->
        Logger.info("[MusicCacheFill] joining in-flight fill #{video_id}")
        {:noreply, add_waiter(state, video_id, from)}

      true ->
        task = Task.Supervisor.async_nolink(Vibe.TaskSupervisor, fun)

        {:noreply,
         %{
           state
           | inflight: Map.put(state.inflight, video_id, %{ref: task.ref, waiters: [from]}),
             refs: Map.put(state.refs, task.ref, video_id)
         }}
    end
  end

  @impl true
  def handle_cast({:clear_failure, video_id}, state) do
    {:noreply, %{state | failures: Map.delete(state.failures, video_id)}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, finish(state, ref, {:error, "Cache fill crashed: #{inspect(reason)}"})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- internals ------------------------------------------------------------

  defp add_waiter(state, video_id, from) do
    entry = Map.fetch!(state.inflight, video_id)
    put_in(state.inflight[video_id], %{entry | waiters: [from | entry.waiters]})
  end

  defp finish(state, ref, result) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        state

      {video_id, refs} ->
        {entry, inflight} = Map.pop(state.inflight, video_id)
        Enum.each(entry.waiters, &GenServer.reply(&1, result))

        %{
          state
          | inflight: inflight,
            refs: refs,
            failures: record_outcome(state.failures, video_id, result)
        }
    end
  end

  # Only failures are remembered. A success needs no note here — it has written the
  # database row every later request reads first.
  defp record_outcome(failures, video_id, {:error, reason}) do
    Map.put(failures, video_id, {System.monotonic_time(:millisecond), reason})
  end

  defp record_outcome(failures, video_id, _ok), do: Map.delete(failures, video_id)

  defp recent_failure(state, video_id) do
    case Map.get(state.failures, video_id) do
      {at, reason} ->
        if System.monotonic_time(:millisecond) - at < @failure_backoff_ms, do: reason

      _ ->
        nil
    end
  end
end
