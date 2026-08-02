import CoreGraphics
import Foundation
import UIKit

// MARK: - Metrics

/// Bubble geometry constants used to measure a row.
///
/// These live in Swift and always will. The core decides *what* a row is and
/// *whether* a change can affect its height; it cannot decide *how tall* the row
/// is, because that is `UIFont`, Dynamic Type, the text engine, and the device's
/// line-breaking rules. Anyone hoping the Rust core would make scrolling smooth
/// by itself should read this struct and §0 of the refactor doc.
struct VibeTimelineMetrics: Equatable {
  var horizontalInset: CGFloat = 12
  var bubblePaddingH: CGFloat = 11
  var bubblePaddingV: CGFloat = 7
  var interRowSpacing: CGFloat = 4
  var metaHeight: CGFloat = 13
  var maxBubbleWidthFraction: CGFloat = 0.78
  var minRowHeight: CGFloat = 28

  /// Height reserved for media whose natural size is not yet known.
  ///
  /// Deliberately **not** a square. Guessing square and correcting after decode
  /// is the media list-shift bug; a fixed reservation is wrong-looking at worst,
  /// whereas a corrected guess moves every row below it.
  var unknownMediaHeight: CGFloat = 220

  static let `default` = VibeTimelineMetrics()
}

// MARK: - Measured geometry cache

/// One row's frozen geometry.
///
/// `revision` only advances when something *allowed* to change height did.
struct VibeMeasuredRow: Equatable {
  let size: CGSize
  let layout: VibeBubbleLayoutSpec
  let revision: UInt64
}

/// Measures rows and, more importantly, refuses to re-measure settled ones.
///
/// # The actual layout-shift fix
///
/// The shipped list re-derives a row's height whenever anything about the row
/// changes, and estimates it when measurement is too expensive. Both are how a
/// settled row's height moves after it is on screen: an estimate that was ~16 pt
/// short, a media box that guessed square and corrected after decode, a receipt
/// arriving and dragging a re-layout with it.
///
/// Here a settled row is measured **once** and the result is frozen. A
/// content-only op reuses the frozen size verbatim — it is not re-measured and
/// then compared, it is never measured again at all, so there is nothing to
/// drift. Height can only change through `UpdateGeometry`, which the core emits
/// only for the mask bits that are geometry-relevant (§5.3), and which the host
/// applies with anchor preservation.
///
/// The cache is invalidated wholesale by width, Dynamic Type, or theme changes —
/// those legitimately re-measure everything, and §5.4 says they get one new
/// snapshot and one preserve, not per-row thrash.
@MainActor
final class VibeRowMeasurementCache {
  private var rows: [String: VibeMeasuredRow] = [:]
  private var width: CGFloat = 0
  private var contentSizeCategory: UIContentSizeCategory = .large
  private var themeEpoch: UInt64 = 0

  private(set) var measurements = 0
  private(set) var reuses = 0
  private(set) var invalidations = 0

  var metrics: VibeTimelineMetrics = .default

  /// Returns true when the environment changed and every row must be re-measured.
  @discardableResult
  func setEnvironment(
    width: CGFloat, contentSizeCategory: UIContentSizeCategory, themeEpoch: UInt64
  ) -> Bool {
    guard
      width != self.width || contentSizeCategory != self.contentSizeCategory
        || themeEpoch != self.themeEpoch
    else { return false }
    self.width = width
    self.contentSizeCategory = contentSizeCategory
    self.themeEpoch = themeEpoch
    rows.removeAll(keepingCapacity: true)
    invalidations += 1
    return true
  }

  var layoutWidth: CGFloat { width }

  func cached(_ messageId: String) -> VibeMeasuredRow? { rows[messageId] }

  func forget(_ messageId: String) { rows.removeValue(forKey: messageId) }

  func forgetAll() { rows.removeAll(keepingCapacity: true) }

