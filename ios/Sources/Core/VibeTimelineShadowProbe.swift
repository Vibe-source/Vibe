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

  /// The core's most recent window, newest last. This is the only thing the core
  /// can hold an authoritative opinion about: it caps at 200 rows and evicts from
  /// the head, so it has nothing to say about anything older than its own window.
  private var latestCoreOrder: [String] = []

  var comparisons: Int { box.comparisons }
  var mismatches: Int { box.mismatches }

  /// One clean comparison in `cleanLogInterval` is logged.
  ///
  /// Logging every clean comparison floods the ring and buries the rare line that
  /// matters — a mistake this project has already shipped once, where the fix for
  /// a noisy export was itself the thing that filled it. Logging *none* is the
  /// opposite failure: a silent probe and a probe that never ran produce byte-for-byte
  /// identical exports, so "no divergence" would be unfalsifiable.
  private static let cleanLogInterval = 25

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
  /// Saved Messages is its own chat class, and it is not a direct message.
  ///
  /// A device run caught the probe arming on `saved_messages`: the only
  /// eligibility input was `isGroupOrChannel`, which Saved Messages answers
  /// `false` to, so it slipped through a DM-only allowlist. It has its own
  /// ordering quirks — the dual-id generations that produced duplicate cells —
  /// which is exactly why it is a separate class with a separate soak.
  private static func chatClass(for chatId: String, isGroupOrChannel: Bool)
    -> VibeTimelineChatClass
  {
    if isGroupOrChannel { return .group }
    if chatId == "saved_messages" || chatId.hasPrefix("saved_messages") {
      return .savedMessages
    }
    return .directMessage
  }

  static func makeIfEligible(
    chatId: String,
    isGroupOrChannel: Bool,
    flags: VibeTimelineFeatureFlags = VibeTimelineUserDefaultsFeatureFlags().flags
  ) -> VibeTimelineShadowProbe? {
    guard flags.vibeTimelineShadowCompareEnabled else { return nil }
    guard !isGroupOrChannel else { return nil }
    let trimmed = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    // The shadow allowlist, not the render one — see the note on the field.
    let chatClass = chatClass(for: trimmed, isGroupOrChannel: isGroupOrChannel)
    guard flags.shadowEligibleChatClasses.contains(chatClass) else { return nil }
    VibeLog.notice(
      "shadow probe armed", category: "core", metadata: ["chat": String(trimmed.prefix(12))])
    return VibeTimelineShadowProbe(chatId: trimmed)
  }

  /// Joins the core's worker thread and reports the verdict for this chat.
  ///
  /// Safe to call from any thread, including a `deinit`, and safe to call more
  /// than once. The tally lives in the lock-guarded box precisely so this line
  /// can be written from a `deinit`, which is not actor-isolated — leaving a chat
  /// is the moment the numbers are final and the only moment anyone would look
  /// for them.
  nonisolated func shutdown() {
    let handle = box.take()
    guard handle != nil else { return }
    handle?.shutdown()
    let (compared, diverged) = box.tally()
    guard compared > 0 else { return }
    var meta: [String: String] = [:]
    meta["chat"] = String(chatId.prefix(12))
    meta["comparisons"] = String(compared)
    meta["divergences"] = String(diverged)
    if diverged == 0 {
      VibeLog.notice("shadow probe closed CLEAN", category: "core", metadata: meta)
    } else {
      VibeLog.error("shadow probe closed WITH DIVERGENCE", category: "core", metadata: meta)
    }
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
    let orderChanged = order != pendingEngineOrder
    pendingEngineOrder = order
    // Ask the core only when something actually changed — a re-emit of an
    // identical window is not a new comparison.
    //
    // "Changed" has to include a *reordering* with no new ids, not just new
    // frames. Gating on `newFrames` alone meant the engine could re-emit the
    // same messages in a different order and the probe would never look, which
    // is precisely the divergence it exists to catch. A device run showed the
    // cost of the narrow rule: one comparison per chat open and nothing after.
    guard newFrames > 0 || orderChanged else { return }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try? handle.flush(nowMs: now)
    try? handle.requestWindow(chatId: chatId, nowMs: now)
  }

  // MARK: Comparison

  /// Reorders the tail of `rows` to match the core, or returns `nil`.
  ///
  /// **This is the read-authority seam.** Everything above it in this type is a
  /// diagnostic; this is the one method whose result can reach the screen.
  ///
  /// It answers `nil` far more often than it answers rows, and every one of those
  /// refusals is deliberate:
  ///
  /// - the core has produced no window yet,
  /// - the core's window and the engine's rows do not cover the same ids, so
  ///   reordering would mean inventing a position for something the core has
  ///   never seen,
  /// - the two already agree, so there is nothing to do and the caller should
  ///   keep its own array rather than pay for a rebuild.
  ///
  /// Only the overlapping **tail** is ever touched. The core evicts from the head
  /// at 200 rows, so it has no opinion about older history and must not be asked
  /// to reorder it. Anything the core does not know keeps the engine's order and
  /// its position.
  func authoritativeOrder(for rows: [[String: Any]]) -> [[String: Any]]? {
    Self.reorder(rows: rows, toMatch: latestCoreOrder)
  }

  /// The reorder decision, as a pure function.
  ///
  /// Separated from the live probe on purpose: this is the only logic in this
  /// file whose output can reach a user's screen, and it should be provable
  /// without a Rust worker thread, a chat, or a device. Every `nil` below is a
  /// case worth a test.
  nonisolated static func reorder(rows: [[String: Any]], toMatch coreOrder: [String])
    -> [[String: Any]]?
  {
    guard !coreOrder.isEmpty, !rows.isEmpty else { return nil }

    // Index the engine's rows by id. Every row must have one, and no id may
    // repeat: `firstGoverned` below is an index into this array and is used to
    // slice `rows`, so the two must line up exactly. A duplicate makes them
    // diverge silently and the reorder would drop or misplace a real message.
    // Duplicates are an engine bug, not something to paper over here.
    var rowById: [String: [String: Any]] = [:]
    var idsInEngineOrder: [String] = []
    idsInEngineOrder.reserveCapacity(rows.count)
    for row in rows {
      guard let id = messageId(from: row) else { return nil }
      guard rowById.updateValue(row, forKey: id) == nil else { return nil }
      idsInEngineOrder.append(id)
    }

    // The core may only speak about ids it holds AND the engine still has.
    let coreKnown = coreOrder.filter { rowById[$0] != nil }
    guard coreKnown.count >= 2 else { return nil }

    // The core's opinion covers a suffix of the engine's rows. Find where that
    // suffix starts; everything before it is history the core has evicted.
    let coreSet = Set(coreKnown)
    guard let firstGoverned = idsInEngineOrder.firstIndex(where: { coreSet.contains($0) })
    else { return nil }

    // Every engine row from that point on must be one the core knows, or the two
    // are describing different transcripts and reordering would interleave them.
    let governed = Array(idsInEngineOrder[firstGoverned...])
    guard governed.count == coreKnown.count, Set(governed) == coreSet else { return nil }
    guard governed != coreKnown else { return nil }

    var reordered = Array(rows.prefix(firstGoverned))
    reordered.append(contentsOf: coreKnown.compactMap { rowById[$0] })
    return reordered
  }

  private func compare(coreOrder: [String]) {
    latestCoreOrder = coreOrder
    let engineOrder = pendingEngineOrder
    guard !engineOrder.isEmpty, !coreOrder.isEmpty else { return }
    let comparisons = box.countComparison()

    // The core caps its window at 200 and evicts from the head, so compare the
    // overlapping tail rather than the whole array. Length disagreement caused by
    // eviction is expected behaviour, not a divergence — the same trap that made
    // the first preview grader report failure on every window.
    let n = min(engineOrder.count, coreOrder.count)
    let engineTail = Array(engineOrder.suffix(n))
    let coreTail = Array(coreOrder.suffix(n))
    guard engineTail != coreTail else {
      if comparisons % Self.cleanLogInterval == 1 {
        VibeLog.info(
          "shadow agrees", category: "core",
          metadata: [
            "chat": String(chatId.prefix(12)),
            "rows": String(n),
            "comparison": String(comparisons),
          ])
      }
      return
    }

    let mismatches = box.countMismatch()
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
  private var comparisonCount = 0
  private var mismatchCount = 0

  var current: VibeCoreHandle? {
    lock.lock()
    defer { lock.unlock() }
    return handle
  }

  var comparisons: Int {
    lock.lock()
    defer { lock.unlock() }
    return comparisonCount
  }

  var mismatches: Int {
    lock.lock()
    defer { lock.unlock() }
    return mismatchCount
  }

  /// Returns the new total so callers can sample without a second lock round-trip.
  func countComparison() -> Int {
    lock.lock()
    defer { lock.unlock() }
    comparisonCount += 1
    return comparisonCount
  }

  func countMismatch() -> Int {
    lock.lock()
    defer { lock.unlock() }
    mismatchCount += 1
    return mismatchCount
  }

  func tally() -> (comparisons: Int, mismatches: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (comparisonCount, mismatchCount)
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

  nonisolated private static func messageId(from row: [String: Any]) -> String? {
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
