import CoreGraphics
import UIKit

/// P4-D — `ChatListView` as a renderer the timeline core can drive.
///
/// # Why this is an extension and not a new screen
///
/// A parallel `VibeCoreChatViewController` was built on 2026-08-03 and deleted the same
/// day. It compiled and routed and rendered an empty transcript, because engine rows are
/// **nested** — the timestamp is at `row["message"]["timestampMs"]`, not at the top
/// level — so a re-derived feed read `nil` for every row and skipped all of them. One
/// small re-derived piece, wrong within the hour.
///
/// The header, wallpaper, theme handling, share sheets, send morph, cell-removal
/// animation and edge masks are far more intricate than that feed and are all already
/// tuned. Re-deriving them yields twenty of the same bug, each in code that was paid for
/// once already. So the engine gets replaced *where it lives*.
///
/// `collectionView` is a `let` on `ChatListView`, referenced 449 times, and it does not
/// move. Every mask, gesture, overlay and animation bound to it keeps working **by
/// construction** rather than by re-implementation.
///
/// # What this file is allowed to change
///
/// Which rows exist, in what order, and how tall each one is. Nothing else. Appearance
/// and every other system stay exactly as they are — that is a hard constraint from the
/// product owner, and it is the reason this approach was chosen over copying the chrome
/// into a new file.
///
/// # Staging
///
/// This is step one and it is deliberately inert: the core's answer is **recorded**, not
/// rendered. `frozenGeometry` is populated and reported, and `sizeForItemAt` still
/// decides heights the way it does today. That makes the seam verifiable on a device
/// before it is load-bearing — the log can show the core and the list agreeing on every
/// row of a real conversation while the user sees exactly the build they had.
///
/// Step two flips `sizeForItemAt` to read `frozenGeometry` behind the gate, at which
/// point heights are *told* rather than derived and the post-hoc height movers have
/// nothing left to correct.

/// The core's opinion about this list, held beside the view.
///
/// An extension cannot add stored properties, and putting these on `ChatListView` itself
/// would mean editing the one file this migration is trying not to churn. One associated
/// object, one class, released with the view.
final class VibeCoreEngineState {
  var generation: UInt64 = 0
  /// Message ids oldest → newest, exactly as the core ordered them.
  var orderedMessageIds: [String] = []
  /// Frozen row height per message id. Measured once, never re-derived.
  var frozenGeometry: [String: CGFloat] = [:]
  /// Rows whose height changed while settled. §9.1 requires this to be 0.
  var settledGeometryChanges = 0
  /// The core, or `nil` when a gate said no. Built once per chat.
  var driver: VibeCoreListDriver?
  /// Eligibility is resolved once per chat, not once per row batch — a gate that could
  /// change mid-chat would swap the sizing authority under a reader.
  var eligibilityChecked = false
  /// Width the core was last told to measure against.
  var layoutWidth: CGFloat = 0
}

extension ChatListView: VibeMessageListHost {

  private static var coreStateKey: UInt8 = 0

