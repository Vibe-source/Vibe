defmodule VibeAgents.Test.FakeSandboxHTTP do
  @moduledoc "Stand-in for `VibeAgents.Sandbox.Client.Finch` (config `:sandbox_http`)."

  def request(:post, url, body, _headers, _timeout) do
    cond do
      String.ends_with?(url, "/v1/sandboxes") ->
        {:ok, %{"id" => "vibe-sb-test", "status" => "running", "createdAt" => 0}}

      String.contains?(url, "/exec") ->
        {:ok, %{"exitCode" => 0, "stdout" => "ran: #{body["cmd"] |> List.wrap() |> Enum.join(" ")}", "stderr" => "", "truncated" => false, "durationMs" => 1}}

      true ->
        {:ok, %{"ok" => true}}
    end
  end

  def request(_method, _url, _body, _headers, _timeout), do: {:ok, %{"ok" => true}}
end