  /// Frozen geometry for a settled row: measured on first sight, reused forever.
  func settledGeometry(for message: VibeFfiMessage) -> VibeMeasuredRow {
    if let hit = rows[message.messageId] {
      reuses += 1
      return hit
    }
    let measured = measure(message, revision: 1)
    rows[message.messageId] = measured
    measurements += 1
    return measured
  }

  /// Re-measures a row that is *allowed* to change height, bumping its revision.
  ///
  /// The only legitimate way a settled row's size moves.
  func remeasure(_ message: VibeFfiMessage) -> VibeMeasuredRow {
    let previous = rows[message.messageId]?.revision ?? 0
    let measured = measure(message, revision: previous + 1)
    rows[message.messageId] = measured
    measurements += 1
    return measured
  }

  // MARK: Measurement

  private func measure(_ message: VibeFfiMessage, revision: UInt64) -> VibeMeasuredRow {
    let available = max(80, width - metrics.horizontalInset * 2)
    let maxBubble = max(60, available * metrics.maxBubbleWidthFraction)
    let textWidth = maxBubble - metrics.bubblePaddingH * 2

    let font = UIFont.preferredFont(
      forTextStyle: .body,
      compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
    )

    var contentHeight: CGFloat = 0
    var contentWidth: CGFloat = 0

    // Media first: it dictates the bubble width when present.
    var mediaFrame = CGRect.zero
    if message.hasMedia {
      // No natural size crosses this boundary yet, so every media row reserves
      // the same box and keeps it. When `VibeFfiMessage` starts carrying natural
      // size this becomes `aspect * width`, still measured once and frozen.
      mediaFrame = CGRect(x: 0, y: 0, width: textWidth, height: metrics.unknownMediaHeight)
      contentHeight += mediaFrame.height
      contentWidth = max(contentWidth, mediaFrame.width)
    }

    var textFrame = CGRect.zero
    let body = message.text.isEmpty ? (message.caption ?? "") : message.text
    if !body.isEmpty {
      let bounds = (body as NSString).boundingRect(
        with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font],
        context: nil
      )
      let h = ceil(bounds.height)
      textFrame = CGRect(x: 0, y: contentHeight, width: ceil(bounds.width), height: h)
      contentHeight += h
      contentWidth = max(contentWidth, textFrame.width)
    }

    var replyFrame = CGRect.zero
    if message.hasReply {
      // Reply chrome is fixed-height by design. A variable-height reply preview
      // whose height arrives with the quoted message is another way a settled row
      // moves, so it does not get to be variable here.
      replyFrame = CGRect(x: 0, y: 0, width: textWidth, height: 34)
      contentHeight += replyFrame.height
      textFrame.origin.y += replyFrame.height
      mediaFrame.origin.y += replyFrame.height
      contentWidth = max(contentWidth, replyFrame.width)
    }

    contentHeight += metrics.metaHeight
    let metaFrame = CGRect(
      x: 0, y: contentHeight - metrics.metaHeight, width: contentWidth, height: metrics.metaHeight)

    let bubbleWidth = min(maxBubble, contentWidth + metrics.bubblePaddingH * 2)
    let rowHeight = max(
      metrics.minRowHeight, contentHeight + metrics.bubblePaddingV * 2 + metrics.interRowSpacing)

    return VibeMeasuredRow(
      size: CGSize(width: bubbleWidth, height: ceil(rowHeight)),
      layout: VibeBubbleLayoutSpec(
        textFrame: textFrame,
        mediaBoxFrame: mediaFrame,
        replyFrame: replyFrame,
        metaFrame: metaFrame,
        avatarGutter: .zero
      ),
      revision: revision
    )
  }
}

// MARK: - Order key

