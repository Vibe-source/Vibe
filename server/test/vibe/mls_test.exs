defmodule Vibe.MlsTest do
  @moduledoc """
  MLS KeyPackage publish/claim: round trip, single-use claiming, exhaustion,
  concurrent-claim atomicity, and publish scoping.
  """

  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Mls
  alias Vibe.Repo
  alias Vibe.Schemas.MlsKeyPackage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    user = insert_user("mls_owner")
    %{user: user}
  end

  test "publish then claim returns one of the published packages", %{user: user} do
    packages = for i <- 1..3, do: fake_key_package(i)

    assert {:ok, %{count: 3}} =
             Mls.publish_key_packages(user.id, %{
               "deviceId" => "device-a",
               "keyPackages" => packages
             })

    assert {:ok, claimed} = Mls.claim_key_package(user.id)
    assert claimed.device_id == "device-a"
    assert Base.encode64(claimed.key_package) in packages
    refute is_nil(claimed.claimed_at)
  end

  test "claiming twice never returns the same package", %{user: user} do
    packages = for i <- 1..2, do: fake_key_package(i)

    {:ok, _} =
      Mls.publish_key_packages(user.id, %{"deviceId" => "device-a", "keyPackages" => packages})

    assert {:ok, first} = Mls.claim_key_package(user.id)
    assert {:ok, second} = Mls.claim_key_package(user.id)

    refute first.id == second.id
    refute first.key_package == second.key_package

    # The first claim is durably marked claimed, not just absent from a cache.
    reloaded = Repo.get!(MlsKeyPackage, first.id)
    refute is_nil(reloaded.claimed_at)
  end

  test "claiming when none remain returns not-found, no crash", %{user: user} do
    assert {:error, :not_found} = Mls.claim_key_package(user.id)

    {:ok, _} =
      Mls.publish_key_packages(user.id, %{
        "deviceId" => "device-a",
        "keyPackages" => [fake_key_package(1)]
      })

    assert {:ok, _} = Mls.claim_key_package(user.id)
    # Drained again — still a clean not-found, not an error/crash.
    assert {:error, :not_found} = Mls.claim_key_package(user.id)
  end

  test "concurrency: N parallel claims hand out N distinct packages", %{user: user} do
    n = 20
    packages = for i <- 1..n, do: fake_key_package(i)

    {:ok, %{count: ^n}} =
      Mls.publish_key_packages(user.id, %{"deviceId" => "device-a", "keyPackages" => packages})

    # Shared mode lets the Task.async_stream workers below use the same
    # sandboxed connection as this test process without individually calling
    # Sandbox.allow/3 — this is what actually lets them race against the real
    # Repo instead of a mocked/serialized stand-in.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

    results =
      1..n
      |> Task.async_stream(fn _ -> Mls.claim_key_package(user.id) end,
        max_concurrency: n,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(results) == n
    assert Enum.all?(results, &match?({:ok, _}, &1))

    claimed_ids = Enum.map(results, fn {:ok, package} -> package.id end)
    claimed_bins = Enum.map(results, fn {:ok, package} -> package.key_package end)

    # This is the property the atomic UPDATE ... WHERE id IN (SELECT ... FOR
    # UPDATE SKIP LOCKED) exists to guarantee: N racing claims, N distinct
    # winners, nobody doubles up on somebody else's one-time init key.
    assert length(Enum.uniq(claimed_ids)) == n
    assert length(Enum.uniq(claimed_bins)) == n
    assert MapSet.new(claimed_bins) == MapSet.new(Enum.map(packages, &Base.decode64!/1))

    assert {:error, :not_found} = Mls.claim_key_package(user.id)
  end

  test "a user cannot publish on behalf of another user", %{user: user} do
    victim = insert_user("mls_victim")

    # Even if the request body smuggles another user's id, publish is always
    # scoped to the explicit (trusted) user_id argument — mirroring how the
    # controller only ever passes conn.assigns.current_user.id, never a
    # client-supplied "userId".
    assert {:ok, %{count: 1}} =
             Mls.publish_key_packages(user.id, %{
               "userId" => victim.id,
               "deviceId" => "attacker-device",
               "keyPackages" => [fake_key_package(1)]
             })

    assert Mls.count_available(user.id) == 1
    assert Mls.count_available(victim.id) == 0

    {:ok, claimed} = Mls.claim_key_package(user.id)
    assert claimed.device_id == "attacker-device"
    assert {:error, :not_found} = Mls.claim_key_package(victim.id)
  end

  test "an over-large batch is rejected outright, not truncated", %{user: user} do
    too_many = for i <- 1..101, do: fake_key_package(i)

    assert {:error, :batch_too_large} =
             Mls.publish_key_packages(user.id, %{
               "deviceId" => "device-a",
               "keyPackages" => too_many
             })

    # Rejected means nothing landed — not "the first 100 got in".
    assert Mls.count_available(user.id) == 0
  end

  test "rejects a non-base64 keyPackage entry", %{user: user} do
    assert {:error, :invalid_key_package_encoding} =
             Mls.publish_key_packages(user.id, %{
               "deviceId" => "device-a",
               "keyPackages" => ["not-valid-base64!!"]
             })

    assert Mls.count_available(user.id) == 0
  end

  test "rejects a missing or blank deviceId", %{user: user} do
    assert {:error, :invalid_device_id} =
             Mls.publish_key_packages(user.id, %{"keyPackages" => [fake_key_package(1)]})

    assert {:error, :invalid_device_id} =
             Mls.publish_key_packages(user.id, %{
               "deviceId" => "   ",
               "keyPackages" => [fake_key_package(1)]
             })
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp fake_key_package(label) do
    Base.encode64("mls-keypkg-#{label}-#{System.unique_integer([:positive])}")
  end

  # ── Welcome relay ──────────────────────────────────────────────────────
  #
  # A Welcome carries the group secrets for whoever it is addressed to, so the
  # authorization properties below are the whole point of this relay: serving
  # or letting someone ack another user's Welcome hands them the conversation.

  test "a welcome round-trips to its recipient", %{user: sender} do
    recipient = insert_user("mls_recipient")

    assert {:ok, _row} = post_welcome(sender.id, recipient.id, "chat-1")

    assert [pending] = Mls.pending_welcomes(recipient.id)
    assert pending.chat_id == "chat-1"
    assert pending.sender_user_id == sender.id
    assert pending.welcome == "welcome-bytes"
    assert pending.ratchet_tree == "tree-bytes"
  end

  test "a body-supplied senderUserId is ignored in favour of the authenticated user", %{
    user: sender
  } do
    recipient = insert_user("mls_recipient")
    impostor = insert_user("mls_impostor")

    {:ok, _} =
      Mls.post_welcome(sender.id, %{
        "recipientUserId" => recipient.id,
        "senderUserId" => impostor.id,
        "chatId" => "chat-1",
        "welcome" => Base.encode64("welcome-bytes")
      })

    assert [pending] = Mls.pending_welcomes(recipient.id)
    assert pending.sender_user_id == sender.id
  end

  test "one user cannot read another user's pending welcome", %{user: sender} do
    recipient = insert_user("mls_recipient")
    outsider = insert_user("mls_outsider")

    {:ok, _} = post_welcome(sender.id, recipient.id, "chat-1")

    assert [_one] = Mls.pending_welcomes(recipient.id)
    assert [] = Mls.pending_welcomes(outsider.id)
  end

  test "one user cannot ack another user's welcome", %{user: sender} do
    recipient = insert_user("mls_recipient")
    outsider = insert_user("mls_outsider")

    {:ok, row} = post_welcome(sender.id, recipient.id, "chat-1")

    assert {:error, :not_found} = Mls.ack_welcome(outsider.id, row.id)
    # Still pending for its real recipient — the failed ack changed nothing.
    assert [_one] = Mls.pending_welcomes(recipient.id)

    assert :ok = Mls.ack_welcome(recipient.id, row.id)
    assert [] = Mls.pending_welcomes(recipient.id)
  end

  test "acking twice is not an error the second time it is a miss", %{user: sender} do
    recipient = insert_user("mls_recipient")
    {:ok, row} = post_welcome(sender.id, recipient.id, "chat-1")

    assert :ok = Mls.ack_welcome(recipient.id, row.id)
    assert {:error, :not_found} = Mls.ack_welcome(recipient.id, row.id)
  end

  test "a malformed id is a miss rather than a crash", %{user: recipient} do
    assert {:error, :not_found} = Mls.ack_welcome(recipient.id, "not-a-uuid")
  end

  test "an oversize welcome is rejected rather than stored", %{user: sender} do
    recipient = insert_user("mls_recipient")

    oversize = Base.encode64(:crypto.strong_rand_bytes(256 * 1024 + 1))

    assert {:error, :too_large} =
             Mls.post_welcome(sender.id, %{
               "recipientUserId" => recipient.id,
               "chatId" => "chat-1",
               "welcome" => oversize
             })

    assert [] = Mls.pending_welcomes(recipient.id)
  end

  test "non-base64 welcome bytes are rejected", %{user: sender} do
    recipient = insert_user("mls_recipient")

    assert {:error, :invalid_encoding} =
             Mls.post_welcome(sender.id, %{
               "recipientUserId" => recipient.id,
               "chatId" => "chat-1",
               "welcome" => "!!!not base64!!!"
             })
  end

  test "one sender cannot pile up unlimited welcomes for one recipient", %{user: sender} do
    recipient = insert_user("mls_recipient")

    for i <- 1..20 do
      assert {:ok, _} = post_welcome(sender.id, recipient.id, "chat-#{i}")
    end

    assert {:error, :too_many_pending} = post_welcome(sender.id, recipient.id, "chat-21")

    # The cap is per sender, so an unrelated sender is unaffected.
    other_sender = insert_user("mls_other_sender")
    assert {:ok, _} = post_welcome(other_sender.id, recipient.id, "chat-22")
  end

  defp post_welcome(sender_id, recipient_id, chat_id) do
    Mls.post_welcome(sender_id, %{
      "recipientUserId" => recipient_id,
      "chatId" => chat_id,
      "welcome" => Base.encode64("welcome-bytes"),
      "ratchetTree" => Base.encode64("tree-bytes")
    })
  end

  defp insert_user(prefix) do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      id: Ecto.UUID.generate(),
      username: "#{prefix}_#{suffix}",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      is_agent: false
    })
  end
end
