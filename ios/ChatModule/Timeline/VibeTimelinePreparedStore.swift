import Foundation
import UIKit

/// A transcript that was parsed and measured **before** the push, so opening a chat
/// costs a dictionary lookup per row instead of a measurement per row.
///
/// # Why this exists
///
/// `presentationSeedMessageHeight` measures every non-agent kind exactly, and that is
/// the right answer: an estimate that disagrees with the later measurement *is* the
/// shift this project exists to remove, and each kind was converted estimate→exact to
/// kill a named jump (voice 3 pt, video note 20 pt, media 20 pt, text 16 pt).
///
/// But it runs those measurements at seed time, and seed time is inside the push. A
/// device run on the current build reads:
///
/// ```
/// [ChatOpen] presentation-seed rows=134 layoutMs=164 mountMs=176 totalMs=180
/// [ChatOpen] host-stage pre-push prestage 214ms
/// ```
///
/// Requirement 1 is that the push is not settled by the main thread **at all**.
/// Measuring on the push satisfies "never shifts" and violates that one. Measuring
/// off the push satisfies both, and that is the entire content of this file — the
/// numbers are identical, only *when* they are produced changes.
///
/// # What it is not
///
/// It is not a second height system. It calls `VibeRowMetrics.height`, which calls
/// `measureMessageBubbleLayout`, which is the same function the cell calls — so
/// agreement is identity, not tolerance. A store that computed its own answer would
/// owe the real path 0.5 pt of agreement forever, which is the defect, not the fix.
///
/// # Threading
///
/// Written from a background queue, read from the seed on main, so every access is
/// behind one lock. The measurement is off-main-safe by construction:
/// `VibeRowMetrics.height` returns `nil` for the one kind that needs a live view
/// (`VibeAgentTurnContentView`), and those keys come back as `deferredKeys` rather
/// than being silently dropped — a row with no prepared height falls back to the
/// estimate, and an unnoticed estimate is how this bug survived for months.
final class VibeTimelinePreparedStore: @unchecked Sendable {
  static let shared = VibeTimelinePreparedStore()

  /// One chat's transcript, ordered and sized, as of a particular width.
  struct Prepared {
    let chatId: String
    /// The width every height in `heightsByKey` was measured against. A prepared set
    /// is only valid at its own width; handing it out at another one would be a
    /// wrong number rather than a missing one, which is strictly worse.
    let width: CGFloat
    /// Row keys oldest → newest, as the engine ordered them.
    let orderedKeys: [String]
    let heightsByKey: [String: VibeRowMetrics.Measured]
    /// The row each height was measured from.
    ///
    /// Kept, rather than trusting the key, because a key is stable across an edit, a
    /// status change and a tail change, and every one of those changes the height. The
    /// in-memory height cache already guards itself this way (`chatListRowContentEqual`);
    /// a prepared height that skipped the same check would be a *stale* height, which is
    /// a shift with an extra step — and the caller owns that predicate, so it is handed
    /// back the row rather than asked to trust a fingerprint computed here.
    let rowsByKey: [String: ChatListRow]
    /// Keys that could only be measured on the main thread (agent turns). Recorded
    /// so the seed can tell "no prepared height" from "prepared height of zero".
    let deferredKeys: Set<String>
    let preparedAt: TimeInterval
    /// How long the off-push measurement actually took, for the liveness log.
    let measureMs: Int
  }

  /// Chats kept prepared at once. The MRU list the raster prewarm uses is six; eight
  /// leaves room for the two the user bounces between without letting a long session
  /// accumulate transcripts nothing will open.
  private static let maxChats = 8

  /// Ceiling on rows measured per chat. The core's own window is 200 and the list
  /// seeds a full window, so this covers a whole open; past it the marginal row is
  /// off-screen by thousands of points and its height is not what anyone is looking at.
  private static let maxRows = 200

  private let lock = NSLock()
  private var byChat: [String: Prepared] = [:]
  /// MRU, most recent last.
  private var order: [String] = []

  /// Width the list last reported. Preparation is skipped until it is known, because
  /// measuring against a guessed width and correcting on mount is the shift.
  private var measurementWidth: CGFloat = 0

