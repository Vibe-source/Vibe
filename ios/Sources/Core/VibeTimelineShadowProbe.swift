import Foundation

/// Runs the Rust core **beside** the production list and reports where they disagree.
///
/// # Why this is the right P4 step
///
/// "Gated read authority" means the list renders what the core says. Turning that
/// on for a real conversation before ever having compared the two orderings on
/// real data is a bet, not a rollout — and the failure mode is a user's chat in
/// the wrong order, which is the single most visible bug this app could ship.
///
/// So the gate opens in two moves. This is the first: the same rows the engine is
/// about to render are also fed to the core, and the two orderings are compared.
/// It renders nothing, returns nothing to the caller, and its worst failure is a
/// log line. When divergence is zero across real conversations, read authority is
/// a measurement rather than a hope.
///
/// # What it never does
///
/// - never mutates, returns, or reorders anything the list uses
/// - never logs message bodies — ids, indices and counts only
/// - never runs unless `vibeTimelineShadowCompareEnabled` **and** the chat class
///   is in the eligibility allowlist, both of which default to off/empty
@MainActor
final class VibeTimelineShadowProbe {
  /// Ceiling on rows fed per observation, so a large history page cannot turn a
  /// diagnostic into a stall. The core's own window is 200; going past it would
  /// only measure eviction, which the preview screen already covers.
  private static let maxRowsPerObservation = 300

  private let chatId: String
  /// The handle lives in a lock-guarded box rather than as isolated state so
  /// ``shutdown()`` can be `nonisolated` and therefore callable from a `deinit`.
  /// Tearing the worker down is exactly the thing a dying chat view needs to do,
  /// and `deinit` is not actor-isolated even on a `@MainActor` class.
  private let box = CoreHandleBox()
  private var sink: ShadowSink?

  private var handle: VibeCoreHandle? { box.current }

  /// Ids already handed to the core. Re-ingesting an unchanged row every time the
  /// engine re-emits its window would be pure overhead — the core would dedup it,
  /// but only after paying for the JSON.
  private var ingested: Set<String> = []

  /// Engine order as of the last observation, awaiting the core's answer.
  private var pendingEngineOrder: [String] = []

  private(set) var comparisons = 0
  private(set) var mismatches = 0

  init(chatId: String) {
    self.chatId = chatId
  }

  /// Builds a probe only when every gate agrees, otherwise `nil`.
  ///
  /// The eligibility decision lives here rather than at the call site so that
  /// `ChatListView`'s footprint stays at the "one branch" the plan budgets for —
  /// and so the rule that P4 is **1:1 DM only** is written once, next to the
  /// thing it governs, instead of being a condition someone can later widen in
  /// passing.
  ///
  /// Fails closed: unset flags, an empty allowlist, a group, a channel, or a
  /// blank chat id all return `nil`.
  static func makeIfEligible(
    chatId: String,
    isGroupOrChannel: Bool,
    flags: VibeTimelineFeatureFlags = VibeTimelineUserDefaultsFeatureFlags().flags
  ) -> VibeTimelineShadowProbe? {
    guard flags.vibeTimelineShadowCompareEnabled else { return nil }
    guard !isGroupOrChannel else { return nil }
    guard flags.eligibleChatClasses.contains(.directMessage) else { return nil }
    let trimmed = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    VibeLog.notice(
      "shadow probe armed", category: "core", metadata: ["chat": String(trimmed.prefix(12))])
    return VibeTimelineShadowProbe(chatId: trimmed)
  }

  /// Joins the core's worker thread. Safe to call from any thread, including a
  /// `deinit`, and safe to call more than once.
  nonisolated func shutdown() {
    box.take()?.shutdown()
  }

  /// Feeds one engine window to the core and schedules a comparison.
  ///
  /// `rows` is the engine's own payload array, in the order it is about to
  /// render. Rows without a usable id or millisecond timestamp are skipped: the
  /// probe compares ordering, and a row the core cannot place is not evidence of
  /// a core defect.
  func observe(rows: [[String: Any]]) {
    guard !rows.isEmpty else { return }
    startIfNeeded()
    guard let handle else { return }

    let slice = rows.suffix(Self.maxRowsPerObservation)
    var order: [String] = []
    order.reserveCapacity(slice.count)
    var newFrames = 0

    for row in slice {
      guard let id = Self.messageId(from: row), let ts = Self.timestampMs(from: row) else {
        continue
      }
      order.append(id)
      guard !ingested.contains(id) else { continue }
      ingested.insert(id)
      newFrames += 1
      let frame = Self.frame(id: id, chatId: chatId, tsMs: ts, isMine: Self.isMine(row))
      do {
        try handle.ingestFrame(
          chatId: chatId, json: frame, source: .chatTopic, receivedAtMs: ts)
      } catch {
        VibeLog.warning(
          "shadow ingest rejected", category: "core",
          metadata: ["chat": String(chatId.prefix(12)), "error": String(describing: error)])
      }
    }

    guard !order.isEmpty else { return }
    pendingEngineOrder = order
    // Only ask for a window when something actually changed. A re-emit of an
    // identical window is not a new comparison.
    guard newFrames > 0 else { return }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try? handle.flush(nowMs: now)
    try? handle.requestWindow(chatId: chatId, nowMs: now)
  }

