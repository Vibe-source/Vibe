import Foundation
import UIKit

enum ChatAvatarURLResolver {
  private static let fallbackAPIBaseURL =
    "https://api.vibegram.io"

  /// Known bridge-agent CDN avatars (same assets as server `LocalAgentWorker`).
  static func bridgeAgentAvatarURL(for provider: String?) -> String? {
    guard let provider = normalizedString(provider)?.lowercased() else { return nil }
    switch provider {
    case "claude": return "https://media.vibegram.io/chat-media/agent-profiles/claude.png"
    case "codex": return "https://media.vibegram.io/chat-media/agent-profiles/codex.png"
    case "grok": return "https://media.vibegram.io/chat-media/agent-profiles/grok-v2.png"
    case "agy", "antigravity": return "https://media.vibegram.io/chat-media/agent-profiles/agy.png"
    default: return nil
    }
  }

  /// Resolve avatar for a peer, injecting the official agent CDN photo for
  /// Claude/Codex/Grok/Agy even when `profile_image` / push avatar is empty.
  static func resolve(
    rawAvatar: String?,
    peerUserId: String? = nil,
    chatId: String? = nil,
    preferPushAvatar: Bool = false,
    isAgent: Bool = false,
    agentId: String? = nil,
    displayName: String? = nil
  ) -> String? {
    if chatId == "saved_messages" {
      return nil
    }

    let apiBaseURL = resolvedAPIBaseURL()

    // Bridge agents (Claude/Codex/Grok/Agy): reserved UUIDs resolve without isAgent;
    // username match only when isAgent is true (so a human named "claude" is safe).
    let agentProvider = ChatHomeListRow.bridgeProvider(
      peerUserId: peerUserId,
      name: displayName,
      isAgent: isAgent,
      agentId: agentId
    )
    if let agentURL = bridgeAgentAvatarURL(for: agentProvider) {
      // Prefer explicit HTTPS profile when present; otherwise official CDN mark so
      // home list + search never fall back to initials for known agents.
      if let trimmed = normalizedString(rawAvatar), isHTTPURL(trimmed) {
        return trimmed
      }
      return agentURL
    }

    // Prefer the raw avatar when it's already a direct HTTPS URL — it carries its
    // own cache key so a changed image URL automatically busts the in-app cache.
    if let trimmed = normalizedString(rawAvatar), isHTTPURL(trimmed) {
      return trimmed
    }

    if preferPushAvatar,
      let normalizedPeerUserId = normalizedString(peerUserId),
      let apiBaseURL
    {
      return pushAvatarURL(baseURL: apiBaseURL, userId: normalizedPeerUserId)
    }

    guard let trimmed = normalizedString(rawAvatar) else { return nil }
    if trimmed.hasPrefix("/"), let apiBaseURL {
      return URL(string: trimmed, relativeTo: apiBaseURL)?.absoluteURL.absoluteString
    }
    return nil
  }

  static func resolvedAPIBaseURL() -> URL? {
    let config = ChatEngineStore.shared.getConfig()
    if let explicit = normalizedString(config["apiBaseUrl"] ?? config["baseUrl"]),
      let url = URL(string: explicit)
    {
      return url
    }
    guard let socketURLString = normalizedString(config["socketUrl"] ?? config["url"]),
      var components = URLComponents(string: socketURLString)
    else {
      return URL(string: fallbackAPIBaseURL)
    }
    if components.scheme == "wss" { components.scheme = "https" }
    if components.scheme == "ws" { components.scheme = "http" }
    if components.path.hasSuffix("/socket") {
      components.path = String(components.path.dropLast("/socket".count))
    }
    if components.path.hasSuffix("/websocket") {
      components.path = String(components.path.dropLast("/websocket".count))
    }
    return components.url ?? URL(string: fallbackAPIBaseURL)
  }

  private static func pushAvatarURL(baseURL: URL, userId: String) -> String? {
    guard !userId.isEmpty else { return nil }
    let hasApiSuffix = baseURL.path.lowercased().hasSuffix("/api")
    var url = baseURL
    if !hasApiSuffix {
      url = url.appendingPathComponent("api")
    }
    return url.appendingPathComponent("push")
      .appendingPathComponent("avatar")
      .appendingPathComponent(userId)
      .absoluteString
  }

  private static func isHTTPURL(_ value: String) -> Bool {
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "https" || scheme == "http"
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }
}

/// Shared avatar memory + disk store used by home, chat, profile, and members.
///
/// **Display contract for call sites:**
/// - Always call `cached(for:)` first and paint that image immediately when present.
/// - Never clear an on-screen avatar to initials while the **same URL** is still loading.
/// - On URL change for the same entity: keep the previous image until the new one
///   arrives, then soft-crossfade (see `VibeAvatarDisplay.apply`).
enum ChatAvatarImageStore {
  /// Downsampled avatar edge for list cells (fast cold open / memory).
  private static let diskPixelMax: CGFloat = 384
  /// Higher cap for profile/settings hero (full-width banner needs more than 384).
  private static let heroPixelMax: CGFloat = 1280

