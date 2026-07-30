defmodule Vibe.RelayRegistry do
  @moduledoc """
  In-memory registry for VibeNet relay nodes.

  Uses ETS for fast concurrent reads/writes.
  Relays are ephemeral — they only exist while the relay node is connected.

  Ownership is bound to `relay.user_id`. Only the registering user may
  re-register, update, or unregister that relay id.
  """

  use GenServer

  @table :relay_registry

  # ─── Public API ──────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Fetch a relay by id. Returns `{:ok, relay}` or `:not_found`."
  def get_relay(relay_id) when is_binary(relay_id) do
    case :ets.lookup(@table, relay_id) do
      [{^relay_id, relay}] -> {:ok, relay}
      [] -> :not_found
    end
  end

  def get_relay(_), do: :not_found

  @doc """
  Register a new relay node, or re-register when the caller owns the id.

  Returns:
  - `:ok` on insert or owner re-register
  - `{:error, :forbidden}` when the id is already owned by another user
  - `{:error, :invalid_relay}` when required fields are missing
  """
  def register_relay(relay) when is_map(relay) do
    relay_id = relay_id(relay)
    user_id = relay_user_id(relay)

    cond do
      not is_binary(relay_id) or relay_id == "" ->
        {:error, :invalid_relay}

      is_nil(user_id) ->
        {:error, :invalid_relay}

      true ->
        normalized = normalize_relay(relay)

        if :ets.insert_new(@table, {relay_id, normalized}) do
          :ok
        else
          merge_owned_reregister(relay_id, user_id, normalized, relay)
        end
    end
  end

  def register_relay(_), do: {:error, :invalid_relay}

  @doc """
  Update a relay's metadata.

  When `as_user:` is provided, the caller must own the relay.
  Returns `:ok`, `:not_found`, or `{:error, :forbidden}`.
  """
  def update_relay(relay_id, updates, opts \\ []) when is_map(updates) do
    as_user = Keyword.get(opts, :as_user)

    case :ets.lookup(@table, relay_id) do
      [{^relay_id, existing}] ->
        if is_nil(as_user) or relay_user_id(existing) == as_user do
          # Never allow callers to reassign ownership via updates.
          safe_updates = Map.drop(updates, [:user_id, "user_id"])
          updated = Map.merge(existing, safe_updates)
          :ets.insert(@table, {relay_id, updated})
          :ok
        else
          {:error, :forbidden}
        end

      [] ->
        :not_found
    end
  end

  @doc """
  Remove a relay from the registry.

  When `as_user:` is provided, only the owner may delete.
  Returns `:ok`, `:not_found`, or `{:error, :forbidden}`.
  """
  def unregister_relay(relay_id, opts \\ []) do
    as_user = Keyword.get(opts, :as_user)

    case :ets.lookup(@table, relay_id) do
      [{^relay_id, existing}] ->
        if is_nil(as_user) or relay_user_id(existing) == as_user do
          :ets.delete(@table, relay_id)
          :ok
        else
          {:error, :forbidden}
        end

      [] ->
        :not_found
    end
  end

  @doc "True when the given user owns the relay id."
  def owned_by?(relay_id, user_id) when is_binary(relay_id) do
    case get_relay(relay_id) do
      {:ok, relay} -> relay_user_id(relay) == user_id
      :not_found -> false
    end
  end

  def owned_by?(_, _), do: false

  @doc "Find a relay by invite code"
  def find_by_invite_code(code) when is_binary(code) and code != "" do
    result =
      :ets.foldl(
        fn {_id, relay}, acc ->
          if relay_invite_code(relay) == code do
            [relay | acc]
          else
            acc
          end
        end,
        [],
        @table
      )

    case result do
      [relay | _] ->
        {:ok, relay_to_map(relay)}

      [] ->
        :not_found
    end
  end

  def find_by_invite_code(_), do: :not_found

  @doc "List all public relays"
  def list_public_relays do
    :ets.foldl(
      fn {_id, relay}, acc ->
        if relay_public?(relay) do
          [relay_to_map(relay) |> Map.put(:uptime, calculate_uptime(relay[:started_at])) | acc]
        else
          acc
        end
      end,
      [],
      @table
    )
  end

  @doc "Get relay count"
  def count do
    :ets.info(@table, :size)
  end

  @doc false
  def relay_user_id(relay) when is_map(relay) do
    Map.get(relay, :user_id) || Map.get(relay, "user_id")
  end

  def relay_user_id(_), do: nil

  @doc false
  def relay_public?(relay) when is_map(relay) do
    Map.get(relay, :is_public) == true or Map.get(relay, "is_public") == true
  end

  def relay_public?(_), do: false

  @doc false
  def relay_invite_code(relay) when is_map(relay) do
    Map.get(relay, :invite_code) || Map.get(relay, "invite_code")
  end

  def relay_invite_code(_), do: nil

  @doc false
  def relay_invite_key(relay) when is_map(relay) do
    Map.get(relay, :invite_key) || Map.get(relay, "invite_key")
  end

  def relay_invite_key(_), do: nil

  # ─── GenServer Callbacks ─────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  # ─── Helpers ─────────────────────────────────────────────────

  defp relay_id(relay) when is_map(relay) do
    Map.get(relay, :relay_id) || Map.get(relay, "relay_id")
  end

  defp normalize_relay(relay) when is_map(relay) do
    # Prefer atom keys for internal storage consistency.
    %{
      relay_id: relay_id(relay),
      user_id: relay_user_id(relay),
      invite_code: relay_invite_code(relay),
      invite_key: relay_invite_key(relay),
      is_public: Map.get(relay, :is_public, Map.get(relay, "is_public", false)) == true,
      name: Map.get(relay, :name) || Map.get(relay, "name") || "Relay",
      max_peers: Map.get(relay, :max_peers) || Map.get(relay, "max_peers") || 5,
      current_peers: Map.get(relay, :current_peers) || Map.get(relay, "current_peers") || 0,
      region: Map.get(relay, :region) || Map.get(relay, "region") || "unknown",
      started_at: Map.get(relay, :started_at) || Map.get(relay, "started_at"),
      last_heartbeat_at:
        Map.get(relay, :last_heartbeat_at) || Map.get(relay, "last_heartbeat_at"),
      capabilities: Map.get(relay, :capabilities) || Map.get(relay, "capabilities") || [],
      external_ip: Map.get(relay, :external_ip) || Map.get(relay, "external_ip"),
      bridge_url: Map.get(relay, :bridge_url) || Map.get(relay, "bridge_url"),
      share_link: Map.get(relay, :share_link) || Map.get(relay, "share_link"),
      bridge_descriptor: Map.get(relay, :bridge_descriptor) || Map.get(relay, "bridge_descriptor")
    }
  end

  defp compact_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp merge_owned_reregister(relay_id, user_id, normalized, original_relay) do
    case :ets.lookup(@table, relay_id) do
      [] ->
        # The relay disappeared between insert_new/lookup; retry once so a
        # concurrent owner disconnect cannot create a false forbidden result.
        register_relay(original_relay)

      [{^relay_id, existing}] ->
        if relay_user_id(existing) == user_id do
          # Owner re-register: merge non-nil fields so omitted keys (e.g. bridge
          # descriptor from a channel rejoin) do not wipe controller-set data.
          incoming = compact_nil_values(normalized)

          merged =
            existing
            |> Map.merge(incoming)
            |> Map.put(:relay_id, relay_id)
            |> Map.put(:user_id, user_id)

          :ets.insert(@table, {relay_id, merged})
          :ok
        else
          {:error, :forbidden}
        end
    end
  end

  defp calculate_uptime(nil), do: 0

  defp calculate_uptime(started_at) do
    elapsed = System.system_time(:second) - started_at
    # rough percentage based on 1 hour = 100%
    min(100, div(elapsed, 36))
  end

  defp relay_to_map(relay) do
    %{
      relay_id: relay_id(relay),
      name: Map.get(relay, :name) || Map.get(relay, "name") || "Relay",
      invite_code: relay_invite_code(relay),
      is_public: relay_public?(relay),
      region: Map.get(relay, :region) || Map.get(relay, "region") || "unknown",
      current_peers: Map.get(relay, :current_peers) || Map.get(relay, "current_peers") || 0,
      max_peers: Map.get(relay, :max_peers) || Map.get(relay, "max_peers") || 5,
      capabilities: Map.get(relay, :capabilities) || Map.get(relay, "capabilities") || [],
      last_heartbeat_at:
        Map.get(relay, :last_heartbeat_at) || Map.get(relay, "last_heartbeat_at"),
      tags: [],
      external_ip: Map.get(relay, :external_ip) || Map.get(relay, "external_ip"),
      bridge_url: Map.get(relay, :bridge_url) || Map.get(relay, "bridge_url"),
      share_link: Map.get(relay, :share_link) || Map.get(relay, "share_link"),
      bridge_descriptor: Map.get(relay, :bridge_descriptor) || Map.get(relay, "bridge_descriptor")
    }
  end
end
