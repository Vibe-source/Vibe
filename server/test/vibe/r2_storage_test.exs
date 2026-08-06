defmodule Vibe.R2StorageTest do
  @moduledoc """
  Covers what actually makes R2Storage safe to add alongside Supabase:
  object keys carry no identifiers, presigned URLs really are signed with a
  real expiry, and missing config fails closed rather than falling back to
  an unsigned/public request. Also covers Vibe.Storage.backend/0's default.

  Nothing here makes a real network call or needs real credentials.
  Presigning is pure local computation (AWS SigV4 is HMAC-SHA256 over
  :crypto, no HTTP involved), so a placeholder access key id / secret is
  enough to exercise it end to end. The "fake_config" values below are not
  real credentials — they never touch a real R2 account.
  """

  use ExUnit.Case, async: false

  alias Vibe.R2Storage
  alias Vibe.Storage

  @r2_env_vars ~w(R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET R2_PUBLIC_BASE_URL)

  @fake_config [
    account_id: "test-account-id",
    access_key_id: "AKIAEXAMPLE00000TEST",
    secret_access_key: "test-placeholder-secret-not-a-real-credential",
    bucket: "test-bucket"
  ]

  # Every test starts from a clean slate: no :vibe, :r2 app env and no R2_*
  # env vars, regardless of what the ambient shell/CI happens to have set.
  # Individual tests opt into @fake_config via with_fake_config/1.
  setup do
    prev_app_env = Application.get_env(:vibe, :r2)
    prev_os_env = for key <- @r2_env_vars, into: %{}, do: {key, System.get_env(key)}

    Application.delete_env(:vibe, :r2)
    Enum.each(@r2_env_vars, &System.delete_env/1)

    on_exit(fn ->
      case prev_app_env do
        nil -> Application.delete_env(:vibe, :r2)
        value -> Application.put_env(:vibe, :r2, value)
      end

      Enum.each(prev_os_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  defp with_fake_config(fun) do
    Application.put_env(:vibe, :r2, @fake_config)
    fun.()
  end

  describe "generate_object_key/1 — unguessable, identifier-free keys" do
    test "does not contain the user id, chat id, message id, or filename it was uploaded with" do
      user_id = "user_#{System.unique_integer([:positive])}"
      chat_id = "chat_#{System.unique_integer([:positive])}"
      message_id = "message_#{System.unique_integer([:positive])}"

      # Shaped like how a caller builds remote_path today (see
      # media_controller / chat_bridge) — exactly the kind of path this key
      # must NOT be derived from.
      remote_path = "chat-media/#{user_id}/#{chat_id}/#{message_id}/vacation_photo.jpg"

      key = R2Storage.generate_object_key(remote_path)

      refute key =~ user_id
      refute key =~ chat_id
      refute key =~ message_id
      refute key =~ "vacation_photo"
      refute key =~ "chat-media"
    end

    test "keeps a recognized extension but drops directories and the filename stem" do
      key = R2Storage.generate_object_key("some/nested/path/secret-name.png")

      assert String.ends_with?(key, ".png")
      refute key =~ "secret-name"
      refute key =~ "nested"
    end

    test "drops unrecognized extensions instead of trusting caller input verbatim" do
      key = R2Storage.generate_object_key("payload.exe")
      refute String.ends_with?(key, ".exe")
    end

    test "produces a bare key with no extension when no source path is given" do
      key = R2Storage.generate_object_key()
      refute key =~ "."
    end

    test "carries real entropy, not a short or predictable token" do
      key = R2Storage.generate_object_key()
      # 24 random bytes, url-safe base64: real output is 32 chars. Assert a
      # floor rather than the exact constant so this doesn't over-couple to
      # the current byte count.
      assert String.length(key) >= 20
    end

    test "two keys generated for the exact same filename are always different" do
      keys = for _ <- 1..50, do: R2Storage.generate_object_key("same-name.png")
      assert keys |> Enum.uniq() |> length() == 50
    end
  end

  describe "get_presigned_url/1,2 — with configuration present" do
    test "returns a URL carrying a real AWS SigV4 expiry and signature" do
      with_fake_config(fn ->
        assert {:ok, url} = R2Storage.get_presigned_url("some-object-key")

        uri = URI.parse(url)
        query = URI.decode_query(uri.query || "")

        assert uri.scheme == "https"
        assert uri.host == "test-account-id.r2.cloudflarestorage.com"
        assert query["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
        # Default TTL is 15 minutes.
        assert query["X-Amz-Expires"] == "900"
        assert is_binary(query["X-Amz-Signature"]) and query["X-Amz-Signature"] != ""
        assert is_binary(query["X-Amz-Credential"]) and query["X-Amz-Credential"] != ""
        refute url =~ "/public/"
      end)
    end

    test "TTL is configurable per call" do
      with_fake_config(fn ->
        assert {:ok, url} = R2Storage.get_presigned_url("some-object-key", ttl: 42)
        query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
        assert query["X-Amz-Expires"] == "42"
      end)
    end
  end

  describe "fail closed — no R2 config and no R2_* env vars" do
    test "get_presigned_url/1 errors instead of ever returning an unsigned URL" do
      assert {:error, _reason} = R2Storage.get_presigned_url("some-object-key")
    end

    test "upload/2 errors instead of uploading unsigned" do
      assert {:error, _reason} = R2Storage.upload("/nonexistent/path.png", "whatever.png")
    end

    test "delete/1 errors" do
      assert {:error, _reason} = R2Storage.delete("some-object-key")
    end

    test "exists?/1 returns false — matches Vibe.SupabaseStorage.exists?/1's own shape — never raises" do
      refute R2Storage.exists?("some-object-key")
    end
  end

  describe "upload/2,3" do
    test "fails at the local file read, before any signing or network attempt, when the file is missing" do
      with_fake_config(fn ->
        assert {:error, reason} = R2Storage.upload("/no/such/file/on/disk.png", "whatever.png")
        assert reason =~ "Could not read file"
      end)
    end
  end

  describe "Vibe.Storage.backend/0" do
    test "defaults to :supabase when :vibe, :storage_backend is unset" do
      prev = Application.get_env(:vibe, :storage_backend)
      Application.delete_env(:vibe, :storage_backend)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:vibe, :storage_backend)
          value -> Application.put_env(:vibe, :storage_backend, value)
        end
      end)

      assert Storage.backend() == :supabase
    end

    test "only switches to :r2 when explicitly configured" do
      prev = Application.get_env(:vibe, :storage_backend)
      Application.put_env(:vibe, :storage_backend, :r2)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:vibe, :storage_backend)
          value -> Application.put_env(:vibe, :storage_backend, value)
        end
      end)

      assert Storage.backend() == :r2
    end

    test "forwards exists?/1 to the default (Supabase) backend without crashing when unconfigured" do
      refute Storage.exists?("whatever")
    end
  end
end