  private static let imageCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 256
    // ~48 MB of decoded avatar pixels (cost ≈ width*height*4 when known).
    cache.totalCostLimit = 48 * 1024 * 1024
    return cache
  }()
  private static let inFlightCoordinator = ChatAvatarImageLoadCoordinator()
  /// Avoid repeated failed disk stats on hot scroll paths.
  private static let diskMissLock = NSLock()
  private static var diskMissKeys = Set<String>()
  /// Remote fetches that came back with nothing, and when to stop believing that.
  /// A user with no uploaded picture 404s forever, and without this every repaint asked
  /// again — the server log shows the same `/api/push/avatar/<id>` 404 (~350ms each)
  /// every few seconds, indefinitely. Short enough that a newly-set avatar appears on
  /// its own within a few minutes; `invalidate`/`purge` clear it immediately.
  private static let negativeTTL: TimeInterval = 300
  private static var negativeUntilByKey: [String: TimeInterval] = [:]

  private static func isNegativeCached(_ key: String) -> Bool {
    diskMissLock.lock()
    defer { diskMissLock.unlock() }
    guard let until = negativeUntilByKey[key] else { return false }
    if until > Date().timeIntervalSince1970 { return true }
    negativeUntilByKey.removeValue(forKey: key)
    return false
  }

  private static func markNegative(_ key: String) {
    diskMissLock.lock()
    negativeUntilByKey[key] = Date().timeIntervalSince1970 + negativeTTL
    diskMissLock.unlock()
  }

  private static var diskDirectory: URL = {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("vibe-avatars", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  /// Memory hit, else **synchronous** disk seed (downsampled JPEG) so cold launch
  /// paints avatars on first layout without an initials flash.
  static func cached(for rawValue: String?) -> UIImage? {
    guard let key = cacheKey(rawValue) else { return nil }
    if let mem = imageCache.object(forKey: key as NSString) {
      return mem
    }
    if let disk = loadFromDisk(key: key) {
      storeInMemory(disk, key: key)
      return disk
    }
    return nil
  }

  static func cache(_ image: UIImage, for rawValue: String?) {
    cache(image, for: rawValue, maxPixel: diskPixelMax)
  }

  /// Prefer for profile/settings hero uploads (sharper than list 384px).
  static func cacheHero(_ image: UIImage, for rawValue: String?) {
    cache(image, for: rawValue, maxPixel: heroPixelMax)
  }

  static func cache(_ image: UIImage, for rawValue: String?, maxPixel: CGFloat) {
    guard let key = cacheKey(rawValue) else { return }
    let prepared = downsample(image, maxPixel: maxPixel) ?? image
    storeInMemory(prepared, key: key)
    writeToDisk(prepared, key: key)
  }

  /// Memory-only purge (memory warnings). Disk survives for the next paint.
  static func purge() {
    imageCache.removeAllObjects()
    diskMissLock.lock()
    diskMissKeys.removeAll()
    negativeUntilByKey.removeAll()
    diskMissLock.unlock()
  }

  /// Drop one key (e.g. after a known avatar URL rotation).
  static func invalidate(rawValue: String?) {
    guard let key = cacheKey(rawValue) else { return }
    imageCache.removeObject(forKey: key as NSString)
    diskMissLock.lock()
    diskMissKeys.remove(key)
    negativeUntilByKey.removeValue(forKey: key)
    diskMissLock.unlock()
    let url = diskFileURL(for: key)
    try? FileManager.default.removeItem(at: url)
  }

  static func load(from rawValue: String?) async -> UIImage? {
    await load(from: rawValue, maxPixel: diskPixelMax)
  }

  /// Higher-res load for hero/settings (does not force every list cell to pay).
  static func loadHero(from rawValue: String?) async -> UIImage? {
    await load(from: rawValue, maxPixel: heroPixelMax)
  }

  static func load(from rawValue: String?, maxPixel: CGFloat) async -> UIImage? {
    guard let key = cacheKey(rawValue) else { return nil }

    if let cached = imageCache.object(forKey: key as NSString) {
      // List path always accepts cache; hero path re-fetches if under-resolved.
      if maxPixel <= diskPixelMax || longestPixelEdge(cached) >= maxPixel * 0.55 {
        return cached
      }
    }

    if let disk = loadFromDisk(key: key) {
      if maxPixel <= diskPixelMax || longestPixelEdge(disk) >= maxPixel * 0.55 {
        storeInMemory(disk, key: key)
        return disk
      }
    }

    if isNegativeCached(key) { return nil }

    let task = await inFlightCoordinator.task(for: key) {
      Task.detached(priority: .utility) {
        await fetchImage(for: key)
      }
    }
    let image = await task.value
    await inFlightCoordinator.finish(key: key)

    if image == nil { markNegative(key) }
    if let image {
      let prepared = downsample(image, maxPixel: maxPixel) ?? image
      storeInMemory(prepared, key: key)
      writeToDisk(prepared, key: key)
      return prepared
    }
    return nil
  }

  private static func longestPixelEdge(_ image: UIImage) -> CGFloat {
    max(image.size.width * image.scale, image.size.height * image.scale)
  }

  private static func storeInMemory(_ image: UIImage, key: String) {
    let pixelW = max(1, Int(image.size.width * image.scale))
    let pixelH = max(1, Int(image.size.height * image.scale))
    imageCache.setObject(image, forKey: key as NSString, cost: pixelW * pixelH * 4)
  }

  private static func diskFileURL(for key: String) -> URL {
    let safe = key.data(using: .utf8).map { $0.base64EncodedString() } ?? key
    let trimmed = safe
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
    let name = String(trimmed.prefix(180)) + ".jpg"
    return diskDirectory.appendingPathComponent(name)
  }

  private static func loadFromDisk(key: String) -> UIImage? {
    diskMissLock.lock()
    let knownMiss = diskMissKeys.contains(key)
    diskMissLock.unlock()
    if knownMiss { return nil }

    let url = diskFileURL(for: key)
    guard FileManager.default.fileExists(atPath: url.path) else {
      diskMissLock.lock()
      diskMissKeys.insert(key)
      diskMissLock.unlock()
      return nil
    }
    guard let data = try? Data(contentsOf: url),
      let image = UIImage(data: data)
    else {
      diskMissLock.lock()
      diskMissKeys.insert(key)
      diskMissLock.unlock()
      return nil
    }
    return image
  }

  private static func writeToDisk(_ image: UIImage, key: String) {
    diskMissLock.lock()
    diskMissKeys.remove(key)
    diskMissLock.unlock()
    let url = diskFileURL(for: key)
    DispatchQueue.global(qos: .utility).async {
      guard let data = image.jpegData(compressionQuality: 0.82) else { return }
      try? data.write(to: url, options: [.atomic])
    }
  }

  private static func downsample(_ image: UIImage, maxPixel: CGFloat) -> UIImage? {
    let pixelW = image.size.width * image.scale
    let pixelH = image.size.height * image.scale
    let longest = max(pixelW, pixelH)
    guard longest > maxPixel else { return image }
    let scale = maxPixel / longest
    let newSize = CGSize(width: max(1, pixelW * scale), height: max(1, pixelH * scale))
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
    return renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: newSize))
    }
  }

  private static func fetchImage(for value: String) async -> UIImage? {
    if value.hasPrefix("data:"), let commaIndex = value.firstIndex(of: ",") {
      let base64 = String(value[value.index(after: commaIndex)...])
      guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
        return nil
      }
      return UIImage(data: data)
    }

    if value.hasPrefix("/") {
      return UIImage(contentsOfFile: value)
    }

    if let url = URL(string: value) {
      if url.isFileURL {
        return UIImage(contentsOfFile: url.path)
      }

      if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
        do {
          var request = URLRequest(url: url)
          request.cachePolicy = .returnCacheDataElseLoad
          request.timeoutInterval = 12.0
          request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
          request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
          let (data, response) = try await URLSession.shared.data(for: request)
          if let status = (response as? HTTPURLResponse)?.statusCode,
            !(200...299).contains(status)
          {
            return nil
          }
          return UIImage(data: data)
        } catch {
          return nil
        }
      }
    }

    guard let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]) else {
      return nil
    }
    return UIImage(data: data)
  }

  private static func cacheKey(_ rawValue: String?) -> String? {
    let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }
}

/// Soft in-circle avatar apply: never flash initials when a cached/previous image exists.
enum VibeAvatarDisplay {
  /// Apply `image` into `imageView` with a short cross-dissolve when replacing a prior photo.
  /// Call only on main. When `image` is nil and `keepPrevious` is true, leave the current photo.
  static func apply(
    _ image: UIImage?,
    to imageView: UIImageView,
    fallbackLabel: UILabel?,
    animated: Bool,
    keepPreviousIfNil: Bool = true
  ) {
    if image == nil {
      if keepPreviousIfNil, imageView.image != nil { return }
      imageView.image = nil
      fallbackLabel?.isHidden = false
      return
    }
    // Same instance already on screen — never re-assign or touch fallback (avoids letter fade).
    if imageView.image === image {
      if let fallbackLabel, !fallbackLabel.isHidden {
        fallbackLabel.isHidden = true
      }
      return
    }
    let hadPhoto = imageView.image != nil
    if animated, hadPhoto {
      UIView.transition(
        with: imageView,
        duration: 0.22,
        options: [.transitionCrossDissolve, .allowUserInteraction]
      ) {
        imageView.image = image
      }
    } else {
      imageView.image = image
    }
    if let fallbackLabel, !fallbackLabel.isHidden {
      fallbackLabel.isHidden = true
    }
  }
}

