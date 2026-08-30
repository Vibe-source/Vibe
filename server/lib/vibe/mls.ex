defmodule Vibe.Mls do
  @moduledoc """
  MLS KeyPackage publish/claim.

  MLS adds a member to a group by consuming that member's **KeyPackage**, which
  wraps a one-time init key. Reusing a KeyPackage across two group additions
  reuses that init key and breaks the forward-secrecy guarantee MLS exists to
  provide, so a KeyPackage is single-use: once `claim_key_package/2` hands one
  out it is immediately unclaimable.

  `claim_key_package/2` does this with a single atomic
  `UPDATE ... WHERE id IN (SELECT ... FOR UPDATE SKIP LOCKED LIMIT 1)`
  statement — never a read followed by a separate write. See its doc for why
  that matters.

  See `docs/secure-core-architecture.md` §3-4.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Vibe.Accounts
  alias Vibe.Chat
  alias Vibe.Chat.Participant
  alias Vibe.Repo
  alias Vibe.Schemas.MlsKeyPackage
  alias Vibe.Schemas.MlsWelcome

  # Publishing is a low-frequency, client-initiated batch (a device tops up its
  # KeyPackage pool). Cap it well above any realistic single call so a bad or
  # malicious client can't force one huge insert; reject rather than truncate
  # so the caller finds out its batch was short, instead of silently trusting
  # a partial publish.
  @max_batch 100

  # ── Publish ──────────────────────────────────────────────────────────────

  @doc """
  Publish a batch of KeyPackages on behalf of `user_id`.

  `user_id` must be the *authenticated* caller's id — this function has no
  notion of "publish for someone else", by design. Callers must never source
  it from request-body fields (a controller should always pass
  `conn.assigns.current_user.id`, never a client-supplied `userId`).

  `params` is the raw (string-keyed) request body; only `"deviceId"` and
  `"keyPackages"` are read from it. Any `"userId"`/`"user_id"` present in
  `params` is ignored — ownership is always the explicit `user_id` argument.

  `keyPackages` entries are base64-encoded opaque blobs (the client's
  serialized MLS KeyPackage). Returns `{:ok, %{count: n}}` or `{:error, reason}`
  with `reason` one of `:invalid_device_id`, `:invalid_key_packages`,
  `:batch_too_large`, `:invalid_key_package_encoding`.

  ## `retireDeviceKeys`

  When truthy, everything already on file for this device is deleted in the
  **same transaction** as the insert. A device sends this when its MLS signing
  key changed, and it is not housekeeping — without it the fix for that does not
  hold:

    * Unclaimed KeyPackages carry the retired signing key. `claim_key_package/1`
      hands out the *oldest* first, so a peer would reliably claim a dead one,
      build a group around a leaf the device can no longer sign as, and land
      right back in "both sides sealed fine, neither can read the other".
    * Undelivered Welcomes are the same trap from the other side: they target a
      dead KeyPackage whose private half is still in the device's store, so the
      join *succeeds* and produces a session that is broken from birth.

  One transaction rather than a separate endpoint the client calls first, so
  there is no window in which a peer can claim a stale KeyPackage that has
  already been "logically" retired, and none in which the device has no
  KeyPackages at all.

  Welcomes are cleared per **user**, not per device: `mls_welcomes` records only
  a recipient user. With one device per account today that is exact; a real
  multi-device account would need the recipient device recorded on the row
  before this can be narrowed.
  """
  def publish_key_packages(user_id, params) when is_binary(user_id) and is_map(params) do
    device_id = params["deviceId"] || params["device_id"]
    key_packages = params["keyPackages"] || params["key_packages"]
    retire? = params["retireDeviceKeys"] == true or params["retire_device_keys"] == true

    with {:ok, device_id} <- validate_device_id(device_id),
         {:ok, decoded} <- validate_key_packages(key_packages) do
      insert_batch(user_id, device_id, decoded, retire?)
    end
  end

  def publish_key_packages(_user_id, _params), do: {:error, :invalid_device_id}

  # ── Claim ────────────────────────────────────────────────────────────────

  @doc """
  Atomically claim one available KeyPackage published by `user_id`, marking it
  claimed in the same statement that hands it out.

  Race safety: this is a single `UPDATE ... WHERE id IN (subquery)` statement,
  where the subquery selects the oldest unclaimed row `FOR UPDATE SKIP LOCKED`.
  Postgres executes the subquery's row lock and the outer UPDATE as one
  statement, so there is no window between "pick a row" and "mark it claimed"
  for a second caller to land in — unlike a read-then-write done as two
  separate queries, which can both read the same unclaimed row before either
  writes back. `SKIP LOCKED` means a concurrent claim doesn't queue behind
  this one waiting on the same row either: it just moves on to the next
  unclaimed row, so N concurrent claims against N available rows all proceed
  independently instead of serializing.

  Returns `{:error, :not_found}` when nothing is left to claim. That is a
  normal, expected state — the caller has run out of published KeyPackages for
  this user, not an error.
  """
  def claim_key_package(target_id) when is_binary(target_id) do
    claim_key_package(target_id, target_id)
  end

  def claim_key_package(_target_id), do: {:error, :not_found}

  def claim_key_package(claimer_id, target_id)
      when is_binary(claimer_id) and is_binary(target_id) do
    with :ok <- authorize_claim(claimer_id, target_id),
         :ok <- check_claim_quota(claimer_id, target_id) do
      do_claim_key_package(target_id)
    end
  end

  def claim_key_package(_claimer_id, _target_id), do: {:error, :not_found}

  defp do_claim_key_package(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    candidate =
      from(kp in MlsKeyPackage,
        where: kp.user_id == ^user_id and is_nil(kp.claimed_at),
        order_by: [asc: kp.inserted_at, asc: kp.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED",
        select: kp.id
      )

    # `update_all` only returns rows back when the query itself carries a
    # `select` — an opts-level `returning:` (unlike insert/insert_all) is not
    # a thing it honors. `select: kp` is what turns this into
    # `UPDATE ... WHERE id IN (...) RETURNING *`.
    claimable_row =
      from(kp in MlsKeyPackage, where: kp.id in subquery(candidate), select: kp)

    case Repo.update_all(claimable_row, set: [claimed_at: now, updated_at: now]) do
      {1, [package]} ->
        {:ok, package}

      {0, _} ->
        {:error, :not_found}
    end
  end

  # ── Count ────────────────────────────────────────────────────────────────

  @doc """
  Count how many unclaimed KeyPackages remain for `user_id`.
  """
  def count_available(user_id) when is_binary(user_id) do
    Repo.aggregate(
      from(kp in MlsKeyPackage, where: kp.user_id == ^user_id and is_nil(kp.claimed_at)),
      :count,
      :id
    )
  end

  def count_available(_user_id), do: 0

  # ── Internals ────────────────────────────────────────────────────────────

  defp validate_device_id(device_id) when is_binary(device_id) do
    case String.trim(device_id) do
      "" -> {:error, :invalid_device_id}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_device_id(_), do: {:error, :invalid_device_id}

  defp validate_key_packages(list) when is_list(list) do
    cond do
      list == [] ->
        {:error, :invalid_key_packages}

      length(list) > @max_batch ->
        Logger.warning(
          "[Mls] rejected oversize publish batch size=#{length(list)} max=#{@max_batch}"
        )

        {:error, :batch_too_large}

      not Enum.all?(list, &is_binary/1) ->
        {:error, :invalid_key_packages}

      true ->
        decode_all(list)
    end
  end

  defp validate_key_packages(_), do: {:error, :invalid_key_packages}

  defp decode_all(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn encoded, {:ok, acc} ->
      case decode_key_package(encoded) do
        {:ok, binary} -> {:cont, {:ok, [binary | acc]}}
        :error -> {:halt, {:error, :invalid_key_package_encoding}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_key_package(encoded) do
    trimmed = String.trim(encoded)

    case Base.decode64(trimmed) do
      {:ok, binary} when byte_size(binary) > 0 -> {:ok, binary}
      {:ok, _empty} -> :error
      :error -> decode_key_package_unpadded(trimmed)
    end
  end

  defp decode_key_package_unpadded(trimmed) do
    case Base.decode64(trimmed, padding: false) do
      {:ok, binary} when byte_size(binary) > 0 -> {:ok, binary}
      _ -> :error
    end
  end

  defp insert_batch(user_id, device_id, decoded_key_packages, retire?) do
    Repo.transaction(fn ->
      if retire?, do: retire_device_artifacts(user_id, device_id)

      Enum.map(decoded_key_packages, fn key_package ->
        %MlsKeyPackage{}
        |> MlsKeyPackage.changeset(%{
          user_id: user_id,
          device_id: device_id,
          key_package: key_package
        })
        |> Repo.insert!()
      end)
    end)
    |> case do
      # `retired` is reported back because the client cannot otherwise tell this
      # server from one that predates the flag and silently ignored it. A device
      # that assumed success against an old server would clear its pending
      # retirement while every stale KeyPackage stayed claimable — reproducing
      # the exact failure the flag exists to end.
      {:ok, inserted} ->
        {:ok, %{count: length(inserted), retired: retire?}}

      {:error, reason} ->
        Logger.warning("[Mls] publish batch failed: #{inspect(reason)}")
        {:error, :publish_failed}
    end
  end

  # Deletes what a retired signing key leaves behind. Runs inside the publish
  # transaction — see `publish_key_packages/2`'s doc for why it cannot be its
  # own call.
  #
  # Claimed KeyPackages are left alone. They are already spent (a claim is
  # single-use and irreversible), so deleting them would only destroy the record
  # that they were, and the groups they produced are the caller's to abandon
  # locally.
  defp retire_device_artifacts(user_id, device_id) do
    {retired_packages, _} =
      from(kp in MlsKeyPackage,
        where: kp.user_id == ^user_id and kp.device_id == ^device_id and is_nil(kp.claimed_at)
      )
      |> Repo.delete_all()

    {dropped_welcomes, _} =
      from(w in MlsWelcome,
        where: w.recipient_user_id == ^user_id and is_nil(w.delivered_at)
      )
      |> Repo.delete_all()

    Logger.info(
      "[Mls] retired signing key for device #{String.slice(device_id, 0, 12)}: " <>
        "#{retired_packages} unclaimed KeyPackage(s), #{dropped_welcomes} pending Welcome(s)"
    )
  end

  # ── Welcome relay ────────────────────────────────────────────────────────

  # A Welcome for a two-member group is a few hundred bytes; the ratchet tree
  # grows with membership. These caps sit far above anything a real group
  # produces while still bounding what one request can write, so a hostile
  # client cannot turn this table into free storage. Reject rather than
  # truncate: a truncated Welcome is undecryptable, and failing loudly at
  # publish is much easier to diagnose than a peer who can never join.
  @max_welcome_bytes 256 * 1024
  @max_ratchet_tree_bytes 4 * 1024 * 1024

  # How many undelivered Welcomes one sender may have outstanding to one
  # recipient. Establishment is first-contact-only, so more than a handful
  # means retries piling up or a client misbehaving; either way the answer is
  # to stop accepting rather than accumulate.
  @max_pending_per_sender 20

  @doc """
  Store a Welcome addressed to `recipient_user_id`, sent by `sender_user_id`.

  `sender_user_id` must be the *authenticated* caller's id. As with
  `publish_key_packages/2`, this function has no notion of "send on behalf of"
  — a controller passes `conn.assigns.current_user.id` and never a body field.

  The `welcome`/`ratchetTree` values are base64 of opaque MLS bytes. Nothing
  here parses them; only their size is checked.
  """
  def post_welcome(sender_user_id, params) when is_binary(sender_user_id) and is_map(params) do
    recipient_id = params["recipientUserId"] || params["recipient_user_id"]
    chat_id = params["chatId"] || params["chat_id"]

    with {:ok, recipient_id} <- validate_id(recipient_id),
         {:ok, chat_id} <- validate_id(chat_id),
         :ok <- authorize_welcome(sender_user_id, recipient_id, chat_id),
         {:ok, welcome} <- decode_blob(params["welcome"], @max_welcome_bytes),
         {:ok, tree} <- decode_optional_blob(params["ratchetTree"], @max_ratchet_tree_bytes),
         :ok <- check_pending_quota(recipient_id, sender_user_id) do
      %MlsWelcome{}
      |> MlsWelcome.changeset(%{
        recipient_user_id: recipient_id,
        sender_user_id: sender_user_id,
        chat_id: chat_id,
        welcome: welcome,
        ratchet_tree: tree
      })
      |> Repo.insert()
      |> case do
        {:ok, row} ->
          # Without this the recipient has no reason to drain: a first-contact DM
          # gives them neither socket_open nor chat_joined for the new chat.
          VibeWeb.Endpoint.broadcast("user:#{recipient_id}", "mls_welcome", %{chatId: chat_id})
          {:ok, row}

        {:error, reason} ->
          Logger.warning("[Mls] welcome insert failed: #{inspect(reason)}")
          {:error, :post_failed}
      end
    end
  end

  def post_welcome(_sender_user_id, _params), do: {:error, :invalid_request}

  @doc """
  Every Welcome still waiting for `user_id`.

  Scoped to `user_id` with no widening parameter, deliberately: a Welcome
  carries the group secrets for its recipient, so serving one to the wrong user
  hands them the conversation.
  """
  def pending_welcomes(user_id) when is_binary(user_id) do
    MlsWelcome
    |> where([w], w.recipient_user_id == ^user_id and is_nil(w.delivered_at))
    |> order_by([w], asc: w.inserted_at)
    |> Repo.all()
  end

  @doc """
  Mark one Welcome delivered.

  Scoped by recipient as well as id, so one user cannot ack — and thereby hide
  — another user's pending Welcome. A row that does not belong to `user_id` is
  reported as `:not_found` rather than `:forbidden`, so the caller learns
  nothing about whether the id exists.
  """
  def ack_welcome(user_id, id) when is_binary(user_id) and is_binary(id) do
    query =
      from(w in MlsWelcome,
        where: w.id == ^id and w.recipient_user_id == ^user_id and is_nil(w.delivered_at)
      )

    case Repo.update_all(query, set: [delivered_at: DateTime.utc_now() |> DateTime.truncate(:second)]) do
      {1, _} -> :ok
      _ -> {:error, :not_found}
    end
  rescue
    # A malformed uuid makes Postgres raise rather than return no rows. That is
    # an ordinary "no such row" from the caller's point of view.
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  Welcome counts for `user_id` on `chat_id`: sent (`pending`/`delivered`) and received (`incoming_*`).
  """
  def welcome_status(user_id, chat_id) when is_binary(user_id) and is_binary(chat_id) do
    sent = welcome_counts(sender_user_id: user_id, chat_id: chat_id)
    incoming = welcome_counts(recipient_user_id: user_id, chat_id: chat_id)

    %{
      pending: sent.pending,
      delivered: sent.delivered,
      incoming_pending: incoming.pending,
      incoming_delivered: incoming.delivered
    }
  end

  def welcome_status(_user_id, _chat_id),
    do: %{pending: 0, delivered: 0, incoming_pending: 0, incoming_delivered: 0}

  defp welcome_counts(sender_user_id: sender_id, chat_id: chat_id) do
    MlsWelcome
    |> where([w], w.sender_user_id == ^sender_id and w.chat_id == ^chat_id)
    |> reduce_welcome_counts()
  end

  defp welcome_counts(recipient_user_id: recipient_id, chat_id: chat_id) do
    MlsWelcome
    |> where([w], w.recipient_user_id == ^recipient_id and w.chat_id == ^chat_id)
    |> reduce_welcome_counts()
  end

  defp reduce_welcome_counts(query) do
    rows =
      query
      |> select([w], {is_nil(w.delivered_at), count(w.id)})
      |> group_by([w], is_nil(w.delivered_at))
      |> Repo.all()

    Enum.reduce(rows, %{pending: 0, delivered: 0}, fn
      {true, count}, acc -> %{acc | pending: count}
      {false, count}, acc -> %{acc | delivered: count}
    end)
  end

  # Claims are irreversible. Without this, any account can drain a target's pool
  # and deny every legitimate peer an E2EE session with them.
  @max_claims_per_peer 8
  @claim_window_ms 3_600_000
  @claim_quota_table :mls_claim_quota

  defp authorize_claim(claimer_id, target_id) when claimer_id == target_id, do: :ok

  defp authorize_claim(claimer_id, target_id) do
    cond do
      Accounts.blocked?(claimer_id, target_id) or Accounts.blocked?(target_id, claimer_id) ->
        {:error, :not_allowed}

      share_chat?(claimer_id, target_id) ->
        :ok

      true ->
        Logger.warning("[Mls] refused key-package claim with no shared chat")
        {:error, :not_allowed}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_allowed}
  end

  defp share_chat?(user_a, user_b) do
    Repo.exists?(
      from(p1 in Participant,
        join: p2 in Participant,
        on: p1.chat_id == p2.chat_id,
        where:
          p1.user_id == ^user_a and p2.user_id == ^user_b and
            (is_nil(p1.deleted) or p1.deleted == false) and
            (is_nil(p2.deleted) or p2.deleted == false)
      )
    )
  end

  defp check_claim_quota(claimer_id, target_id) when claimer_id == target_id, do: :ok

  defp check_claim_quota(claimer_id, target_id) do
    ensure_claim_quota_table()
    now = System.monotonic_time(:millisecond)
    key = {claimer_id, target_id}
    window_start = now - @claim_window_ms

    case :ets.lookup(@claim_quota_table, key) do
      [{^key, stamps}] ->
        recent = Enum.filter(stamps, &(&1 > window_start))

        if length(recent) >= @max_claims_per_peer do
          {:error, :too_many}
        else
          :ets.insert(@claim_quota_table, {key, [now | recent]})
          :ok
        end

      [] ->
        :ets.insert(@claim_quota_table, {key, [now]})
        :ok
    end
  end

  defp ensure_claim_quota_table do
    case :ets.whereis(@claim_quota_table) do
      :undefined ->
        :ets.new(@claim_quota_table, [:set, :public, :named_table, :compressed])

      _tid ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # A Welcome makes the recipient a member of a group the sender built. Without
  # this, any account could seat a victim in an attacker-controlled group.
  defp authorize_welcome(sender_id, recipient_id, chat_id) do
    if Chat.is_participant?(chat_id, sender_id) and Chat.is_participant?(chat_id, recipient_id) do
      :ok
    else
      Logger.warning("[Mls] refused welcome outside chat membership chat=#{String.slice(chat_id, 0, 12)}")
      {:error, :not_allowed}
    end
  rescue
    # chat_id is a free-form string here but a binary_id column there; a
    # non-uuid raises rather than returning no rows.
    Ecto.Query.CastError -> {:error, :not_allowed}
  end

  defp check_pending_quota(recipient_id, sender_id) do
    count =
      MlsWelcome
      |> where(
        [w],
        w.recipient_user_id == ^recipient_id and w.sender_user_id == ^sender_id and
          is_nil(w.delivered_at)
      )
      |> Repo.aggregate(:count, :id)

    if count >= @max_pending_per_sender, do: {:error, :too_many_pending}, else: :ok
  end

  defp validate_id(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "" or String.length(trimmed) > 255, do: {:error, :invalid_request}, else: {:ok, trimmed}
  end

  defp validate_id(_), do: {:error, :invalid_request}

  defp decode_blob(value, max_bytes) when is_binary(value) do
    case Base.decode64(String.trim(value)) do
      {:ok, binary} when byte_size(binary) > 0 and byte_size(binary) <= max_bytes -> {:ok, binary}
      {:ok, binary} when byte_size(binary) > max_bytes -> {:error, :too_large}
      _ -> {:error, :invalid_encoding}
    end
  end

  defp decode_blob(_value, _max_bytes), do: {:error, :invalid_encoding}

  defp decode_optional_blob(nil, _max_bytes), do: {:ok, nil}
  defp decode_optional_blob("", _max_bytes), do: {:ok, nil}
  defp decode_optional_blob(value, max_bytes), do: decode_blob(value, max_bytes)
end