  // MARK: Comparison

  private func compare(coreOrder: [String]) {
    let engineOrder = pendingEngineOrder
    guard !engineOrder.isEmpty, !coreOrder.isEmpty else { return }
    comparisons += 1

    // The core caps its window at 200 and evicts from the head, so compare the
    // overlapping tail rather than the whole array. Length disagreement caused by
    // eviction is expected behaviour, not a divergence — the same trap that made
    // the first preview grader report failure on every window.
    let n = min(engineOrder.count, coreOrder.count)
    let engineTail = Array(engineOrder.suffix(n))
    let coreTail = Array(coreOrder.suffix(n))
    guard engineTail != coreTail else { return }

    mismatches += 1
    let diffs = VibeTimelineShadowComparator.compareOrder(
      leftIds: engineTail, rightIds: coreTail)
    let firstIndex = diffs.first(where: { $0.kind == .orderMismatch })?.metricA ?? -1

    // Ids and indices only. This is a divergence report, not a transcript.
    // Built incrementally rather than as one literal: a large heterogeneous
    // dictionary literal is exactly the shape that blows up Swift's type checker.
    var meta: [String: String] = [:]
    meta["chat"] = String(chatId.prefix(12))
    meta["compared"] = String(n)
    meta["engineRows"] = String(engineOrder.count)
    meta["coreRows"] = String(coreOrder.count)
    meta["firstDivergentIndex"] = String(Int(firstIndex))
    meta["diffs"] = String(diffs.count)
    meta["mismatches"] = String(mismatches)
    meta["of"] = String(comparisons)
    VibeLog.error("shadow order divergence", category: "core", metadata: meta)
  }

  // MARK: Core lifecycle

  private func startIfNeeded() {
    guard handle == nil else { return }
    let sink = ShadowSink()
    sink.onWindow = { [weak self] ids in
      Task { @MainActor in self?.compare(coreOrder: ids) }
    }
    self.sink = sink
    // Immediate flush: the probe is comparing a settled window, not driving a
    // renderer, so frame coalescing would only delay the answer.
    box.set(
      VibeCoreHandle(config: VibeFfiConfig(ownUserId: "", flushFrameIntervalMs: 0), sink: sink))
  }

/// Lock-guarded handle holder.
///
/// `@unchecked Sendable` is an assertion, so here is the basis for it: the core
/// handle wraps a Rust object whose only mutable state sits behind the worker
/// thread's command queue, and the FFI layer exposes no synchronous read. The
/// lock in this box guards the Swift-side *reference*, which is the only part
/// Swift can race on.
private final class CoreHandleBox: @unchecked Sendable {
  private let lock = NSLock()
  private var handle: VibeCoreHandle?

  var current: VibeCoreHandle? {
    lock.lock()
    defer { lock.unlock() }
    return handle
  }

  func set(_ newHandle: VibeCoreHandle?) {
    lock.lock()
    defer { lock.unlock() }
    handle = newHandle
  }

  /// Clears and returns the handle, so a double shutdown is a no-op.
  func take() -> VibeCoreHandle? {
    lock.lock()
    defer { lock.unlock() }
    let existing = handle
    handle = nil
    return existing
  }
}

  // MARK: Row parsing

  private static func messageId(from row: [String: Any]) -> String? {
    for key in ["messageId", "id", "key"] {
      if let value = row[key] as? String, !value.isEmpty { return value }
    }
    return nil
  }

  /// Millisecond timestamp, and only that.
  ///
  /// `timestamp` is a *display label* in some row payloads and epoch ms in
  /// others. Accepting a string here would parse "12:04" as garbage and produce
  /// a divergence report blaming the core for the probe's own bug.
  private static func timestampMs(from row: [String: Any]) -> Int64? {
    for key in ["timestampMs", "timestamp_ms", "timestamp"] {
      if let value = row[key] as? Int64 { return value }
      if let value = row[key] as? Int { return Int64(value) }
      if let value = row[key] as? Double, value.isFinite { return Int64(value) }
      if let value = row[key] as? NSNumber { return value.int64Value }
    }
    return nil
  }

  private static func isMine(_ row: [String: Any]) -> Bool {
    (row["isMe"] as? Bool) ?? (row["isMine"] as? Bool) ?? false
  }

  /// Builds the minimal frame the core needs to place a row.
  ///
  /// Body text is deliberately **empty**. Ordering depends on `(ts_ms,
  /// message_id)` and nothing else, so sending the message content would put
  /// plaintext through a diagnostic path for no benefit to what is being
  /// measured.
  private static func frame(id: String, chatId: String, tsMs: Int64, isMine: Bool) -> Data {
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

/// Receives windows from the Rust worker thread. Ids only.
private final class ShadowSink: VibeDeltaSink {
  var onWindow: (([String]) -> Void)?

  func onDelta(delta: VibeFfiDelta) {}

  func onWindow(window: VibeFfiWindow) {
    onWindow?(window.messages.map(\.messageId))
  }

  func onError(message: String) {
    VibeLog.warning("shadow core error", category: "core", metadata: ["message": message])
  }
}
