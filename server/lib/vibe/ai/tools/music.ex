defmodule Vibe.AI.Tools.Music do
  @moduledoc """
  Music search + URL resolve tool using yt-dlp for free, full-length audio streaming.

  Architecture:
  1. If the query is a music page URL (SoundCloud, YouTube, …), resolve it with yt-dlp
  2. Else check database cache, then YouTube search via yt-dlp
  3. Cache results (stream URLs expire; playback uses `/api/music/stream/:id`)
  4. Agent turn pipeline turns tracks into playable `music` rich messages

  Supported URL hosts include SoundCloud and YouTube (and other yt-dlp extractors).
  """

  require Logger

  alias Vibe.MusicCache
  alias Vibe.AI.Tools.YtDlp

  @doc """
  Search for music or resolve a share URL into playable track(s).

  Params:
  - `query` (required for search) — song/artist text **or** a SoundCloud/YouTube URL
  - `url` (optional) — explicit page URL; takes precedence over query when present
  - `type` — track | album | artist (search only)
  - `max_results` — 1..5 (default 1)
  """
  def search(params, opts \\ [])

  def search(params, opts) when is_map(params) do
    url = extract_url(params)
    query = extract_query(params)
    max_results = normalize_max_results(params["max_results"] || params[:max_results])
    type = params["type"] || "track"
    step = step_reporter(opts)

    cond do
      is_binary(url) ->
        Logger.info("[Music] Resolving URL: #{url}")
        resolve_page_url(url, step)

      is_binary(query) and YtDlp.music_page_url?(query) ->
        Logger.info("[Music] Resolving music page from query: #{query}")
        resolve_page_url(String.trim(query), step)

      is_binary(query) ->
        Logger.info("[Music] Searching for: #{query} (type: #{type}, max_results: #{max_results})")

        result =
          case check_cache(query) do
            {:ok, cached_tracks} when cached_tracks != [] ->
              Logger.info("[Music] Cache hit! Returning #{length(cached_tracks)} cached tracks")
              step.("Reading saved track…")
              format_cached_results(cached_tracks)

            _ ->
              step.("Asking YouTube…")
              search_fresh(query, type, step)
          end

        limit_tracks(result, max_results)

      true ->
        Logger.error("[Music] Called with invalid params: #{inspect(params)}")
        %{error: "Missing search query or url"}
    end
  end

  def search(params, _opts) do
    Logger.error("[Music] Called with invalid params: #{inspect(params)}")
    %{error: "Missing search query"}
  end

  # Intermediate progress beats. A URL resolve or a fresh search takes 2-5s; the caller passes
  # `on_step` so the note can advance while it waits instead of freezing on one label.
  defp step_reporter(opts) do
    case Keyword.get(opts, :on_step) do
      fun when is_function(fun, 1) -> fn label -> fun.(label) end
      _ -> fn _label -> :ok end
    end
  end

  # ── URL resolve (SoundCloud / YouTube / …) ──────────────────────────────

  defp resolve_page_url(url, step) do
    step.("Reading track info…")

    case YtDlp.resolve_url(url) do
      {:ok, track} ->
        # Guarantee a resolvable page URL survives into the payload + cache. A bare
        # sc_* SoundCloud id is the ONLY id type /api/music/stream/:id cannot rebuild
        # without a stored page URL, so if yt-dlp ever omits webpage_url, backfill the
        # share `url` we just resolved from — it IS that page.
        track = backfill_page_link(track, url)

        Logger.info(
          "[Music] Resolved #{track[:source]} track=#{track[:video_id]} title=#{inspect(track[:title])}"
        )

        # Persist SYNCHRONOUSLY (and read back to confirm) before the playable card
        # ships. The old fire-and-forget spawn could lose the race or die on error,
        # leaving no cache row — then the stream endpoint falls back to the bare sc_*
        # id and 500s ("Missing SoundCloud source URL in cache"). For SoundCloud a
        # committed row is mandatory for playback.
        step.("Preparing audio…")
        cached? = cache_track_now(url, track)

        if streamable?(track, cached?) do
          format_resolved_track(track)
        else
          # Never surface a SoundCloud card that can't stream (no committed row / no
          # page URL) — it would 500 on the first tap. Fail the resolve cleanly.
          Logger.error(
            "[Music] Refusing unplayable track=#{track[:video_id]} source=#{track[:source]} cached?=#{cached?}"
          )

          %{
            error:
              "Could not load audio from that link. Supported: SoundCloud, YouTube, and other yt-dlp music pages."
          }
        end

      {:error, reason} ->
        Logger.error("[Music] URL resolve failed: #{inspect(reason)}")

        %{
          error:
            "Could not load audio from that link. Supported: SoundCloud, YouTube, and other yt-dlp music pages."
        }
    end
  end

  defp format_resolved_track(track) when is_map(track) do
    formatted = %{
      video_id: track[:video_id] || track[:id],
      title: track[:title],
      artist: track[:artist],
      album: track[:album],
      duration: track[:duration],
      duration_seconds: track[:duration_seconds],
      preview_url: track[:stream_url] || track[:preview_url],
      cover: track[:cover],
      links: track[:links] || %{}
    }

    source = track[:source] || "web"

    %{
      source: source,
      count: 1,
      primary: formatted,
      alternatives: [],
      tracks: [formatted]
    }
  end

  # Ensure the track carries a resolvable page URL in :links so /api/music/stream
  # can re-extract later. Prefer what yt-dlp returned; fall back to the page we
  # resolved from (only when that really is a music page URL).
  defp backfill_page_link(track, source_url) when is_map(track) do
    links = track[:links] || %{}

    if has_page_link?(links) or not YtDlp.music_page_url?(source_url) do
      track
    else
      Map.put(track, :links, Map.put(links, "webpage_url", source_url))
    end
  end

  defp backfill_page_link(track, _source_url), do: track

  # A cached row can re-extract audio only if it stores a real page URL.
  defp has_page_link?(links) when is_map(links) do
    (is_binary(links["webpage_url"]) and links["webpage_url"] != "") or
      (is_binary(links[:webpage_url]) and links[:webpage_url] != "") or
      (is_binary(links["soundcloud"]) and links["soundcloud"] != "") or
      (is_binary(links["youtube"]) and links["youtube"] != "")
  end

  defp has_page_link?(_), do: false

  # Would /api/music/stream/:id be able to play this track?
  #  • SoundCloud (sc_*) — ONLY if a cache row committed AND it carries a page URL,
  #    because a bare sc_* cannot be rebuilt from the id alone.
  #  • YouTube/other — the id re-resolves to a watch URL with no cache row needed.
  defp streamable?(track, cached?) when is_map(track) do
    video_id = to_string(track[:video_id] || track[:id] || "")

    cond do
      String.starts_with?(video_id, "sc_") -> cached? and has_page_link?(track[:links] || %{})
      video_id != "" -> true
      true -> false
    end
  end

  # Persist synchronously and confirm the row is really queryable before we let the
  # card ship. MusicCache.cache_results swallows changeset errors (logs a warning),
  # so a read-back is the only trustworthy signal that the write actually landed.
  defp cache_track_now(query, track) do
    video_id = track[:video_id] || track[:id]
    cache_results(query, [track], track[:source] || "web")

    committed? = is_binary(video_id) and not is_nil(MusicCache.get_by_video_id(video_id))

    unless committed? do
      Logger.error("[Music] Cache write did not land for #{inspect(video_id)}")
    end

    committed?
  rescue
    e ->
      Logger.error(
        "[Music] Sync cache write failed for #{inspect(track[:video_id])}: #{inspect(e)}"
      )

      false
  end

  # Default to a single best match; the agent opts into more only when the user
  # explicitly asks for options. Clamp to a sane 1..5 range.
  defp normalize_max_results(value) do
    n =
      cond do
        is_integer(value) ->
          value

        is_binary(value) ->
          case Integer.parse(value) do
            {i, _} -> i
            :error -> 1
          end

        true ->
          1
      end

    n |> max(1) |> min(5)
  end

  # Trim the emitted track list to the requested count without losing the
  # source/primary metadata the rest of the pipeline expects. `count` and `alternatives`
  # must be clamped too: leaving them at the unclamped values told the model it had 3
  # results and handed it two extra tracks it was instructed not to mention.
  defp limit_tracks(%{tracks: tracks} = result, max_results) when is_list(tracks) do
    kept = Enum.take(tracks, max_results)

    result
    |> Map.put(:tracks, kept)
    |> Map.put(:count, length(kept))
    |> Map.put(:alternatives, kept |> Enum.drop(1))
  end

  defp limit_tracks(result, _max_results), do: result

  defp extract_url(params) do
    raw = params["url"] || params[:url] || params["link"] || params[:link]

    case normalize_string(raw) do
      nil -> nil
      value -> if YtDlp.music_page_url?(value) or String.starts_with?(value, "http"), do: value
    end
  end

  defp extract_query(params) do
    normalize_string(params["query"] || params[:query])
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  # Check database cache for this query
  defp check_cache(query) do
    try do
      cached = MusicCache.get_cached(query)

      if cached != [] do
        {:ok, cached}
      else
        {:ok, []}
      end
    rescue
      e ->
        Logger.warning("[Music] Cache lookup failed: #{inspect(e)}")
        {:error, :cache_error}
    end
  end

  # Fresh search using yt-dlp - FAST mode (metadata only, no stream extraction)
  defp search_fresh(query, _type, step) do
    # Use fast flat-playlist search (just metadata, no stream URLs)
    # Stream URLs will be fetched on-demand when user plays
    # Return 1 primary result + up to 2 alternatives
    limit = 3

    case YtDlp.search(query, limit: limit) do
      {:ok, tracks} when tracks != [] ->
        Logger.info("[Music] yt-dlp returned #{length(tracks)} results (fast mode)")
        step.("Reading results…")

        # Cache metadata for future requests
        spawn(fn -> cache_results(query, tracks, "youtube") end)

        format_ytdlp_results(tracks)

      {:ok, []} ->
        # If exact match fails, try adding "audio" to query
        Logger.info("[Music] Initial search failed, trying with 'audio' suffix")
        step.("Widening search…")
        retry_search(query <> " audio")

      {:error, reason} ->
        Logger.error("[Music] yt-dlp failed: #{reason}")
        %{error: "Could not find that song. Please try again."}
    end
  end

  defp retry_search(query) do
    case YtDlp.search(query, limit: 1) do
      {:ok, tracks} when tracks != [] ->
        spawn(fn -> cache_results(query, tracks, "youtube") end)
        format_ytdlp_results(tracks)

      _ ->
        %{error: "No results found for music query"}
    end
  end

  # Cache results to database
  defp cache_results(query, tracks, source) do
    try do
      MusicCache.cache_results(query, tracks, source || "youtube")
      Logger.info("[Music] Cached #{length(tracks)} tracks for query: #{query}")
    rescue
      e -> Logger.warning("[Music] Failed to cache results: #{inspect(e)}")
    end
  end

  # Format yt-dlp results (handles both flat-playlist and full extraction)
  # Returns primary track first, then alternatives
  defp format_ytdlp_results(tracks) do
    formatted =
      Enum.map(tracks, fn track ->
        video_id = track[:video_id] || track[:id]
        source = track[:source] || "youtube"

        links =
          track[:links] ||
            %{
              "webpage_url" => track[:webpage_url] || track[:url] ||
                "https://www.youtube.com/watch?v=#{video_id}",
              "youtube" => "https://www.youtube.com/watch?v=#{video_id}",
              "youtube_music" => "https://music.youtube.com/watch?v=#{video_id}"
            }

        %{
          # Critical for backend proxy to fetch stream on-demand
          video_id: video_id,
          title: track[:title],
          artist: track[:artist],
          album: nil,
          duration: track[:duration],
          # For flat-playlist mode, stream_url is nil — fetched via /api/music/stream/:id
          preview_url: track[:stream_url] || track[:preview_url],
          cover: track[:cover],
          links: links,
          source: source
        }
      end)

    # Split into primary and alternatives
    {primary, alternatives} =
      case formatted do
        [first | rest] -> {first, rest}
        [] -> {nil, []}
      end

    %{
      source: "youtube",
      count: length(formatted),
      primary: primary,
      alternatives: alternatives,
      # Keep full list for backwards compatibility
      tracks: formatted
    }
  end

  # Format cached results
  defp format_cached_results(cached_tracks) do
    formatted =
      Enum.map(cached_tracks, fn track ->
        %{
          video_id: track.video_id,
          title: track.title,
          artist: track.artist,
          album: track.album,
          duration: track.duration,
          preview_url: track.stream_url || track.preview_url,
          cover: track.cover_url,
          links: track.external_links || %{},
          source: track.source
        }
      end)

    %{
      source: "cache",
      count: length(formatted),
      tracks: formatted
    }
  end
end
