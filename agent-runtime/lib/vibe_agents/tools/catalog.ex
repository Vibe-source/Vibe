defmodule VibeAgents.Tools.Catalog do
  @moduledoc "Anthropic-style tool specs for every frozen runtime tool name, filtered per run."

  @always_on ["ask_user", "request_approval", "remember", "recall"]
  @computer_tools ["computer_run", "computer_read_file", "computer_write_file"]
  @browser_tools ["browser_open", "browser_act", "browser_screenshot"]

  @doc "agent_profile: map with enabledTools. capabilities: map with computer/browser bools."
  def specs(agent_profile, capabilities) when is_map(agent_profile) do
    enabled =
      (agent_profile["enabledTools"] || agent_profile[:enabledTools] || [])
      |> Enum.map(&to_string/1)
      |> Kernel.++(@always_on)
      |> Enum.uniq()

    computer? = truthy(capabilities["computer"] || capabilities[:computer])
    browser? = truthy(capabilities["browser"] || capabilities[:browser])

    enabled
    |> Enum.reject(&(&1 in @computer_tools and not computer?))
    |> Enum.reject(&(&1 in @browser_tools and not browser?))
    |> Enum.map(&spec/1)
    |> Enum.reject(&is_nil/1)
  end

  def specs(_agent_profile, _capabilities), do: Enum.map(@always_on, &spec/1)

  defp truthy(true), do: true
  defp truthy(_), do: false

  defp spec("search_google") do
    %{
      "name" => "search_google",
      "description" => "Search the web. Returns real URLs, relevance scores, and publication dates.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string"},
          "max_results" => %{"type" => "integer"},
          "time_range" => %{"type" => "string", "enum" => ["day", "week", "month", "year"]}
        },
        "required" => ["query"]
      }
    }
  end

  defp spec("read_url") do
    %{
      "name" => "read_url",
      "description" => "Fetch one or more URLs (up to 3) and return their readable text.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "url" => %{"type" => "string"},
          "urls" => %{"type" => "array", "items" => %{"type" => "string"}}
        }
      }
    }
  end

  defp spec("ask_user") do
    %{
      "name" => "ask_user",
      "description" => "Ask the human a question and wait for their answer before continuing this run.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "questions" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "question" => %{"type" => "string"},
                "header" => %{"type" => "string"},
                "multiSelect" => %{"type" => "boolean"},
                "options" => %{"type" => "array", "items" => %{"type" => "object"}}
              },
              "required" => ["question", "header", "options"]
            }
          }
        },
        "required" => ["questions"]
      }
    }
  end

  defp spec("request_approval") do
    %{
      "name" => "request_approval",
      "description" =>
        "Ask the human to approve a specific consequential action before you take it. " <>
          "Always use this before anything with an external effect.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string"},
          "detail" => %{"type" => "string"},
          "risk" => %{"type" => "string", "enum" => ["external_effect", "credential", "write_local", "spend"]}
        },
        "required" => ["title"]
      }
    }
  end

  defp spec("computer_run") do
    %{
      "name" => "computer_run",
      "description" => "Run a shell command on your sandboxed computer. Output is truncated to 16,000 chars.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string"},
          "cwd" => %{"type" => "string"},
          "timeoutMs" => %{"type" => "integer"}
        },
        "required" => ["command"]
      }
    }
  end

  defp spec("computer_read_file") do
    %{
      "name" => "computer_read_file",
      "description" => "Read a file from your sandboxed computer.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}},
        "required" => ["path"]
      }
    }
  end

  defp spec("computer_write_file") do
    %{
      "name" => "computer_write_file",
      "description" => "Write a file on your sandboxed computer.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "content" => %{"type" => "string"}
        },
        "required" => ["path", "content"]
      }
    }
  end

  defp spec("browser_open") do
    %{
      "name" => "browser_open",
      "description" => "Navigate your sandboxed browser to a URL.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"url" => %{"type" => "string"}},
        "required" => ["url"]
      }
    }
  end

  defp spec("browser_act") do
    %{
      "name" => "browser_act",
      "description" => "Act on the current page in your sandboxed browser: click, type, scroll, key, or select.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "kind" => %{"type" => "string", "enum" => ["click", "type", "scroll", "key", "select"]},
          "selector" => %{"type" => "string"},
          "text" => %{"type" => "string"},
          "x" => %{"type" => "number"},
          "y" => %{"type" => "number"}
        },
        "required" => ["kind"]
      }
    }
  end

  defp spec("browser_screenshot") do
    %{
      "name" => "browser_screenshot",
      "description" => "Take a screenshot of your sandboxed browser's current page.",
      "input_schema" => %{"type" => "object", "properties" => %{}}
    }
  end

  defp spec("handoff_to_agent") do
    %{
      "name" => "handoff_to_agent",
      "description" => "Hand this task to another agent in the same chat by @username, with a short note.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "username" => %{"type" => "string"},
          "note" => %{"type" => "string"}
        },
        "required" => ["username", "note"]
      }
    }
  end

  defp spec("remember") do
    %{
      "name" => "remember",
      "description" => "Save a short fact for your future self, keyed by name.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"key" => %{"type" => "string"}, "value" => %{"type" => "string"}},
        "required" => ["key", "value"]
      }
    }
  end

  defp spec("recall") do
    %{
      "name" => "recall",
      "description" => "Search your saved facts (up to 20 matches).",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      }
    }
  end

  defp spec(_unknown), do: nil
end
