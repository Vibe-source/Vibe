defmodule VibeWeb.AuthController do
  use VibeWeb, :controller
  import Ecto.Query, warn: false
  require Logger
  alias Vibe.Accounts
  alias Vibe.Accounts.User

  # SECURITY: PBKDF2 iteration count - OWASP 2023 recommends 600,000 for SHA512
  @pbkdf2_iterations 600_000

  # SECURITY: Token validity period (30 days in seconds)
  @token_validity_seconds 30 * 24 * 60 * 60

  # SECURITY: `VIBE_HMAC_SECRET` is a server-side pepper used for deriving `secure_id`.
  # It must be set in production. If you need to rotate it, set `VIBE_HMAC_SECRET_LEGACY`
  # to the previous value to preserve existing secure-id logins.

  def register(conn, %{"username" => username, "password" => password, "deviceId" => device_id} = params) do
    # Input Validation
    username = username |> to_string() |> String.trim()
    password = to_string(password)
    normalized_phone = Accounts.normalize_phone_number(params["phoneNumber"])

    cond do
      String.length(username) < 3 ->
        conn |> put_status(400) |> json(%{error: "Username must be at least 3 characters"})

      String.length(username) > 30 ->
        conn |> put_status(400) |> json(%{error: "Username must be 30 characters or less"})

      not Regex.match?(~r/^[a-zA-Z0-9_]+$/, username) ->
        conn |> put_status(400) |> json(%{error: "Username can only contain letters, numbers, and underscores"})

      Accounts.reserved_username?(username) ->
        conn |> put_status(409) |> json(%{error: "Username taken"})

      String.length(password) < 8 ->
        conn |> put_status(400) |> json(%{error: "Password must be at least 8 characters"})

      Accounts.username_exists?(username) ->
        conn |> put_status(409) |> json(%{error: "Username taken"})

      params["phoneNumber"] && is_nil(normalized_phone) ->
        conn |> put_status(400) |> json(%{error: "Invalid phone number format"})

      normalized_phone && Accounts.get_user_by_phone(normalized_phone) ->
        conn |> put_status(409) |> json(%{error: "Phone number already in use"})

      true ->
        # SECURITY: Password hashing with proper iterations
        salt = :crypto.strong_rand_bytes(16)
        derived_bin = :crypto.pbkdf2_hmac(:sha512, password, salt, @pbkdf2_iterations, 64)
        password_hash = Base.encode16(salt, case: :lower) <> ":" <> Base.encode16(derived_bin, case: :lower)

        user_id = UUID.uuid4()

        # SECURITY: Use HMAC instead of plain SHA256 for secure_id
        # This prevents rainbow table attacks even if the database leaks
        #
        # v3 clients send a `credential` that is a one-way HKDF derivation of the
        # user's recovery secret, and a `password` that is a *different* one-way
        # derivation of it. The raw recovery secret — which is also the passphrase
        # wrapping `encrypted_private_key` — never reaches this server at all.
        # Pre-v3 clients send no `credential`, and for them `password` *is* the
        # raw secret, so it stays the lookup handle. See `upgrade_identity/2`.
        lookup_value = present_credential(params["credential"]) || password
        secure_id = secure_id_for(hmac_secret!(), lookup_value)

        # SECURITY: Token with expiration
        login_token = UUID.uuid4()
        token_expires_at = DateTime.utc_now() |> DateTime.add(@token_validity_seconds, :second)

        # SECURITY: Require client-side key generation for v2+ clients
        # Server should NEVER generate private keys - defeats E2E encryption
        identity_version = params["identityKey"] || "v1"

        {public_key, encrypted_private_key} =
          cond do
            # V2/V3: Client must provide keys (secure E2E)
            identity_version in ["v2", "v3"] && params["publicKey"] &&
                params["encryptedPrivateKey"] ->
              {params["publicKey"], params["encryptedPrivateKey"]}

            # V1 Legacy: Client provides keys (backward compatible)
            params["publicKey"] && params["encryptedPrivateKey"] ->
              {params["publicKey"], params["encryptedPrivateKey"]}



            # V2+ without keys: Reject (security requirement)
            true ->
              conn |> put_status(400) |> json(%{error: "Client must provide publicKey and encryptedPrivateKey for E2E encryption"})
              {:error, :missing_keys}
          end

        case {public_key, encrypted_private_key} do
          {:error, _} ->
            # Already sent error response above
            conn

          {pub_key, enc_priv_key} ->
            user_params = %{
              "id" => user_id,
              "username" => username,
              "password_hash" => password_hash,
              "device_id" => device_id,
              "public_key" => pub_key,
              "encrypted_private_key" => enc_priv_key,
              "identity_key" => identity_version,
              "secure_id" => secure_id,
              "login_token" => login_token,
              "token_expires_at" => token_expires_at,
              "phone_number" => normalized_phone
            }

            case Accounts.create_user(user_params) do
              {:ok, user} ->
                json(conn, %{
                  userId: user.id,
                  username: user.username,
                  secureId: user.secure_id,
                  token: user.login_token,
                  tokenExpiresAt: DateTime.to_iso8601(token_expires_at),
                  publicKey: user.public_key,
                  encryptedPrivateKey: user.encrypted_private_key,
                  phoneNumber: user.phone_number
                })
              {:error, changeset} ->
                errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
                  Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
                    opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
                  end)
                end)
                conn |> put_status(400) |> json(%{error: "Validation failed", details: errors})
            end
        end
    end
  end

  def login(conn, %{"credential" => credential, "password" => password}) do
    credential = credential |> to_string() |> String.trim()
    password = to_string(password)

    user =
      Accounts.get_user_by_username(credential) ||
        Accounts.get_user_by_phone(credential) ||
        get_user_by_secure_id(credential)

    case user do
      nil ->
        # SECURITY: Use consistent error message to prevent user enumeration
        conn |> put_status(401) |> json(%{error: "Invalid credentials"})

      %User{is_agent: true} ->
        conn |> put_status(401) |> json(%{error: "Invalid credentials"})

      %User{} = u ->
        case Accounts.verify_password_with_info(password, u.password_hash) do
          {:ok, :current} ->
            issue_login_response(conn, u)

          {:ok, :legacy} ->
            user_for_login =
              case Accounts.upgrade_password_hash(u, password) do
                {:ok, upgraded_user} -> upgraded_user
                _ -> u
              end

            issue_login_response(conn, user_for_login)

          :error ->
            # SECURITY: Use consistent error message to prevent user enumeration
            conn |> put_status(401) |> json(%{error: "Invalid credentials"})
        end
    end
  end

  @doc """
  Re-keys a pre-v3 account onto one-way-derived credentials.

  Before v3 the client sent the user's recovery secret here verbatim, as both the
  login `credential` and the `password` — while that same secret is the PBKDF2
  passphrase wrapping `encrypted_private_key`, a copy of which this server
  stores. Every login therefore handed us both halves: enough to unwrap the
  user's private key and read their entire history. That made the product's
  end-to-end encryption nominal. This endpoint rotates such an account so it
  stops being true, after which the raw secret is never transmitted again.

  It deliberately does **not** touch `encrypted_private_key`. The client's KEK
  derivation is unchanged, so there is nothing to re-wrap — and that is what
  makes this migration non-destructive. The worst outcome of a failure here is a
  login that falls back to the legacy path again, never unreadable key material.

  Authenticated by the bearer token issued moments earlier by `login/2`, so only
  a caller who already proved possession of the old secret can rotate it.
  """
  def upgrade_identity(conn, params) do
    user = conn.assigns.current_user

    with credential when is_binary(credential) <- present_credential(params["credential"]),
         password when is_binary(password) <- present_credential(params["password"]) do
      salt = :crypto.strong_rand_bytes(16)
      derived_bin = :crypto.pbkdf2_hmac(:sha512, password, salt, @pbkdf2_iterations, 64)

      password_hash =
        Base.encode16(salt, case: :lower) <> ":" <> Base.encode16(derived_bin, case: :lower)

      # `secure_id` is the account's lookup handle and is derived from whatever
      # the client will send as `credential` at the next login, so it has to
      # rotate in lockstep with `password_hash`. The client is handed the new
      # value back because it cannot recompute it — the pepper is server-side.
      case Accounts.update_user(user, %{
             "password_hash" => password_hash,
             "secure_id" => secure_id_for(hmac_secret!(), credential),
             "identity_key" => "v3"
           }) do
        {:ok, updated_user} ->
          Logger.info("[Auth] identity upgraded to v3 user_id=#{updated_user.id}")
          json(conn, %{ok: true, secureId: updated_user.secure_id, identityKey: "v3"})

        {:error, _changeset} ->
          conn |> put_status(500) |> json(%{error: "Identity upgrade failed"})
      end
    else
      _ ->
        conn |> put_status(400) |> json(%{error: "credential and password are required"})
    end
  end

  defp present_credential(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_credential(_), do: nil

  defp issue_login_response(conn, %User{} = user) do
    # SECURITY: Generate new token on each login and set expiration
    new_token = UUID.uuid4()
    token_expires_at = DateTime.utc_now() |> DateTime.add(@token_validity_seconds, :second)

    case Accounts.update_user(user, %{
           "login_token" => new_token,
           "token_expires_at" => token_expires_at
         }) do
      {:ok, updated_user} ->
        json(conn, %{
          userId: updated_user.id,
          username: updated_user.username,
          secureId: updated_user.secure_id,
          token: new_token,
          tokenExpiresAt: DateTime.to_iso8601(token_expires_at),
          publicKey: updated_user.public_key,
          encryptedPrivateKey: updated_user.encrypted_private_key,
          phoneNumber: updated_user.phone_number
        })

      {:error, _} ->
        conn |> put_status(500) |> json(%{error: "Failed to issue session token"})
    end
  end

  defp hmac_secret! do
    System.get_env("VIBE_HMAC_SECRET")
    |> normalize_secret()
    |> case do
      nil ->
        raise "VIBE_HMAC_SECRET not set"

      secret ->
        secret
    end
  end

  defp legacy_hmac_secret do
    System.get_env("VIBE_HMAC_SECRET_LEGACY")
    |> normalize_secret()
  end

  defp normalize_secret(nil), do: nil

  defp normalize_secret(secret) when is_binary(secret) do
    secret = String.trim(secret)
    if secret == "", do: nil, else: secret
  end

  defp secure_id_candidates(value) when is_binary(value) do
    [hmac_secret!(), legacy_hmac_secret()]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&secure_id_for(&1, value))
  end

  defp get_user_by_secure_id(credential) do
    secure_hashes = secure_id_candidates(credential)

    Vibe.Repo.one(
      from u in User,
        where: u.secure_id in ^secure_hashes,
        limit: 1
    )
  end

  defp secure_id_for(secret, value) when is_binary(secret) and is_binary(value) do
    :crypto.mac(:hmac, :sha256, secret, value)
    |> Base.encode16(case: :upper)
  end
end