private actor ChatAvatarImageLoadCoordinator {
  private var inFlightLoads: [String: Task<UIImage?, Never>] = [:]

  func task(
    for key: String,
    create: () -> Task<UIImage?, Never>
  ) -> Task<UIImage?, Never> {
    if let existing = inFlightLoads[key] {
      return existing
    }
    let task = create()
    inFlightLoads[key] = task
    return task
  }

  func finish(key: String) {
    inFlightLoads.removeValue(forKey: key)
  }
}

enum ChatAvatarFallbackStyle {
  private static let palettes: [(lightStart: String, lightEnd: String, darkStart: String, darkEnd: String)] = [
    ("#5B8DEF", "#3D6BC6", "#6EA2FF", "#355EAA"),
    ("#1FA97A", "#167A60", "#3BC99A", "#126B55"),
    ("#D66A5A", "#AF493F", "#E98574", "#963B33"),
    ("#A06AD8", "#7C4EB2", "#B984EA", "#6E45A0"),
    ("#D59A2E", "#AF741D", "#E6B24A", "#966418"),
    ("#2F9AA8", "#207585", "#4BB6C4", "#1B6575"),
    ("#E05A8A", "#B83E6A", "#F178A4", "#9C345B"),
    ("#6078D6", "#4659AE", "#7A91EA", "#3A4E9C"),
  ]

  static func hexGradient(
    title: String?,
    peerUserId: String?,
    chatId: String?,
    isSavedMessages: Bool
  ) -> (lightStart: String, lightEnd: String, darkStart: String, darkEnd: String)? {
    guard !isSavedMessages else { return nil }
    let seed = stableSeed(title: title, peerUserId: peerUserId, chatId: chatId)
    guard !seed.isEmpty else { return nil }
    return palettes[paletteIndex(for: seed)]
  }

  static func uiGradient(
    title: String?,
    peerUserId: String?,
    chatId: String?,
    isDark: Bool,
    isSavedMessages: Bool = false
  ) -> (UIColor, UIColor) {
    if isSavedMessages {
      return isDark
        ? (
          UIColor(red: 77 / 255, green: 217 / 255, blue: 229 / 255, alpha: 1),
          UIColor(red: 43 / 255, green: 165 / 255, blue: 181 / 255, alpha: 1)
        )
        : (
          UIColor(red: 43 / 255, green: 165 / 255, blue: 181 / 255, alpha: 1),
          UIColor(red: 0 / 255, green: 122 / 255, blue: 124 / 255, alpha: 1)
        )
    }

    let seed = stableSeed(title: title, peerUserId: peerUserId, chatId: chatId)
    let palette = palettes[paletteIndex(for: seed.isEmpty ? "user" : seed)]
    return (
      uiColor(hex: isDark ? palette.darkStart : palette.lightStart),
      uiColor(hex: isDark ? palette.darkEnd : palette.lightEnd)
    )
  }

  static func stableSeed(title: String?, peerUserId: String?, chatId: String?) -> String {
    [peerUserId, title, chatId]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? ""
  }

  private static func paletteIndex(for seed: String) -> Int {
    abs(seed.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % palettes.count
  }

  private static func uiColor(hex raw: String) -> UIColor {
    var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    var value: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&value)
    return UIColor(
      red: CGFloat((value >> 16) & 0xff) / 255.0,
      green: CGFloat((value >> 8) & 0xff) / 255.0,
      blue: CGFloat(value & 0xff) / 255.0,
      alpha: 1.0
    )
  }
}

