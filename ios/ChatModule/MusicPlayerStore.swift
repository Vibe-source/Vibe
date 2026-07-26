import CryptoKit
import Foundation

enum NativeMusicPlayerQueueOrderMode: String, CaseIterable {
  case forward
  case reverse
  case random

  func next() -> NativeMusicPlayerQueueOrderMode {
    switch self {
    case .forward:
      return .reverse
    case .reverse:
      return .random
    case .random:
      return .forward
    }
  }
}

struct NativeMusicPlayerTrack: Codable, Equatable {
  let trackId: String
  var videoId: String?
  var id: String?
  var source: String?
  var title: String
  var artist: String
  var album: String?
  var duration: String?
  var durationSeconds: Double?
  var cover: String?
  var previewURL: String?
  var streamURL: String?
  var localURI: String?
  var cachedAt: Double?
  var playCount: Int
  var lastPlayedAt: Double?
  var links: [String: String]

  init(
    trackId: String,
    videoId: String? = nil,
    id: String? = nil,
    source: String? = nil,
    title: String,
    artist: String,
    album: String? = nil,
    duration: String? = nil,
    durationSeconds: Double? = nil,
    cover: String? = nil,
    previewURL: String? = nil,
    streamURL: String? = nil,
    localURI: String? = nil,
    cachedAt: Double? = nil,
    playCount: Int = 0,
    lastPlayedAt: Double? = nil,
    links: [String: String] = [:]
  ) {
    self.trackId = trackId
    self.videoId = videoId
    self.id = id
    self.source = source
    self.title = title
    self.artist = artist
    self.album = album
    self.duration = duration
    self.durationSeconds = durationSeconds
    self.cover = cover
    self.previewURL = previewURL
    self.streamURL = streamURL
    self.localURI = localURI
    self.cachedAt = cachedAt
    self.playCount = playCount
    self.lastPlayedAt = lastPlayedAt
    self.links = links
  }

  static func resolveTrackId(from payload: [String: Any]) -> String? {
    let candidates: [Any?] = [
      payload["trackId"],
      payload["track_id"],
      payload["videoId"],
      payload["video_id"],
      payload["id"],
      payload["previewUrl"],
      payload["preview_url"],
      payload["streamUrl"],
      payload["stream_url"],
      payload["mediaUrl"],
      payload["media_url"],
      payload["localUri"],
      payload["local_uri"],
    ]
    for candidate in candidates {
      if let value = Self.stringValue(candidate) {
        return value
      }
    }
    return nil
  }

