defmodule VibeWeb.UserSocket do
  use Phoenix.Socket

  # A Socket handler
  #
  # It's possible to control the websocket connection and
  # assign values that can be accessed by your channel topics.

  ## Channels
  # Personal channel for calls/notifications
  channel("user:*", VibeWeb.UserChannel)
  # Chat rooms
  channel("chat:*", VibeWeb.ChatChannel)
  # AI Agent streaming
  channel("agent:*", VibeWeb.AgentChannel)
  # VibeNet peer relay network
  channel("relay:*", VibeWeb.RelayChannel)

  # Socket params are passed from the client and can
  # be used to verify and authenticate a user. After
  # verification, you can put default assigns into
  # the socket that will be set for all channels, ie
  #
  #     {:ok, assign(socket, :user_id, verified_user_id)}
  #
  # To deny connection, return `:error` or `{:error, term}`.
  @impl true
  def connect(params, socket, connect_info) do
    # Priority: x-vibe-auth header (mobile / new clients) > query param token
    # (legacy). Phoenix connect_info: [:x_headers] only forwards headers whose
    # names start with "x-", so Authorization is never available here.
    case extract_connect_token(params, connect_info) do
      nil ->
        :error

      t when is_binary(t) and t != "" ->
        case Vibe.Accounts.get_user_by_token(t) do
          {:ok, user} ->
            {:ok, assign(socket, :user_id, user.id)}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  @doc """
  Resolves the login token for a WebSocket connect.

  Priority:
  1. `x-vibe-auth` from `connect_info.x_headers` (`Bearer <token>` preferred;
     a raw token is accepted as a defensive fallback)
  2. Query param `token` (compatibility for existing clients)

  Returns `nil` when no usable token is present (including the client sentinel
  `"undefined"`). Does not log token material.
  """
  def extract_connect_token(params, connect_info) do
    case header_token(connect_info) do
      nil -> query_token(params)
      token -> token
    end
  end

  defp header_token(%{x_headers: headers}) when is_list(headers) do
    Enum.find_value(headers, fn
      {"x-vibe-auth", value} when is_binary(value) -> parse_auth_header_value(value)
      _ -> nil
    end)
  end

  defp header_token(_), do: nil

  defp query_token(%{"token" => token}) when is_binary(token) do
    case String.trim(token) do
      "" -> nil
      "undefined" -> nil
      t -> t
    end
  end

  defp query_token(_), do: nil

  @doc false
  def parse_auth_header_value(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Regex.run(~r/^Bearer\s+(.+)$/i, trimmed) do
      [_, token] ->
        case String.trim(token) do
          "" -> nil
          "undefined" -> nil
          t -> t
        end

      nil ->
        # Defensive fallback: some clients may send the raw token without Bearer.
        if trimmed == "" or trimmed == "undefined" or String.downcase(trimmed) == "bearer",
          do: nil,
          else: trimmed
    end
  end

  def parse_auth_header_value(_), do: nil

  # Socket id's are topics that allow you to identify all sockets for a given user:
  #
  #     def id(socket), do: "user_socket:#{socket.assigns.user_id}"
  #
  # Would allow you to broadcast a "disconnect" event and terminate
  # all active sockets and channels for a given user:
  #
  #     Elixir.VibeWeb.Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
  #
  # Returning `nil` makes this socket anonymous.
  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
