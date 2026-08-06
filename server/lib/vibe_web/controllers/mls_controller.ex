defmodule VibeWeb.MlsController do
  use VibeWeb, :controller

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
      {:ok, %{count: count}} ->
        json(conn, %{success: true, count: count})

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
    case Mls.claim_key_package(user_id) do
      {:ok, package} ->
        json(conn, %{
          keyPackage: Base.encode64(package.key_package),
          deviceId: package.device_id
        })

      {:error, :not_found} ->
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
end