struct ChatHomeListRow {
  let chatId: String
  let title: String
  let preview: String
  let timeLabel: String
  let unreadCount: Int
  let markedUnread: Bool
  let muted: Bool
  let pinned: Bool
  let archived: Bool
  let isTyping: Bool
  let isOnline: Bool
  let peerUserId: String?
  let avatarUri: String?
  let avatarFallback: String
  let avatarGradientStartLight: String?
  let avatarGradientEndLight: String?
  let avatarGradientStartDark: String?
  let avatarGradientEndDark: String?
  let isSavedMessages: Bool
  let isArchiveEntry: Bool
  let type: String?
  let isGroup: Bool
  /// True when `type == "channel"`. Channels are group-like rooms but must NOT
  /// expose a members roster in the profile (groups do). `parse` also forces
  /// `type = "channel"` when the server sends `isChannel: true`.
  var isChannel: Bool {
    (type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "channel"
  }
  /// Group chats where every participant can open the Members list.
  var showsMemberList: Bool { isGroup && !isChannel }
  /// Signed-in user's role in this room (`owner`/`admin`/`member`), from home list.
  let myRole: String?
  /// True when the chat's friend is an AI agent's shadow user — i.e. this is a
  /// 1:1 "talk to the agent" chat. Mirrors the server's `friendIsAgent` flag.
  let isAgentFriend: Bool
  /// The agent's id when `isAgentFriend` is true. Sent as `peerAgentId` so the
  /// engine routes the message to the agent backend instead of E2E-encrypting
  /// to a human peer. Mirrors the server's `friendAgentId`.
  let peerAgentId: String?
  /// The attached agent's event-inbox mode (`per_event` or `batched_summary`).
  /// In `batched_summary` (inbox) mode the chat view hides event notifications
  /// from the transcript and surfaces them via the Inbox banner. Mirrors the
  /// server's `friendAgentEventInboxMode`.
  let agentEventInboxMode: String?
  /// Profile tier for the peer. Claude/Codex are seeded server-side as `gold`.
  let peerTier: String?
  let previewRows: [[String: Any]]
  let initialMessages: [[String: Any]]
  /// Group/channel participant list (`[{userId, name, avatarUrl, role}]`), sent by
  /// the server for `isGroup` rows. Empty for DMs.
  let members: [[String: Any]]
  /// Epoch-millisecond timestamp of this chat's most recent activity (newest
  /// visible message, else room creation). Drives newest-first home ordering.
  /// Mirrors the server's `lastMessageAt`.
  let lastMessageAt: Double
  /// Room creation epoch-ms when present (`createdAt`).
  let createdAt: Double
  /// Optional room description (group/channel).
  let roomDescription: String?
  /// Channel access: `private` or `public`.
  let accessType: String?
  /// Public channel slug identity.
  let publicSlug: String?
  /// Shareable invite / public link when known.
  let shareLink: String?
  /// Channel join-approval policy.
  let joinApprovalRequired: Bool
  /// Channel restrict-saving-content policy.
  let restrictSavingContent: Bool
  /// Server member count when provided.
  let memberCount: Int?
  /// Server subscriber count for channels when provided.
  let subscriberCount: Int?

  /// Explicit initializer (replaces the synthesized memberwise init) so
  /// additive fields can default — every pre-existing `ChatHomeListRow(...)` call
  /// site keeps compiling and only the recency-aware paths pass a real value.
  init(
    chatId: String,
    title: String,
    preview: String,
    timeLabel: String,
    unreadCount: Int,
    markedUnread: Bool,
    muted: Bool,
    pinned: Bool,
    archived: Bool,
    isTyping: Bool,
    isOnline: Bool,
    peerUserId: String?,
    avatarUri: String?,
    avatarFallback: String,
    avatarGradientStartLight: String?,
    avatarGradientEndLight: String?,
    avatarGradientStartDark: String?,
    avatarGradientEndDark: String?,
    isSavedMessages: Bool,
    isArchiveEntry: Bool,
    type: String?,
    isGroup: Bool,
    myRole: String? = nil,
    isAgentFriend: Bool,
    peerAgentId: String?,
    agentEventInboxMode: String?,
    peerTier: String?,
    previewRows: [[String: Any]],
    initialMessages: [[String: Any]],
    members: [[String: Any]],
    lastMessageAt: Double = 0,
    createdAt: Double = 0,
    roomDescription: String? = nil,
    accessType: String? = nil,
    publicSlug: String? = nil,
    shareLink: String? = nil,
    joinApprovalRequired: Bool = false,
    restrictSavingContent: Bool = false,
    memberCount: Int? = nil,
    subscriberCount: Int? = nil
  ) {
    self.chatId = chatId
    self.title = title
    self.preview = preview
    self.timeLabel = timeLabel
    self.unreadCount = unreadCount
    self.markedUnread = markedUnread
    self.muted = muted
    self.pinned = pinned
    self.archived = archived
    self.isTyping = isTyping
    self.isOnline = isOnline
    self.peerUserId = peerUserId
    self.avatarUri = avatarUri
    self.avatarFallback = avatarFallback
    self.avatarGradientStartLight = avatarGradientStartLight
    self.avatarGradientEndLight = avatarGradientEndLight
    self.avatarGradientStartDark = avatarGradientStartDark
    self.avatarGradientEndDark = avatarGradientEndDark
    self.isSavedMessages = isSavedMessages
    self.isArchiveEntry = isArchiveEntry
    self.type = type
    self.isGroup = isGroup
    self.myRole = myRole
    self.isAgentFriend = isAgentFriend
    self.peerAgentId = peerAgentId
    self.agentEventInboxMode = agentEventInboxMode
    self.peerTier = peerTier
    self.previewRows = previewRows
    self.initialMessages = initialMessages
    self.members = members
    self.lastMessageAt = lastMessageAt
    self.createdAt = createdAt
    self.roomDescription = roomDescription
    self.accessType = accessType
    self.publicSlug = publicSlug
    self.shareLink = shareLink
    self.joinApprovalRequired = joinApprovalRequired
    self.restrictSavingContent = restrictSavingContent
    self.memberCount = memberCount
    self.subscriberCount = subscriberCount
  }

  var isBuiltInAgentSurface: Bool {
    Self.isBuiltInAgentChatId(chatId)
  }

  var isBridgeAgentSurface: Bool {
    Self.bridgeProvider(peerUserId: peerUserId, name: title, isAgent: isAgentFriend, agentId: peerAgentId) != nil
  }

  var isGoldTier: Bool {
    peerTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "gold"
  }

  static func isBuiltInAgentChatId(_ rawChatId: String) -> Bool {
    switch rawChatId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "vibe", "vibe_agent", "vibeagent", "vibe-ai", "vibe_ai":
      return true
    default:
      return false
    }
  }

