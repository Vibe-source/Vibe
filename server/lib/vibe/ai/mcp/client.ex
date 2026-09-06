defmodule Vibe.AI.MCP.Client do
  @moduledoc """
  Minimal MCP client speaking JSON-RPC 2.0 over the Streamable HTTP transport.

  Only three methods matter to us: `initialize`, `tools/list`, `tools/call`.
  We do not open the optional server→client SSE stream — nothing in the agent
  loop consumes server-initiated messages, and an idle long-poll per agent per
  server is a socket we would be holding for nothing.

  Stateless by choice. We never send `Mcp-Session-Id`, so a server restart or a
  second instance behind a load balancer cannot strand a conversation
  mid-turn. Servers that *require* sessions will say so and are unsupported;
  that is a deliberate trade for operational simplicity.

  Servers may answer with `application/json` or with a one-shot
  `text/event-stream`. Both are legal, so both are parsed here — a server that
  streams its single response should not look like an outage.
  """

  require Logger

  alias Vibe.Net.SafeURL

  @protocol_version "2025-06-18"
  @client_info %{"name" => "vibe", "version" => "1.0.0"}
  @default_timeout_ms 20_000
  @max_timeout_ms 60_000
  # One MCP response carrying a document. Anything past this is not a
  # document, it is someone trying to exhaust the node.
  @max_response_bytes 32 * 1024 * 1024
  # Server-supplied text lands in the system prompt, so it is bounded.
  @max_instructions_chars 4_000

  @doc """
  Handshake. Returns the server's own description of itself, including the
  `instructions` string — which is how a server teaches the agent to use it
  without anyone hand-writing that into an agent prompt.
  """
  def initialize(server) do
    params = %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => @client_info
    }

    with {:ok, result} <- request(server, "initialize", params) do
      {:ok,
       %{
         protocol_version: result["protocolVersion"],
         server_info: result["serverInfo"] || %{},
         instructions: bounded_instructions(result["instructions"]),
         capabilities: result["capabilities"] || %{}
       }}
    end
  end

  @doc "Lists the tools a server exposes, with their JSON Schemas."
  def list_tools(server) do
    with {:ok, result} <- request(server, "tools/list", %{}) do
      tools =
        result
        |> Map.get("tools", [])
        |> Enum.map(fn tool ->
          %{
            name: tool["name"],
            description: tool["description"],
            input_schema: tool["inputSchema"] || %{"type" => "object"}
          }
        end)
        |> Enum.reject(&(&1.name in [nil, ""]))

      {:ok, tools}
    end
  end

  @doc """
  Invokes one tool.

  A tool that fails is not a transport failure: MCP reports it as a normal
  result carrying `isError: true`, so the model can read the message and pick
  a different move. We preserve that distinction — `{:ok, %{is_error: true}}`
  means "the tool said no", `{:error, reason}` means "we never reached it".
  """
  def call_tool(server, tool_name, arguments) do
    params = %{"name" => tool_name, "arguments" => arguments || %{}}

    with {:ok, result} <- request(server, "tools/call", params) do
      {:ok,
       %{
         content: List.wrap(result["content"]),
         structured: result["structuredContent"],
         is_error: result["isError"] == true
       }}
    end
  end

  @doc "Validates a server URL the same way any other outbound config is validated."
  def validate_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        {:ok, String.trim(url)}

      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1", "::1"] ->
        {:ok, String.trim(url)}

      %URI{scheme: "http"} = uri ->
        # Plain HTTP to anywhere else would put a super-admin bearer token on
        # the wire in clear text. Local dev is the only case worth allowing.
        case SafeURL.validate(URI.to_string(uri)) do
          {:ok, _} -> {:error, :insecure_scheme}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  def validate_url(_url), do: {:error, :invalid_url}

  defp request(server, method, params) do
    with {:ok, url} <- validate_url(server.url),
         :ok <- guard_host(url) do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => System.unique_integer([:positive]),
          "method" => method,
          "params" => params
        })

      headers =
        [
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"},
          {"mcp-protocol-version", @protocol_version}
        ] ++ auth_headers(server)

      request = Finch.build(:post, url, headers, body)

      case bounded_request(request, timeout_ms(server)) do
        {:ok, status, resp_headers, raw} when status in 200..299 ->
          decode_rpc(raw, resp_headers)

        {:ok, 401, _headers, _raw} ->
          {:error, :unauthorized}

        {:ok, status, _headers, raw} ->
          Logger.warning("[MCP] #{server.name} #{method} http_status=#{status}")
          {:error, {:http_error, status, truncate(raw)}}

        {:error, :response_too_large} ->
          Logger.warning("[MCP] #{server.name} #{method} response exceeded #{@max_response_bytes} bytes")
          {:error, :response_too_large}

        {:error, reason} ->
          Logger.warning("[MCP] #{server.name} #{method} failed reason=#{inspect(reason)}")
          {:error, {:request_failed, reason}}
      end
    end
  end

  # `Finch.request/3` buffers the whole body with no ceiling, so a hostile or
  # broken server could answer a 200-byte request with gigabytes and take the
  # node down with it. Streaming lets us stop reading the moment the body
  # passes what any legitimate MCP response could need.
  defp bounded_request(request, timeout) do
    acc = %{status: nil, headers: [], body: [], size: 0}

    result =
      Finch.stream(request, Vibe.Finch, acc, &collect/2, receive_timeout: timeout)

    case result do
      {:ok, %{status: status, headers: headers, body: chunks}} ->
        {:ok, status, headers, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, %{__struct__: _} = error} ->
        if Map.get(error, :reason) == :response_too_large do
          {:error, :response_too_large}
        else
          {:error, error}
        end

      {:error, :response_too_large} ->
        {:error, :response_too_large}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :throw, :response_too_large -> {:error, :response_too_large}
  end

  defp collect({:status, status}, acc), do: %{acc | status: status}
  defp collect({:headers, headers}, acc), do: %{acc | headers: acc.headers ++ headers}

  defp collect({:data, chunk}, acc) do
    size = acc.size + byte_size(chunk)

    if size > @max_response_bytes do
      throw(:response_too_large)
    end

    %{acc | body: [chunk | acc.body], size: size}
  end

  defp collect(_other, acc), do: acc

  # An https URL can still resolve to 169.254.169.254 or a private range, so
  # the host is checked, not just the scheme.
  #
  # Loopback is the one exception, and only because `validate_url/1` already
  # refused to reach it over anything but a literal localhost host — that is
  # the local-development server, not an SSRF target reached through DNS.
  defp guard_host(url) do
    if loopback?(url) do
      :ok
    else
      case SafeURL.validate(url) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp loopback?(url) do
    case URI.parse(url) do
      %URI{host: host} -> host in ["localhost", "127.0.0.1", "::1"]
      _ -> false
    end
  end

  defp decode_rpc(raw, headers) do
    payload =
      if event_stream?(headers) do
        extract_sse_json(raw)
      else
        raw
      end

    case Jason.decode(payload) do
      {:ok, %{"error" => %{"message" => message, "code" => code}}} ->
        {:error, {:rpc_error, code, message}}

      {:ok, %{"result" => result}} ->
        {:ok, result}

      {:ok, other} ->
        {:error, {:unexpected_payload, truncate(inspect(other))}}

      {:error, _} ->
        {:error, {:invalid_json, truncate(payload)}}
    end
  end

  defp event_stream?(headers) do
    Enum.any?(headers, fn {k, v} ->
      String.downcase(k) == "content-type" and String.contains?(String.downcase(v), "text/event-stream")
    end)
  end

  # A one-shot SSE body: take the last `data:` payload, which is the response.
  defp extract_sse_json(raw) do
    raw
    |> String.split(~r/\r?\n/)
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(&(&1 |> String.replace_prefix("data:", "") |> String.trim()))
    |> List.last()
    |> case do
      nil -> raw
      data -> data
    end
  end

  # Header names and values come from operator config. A newline in either
  # would split the request and let a crafted config forge extra headers.
  defp auth_headers(server) do
    server
    |> Map.get(:headers, %{})
    |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
    |> Enum.filter(fn {k, v} -> safe_header?(k) and safe_header?(v) end)
  end

  defp safe_header?(value) do
    value != "" and not String.match?(value, ~r/[\x00-\x1f\x7f]/)
  end

  defp timeout_ms(server) do
    server
    |> Map.get(:timeout_ms)
    |> case do
      value when is_integer(value) -> value |> max(1_000) |> min(@max_timeout_ms)
      _ -> @default_timeout_ms
    end
  end

  # `instructions` is text a third party controls that we place in the system
  # prompt, which makes it the most direct prompt-injection surface in this
  # module. It cannot be dropped — it is how a server teaches its own usage —
  # so it is bounded instead: capped in length so it cannot bury the real
  # prompt, and the caller labels it as untrusted server-supplied text.
  defp bounded_instructions(value) do
    case normalize_string(value) do
      nil -> nil
      text -> String.slice(text, 0, @max_instructions_chars)
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  defp truncate(value) when is_binary(value), do: String.slice(value, 0, 400)
  defp truncate(value), do: value |> inspect() |> String.slice(0, 400)
end