enum VibeTimelineOrderKeyFactory {
  /// Maps a message onto the render contract's order key.
  ///
  /// `rank` is the timestamp mapped order-preservingly onto `UInt64` (flip the
  /// sign bit) so pre-1970 timestamps cannot sort above everything.
  ///
  /// `tieBreak` is the first eight bytes of the message id, big-endian and zero
  /// padded — **not** a hash. The core's total order is `ts_ms ASC, message_id
  /// ASC`, and a hash would order same-millisecond messages arbitrarily, which
  /// the snapshot validator would then correctly reject as non-ascending. This
  /// preserves lexicographic order for the first eight bytes; ids sharing a
  /// longer prefix tie, which is harmless because the array order still comes
  /// from the core.
  static func key(tsMs: Int64, messageId: String) -> VibeOrderKey {
    let rank = UInt64(bitPattern: tsMs) ^ (1 << 63)
    var tie: UInt64 = 0
    for byte in messageId.utf8.prefix(8) { tie = (tie << 8) | UInt64(byte) }
    let shortfall = 8 - min(8, messageId.utf8.count)
    tie <<= UInt64(shortfall * 8)
    return VibeOrderKey(rank: rank, tieBreak: tie)
  }
}

// MARK: - Render item factory

/// Turns a core message into a render item, using frozen geometry.
@MainActor
struct VibeRenderItemFactory {
  let cache: VibeRowMeasurementCache

  /// A row as it should look when nothing is changing.
  func settledItem(_ message: VibeFfiMessage) -> VibeRenderItem {
    let geometry = cache.settledGeometry(for: message)
    return item(message, geometry: geometry, contentRevision: message.contentHash)
  }

  /// A row after a content-only change: **the frozen size is reused**.
  ///
  /// This is the contract enforced by construction. There is no code path here
  /// that measures on a content-only op, so no amount of later carelessness can
  /// make a receipt move a bubble.
  func contentUpdatedItem(_ message: VibeFfiMessage) -> VibeRenderItem {
    let geometry = cache.cached(message.messageId) ?? cache.settledGeometry(for: message)
    return item(message, geometry: geometry, contentRevision: message.contentHash)
  }

  /// A row after a geometry-relevant change: re-measured, revision bumped.
  func geometryUpdatedItem(_ message: VibeFfiMessage) -> (VibeRenderItem, CGFloat) {
    let before = cache.cached(message.messageId)?.size.height ?? 0
    let geometry = cache.remeasure(message)
    let updated = item(message, geometry: geometry, contentRevision: message.contentHash)
    return (updated, geometry.size.height - before)
  }

  private func item(
    _ message: VibeFfiMessage, geometry: VibeMeasuredRow, contentRevision: UInt64
  ) -> VibeRenderItem {
    var flags: VibeRenderItemFlags = []
    // `VibeMessageFlags` bit 1 is streaming; see `vibe_core::types`. A streaming
    // row is explicitly not settled, which is what lets it grow.
    let isStreaming = (message.flags & (1 << 1)) != 0
    if isStreaming {
      flags.insert(.streaming)
    } else {
      flags.insert(.settled)
    }
    if message.hasMedia { flags.insert(.provisionalMedia) }

    return VibeRenderItem(
      identity: VibeTimelineAnchor(
        messageId: message.messageId, identityGeneration: geometry.revision),
      orderKey: VibeTimelineOrderKeyFactory.key(
        tsMs: message.tsMs, messageId: message.messageId),
      kind: renderKind(message),
      contentRevision: contentRevision,
      geometryRevision: geometry.revision,
      size: geometry.size,
      layout: geometry.layout,
      paint: VibePaintSpec(
        backgroundToken: message.authorIsMe ? "bubble.outgoing" : "bubble.incoming",
        textStyleToken: message.authorIsMe ? "text.body.outgoing" : "text.body"
      ),
      mediaSlots: message.hasMedia
        ? [
          VibeMediaSlot(
            frame: geometry.layout.mediaBoxFrame,
            aspectRatio: 0,
            placeholderToken: nil,
            loadKey: message.messageId
          )
        ] : [],
      interaction: VibeInteractionSpec(
        accessibilityLabel: message.text.isEmpty ? (message.caption ?? "") : message.text
      ),
      flags: flags
    )
  }