  init?(payload: [String: Any]) {
    guard let trackId = Self.resolveTrackId(from: payload) else { return nil }
    let titleRaw =
      Self.stringValue(payload["title"])
      ?? Self.stringValue(payload["name"])
      ?? Self.stringValue(payload["fileName"])
      ?? Self.stringValue(payload["file_name"])
    let titleTrimmed = titleRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let title = titleTrimmed
    let artist =
      Self.stringValue(payload["artist"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !title.isEmpty else { return nil }

    self.trackId = trackId
    self.videoId = Self.stringValue(payload["videoId"]) ?? Self.stringValue(payload["video_id"])
    self.id = Self.stringValue(payload["id"])
    self.source = Self.stringValue(payload["source"])
    self.title = title
    self.artist = artist.isEmpty ? "Unknown Artist" : artist
    self.album = Self.stringValue(payload["album"])
    self.duration = Self.durationLabel(from: payload)
    self.durationSeconds = Self.durationSeconds(from: payload)
    self.cover =
      Self.stringValue(payload["cover"])
      ?? Self.stringValue(payload["thumbnail"])
      ?? Self.stringValue(payload["artwork"])
    self.previewURL =
      Self.stringValue(payload["previewUrl"])
      ?? Self.stringValue(payload["preview_url"])
      ?? Self.stringValue(payload["mediaUrl"])
      ?? Self.stringValue(payload["media_url"])
    self.streamURL =
      Self.stringValue(payload["streamUrl"])
      ?? Self.stringValue(payload["stream_url"])
      ?? Self.stringValue(payload["mediaUrl"])
      ?? Self.stringValue(payload["media_url"])
    self.localURI =
      Self.stringValue(payload["localUri"]) ?? Self.stringValue(payload["local_uri"])
    self.cachedAt =
      Self.doubleValue(payload["cachedAt"]) ?? Self.doubleValue(payload["cached_at"])
    self.playCount =
      Self.intValue(payload["playCount"])
      ?? Self.intValue(payload["play_count"])
      ?? 0
    self.lastPlayedAt =
      Self.doubleValue(payload["lastPlayedAt"])
      ?? Self.doubleValue(payload["last_played_at"])
    var links = Self.linksValue(from: payload["links"])
    if links["chat_id"] == nil {
      if let chatId = Self.stringValue(payload["chat_id"]) ?? Self.stringValue(payload["chatId"]) {
        links["chat_id"] = chatId
      }
    }
    self.links = links
  }

  func applying(payload: [String: Any]) -> NativeMusicPlayerTrack {
    var next = self
    if let value = Self.stringValue(payload["videoId"]) ?? Self.stringValue(payload["video_id"]),
      !value.isEmpty
    {
      next.videoId = value
    }
    if let value = Self.stringValue(payload["id"]), !value.isEmpty { next.id = value }
    if let value = Self.stringValue(payload["source"]), !value.isEmpty { next.source = value }
    if let value = Self.stringValue(payload["title"]) ?? Self.stringValue(payload["name"]),
      !value.isEmpty
    {
      next.title = value
    }
    if let value = Self.stringValue(payload["artist"]), !value.isEmpty { next.artist = value }
    if let value = Self.stringValue(payload["album"]), !value.isEmpty { next.album = value }
    if let value = Self.durationLabel(from: payload), !value.isEmpty { next.duration = value }
    if let value = Self.durationSeconds(from: payload) {
      next.durationSeconds = value
    }
    if let value =
      Self.stringValue(payload["cover"])
      ?? Self.stringValue(payload["thumbnail"])
      ?? Self.stringValue(payload["artwork"]),
      !value.isEmpty
    {
      next.cover = value
    }
    if let value =
      Self.stringValue(payload["previewUrl"])
      ?? Self.stringValue(payload["preview_url"])
      ?? Self.stringValue(payload["mediaUrl"])
      ?? Self.stringValue(payload["media_url"]),
      !value.isEmpty
    {
      next.previewURL = value
    }
    if let value =
      Self.stringValue(payload["streamUrl"])
      ?? Self.stringValue(payload["stream_url"])
      ?? Self.stringValue(payload["mediaUrl"])
      ?? Self.stringValue(payload["media_url"]),
      !value.isEmpty
    {
      next.streamURL = value
    }
    if let value = Self.stringValue(payload["localUri"]) ?? Self.stringValue(payload["local_uri"]),
      !value.isEmpty
    {
      next.localURI = value
    }
    if let value = Self.doubleValue(payload["cachedAt"]) ?? Self.doubleValue(payload["cached_at"])
    {
      next.cachedAt = value
    }
    if let value = Self.intValue(payload["playCount"]) ?? Self.intValue(payload["play_count"]) {
      next.playCount = value
    }
    if let value =
      Self.doubleValue(payload["lastPlayedAt"]) ?? Self.doubleValue(payload["last_played_at"])
    {
      next.lastPlayedAt = value
    }
    let links = Self.linksValue(from: payload["links"])
    if !links.isEmpty {
      next.links = links
    }
    return next
  }

  private static func stringValue(_ raw: Any?) -> String? {
    if let value = raw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = raw as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func doubleValue(_ raw: Any?) -> Double? {
    if let value = raw as? Double, value.isFinite { return value }
    if let value = raw as? Float, value.isFinite { return Double(value) }
    if let value = raw as? NSNumber { return value.doubleValue }
    if let value = raw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return Double(trimmed)
    }
    return nil
  }

  private static func intValue(_ raw: Any?) -> Int? {
    if let value = raw as? Int { return value }
    if let value = raw as? NSNumber { return value.intValue }
    if let value = raw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return Int(trimmed)
    }
    return nil
  }

  private static func durationSeconds(from payload: [String: Any]) -> Double? {
    if let value =
      doubleValue(payload["durationSeconds"]) ?? doubleValue(payload["duration_seconds"])
    {
      // Values that look like milliseconds.
      return value > 10_000 ? value / 1000.0 : value
    }
    if let value = doubleValue(payload["duration"]) {
      return value > 10_000 ? value / 1000.0 : value
    }
    if let label = stringValue(payload["duration"]) {
      let parts = label.split(separator: ":").compactMap { Double($0) }
      if parts.count == 2 { return parts[0] * 60.0 + parts[1] }
      if parts.count == 3 { return parts[0] * 3600.0 + parts[1] * 60.0 + parts[2] }
    }
    return nil
  }

  private static func durationLabel(from payload: [String: Any]) -> String? {
    if let label = stringValue(payload["duration"]), label.contains(":") {
      return label
    }
    if let seconds = durationSeconds(from: payload), seconds.isFinite, seconds > 0 {
      let total = Int(seconds.rounded())
      return String(format: "%d:%02d", total / 60, total % 60)
    }
    if let label = stringValue(payload["duration"]) {
      return label
    }
    return nil
  }

  private static func linksValue(from raw: Any?) -> [String: String] {
    if let dict = raw as? [String: String] {
      return dict
    }
    if let dict = raw as? [String: Any] {
      var result: [String: String] = [:]
      for (key, value) in dict {
        if let string = stringValue(value) {
          result[key] = string
        }
      }
      return result
    }
    return [:]
  }

  func toPayload() -> [String: Any] {
    var payload: [String: Any] = [
      "track_id": trackId,
      "title": title,
      "artist": artist,
      "play_count": playCount,
      "links": links,
    ]
    if let videoId { payload["video_id"] = videoId }
    if let id { payload["id"] = id }
    if let source { payload["source"] = source }
    if let album { payload["album"] = album }
    if let duration { payload["duration"] = duration }
    if let durationSeconds { payload["duration_seconds"] = durationSeconds }
    if let cover { payload["cover"] = cover }
    if let previewURL { payload["preview_url"] = previewURL }
    if let streamURL { payload["stream_url"] = streamURL }
    if let localURI { payload["local_uri"] = localURI }
    if let cachedAt { payload["cached_at"] = cachedAt }
    if let lastPlayedAt { payload["last_played_at"] = lastPlayedAt }
    return payload
  }
}

struct NativeMusicCacheStats {
  let trackCount: Int
  let recentlyPlayedCount: Int
  let bytesUsed: Int64
}

final class NativeMusicPlayerStore {
  static let shared = NativeMusicPlayerStore()

