defmodule Vibe.Accounts.TokenCache do
  @moduledoc """
  Short-TTL cache for `bearer token -> %User{}` resolution.

  Every authenticated REST call runs through `VibeWeb.Plugs.ApiAuth`, which
  resolved the bearer token with a `Repo.get_by(User, login_token: ...)` on
  *every single request*. The app server and Postgres are ~350ms apart, so that
  lookup alone was the floor under every endpoint: a trivial call like
  `GET /api/agent-bridge/status` measured a flat ~690ms in production — one
  round trip to authenticate, one to do the actual work. Endpoints that issue
  more queries came out as near-exact multiples of that same ~350ms unit.

  Authentication is the one query that repeats identically on every request of a
  session, so it is the one worth caching. A hit serves the user struct from ETS
  and the request never touches the database to authenticate.

  Correctness rules:

    * TTL is deliberately short (`@ttl_ms`), so any state we fail to invalidate
      explicitly still self-heals within a minute.
    * `Vibe.Accounts.update_user/2` and `delete_user/1` invalidate the user's
      entries, so a profile write is visible to the next request rather than up
      to a TTL later.
    * Token rotation (logout / re-issue) invalidates by user id, which drops the
      old token's entry as well — a rotated-away token cannot outlive its
      rotation.
    * Only successful lookups are cached. Unknown tokens always hit the DB, so a
      flood of junk tokens cannot fill this table.

  The table is created by `Vibe.Application.start/2` (public, owned by the
  application master) alongside the other process-independent ETS caches.
  """

  alias Vibe.Accounts.User

  @table :auth_token_cache
  @ttl_ms 60_000
  # Above this many entries a `put` sweeps expired rows first. Bounds the table
  # for a large fleet of live sessions without needing a timer process.
  @sweep_threshold 5_000

  @doc "Cache TTL in milliseconds."
  def ttl_ms, do: @ttl_ms

  @doc """
  Look up a cached user for `token`.

  Returns `{:ok, user}` only for an entry that is present and unexpired;
  `:miss` otherwise (including when the table does not exist yet).
  """
  @spec fetch(String.t()) :: {:ok, struct()} | :miss
  def fetch(token) when is_binary(token) and token != "" do
    case :ets.whereis(@table) do
      :undefined ->
        emit(:miss)
        :miss

      _ ->
        case :ets.lookup(@table, token) do
          [{^token, _user_id, user, expires_at}] ->
            if now_ms() < expires_at do
              emit(:hit)
              {:ok, user}
            else
              :ets.delete(@table, token)
              emit(:expired)
              :miss
            end

          _ ->
            emit(:miss)
            :miss
        end
    end
  end

  def fetch(_token), do: :miss

  # Hit ratio is the signal that says whether a shared cache is worth adding.
  defp emit(result) do
    :telemetry.execute([:vibe, :cache, :token], %{count: 1}, %{result: result})
  end

  @doc "Cache a resolved user for `token` for one TTL window."
  @spec put(String.t(), struct()) :: :ok
  def put(token, %User{id: user_id} = user) when is_binary(token) and token != "" do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        maybe_sweep()
        :ets.insert(@table, {token, user_id, user, now_ms() + @ttl_ms})
        :ok
    end
  end

  def put(_token, _user), do: :ok

  @doc "Drop a single token's entry."
  @spec invalidate(String.t()) :: :ok
  def invalidate(token) when is_binary(token) and token != "" do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete(@table, token)
    end

    :ok
  end

  def invalidate(_token), do: :ok

  @doc """
  Drop every cached entry for a user.

  Used after any write to the user row, and after token rotation — the rotated
  token is keyed by its own value, so only a user-id sweep can evict it.
  """
  @spec invalidate_user(String.t() | nil) :: :ok
  def invalidate_user(user_id) when is_binary(user_id) and user_id != "" do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.match_delete(@table, {:_, user_id, :_, :_})
    end

    :ok
  end

  def invalidate_user(_user_id), do: :ok

  defp maybe_sweep do
    if :ets.info(@table, :size) > @sweep_threshold do
      :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", now_ms()}], [true]}])
    end

    :ok
  end

  defp now_ms, do: System.system_time(:millisecond)
end