  static func bridgeProvider(
    peerUserId: String?,
    name: String?,
    isAgent: Bool,
    agentId: String? = nil
  ) -> String? {
    let peer = peerUserId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if peer == "11111111-1111-1111-1111-111111111111" { return "claude" }
    if peer == "22222222-2222-2222-2222-222222222222" { return "codex" }
    if peer == "33333333-3333-3333-3333-333333333333" { return "grok" }
    if peer == "44444444-4444-4444-4444-444444444444" { return "agy" }

    let agent = agentId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch agent {
    case "claude", "11111111-1111-1111-1111-111111111111":
      return "claude"
    case "codex", "22222222-2222-2222-2222-222222222222":
      return "codex"
    case "grok", "33333333-3333-3333-3333-333333333333":
      return "grok"
    case "agy", "antigravity", "44444444-4444-4444-4444-444444444444":
      return "agy"
    default:
      break
    }

    guard isAgent else { return nil }
    switch name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "claude": return "claude"
    case "codex": return "codex"
    case "grok": return "grok"
    case "agy", "antigravity": return "agy"
    default: return nil
    }
  }

  func cachePayload(messageLimit: Int = 5) -> [String: Any] {
    // Bridge-agent DMs are ordinary conversations from Home's perspective. Keeping
    // their latest row lets Home show the actual session/activity after a relaunch
    // instead of permanently replacing every preview with "Start session".
    let shouldIncludeMessagePayload = messageLimit > 0
    var payload: [String: Any] = [
      "chatId": chatId,
      "title": title,
      "preview": preview,
      "timeLabel": timeLabel,
      "unreadCount": unreadCount,
      "markedUnread": markedUnread,
      "muted": muted,
      "pinned": pinned,
      "archived": archived,
      "isTyping": isTyping,
      "isOnline": isOnline,
      "avatarFallback": avatarFallback,
      "isSavedMessages": isSavedMessages,
      "isArchiveEntry": isArchiveEntry,
      "isGroup": isGroup,
      "isAgentFriend": isAgentFriend,
      "previewRows": shouldIncludeMessagePayload ? previewRows : [],
      "messages": shouldIncludeMessagePayload ? Array(initialMessages.suffix(messageLimit)) : [],
      "lastMessageAt": lastMessageAt,
    ]
    if let peerUserId { payload["peerUserId"] = peerUserId }
    if let peerAgentId { payload["peerAgentId"] = peerAgentId }
    if let agentEventInboxMode { payload["agentEventInboxMode"] = agentEventInboxMode }
    if let peerTier { payload["peerTier"] = peerTier }
    if let avatarUri { payload["avatarUri"] = avatarUri }
    if let avatarGradientStartLight { payload["avatarGradientStartLight"] = avatarGradientStartLight }
    if let avatarGradientEndLight { payload["avatarGradientEndLight"] = avatarGradientEndLight }
    if let avatarGradientStartDark { payload["avatarGradientStartDark"] = avatarGradientStartDark }
    if let avatarGradientEndDark { payload["avatarGradientEndDark"] = avatarGradientEndDark }
    if let type { payload["type"] = type }
    if isChannel { payload["isChannel"] = true }
    if let myRole { payload["role"] = myRole }
    // Group roster must survive cold start. Without this, opening a group from
    // cache always showed 0 members (profile "No members yet") until a live
    // home refresh happened to re-open the chat.
    if !members.isEmpty {
      payload["members"] = members
    }
    if createdAt > 0 { payload["createdAt"] = createdAt }
    if let roomDescription { payload["description"] = roomDescription }
    if let accessType { payload["accessType"] = accessType }
    if let publicSlug { payload["publicSlug"] = publicSlug }
    if let shareLink { payload["shareLink"] = shareLink }
    if joinApprovalRequired { payload["joinApprovalRequired"] = true }
    if restrictSavingContent { payload["restrictSavingContent"] = true }
    if let memberCount { payload["memberCount"] = memberCount }
    if let subscriberCount { payload["subscriberCount"] = subscriberCount }
    return payload
  }

  func withPresence(isTyping: Bool, isOnline: Bool, preview: String? = nil) -> ChatHomeListRow {
    return ChatHomeListRow(
      chatId: chatId,
      title: title,
      preview: preview ?? self.preview,
      timeLabel: timeLabel,
      unreadCount: unreadCount,
      markedUnread: markedUnread,
      muted: muted,
      pinned: pinned,
      archived: archived,
      isTyping: isTyping,
      isOnline: isOnline,
      peerUserId: peerUserId,
      avatarUri: avatarUri,
      avatarFallback: avatarFallback,
      avatarGradientStartLight: avatarGradientStartLight,
      avatarGradientEndLight: avatarGradientEndLight,
      avatarGradientStartDark: avatarGradientStartDark,
      avatarGradientEndDark: avatarGradientEndDark,
      isSavedMessages: isSavedMessages,
      isArchiveEntry: isArchiveEntry,
      type: type,
      isGroup: isGroup,
      myRole: myRole,
      isAgentFriend: isAgentFriend,
      peerAgentId: peerAgentId,
      agentEventInboxMode: agentEventInboxMode,
      peerTier: peerTier,
      previewRows: previewRows,
      initialMessages: initialMessages,
      members: members,
      lastMessageAt: lastMessageAt,
      createdAt: createdAt,
      roomDescription: roomDescription,
      accessType: accessType,
      publicSlug: publicSlug,
      shareLink: shareLink,
      joinApprovalRequired: joinApprovalRequired,
      restrictSavingContent: restrictSavingContent,
      memberCount: memberCount,
      subscriberCount: subscriberCount
    )
  }

  static func parse(_ raw: [String: Any]) -> ChatHomeListRow? {
    guard let chatId = normalizedString(raw["chatId"] ?? raw["chat_id"]), !chatId.isEmpty else {
      return nil
    }
    let isSavedMessages = chatId == "saved_messages"
    let isArchiveEntry = parseBool(raw["isArchiveEntry"] ?? raw["is_archive_entry"]) ?? false
    let serverMessages = parseServerMessages(raw["messages"])
    let names = [
      raw["name"], raw["title"], raw["chatName"], raw["chat_name"],
      raw["friendName"], raw["friend_name"], raw["displayName"], raw["display_name"],
      raw["fullName"], raw["full_name"], raw["username"], raw["handle"]
    ]
    var resolvedTitle: String? = nil
    for name in names {
      if let n = normalizedString(name) {
        if !looksLikeUUID(n) {
          resolvedTitle = n
          break
        }
      }
    }
    let title = resolvedTitle ?? "Vibegram User"

    let previewRaw = firstSafeDisplayText(raw["preview"], raw["subtitle"])
    let previewMessage = serverMessages.last.map(homePreviewText(from:))
    let unreadCount = parseInt(raw["unreadCount"] ?? raw["unread_count"]) ?? 0
    let markedUnread = parseBool(raw["markedUnread"] ?? raw["marked_unread"]) ?? false
    let muted = parseBool(raw["muted"]) ?? false
    let pinned = parseBool(raw["pinned"]) ?? false
    let archived = parseBool(raw["archived"]) ?? false
    let isTyping = parseBool(raw["isTyping"] ?? raw["is_typing"]) ?? false
    let isOnline = parseBool(raw["isOnline"] ?? raw["is_online"]) ?? false
    let rawType = normalizedString(raw["type"] ?? raw["chatType"] ?? raw["chat_type"])
    // Explicit isChannel from server (or cache) wins over a missing/stale type.
    let explicitChannel = parseBool(raw["isChannel"] ?? raw["is_channel"]) == true
    let type: String? = explicitChannel ? "channel" : rawType
    // Type is authoritative for multi-party rooms. Older channel rows may have
    // `is_group: false` on the server while `type == "channel"` — still treat as
    // group-like so list/header/profile use the channel path, not a DM.
    let isGroup: Bool = {
      if type == "group" || type == "channel" { return true }
      return parseBool(raw["isGroup"] ?? raw["is_group"]) ?? false
    }()
    let isChannelRow =
      (type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "channel"
    // Per-user role for this room (owner/admin/member). Stabilizes admin chrome
    // without re-deriving only from the members array (which can arrive incomplete).
    let myRole = normalizedString(
      raw["role"] ?? raw["myRole"] ?? raw["my_role"] ?? raw["memberRole"] ?? raw["member_role"]
    )?.lowercased()
    // Groups/channels are never a 1:1 with a "friend": ignore any friend_* fields. A stale
    // pre-fix cached row can still carry a leaked agent friendId/friendImage — that's what
    // made an old group open Codex AND show Codex's avatar instead of the uploaded photo.
    // Prefer the room's own avatar_url and never fall back to a member/friend image.
    let friendId =
      isGroup
      ? nil
      : normalizedString(
        raw["friendId"] ?? raw["friend_id"] ?? raw["peerUserId"] ?? raw["peer_user_id"]
          ?? raw["userId"] ?? raw["user_id"])
    let peerUserId = friendId
    let rawAvatar =
      isGroup
      ? normalizedString(
        raw["avatarUrl"] ?? raw["avatar_url"] ?? raw["avatarUri"] ?? raw["avatar_uri"])
      : normalizedString(
        raw["avatarUri"] ?? raw["avatar_uri"] ?? raw["friendImage"] ?? raw["friend_image"]
          ?? raw["profileImage"] ?? raw["profile_image"] ?? raw["avatarUrl"] ?? raw["avatar_url"])
    let peerAgentId =
      isGroup
      ? nil
      : normalizedString(
        raw["friendAgentId"] ?? raw["friend_agent_id"] ?? raw["agentId"] ?? raw["agent_id"])
    // Bridge agents (Claude/Codex/Grok) are real users with is_agent=true but NO
    // Agent record (`peerAgentId` is nil). Treat reserved shadow-user ids as agents
    // even when the payload omits friendIsAgent, so Grok DMs route into the agent view.
    let isReservedBridgeAgent =
      Self.bridgeProvider(peerUserId: peerUserId, name: title, isAgent: true, agentId: peerAgentId)
      != nil
    let isAgentFriend =
      !isGroup
      && (Self.isBuiltInAgentChatId(chatId)
        || isReservedBridgeAgent
        || (parseBool(raw["friendIsAgent"] ?? raw["friend_is_agent"]) ?? (peerAgentId != nil)))
    // Resolve avatar AFTER isAgentFriend so bridge agents get CDN marks when the
    // server omits friendImage (search/home used to show initials only).
    let avatarUri = resolveAvatarURI(
      rawAvatar: rawAvatar,
      friendId: friendId,
      chatId: chatId,
      isAgent: isAgentFriend,
      agentId: peerAgentId,
      displayName: title
    )
    let avatarFallback =
      normalizedString(raw["avatarFallback"] ?? raw["avatar_fallback"])
      ?? String(title.prefix(1)).uppercased()
    let avatarGradientStartLight =
      normalizedString(raw["avatarGradientStartLight"] ?? raw["avatar_gradient_start_light"])
    let avatarGradientEndLight =
      normalizedString(raw["avatarGradientEndLight"] ?? raw["avatar_gradient_end_light"])
    let avatarGradientStartDark =
      normalizedString(raw["avatarGradientStartDark"] ?? raw["avatar_gradient_start_dark"])
    let avatarGradientEndDark =
      normalizedString(raw["avatarGradientEndDark"] ?? raw["avatar_gradient_end_dark"])
    let fallbackGradient = ChatAvatarFallbackStyle.hexGradient(
      title: title,
      peerUserId: peerUserId,
      chatId: chatId,
      isSavedMessages: isSavedMessages
    )
    let agentEventInboxMode = normalizedString(
      raw["friendAgentEventInboxMode"] ?? raw["friend_agent_event_inbox_mode"]
        ?? raw["agentEventInboxMode"] ?? raw["agent_event_inbox_mode"] ?? raw["eventInboxMode"]
        ?? raw["event_inbox_mode"])
    let peerTier = normalizedString(
      raw["friendTier"] ?? raw["friend_tier"] ?? raw["peerTier"] ?? raw["peer_tier"]
        ?? raw["tier"] ?? raw["badge"] ?? raw["badgeTier"] ?? raw["badge_tier"])
    // Do not erase real bridge-agent activity. The server supplies the newest
    // transcript row, which is the source of truth for Home's preview and order.
    // Empty multi-party rooms with no messages get localized create copy.
    let preview: String = {
      if let previewRaw { return previewRaw }
      if let previewMessage { return previewMessage }
      if serverMessages.isEmpty {
        if isChannelRow { return "Channel created" }
        if isGroup { return "Group created" }
      }
      return ""
    }()
    let initialMessages = serverMessages
    let previewRows = parsePreviewRows(raw["previewRows"] ?? raw["preview_rows"])

    let createdAt: Double = {
      if let value = parseEpochMillis(raw["createdAt"] ?? raw["created_at"]) { return value }
      return 0
    }()

    let lastMessageAt: Double = {
      if let value = parseEpochMillis(raw["lastMessageAt"] ?? raw["last_message_at"]) {
        return value
      }
      // Cache/legacy payloads without the field: derive from the newest message.
      if let newest = serverMessages.last {
        let ts = Double(parseTimestamp(newest))
        if ts > 0 { return ts }
      }
      // Empty rooms: fall back to createdAt so ordering/time still work.
      if createdAt > 0 { return createdAt }
      return 0
    }()

    // Explicit time text first, then message time, then lastMessageAt/createdAt.
    let timeLabel: String = {
      if let explicit = normalizedString(raw["timeLabel"] ?? raw["time_label"] ?? raw["time"]) {
        return explicit
      }
      if let fromMessage = serverMessages.last.map(homeTimeLabel(from:)), !fromMessage.isEmpty {
        return fromMessage
      }
      if lastMessageAt > 0 {
        return homeTimeLabel(fromEpochMillis: lastMessageAt)
      }
      if createdAt > 0 {
        return homeTimeLabel(fromEpochMillis: createdAt)
      }
      return ""
    }()

    let roomDescription = normalizedString(
      raw["description"] ?? raw["roomDescription"] ?? raw["room_description"])
    let accessType = normalizedString(raw["accessType"] ?? raw["access_type"])?.lowercased()
    let publicSlug = normalizedString(raw["publicSlug"] ?? raw["public_slug"])
    let shareLink = normalizedString(
      raw["shareLink"] ?? raw["share_link"] ?? raw["inviteLink"] ?? raw["invite_link"])
    let joinApprovalRequired =
      parseBool(raw["joinApprovalRequired"] ?? raw["join_approval_required"]) ?? false
    let restrictSavingContent =
      parseBool(raw["restrictSavingContent"] ?? raw["restrict_saving_content"]) ?? false
    let memberCount = parseInt(raw["memberCount"] ?? raw["member_count"])
    let subscriberCount = parseInt(raw["subscriberCount"] ?? raw["subscriber_count"])

    return ChatHomeListRow(
      chatId: chatId,
      title: title,
      preview: preview,
      timeLabel: timeLabel,
      unreadCount: max(0, unreadCount),
      markedUnread: markedUnread,
      muted: muted,
      pinned: pinned,
      archived: archived,
      isTyping: isTyping,
      isOnline: isOnline,
      peerUserId: peerUserId,
      avatarUri: avatarUri,
      avatarFallback: avatarFallback,
      avatarGradientStartLight: avatarGradientStartLight ?? fallbackGradient?.lightStart,
      avatarGradientEndLight: avatarGradientEndLight ?? fallbackGradient?.lightEnd,
      avatarGradientStartDark: avatarGradientStartDark ?? fallbackGradient?.darkStart,
      avatarGradientEndDark: avatarGradientEndDark ?? fallbackGradient?.darkEnd,
      isSavedMessages: isSavedMessages,
      isArchiveEntry: isArchiveEntry,
      type: type,
      isGroup: isGroup,
      myRole: myRole,
      isAgentFriend: isAgentFriend,
      peerAgentId: peerAgentId,
      agentEventInboxMode: agentEventInboxMode,
      peerTier: peerTier,
      previewRows: previewRows,
      initialMessages: initialMessages,
      members: parsePreviewRows(raw["members"]),
      lastMessageAt: lastMessageAt,
      createdAt: createdAt,
      roomDescription: roomDescription,
      accessType: accessType,
      publicSlug: publicSlug,
      shareLink: shareLink,
      joinApprovalRequired: joinApprovalRequired,
      restrictSavingContent: restrictSavingContent,
      memberCount: memberCount,
      subscriberCount: subscriberCount
    )
  }

  private static func parsePreviewRows(_ value: Any?) -> [[String: Any]] {
    guard let array = value as? [Any], !array.isEmpty else { return [] }
    return array.compactMap { item in
      item as? [String: Any]
    }
  }

  static func parseServerMessages(_ value: Any?) -> [[String: Any]] {
    guard let array = value as? [Any], !array.isEmpty else { return [] }
    return array.compactMap { item in
      item as? [String: Any]
    }.sorted { lhs, rhs in
      parseTimestamp(lhs) < parseTimestamp(rhs)
    }
  }

  static func homePreviewText(from raw: [String: Any]) -> String {
    let base: String = {
      if let text = firstSafeDisplayText(
        raw["preview"],
        raw["plainContent"],
        raw["plain_content"],
        raw["plaintext"]
      ) {
        return text
      }

      if let text = ChatEngine.shared.makeHomePreviewText(raw) {
        return text
      }

      if let text = firstSafeDisplayText(raw["content"], raw["text"]) {
        return text
      }

      let type = normalizedString(raw["type"])?.lowercased() ?? "text"
      let fileName =
        normalizedString(raw["fileName"] ?? raw["file_name"] ?? raw["name"] ?? raw["title"])

      switch type {
      case "image":
        return "Photo"
      case "video":
        return "Video"
      case "voice":
        return "Voice message"
      case "music":
        return "Audio"
      case "file":
        return fileName ?? "File"
      case "location":
        return "Location"
      case "contact":
        return "Contact"
      case "gif":
        return "GIF"
      case "sticker":
        return "Sticker"
      default:
        if normalizedString(raw["mediaUrl"] ?? raw["media_url"]) != nil {
          return fileName ?? "Attachment"
        }
        return "Encrypted message"
      }
    }()

    // Telegram-style home list: "Forwarded message" (or prefix) when last msg is a forward.
    if isForwardedHomeMessage(raw) {
      let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty || trimmed == "Encrypted message" {
        return "Forwarded message"
      }
      // Avoid double-prefix if server already formatted it.
      if trimmed.lowercased().hasPrefix("forwarded") {
        return trimmed
      }
      return "Forwarded message"
    }
    return base
  }

  private static func isForwardedHomeMessage(_ raw: [String: Any]) -> Bool {
    let metadata =
      (raw["metadata"] as? [String: Any])
      ?? (raw["meta"] as? [String: Any])
      ?? [:]
    if parseBool(metadata["isForwarded"] ?? metadata["is_forwarded"]) == true {
      return true
    }
    if parseBool(raw["isForwarded"] ?? raw["is_forwarded"]) == true {
      return true
    }
    let keys = [
      "forwardedFromName", "forwarded_from_name",
      "forwardedFromUserId", "forwarded_from_user_id",
      "forwardedFromMessageId", "forwarded_from_message_id",
    ]
    for key in keys {
      if normalizedString(metadata[key]) != nil { return true }
      if normalizedString(raw[key]) != nil { return true }
    }
    return false
  }

  static func homeTimeLabel(from raw: [String: Any]) -> String {
    let timestamp = parseTimestamp(raw)
    guard timestamp > 0 else { return "" }
    return homeTimeLabel(fromEpochMillis: Double(timestamp))
  }

  /// Format an epoch-millisecond activity/create timestamp for the home list.
  static func homeTimeLabel(fromEpochMillis millis: Double) -> String {
    guard millis > 0 else { return "" }
    // Accept seconds if a server ever sends them (pre-2001 ms values).
    let seconds: TimeInterval = millis > 1_000_000_000_000
      ? millis / 1000.0
      : millis
    let date = Date(timeIntervalSince1970: seconds)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return HomeTimeFormatters.time.string(from: date)
    }
    if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
      return HomeTimeFormatters.day.string(from: date)
    }
    return HomeTimeFormatters.shortDate.string(from: date)
  }

  private static func parseEpochMillis(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
      let d = number.doubleValue
      return d > 0 ? d : nil
    }
    if let text = normalizedString(value), let parsed = Double(text), parsed > 0 {
      return parsed
    }
    return nil
  }

  private static func resolveAvatarURI(
    rawAvatar: String?,
    friendId: String?,
    chatId: String,
    isAgent: Bool = false,
    agentId: String? = nil,
    displayName: String? = nil
  ) -> String? {
    return ChatAvatarURLResolver.resolve(
      rawAvatar: rawAvatar,
      peerUserId: friendId,
      chatId: chatId,
      preferPushAvatar: true,
      isAgent: isAgent,
      agentId: agentId,
      displayName: displayName
    )
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func firstSafeDisplayText(_ values: Any?...) -> String? {
    for value in values {
      guard let text = normalizedString(value), !looksLikeEncryptedPayload(text) else {
        continue
      }
      return text
    }
    return nil
  }

  private static func looksLikeEncryptedPayload(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let json = object as? [String: Any]
    {
      return json["iv"] != nil && json["c"] != nil && json["k"] != nil
    }
    let compact = trimmed.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    return compact.contains("\"iv\"") && compact.contains("\"c\"") && compact.contains("\"k\"")
  }

  private static func looksLikeUUID(_ value: String) -> Bool {
    UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
  }

  private static func parseInt(_ value: Any?) -> Int? {
    if let value = value as? NSNumber {
      return value.intValue
    }
    if let value = value as? String {
      return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }

  private static func parseTimestamp(_ raw: [String: Any]) -> Int64 {
    if let value = raw["timestamp"] as? NSNumber {
      return value.int64Value
    }
    if let value = raw["timestamp_ms"] as? NSNumber {
      return value.int64Value
    }
    if let value = raw["timestampMs"] as? NSNumber {
      return value.int64Value
    }
    if let value = raw["timestamp"] as? String {
      return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    if let value = raw["timestamp_ms"] as? String {
      return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    if let value = raw["timestampMs"] as? String {
      return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    return 0
  }

  private static func parseBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool {
      return value
    }
    if let value = value as? NSNumber {
      return value.boolValue
    }
    if let value = value as? String {
      switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "1", "true", "yes", "on":
        return true
      case "0", "false", "no", "off":
        return false
      default:
        return nil
      }
    }
    return nil
  }
}

private enum HomeTimeFormatters {
  static let time: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
  }()

  static let day: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEE")
    return formatter
  }()

  static let shortDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter
  }()
}