  private let tracksDefaultsKey = "vibe.native.musicPlayer.tracks.v1"
  private let cacheDirectoryName = "native-music-player-cache"
  private let defaults = UserDefaults.standard

  private var tracks: [String: NativeMusicPlayerTrack] = [:]
  private var downloadingTracks: [String: Double] = [:]

  private init() {
    tracks = loadTracks()
  }

  func allTracksPayload() -> [String: [String: Any]] {
    var payload: [String: [String: Any]] = [:]
    for (trackId, track) in tracks {
      payload[trackId] = track.toPayload()
    }
    return payload
  }

  func downloadingTracksPayload() -> [String: Double] {
    downloadingTracks
  }

  func libraryTracksPayload() -> [[String: Any]] {
    libraryTracks().map { $0.toPayload() }
  }

  func tracks(forChatId chatId: String) -> [NativeMusicPlayerTrack] {
    let target = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return [] }
    return tracks.values
      .filter { $0.links["chat_id"] == target }
      .sorted { lhs, rhs in
        let lhsTime = lhs.cachedAt ?? 0.0
        let rhsTime = rhs.cachedAt ?? 0.0
        if lhsTime != rhsTime {
          return lhsTime > rhsTime
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
  }

  func cacheTrack(payload: [String: Any]) -> NativeMusicPlayerTrack? {
    guard var nextTrack = NativeMusicPlayerTrack(payload: payload) else { return nil }
    if let existing = tracks[nextTrack.trackId] {
      nextTrack = existing.applying(payload: payload)
    } else if nextTrack.cachedAt == nil {
      nextTrack.cachedAt = Date().timeIntervalSince1970 * 1000.0
    }
    tracks[nextTrack.trackId] = nextTrack
    persistTracks()
    return nextTrack
  }

  func getTrack(trackId: String) -> NativeMusicPlayerTrack? {
    tracks[trackId]
  }

  @discardableResult
  func updateLocalURI(trackId: String, localURI: String?) -> NativeMusicPlayerTrack? {
    guard var track = tracks[trackId] else { return nil }
    track.localURI = localURI
    if track.cachedAt == nil {
      track.cachedAt = Date().timeIntervalSince1970 * 1000.0
    }
    tracks[trackId] = track
    persistTracks()
    return track
  }

  @discardableResult
  func recordPlay(trackId: String) -> NativeMusicPlayerTrack? {
    guard var track = tracks[trackId] else { return nil }
    track.playCount += 1
    track.lastPlayedAt = Date().timeIntervalSince1970 * 1000.0
    tracks[trackId] = track
    persistTracks()
    return track
  }

  func setDownloadProgress(trackId: String, progress: Double?) {
    if let progress {
      downloadingTracks[trackId] = max(0.0, min(1.0, progress))
    } else {
      downloadingTracks.removeValue(forKey: trackId)
    }
  }

  func removeTrack(trackId: String) {
    if let localURI = tracks[trackId]?.localURI {
      deleteFileIfNeeded(localURI: localURI)
    }
    tracks.removeValue(forKey: trackId)
    downloadingTracks.removeValue(forKey: trackId)
    persistTracks()
  }

  func resolvedCachedFileURL(for track: NativeMusicPlayerTrack) -> URL? {
    guard let localURI = track.localURI else { return nil }
    guard let url = resolvedLocalURL(from: localURI) else { return nil }
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  func cacheDestinationURL(for track: NativeMusicPlayerTrack, remoteURL: URL?) -> URL {
    let cacheDirectory = resolvedCacheDirectory()
    let ext: String = {
      if let remoteURL, !remoteURL.pathExtension.isEmpty {
        return remoteURL.pathExtension
      }
      if let localURI = track.localURI,
        let url = resolvedLocalURL(from: localURI),
        !url.pathExtension.isEmpty
      {
        return url.pathExtension
      }
      return "m4a"
    }()
    let digest = SHA256.hash(data: Data(track.trackId.utf8))
      .compactMap { String(format: "%02x", $0) }
      .joined()
    return cacheDirectory.appendingPathComponent("\(digest).\(ext)", isDirectory: false)
  }

  func hasLocalPlaybackFile(for track: NativeMusicPlayerTrack) -> Bool {
    resolvedPlayableLocalURL(for: track) != nil
  }

  func cacheStats() -> NativeMusicCacheStats {
    let cachedTracks = tracks.values.filter { resolvedPlayableLocalURL(for: $0) != nil }
    let recentThreshold = Date().timeIntervalSince1970 * 1000.0 - 86_400_000.0

    var bytesUsed: Int64 = 0
    var recentlyPlayedCount = 0

    for track in cachedTracks {
      if let lastPlayedAt = track.lastPlayedAt, lastPlayedAt >= recentThreshold {
        recentlyPlayedCount += 1
      }

      guard let url = resolvedPlayableLocalURL(for: track) else { continue }
      let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      bytesUsed += Int64(fileSize)
    }

    return NativeMusicCacheStats(
      trackCount: cachedTracks.count,
      recentlyPlayedCount: recentlyPlayedCount,
      bytesUsed: bytesUsed
    )
  }

  func clearExpired(olderThanDays days: Int) {
    let expiryMs = Double(max(days, 1)) * 86_400_000.0
    let nowMs = Date().timeIntervalSince1970 * 1000.0
    let recentThreshold = nowMs - 86_400_000.0

    for track in tracks.values {
      guard let cachedAt = track.cachedAt else { continue }
      let isExpired = nowMs - cachedAt > expiryMs
      let playedRecently = (track.lastPlayedAt ?? 0.0) >= recentThreshold
      if isExpired && !playedRecently {
        removeTrack(trackId: track.trackId)
      }
    }
  }

  func clearAll() {
    for trackID in Array(tracks.keys) {
      removeTrack(trackId: trackID)
    }
  }

  private func loadTracks() -> [String: NativeMusicPlayerTrack] {
    guard let data = defaults.data(forKey: tracksDefaultsKey) else { return [:] }
    guard let decoded = try? JSONDecoder().decode([String: NativeMusicPlayerTrack].self, from: data)
    else {
      return [:]
    }
    return decoded
  }

  private func persistTracks() {
    guard let data = try? JSONEncoder().encode(tracks) else { return }
    defaults.set(data, forKey: tracksDefaultsKey)
  }

  private func libraryTracks() -> [NativeMusicPlayerTrack] {
    tracks.values
      .filter { track in
        guard track.source != "chat-voice" else { return false }
        return hasLocalPlaybackFile(for: track)
      }
      .sorted { lhs, rhs in
        let lhsLastPlayed = lhs.lastPlayedAt ?? 0.0
        let rhsLastPlayed = rhs.lastPlayedAt ?? 0.0
        if lhsLastPlayed != rhsLastPlayed {
          return lhsLastPlayed > rhsLastPlayed
        }

        let lhsCachedAt = lhs.cachedAt ?? 0.0
        let rhsCachedAt = rhs.cachedAt ?? 0.0
        if lhsCachedAt != rhsCachedAt {
          return lhsCachedAt > rhsCachedAt
        }

        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
  }

  private func resolvedPlayableLocalURL(for track: NativeMusicPlayerTrack) -> URL? {
    if let localURI = track.localURI,
      let url = resolvedLocalURL(from: localURI),
      FileManager.default.fileExists(atPath: url.path)
    {
      return url
    }
    return nil
  }

  private func deleteFileIfNeeded(localURI: String) {
    guard let url = resolvedLocalURL(from: localURI) else { return }
    try? FileManager.default.removeItem(at: url)
  }

  private func resolvedCacheDirectory() -> URL {
    let baseDirectory =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let directory = baseDirectory.appendingPathComponent(cacheDirectoryName, isDirectory: true)
    if !FileManager.default.fileExists(atPath: directory.path) {
      try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
    }
    return directory
  }

  private func resolvedLocalURL(from value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), url.isFileURL {
      return url
    }
    if trimmed.hasPrefix("/") {
      return URL(fileURLWithPath: trimmed)
    }
    return nil
  }
}
