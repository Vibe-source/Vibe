import Foundation
import UIKit

/// Feeds the timeline core the rows the list is about to render, and lets the core
/// answer with the window: which rows, in what order, how tall.
///
/// # The seam
///
/// ```
/// ChatEngine → setRows → VibeCoreListDriver → core
///                                              ↓
///              ChatListView ← VibeTimelineHost ┘
/// ```
///
/// One feed, and it is the one the list already trusts. That is the entire correction
/// over the screen deleted on 2026-08-03: a second feed was written against the row
/// payload and got its shape wrong — see ``messageTimestampMs`` — so the core was handed
/// nothing and rendered nothing. Rows arrive here already proven by the list that is
/// about to draw them.
///
/// # Threading
///
/// `@MainActor` throughout. Core callbacks arrive on the Rust worker thread and hop
/// before touching anything here; `VibeTimelineHost` funnels commits through a
/// display-link committer so a burst of deltas is at most one commit per frame.
@MainActor
final class VibeCoreListDriver {

  private let chatId: String
  private let timelineHost: VibeTimelineHost
  private var handle: VibeCoreHandle?
  private var sink: CoreListSink?

  /// Ids already handed to the core. Re-ingesting an unchanged row every time the engine
  /// re-emits its window would pay for the JSON just to have the core dedup it.
  private var ingestedIds: Set<String> = []

  /// The order handed over last time, so a re-emit of an identical window does not ask
  /// for a new one. A *reorder* with no new ids still counts as a change — gating on new
  /// frames alone is how a probe once looked exactly once per chat open.
  private var lastObservedOrder: [String] = []

  private(set) var observations = 0
  private(set) var skippedRows = 0

  /// Ceiling per observation. The core's own window is 200; past it this would only be
  /// measuring eviction, which the preview screens already cover.
  private static let maxRowsPerObservation = 300

  init(chatId: String, listHost: VibeMessageListHost) {
    self.chatId = chatId
    self.timelineHost = VibeTimelineHost(chatId: chatId, listHost: listHost)
    timelineHost.onNeedsResync = { [weak self] in self?.requestWindow() }
    timelineHost.onDiagnostic = { message, meta in
      VibeLog.error("core list adapter: \(message)", category: "core", metadata: meta)
    }
  }

  /// Starts the worker. Idempotent.
  func start(rowProvider: @escaping (String) -> ChatListRow?) {
    guard handle == nil else { return }
    timelineHost.setRowProvider(rowProvider)

    let sink = CoreListSink()
    sink.onWindow = { [weak self] window in
      Task { @MainActor in self?.timelineHost.mount(window: window, reason: .engineReconcile) }
    }
    sink.onDelta = { [weak self] delta in
      Task { @MainActor in self?.timelineHost.ingest(delta: delta) }
    }
    self.sink = sink
    handle = VibeCoreHandle(
      config: VibeFfiConfig(
        // Matches the `sender_id` written into every frame below. The two must agree,
        // and agreeing on a constant this side controls beats agreeing on an id the
        // engine may not have resolved yet at open.
        ownUserId: "me",
        // One display frame at 120 Hz — stream sources coalesce up to this barrier.
        flushFrameIntervalMs: 8),
      sink: sink)
  }

  /// Tells the core the width rows must be measured against.
  func setLayoutWidth(_ width: CGFloat) {
    guard width > 0 else { return }
    timelineHost.setEnvironment(width: width)
  }

  func shutdown() {
    timelineHost.shutdown()
    handle?.shutdown()
    handle = nil
    sink = nil
    ingestedIds.removeAll()
    lastObservedOrder.removeAll()
  }

  var measurementStats: (measured: Int, reused: Int, invalidations: Int, placeholders: Int) {
    timelineHost.measurementStats
  }

  // MARK: Feed