enum ChatHomeSwipeEdge {
  case leading
  case trailing
}

struct ChatHomeSwipeActionSpec {
  let eventType: String
  let title: String
  let systemImageName: String
  let backgroundColor: UIColor
  let foregroundColor: UIColor
  let style: UIContextualAction.Style
  let isFullSwipeTarget: Bool
}

extension ChatHomeListRow {
  var leadingSwipeActionSpecs: [ChatHomeSwipeActionSpec] {
    let hasUnread = unreadCount > 0 || markedUnread
    return [
      ChatHomeSwipeActionSpec(
        eventType: "swipePin",
        title: pinned ? "Unpin" : "Pin",
        systemImageName: pinned ? "pin.slash.fill" : "pin.fill",
        backgroundColor: ChatHomeSwipePalette.pin,
        foregroundColor: .white,
        style: .normal,
        isFullSwipeTarget: true
      ),
      ChatHomeSwipeActionSpec(
        eventType: "swipeMarkRead",
        title: hasUnread ? "Read" : "Unread",
        systemImageName: hasUnread ? "message.fill" : "circle.fill",
        backgroundColor: ChatHomeSwipePalette.read,
        foregroundColor: .white,
        style: .normal,
        isFullSwipeTarget: false
      ),
    ]
  }

  var trailingSwipeActionSpecs: [ChatHomeSwipeActionSpec] {
    [
      ChatHomeSwipeActionSpec(
        eventType: "swipeDelete",
        title: "Delete",
        systemImageName: "trash.fill",
        backgroundColor: ChatHomeSwipePalette.delete,
        foregroundColor: .white,
        style: .destructive,
        isFullSwipeTarget: true
      ),
      ChatHomeSwipeActionSpec(
        eventType: "swipeMute",
        title: muted ? "Unmute" : "Mute",
        systemImageName: muted ? "speaker.wave.2.fill" : "speaker.slash.fill",
        backgroundColor: ChatHomeSwipePalette.mute,
        foregroundColor: .white,
        style: .normal,
        isFullSwipeTarget: false
      ),
      ChatHomeSwipeActionSpec(
        eventType: "swipeArchive",
        title: "Archive",
        systemImageName: "archivebox.fill",
        backgroundColor: ChatHomeSwipePalette.archive,
        foregroundColor: .white,
        style: .normal,
        isFullSwipeTarget: false
      ),
    ]
  }
}