  private func renderKind(_ message: VibeFfiMessage) -> VibeRenderItemKind {
    if message.hasService { return .service }
    if message.hasAgent { return .agentTurn }
    return .message
  }
}

// MARK: - Body sink

/// Optional companion to ``VibeMessageListHost`` for hosts that paint text.
///
/// `VibeRenderItem` deliberately carries geometry and theme *tokens* and no
/// message bodies, so that a render item can be logged, diffed, or compared in
/// shadow mode without leaking plaintext. Painting still needs the text, so it
/// travels on a separate, explicitly-named channel rather than being smuggled
/// into the render contract.
@MainActor
protocol VibeMessageListBodySink: AnyObject {
  func setBodies(_ bodies: [String: String], details: [String: String])
}

/// Optional companion for hosts that outlive the engine driving them.
///
/// A generation fence is only meaningful within one engine's lifetime. When the
/// engine is replaced — logout, chat switch, a `reset` — the new one starts its
/// generations from zero while a long-lived host is still holding the old one's
/// high-water mark, so every transaction from the replacement is fenced off as
/// stale. The host keeps showing the dead engine's rows until a full mount
/// happens to arrive.
///
/// Nothing about a transaction distinguishes "arrived out of order" from "came
/// from a different engine", so the fence cannot infer this. It has to be told.
@MainActor
protocol VibeMessageListEngineLifecycle: AnyObject {
  /// Drops all rows and generation state. The next mount starts clean.
  func detachFromEngine()
}

// MARK: - VibeTimelineHost

/// Drives a ``VibeMessageListHost`` from the Rust core.
///
/// # Where the split falls
///
/// | Concern | Owner |
/// |---|---|
/// | order, dedup, windowing, what changed | Rust core |
/// | *is this change allowed to move the row* | Rust core (`VibeChangeMask`) |
/// | how tall the row is | **this file, in Swift** |
/// | where the scroll offset goes afterwards | the list host |
///
/// The core never learns about points, fonts, or the screen. This class never
/// decides what order rows go in. That boundary is the whole design.
///
/// # Threading
///
/// Core callbacks arrive on the Rust worker thread. Everything here is
/// `@MainActor`; the sink hops before touching any of it. Transactions are
/// funnelled through ``VibeListDisplayLinkCommitter`` so a burst of deltas
/// becomes at most one commit per frame (§5.5).
@MainActor
final class VibeTimelineHost {
  private let chatId: String
  private let listHost: VibeMessageListHost
  private let committer = VibeListDisplayLinkCommitter()
  private let cache = VibeRowMeasurementCache()
  private let factory: VibeRenderItemFactory

  /// Mirror of the applied window, oldest → newest. The core owns truth; this is
  /// only what has actually been committed to the list.
  private var applied: [VibeRenderItem] = []
  private var generation: UInt64 = 0
  private var themeEpoch: UInt64 = 0

  /// Row text, kept out of `VibeRenderItem` on purpose. See ``VibeMessageListBodySink``.
  private var bodies: [String: String] = [:]
  private var details: [String: String] = [:]

  /// A window that arrived before the list knew how wide it was.
  ///
  /// Held rather than dropped: measuring against a placeholder width and
  /// correcting later is precisely the shift this stack exists to remove, so the
  /// mount waits for a real width instead of guessing at one.
  private var pendingMountWindow: VibeFfiWindow?
  private var pendingMountReason: VibeMountReason = .engineReconcile

  /// Set when a delta could not be applied and the core must be re-queried.
  /// The owner drives the resync — this class has no handle to ask with.
  var onNeedsResync: (() -> Void)?

  /// True between asking for a window and mounting one. Keeps a burst from
  /// queueing one full-window request per delta.
  private var resyncOutstanding = false

