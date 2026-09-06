defmodule VibeWeb.BridgeStatusPushTest do
  @moduledoc """
  The phone stopped polling `/api/agent-bridge/status`; it now learns about its
  computer from a `bridge-status` push that `UserChannel` emits whenever Presence
  changes on the `bridge:<user_id>` topic.

  These tests pin the mechanism that makes that possible: that subscribing to the
  bridge topic really does deliver a `presence_diff` for a computer joining AND
  for one that merely updates its metadata (repos / running tasks). If Presence
  ever stopped emitting the metadata-update diff, the phone would silently go back
  to never seeing a task start.
  """
  use ExUnit.Case, async: true

  alias Vibe.AgentBridge
  alias VibeWeb.Presence

  defp unique_user_id, do: "push-test-#{System.unique_integer([:positive])}"

  defp track(topic, key, meta) do
    # Track from a throwaway process so each test's presence dies with it.
    owner = self()

    pid =
      spawn(fn ->
        {:ok, _ref} = Presence.track(self(), topic, key, meta)
        send(owner, :tracked)
        receive do: (:stop -> :ok)
      end)

    assert_receive :tracked, 2_000
    pid
  end

  test "a computer coming online emits a diff on the bridge topic" do
    user_id = unique_user_id()
    topic = AgentBridge.topic(user_id)
    :ok = Phoenix.PubSub.subscribe(Vibe.PubSub, topic)

    pid = track(topic, "computer-1", %{"deviceLabel" => "Mac", "repositories" => []})

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "presence_diff"}, 2_000

    send(pid, :stop)
  end

  test "a metadata update emits a diff too — this is how a task start reaches the phone" do
    user_id = unique_user_id()
    topic = AgentBridge.topic(user_id)

    owner = self()

    pid =
      spawn(fn ->
        {:ok, _} = Presence.track(self(), topic, "computer-1", %{"deviceLabel" => "Mac"})
        send(owner, :tracked)

        receive do
          :update ->
            {:ok, _} =
              Presence.update(self(), topic, "computer-1", %{
                "deviceLabel" => "Mac",
                "runningTasks" => [%{"taskId" => "t-1", "provider" => "claude"}]
              })

            send(owner, :updated)
            receive do: (:stop -> :ok)
        end
      end)

    assert_receive :tracked, 2_000

    # Subscribe only now, so the diff we assert on is the *update*, not the join.
    :ok = Phoenix.PubSub.subscribe(Vibe.PubSub, topic)
    send(pid, :update)
    assert_receive :updated, 2_000

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "presence_diff"}, 2_000

    send(pid, :stop)
  end

  test "status_for_push reports the connected computer and its running tasks" do
    user_id = unique_user_id()
    topic = AgentBridge.topic(user_id)

    pid =
      track(topic, "computer-1", %{
        "deviceLabel" => "Mac",
        "computerId" => "computer-1",
        "repositories" => [%{"name" => "Vibe", "path" => "/Users/x/Vibe"}],
        "runningTasks" => [%{"taskId" => "t-1", "provider" => "claude"}]
      })

    status = AgentBridge.status_for_push(user_id)

    assert status.connected
    # A live bridge channel only exists behind an accepted pairing, so the
    # connected path asserts paired without spending a DB round trip.
    assert status.paired
    assert [%{"taskId" => "t-1"}] = status.runningTasks
    assert length(status.repositories) == 1

    send(pid, :stop)
  end

  test "an unknown user with no computer reports disconnected and unpaired" do
    status = AgentBridge.status_for_push(Ecto.UUID.generate())

    refute status.connected
    refute status.paired
    assert status.runningTasks == []
    assert status.repositories == []
  end

  # `status_for_push` runs inside UserChannel on every bridge Presence change, so it
  # must never raise: an exception there kills the phone's channel and disconnects it.
  # A non-UUID id cannot be cast to :binary_id and used to blow up the `paired?` query.
  test "a malformed user id degrades to disconnected instead of crashing the channel" do
    status = AgentBridge.status_for_push("not-a-uuid")

    refute status.connected
    refute status.paired
  end
end