private enum ChatHomeSwipePalette {
  static let pin = UIColor(red: 0.20, green: 0.47, blue: 0.90, alpha: 1)
  static let read = UIColor(red: 0.24, green: 0.61, blue: 0.86, alpha: 1)
  static let mute = UIColor(red: 0.86, green: 0.53, blue: 0.04, alpha: 1)
  static let delete = UIColor(red: 0.88, green: 0.10, blue: 0.10, alpha: 1)
  static let archive = UIColor(red: 0.51, green: 0.51, blue: 0.53, alpha: 1)
}

/// Shared builder for the "mosaic" group avatar — a composite tile made from up to
/// four members' avatars (photo where available, coloured initials otherwise).
///
/// Previously private to `ChatHomeCardCell`; now backs both the home list row AND
/// the group *profile* hero so the two surfaces show the exact same group image
/// (and share the `ChatAvatarImageStore` cache). Lives here alongside
/// `ChatAvatarURLResolver` so it stays in the app target without a new file ref.
enum GroupCompositeAvatar {
  struct Slot {
    let id: String
    let name: String
    let url: String?
  }

  /// Parse a raw members payload into avatar slots, tolerating the several key
  /// spellings the server/home use.
  static func slots(from members: [[String: Any]]) -> [Slot] {
    members.compactMap { member -> Slot? in
      let id =
        (member["userId"] as? String) ?? (member["id"] as? String)
        ?? (member["memberId"] as? String)
      guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      let name =
        ((member["name"] as? String) ?? (member["displayName"] as? String)
          ?? (member["username"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let rawURL =
        (member["avatarUrl"] as? String) ?? (member["avatar_url"] as? String)
        ?? (member["profileImage"] as? String) ?? (member["profile_image"] as? String)
      let url = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines)
      return Slot(id: id, name: name, url: (url?.isEmpty ?? true) ? nil : url)
    }
  }

  /// Stable, size-aware cache key for a set of slots (order-sensitive). Size is
  /// part of the key so the small home tile and the large profile hero don't
  /// clobber each other in `ChatAvatarImageStore`.
  static func cacheKey(for slots: [Slot], side: CGFloat) -> String {
    "group-composite:" + slots.map(\.id).joined(separator: ",") + "@\(Int(side))"
  }

  /// Fully build the composite for a members payload: parse → load member images
  /// concurrently → render → cache. Returns `nil` when there are fewer than two
  /// usable members (the caller should fall back to initials/single avatar).
  static func composedImage(
    members: [[String: Any]],
    side: CGFloat = 60,
    isDark: Bool
  ) async -> UIImage? {
    let usable = Array(slots(from: members).prefix(4))
    guard usable.count >= 2 else { return nil }

    let key = cacheKey(for: usable, side: side)
    if let cached = ChatAvatarImageStore.cached(for: key) { return cached }

    var images: [String: UIImage] = [:]
    await withTaskGroup(of: (String, UIImage?).self) { group in
      for slot in usable {
        guard let url = slot.url else { continue }
        group.addTask { (slot.id, await ChatAvatarImageStore.load(from: url)) }
      }
      for await (id, image) in group {
        if let image { images[id] = image }
      }
    }

    let composite = render(slots: usable, images: images, side: side, isDark: isDark)
    ChatAvatarImageStore.cache(composite, for: key)
    return composite
  }

  // MARK: - Rendering

  static func render(
    slots: [Slot], images: [String: UIImage], side: CGFloat, isDark: Bool
  ) -> UIImage {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = UIScreen.main.scale
    let size = CGSize(width: side, height: side)
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let rects = compositeRects(count: slots.count, side: side)
    let seam = (isDark ? UIColor.black : UIColor.white).withAlphaComponent(0.7)

    return renderer.image { rendererContext in
      let cg = rendererContext.cgContext
      for (index, slot) in slots.enumerated() where index < rects.count {
        let rect = rects[index]
        cg.saveGState()
        cg.addRect(rect)
        cg.clip()
        if let image = images[slot.id] {
          drawAspectFill(image, in: rect, context: cg)
        } else {
          colorForName(slot.name.isEmpty ? slot.id : slot.name).setFill()
          cg.fill(rect)
          drawInitials(initials(from: slot.name), in: rect, context: rendererContext, side: side)
        }
        cg.restoreGState()
      }
      // Thin seams between tiles.
      seam.setStroke()
      cg.setLineWidth(1)
      for rect in rects {
        cg.stroke(rect)
      }
    }
  }

  private static func compositeRects(count: Int, side: CGFloat) -> [CGRect] {
    let half = side / 2
    switch count {
    case 2:
      return [
        CGRect(x: 0, y: 0, width: half, height: side),
        CGRect(x: half, y: 0, width: half, height: side),
      ]
    case 3:
      return [
        CGRect(x: 0, y: 0, width: half, height: side),
        CGRect(x: half, y: 0, width: half, height: half),
        CGRect(x: half, y: half, width: half, height: half),
      ]
    default:
      return [
        CGRect(x: 0, y: 0, width: half, height: half),
        CGRect(x: half, y: 0, width: half, height: half),
        CGRect(x: 0, y: half, width: half, height: half),
        CGRect(x: half, y: half, width: half, height: half),
      ]
    }
  }

  private static func drawAspectFill(_ image: UIImage, in rect: CGRect, context cg: CGContext) {
    let imageSize = image.size
    guard imageSize.width > 0, imageSize.height > 0 else { return }
    let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
    let drawWidth = imageSize.width * scale
    let drawHeight = imageSize.height * scale
    let drawRect = CGRect(
      x: rect.midX - drawWidth / 2,
      y: rect.midY - drawHeight / 2,
      width: drawWidth,
      height: drawHeight)
    image.draw(in: drawRect)
    _ = cg
  }

  private static func drawInitials(
    _ text: String, in rect: CGRect, context: UIGraphicsImageRendererContext, side: CGFloat
  ) {
    guard !text.isEmpty else { return }
    let fontSize = min(rect.width, rect.height) * 0.42
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
      .foregroundColor: UIColor.white,
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let textSize = attributed.size()
    let origin = CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2)
    attributed.draw(at: origin)
  }

  private static func initials(from name: String) -> String {
    let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
    if parts.isEmpty { return "" }
    if parts.count == 1 {
      return String(parts[0].prefix(1)).uppercased()
    }
    let first = parts[0].prefix(1)
    let second = parts[1].prefix(1)
    return (String(first) + String(second)).uppercased()
  }

  private static func colorForName(_ seed: String) -> UIColor {
    var hash: UInt64 = 5381
    for byte in seed.utf8 {
      hash = (hash &* 33) &+ UInt64(byte)
    }
    let hue = CGFloat(hash % 360) / 360.0
    return UIColor(hue: hue, saturation: 0.55, brightness: 0.72, alpha: 1)
  }
}