  /// Counters for the qualification gates in §9.1. Ids and numbers only.
  private(set) var appliedTransactions = 0
  private(set) var rejectedTransactions = 0
  private(set) var settledGeometryChanges = 0

  var onDiagnostic: ((String, [String: String]) -> Void)?

  init(chatId: String, listHost: VibeMessageListHost) {
    self.chatId = chatId
    self.listHost = listHost
    self.factory = VibeRenderItemFactory(cache: cache)
    committer.onCommit = { [weak self] transaction in
      guard let self else { return }
      self.pushBodies()
      self.listHost.apply(transaction: transaction)
      self.appliedTransactions += 1
    }
  }

  deinit {
    // `committer` is main-actor isolated and cannot be invalidated from deinit.
    // `invalidate()` is called from `shutdown()`; the proxy holds no strong
    // reference back, so a missed call leaks a paused display link at worst.
  }

  func shutdown() {
    committer.cancelPending()
    committer.invalidate()
    // The list may well outlive this adapter — it does in the preview, and it
    // will in production, where the view is reused across chats. Leaving it
    // holding this engine's generation high-water mark fences off everything the
    // next engine sends.
    (listHost as? VibeMessageListEngineLifecycle)?.detachFromEngine()
    applied.removeAll()
    bodies.removeAll()
    details.removeAll()
    cache.forgetAll()
    pendingMountWindow = nil
    resyncOutstanding = false
    generation = 0
  }

  /// Sets the layout environment. Returns true when everything must be re-measured.
  @discardableResult
  func setEnvironment(
    width: CGFloat,
    contentSizeCategory: UIContentSizeCategory = UIApplication.shared.preferredContentSizeCategory,
    themeEpoch: UInt64 = 0
  ) -> Bool {
    self.themeEpoch = themeEpoch
    let changed = cache.setEnvironment(
      width: width, contentSizeCategory: contentSizeCategory, themeEpoch: themeEpoch)
    guard changed else { return false }

    // A window that was waiting on a width can now be measured correctly the
    // first time, which is the whole point of having waited.
    if let pending = pendingMountWindow, width > 0 {
      mount(window: pending, reason: pendingMountReason)
      return true
    }
    // Everything already on screen was measured against the old environment and
    // must be re-derived. §5.4: one new snapshot and one preserve, not per-row
    // thrash — so ask the owner for a fresh window rather than re-measuring
    // piecemeal from a mirror that may already be stale.
    if !applied.isEmpty { onNeedsResync?() }
    return true
  }

  var measurementStats: (measured: Int, reused: Int, invalidations: Int) {
    (cache.measurements, cache.reuses, cache.invalidations)
  }

  // MARK: Mount

  /// Mounts a full window. Used for first paint, reopen, and trait changes.
  func mount(window: VibeFfiWindow, reason: VibeMountReason) {
    guard cache.layoutWidth > 0 else {
      pendingMountWindow = window
      pendingMountReason = reason
      onDiagnostic?("mount deferred: no layout width", ["chat": chatId])
      return
    }
    pendingMountWindow = nil
    resyncOutstanding = false
    // Anything already queued describes a window that is about to be replaced.
    // Committing it after the mount would apply stale ops to fresh state.
    committer.cancelPending()

    let items = window.messages.map { factory.settledItem($0) }
    for message in window.messages { recordBody(message) }
    generation = window.generation
    applied = items

    let snapshot = VibeRenderSnapshot(
      chatId: chatId,
      generation: generation,
      window: VibeTimelineWindowV1(
        chatId: chatId,
        messageIds: items.map(\.identity.messageId),
        anchors: items.map(\.identity),
        startIndex: 0,
        hasOlder: window.bounds.hasMoreBefore,
        hasNewer: window.bounds.hasMoreAfter
      ),
      items: items,
      anchor: .pinToBottom,
      contentHeight: items.reduce(0) { $0 + $1.size.height },
      themeEpoch: themeEpoch,
      direction: UIView.userInterfaceLayoutDirection(for: .unspecified) == .rightToLeft
        ? .rtl : .ltr,
      preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory.rawValue
    )

    // Validate before mounting, not after. A snapshot that violates the contract
    // is a bug in this file, and mounting it first would turn a diagnosable
    // assertion into a visual glitch someone has to reproduce.
    if case .failure(let failure) = VibeRenderSnapshotValidator.validate(snapshot) {
      rejectedTransactions += 1
      onDiagnostic?(
        "snapshot rejected", ["chat": chatId, "failure": String(describing: failure)])
      return
    }
    pushBodies()
    listHost.apply(snapshot: snapshot, reason: reason)
  }

