defmodule VibeWeb.MlsController do
  use VibeWeb, :controller

  alias Vibe.Chat
  alias Vibe.GroupKeys
  alias Vibe.Mls

  @doc """
  Publish a batch of MLS KeyPackages for the calling device.

  Always scoped to `conn.assigns.current_user` — the `ApiAuth` plug is the
  only source of truth for whose packages these are. Any `userId` in the
  body is ignored (see `Vibe.Mls.publish_key_packages/2`).
  """
  def publish(conn, params) do
    user_id = conn.assigns.current_user.id

    case Mls.publish_key_packages(user_id, params) do
      {:ok, %{count: count} = result} ->
        json(conn, %{success: true, count: count, retired: Map.get(result, :retired, false)})

      {:error, :invalid_device_id} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Invalid deviceId"})

      {:error, :invalid_key_packages} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Invalid keyPackages"})

      {:error, :batch_too_large} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Too many keyPackages"})

      {:error, :invalid_key_package_encoding} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "keyPackages must be base64-encoded"})

      {:error, _reason} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "Failed to publish"})
    end
  end

  @doc """
  Claim one available KeyPackage published by `:user_id` — i.e. the device
  claiming this is about to add that user to an MLS group. A 404 here means
  that user currently has no spare KeyPackage, which is an expected state the
  client must handle (prompt a re-publish / retry later), not an error.
  """
  def claim(conn, %{"user_id" => user_id}) do
    claimer_id = conn.assigns.current_user.id

    case Mls.claim_key_package(claimer_id, user_id) do
      {:ok, package} ->
        json(conn, %{
          keyPackage: Base.encode64(package.key_package),
          deviceId: package.device_id
        })

      {:error, :too_many} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Too many KeyPackage claims"})

      {:error, _reason} ->
        # :not_allowed and :not_found both 404 so a stranger cannot probe
        # whether a user has packages or whether the two share a chat.
        conn |> put_status(:not_found) |> json(%{error: "No available KeyPackage"})
    end
  end

  @doc """
  How many unclaimed KeyPackages the calling user currently has published.
  """
  def count(conn, _params) do
    user_id = conn.assigns.current_user.id
    json(conn, %{count: Mls.count_available(user_id)})
  end

  @doc """
  Hand a Welcome to the server for delivery to one recipient.

  The sender is always `conn.assigns.current_user` — a `senderUserId` in the
  body is ignored, the same discipline as `publish/2`.
  """
  def post_welcome(conn, params) do
    sender_id = conn.assigns.current_user.id

    case Mls.post_welcome(sender_id, params) do
      {:ok, row} ->
        json(conn, %{success: true, id: row.id})

      {:error, :too_large} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Welcome too large"})

      {:error, :invalid_encoding} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "welcome must be base64-encoded"})

      {:error, :too_many_pending} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Too many undelivered welcomes"})

      {:error, :not_allowed} ->
        conn |> put_status(:not_found) |> json(%{error: "Not found"})

      {:error, :invalid_request} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Invalid request"})

      {:error, _reason} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "Failed to post welcome"})
    end
  end

  @doc """
  Every Welcome still waiting for the calling user. Scoped to them with no
  parameter that can widen it — see `Vibe.Mls.pending_welcomes/1`.
  """
  def pending_welcomes(conn, _params) do
    user_id = conn.assigns.current_user.id

    welcomes =
      user_id
      |> Mls.pending_welcomes()
      |> Enum.map(fn row ->
        %{
          id: row.id,
          chatId: row.chat_id,
          senderUserId: row.sender_user_id,
          welcome: Base.encode64(row.welcome),
          ratchetTree: row.ratchet_tree && Base.encode64(row.ratchet_tree),
          createdAt: row.inserted_at
        }
      end)

    json(conn, %{welcomes: welcomes})
  end

  @doc """
  Confirm a Welcome was applied. Scoped by recipient, so one user cannot ack
  another's — a mismatch reports 404 and leaks nothing about the id.
  """
  def ack_welcome(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id

    case Mls.ack_welcome(user_id, id) do
      :ok -> json(conn, %{success: true})
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "Not found"})
    end
  end

  @doc """
  The user ids that must be added to this chat's MLS group.

  Exists because establishing a group session needs the whole membership in
  one commit, and the client has no other way to learn it. Only a participant
  may ask: a non-member gets 404 rather than 403, so this cannot be used to
  probe which chat ids exist.
  """
  def chat_members(conn, %{"chat_id" => chat_id}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      json(conn, %{memberIds: Chat.get_participant_ids(chat_id)})
    else
      conn |> put_status(:not_found) |> json(%{error: "Not found"})
    end
  end

  @doc """
  Welcome counts for this caller on a chat: sent pending/delivered plus incomingPending/incomingDelivered.
  Incoming counts distinguish a joiner from an initiator whose Welcome never landed.
  """
  def welcome_status(conn, %{"chat_id" => chat_id}) do
    status = Mls.welcome_status(conn.assigns.current_user.id, chat_id)

    json(conn, %{
      chatId: chat_id,
      pending: status.pending,
      delivered: status.delivered,
      incomingPending: status.incoming_pending,
      incomingDelivered: status.incoming_delivered
    })
  end

  # ── group epoch keys ───────────────────────────────────────────────────────
  #
  # The epoch-key layer covers channels and groups past the MLS member cap. See
  # `Vibe.GroupKeys` for why authority is checked on every post rather than
  # assumed — an epoch key blob, unlike a Welcome, is useful to whoever can get
  # a recipient to install it.

  @doc """
  Post epoch keys, each already sealed to its recipient by the caller's device.

  Refused unless the caller is the chat's key authority: owner/admin for a
  channel, any member for a group. A DM has no epochs and is refused outright.
  """
  def post_epoch_keys(conn, params) do
    sender_id = conn.assigns.current_user.id

    case GroupKeys.post_epoch_keys(sender_id, params) do
      {:ok, count} ->
        json(conn, %{success: true, stored: count})

      {:error, :not_allowed} ->
        # 403 rather than 404: unlike claiming a key package, the caller already
        # knows this chat exists — they are in it — so there is nothing to hide
        # and "you are not an admin" is the actionable answer.
        conn |> put_status(:forbidden) |> json(%{error: "Not allowed to issue keys here"})

      {:error, :too_large} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Sealed key too large"})

      {:error, :too_many} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Too many keys in one batch"})

      {:error, :invalid_encoding} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "sealedKey must be base64-encoded"})

      {:error, :too_many_pending} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Too many undelivered epoch keys"})

      {:error, _reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Invalid request"})
    end
  end

  @doc """
  Every epoch key still waiting for the caller. Scoped to the caller only.
  """
  def pending_epoch_keys(conn, _params) do
    user_id = conn.assigns.current_user.id

    keys =
      user_id
      |> GroupKeys.pending_epoch_keys()
      |> Enum.map(fn row ->
        %{
          id: row.id,
          chatId: row.chat_id,
          senderUserId: row.sender_user_id,
          epoch: row.epoch,
          sealedKey: Base.encode64(row.sealed_key),
          createdAt: row.inserted_at
        }
      end)

    json(conn, %{keys: keys})
  end

  @doc """
  Confirm an epoch key was installed. Scoped by recipient; a mismatch reports
  404 and leaks nothing about the id.
  """
  def ack_epoch_key(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id

    case GroupKeys.ack_epoch_key(user_id, id) do
      :ok -> json(conn, %{success: true})
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "Not found"})
    end
  end
end
