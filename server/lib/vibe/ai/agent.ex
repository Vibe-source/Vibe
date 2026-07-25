defmodule Vibe.AI.Agent do
  @moduledoc """
  AI Agent with tool-use capabilities.
  Tools: Music Search, Google Search, Image/Document Analysis
  """

  import Ecto.Query, warn: false

  require Logger

  alias Vibe.Agent, as: AgentSchema
  alias Vibe.AgentEvent
  alias Vibe.AgentEventThread
  alias Vibe.Agents
  alias Vibe.AI.AgentRuntime
  alias Vibe.AI.GroupAgent
  alias Vibe.AI.SubagentRegistry
  alias Vibe.AI.ToolRegistry
  alias Vibe.Repo

  @claude_api "https://api.anthropic.com/v1/messages"
  @claude_model "claude-haiku-4-5-20251001"
  @always_available_tool_names ~w[
    query_event_inbox
    configure_event_inbox
    get_current_agent_config
    update_current_agent_config
    inspect_current_agent_tools
    test_current_agent_tool
    ask_user
  ]

  # Tool definitions for Claude
  @tools [
    %{
      name: "search_music",
      description:
        "Search for music by name OR resolve a SoundCloud/YouTube (and similar) share URL into a playable audio card the user can listen to in chat. Prefer this whenever the user pastes a music link or asks to play a track.",
      input_schema: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description:
              "Song name, artist, album, lyrics, OR a full music page URL (SoundCloud, YouTube, etc.)"
          },
          url: %{
            type: "string",
            description:
              "Optional explicit track page URL (SoundCloud/YouTube). When set, the link is resolved to audio instead of text search."
          },
          type: %{
            type: "string",
            enum: ["track", "album", "artist"],
            description: "Type of search (ignored for URL resolve)"
          },
          max_results: %{
            type: "integer",
            description:
              "How many tracks to return. Default 1 (a single best match). Only set higher when the user EXPLICITLY asks for multiple options/alternatives/a few. Max 5."
          }
        },
        required: ["query"]
      }
    },
    %{
      name: "search_google",
      description:
        "Search the web using Google. Returns relevant web results with titles, snippets, and URLs.",
      input_schema: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Search query"}
        },
        required: ["query"]
      }
    },
    %{
      name: "analyze_image",
      description:
        "Analyze an image URL. Can describe contents, read text (OCR), identify objects, etc.",
      input_schema: %{
        type: "object",
        properties: %{
          image_url: %{type: "string", description: "URL of the image to analyze"},
          task: %{
            type: "string",
            description: "What to do: describe, ocr, identify, or custom question"
          }
        },
        required: ["image_url"]
      }
    },
    %{
      name: "analyze_document",
      description:
        "Analyze a document (PDF, text). Extract information, summarize, or answer questions about it.",
      input_schema: %{
        type: "object",
        properties: %{
          document_url: %{type: "string", description: "URL of the document"},
          task: %{
            type: "string",
            description: "What to do: summarize, extract_key_points, answer_question"
          },
          question: %{
            type: "string",
            description: "Optional specific question about the document"
          }
        },
        required: ["document_url", "task"]
      }
    },
    %{
      name: "post_to_channel",
      description:
        "Post a message to the user's channel. Supports text, images, and media. The message will be broadcast to all channel subscribers.",
      input_schema: %{
        type: "object",
        properties: %{
          channel_id: %{type: "string", description: "The channel ID to post to"},
          content: %{type: "string", description: "The message content to post"},
          type: %{
            type: "string",
            enum: ["text", "image", "media", "music", "audio", "voice", "video", "file"],
            description: "Type of content"
          },
          media_url: %{type: "string", description: "URL of the media (for image/media types)"}
        },
        required: ["channel_id", "content"]
      }
    },
    %{
      name: "get_channel_analytics",
      description:
        "Get analytics for a channel the user owns: subscriber count, message count, recent joins.",
      input_schema: %{
        type: "object",
        properties: %{
          channel_id: %{type: "string", description: "The channel ID to get analytics for"}
        },
        required: ["channel_id"]
      }
    },
    %{
      name: "schedule_channel_post",
      description: "Schedule a post to be published to a channel at a specific future time.",
      input_schema: %{
        type: "object",
        properties: %{
          channel_id: %{type: "string", description: "The channel ID to post to"},
          content: %{type: "string", description: "The message content to post"},
          type: %{
            type: "string",
            enum: ["text", "image", "media", "music", "audio", "voice", "video", "file"],
            description: "Type of content"
          },
          media_url: %{type: "string", description: "URL of the media (for image/media types)"},
          scheduled_at: %{
            type: "string",
            description: "ISO8601 datetime when to publish (e.g. 2026-02-06T18:00:00Z)"
          }
        },
        required: ["channel_id", "content", "scheduled_at"]
      }
    },
    %{
      name: "query_event_inbox",
      description:
        "Query and AGGREGATE the events this agent has received from its connected apps, to answer questions about them over a timeframe (today, yesterday, last 4h, last 24h, last 7d, last 30d). Returns exact total counts that are NOT limited by `limit`, plus per-event-type and per-source breakdowns. The agent does not know the event shapes in advance: FIRST call it without `group_by` to inspect a few sample events and learn the available payload fields, THEN refine. Pass `group_by` to break counts down by a dimension (a payload path like `a.b.c`, or one of `event_type`/`source`), and `metrics` to sum numeric payload fields by path. Filter with `event_type` (exact) or `event_type_prefix` (a whole family). Compute any derived rates yourself. Only fall back to `call_connected_app` for fresh live data the inbox has not received yet.",
      input_schema: %{
        type: "object",
        properties: %{
          timeframe: %{
            type: "string",
            description:
              "Time window to inspect, such as today, yesterday, last 4h, last 24h, last 7d, or last 30d"
          },
          source: %{type: "string", description: "Optional source filter to a single sending app"},
          event_type: %{
            type: "string",
            description: "Optional exact event type filter (use a value seen in the samples)"
          },
          event_type_prefix: %{
            type: "string",
            description:
              "Optional event type prefix filter to match a whole family of event types"
          },
          group_by: %{
            type: "string",
            description:
              "Optional dimension to break counts down by. Use a dotted payload path (e.g. `a.b.c`) seen in the sample events, or one of `event_type`, `source`."
          },
          metrics: %{
            type: "array",
            items: %{type: "string"},
            description:
              "Optional list of numeric payload paths to sum across matching events (use dotted paths seen in the sample events)."
          },
          limit: %{
            type: "integer",
            description: "Maximum sample events to return alongside the aggregates, default 25"
          },
          query: %{
            type: "string",
            description: "Optional free-form intent note for the lookup"
          }
        }
      }
    },
    %{
      name: "configure_event_inbox",
      description:
        "Configure how incoming external events are surfaced in chat. Use this when the user asks for normal per-event delivery or batched summaries like every 4h or daily.",
      input_schema: %{
        type: "object",
        properties: %{
          mode: %{
            type: "string",
            enum: ["per_event", "batched_summary"],
            description:
              "per_event posts each event as it arrives; batched_summary stores events and posts summaries on the chosen cadence."
          },
          cadence: %{
            type: "string",
            enum: ["4h", "daily"],
            description: "Summary cadence when mode is batched_summary."
          }
        },
        required: ["mode"]
      }
    },
    %{
      name: "call_connected_app",
      description:
        "Call a configured connected app action for website, business, admin, or app-side data and changes. Only use actions that the agent's connected app explicitly exposes.",
      input_schema: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            description:
              "The connected app action id, such as website.summary or waitlist.summary"
          },
          params: %{
            type: "object",
            description: "Action parameters to send to the connected app",
            additionalProperties: true
          },
          integration_id: %{
            type: "string",
            description:
              "Optional specific integration id when multiple connected apps are configured"
          },
          integration_name: %{
            type: "string",
            description:
              "Optional specific integration name when multiple connected apps are configured"
          }
        },
        required: ["action"]
      }
    },
    %{
      name: "list_platform_connections",
      description:
        "List OAuth platform connectors granted to this agent (GitHub, Microsoft Excel, Slack, Linear, Calendar). Returns provider, account login, and allowed capability ids — never tokens.",
      input_schema: %{
        type: "object",
        properties: %{},
        required: []
      }
    },
    %{
      name: "call_platform",
      description:
        "Call a granted multi-platform connector action. Primary use: GitHub PR workflows (list_pull_requests, get_pull_request, list_pr_files, create_pr_comment, list_issues, create_issue, list_repos, get_repo). Tokens stay on the server; only capability results are returned.",
      input_schema: %{
        type: "object",
        properties: %{
          provider: %{
            type: "string",
            description: "Platform id such as github (later: microsoft_excel, slack, linear, google_calendar)"
          },
          action: %{
            type: "string",
            description:
              "Capability id, e.g. list_pull_requests, get_pull_request, create_pr_comment"
          },
          params: %{
            type: "object",
            description:
              "Action parameters (e.g. owner, repo, number, body). Never include tokens or passwords.",
            additionalProperties: true
          },
          connection_id: %{
            type: "string",
            description: "Optional connection id when multiple accounts are connected for one provider"
          }
        },
        required: ["provider", "action"]
      }
    },
    %{
      name: "get_current_agent_config",
      description:
        "Read the current standalone agent's live config for the owner, including prompt, ids, status, tools, output modes, destination chats, and endpoints. Prefer this for simple questions about the agent you are already talking to.",
      input_schema: %{
        type: "object",
        properties: %{
          include_prompt: %{
            type: "boolean",
            description: "When true, include the full saved system prompt. Defaults to true."
          }
        }
      }
    },
    %{
      name: "update_current_agent_config",
      description:
        "Update the current standalone agent directly for simple one-agent changes such as prompt, name, persona, welcome message, profile image/avatar, voice profile, or status. Prefer this over delegate_to_subagent when the user is changing the agent they are already chatting with. When the user shares an image and asks to use it as the agent's profile/avatar, pass its URL as avatar_url.",
      input_schema: %{
        type: "object",
        properties: %{
          display_name: %{type: "string", description: "Updated display name."},
          system_prompt: %{type: "string", description: "Updated system prompt."},
          persona: %{type: "string", description: "Updated persona."},
          welcome_message: %{type: "string", description: "Updated welcome message."},
          avatar_url: %{
            type: "string",
            description:
              "Updated profile image/avatar URL for the agent. Use a hosted image URL, e.g. one the user just sent."
          },
          voice_profile: %{type: "string", description: "Updated voice profile."},
          status: %{
            type: "string",
            enum: ["draft", "published", "disabled"],
            description: "Optional status change for the current agent."
          },
          enabled_tools: %{
            type: "array",
            items: %{type: "string"},
            description: "Updated allowlisted tool ids for this agent."
          },
          output_modes: %{
            type: "array",
            items: %{type: "string", enum: ["text", "media", "voice"]},
            description: "Updated output modes for this agent."
          }
        }
      }
    },
    %{
      name: "create_chat_space",
      description:
        "Create an owned group or channel and optionally attach the current agent. Channel creation supports private/public access, slug, approval, and saving restrictions.",
      input_schema: %{
        type: "object",
        properties: %{
          room_type: %{type: "string", enum: ["group", "channel"]},
          name: %{type: "string"},
          description: %{type: "string"},
          avatar_url: %{type: "string"},
          member_ids: %{type: "array", items: %{type: "string"}},
          access_type: %{type: "string", enum: ["private", "public"]},
          public_slug: %{type: "string"},
          join_approval_required: %{type: "boolean"},
          restrict_saving: %{type: "boolean"},
          attach_current_agent: %{
            type: "boolean",
            description: "Attach this agent to the new room. Defaults to true."
          }
        },
        required: ["room_type", "name"]
      }
    },
    %{
      name: "attach_current_agent_to_chat",
      description: "Attach the current agent to a group or channel owned by the requester.",
      input_schema: %{
        type: "object",
        properties: %{
          chat_id: %{type: "string"},
          allowed_tools: %{type: "array", items: %{type: "string"}},
          allowed_output_modes: %{type: "array", items: %{type: "string"}},
          permissions: %{type: "object", additionalProperties: true}
        },
        required: ["chat_id"]
      }
    },
    %{
      name: "inspect_current_agent_tools",
      description:
        "Inspect the current owned agent's complete tool registry, configured and effective state, output modes, and safe testability.",
      input_schema: %{type: "object", properties: %{}}
    },
    %{
      name: "test_current_agent_tool",
      description:
        "Boundedly test one registered current-agent tool. Web/music search may run with explicit sample input; mutation and destructive tools return dry-run capability validation only.",
      input_schema: %{
        type: "object",
        properties: %{
          tool_id: %{type: "string"},
          sample_input: %{type: "object", additionalProperties: true}
        },
        required: ["tool_id"]
      }
    },
    %{
      name: "ask_user",
      description:
        "Finish this turn with one or more structured questions. Returns waiting_for_user immediately; never wait or call it recursively.",
      input_schema: %{
        type: "object",
        properties: %{
          questions: %{
            type: "array",
            items: %{
              type: "object",
              properties: %{
                question: %{type: "string"},
                header: %{type: "string"},
                multiSelect: %{type: "boolean"},
                options: %{
                  type: "array",
                  items: %{
                    type: "object",
                    properties: %{
                      label: %{type: "string"},
                      description: %{type: "string"}
                    },
                    required: ["label"]
                  }
                }
              },
              required: ["question", "header", "options"]
            }
          }
        },
        required: ["questions"]
      }
    },
    %{
      name: "delegate_to_subagent",
      description:
        "OPTIONAL specialist handoff for complex multi-step work only. Default is to DO THE WORK YOURSELF with your direct tools (search_music, search_google, analyze_*, get/update_current_agent_config, etc.). Do NOT call this for ordinary one-shot music, search, image, or document requests. Use only when the task needs multi-part context, parallel specialist workflows, or deep builder/integration setup that your direct tools cannot finish alone.",
      input_schema: %{
        type: "object",
        properties: %{
          subagent_id: %{
            type: "string",
            enum: [
              "builder_assistant",
              "integration_advisor",
              "music_specialist",
              "document_specialist"
            ],
            description:
              "Specialist id. Prefer builder_assistant / integration_advisor for complex agent-building or integration. music_specialist / document_specialist only for multi-track research, playlists, or multi-document synthesis — never for a single song URL or one web lookup."
          },
          task: %{
            type: "string",
            description:
              "Self-contained task brief for the specialist (goal, constraints, what to return). Only when delegation is justified."
          }
        },
        required: ["subagent_id", "task"]
      }
    }
  ]

  @system_prompt """
  You are Vibe AI, a helpful assistant in a messaging app.

  RUNTIME ARCHITECTURE (READ FIRST):
  - YOU are the primary runtime. For most requests, YOU call tools and answer — no subagent.
  - Subagents are OPTIONAL helpers for complex multi-part work only (multi-step agent building,
    deep integration setup, multi-source research that needs parallel specialist focus).
  - NEVER fan out to a subagent for a single music link, one song search, one web lookup,
    one image/document analysis, a greeting, or any other job your direct tools can finish.
  - If you can do it with search_music / search_google / analyze_* / get|update_current_agent_config
    / call_platform / etc., do that yourself. Do not wrap it in delegate_to_subagent.

  HOW A TURN READS (this is the shape the UI renders):
  intent line → tool steps (live notes) → short specific summary.
  - Open with ONE short intent line (max ~12 words) saying what you are about to do, then
    call the tool. Skip it only for a greeting or a one-word answer.
  - Close with a summary that is SPECIFIC to this result. Name what you found (title,
    version, artist, count, file name) — that is what makes the answer useful.
  - NEVER reuse a sentence you have already used in this conversation. If your previous
    reply said "Here it is again", you may not say it again. Vary the wording every turn.
  - Do not narrate the tool machinery ("calling search_music") — the notes already show it.

  CONTINUITY (READ BEFORE ANY TOOL CALL):
  - A "RECENT TURN MEMORY" section may appear at the end of this prompt listing what you
    produced in earlier turns (track title + id, file name, …). It is authoritative.
  - If the user says "again", "the same one", "resend", "one more time": reuse the EXACT
    item from the newest memory entry — for music, call search_music with that track's
    stored title so the same track comes back. Do NOT start a fresh open-ended search, and
    never claim it is "the same" if you searched for something new.
  - If the user asks for "another version / a different one" and memory holds what you last
    sent, that is NOT ambiguous — do NOT ask which one. Pick a concrete different variant
    yourself (live, acoustic, remix, cover, remaster), send it, and say how it differs. Ask
    only when there is nothing in memory to differ from.
  - That memory block is internal. Never quote it, never reproduce its format in a reply.

  CRITICAL TOOL USAGE RULES (AGENTIC LOOP):
  1. TOOL-FIRST when action is clear: intent line, then call the tool immediately.
     - Prefer action over stalling. The UI shows live tool progress notes.
     - Never write multiple paragraphs before a tool call.

  2. search_music: YOU handle music yourself. Use when user asks for songs, music, artists, albums, OR pastes a music link.
     - SOUNDCLOUD / YOUTUBE / music page URLs: pass the full URL as `query` (or `url`). The tool resolves it and the app sends a playable audio cell — do this immediately, do not only describe the link, and do NOT delegate to music_specialist.
     - If the user provides lyrics (e.g., "music that says 'some part of music'"), search for the lyrics or the inferred song title.
     - If the user describes a vibe or sound, keyword search for it.
     - Correct typos intelligently (e.g., "tylor swift" → "Taylor Swift").
     - ALWAYS provide the "query" parameter (use the URL itself when they shared a link).
     - RETURN ONE TRACK BY DEFAULT: omit max_results or set it to 1. The user asked for a song, not a list.
     - ASK BEFORE GUESSING: only when the request is genuinely ambiguous on its own — several well-known songs or artists could match a bare title ("play hello") — call ask_user with concrete options FIRST. Never ask when the intended track is clear, when the user pasted a link, or when TURN MEMORY already tells you what this refers to ("again", "another version").
     - Only set max_results > 1 when the user EXPLICITLY asks for multiple options, alternatives, "a few", or a playlist.
     - EVERY successful search_music call ships its track to the user as a playable card, and
       the card that lands is the one from your LAST successful call. So the last call you make
       IS the track you send. Never say you "did not send it" after a successful call, and
       never call the tool for a track you do not want to send.
     - AFTER the tool returns successfully: 1–2 short lines naming the track/version you sent
       (e.g. "Sent the 2012 live version — 9:21."). The playable cell is attached by the app.
     - You MAY name the title, artist and version. Do NOT paste URLs or links.

  3. search_google: YOU handle web lookup yourself. Use when user needs current info, facts, or web lookup.
     - ALWAYS provide the "query" parameter. Do not delegate one search to document_specialist.

  4. analyze_image: YOU handle this yourself when user shares an image URL.
     - ALWAYS provide "image_url" parameter.

  5. analyze_document: YOU handle this yourself when user shares a document URL.
     - ALWAYS provide "document_url" and "task" parameters.

  ON ERRORS (a failed tool does NOT end the turn — you decide what happens next):
  - A failed tool returns `{"ok": false, "error": {"code", "message", "retryable", "hint"}}`.
    READ IT. The decision is yours and it is made from those fields:
      * `retryable: true`  → you MAY retry ONCE, with genuinely better input. Then stop.
      * `retryable: false` → do NOT retry and do NOT substitute something else. Say what
        failed in one line and, if useful, ask the user for what you need.
    Always follow `hint` when it is present.
  - Never invent a replacement result to cover a failure. Sending an unrelated track for a
    dead link is worse than saying the link did not work.
  - If one tool of several fails, finish the work you CAN do and report the failed part.
  - Name the failed thing concretely ("that SoundCloud link is unavailable"), not "something
    went wrong".

  6. post_to_channel: Use when user asks to post/publish something to their channel.
     - ALWAYS provide "channel_id" and "content" parameters.
     - If user doesn't specify channel_id, ask which channel they want to post to.
     - After posting: Confirm briefly, e.g., "Posted to your channel!"

  7. get_channel_analytics: Use when user asks about channel stats, subscribers, activity.
     - ALWAYS provide "channel_id" parameter.
     - Present analytics in a brief, readable format.

  8. schedule_channel_post: Use when user asks to schedule a post for later.
     - ALWAYS provide "channel_id", "content", and "scheduled_at" (ISO8601 format).
     - Convert natural language times to ISO8601 (e.g., "6pm today" → appropriate datetime).
     - Confirm the scheduled time after scheduling.

  9. query_event_inbox: Use for questions about the events this agent has received from its connected apps (analytics, notifications, past activity).
     - Returns EXACT total counts (not limited by `limit`) plus per-event-type and per-source breakdowns. You do not know the payload shapes in advance: first call it without `group_by` to inspect a few sample events and learn what fields they carry, then pass `group_by` (a payload path, or event_type/source) and `metrics` (numeric payload paths) to break down and sum. Compute any derived rates yourself.
     - Use this BEFORE answering questions like:
       * "How many <events> did we get today, and how do they break down?"
       * "What were the totals or top values over the last 7 days?"
       * "Summarize the last 4 hours of notifications"
     - If you are not certain about past events, counts, timing, or related notifications, look them up first instead of guessing from memory.
     - The agent's own system prompt describes which event types this agent receives and what their fields mean; rely on that for project-specific context.

  10. configure_event_inbox: Use when the user wants notification mode changes.
      - Use this for requests like:
        * "Don't reply to every event"
        * "Summarize these daily"
        * "Switch back to normal event bubbles"
      - `per_event` means each event posts as a chat bubble.
      - `batched_summary` means events are stored and summarized on the selected cadence.

  11. call_connected_app: Use when the user asks about a connected website, admin dashboard, waitlist, business metrics, catalog, orders, or wants the connected app/backend to do something.
      - ALWAYS provide the `action` parameter.
      - Put request arguments inside `params` as a JSON object.
      - Only use actions explicitly listed in the connected-app section of the system prompt or returned by the tool itself.
      - If the user asks for website traffic, conversions, waitlist numbers, product counts, or to change something in the connected app, prefer this tool over guessing.

  11b. list_platform_connections / call_platform: OAuth platforms (GitHub PRs, Excel later, Slack/Linear later).
      - Use list_platform_connections to see what the user has connected and which actions are granted.
      - Use call_platform with provider + action + params for live GitHub PR review, comments, issues, and repos.
      - Never ask for or invent GitHub tokens; the server holds OAuth credentials.
      - Prefer call_platform over guessing PR state from chat history when GitHub is connected.

  12. get_current_agent_config: Use for simple live questions about the agent you are already talking to.
      - Use this for requests like:
        * "what is my current prompt?"
        * "what tools do you have enabled?"
        * "what is this agent's id or invoke url?"
        * "is incoming chat enabled?"
      - Prefer this over delegate_to_subagent when the request is only about the current agent's existing state.

  13. update_current_agent_config: Use for simple direct edits to the agent you are already talking to.
      - Use this for requests like:
        * "change your prompt to ..."
        * "rename yourself to ..."
        * "update your welcome message"
        * "switch your status to draft/published/disabled"
      - Prefer this over delegate_to_subagent when the request is a one-agent edit and you already have enough information.

  14. create_chat_space / attach_current_agent_to_chat: Use these for explicit requests to create an owned group/channel or attach this agent to an existing owned room.
      - Never claim that a subscriber owns a channel. The tools independently verify the current agent id and requester owner id.
      - Public channels require a public_slug. attach_current_agent defaults to true on creation.

  15. inspect_current_agent_tools / test_current_agent_tool: Use these to explain or validate this agent's tools.
      - Tool tests are bounded: only explicit web/music sample searches may execute live. Mutating/destructive tools only report a dry-run capability result.
      - Never use test_current_agent_tool to call itself or to dispatch an arbitrary tool.

  16. ask_user: Use only when a real choice is required before a useful next turn.
      - Supply normalized questions and options. The call finalizes this turn as waiting_for_user; it does not block or wait.
      - The user's answer arrives as a new turn.

  17. delegate_to_subagent: RARE. Default is you do the work with your own tools.
     WHEN TO DELEGATE (only if true):
     - Multi-step agent creation / complex reconfiguration spanning several builder steps → builder_assistant
     - Deep integration (invoke URLs, events, secrets, multi-room attach) when direct config tools are not enough → integration_advisor
     - Multi-source research or multi-document synthesis that genuinely needs a focused specialist pass → document_specialist
     - Complex multi-track / playlist-scale music research (not a single URL or single song) → music_specialist
     WHEN NOT TO DELEGATE (almost everything else):
     - One SoundCloud/YouTube link, one song search → call search_music yourself
     - One web fact lookup → search_google yourself
     - One image or one document → analyze_image / analyze_document yourself
     - Current-agent prompt/name/status read or one-field edit → get/update_current_agent_config
     - Greetings, short Q&A, anything solvable in one tool call
     - ALWAYS provide both "subagent_id" and "task" when you do delegate
     - After a rare successful delegation, answer from the result as your own (never say "ask a specialist")

  IMPORTANT:
  - Prefer direct tools. Subagents are for complex multi-part work, not default routing.
  - Agentic loop: short intent → tool → READ the tool result → short specific summary.
    Never end a turn with empty text after a tool ran.
  - For music: you may name the track/version you sent; never paste URLs or links.
  - If a user asks for live agent configuration, current inbox mode, or historical notification facts, use the live lookup/config tools first.
  - For simple current-agent prompt or name changes, use `update_current_agent_config` instead of delegating.
  - Use `ask_user` for required structured choices; never simulate waiting inside a tool call.
  - For simple greetings, respond naturally WITHOUT tools.
  - Keep each prose beat short (1–2 sentences) — mobile chat — but DO speak after tools succeed or fail.
  """

  @doc """
  Process a message and return streaming chunks via callback.
  """
  def stream_response(user_message, callback, opts \\ []) do
    conversation_history = Keyword.get(opts, :history, [])
    image_urls = Keyword.get(opts, :images, [])
    user_id = Keyword.get(opts, :user_id, nil)
    requester_user_id = Keyword.get(opts, :requester_user_id, nil)
    chat_id = Keyword.get(opts, :chat_id, nil)
    agent_id = Keyword.get(opts, :agent_id, nil)
    system_prompt =
      opts
      |> Keyword.get(:system_prompt, @system_prompt)
      |> with_turn_memory(Keyword.get(opts, :turn_memory, []))

    enabled_tools = Keyword.get(opts, :enabled_tools, available_tool_names())
    max_tokens = Keyword.get(opts, :max_tokens, 4096)
    # 3 was too tight for a real agentic loop: resolve → fails → retry → answer is already 4
    # rounds, and hitting the cap used to surface as a hard error with the streamed text
    # thrown away. Depth exhaustion now returns the partial answer (see AgentRuntime.do_run).
    max_depth = Keyword.get(opts, :max_depth, 6)
    model_provider = Keyword.get(opts, :model_provider, "anthropic")
    model_id = Keyword.get(opts, :model_id, @claude_model)
    thinking_level = Keyword.get(opts, :thinking_level, "medium")
    tools = filter_tools(enabled_tools)

    messages = build_messages(conversation_history, user_message, image_urls)

    AgentRuntime.run(
      messages,
      %AgentRuntime.Config{
        provider: model_provider,
        model: model_id,
        thinking_level: thinking_level,
        max_tokens: max_tokens,
        max_depth: max_depth,
        system_prompt: system_prompt,
        tools: tools,
        state: %{
          user_id: user_id,
          requester_user_id: requester_user_id,
          chat_id: chat_id,
          agent_id: agent_id
        },
        callback: callback,
        stream_text?: true,
        execute_tools: &execute_tools_runtime/3,
        missing_api_key_error: "ANTHROPIC_API_KEY not configured",
        depth_error: "Max tool depth reached",
        request_label: "Agent"
      }
    )
  end

  # Turn memory rides in the SYSTEM prompt, not in the assistant history. Putting it in the
  # message content (as a `[did: …]` line) worked, but the model copied the format straight
  # into its user-visible reply — internal state must not live where the model is imitating
  # style.
  @turn_memory_limit 6

  defp with_turn_memory(system_prompt, memory) when is_binary(system_prompt) do
    entries =
      memory
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(-@turn_memory_limit)

    if entries == [] do
      system_prompt
    else
      lines = Enum.map_join(entries, "\n", &"- #{&1}")

      system_prompt <>
        """

        RECENT TURN MEMORY (internal — what you already produced in this chat, oldest first):
        #{lines}

        Use it to honour "again" / "the same one", to avoid resending something you already
        sent, and to avoid repeating your own wording. Never quote this block to the user.
        """
    end
  end

  defp with_turn_memory(system_prompt, _memory), do: system_prompt

  def available_tools do
    (@tools ++ GroupAgent.standalone_available_tools())
    |> Enum.uniq_by(& &1.name)
  end

  def available_tool_names, do: Enum.map(available_tools(), & &1.name)

  @doc """
  Quick non-streaming completion for simple tasks like title generation.
  Uses Claude haiku for speed.
  """
  def quick_completion(prompt) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_API_KEY")

    if is_nil(api_key) do
      {:error, "No API key configured"}
    else
      body =
        Jason.encode!(%{
          model: @claude_model,
          max_tokens: 100,
          messages: [%{role: "user", content: prompt}]
        })

      headers = [
        {"content-type", "application/json"},
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"}
      ]

      request = Finch.build(:post, @claude_api, headers, body)

      case Finch.request(request, Vibe.Finch, receive_timeout: 10_000) do
        {:ok, %{status: 200, body: resp_body}} ->
          case Jason.decode(resp_body) do
            {:ok, %{"content" => [%{"text" => text} | _]}} ->
              {:ok, text}

            _ ->
              {:error, "Failed to parse response"}
          end

        {:ok, %{status: status, body: body}} ->
          Logger.error("Claude API error: #{status} - #{body}")
          {:error, "API error: #{status}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_messages(history, user_message, image_urls) do
    # Convert history to Claude format
    history_messages =
      Enum.map(history, fn msg ->
        %{
          role: msg["role"] || msg[:role],
          content: msg["content"] || msg[:content]
        }
      end)

    # Build current message with optional images
    current_content =
      if Enum.empty?(image_urls) do
        user_message
      else
        # Multi-modal message with images
        image_blocks =
          Enum.map(image_urls, fn url ->
            %{
              type: "image",
              source: %{
                type: "url",
                url: url
              }
            }
          end)

        text_block = %{type: "text", text: user_message}
        image_blocks ++ [text_block]
      end

    history_messages ++ [%{role: "user", content: current_content}]
  end

  defp execute_tools_runtime(tool_calls, state, callback) do
    user_id = Map.get(state, :user_id)
    requester_user_id = Map.get(state, :requester_user_id)
    chat_id = Map.get(state, :chat_id)
    agent_id = Map.get(state, :agent_id)
    # A question is a terminal control item, equivalent to Codex yielding for
    # user input. Do not execute sibling calls speculatively in that batch.
    executable_calls =
      case Enum.find(tool_calls, &(&1["name"] == "ask_user")) do
        nil -> tool_calls
        ask_call -> [ask_call]
      end

    results =
      execute_tools(
        executable_calls,
        callback,
        user_id,
        requester_user_id,
        chat_id,
        agent_id
      )

    next_state =
      if Enum.any?(results, &waiting_for_user_result?/1) do
        Map.put(state, :terminal_status, "waiting_for_user")
      else
        state
      end

    {results, next_state}
  end

  defp execute_tools(tool_calls, callback, user_id, requester_user_id, chat_id, agent_id) do
    # Send all progress labels immediately so the UI shows activity
    Enum.each(tool_calls, fn tool ->
      tool_name = tool["name"]
      tool_input = tool["input"] || %{}
      label = tool_running_label(tool_name, tool_input)

      callback.(%{
        type: :progress,
        label: label,
        tool: tool_name,
        tool_call_id: tool["id"],
        status: "running",
        # Codex-like item identity for list note rows
        item: %{
          type: "tool",
          name: tool_name,
          status: "running",
          detail: label
        }
      })
    end)

    # Run tool calls concurrently. async_nolink + an explicit {:exit, _} clause so ONE
    # broken tool becomes an error the model can read instead of killing the whole turn:
    # Task.async links, so a raising tool used to take the runtime process down with it
    # (no done, no error, no DB finalize — the turn just evaporated).
    tasks =
      Enum.map(tool_calls, fn tool ->
        {tool,
         Task.Supervisor.async_nolink(Vibe.TaskSupervisor, fn ->
           execute_single_tool(tool, callback, user_id, requester_user_id, chat_id, agent_id)
         end)}
      end)

    # Await all tasks with a generous timeout (120s per tool)
    Enum.map(tasks, fn {tool, task} ->
      case Task.yield(task, 120_000) || Task.shutdown(task) do
        {:ok, result} ->
          result

        {:exit, reason} ->
          Logger.error("[Agent] Tool #{tool["name"]} crashed: #{inspect(reason)}")
          crash_tool_result(tool, callback, reason)

        nil ->
          Logger.error("[Agent] Tool #{tool["name"]} timed out after 120s")
          timeout_tool_result(tool, callback)
      end
    end)
  end

  # Re-emits the running node with a new label. Same id + same tool, so the client updates
  # the row in place rather than appending another step.
  defp tool_step_reporter(tool, callback) do
    fn label ->
      callback.(%{
        type: :progress,
        label: label,
        tool: tool["name"],
        tool_call_id: tool["id"],
        status: "running"
      })

      :ok
    end
  end

  # A crashed tool still owes the model a tool_result for its tool_use id (a missing or
  # "unknown" id makes the provider reject the whole follow-up request), and still owes
  # the UI a failed step.
  defp crash_tool_result(tool, callback, reason) do
    result =
      tool_error_envelope(
        "tool_crashed",
        "#{tool["name"]} failed unexpectedly.",
        retryable: false,
        hint:
          "This tool is currently broken — do not retry it. Tell the user plainly that it " <>
            "failed and offer an alternative if one exists.",
        detail: inspect(reason) |> String.slice(0, 300)
      )

    emit_tool_failure(tool, callback, result, tool_failed_label(tool["name"]))
    encoded_tool_result(tool, result)
  end

  defp timeout_tool_result(tool, callback) do
    result =
      tool_error_envelope("tool_timeout", "#{tool["name"]} timed out after 120s.",
        retryable: true,
        hint: "Retry at most once with a simpler input, then stop and tell the user."
      )

    emit_tool_failure(tool, callback, result, "Timed out")
    encoded_tool_result(tool, result)
  end

  defp emit_tool_failure(tool, callback, result, label) do
    callback.(%{
      type: :progress,
      label: label,
      tool: tool["name"],
      tool_call_id: tool["id"],
      status: "error"
    })

    callback.(%{
      type: :tool_result,
      tool: tool["name"],
      tool_call_id: tool["id"],
      result: result,
      status: "error"
    })
  end

  defp encoded_tool_result(tool, result) do
    %{
      type: "tool_result",
      tool_use_id: tool["id"] || "unknown",
      content: Jason.encode!(result)
    }
  end

  # Progress labels are single-line shimmer rows. Keep them SHORT (verb + object, ≤ 24
  # chars) so nothing is clipped downstream — AgenticEventShape.compact_label is a safety
  # net, not the intended shortener.
  defp tool_running_label(tool_name, tool_input) do
    case tool_name do
      "search_music" -> music_progress_label(tool_input)
      "search_google" -> "Searching the web…"
      "analyze_image" -> "Reading image…"
      "analyze_document" -> "Reading document…"
      "create_document" -> "Making file…"
      "find_rows" -> "Checking rows…"
      "edit_rows" -> "Updating rows…"
      "delete_rows" -> "Deleting rows…"
      "export_rows" -> "Exporting file…"
      "delete_document" -> "Removing file…"
      "post_to_channel" -> "Posting…"
      "get_channel_analytics" -> "Reading stats…"
      "schedule_channel_post" -> "Scheduling…"
      "query_event_inbox" -> "Checking inbox…"
      "configure_event_inbox" -> "Updating inbox…"
      "call_connected_app" -> "Calling your app…"
      "list_platform_connections" -> "Checking apps…"
      "call_platform" -> "Calling connector…"
      "get_current_agent_config" -> "Reading config…"
      "update_current_agent_config" -> "Updating agent…"
      "create_chat_space" -> "Creating space…"
      "attach_current_agent_to_chat" -> "Attaching agent…"
      "inspect_current_agent_tools" -> "Checking tools…"
      "test_current_agent_tool" -> "Testing tool…"
      "ask_user" -> "Asking you…"
      "delegate_to_subagent" -> SubagentRegistry.progress_label(tool_input["subagent_id"] || "", tool_input["task"])
      _ -> "Working…"
    end
  end

  defp execute_single_tool(tool, callback, user_id, requester_user_id, chat_id, agent_id) do
    tool_name = tool["name"]
    tool_input = tool["input"] || %{}
    start_time = System.monotonic_time(:millisecond)

    # Long-running tools report their own intermediate beats on the SAME node, so a 3-5s
    # lookup reads "Opening SoundCloud… → Reading metadata… → Found · X" instead of sitting
    # on one frozen label.
    on_step = tool_step_reporter(tool, callback)

    result =
      cond do
        tool_name == "search_music" ->
          Vibe.AI.Tools.Music.search(tool["input"], on_step: on_step)

        tool_name == "search_google" ->
          on_step.("Reading results…")
          Vibe.AI.Tools.Search.google(tool["input"])

        tool_name == "analyze_image" ->
          Vibe.AI.Tools.Vision.analyze(tool["input"])

        tool_name == "analyze_document" ->
          Vibe.AI.Tools.Document.analyze(tool["input"])

        tool_name in GroupAgent.standalone_tool_names() ->
          GroupAgent.execute_standalone_tool(tool_name, tool["input"], user_id, chat_id)

        tool_name == "post_to_channel" ->
          if is_binary(agent_id) do
            Vibe.AI.Tools.Channel.post_to_channel(tool_input, agent_id, requester_user_id)
          else
            Vibe.AI.Tools.Channel.post_to_channel(tool_input, user_id)
          end

        tool_name == "get_channel_analytics" ->
          Vibe.AI.Tools.Channel.get_analytics(tool["input"], user_id)

        tool_name == "schedule_channel_post" ->
          if is_binary(agent_id) do
            Vibe.AI.Tools.Channel.schedule_post(tool_input, agent_id, requester_user_id)
          else
            Vibe.AI.Tools.Channel.schedule_post(tool_input, user_id)
          end

        tool_name == "query_event_inbox" ->
          query_event_inbox(tool_input, agent_id, requester_user_id)

        tool_name == "configure_event_inbox" ->
          configure_event_inbox(tool_input, agent_id, requester_user_id)

        tool_name == "call_connected_app" ->
          Vibe.AI.Tools.ConnectedApp.invoke(tool_input, agent_id, requester_user_id)

        tool_name == "list_platform_connections" ->
          Vibe.AI.Tools.Platform.list_connections(tool_input, agent_id, requester_user_id)

        tool_name == "call_platform" ->
          Vibe.AI.Tools.Platform.invoke(tool_input, agent_id, requester_user_id)

        tool_name == "get_current_agent_config" ->
          get_current_agent_config(tool_input, agent_id, requester_user_id)

        tool_name == "update_current_agent_config" ->
          update_current_agent_config(tool_input, agent_id, requester_user_id)

        tool_name == "create_chat_space" ->
          Vibe.AI.Tools.Channel.create_chat_space(tool_input, agent_id, requester_user_id)

        tool_name == "attach_current_agent_to_chat" ->
          Vibe.AI.Tools.Channel.attach_current_agent_to_chat(
            tool_input,
            agent_id,
            requester_user_id
          )

        tool_name == "inspect_current_agent_tools" ->
          inspect_current_agent_tools(tool_input, agent_id, requester_user_id)

        tool_name == "test_current_agent_tool" ->
          test_current_agent_tool(tool_input, agent_id, requester_user_id)

        tool_name == "ask_user" ->
          ask_user(tool_input)

        tool_name == "delegate_to_subagent" ->
          case maybe_fast_delegate_current_agent(tool_input, agent_id, requester_user_id) do
            {:ok, payload} ->
              payload

            :no_match ->
              case SubagentRegistry.run(
                     tool_input["subagent_id"],
                     tool_input["task"],
                     user_id: user_id,
                     requester_user_id: requester_user_id,
                     chat_id: chat_id,
                     active_agent_id: agent_id,
                     callback: callback
                   ) do
                {:ok, payload} -> payload
                {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
              end
          end

        true ->
          %{error: "Unknown tool"}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time
    Logger.info("[Agent] Tool #{tool_name} completed in #{duration_ms}ms")

    # Failures are reported as failures. The old code sent status "done"/"complete" for
    # error results too, so the UI could never show a failed step and the model had only
    # a bare error string to reason about.
    failed? = tool_result_error?(result)
    result = if failed?, do: enrich_tool_error(tool_name, tool_input, result), else: result
    complete_label = tool_complete_label(tool_name, tool_input, result)

    callback.(%{
      type: :progress,
      label: complete_label,
      tool: tool_name,
      tool_call_id: tool["id"],
      status: if(failed?, do: "error", else: "done")
    })

    callback.(%{
      type: :tool_result,
      tool: tool_name,
      tool_call_id: tool["id"],
      result: result,
      status: if(failed?, do: "error", else: "complete"),
      duration_ms: duration_ms,
      label: complete_label
    })

    encoded_tool_result(tool, result)
  rescue
    error ->
      Logger.error(
        "[Agent] Tool #{tool["name"]} raised: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      crash_tool_result(tool, callback, error)
  catch
    kind, reason ->
      Logger.error("[Agent] Tool #{tool["name"]} #{kind}: #{inspect(reason)}")
      crash_tool_result(tool, callback, {kind, reason})
  end

  # Turn a bare `%{error: "..."}` into something the model can DECIDE on:
  # retryable? which code? what should it do next? Without this the prompt's "one
  # intelligent retry is allowed" made the model keyword-search a dead URL's slug and
  # ship an unrelated track as "a likely match".
  defp enrich_tool_error(tool_name, tool_input, result) when is_map(result) do
    message = Map.get(result, :error) || Map.get(result, "error") || "Tool failed"
    {code, retryable, hint} = classify_tool_error(tool_name, tool_input, to_string(message))

    result
    |> Map.drop([:error, "error"])
    |> Map.merge(tool_error_envelope(code, message, retryable: retryable, hint: hint))
  end

  defp enrich_tool_error(_tool_name, _tool_input, result), do: result

  # A dead / private / removed link is TERMINAL — there is nothing to retry, and
  # re-searching the URL text is how we ended up sending deadmau5 for a 404 slug.
  defp classify_tool_error("search_music", tool_input, message) do
    url = tool_input["url"] || tool_input["link"] || tool_input["query"] || ""
    link_request? = is_binary(url) and String.starts_with?(to_string(url), "http")

    cond do
      link_request? ->
        {"link_unavailable", false,
         "That exact link cannot be resolved. Do NOT keyword-search the URL text or " <>
           "substitute a different track. Say the link did not work and ask for another one."}

      String.contains?(message, "Missing search query") ->
        {"missing_query", true, "Call the tool again with a real `query` string."}

      true ->
        {"no_results", true,
         "You may retry ONCE with a better query (title + artist, or a typo fix). " <>
           "If that also finds nothing, say so plainly — never send an unrelated track."}
    end
  end

  defp classify_tool_error(_tool_name, _tool_input, message) do
    if String.contains?(message, "not available") or String.contains?(message, "not found") do
      {"unavailable", false, "This is not retryable. Tell the user what is missing."}
    else
      {"tool_error", true, "You may retry once with corrected input, then stop."}
    end
  end

  defp tool_error_envelope(code, message, opts) do
    %{
      "ok" => false,
      "error" => %{
        "code" => code,
        "message" => to_string(message),
        "retryable" => Keyword.get(opts, :retryable, false),
        "hint" => Keyword.get(opts, :hint),
        "detail" => Keyword.get(opts, :detail)
      }
    }
  end

  defp music_progress_label(input) when is_map(input) do
    url = input["url"] || input["link"]
    query = input["query"] || ""
    link = if is_binary(url), do: url, else: query

    cond do
      is_binary(link) and String.contains?(link, "soundcloud") -> "Opening SoundCloud…"
      is_binary(link) and String.starts_with?(link, "http") -> "Opening link…"
      true -> "Searching music…"
    end
  end

  defp music_progress_label(_), do: "Searching music…"

  # Done labels are single-line notes: keep the whole string short enough that the client
  # never has to clip mid-word ("Found · Anathema - Flying [Live…" was the old output), but
  # long enough to stay informative ("Found · Flying…" told the user nothing).
  @done_label_limit 30

  defp tool_complete_label("search_music", _input, result) when is_map(result) do
    if tool_result_error?(result) do
      "No track found"
    else
      case first_track_title(result) do
        title when is_binary(title) and title != "" ->
          "Found · #{clip_words(title, @done_label_limit - 8)}"

        _ ->
          "Track ready"
      end
    end
  end

  defp tool_complete_label(tool_name, _input, result) do
    if is_map(result) and tool_result_error?(result) do
      tool_failed_label(tool_name)
    else
      tool_done_label(tool_name)
    end
  end

  defp tool_done_label(tool_name) do
    case tool_name do
      "search_google" -> "Web results in"
      "analyze_image" -> "Image read"
      "analyze_document" -> "Document read"
      "create_document" -> "File ready"
      "find_rows" -> "Rows checked"
      "edit_rows" -> "Rows updated"
      "delete_rows" -> "Rows deleted"
      "export_rows" -> "File exported"
      "delete_document" -> "File removed"
      "post_to_channel" -> "Posted"
      "get_channel_analytics" -> "Stats in"
      "schedule_channel_post" -> "Scheduled"
      "query_event_inbox" -> "Inbox checked"
      "configure_event_inbox" -> "Inbox updated"
      "call_connected_app" -> "App replied"
      "list_platform_connections" -> "Apps listed"
      "call_platform" -> "Connector replied"
      "get_current_agent_config" -> "Config read"
      "update_current_agent_config" -> "Agent updated"
      "create_chat_space" -> "Space created"
      "attach_current_agent_to_chat" -> "Agent attached"
      "inspect_current_agent_tools" -> "Tools checked"
      "test_current_agent_tool" -> "Tool tested"
      "ask_user" -> "Question ready"
      "delegate_to_subagent" -> "Specialist done"
      _ -> "Step done"
    end
  end

  defp tool_failed_label(tool_name) do
    case to_string(tool_name) do
      "search_music" -> "No track found"
      "search_google" -> "Search failed"
      "analyze_image" -> "Image failed"
      "analyze_document" -> "Document failed"
      "delegate_to_subagent" -> "Specialist failed"
      "call_connected_app" -> "App call failed"
      "call_platform" -> "Connector failed"
      "post_to_channel" -> "Post failed"
      "create_document" -> "File failed"
      _ -> "Step failed"
    end
  end

  defp first_track_title(result) do
    (Map.get(result, :tracks) || Map.get(result, "tracks") || [])
    |> List.wrap()
    |> List.first()
    |> case do
      track when is_map(track) -> Map.get(track, :title) || Map.get(track, "title")
      _ -> nil
    end
  end

  # Trim on a word boundary so a note never ends mid-word.
  defp clip_words(text, limit) do
    trimmed = text |> to_string() |> String.split(~r/\s+/u, trim: true) |> Enum.join(" ")

    if String.length(trimmed) <= limit do
      trimmed
    else
      cut = String.slice(trimmed, 0, limit - 1)
      on_word = String.replace(cut, ~r/\s+\S*$/u, "")
      # Keep the word boundary only while it preserves most of the label (a single long token
      # would otherwise be erased entirely).
      base = if String.length(on_word) >= div(limit * 3, 5), do: on_word, else: cut

      base
      |> String.trim_trailing(" -–—·,:(")
      |> Kernel.<>("…")
    end
  end

  defp waiting_for_user_result?(%{content: content}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"status" => "waiting_for_user"}} -> true
      _ -> false
    end
  end

  defp waiting_for_user_result?(_), do: false

  # Cap of events pulled into memory for payload-based aggregation (group_by /
  # metric sums). Exact totals and event_type/source breakdowns are computed in
  # SQL and are NOT bounded by this cap; only payload aggregation samples it.
  @inbox_aggregation_cap 5_000

  defp query_event_inbox(input, agent_id, requester_user_id) do
    with {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id) do
      timeframe =
        resolve_event_timeframe(input["timeframe"] || input["window"] || input["period"])

      source_filter = normalize_tool_string(input["source"])
      event_type_filter = normalize_tool_string(input["event_type"] || input["eventType"])

      event_type_prefix =
        normalize_tool_string(input["event_type_prefix"] || input["eventTypePrefix"])

      group_by = normalize_tool_string(input["group_by"] || input["groupBy"])
      metrics = normalize_metric_paths(input["metrics"])
      limit = normalize_limit(input["limit"], 25, 60)

      base =
        from(e in AgentEvent,
          where:
            e.agent_id == ^agent.id and
              e.occurred_at >= ^timeframe.since and
              e.occurred_at <= ^timeframe.until
        )

      base =
        if is_binary(source_filter),
          do: from(e in base, where: e.source == ^source_filter),
          else: base

      base =
        if is_binary(event_type_filter),
          do: from(e in base, where: e.event_type == ^event_type_filter),
          else: base

      base =
        if is_binary(event_type_prefix),
          do: from(e in base, where: like(e.event_type, ^(event_type_prefix <> "%"))),
          else: base

      # Exact totals, independent of any row limit.
      total_matching = Repo.aggregate(base, :count, :id)
      source_counts = sql_count_by(base, :source)
      event_type_counts = sql_count_by(base, :event_type)

      # Sample (capped) for payload-based aggregation and human-readable rows.
      sample_cap = if(group_by || metrics != [], do: @inbox_aggregation_cap, else: limit)

      sample =
        from(e in base,
          join: t in AgentEventThread,
          on: t.id == e.thread_id,
          order_by: [desc: e.occurred_at, desc: e.inserted_at],
          limit: ^sample_cap,
          select: %{
            id: e.id,
            message_id: e.message_id,
            occurred_at: e.occurred_at,
            source: e.source,
            event_type: e.event_type,
            title: e.title,
            text: e.text,
            payload: e.payload,
            thread_id: t.id,
            thread_key: t.thread_key,
            thread_title: t.title
          }
        )
        |> Repo.all()

      events = Enum.take(sample, limit)
      aggregation_sampled = total_matching > length(sample)

      related_message_ids =
        events |> Enum.map(& &1.message_id) |> Enum.filter(&is_binary/1) |> Enum.uniq()

      base_result = %{
        "ok" => true,
        "timeframe" => %{
          "label" => timeframe.label,
          "since" => DateTime.to_iso8601(timeframe.since),
          "until" => DateTime.to_iso8601(timeframe.until)
        },
        "mode" => current_event_inbox_mode(agent),
        "summary_window_hours" => current_event_inbox_window_hours(agent),
        "total_events" => total_matching,
        "sampled_events" => length(sample),
        "source_counts" => source_counts,
        "event_type_counts" => event_type_counts,
        "events" =>
          Enum.map(events, fn event ->
            %{
              "id" => event.id,
              "message_id" => event.message_id,
              "occurred_at" => DateTime.to_iso8601(event.occurred_at),
              "source" => event.source,
              "event_type" => event.event_type,
              "title" => event.title,
              "text" => event.text,
              "thread_id" => event.thread_id,
              "thread_key" => event.thread_key,
              "thread_title" => event.thread_title,
              "payload" => condensed_payload(event.payload)
            }
          end),
        "summary" =>
          build_event_inbox_summary(
            events,
            total_matching,
            timeframe.label,
            source_filter,
            event_type_filter
          ),
        "related_message_ids" => related_message_ids,
        "related_title" => related_messages_title(length(related_message_ids)),
        "related_subtitle" =>
          if(related_message_ids == [], do: nil, else: "Tap to review the underlying messages")
      }

      base_result
      |> maybe_put_group_counts(group_by, sample)
      |> maybe_put_metric_sums(metrics, sample)
      |> maybe_flag_sampled(aggregation_sampled, group_by, metrics)
    else
      {:error, reason} ->
        %{"ok" => false, "error" => inbox_error_message(reason)}
    end
  end

  defp maybe_put_group_counts(result, nil, _sample), do: result

  defp maybe_put_group_counts(result, group_by, sample) do
    counts = aggregate_group_counts(sample, group_by)

    result
    |> Map.put("group_by", group_by)
    |> Map.put("group_counts", counts)
  end

  defp maybe_put_metric_sums(result, [], _sample), do: result

  defp maybe_put_metric_sums(result, metrics, sample) do
    Map.put(result, "metric_sums", aggregate_metric_sums(sample, metrics))
  end

  defp maybe_flag_sampled(result, true, group_by, metrics)
       when not is_nil(group_by) or metrics != [] do
    result
    |> Map.put("aggregation_sampled", true)
    |> Map.put(
      "aggregation_note",
      "group_by/metrics aggregates cover the most recent #{result["sampled_events"]} of #{result["total_events"]} matching events; totals and breakdowns above are exact."
    )
  end

  defp maybe_flag_sampled(result, _sampled, _group_by, _metrics), do: result

  defp normalize_metric_paths(values) do
    values
    |> List.wrap()
    |> Enum.map(&normalize_tool_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Exact group counts computed in SQL for a top-level column.
  defp sql_count_by(query, column) do
    from(e in query,
      group_by: field(e, ^column),
      select: {field(e, ^column), count(e.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn
      {nil, _count}, acc -> acc
      {key, count}, acc -> Map.put(acc, to_string(key), count)
    end)
  end

  # Group counts over a payload dimension (or event_type/source) from the
  # in-memory sample. Supports arbitrary dotted payload paths (e.g. "a.b.c").
  defp aggregate_group_counts(events, "event_type"), do: count_by(events, & &1.event_type)
  defp aggregate_group_counts(events, "source"), do: count_by(events, & &1.source)

  defp aggregate_group_counts(events, path) do
    segments = String.split(path, ".")

    Enum.reduce(events, %{}, fn event, acc ->
      case dig_payload(event.payload, segments) do
        value when is_binary(value) or is_number(value) or is_boolean(value) ->
          key = to_string(value)
          if key == "", do: acc, else: Map.update(acc, key, 1, &(&1 + 1))

        _ ->
          acc
      end
    end)
  end

  defp aggregate_metric_sums(events, metrics) do
    Enum.reduce(metrics, %{}, fn path, acc ->
      segments = String.split(path, ".")

      sum =
        Enum.reduce(events, 0, fn event, total ->
          total + coerce_number(dig_payload(event.payload, segments))
        end)

      Map.put(acc, path, sum)
    end)
  end

  # Resolve a dotted path against an event payload. Robust to two shapes:
  #   * flat dotted scalar keys, e.g. %{"traffic.sessions" => 12} (how external
  #     senders that flatten nested data deliver analytics), and
  #   * nested maps, e.g. %{"traffic" => %{"sessions" => 12}}, including the case
  #     where an intermediate value arrived as a JSON-encoded string.
  defp dig_payload(payload, segments) when is_map(payload) do
    path = Enum.join(segments, ".")

    case fetch_payload_key(payload, path) do
      {:ok, value} -> value
      :error -> descend_payload(payload, segments)
    end
  end

  defp dig_payload(_payload, _segments), do: nil

  defp descend_payload(payload, [segment | rest]) when is_map(payload) do
    case fetch_payload_key(payload, segment) do
      {:ok, value} when rest == [] -> value
      {:ok, value} -> descend_payload(maybe_decode_json(value), rest)
      :error -> nil
    end
  end

  defp descend_payload(_payload, _segments), do: nil

  defp fetch_payload_key(map, key) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, Map.get(map, key)}

      (atom = safe_atom(key)) && Map.has_key?(map, atom) ->
        {:ok, Map.get(map, atom)}

      true ->
        :error
    end
  end

  defp maybe_decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> value
    end
  end

  defp maybe_decode_json(value), do: value

  defp safe_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp coerce_number(value) when is_number(value), do: value

  defp coerce_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> number
      :error -> 0
    end
  end

  defp coerce_number(_), do: 0

  defp configure_event_inbox(input, agent_id, requester_user_id) do
    with {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id),
         mode <- normalize_event_inbox_mode(input["mode"]),
         {:ok, next_rules} <-
           updated_event_inbox_rules(agent.approval_rules || %{}, mode, input["cadence"]) do
      case Agents.update_agent(agent, %{"approval_rules" => next_rules}, requester_user_id) do
        {:ok, updated_agent} ->
          %{
            "ok" => true,
            "mode" => current_event_inbox_mode(updated_agent),
            "summary_window_hours" => current_event_inbox_window_hours(updated_agent),
            "summary" => event_inbox_config_summary(updated_agent)
          }

        {:error, reason} ->
          %{"ok" => false, "error" => inspect(reason)}
      end
    else
      {:error, reason} ->
        %{"ok" => false, "error" => inbox_error_message(reason)}
    end
  end

  defp get_current_agent_config(input, agent_id, requester_user_id) do
    include_prompt =
      case Map.get(input, "include_prompt") do
        false -> false
        "false" -> false
        "0" -> false
        0 -> false
        _ -> true
      end

    with {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id) do
      %{"ok" => true, "agent" => current_agent_config_payload(agent, include_prompt)}
    else
      {:error, reason} ->
        %{"ok" => false, "error" => inbox_error_message(reason)}
    end
  end

  @doc false
  def update_current_agent_config(input, agent_id, requester_user_id) do
    with {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id),
         {:ok, attrs} <- current_agent_update_attrs(input),
         {:ok, updated_agent} <- persist_current_agent_update(agent, attrs, requester_user_id) do
      %{
        "ok" => true,
        "message" => "Agent updated.",
        "agent" => current_agent_config_payload(updated_agent, true)
      }
    else
      {:error, :no_changes_requested} ->
        %{"ok" => false, "error" => "No agent changes were requested."}

      {:error, :empty_system_prompt} ->
        %{"ok" => false, "error" => "System prompt cannot be empty."}

      {:error, :invalid_enabled_tools} ->
        %{"ok" => false, "error" => "enabled_tools must contain only registered tool ids."}

      {:error, :invalid_output_modes} ->
        %{"ok" => false, "error" => "output_modes must contain only text, media, or voice."}

      {:error, reason} ->
        %{"ok" => false, "error" => inbox_error_message(reason)}
    end
  end

  @doc false
  def inspect_current_agent_tools(_input, agent_id, requester_user_id) do
    with {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id) do
      configured = MapSet.new(agent.enabled_tools || [])

      tools =
        Enum.map(ToolRegistry.tools(), fn tool ->
          enabled = MapSet.member?(configured, tool.id)

          %{
            "id" => tool.id,
            "name" => tool.name,
            "category" => tool.category,
            "enabled" => enabled,
            "always_on" => tool.always_on,
            "effective" => enabled || tool.always_on,
            "testability" => tool.testability
          }
        end)

      %{
        "ok" => true,
        "agent_id" => agent.id,
        "tools" => tools,
        "enabled_tools" => agent.enabled_tools || [],
        "effective_tools" => tools |> Enum.filter(& &1["effective"]) |> Enum.map(& &1["id"]),
        "output_modes" => %{
          "configured" => agent.output_modes || [],
          "supported" => ~w[text media voice]
        }
      }
    else
      {:error, reason} -> %{"ok" => false, "error" => inbox_error_message(reason)}
    end
  end

  @doc false
  def test_current_agent_tool(input, agent_id, requester_user_id) when is_map(input) do
    tool_id = normalize_tool_string(input["tool_id"] || input["toolId"])
    sample_input = input["sample_input"] || input["sampleInput"] || %{}

    with {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id),
         tool when not is_nil(tool) <- ToolRegistry.get(tool_id),
         true <- tool.always_on || tool.id in (agent.enabled_tools || []) do
      test_registered_tool(tool, sample_input)
    else
      nil -> %{"ok" => false, "error" => "Unknown tool id."}
      false -> %{"ok" => false, "error" => "Tool is not enabled for this agent."}
      {:error, reason} -> %{"ok" => false, "error" => inbox_error_message(reason)}
    end
  end

  def test_current_agent_tool(_input, _agent_id, _requester_user_id),
    do: %{"ok" => false, "error" => "Invalid tool test input."}

  @doc false
  def ask_user(input) when is_map(input) do
    questions =
      input
      |> Map.get("questions", [])
      |> normalize_questions()

    if questions == [] do
      %{"ok" => false, "error" => "At least one valid question is required."}
    else
      fallback = Enum.map_join(questions, "\n", & &1["question"])

      %{
        "ok" => true,
        "requestId" => Ecto.UUID.generate(),
        "status" => "waiting_for_user",
        "fallbackText" => fallback,
        "questions" => questions
      }
    end
  end

  def ask_user(_input),
    do: %{"ok" => false, "error" => "At least one valid question is required."}

  defp test_registered_tool(%{id: tool_id, testability: "live_readonly"}, sample_input)
       when tool_id in ["search_google", "search_music"] and is_map(sample_input) do
    case normalize_tool_string(sample_input["query"]) do
      nil ->
        %{
          "ok" => false,
          "tool_id" => tool_id,
          "error" => "An explicit sample_input.query is required for a live read-only test."
        }

      query ->
        result =
          case tool_id do
            "search_google" -> Vibe.AI.Tools.Search.google(%{"query" => query})
            "search_music" -> Vibe.AI.Tools.Music.search(%{"query" => query, "type" => "track"})
          end

        %{
          "ok" => not tool_result_error?(result),
          "tool_id" => tool_id,
          "testability" => "live_readonly",
          "executed" => true,
          "result" => result
        }
    end
  end

  defp test_registered_tool(tool, _sample_input) do
    %{
      "ok" => true,
      "tool_id" => tool.id,
      "testability" => "dry_run",
      "executed" => false,
      "capability" => %{
        "registered" => true,
        "effective" => true,
        "mutation_performed" => false
      }
    }
  end

  defp tool_result_error?(result) when is_map(result) do
    case result[:error] || result["error"] do
      value when is_binary(value) -> true
      %{} -> true
      _ -> (result[:ok] || result["ok"]) == false
    end
  end

  defp tool_result_error?(_), do: false

  defp normalize_questions(value) when is_list(value) do
    value
    |> Enum.map(&normalize_question/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(3)
  end

  defp normalize_questions(_), do: []

  defp normalize_question(question) when is_map(question) do
    text = normalize_display_string(question["question"] || question[:question], 500)
    header = normalize_display_string(question["header"] || question[:header], 12)

    options =
      question
      |> then(&(Map.get(&1, "options") || Map.get(&1, :options) || []))
      |> normalize_question_options()

    if is_binary(text) and is_binary(header) and options != [] do
      %{
        "question" => text,
        "header" => header,
        "multiSelect" =>
          normalize_tool_boolean(
            question["multiSelect"] || question[:multiSelect] ||
              question["multi_select"] || question[:multi_select]
          ),
        "options" => options
      }
    end
  end

  defp normalize_question(_), do: nil

  defp normalize_question_options(value) when is_list(value) do
    value
    |> Enum.map(fn
      option when is_map(option) ->
        label = normalize_display_string(option["label"] || option[:label], 80)

        if is_binary(label) do
          %{
            "label" => label,
            "description" =>
              normalize_display_string(option["description"] || option[:description], 240) || ""
          }
        end

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1["label"])
    |> Enum.take(4)
  end

  defp normalize_question_options(_), do: []

  defp normalize_display_string(value, max_length) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, max_length)
    end
  end

  defp normalize_display_string(_, _), do: nil

  defp normalize_tool_boolean(value) when value in [true, "true", "1", 1], do: true
  defp normalize_tool_boolean(_), do: false

  defp maybe_fast_delegate_current_agent(input, agent_id, requester_user_id) when is_map(input) do
    subagent_id = normalize_tool_string(input["subagent_id"])
    task = Map.get(input, "task")

    with true <- subagent_id in ["builder_assistant", "integration_advisor"],
         true <- current_agent_read_task?(task),
         {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id) do
      {:ok, current_agent_delegation_payload(subagent_id, agent, include_prompt_for_task?(task))}
    else
      _ -> :no_match
    end
  end

  defp maybe_fast_delegate_current_agent(_input, _agent_id, _requester_user_id), do: :no_match

  defp current_agent_read_task?(task) when is_binary(task) do
    text =
      task
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_@\s\/\.\-]+/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    text != "" and read_intent_task?(text) and current_agent_info_task?(text) and
      not mutating_agent_task?(text)
  end

  defp current_agent_read_task?(_task), do: false

  defp read_intent_task?(text) do
    Regex.match?(
      ~r/\b(what|where|which|who|how|show|list|read|get|fetch|check|inspect|review|tell|provide|give|return|explain|help)\b/u,
      text
    )
  end

  defp current_agent_info_task?(text) do
    Regex.match?(
      ~r/\b(current|this|agent|config|configuration|prompt|persona|name|status|tool|endpoint|url|invoke|event|webhook|integration|secret|header|chat\s*id|vibechatid|destination|env|environment|api|base\s*url|identifier|username|inbox|mode|python|curl)\b/u,
      text
    )
  end

  defp mutating_agent_task?(text) do
    Regex.match?(
      ~r/\b(create|update|change|rename|publish|disable|delete|remove|archive|rotate|edit|attach|detach)\b/u,
      text
    )
  end

  defp include_prompt_for_task?(task) when is_binary(task) do
    Regex.match?(~r/\b(prompt|system prompt|instruction|persona)\b/iu, task)
  end

  defp include_prompt_for_task?(_task), do: false

  defp current_agent_delegation_payload(subagent_id, agent, include_prompt) do
    agent_payload = current_agent_config_payload(agent, include_prompt)

    %{
      "ok" => true,
      "subagent_id" => subagent_id,
      "label" => current_agent_delegation_label(subagent_id),
      "response" => current_agent_integration_summary(agent_payload),
      "metadata" => %{
        "fast_path" => "current_agent_config",
        "agent" => agent_payload,
        "integration" => current_agent_integration_metadata(agent_payload)
      }
    }
  end

  defp current_agent_delegation_label("integration_advisor"), do: "Integration Advisor"
  defp current_agent_delegation_label("builder_assistant"), do: "Builder Assistant"
  defp current_agent_delegation_label(_subagent_id), do: "Subagent"

  defp current_agent_integration_summary(agent_payload) do
    [
      "Current agent: #{agent_payload["display_name"] || agent_payload["identifier"]}.",
      "Agent id: #{agent_payload["id"]}.",
      if(agent_payload["username"], do: "Identifier: #{agent_payload["username"]}.", else: nil),
      "Invoke URL: #{agent_payload["invoke_url"]}.",
      "Events URL: #{agent_payload["events_url"]}.",
      "Default destination chat id: #{agent_payload["default_destination_chat_id"] || "not configured"}.",
      "Incoming chat: #{if(agent_payload["incoming_chat_enabled"], do: "enabled", else: "disabled")}.",
      "Inbox mode: #{agent_payload["event_inbox_mode"]}."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp current_agent_integration_metadata(agent_payload) do
    %{
      "agent_id" => agent_payload["id"],
      "identifier" => agent_payload["identifier"],
      "username" => agent_payload["username"],
      "api_base_url" => agent_payload["api_base_url"],
      "invoke_url" => agent_payload["invoke_url"],
      "events_url" => agent_payload["events_url"],
      "default_destination_chat_id" => agent_payload["default_destination_chat_id"],
      "attached_chats" => agent_payload["attached_chats"] || [],
      "incoming_chat_enabled" => agent_payload["incoming_chat_enabled"],
      "event_inbox_mode" => agent_payload["event_inbox_mode"],
      "headers" => %{"X-Vibe-Agent-Secret" => "<agent secret>"}
    }
  end

  defp persist_current_agent_update(agent, attrs, requester_user_id) do
    status = Map.get(attrs, "status")
    update_attrs = Map.delete(attrs, "status")

    with {:ok, updated_agent} <-
           if(map_size(update_attrs) > 0,
             do: Agents.update_agent(agent, update_attrs, requester_user_id),
             else: {:ok, agent}
           ) do
      case status do
        nil ->
          {:ok, updated_agent}

        "published" ->
          Agents.publish_agent(updated_agent, requester_user_id)

        "draft" ->
          Agents.update_agent(updated_agent, %{"status" => "draft"}, requester_user_id)

        "disabled" ->
          Agents.update_agent(updated_agent, %{"status" => "disabled"}, requester_user_id)

        _ ->
          {:error, :invalid_status}
      end
    end
  end

  defp current_agent_update_attrs(input) when is_map(input) do
    base_attrs =
      %{}
      |> maybe_put_trimmed(input, "display_name")
      |> maybe_put_trimmed(input, "persona")
      |> maybe_put_trimmed(input, "welcome_message")
      |> maybe_put_trimmed(input, "avatar_url")
      |> maybe_put_trimmed(input, "voice_profile")
      |> maybe_put_status(input)

    with {:ok, attrs} <- maybe_put_tool_list(base_attrs, input),
         {:ok, attrs} <- maybe_put_output_modes(attrs, input),
         {:ok, attrs} <- maybe_put_system_prompt(attrs, input) do
      if map_size(attrs) == 0, do: {:error, :no_changes_requested}, else: {:ok, attrs}
    end
  end

  defp current_agent_update_attrs(_input), do: {:error, :no_changes_requested}

  defp maybe_put_tool_list(attrs, input) do
    case Map.fetch(input, "enabled_tools") do
      :error ->
        {:ok, attrs}

      {:ok, tools} when is_list(tools) ->
        normalized_input = Enum.map(tools, &normalize_tool_string/1) |> Enum.reject(&is_nil/1)

        if Enum.all?(normalized_input, &(&1 in ToolRegistry.tool_ids())) do
          {:ok, Map.put(attrs, "enabled_tools", Agents.normalize_enabled_tools(normalized_input))}
        else
          {:error, :invalid_enabled_tools}
        end

      _ ->
        {:error, :invalid_enabled_tools}
    end
  end

  defp maybe_put_output_modes(attrs, input) do
    case Map.fetch(input, "output_modes") do
      :error ->
        {:ok, attrs}

      {:ok, modes} when is_list(modes) ->
        normalized_input = Enum.map(modes, &normalize_tool_string/1) |> Enum.reject(&is_nil/1)

        if Enum.all?(normalized_input, &(&1 in ~w[text media voice])) do
          {:ok, Map.put(attrs, "output_modes", Agents.normalize_output_modes(normalized_input))}
        else
          {:error, :invalid_output_modes}
        end

      _ ->
        {:error, :invalid_output_modes}
    end
  end

  defp maybe_put_system_prompt(attrs, input) do
    case Map.fetch(input, "system_prompt") do
      {:ok, prompt} when is_binary(prompt) ->
        case String.trim(prompt) do
          "" -> {:error, :empty_system_prompt}
          trimmed -> {:ok, Map.put(attrs, "system_prompt", trimmed)}
        end

      {:ok, _other} ->
        {:error, :empty_system_prompt}

      :error ->
        {:ok, attrs}
    end
  end

  defp maybe_put_trimmed(attrs, input, key) do
    case Map.fetch(input, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> attrs
          trimmed -> Map.put(attrs, key, trimmed)
        end

      _ ->
        attrs
    end
  end

  defp maybe_put_status(attrs, input) do
    case Map.get(input, "status") do
      value when value in ["draft", "published", "disabled"] -> Map.put(attrs, "status", value)
      _ -> attrs
    end
  end

  defp current_agent_config_payload(agent, include_prompt) do
    payload = Agents.agent_payload(agent)
    attached_chats = Enum.map(payload.attachedChats || [], &chat_payload/1)

    default_destination_chat =
      attached_chats
      |> Enum.find(fn chat -> chat["chat_id"] == payload.defaultDestinationChatId end)
      |> case do
        nil when is_binary(payload.defaultDestinationChatId) ->
          %{"chat_id" => payload.defaultDestinationChatId}

        found ->
          found
      end

    %{
      "id" => payload.id,
      "display_name" => payload.displayName,
      "username" => payload.username,
      "identifier" => payload.username || payload.id,
      "status" => payload.status,
      "persona" => payload.persona,
      "welcome_message" => payload.welcomeMessage,
      "enabled_tools" => payload.enabledTools || [],
      "output_modes" => payload.outputModes || [],
      "voice_profile" => payload.voiceProfile,
      "callback_url" => payload.callbackUrl,
      "api_base_url" => public_base_url(),
      "invoke_url" => build_invoke_url(agent),
      "events_url" => build_events_url(agent),
      "default_destination_chat_id" => payload.defaultDestinationChatId,
      "default_destination_chat" => default_destination_chat,
      "attached_chats" => attached_chats,
      "incoming_chat_enabled" => Agents.incoming_chat_enabled?(agent),
      "event_inbox_mode" => current_event_inbox_mode(agent),
      "summary_window_hours" => current_event_inbox_window_hours(agent),
      "prompt_status" =>
        if(String.trim(agent.system_prompt || "") == "", do: "Missing", else: "Custom"),
      "prompt_preview" => condensed_prompt_preview(agent.system_prompt)
    }
    |> maybe_put("system_prompt", if(include_prompt, do: agent.system_prompt, else: nil))
  end

  defp chat_payload(%{} = chat) do
    %{}
    |> maybe_put("chat_id", Map.get(chat, :chatId) || Map.get(chat, "chatId"))
    |> maybe_put("type", Map.get(chat, :type) || Map.get(chat, "type"))
    |> maybe_put("name", Map.get(chat, :name) || Map.get(chat, "name"))
    |> maybe_put("avatar_url", Map.get(chat, :avatarUrl) || Map.get(chat, "avatarUrl"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp condensed_prompt_preview(prompt) when is_binary(prompt) do
    prompt
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> case do
      "" -> nil
      text -> String.slice(text, 0, 180)
    end
  end

  defp condensed_prompt_preview(_prompt), do: nil

  defp build_invoke_url(%AgentSchema{id: id}) do
    path = "/api/agents/#{id}/invoke"
    append_public_path(path)
  end

  defp build_events_url(%AgentSchema{id: id}) do
    path = "/api/agents/#{id}/events"
    append_public_path(path)
  end

  defp append_public_path(path) do
    case public_base_url() do
      "" -> path
      base -> String.trim_trailing(base, "/") <> path
    end
  end

  defp public_base_url do
    System.get_env("PUBLIC_BASE_URL") ||
      System.get_env("API_BASE_URL") ||
      endpoint_url()
  end

  defp endpoint_url do
    try do
      VibeWeb.Endpoint.url()
    rescue
      _ -> ""
    end
  end

  defp resolve_owned_agent(agent_id, requester_user_id)
       when is_binary(agent_id) and is_binary(requester_user_id) do
    case Agents.get_agent(agent_id, requester_user_id) do
      %AgentSchema{} = agent -> {:ok, agent}
      nil -> {:error, :agent_not_available}
    end
  end

  defp resolve_owned_agent(_agent_id, _requester_user_id), do: {:error, :owner_lookup_required}

  defp resolve_event_timeframe(raw) do
    now = DateTime.utc_now()
    normalized = normalize_tool_string(raw) || "last 24h"

    case normalized do
      "today" ->
        date = Date.utc_today()
        %{label: "today", since: DateTime.new!(date, ~T[00:00:00], "Etc/UTC"), until: now}

      "yesterday" ->
        date = Date.add(Date.utc_today(), -1)

        %{
          label: "yesterday",
          since: DateTime.new!(date, ~T[00:00:00], "Etc/UTC"),
          until: DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
        }

      "daily" ->
        %{label: "last 24h", since: DateTime.add(now, -24 * 3600, :second), until: now}

      "last 4h" ->
        %{label: "last 4h", since: DateTime.add(now, -4 * 3600, :second), until: now}

      "last 24h" ->
        %{label: "last 24h", since: DateTime.add(now, -24 * 3600, :second), until: now}

      "last 7d" ->
        %{label: "last 7d", since: DateTime.add(now, -7 * 24 * 3600, :second), until: now}

      other ->
        case Regex.run(~r/^last\s+(\d+)\s*(h|hr|hrs|hour|hours|d|day|days)$/u, other) do
          [_, amount_raw, unit] ->
            amount = String.to_integer(amount_raw)

            seconds =
              case unit do
                unit when unit in ["d", "day", "days"] -> amount * 24 * 3600
                _ -> amount * 3600
              end

            %{label: other, since: DateTime.add(now, -seconds, :second), until: now}

          _ ->
            %{label: "last 24h", since: DateTime.add(now, -24 * 3600, :second), until: now}
        end
    end
  end

  defp build_event_inbox_summary(
         events,
         total_matching,
         timeframe_label,
         source_filter,
         event_type_filter
       ) do
    headline =
      "Found #{total_matching} event#{if total_matching == 1, do: "", else: "s"} in #{timeframe_label}."

    filters =
      [
        if(source_filter, do: "Source: #{source_filter}.", else: nil),
        if(event_type_filter, do: "Type: #{event_type_filter}.", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    timeline =
      events
      |> Enum.take(5)
      |> Enum.reverse()
      |> Enum.map(fn event ->
        "#{format_event_time(event.occurred_at)} #{event.title || event.event_type}"
      end)
      |> case do
        [] -> nil
        lines -> "Latest: " <> Enum.join(lines, " | ")
      end

    [headline, filters, timeline]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp format_event_time(%DateTime{} = value) do
    Calendar.strftime(value, "%b %d %H:%M")
  rescue
    _ -> DateTime.to_iso8601(value)
  end

  defp condensed_payload(payload) when is_map(payload) do
    # Senders that flatten nested data deliver grouped analytics sections as
    # JSON-encoded strings. Decode them back so the model sees structured numbers
    # (e.g. traffic/commerce/funnel summary blobs) instead of opaque strings.
    payload
    |> Enum.map(fn {key, value} -> {to_string(key), maybe_decode_json(value)} end)
    |> Enum.take(40)
    |> Enum.into(%{})
  end

  defp condensed_payload(_), do: %{}

  defp count_by(events, mapper) when is_list(events) do
    events
    |> Enum.reduce(%{}, fn event, acc ->
      key = mapper.(event)

      if is_binary(key) and key != "" do
        Map.update(acc, key, 1, &(&1 + 1))
      else
        acc
      end
    end)
  end

  defp current_event_inbox_mode(%AgentSchema{} = agent) do
    agent.approval_rules
    |> Map.get("event_inbox", %{})
    |> Map.get("mode")
    |> normalize_event_inbox_mode()
  end

  defp current_event_inbox_window_hours(%AgentSchema{} = agent) do
    agent.approval_rules
    |> Map.get("event_inbox", %{})
    |> Map.get("summary_window_hours")
    |> normalize_summary_window_hours()
  end

  defp updated_event_inbox_rules(rules, "per_event", _cadence) do
    {:ok, Map.put(rules, "event_inbox", %{"mode" => "per_event", "summary_window_hours" => 24})}
  end

  defp updated_event_inbox_rules(rules, "batched_summary", cadence) do
    {:ok,
     Map.put(rules, "event_inbox", %{
       "mode" => "batched_summary",
       "summary_window_hours" => normalize_summary_window_hours(cadence)
     })}
  end

  defp updated_event_inbox_rules(_rules, _mode, _cadence), do: {:error, :invalid_mode}

  defp event_inbox_config_summary(%AgentSchema{} = agent) do
    case current_event_inbox_mode(agent) do
      "batched_summary" ->
        "Inbox mode is batched_summary every #{current_event_inbox_window_hours(agent)}h."

      _ ->
        "Inbox mode is per_event."
    end
  end

  defp normalize_event_inbox_mode(value) do
    case normalize_tool_string(value) do
      "batched_summary" -> "batched_summary"
      "batched" -> "batched_summary"
      "batch" -> "batched_summary"
      "summary" -> "batched_summary"
      "per_event" -> "per_event"
      "default" -> "per_event"
      "live" -> "per_event"
      _ -> "per_event"
    end
  end

  defp normalize_summary_window_hours(value) do
    case normalize_tool_string(value) do
      "4h" ->
        4

      "4" ->
        4

      "daily" ->
        24

      "24h" ->
        24

      "24" ->
        24

      _ ->
        case normalize_limit(value, 24, 168) do
          hours when is_integer(hours) and hours > 0 -> hours
          _ -> 24
        end
    end
  end

  defp normalize_limit(value, _default, max_limit) when is_integer(value) do
    min(max(value, 1), max_limit)
  end

  defp normalize_limit(value, default, max_limit) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> normalize_limit(parsed, default, max_limit)
      :error -> default
    end
  end

  defp normalize_limit(_value, default, _max_limit), do: default

  defp normalize_tool_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_tool_string(_), do: nil

  defp related_messages_title(count) when count <= 1, do: "Related message"
  defp related_messages_title(count), do: "#{count} related messages"

  defp inbox_error_message(:owner_lookup_required),
    do: "Owner lookup is required for inbox tools."

  defp inbox_error_message(:agent_not_available),
    do: "This inbox is not available in the current chat."

  defp inbox_error_message(:invalid_mode), do: "That inbox mode is not supported."
  defp inbox_error_message(reason), do: inspect(reason)

  defp filter_tools(enabled_tools) do
    allowed = MapSet.new(List.wrap(enabled_tools) |> Enum.map(&to_string/1))

    Enum.filter(available_tools(), fn tool ->
      MapSet.member?(allowed, tool.name) or tool.name in @always_available_tool_names
    end)
  end

  @doc false
  def effective_tool_names(enabled_tools) do
    enabled_tools
    |> filter_tools()
    |> Enum.map(& &1.name)
  end
end
