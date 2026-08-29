defmodule VibeAgents.Sandbox do
  @moduledoc "One sandbox per agent, lazily created through the gateway (spec §3.6)."
  alias VibeAgents.Repo
  alias VibeAgents.Sandbox.Client
  alias VibeAgents.Schemas.AgentComputer

  @default_image "vibe-sandbox:latest"

  @doc "Creates (or reuses) the one sandbox for `agent_id`. {:error, :not_configured} when the gateway is unset."
  def ensure_computer(agent_id, capabilities \\ %{}) do
    cond do
      not Client.configured?() ->
        {:error, :not_configured}

      true ->
        case Repo.get_by(AgentComputer, agent_id: agent_id) do
          %AgentComputer{sandbox_id: sandbox_id, status: "running"} = computer when is_binary(sandbox_id) ->
            touch(computer)

          existing ->
            create(agent_id, capabilities, existing)
        end
    end
  end

  defp create(agent_id, capabilities, existing) do
    network = if (capabilities["network"] || capabilities[:network]) == "none", do: "none", else: "proxy"
    owner_key = "agent:#{agent_id}"

    case Client.create_sandbox(%{"ownerKey" => owner_key, "image" => @default_image, "network" => network}) do
      {:ok, %{"id" => sandbox_id, "status" => status}} ->
        record = existing || %AgentComputer{}

        record
        |> AgentComputer.changeset(%{
          agent_id: agent_id,
          sandbox_id: sandbox_id,
          status: status || "running",
          image: @default_image,
          last_used_at: DateTime.utc_now()
        })
        |> Repo.insert_or_update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp touch(computer) do
    computer |> AgentComputer.changeset(%{last_used_at: DateTime.utc_now()}) |> Repo.update()
  end

  @doc "Stops and forgets the sandbox for `agent_id`."
  def destroy(agent_id) do
    case Repo.get_by(AgentComputer, agent_id: agent_id) do
      nil ->
        {:ok, :none}

      %AgentComputer{sandbox_id: nil} = computer ->
        computer |> AgentComputer.changeset(%{status: "none"}) |> Repo.update()

      %AgentComputer{sandbox_id: sandbox_id} = computer ->
        Client.delete(sandbox_id)
        computer |> AgentComputer.changeset(%{status: "none", sandbox_id: nil}) |> Repo.update()
    end
  end

  @doc "Latest screenshot from this agent's sandboxed browser, downscaled by the gateway."
  def preview(agent_id) do
    with %AgentComputer{sandbox_id: sandbox_id} when is_binary(sandbox_id) <- Repo.get_by(AgentComputer, agent_id: agent_id),
         {:ok, %{"imageBase64" => image} = shot} <- Client.browser_screenshot(sandbox_id) do
      {:ok,
       %{
         "imageBase64" => image,
         "mime" => shot["mime"] || "image/jpeg",
         "width" => shot["width"],
         "height" => shot["height"],
         "capturedAt" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    else
      nil -> {:error, :not_available}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_available}
    end
  end

  def sandbox_id_for(agent_id) do
    case Repo.get_by(AgentComputer, agent_id: agent_id) do
      %AgentComputer{sandbox_id: sandbox_id} -> sandbox_id
      nil -> nil
    end
  end
end
