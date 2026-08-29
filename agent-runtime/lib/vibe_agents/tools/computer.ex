defmodule VibeAgents.Tools.Computer do
  @moduledoc "computer_run / computer_read_file / computer_write_file, via VibeAgents.Sandbox."
  alias VibeAgents.Sandbox
  alias VibeAgents.Sandbox.Client

  @max_timeout_ms 240_000
  @max_output_chars 16_000

  def computer_run(run, %{"command" => command} = input) when is_binary(command) do
    if String.trim(command) == "" do
      %{"ok" => false, "error" => "command is required"}
    else
      with {:ok, sandbox_id} <- ensure(run) do
        body = %{
          "cmd" => ["bash", "-lc", command],
          "cwd" => input["cwd"],
          "timeoutMs" => timeout_ms(input),
          "maxOutputBytes" => @max_output_chars * 4
        }

        case Client.exec(sandbox_id, body) do
          {:ok, result} ->
            %{
              "ok" => true,
              "exitCode" => result["exitCode"],
              "stdout" => truncate(result["stdout"]),
              "stderr" => truncate(result["stderr"]),
              "truncated" => result["truncated"] || false,
              "durationMs" => result["durationMs"]
            }

          {:error, reason} ->
            %{"ok" => false, "error" => "computer_run failed: #{inspect(reason)}"}
        end
      else
        {:error, reason} -> error_result(reason)
      end
    end
  end

  def computer_run(_run, _input), do: %{"ok" => false, "error" => "command is required"}

  def computer_read_file(run, %{"path" => path}) when is_binary(path) do
    with {:ok, sandbox_id} <- ensure(run) do
      case Client.read_file(sandbox_id, path) do
        {:ok, %{"contentBase64" => content} = result} -> %{"ok" => true, "path" => path, "contentBase64" => content, "bytes" => result["bytes"]}
        {:error, reason} -> %{"ok" => false, "error" => "could not read #{path}: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> error_result(reason)
    end
  end

  def computer_read_file(_run, _input), do: %{"ok" => false, "error" => "path is required"}

  def computer_write_file(run, %{"path" => path, "content" => content}) when is_binary(path) and is_binary(content) do
    with {:ok, sandbox_id} <- ensure(run) do
      case Client.write_file(sandbox_id, %{"path" => path, "contentBase64" => Base.encode64(content)}) do
        {:ok, result} -> %{"ok" => true, "path" => path, "bytes" => result["bytes"]}
        {:error, reason} -> %{"ok" => false, "error" => "could not write #{path}: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> error_result(reason)
    end
  end

  def computer_write_file(_run, _input), do: %{"ok" => false, "error" => "path and content are required"}

  defp ensure(run) do
    case Sandbox.ensure_computer(run.agent_id, run.capabilities || %{}) do
      {:ok, %{sandbox_id: sandbox_id}} when is_binary(sandbox_id) -> {:ok, sandbox_id}
      {:ok, _computer} -> {:error, "sandbox has no id yet"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp timeout_ms(input) do
    case input["timeoutMs"] do
      value when is_integer(value) and value > 0 -> min(value, @max_timeout_ms)
      _ -> 60_000
    end
  end

  defp truncate(text) when is_binary(text) do
    if String.length(text) > @max_output_chars, do: String.slice(text, 0, @max_output_chars) <> "\n... [truncated]", else: text
  end

  defp truncate(_text), do: ""

  defp error_result(:not_configured) do
    %{"ok" => false, "error" => "The computer is not available (sandbox gateway not configured)."}
  end

  defp error_result(reason), do: %{"ok" => false, "error" => "computer unavailable: #{inspect(reason)}"}
end