  /// Serial so two persists for the same chat cannot interleave into a half-old,
  /// half-new height map. Utility QoS: this is work that must not compete with the
  /// engine queue or with a scroll.
  private let queue = DispatchQueue(
    label: "com.vibegram.timeline.prepare", qos: .utility)

  // Counters for the liveness line. Ids and numbers only.
  private(set) var preparations = 0
  private(set) var hits = 0
  private(set) var misses = 0

  private init() {}

  // MARK: Environment

  /// Publishes the width rows must be measured against.
  ///
  /// The list owns this number (`bounds.width - messageHorizontalInset * 2`), and it
  /// is uniform for a 1:1 DM because there is no sender-name gutter to subtract. A
  /// change invalidates everything: heights measured at another width are not stale,
  /// they are wrong.
  func setMeasurementWidth(_ width: CGFloat) {
    guard width > 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    guard abs(measurementWidth - width) > 0.5 else { return }
    let previous = measurementWidth
    measurementWidth = width
    guard !byChat.isEmpty else { return }
    byChat.removeAll(keepingCapacity: true)
    order.removeAll(keepingCapacity: true)
    NSLog(
      "[VibeCore] prepared-store WIDTH %.0f→%.0f — dropped every prepared transcript",
      previous, width)
  }

  var currentMeasurementWidth: CGFloat {
    lock.lock()
    defer { lock.unlock() }
    return measurementWidth
  }

  // MARK: Write

  /// Prepares a chat off the caller's thread.
  ///
  /// Takes raw rows rather than `ChatListRow` on purpose: the parse and the decrypt
  /// are themselves main-thread work at open today, and moving the measurement while
  /// leaving the parse behind would only relocate half the cost.
  func prepareAsync(chatId: String, rawRows: [[String: Any]], reason: String) {
    let trimmed = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !rawRows.isEmpty else { return }
    let width = currentMeasurementWidth
    guard width > 0 else { return }
    // Newest rows are the ones a chat opens on, so a transcript longer than the cap
    // keeps its tail rather than its head.
    let bounded = rawRows.count > Self.maxRows ? Array(rawRows.suffix(Self.maxRows)) : rawRows
    queue.async { [weak self] in
      self?.prepareNow(chatId: trimmed, rawRows: bounded, width: width, reason: reason)
    }
  }

  /// Prepares from rows the caller has **already parsed**.
  ///
  /// The list has them; re-serialising them so this could parse them again would be
  /// pure ceremony. Used on the way *out* of a chat, which is the moment the transcript
  /// is final, the main thread is idle, and the next open is the one that pays.
  func prepareAsync(chatId: String, rows: [ChatListRow], reason: String) {
    let trimmed = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !rows.isEmpty else { return }
    let width = currentMeasurementWidth
    guard width > 0 else { return }
    // Bounded before the hop as well as inside `prepareNow`, so a long transcript is not
    // copied across a queue boundary only to have most of it thrown away.
    let bounded = rows.count > Self.maxRows ? Array(rows.suffix(Self.maxRows)) : rows
    queue.async { [weak self] in
      self?.prepareNow(chatId: trimmed, rows: bounded, width: width, reason: reason)
    }
  }

  /// The measurement itself. Synchronous, and never called on main by the app —
  /// exposed at this level so a test can assert the result without a queue hop.
  @discardableResult
  func prepareNow(
    chatId: String, rawRows: [[String: Any]], width: CGFloat, reason: String
  ) -> Prepared? {
    var rows: [ChatListRow] = []
    rows.reserveCapacity(rawRows.count)
    for raw in rawRows {
      guard let row = ChatListRow(raw: raw) else { continue }
      rows.append(row)
    }
    return prepareNow(chatId: chatId, rows: rows, width: width, reason: reason)
  }