  /// Hands the core the window the list is about to render.
  ///
  /// `rows` is the engine's own payload array, in the order it is about to draw. A row
  /// without a usable id or millisecond timestamp is counted and skipped rather than
  /// dropped silently — a core that is quietly fed nothing looks identical in the log to
  /// a core that agrees with everything, which is exactly how the deleted screen shipped
  /// an empty transcript.
  func observe(rows: [[String: Any]]) {
    guard let handle, !rows.isEmpty else { return }
    let slice = rows.count > Self.maxRowsPerObservation
      ? Array(rows.suffix(Self.maxRowsPerObservation)) : rows

    var order: [String] = []
    order.reserveCapacity(slice.count)
    var newFrames = 0
    var skipped = 0

    for row in slice {
      guard let id = Self.messageId(from: row), let ts = Self.messageTimestampMs(from: row)
      else {
        skipped += 1
        continue
      }
      order.append(id)
      guard !ingestedIds.contains(id) else { continue }
      ingestedIds.insert(id)
      newFrames += 1
      do {
        try handle.ingestFrame(
          chatId: chatId,
          json: Self.frame(id: id, chatId: chatId, tsMs: ts, isMine: Self.isMine(row)),
          source: .chatTopic,
          receivedAtMs: ts)
      } catch {
        VibeLog.warning(
          "core list ingest rejected", category: "core",
          metadata: ["chat": String(chatId.prefix(12)), "error": String(describing: error)])
      }
    }

    skippedRows += skipped
    observations += 1
    // A whole window that parsed to nothing is a payload-shape bug, not a quiet day.
    if !slice.isEmpty, order.isEmpty {
      NSLog(
        "[VibeCore] driver FED-NOTHING chat=%@ rows=%d — every row missing an id or a ms timestamp",
        String(chatId.prefix(12)), slice.count)
      return
    }
    let orderChanged = order != lastObservedOrder
    lastObservedOrder = order
    guard newFrames > 0 || orderChanged else { return }
    if observations % 25 == 1 || newFrames > 0 {
      NSLog(
        "[VibeCore] driver FED chat=%@ rows=%d new=%d skipped=%d obs=%d",
        String(chatId.prefix(12)), order.count, newFrames, skipped, observations)
    }
    requestWindow()
  }

  private func requestWindow() {
    guard let handle else { return }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try? handle.flush(nowMs: now)
    try? handle.requestWindow(chatId: chatId, nowMs: now)
  }

  // MARK: Row payload

  /// The id the engine and the list agree on.
  ///
  /// `key` is the list's own row key and is always present at the top level; the message
  /// id lives one level down. Both are accepted, top level first, because a row that
  /// reaches the core under one id and the list under another is a row the two can never
  /// be compared on.
  nonisolated static func messageId(from row: [String: Any]) -> String? {
    for key in ["messageId", "id", "key"] {
      if let value = row[key] as? String, !value.isEmpty { return value }
    }
    if let message = row["message"] as? [String: Any] {
      for key in ["messageId", "id"] {
        if let value = message[key] as? String, !value.isEmpty { return value }
      }
    }
    return nil
  }

  /// Milliseconds since epoch, and only that.
  ///
  /// **This function is the bug that killed the parallel chat screen.** Engine rows are
  /// *nested*: the epoch timestamp is at `row["message"]["timestampMs"]`, matching
  /// `ChatEngine.messageTimestampMs(fromRow:)`. A reader that looked only at the top
  /// level answered `nil` for every row, so every row was skipped, so the core was never
  /// handed a single message and the transcript came up empty.
  ///
  /// The top level is still checked first because some payloads do carry it flat — but
  /// only as a *number*. `timestamp` is a display label ("22:20") in several row shapes,
  /// and accepting a string here would order the transcript by nonsense and read as a
  /// core defect.
  nonisolated static func messageTimestampMs(from row: [String: Any]) -> Int64? {
    if let value = numericMs(from: row) { return value }
    if let message = row["message"] as? [String: Any] { return numericMs(from: message) }
    return nil
  }

  private nonisolated static func numericMs(from container: [String: Any]) -> Int64? {
    for key in ["timestampMs", "timestamp_ms", "timestamp"] {
      if let value = container[key] as? Int64 { return value }
      if let value = container[key] as? Int { return Int64(value) }
      if let value = container[key] as? Double, value.isFinite { return Int64(value) }
      if let value = container[key] as? NSNumber { return value.int64Value }
    }
    return nil
  }

  nonisolated static func isMine(_ row: [String: Any]) -> Bool {
    if let value = row["isMe"] as? Bool { return value }
    if let value = row["isMine"] as? Bool { return value }
    if let message = row["message"] as? [String: Any] {
      if let value = message["isMe"] as? Bool { return value }
      if let value = message["isMine"] as? Bool { return value }
    }
    return false
  }

  /// The minimal frame the core needs to place a row.
  ///
  /// `content` is empty on purpose. The core orders by `(ts_ms, message_id)` and nothing
  /// else, and the body is already on the Swift side behind `rowProvider` — sending
  /// plaintext across the FFI would buy nothing.
  nonisolated static func frame(id: String, chatId: String, tsMs: Int64, isMine: Bool) -> Data {
    let object: [String: Any] = [
      "id": id,
      "chat_id": chatId,
      "sender_id": isMine ? "me" : "peer",
      "timestamp": tsMs,
      "content": "",
      "type": "text",
    ]
    return (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
  }
}

/// Forwards core callbacks. Called on the Rust worker thread — every handler hops.
private final class CoreListSink: VibeDeltaSink {
  var onWindow: ((VibeFfiWindow) -> Void)?
  var onDelta: ((VibeFfiDelta) -> Void)?

  func onDelta(delta: VibeFfiDelta) { onDelta?(delta) }
  func onWindow(window: VibeFfiWindow) { onWindow?(window) }
  func onError(message: String) {
    VibeLog.error("core list error", category: "core", metadata: ["message": message])
  }
}
