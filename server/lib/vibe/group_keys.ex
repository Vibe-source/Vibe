defmodule Vibe.GroupKeys do
  @moduledoc """
  Relay for group epoch keys — the distribution half of `vibe_core::group`.

  Covers what MLS cannot: **channels**, where a new subscriber must be able to
  read the backlog (MLS forward secrecy makes that impossible by design), and
  **groups past the MLS member cap**, where the tree operation and Welcome
  fan-out for a join stop being acceptable on a phone.

  The server never sees an epoch key. `sealed_key` arrives already encrypted to
  the recipient by the sender's device; this module checks who may post, who may
  read, and how much — never what.

  ## The attack this module is mostly about

  An epoch key is not like a Welcome. A Welcome is useless to anyone but its
  recipient and cannot be forged without the group's secrets. An epoch key blob
  is just "here is a key, install it" — so if *anyone* could post one, an
  attacker could:

  * post a high epoch with a key of their choosing, which the recipient's
    keyring accepts (installs are monotone, and a higher epoch looks like a
    legitimate rotation), after which the victim seals outgoing messages under a
    key the attacker knows; and
  * make real history unreadable, because the monotonicity rule that stops
    rollbacks also stops the *genuine* key for that epoch from being installed
    afterwards.

  So authority is checked here, on every post, against the same participant
  roles the chat itself uses:

  * **channel** — `owner` or `admin` only. Subscribers receive keys, never issue
    them.
  * **group** — any non-deleted participant, because any member may add another
    and therefore may need to open an epoch.
  * **anything else** — refused. A DM has no epochs; it is MLS.

  This is defence in depth, not the whole defence: a client must still refuse a
  key from a sender it does not consider the group's key authority. But the
  check is cheap and it makes the attack require a compromised admin rather than
  any account at all.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Vibe.Repo
  alias Vibe.Schemas.GroupEpochKey

  # An epoch key is 32 bytes of AES-256 sealed to one recipient. Even an RSA-4096
  # wrap plus envelope framing lands far under this; the ceiling exists so a
  # hostile client cannot use the relay as free storage.
  @max_sealed_key_bytes 8 * 1024

  # How many undelivered keys one sender may have outstanding to one recipient.
  # A member legitimately needs one per epoch they are entitled to, and history
  # backfill can mean several at once — but not hundreds. Past this the answer is
  # to stop accepting rather than accumulate.
  @max_pending_per_sender 128

  # Largest batch one call may post. Adding a member to a large channel means one
  # row per epoch being granted, so batching is the normal path, not an
  # optimisation.
  @max_batch 200

  @doc """
  Store epoch keys posted by `sender_user_id`.

  `sender_user_id` must be the *authenticated* caller's id — a controller passes
  `conn.assigns.current_user.id` and never a body field. There is deliberately no
  "post on behalf of".

  Returns `{:ok, count}`. Rows that collide with a key the recipient already has
  for that `(chat, epoch)` are **skipped, not failed**: a retry after a partial
  delivery is the common case, and making it an error would turn an ordinary
  retry into a stuck client.
  """
  def post_epoch_keys(sender_user_id, params) when is_binary(sender_user_id) and is_map(params) do
    chat_id = params["chatId"] || params["chat_id"]
    entries = params["keys"] || params["entries"]

    with {:ok, chat_id} <- validate_id(chat_id),
         :ok <- authorize_sender(chat_id, sender_user_id),
         {:ok, entries} <- validate_batch(entries),
         {:ok, rows} <- build_rows(entries, chat_id, sender_user_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      rows = Enum.map(rows, &Map.merge(&1, %{inserted_at: now, updated_at: now}))

      # `on_conflict: :nothing` is what makes a retry idempotent. Combined with
      # the unique index it is also what stops a second, different key for an
      # epoch a member already holds — the first one posted wins, permanently.
      {count, _} =
        Repo.insert_all(GroupEpochKey, rows,
          on_conflict: :nothing,
          conflict_target: [:recipient_user_id, :chat_id, :epoch]
        )

      {:ok, count}
    end
  end

  def post_epoch_keys(_sender_user_id, _params), do: {:error, :invalid_request}

  @doc """
  Every epoch key still waiting for `user_id`.

  Scoped to `user_id` with no widening parameter, deliberately: an epoch key is
  read access to a group's history, so serving one to the wrong user hands them
  the conversation.
  """
  def pending_epoch_keys(user_id) when is_binary(user_id) do
    GroupEpochKey
    |> where([k], k.recipient_user_id == ^user_id and is_nil(k.delivered_at))
    |> order_by([k], asc: k.chat_id, asc: k.epoch)
    |> Repo.all()
  end

  def pending_epoch_keys(_user_id), do: []

  @doc """
  Mark one epoch key installed.

  Scoped by recipient as well as id, so one user cannot ack — and thereby hide —
  another user's pending key. A row that does not belong to `user_id` is reported
  as `:not_found` rather than `:forbidden`, so the caller learns nothing about
  whether the id exists.
  """
  def ack_epoch_key(user_id, id) when is_binary(user_id) and is_binary(id) do
    query =
      from(k in GroupEpochKey,
        where: k.id == ^id and k.recipient_user_id == ^user_id and is_nil(k.delivered_at)
      )

    case Repo.update_all(query,
           set: [delivered_at: DateTime.utc_now() |> DateTime.truncate(:second)]
         ) do
      {1, _} -> :ok
      _ -> {:error, :not_found}
    end
  rescue
    # A malformed uuid makes Postgres raise rather than return no rows. From the
    # caller's point of view that is an ordinary "no such row".
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def ack_epoch_key(_user_id, _id), do: {:error, :not_found}

  # ── authority ─────────────────────────────────────────────────────────────

  # Who may issue keys for this chat. See the module doc: this is the check that
  # stops any account from installing a key of its choosing into a victim's
  # keyring.
  defp authorize_sender(chat_id, sender_user_id) do
    case Vibe.Chat.get_room_type(chat_id) do
      "channel" ->
        if Vibe.Chat.get_user_role(chat_id, sender_user_id) in ["owner", "admin"] do
          :ok
        else
          Logger.warning(
            "[GroupKeys] refused epoch-key post from non-admin chat=#{chat_id} user=#{sender_user_id}"
          )

          {:error, :not_allowed}
        end

      "group" ->
        if Vibe.Chat.get_user_role(chat_id, sender_user_id) do
          :ok
        else
          Logger.warning(
            "[GroupKeys] refused epoch-key post from non-member chat=#{chat_id} user=#{sender_user_id}"
          )

          {:error, :not_allowed}
        end

      other ->
        # A DM is MLS and has no epochs; an unknown/missing room is not a chat
        # this relay serves. Both are refused rather than defaulted.
        Logger.warning("[GroupKeys] refused epoch-key post for room_type=#{inspect(other)}")
        {:error, :not_allowed}
    end
  end

  # ── validation ────────────────────────────────────────────────────────────

  defp validate_batch(entries) when is_list(entries) do
    cond do
      entries == [] -> {:error, :invalid_request}
      length(entries) > @max_batch -> {:error, :too_many}
      true -> {:ok, entries}
    end
  end

  defp validate_batch(_entries), do: {:error, :invalid_request}

  defp build_rows(entries, chat_id, sender_user_id) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      with true <- is_map(entry),
           {:ok, recipient_id} <-
             validate_id(entry["recipientUserId"] || entry["recipient_user_id"]),
           {:ok, epoch} <- validate_epoch(entry["epoch"]),
           {:ok, sealed} <- decode_blob(entry["sealedKey"] || entry["sealed_key"]),
           :ok <- check_pending_quota(recipient_id, sender_user_id) do
        row = %{
          recipient_user_id: recipient_id,
          sender_user_id: sender_user_id,
          chat_id: chat_id,
          epoch: epoch,
          sealed_key: sealed
        }

        {:cont, {:ok, [row | acc]}}
      else
        false -> {:halt, {:error, :invalid_request}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp check_pending_quota(recipient_id, sender_id) do
    count =
      GroupEpochKey
      |> where(
        [k],
        k.recipient_user_id == ^recipient_id and k.sender_user_id == ^sender_id and
          is_nil(k.delivered_at)
      )
      |> Repo.aggregate(:count, :id)

    if count >= @max_pending_per_sender, do: {:error, :too_many_pending}, else: :ok
  end

  defp validate_epoch(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp validate_epoch(value) when is_binary(value) do
    case Integer.parse(value) do
      {epoch, ""} when epoch >= 0 -> {:ok, epoch}
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_epoch(_value), do: {:error, :invalid_request}

  defp validate_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" or String.length(trimmed) > 255 do
      {:error, :invalid_request}
    else
      {:ok, trimmed}
    end
  end

  defp validate_id(_value), do: {:error, :invalid_request}

  defp decode_blob(value) when is_binary(value) do
    case Base.decode64(String.trim(value)) do
      {:ok, binary} when byte_size(binary) > 0 and byte_size(binary) <= @max_sealed_key_bytes ->
        {:ok, binary}

      {:ok, _binary} ->
        {:error, :too_large}

      _ ->
        {:error, :invalid_encoding}
    end
  end

  defp decode_blob(_value), do: {:error, :invalid_encoding}
end
