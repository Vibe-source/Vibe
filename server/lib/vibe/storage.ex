defmodule Vibe.Storage do
  @moduledoc """
  Thin facade that selects a storage backend and forwards to it. Real call
  sites (`media_controller`, `story_controller`, `music_controller`,
  `chat_bridge`, `chat`, `ai/tts`, `ai/mcp/content`) call this module
  instead of `Vibe.SupabaseStorage` or `Vibe.R2Storage` directly, so which
  backend actually serves a given request can change without touching any
  of them.

  ## Backend selection (see `backend/0`)

  1. `config :vibe, :storage_backend` — if explicitly set to `:r2`/`"r2"`
     or `:supabase`/`"supabase"`, that value always wins, in both
     directions. This is the escape hatch: an explicit `:supabase` forces
     Supabase even when R2 env vars happen to be present, and an explicit
     `:r2` forces R2 even when they are absent (which then fails closed —
     see `Vibe.R2Storage`'s own "fail closed" contract in its moduledoc).
  2. Otherwise, autodetected from whether R2 is actually configured (see
     `Vibe.R2Storage.configured?/0`): `:r2` once its required env vars
     (account id, access key id, secret access key, bucket) are all
     present and non-empty, `:supabase` if not.

  An install with no explicit config and no R2 env vars set therefore still
  behaves exactly like calling `Vibe.SupabaseStorage` directly — the switch
  only ever moves when someone sets the explicit config or provisions real
  R2 credentials.
  """

  alias Vibe.R2Storage
  alias Vibe.SupabaseStorage

  @doc """
  Returns the configured storage backend: `:supabase` or `:r2`. See the
  module doc for the full selection order.
  """
  def backend do
    case Application.get_env(:vibe, :storage_backend) do
      v when v in [:r2, "r2"] -> :r2
      v when v in [:supabase, "supabase"] -> :supabase
      _ -> autodetect_backend()
    end
  end

  defp autodetect_backend do
    if R2Storage.configured?(), do: :r2, else: :supabase
  end

  @doc "Upload a file through the configured backend. See backend/0."
  def upload(local_path, remote_path), do: upload(local_path, remote_path, [])

  def upload(local_path, remote_path, opts) when is_list(opts) do
    case backend() do
      :r2 -> R2Storage.upload(local_path, remote_path, opts)
      :supabase -> SupabaseStorage.upload(local_path, remote_path, opts)
    end
  end

  @doc "Check existence through the configured backend. See backend/0."
  def exists?(remote_path) do
    case backend() do
      :r2 -> R2Storage.exists?(remote_path)
      :supabase -> SupabaseStorage.exists?(remote_path)
    end
  end

  @doc "Delete through the configured backend. See backend/0."
  def delete(remote_path) do
    case backend() do
      :r2 -> R2Storage.delete(remote_path)
      :supabase -> SupabaseStorage.delete(remote_path)
    end
  end

  @doc """
  Rewrite a stored URL onto whichever CDN fronts the storage it actually lives
  in.

  On `:r2` this applies **both** rewriters, not just R2's. Switching backends
  does not move the objects already uploaded, so the database keeps serving a
  mix: old rows hold Supabase URLs, new rows hold R2 ones. Each rewriter only
  recognises its own URLs and passes everything else through untouched, so
  running both is what keeps existing media working across the cutover —
  picking one would break whichever half it did not recognise.
  """
  def rewrite_public_url(url) do
    case backend() do
      :r2 -> url |> SupabaseStorage.rewrite_public_url() |> R2Storage.rewrite_public_url()
      :supabase -> SupabaseStorage.rewrite_public_url(url)
    end
  end
end