  /// Lazily attached, so a list that never meets the core pays nothing.
  var coreState: VibeCoreEngineState {
    if let existing = objc_getAssociatedObject(self, &Self.coreStateKey)
      as? VibeCoreEngineState
    {
      return existing
    }
    let created = VibeCoreEngineState()
    objc_setAssociatedObject(
      self, &Self.coreStateKey, created, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return created
  }

  /// `engineChatId` is `private` and therefore invisible from this file. `surfaceId` is
  /// the public mirror of it (`"<chatId>#list"`), and for a log label that is enough —
  /// reaching into the other file to widen an access modifier would be churn for a
  /// diagnostic.
  private var coreChatLabel: String {
    String(surfaceId.split(separator: "#").first.map(String.init)?.prefix(12) ?? "?")
  }

  var view: UIView { self }

  // MARK: Lifecycle

  /// Hands the core the window this list is about to render.
  ///
  /// **This is the entire call site.** One line inside `setRows`, taking the values it
  /// already has in hand, so the 23,091-line file gains a single statement rather than a
  /// migration. `chatId` and `isGroupOrChannel` are passed in rather than read off the
  /// view because both live in `private` storage that another file cannot see — and
  /// widening an access modifier to suit a caller is how a boundary stops being one.
  ///
  /// Safe to call on every batch: eligibility is resolved once, the driver dedups rows
  /// it has already ingested, and an identical re-emitted window asks the core nothing.
  func feedCoreEngine(chatId: String, isGroupOrChannel: Bool, rows sourceRows: [[String: Any]]) {
    if !coreState.eligibilityChecked {
      coreState.eligibilityChecked = true
      coreState.driver = Self.makeCoreDriverIfEligible(
        chatId: chatId, isGroupOrChannel: isGroupOrChannel, listHost: self)
      coreState.driver?.start { [weak self] messageId in
        guard let self else { return nil }
        return self.rows.first { $0.messageId == messageId || $0.key == messageId }
      }
    }
    guard let driver = coreState.driver else { return }
    // The width rows are measured against, from the same expression the sizing path
    // uses. A core measuring against a width the cells never use produces heights that
    // are wrong rather than missing, which is strictly worse than having none.
    let width = max(0, bounds.width - (messageHorizontalInset * 2))
    if width > 0, abs(coreState.layoutWidth - width) > 0.5 {
      coreState.layoutWidth = width
      driver.setLayoutWidth(width)
    }
    driver.observe(rows: sourceRows)
  }

  /// Tears the core down. Called when the chat changes or the view goes away — a driver
  /// left holding the previous chat's generation high-water mark fences off everything
  /// the next one sends.
  func shutdownCoreEngine() {
    coreState.driver?.shutdown()
    coreState.driver = nil
    coreState.eligibilityChecked = false
    coreState.generation = 0
    coreState.orderedMessageIds.removeAll()
    coreState.frozenGeometry.removeAll()
    coreState.layoutWidth = 0
  }

  /// Builds a driver only when every gate agrees, otherwise `nil`.
  ///
  /// Fails closed on every input. Kept here, next to the thing it governs, so the rule
  /// that P4 is **1:1 DM only** is written once rather than being a condition someone can
  /// widen in passing at a call site.
  ///
  /// Saved Messages is named explicitly because it slipped through a DM-only allowlist
  /// once already: it answers `false` to `isGroupOrChannel`, and its dual-id history is
  /// exactly the kind of ordering quirk that earns its own soak.
  static func makeCoreDriverIfEligible(
    chatId: String,
    isGroupOrChannel: Bool,
    listHost: VibeMessageListHost,
    flags: VibeTimelineFeatureFlags = VibeTimelineUserDefaultsFeatureFlags().flags
  ) -> VibeCoreListDriver? {
    guard flags.vibeAsyncTimelineV1Enabled else { return nil }
    guard flags.eligibleChatClasses.contains(.directMessage) else { return nil }
    guard !isGroupOrChannel else { return nil }
    let trimmed = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("saved_messages") else { return nil }
    NSLog("[VibeCore] driver ARMED chat=%@", String(trimmed.prefix(12)))
    return VibeCoreListDriver(chatId: trimmed, listHost: listHost)
  }

  // MARK: Mount

  /// Records the core's window: which rows, in what order, how tall.
  ///
  /// Does not touch `rows`, the collection view, or the scroll position. The engine's
  /// own `setRows` pipeline still owns what is on screen — this is the measurement that
  /// proves the two agree before anything depends on it.
  func apply(snapshot: VibeRenderSnapshot, reason: VibeMountReason) {
    coreState.generation = snapshot.generation
    coreState.orderedMessageIds = snapshot.items.map(\.identity.messageId)
    var geometry: [String: CGFloat] = [:]
    geometry.reserveCapacity(snapshot.items.count)
    for item in snapshot.items { geometry[item.identity.messageId] = item.size.height }
    coreState.frozenGeometry = geometry
    NSLog(
      "[VibeCore] host MOUNT chat=%@ reason=%@ gen=%llu rows=%d (recorded, not rendered)",
      coreChatLabel, reason.rawValue, snapshot.generation,
      snapshot.items.count)
    reportCoreGeometryAgreement(stage: "mount")
  }

  /// Applies an ordered, atomic mutation from the core.
  ///
  /// Every op is folded into the recorded window so the mirror stays exactly what the
  /// core believes. Applying a partial op set and letting the rest drift is how a list
  /// ends up rendering an order nobody chose.
  func apply(transaction: VibeListTransaction) {
    guard transaction.baseGeneration == coreState.generation else {
      NSLog(
        "[VibeCore] host TRANSACTION-FENCED chat=%@ base=%llu held=%llu — resync owed",
        coreChatLabel, transaction.baseGeneration, coreState.generation)
      return
    }
    for op in transaction.ops {
      switch op {
      case .insert(let items, let at):
        let ids = items.map(\.identity.messageId)
        let index = min(max(at, 0), coreState.orderedMessageIds.count)
        coreState.orderedMessageIds.insert(contentsOf: ids, at: index)
        for item in items { coreState.frozenGeometry[item.identity.messageId] = item.size.height }
      case .remove(let ids):
        let dropped = Set(ids)
        coreState.orderedMessageIds.removeAll { dropped.contains($0) }
        for id in ids { coreState.frozenGeometry.removeValue(forKey: id) }
      case .updateContent(let id, let item):
        // Content-only ops must never move geometry. If one does, the freeze is broken
        // and the row is about to change height under a reader — record it loudly
        // rather than quietly adopting the new number.
        if let held = coreState.frozenGeometry[id], abs(held - item.size.height) > 0.5 {
          coreState.settledGeometryChanges += 1
          NSLog(
            "[VibeCore] host SETTLED-GEOMETRY-CHANGED chat=%@ id=%@ %.1f→%.1f",
            coreChatLabel, String(id.suffix(14)), held, item.size.height)
        }
      case .updateGeometry(let id, let item, _):
        coreState.frozenGeometry[id] = item.size.height
      case .move(let id, let to):
        guard let from = coreState.orderedMessageIds.firstIndex(of: id) else { break }
        let moved = coreState.orderedMessageIds.remove(at: from)
        coreState.orderedMessageIds.insert(moved, at: min(max(to, 0), coreState.orderedMessageIds.count))
      }
    }
    coreState.generation = transaction.nextGeneration
    reportCoreGeometryAgreement(stage: "transaction")
  }

  // MARK: Viewport

  /// The keyboard, composer and safe-area clearance the scrollable area must leave.
  ///
  /// Routed into `contentPaddingBottom`/`contentPaddingTop` — the flow layout's SECTION
  /// insets — because that is where this list has always put them. They are part of
  /// `contentSize`, not `contentInset`; a guard that read `adjustedContentInset.bottom`
  /// instead is what let keyboard-up rasters be cached for months.
  func setViewportInsets(_ insets: UIEdgeInsets) {
    setContentPaddingTop(insets.top)
    setContentPaddingBottom(insets.bottom)
  }

  func visibleAnchors() -> [VibeTimelineAnchor] {
    collectionView.indexPathsForVisibleItems
      .sorted { $0.item < $1.item }
      .compactMap { path in
        guard rows.indices.contains(path.item), let id = rows[path.item].messageId else {
          return nil
        }
        return VibeTimelineAnchor(messageId: id)
      }
  }

  // MARK: Navigation

  func prepareForNavigationPush(bounds: CGRect, safeBottom: CGFloat) {
    setNavigationPrestageSafeAreaBottom(safeBottom)
    beginNavigationPushPrestaging()
  }

  func completePresentation() {
    completeTranscriptPresentation()
  }

  /// Not implemented, and deliberately not stubbed as "done".
  ///
  /// This list does not prefetch: `isPrefetchingEnabled` is off on the core host for the
  /// same reason it should stay off here — prefetch instantiates cells on its own
  /// schedule, which fights an explicit "visible plus two screens" budget. A budget is
  /// measurable; a heuristic is not.
  func cancelPrefetch(outside range: Range<Int>) {}

  func debugGeometryMap() -> [String: CGFloat] { coreState.frozenGeometry }

  // MARK: Agreement

  /// Compares the core's height for each row against the one this list actually used.
  ///
  /// This is the whole point of landing the seam inert first. Before `sizeForItemAt`
  /// depends on the core, the log has to show the two agreeing on real conversations —
  /// on real media, real agent turns, real edits. A disagreement here is a row that
  /// *would* have jumped, caught while it still costs nothing.
  ///
  /// Ids and numbers only, and only the disagreements: a line per agreeing row would
  /// bury the one line that matters, which this project has already done to itself
  /// three times.
  private func reportCoreGeometryAgreement(stage: String) {
    guard !coreState.frozenGeometry.isEmpty, !rows.isEmpty else { return }
    var compared = 0
    var differed = 0
    var worst: (key: String, core: CGFloat, list: CGFloat)?
    let layout = collectionView.collectionViewLayout
    for (index, row) in rows.enumerated() {
      guard let id = row.messageId, let core = coreState.frozenGeometry[id] else { continue }
      // The height the list actually laid the row out at, not the height it cached.
      // `messageHeightCache` is `private` and invisible here, which turns out to be the
      // better answer: the laid-out attribute is what the reader saw, and a cache that
      // agrees with the core while the layout disagrees with both is exactly the class
      // of bug this comparison exists to catch.
      guard
        let list = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?
          .size.height
      else { continue }
      compared += 1
      let delta = abs(core - list)
      guard delta > 0.5 else { continue }
      differed += 1
      if delta > abs((worst?.core ?? 0) - (worst?.list ?? 0)) {
        worst = (row.key, core, list)
      }
    }
    guard compared > 0 else { return }
    if differed == 0 {
      NSLog(
        "[VibeCore] geometry AGREES chat=%@ stage=%@ rows=%d",
        coreChatLabel, stage, compared)
      return
    }
    NSLog(
      "[VibeCore] geometry DIFFERS chat=%@ stage=%@ rows=%d differed=%d worst=%@ core=%.1f list=%.1f",
      coreChatLabel, stage, compared, differed,
      String(worst?.key.suffix(14) ?? "?"), worst?.core ?? 0, worst?.list ?? 0)
  }
}