  private func recordBody(_ message: VibeFfiMessage) {
    bodies[message.messageId] = message.text.isEmpty ? (message.caption ?? "") : message.text
    details[message.messageId] = "\(message.messageId) · ts \(message.tsMs)"
  }

  private func pushBodies() {
    (listHost as? VibeMessageListBodySink)?.setBodies(bodies, details: details)
  }

  // MARK: Deltas

  /// Converts one core delta into a list transaction and queues it.
  func ingest(delta: VibeFfiDelta) {
    switch delta.body {
    case .reset(let window):
      // A reset is not expressible as ops against the current window, and
      // pending ops describe a window that no longer exists.
      committer.cancelPending()
      mount(window: window, reason: .engineReconcile)

    case .ops(let ops):
      guard !ops.isEmpty else { return }
      // Nothing has been measured yet, so ops have no state to apply against.
      // Dropping them is safe because the deferred mount carries the same rows.
      guard cache.layoutWidth > 0 else { return }
      // Behind us: this delta is already folded into the window we mounted.
      // Dropping it is not a resync condition — a requested window is a
      // point-in-time snapshot, so every delta the core emitted before that
      // point arrives late and redundant by construction.
      if delta.baseGeneration < generation { return }

      // The generation fence, honoured rather than assumed. Op indices are
      // relative to the core's window at `baseGeneration`; applying them to a
      // different window puts rows at the wrong index, which shows up as a
      // visibly wrong order. The contract says resync, so resync.
      guard delta.baseGeneration == generation else {
        // ...but resync *once*. A window request is served asynchronously while
        // the core keeps producing, so the snapshot is already behind again by
        // the time it lands. Requesting one per delta turned a 250-message burst
        // into 687 full re-renders, each of which arrived stale and asked for
        // another. One outstanding request, cleared when a window mounts, makes
        // that converge instead of chasing its own tail.
        guard !resyncOutstanding else { return }
        resyncOutstanding = true
        rejectedTransactions += 1
        onDiagnostic?(
          "delta ahead of mounted window — resyncing once",
          ["base": String(delta.baseGeneration), "held": String(generation)])
        committer.cancelPending()
        onNeedsResync?()
        return
      }
      guard let transaction = transaction(from: ops, delta: delta) else { return }
      committer.enqueue(transaction)
    }
  }