  @discardableResult
  func prepareNow(
    chatId: String, rows: [ChatListRow], width: CGFloat, reason: String
  ) -> Prepared? {
    guard width > 0, !rows.isEmpty else { return nil }
    let started = ProcessInfo.processInfo.systemUptime
    // The cap is enforced here rather than at the async wrapper so no entry point can
    // bypass it. Newest rows are the ones a chat opens on, so a transcript longer than
    // the window keeps its tail; past it a row is thousands of points off screen and its
    // height is not what anyone is looking at.
    let rows = rows.count > Self.maxRows ? Array(rows.suffix(Self.maxRows)) : rows

    let measured = VibeRowMetrics.measuredBatch(rows: rows, rowWidth: width)
    var rowsByKey: [String: ChatListRow] = [:]
    rowsByKey.reserveCapacity(measured.byKey.count)
    for row in rows where measured.byKey[row.key] != nil { rowsByKey[row.key] = row }
    let prepared = Prepared(
      chatId: chatId,
      width: width,
      orderedKeys: rows.map(\.key),
      heightsByKey: measured.byKey,
      rowsByKey: rowsByKey,
      deferredKeys: Set(measured.deferredKeys),
      preparedAt: ProcessInfo.processInfo.systemUptime,
      measureMs: Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
    )

    lock.lock()
    // A width change while this was measuring makes every number in it wrong. Drop it
    // rather than store it — the seed would have no way to tell.
    guard abs(measurementWidth - width) <= 0.5 else {
      lock.unlock()
      return nil
    }
    byChat[chatId] = prepared
    order.removeAll { $0 == chatId }
    order.append(chatId)
    while order.count > Self.maxChats, let oldest = order.first {
      order.removeFirst()
      byChat.removeValue(forKey: oldest)
    }
    preparations += 1
    let total = preparations
    lock.unlock()

    NSLog(
      "[VibeCore] prepared chat=%@ rows=%d sized=%d deferred=%d width=%.0f ms=%d reason=%@ total=%d",
      String(chatId.prefix(12)), rows.count, prepared.heightsByKey.count,
      prepared.deferredKeys.count, width, prepared.measureMs, reason, total)
    return prepared
  }

  /// Forgets one chat. Called when its transcript is structurally healed — prepared
  /// heights for rows that no longer exist are a gap of the wrong size.
  func invalidate(chatId: String) {
    let trimmed = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    guard byChat.removeValue(forKey: trimmed) != nil else { return }
    order.removeAll { $0 == trimmed }
  }

  // MARK: Read

  /// The prepared transcript for a chat, or `nil` when there is none at this width.
  ///
  /// Deliberately returns `nil` rather than a best effort: the caller's fallback is
  /// the exact measurement it does today, so a miss costs what the current build
  /// costs and nothing is risked by not having an answer.
  func prepared(chatId: String, width: CGFloat) -> Prepared? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = byChat[chatId], abs(entry.width - width) <= 0.5 else { return nil }
    return entry
  }

  /// One row's prepared height **and the row it was measured from**.
  ///
  /// The caller must confirm the row it is about to size still equals the one measured
  /// here before using the height, with the same predicate its in-memory cache uses.
  /// Returning the height alone would make this store the one height source in the app
  /// that cannot tell a stale answer from a fresh one.
  ///
  /// Hits and misses are tallied by ``noteHit(_:)`` at the call site rather than here,
  /// so a lookup the caller then rejects on content is counted as the miss it is.
  func preparedRow(chatId: String, key: String, width: CGFloat)
    -> (row: ChatListRow, measured: VibeRowMetrics.Measured)?
  {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = byChat[chatId], abs(entry.width - width) <= 0.5,
      let measured = entry.heightsByKey[key], let row = entry.rowsByKey[key]
    else { return nil }
    return (row, measured)
  }

  /// Records whether a prepared height was actually used.
  func noteHit(_ used: Bool) {
    lock.lock()
    defer { lock.unlock() }
    if used { hits += 1 } else { misses += 1 }
  }

  /// `(hits, misses, preparations)` for the seed's liveness line.
  var stats: (hits: Int, misses: Int, preparations: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (hits, misses, preparations)
  }

  /// Resets counters and content. Tests only — the app has no reason to forget
  /// everything at once, and a shared singleton that tests mutate needs a way back.
  func resetForTesting() {
    lock.lock()
    defer { lock.unlock() }
    byChat.removeAll()
    order.removeAll()
    measurementWidth = 0
    preparations = 0
    hits = 0
    misses = 0
  }
}
