defmodule VibeAgents.Tools.Browser do
  @moduledoc "browser_open / browser_act / browser_screenshot, via VibeAgents.Sandbox."
  require Logger
  alias VibeAgents.Runs.Events
  alias VibeAgents.Sandbox
  alias VibeAgents.Sandbox.Client

  @max_preview_bytes 200_000

  def browser_open(run, %{"url" => url}, _callback) when is_binary(url) do
    with {:ok, sandbox_id} <- ensure(run),
         {:ok, result} <- Client.browser_navigate(sandbox_id, %{"url" => url}) do
      %{"ok" => true, "url" => result["url"] || url, "title" => result["title"]}
    else
      {:error, reason} -> error_result(reason)
    end
  end

  def browser_open(_run, _input, _callback), do: %{"ok" => false, "error" => "url is required"}

  def browser_act(run, %{"kind" => kind} = input, _callback) when is_binary(kind) do
    body = %{
      "kind" => kind,
      "selector" => input["selector"],
      "text" => input["text"],
      "x" => input["x"],
      "y" => input["y"]
    }

    with {:ok, sandbox_id} <- ensure(run),
         {:ok, result} <- Client.browser_action(sandbox_id, body) do
      %{"ok" => result["ok"] != false, "url" => result["url"], "title" => result["title"]}
    else
      {:error, reason} -> error_result(reason)
    end
  end

  def browser_act(_run, _input, _callback), do: %{"ok" => false, "error" => "kind is required"}

  def browser_screenshot(run, _input, _callback) do
    with {:ok, sandbox_id} <- ensure(run),
         {:ok, %{"imageBase64" => image} = shot} <- Client.browser_screenshot(sandbox_id) do
      maybe_emit_preview(run, image, shot)
      %{"ok" => true, "mime" => shot["mime"] || "image/jpeg", "width" => shot["width"], "height" => shot["height"]}
    else
      {:error, reason} -> error_result(reason)
    end
  end

  defp maybe_emit_preview(run, image, shot) when byte_size(image) <= @max_preview_bytes do
    payload = %{
      "imageBase64" => image,
      "mime" => shot["mime"] || "image/jpeg",
      "width" => shot["width"],
      "height" => shot["height"],
      "label" => "Browser"
    }

    Events.emit(run, "run.preview", payload)
  end

  defp maybe_emit_preview(_run, image, _shot) do
    Logger.warning("[VibeAgents.Tools.Browser] screenshot #{byte_size(image)} bytes exceeds preview cap; skipped")
  end

  defp ensure(run) do
    case Sandbox.ensure_computer(run.agent_id, run.capabilities || %{}) do
      {:ok, %{sandbox_id: sandbox_id}} when is_binary(sandbox_id) -> {:ok, sandbox_id}
      {:ok, _computer} -> {:error, "sandbox has no id yet"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp error_result(:not_configured) do
    %{"ok" => false, "error" => "The browser is not available (sandbox gateway not configured)."}
  end

  defp error_result(reason), do: %{"ok" => false, "error" => "browser unavailable: #{inspect(reason)}"}
end
