defmodule VibeWeb.MediaController do
  @moduledoc """
  Controller for media file uploads (images, audio, video).
  Uploads files to Supabase Storage and returns public URLs.
  """
  use VibeWeb, :controller

  alias Vibe.Storage

  require Logger

  @max_file_size (case Integer.parse(System.get_env("MAX_UPLOAD_SIZE_BYTES") || "120000000") do
                   {value, _} when value > 0 -> value
                   _ -> 120_000_000
                 end)

  @doc """
  Upload a media file.
  POST /api/media/upload
  Expects multipart form with:
    - file: the file to upload
    - user_id: the uploader's user ID
    - type: "image" | "audio" | "video" | "file"
  Returns: { url: "https://..." }
  """
  def upload(conn, %{"file" => %Plug.Upload{} = upload} = params) do
    user_id = conn.assigns.current_user.id
    media_type = params["type"] || detect_type(upload.content_type)

    # Check file size
    case File.stat(upload.path) do
      {:ok, %{size: size}} when size > @max_file_size ->
        conn
        |> put_status(:request_entity_too_large)
        |> json(%{error: "File too large", max_size: @max_file_size})

      {:ok, %{size: size}} ->
        Logger.info("[MediaController] Upload: #{upload.filename} (#{size} bytes) type=#{media_type}")

        # Generate unique remote path
        ext = Path.extname(upload.filename) |> String.downcase()
        timestamp = System.system_time(:millisecond)
        random = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
        # Stored inside the configured media bucket (default: "chat-media").
        remote_path = "#{user_id}/#{timestamp}_#{random}#{ext}"

        case Storage.upload(upload.path, remote_path, bucket: :media) do
          {:ok, public_url} ->
            Logger.info("[MediaController] Uploaded to: #{public_url}")
            json(conn, %{url: public_url, size: size, type: media_type})

          {:error, reason} ->
            Logger.error("[MediaController] Upload failed: #{reason}")
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Upload failed", reason: reason})
        end

      {:error, reason} ->
        Logger.error("[MediaController] Cannot stat file: #{inspect(reason)}")
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid file"})
    end
  end

  def upload(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing file parameter. Use multipart form with 'file' field."})
  end

  defp detect_type(content_type) when is_binary(content_type) do
    cond do
      String.starts_with?(content_type, "image/") -> "image"
      String.starts_with?(content_type, "audio/") -> "audio"
      String.starts_with?(content_type, "video/") -> "video"
      true -> "file"
    end
  end

  defp detect_type(_), do: "file"
end
