defmodule Vibe.AgentPostModeTest do
  @moduledoc """
  `responseMode: "post"` — deliver the caller's words, run no model.

  Why this exists: an agix alerting hook posted through `send`, and when the account's
  model credit ran out every alert stopped arriving. The API was up, the secret valid, the
  agent published and attached to the chat — and `generate_outputs` failed, so the whole
  request came back `422 request_failed`. A notification channel that goes down because a
  language model is unavailable fails at exactly the moment it is needed.

  These tests hold the two properties that make `post` worth having: the text arrives
  unchanged, and nothing in the path can ask a model. They do not stub the model — the test
  environment has no provider configured, so a `post` that reached generation would fail
  here for the same reason it failed in production. That is the point: this passing *is* the
  proof that generation was skipped.
  """
  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.AI.StandaloneAgent
  alias Vibe.Chat
  alias Vibe.Repo

  setup context do
    if context[:db] do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      owner = insert_user("post_owner")
      agent = insert_agent(owner)
      chat_id = Ecto.UUID.generate()
      {:ok, _} = Chat.create_chat(chat_id, [owner.id, agent.agent_user_id])

      %{owner: owner, agent: agent, chat_id: chat_id}
    else
      :ok
    end
  end

  @tag :db
  test "post delivers the caller's own words without asking a model", %{
    agent: agent,
    chat_id: chat_id
  } do
    said = "[agix] auth.lockout\n\n20 bad credentials from 203.0.113.7"

    assert {:ok, result} =
             StandaloneAgent.invoke(agent, %{
               "message" => said,
               "responseMode" => "post",
               "vibeChatId" => chat_id
             })

    # One output, and it is the text that went in. Not summarised, not rewritten: an alert
    # that a model has had an opinion about is no longer the alert.
    assert [output] = result.outputs
    assert output_text(output) == said

    # And it actually landed in the chat, rather than being handed back to the caller the
    # way `reply` does — an empty list here is the silent failure this mode exists to avoid.
    assert result.vibe_deliveries != []
  end

  @tag :db
  test "post still refuses what send refuses — it skips generation, not authorisation", %{
    agent: agent,
    chat_id: chat_id,
    owner: owner
  } do
    # No chat named.
    assert {:error, :missing_chat_id} =
             StandaloneAgent.invoke(agent, %{"message" => "hi", "responseMode" => "post"})

    # A chat this agent is not in. Somebody holding a valid agent secret must not be able to
    # post into arbitrary conversations by choosing a different mode.
    stranger = Ecto.UUID.generate()
    {:ok, _} = Chat.create_chat(stranger, [owner.id])

    assert {:error, :chat_not_attached} =
             StandaloneAgent.invoke(agent, %{
               "message" => "hi",
               "responseMode" => "post",
               "vibeChatId" => stranger
             })

    # An unpublished agent, which is the other half of the same boundary.
    draft = agent |> Ecto.Changeset.change(status: "draft") |> Repo.update!()

    assert {:error, :agent_unavailable} =
             StandaloneAgent.invoke(draft, %{
               "message" => "hi",
               "responseMode" => "post",
               "vibeChatId" => chat_id
             })
  end

  @tag :db
  test "an unknown mode is still reply, so an old client cannot post by accident", %{
    agent: agent,
    chat_id: chat_id
  } do
    # `reply` generates, and this environment has no provider, so it fails. What matters is
    # that it did *not* quietly deliver: a mode nobody recognises must never post.
    before = message_count(chat_id)

    StandaloneAgent.invoke(agent, %{
      "message" => "hi",
      "responseMode" => "somethingelse",
      "vibeChatId" => chat_id
    })

    assert message_count(chat_id) == before
  end

  defp output_text(output) do
    Map.get(output, :text) || Map.get(output, "text")
  end

  defp message_count(chat_id) do
    import Ecto.Query
    Repo.aggregate(from(m in "messages", where: m.chat_id == ^chat_id), :count)
  rescue
    _ -> 0
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

  defp insert_agent(owner) do
    shadow = insert_user("post_agent_shadow")

    shadow
    |> Ecto.Changeset.change(is_agent: true)
    |> Repo.update!()

    %Agent{
      owner_user_id: owner.id,
      agent_user_id: shadow.id,
      status: "published",
      display_name: "Post Agent",
      system_prompt: "Help the user.",
      enabled_tools: [],
      output_modes: ["text"],
      webhook_secret_hash: "hash",
      secret_hint: "hint"
    }
    |> Repo.insert!()
    |> Repo.preload(:agent_user)
  end
end
