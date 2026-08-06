defmodule Vibe.R2Storage do
  @moduledoc """
  Cloudflare R2 storage client — a private-bucket counterpart to
  `Vibe.SupabaseStorage`. Not wired into any caller yet; it sits behind
  `Vibe.Storage`'s backend switch, which defaults to `:supabase`, so adding
  this module changes nothing about today's behaviour on its own. See
  docs/secure-core-architecture.md §6 (Media plan).

  R2 is S3-compatible, so requests are authenticated with AWS SigV4 via the
  `:ex_aws` / `:ex_aws_s3` libraries — a mature signer beats hand-rolling
  HMAC canonical requests. We only use their pure, local signing helpers
  (`ExAws.Config.new/2`, `ExAws.S3.presigned_url/5`); no `ExAws.request/1`
  call is ever made, so no ExAws HTTP client/pool is involved. The actual
  bytes still move over `Finch` (`Vibe.Finch`, already started by
  `Vibe.Application`), matching how `Vibe.SupabaseStorage` does HTTP.

  ## Why this module's shape is what it is

  Once media is genuinely end-to-end encrypted (client media keys no longer
  ride the wire — see `securecore-0806`), the storage provider stops being a
  confidentiality boundary and becomes a *metadata* boundary: it still learns
  object sizes, request timing, and client IPs. So the three things this
  module is careful about are ids, URLs, and lifetime — not "encrypting
  harder":

    * **No public objects, ever.** The bucket is private; there is no
      `get_public_url`-style helper here, on purpose. Reads only happen
      through `get_presigned_url/1,2`, which mints a short-TTL signed GET.
    * **Unguessable keys.** `generate_object_key/1` is pure
      `:crypto.strong_rand_bytes/1` output — never derived from or
      containing a user id, chat id, message id, or the original filename.
      Those would turn the bucket into a queryable social graph. The one
      thing kept is a coarse file extension (from an allow-list, not the
      caller's filename) so a downloaded blob still round-trips through
      normal OS/client file handling.
    * **Fail closed.** Missing configuration is always `{:error, _}` (or
      `false` for `exists?/1`, matching `Vibe.SupabaseStorage`'s own shape)
      — never a fallback to an unsigned or public request.

  ## Interface parity with `Vibe.SupabaseStorage`

  `upload/2`, `upload/3`, `exists?/1`, and `delete/1` mirror
  `Vibe.SupabaseStorage`'s arities and `{:ok, _} / {:error, reason}` shapes
  exactly. The one deliberate difference: because object keys are generated
  here (never caller-supplied), the `remote_path` argument to `upload/2,3` is
  accepted only for interface parity and content-type/extension inference —
  it is **not** used as the object key. The key actually written is
  whatever `generate_object_key/1` produced; `upload/2,3` returns a fresh
  presigned URL for it. Callers that need to `exists?/1` or `delete/1` that
  same object later must hold onto the generated key (loggable via the
  "[R2Storage] Uploaded: <key>" line, or parseable from the returned URL's
  path) — this is an open question for whichever later slice actually wires
  callers onto this module, not something this slice resolves.
  """

  require Logger

  # Default read TTL: 15 minutes. Callers can override per-call via
  # `ttl: seconds` in opts; there is no env var for this (see requirement 5
  # in the owning brief — only R2_ACCOUNT_ID/R2_ACCESS_KEY_ID/
  # R2_SECRET_ACCESS_KEY/R2_BUCKET/R2_PUBLIC_BASE_URL are environment-driven).
  @default_ttl_seconds 15 * 60
  # ExAws.S3.presigned_url/5 itself refuses expires_in beyond one week; we
  # clamp to the same bound so a bad override fails predictably instead of
  # bubbling an ExAws error string.
  @max_ttl_seconds 7 * 24 * 60 * 60

  # 24 random bytes = 192 bits of entropy, url-safe-base64-encoded with no
  # padding so the key is a clean path segment.
  @key_random_bytes 24

  # Extensions we know Vibe media can be; anything else is dropped rather
  # than trusting caller input into the key. This list mirrors
  # Vibe.SupabaseStorage's get_content_type/1 suffix set.
  @allowed_extensions ~w(.m4a .mp3 .mp4 .webm .jpg .jpeg .png .gif .webp .heic .wav .mov .pdf .csv .txt .json .xlsx)

  # --- config --------------------------------------------------------------

  defp get_config do
    config = Application.get_env(:vibe, :r2, [])

    %{
      account_id: config[:account_id] || System.get_env("R2_ACCOUNT_ID"),
      access_key_id: config[:access_key_id] || System.get_env("R2_ACCESS_KEY_ID"),
      secret_access_key: config[:secret_access_key] || System.get_env("R2_SECRET_ACCESS_KEY"),
      bucket: config[:bucket] || System.get_env("R2_BUCKET"),
      # Deliberately unused for URL construction — see moduledoc. Kept in
      # config only so a later slice doesn't have to touch runtime.exs again.
      public_base_url: config[:public_base_url] || System.get_env("R2_PUBLIC_BASE_URL")
    }
  end

  @doc """
  Whether R2 has everything it needs to serve a request.

  `Vibe.Storage.backend/0` calls this to select a backend without a separate
  config flag. It lives here rather than in the facade so the list of required
  variables exists in exactly one place — a facade that kept its own copy would
  drift and start routing to a backend that then refuses every call.
  """
  def configured?, do: configured?(get_config())

  @doc """
  Rewrite an R2 object URL onto the configured public base.

  **Only touches URLs that belong to this account's R2 endpoint.** Anything
  else — most importantly the Supabase URLs already stored against existing
  media — is returned unchanged. Rewriting by path alone would point every
  legacy URL at R2, where those objects do not exist, turning working media
  into 404s at the moment the backend flips.

  Returns `url` unchanged when no public base is configured too: an unrewritten
  URL may be suboptimal, but a URL rewritten onto a base that does not exist is
  certainly broken.
  """
  def rewrite_public_url(url) when is_binary(url) do
    config = get_config()

    with true <- present?(config.public_base_url),
         %URI{host: host, path: path} when is_binary(host) and is_binary(path) <- URI.parse(url),
         true <- r2_host?(host, config) do
      # The endpoint form is `<account>.r2.cloudflarestorage.com/<bucket>/<key>`
      # while the public base already addresses the bucket, so the bucket
      # segment has to come off or it ends up in the path twice.
      key = String.replace_prefix(path, "/#{config.bucket}", "")
      String.trim_trailing(config.public_base_url, "/") <> key
    else
      _ -> url
    end
  end

  def rewrite_public_url(url), do: url

  defp r2_host?(host, config) do
    host == "#{config.account_id}.r2.cloudflarestorage.com" or
      String.ends_with?(host, ".r2.cloudflarestorage.com")
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp configured?(config) do
    present?(config.account_id) and
      present?(config.access_key_id) and
      present?(config.secret_access_key) and
      present?(config.bucket)
  end

  defp missing_config_error do
    Logger.error(
      "[R2Storage] Missing config, refusing (need R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET)"
    )

    {:error, "R2 not configured"}
  end

  defp ex_aws_config(config) do
    ExAws.Config.new(:s3,
      access_key_id: config.access_key_id,
      secret_access_key: config.secret_access_key,
      # Cloudflare's documented SigV4 convention for R2 is region "auto" —
      # R2 is not partitioned by AWS region, but SigV4 requires some value.
      region: "auto",
      host: "#{config.account_id}.r2.cloudflarestorage.com",
      scheme: "https://",
      port: 443
    )
  end

  # --- object keys -----------------------------------------------------------

  @doc """
  Generates an unguessable object key: `:crypto.strong_rand_bytes/1` output
  only. Never derived from, or containing, a user id, chat id, message id,
  or the original filename — only a coarse extension is preserved, and only
  when it matches a known media extension, so the *name* itself carries no
  information about who created the object or what it was originally called.

  `source_path` is optional and only consulted for its extension (e.g. pass
  the caller's `remote_path` or original filename — its directory
  components and stem are never read).
  """
  def generate_object_key(source_path \\ nil) do
    random =
      @key_random_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    case safe_extension(source_path) do
      nil -> random
      ext -> random <> ext
    end
  end

  defp safe_extension(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()
    if ext in @allowed_extensions, do: ext, else: nil
  end

  defp safe_extension(_), do: nil

  # --- public interface (mirrors Vibe.SupabaseStorage) ----------------------

  @doc """
  Upload a file to R2 under a freshly generated, unguessable object key (see
  `generate_object_key/1`). `remote_path` is accepted for interface parity
  with `Vibe.SupabaseStorage.upload/2` and to infer a content type /
  extension — it is not used as the object key.

  Returns `{:ok, presigned_url}` (a short-TTL GET URL for the object just
  uploaded — there is no permanent/public URL) or `{:error, reason}`.
  """
  def upload(local_path, remote_path), do: upload(local_path, remote_path, [])

  def upload(local_path, remote_path, opts) when is_list(opts) do
    config = get_config()

    if configured?(config) do
      key = generate_object_key(remote_path)

      case File.read(local_path) do
        {:ok, content} -> do_put(config, key, content, remote_path, opts)
        {:error, reason} -> {:error, "Could not read file: #{inspect(reason)}"}
      end
    else
      missing_config_error()
    end
  end

  defp do_put(config, key, content, remote_path, opts) do
    aws_config = ex_aws_config(config)
    bucket = resolve_bucket(config, opts)

    case ExAws.S3.presigned_url(aws_config, :put, bucket, key, expires_in: 300) do
      {:ok, put_url} ->
        headers = [{"Content-Type", get_content_type(remote_path)}]
        request = Finch.build(:put, put_url, headers, content)

        case Finch.request(request, Vibe.Finch, receive_timeout: 120_000) do
          {:ok, %{status: status}} when status in [200, 201] ->
            Logger.info("[R2Storage] Uploaded: #{key}")
            get_presigned_url(key, opts)

          {:ok, %{status: status, body: body}} ->
            Logger.error("[R2Storage] Upload failed: #{status} - #{body}")
            {:error, "Upload failed: #{status} - #{truncate_body(body)}"}

          {:error, reason} ->
            Logger.error("[R2Storage] Upload error: #{inspect(reason)}")
            {:error, "Upload error: #{inspect(reason)}"}
        end

      {:error, reason} ->
        Logger.error("[R2Storage] Failed to presign upload: #{inspect(reason)}")
        {:error, "Failed to presign upload: #{inspect(reason)}"}
    end
  end

  @doc """
  Check whether an object exists. Returns a bare boolean — matching
  `Vibe.SupabaseStorage.exists?/1`'s shape exactly — `false` on missing
  config or any error, never raises.
  """
  def exists?(remote_path) do
    config = get_config()

    if configured?(config) do
      aws_config = ex_aws_config(config)
      bucket = resolve_bucket(config, [])

      case ExAws.S3.presigned_url(aws_config, :head, bucket, remote_path, expires_in: 60) do
        {:ok, head_url} ->
          request = Finch.build(:head, head_url)

          case Finch.request(request, Vibe.Finch, receive_timeout: 10_000) do
            {:ok, %{status: 200}} -> true
            _ -> false
          end

        {:error, _reason} ->
          false
      end
    else
      false
    end
  end

  @doc """
  Delete an object from storage.
  """
  def delete(remote_path) do
    config = get_config()

    if configured?(config) do
      aws_config = ex_aws_config(config)
      bucket = resolve_bucket(config, [])

      case ExAws.S3.presigned_url(aws_config, :delete, bucket, remote_path, expires_in: 60) do
        {:ok, delete_url} ->
          request = Finch.build(:delete, delete_url)

          case Finch.request(request, Vibe.Finch, receive_timeout: 10_000) do
            {:ok, %{status: status}} when status in [200, 204] -> :ok
            {:ok, %{status: status, body: body}} -> {:error, "Delete failed: #{status} - #{body}"}
            {:error, reason} -> {:error, inspect(reason)}
          end

        {:error, reason} ->
          {:error, "Failed to presign delete: #{inspect(reason)}"}
      end
    else
      {:error, "R2 not configured"}
    end
  end

  @doc """
  The URL accessor for this backend — deliberately not called
  `get_public_url`. R2 objects are private; this mints a short-TTL presigned
  GET (default #{@default_ttl_seconds} seconds / 15 minutes). Pass
  `ttl: seconds` in `opts` to override, up to one week (ExAws.S3's own cap).

  Returns `{:ok, url}` or `{:error, reason}`.
  """
  def get_presigned_url(remote_path), do: get_presigned_url(remote_path, [])

  def get_presigned_url(remote_path, opts) when is_list(opts) do
    config = get_config()

    if configured?(config) do
      aws_config = ex_aws_config(config)
      bucket = resolve_bucket(config, opts)
      ttl = resolve_ttl(opts)

      case ExAws.S3.presigned_url(aws_config, :get, bucket, remote_path, expires_in: ttl) do
        {:ok, url} -> {:ok, url}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      missing_config_error()
    end
  end

  # `opts[:bucket]` is honoured only when it is a non-empty string override
  # (forward-compat with Vibe.SupabaseStorage's per-call bucket override).
  # Vibe.SupabaseStorage callers today pass atoms like :music / :media to
  # pick between two configured buckets; R2 has a single bucket for this
  # slice (only R2_BUCKET is defined), so an atom is treated as "no
  # override" rather than raised on — additive slices should not crash on
  # opts shaped for the other backend.
  defp resolve_bucket(config, opts) do
    case Keyword.get(opts, :bucket) do
      bucket when is_binary(bucket) and bucket != "" -> bucket
      _ -> config.bucket
    end
  end

  defp resolve_ttl(opts) do
    opts
    |> Keyword.get(:ttl, @default_ttl_seconds)
    |> clamp_ttl()
  end

  defp clamp_ttl(ttl) when is_integer(ttl) and ttl > 0, do: min(ttl, @max_ttl_seconds)
  defp clamp_ttl(_), do: @default_ttl_seconds

  defp truncate_body(body) when is_binary(body) do
    max = 600
    if byte_size(body) > max, do: binary_part(body, 0, max) <> "...", else: body
  end

  defp truncate_body(body), do: inspect(body)

  # Mirrors Vibe.SupabaseStorage.get_content_type/1 — duplicated rather than
  # shared because this slice must not modify supabase_storage.ex.
  defp get_content_type(path) when is_binary(path) do
    cond do
      String.ends_with?(path, ".m4a") ->
        "audio/mp4"

      String.ends_with?(path, ".mp3") ->
        "audio/mpeg"

      String.ends_with?(path, ".mp4") ->
        "video/mp4"

      String.ends_with?(path, ".webm") ->
        "audio/webm"

      String.ends_with?(path, ".jpg") ->
        "image/jpeg"

      String.ends_with?(path, ".jpeg") ->
        "image/jpeg"

      String.ends_with?(path, ".png") ->
        "image/png"

      String.ends_with?(path, ".gif") ->
        "image/gif"

      String.ends_with?(path, ".webp") ->
        "image/webp"

      String.ends_with?(path, ".heic") ->
        "image/heic"

      String.ends_with?(path, ".wav") ->
        "audio/wav"

      String.ends_with?(path, ".mov") ->
        "video/quicktime"

      String.ends_with?(path, ".pdf") ->
        "application/pdf"

      String.ends_with?(path, ".csv") ->
        "text/csv"

      String.ends_with?(path, ".txt") ->
        "text/plain"

      String.ends_with?(path, ".json") ->
        "application/json"

      String.ends_with?(path, ".xlsx") ->
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

      true ->
        "application/octet-stream"
    end
  end

  defp get_content_type(_), do: "application/octet-stream"
end