  private func transaction(from ops: [VibeFfiOp], delta: VibeFfiDelta) -> VibeListTransaction? {
    var listOps: [VibeListOp] = []
    var next = applied
    var sawGeometryChange = false

    for op in ops {
      switch op {
      case .insert(let index, let message):
        recordBody(message)
        let item = factory.settledItem(message)
        let at = Int(index)
        guard at >= 0, at <= next.count else {
          onDiagnostic?("insert index out of range", ["index": String(index)])
          return nil
        }
        next.insert(item, at: at)
        listOps.append(.insert(items: [item], at: at))

      case .remove(_, let messageId):
        next.removeAll { $0.identity.messageId == messageId }
        cache.forget(messageId)
        bodies.removeValue(forKey: messageId)
        details.removeValue(forKey: messageId)
        listOps.append(.remove(ids: [messageId]))

      case .remapIdentity(let index, let previousMessageId, let message):
        // An optimistic send getting its server id. Remove-then-insert would
        // animate the user's own message away and back; the scroll anchor is
        // supposed to survive this, so the geometry is carried across.
        if let old = cache.cached(previousMessageId) {
          cache.forget(previousMessageId)
          _ = old
        }
        recordBody(message)
        bodies.removeValue(forKey: previousMessageId)
        details.removeValue(forKey: previousMessageId)
        let item = factory.settledItem(message)
        let at = Int(index)
        if at >= 0, at < next.count {
          next[at] = item
        }
        listOps.append(.remove(ids: [previousMessageId]))
        listOps.append(.insert(items: [item], at: min(max(at, 0), next.count - 1)))

      case .updateContent(let index, let message, _):
        recordBody(message)
        let item = factory.contentUpdatedItem(message)
        let at = Int(index)
        if at >= 0, at < next.count {
          // Belt and braces: the factory reuses frozen geometry, and this
          // catches it if that ever stops being true.
          if next[at].flags.locksGeometry, next[at].size != item.size {
            settledGeometryChanges += 1
            onDiagnostic?(
              "settled geometry changed on content op",
              ["id": message.messageId, "was": "\(next[at].size.height)",
               "now": "\(item.size.height)"])
          }
          next[at] = item
        }
        listOps.append(.updateContent(id: message.messageId, item: item))

      case .updateGeometry(let index, let message, _):
        recordBody(message)
        let (item, deltaHeight) = factory.geometryUpdatedItem(message)
        let at = Int(index)
        if at >= 0, at < next.count { next[at] = item }
        sawGeometryChange = true
        listOps.append(
          .updateGeometry(id: message.messageId, item: item, deltaHeight: deltaHeight))

      case .move(let from, let to, let messageId):
        let f = Int(from)
        let t = Int(to)
        guard f >= 0, f < next.count, t >= 0, t < next.count else { return nil }
        let moved = next.remove(at: f)
        next.insert(moved, at: t)
        listOps.append(.move(id: messageId, to: t))

      case .evictHead(let count):
        // A window trim, not a deletion. Kept as a plain remove of the head ids
        // with `.none` animation — collapsing a trim into an animated delete is
        // exactly the bug §5.4 calls out.
        let n = min(Int(count), next.count)
        guard n > 0 else { break }
        let ids = next.prefix(n).map(\.identity.messageId)
        next.removeFirst(n)
        for id in ids { cache.forget(id); bodies[id] = nil; details[id] = nil }
        listOps.append(.remove(ids: ids))

      case .evictTail(let count):
        let n = min(Int(count), next.count)
        guard n > 0 else { break }
        let ids = next.suffix(n).map(\.identity.messageId)
        next.removeLast(n)
        for id in ids { cache.forget(id); bodies[id] = nil; details[id] = nil }
        listOps.append(.remove(ids: ids))
      }
    }

    guard !listOps.isEmpty else { return nil }

    let base = generation
    // The core's generation verbatim. Inventing one (`max(generation + 1, …)`)
    // makes every subsequent fence check compare against a number the core never
    // issued, which silently disables the fence.
    generation = delta.generation
    guard generation > base else {
      onDiagnostic?(
        "delta did not advance the generation",
        ["base": String(base), "next": String(delta.generation)])
      generation = base
      return nil
    }
    applied = next

    return VibeListTransaction(
      baseGeneration: base,
      nextGeneration: generation,
      ops: listOps,
      // Bottom pinning is the shipped behaviour for live traffic. A geometry
      // change mid-window needs the item anchor instead, which the host resolves
      // from its own visible range — it knows what is on screen and this does not.
      preserve: .pinToBottom,
      animation: sawGeometryChange ? .heightMorph : .none,
      commitDeadline: .displayLink
    )
  }
}
