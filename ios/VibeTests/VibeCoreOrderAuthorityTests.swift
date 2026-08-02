import Foundation
import XCTest

@testable import Vibe

/// Tests for the one piece of core logic that can reach a user's screen.
///
/// `VibeTimelineShadowProbe.reorder` decides whether the Rust core is allowed to
/// permute the production chat list. Everything else in that type is a
/// diagnostic whose worst failure is a log line; this one can put a message in
/// the wrong place, which is the most visible bug this app could ship.
///
/// So the tests are mostly about the **refusals**. A reorder that happens when it
/// should not is worse than one that never happens: the fallback is the engine's
/// own ordering, which is what ships today and works.
final class VibeCoreOrderAuthorityTests: XCTestCase {

  private func row(_ id: String, ts: Int64 = 0) -> [String: Any] {
    ["messageId": id, "timestamp": ts, "content": "body of \(id)"]
  }

  private func ids(_ rows: [[String: Any]]?) -> [String]? {
    rows?.compactMap { $0["messageId"] as? String }
  }

  // MARK: It reorders when it should

  func testItReordersTheTailToMatchTheCore() {
    let rows = [row("a"), row("b"), row("c")]
    let reordered = VibeTimelineShadowProbe.reorder(rows: rows, toMatch: ["a", "c", "b"])
    XCTAssertEqual(ids(reordered), ["a", "c", "b"])
  }

  func testHistoryTheCoreHasEvictedKeepsItsPlace() {
    // The core's window caps at 200 and evicts from the head, so it has no
    // opinion about older history. Those rows must keep both their order and
    // their position — the core may only speak about its own suffix.
    let rows = [row("old1"), row("old2"), row("a"), row("b")]
    let reordered = VibeTimelineShadowProbe.reorder(rows: rows, toMatch: ["b", "a"])
    XCTAssertEqual(ids(reordered), ["old1", "old2", "b", "a"])
  }

  func testTheRowPayloadTravelsWithTheReorder() {
    // A reorder must move the whole row, not just its id — dropping the payload
    // here would blank every message it touched.
    let rows = [row("a"), row("b")]
    let reordered = VibeTimelineShadowProbe.reorder(rows: rows, toMatch: ["b", "a"])
    XCTAssertEqual(reordered?.first?["content"] as? String, "body of b")
    XCTAssertEqual(reordered?.count, 2)
  }

  // MARK: It refuses when it should

  func testAgreementReturnsNilSoTheCallerKeepsItsArray() {
    // The expected case. Rebuilding an identical array would cost a diff pass
    // and a reload for nothing.
    let rows = [row("a"), row("b"), row("c")]
    XCTAssertNil(VibeTimelineShadowProbe.reorder(rows: rows, toMatch: ["a", "b", "c"]))
  }

  func testAnEmptyCoreWindowNeverReorders() {
    XCTAssertNil(VibeTimelineShadowProbe.reorder(rows: [row("a")], toMatch: []))
    XCTAssertNil(VibeTimelineShadowProbe.reorder(rows: [], toMatch: ["a"]))
  }

  func testARowWithoutAnIdRefusesTheWholeBatch() {
    // Reordering around a row we cannot name means inventing a position for it.
    let rows: [[String: Any]] = [row("a"), ["content": "no id here"], row("b")]
    XCTAssertNil(VibeTimelineShadowProbe.reorder(rows: rows, toMatch: ["b", "a"]))
  }

  func testDuplicateIdsRefuseTheWholeBatch() {
    // The governed-suffix index is an index into the de-duplicated id array and
    // is used to slice `rows`. A duplicate makes those two diverge, and the
    // reorder would drop or misplace a real message rather than fail loudly.
    let rows = [row("a"), row("b"), row("a")]
    XCTAssertNil(VibeTimelineShadowProbe.reorder(rows: rows, toMatch: ["b", "a"]))
  }

  func testAnInterleavedTranscriptRefuses() {
    // The core knows a and c but not b, and b sits between them. Honouring the
    // core here would move b relative to rows the core cannot see — the two are
    // describing different transcripts.
    let rows = [row("a"), row("b"), row("c")]
    XCTAssertNil(VibeTimelineShadowProbe.reorder(rows: rows, toMatch: ["c", "a"]))
  }

  func testASingleGovernedRowIsNotWorthReordering() {
    // One row cannot be out of order with respect to itself, and accepting a
    // one-element window would let a nearly-empty core claim authority over a
    // full list.
    let rows = [row("a"), row("b")]
    XCTAssertNil(VibeTimelineShadowProbe.reorder(rows: rows, toMatch: ["b"]))
  }

  func testIdsTheEngineNoLongerHasAreIgnoredRatherThanResurrected() {
    // The core still holds a message the engine has dropped (deleted, retired
    // id). It must not come back on screen.
    let rows = [row("a"), row("b")]
    let reordered = VibeTimelineShadowProbe.reorder(rows: rows, toMatch: ["b", "gone", "a"])
    XCTAssertEqual(ids(reordered), ["b", "a"])
    XCTAssertFalse(ids(reordered)?.contains("gone") ?? true)
  }

  // MARK: Nothing is lost

  func testAReorderIsAlwaysAPermutation() {
    // The property that matters most: whatever comes back must hold exactly the
    // rows that went in. Anything else means the list silently lost a message.
    let rows = (1...12).map { row("m\($0)", ts: Int64($0)) }
    let shuffled = ["m12", "m11", "m10", "m9", "m8", "m7", "m6", "m5", "m4", "m3", "m2", "m1"]
    guard let reordered = VibeTimelineShadowProbe.reorder(rows: rows, toMatch: shuffled) else {
      return XCTFail("expected a reorder")
    }
    XCTAssertEqual(reordered.count, rows.count)
    XCTAssertEqual(Set(ids(reordered) ?? []), Set(ids(rows) ?? []))
  }

  // MARK: The gate

  func testOrderAuthorityIsOffByDefaultEvenInDebug() {
    let defaults = UserDefaults(suiteName: "order-authority-\(UUID().uuidString)")!
    let flags = VibeTimelineUserDefaultsFeatureFlags(defaults: defaults).flags
    // Shadow comparison arms itself in debug because it renders nothing. This
    // one reaches the screen, so it never defaults on anywhere.
    XCTAssertFalse(flags.vibeTimelineCoreOrderAuthorityEnabled)
  }
}

/// Eligibility, verified against what a device run actually did.
@MainActor
final class VibeShadowProbeEligibilityTests: XCTestCase {

  private func flags(_ classes: VibeTimelineChatClassEligibility) -> VibeTimelineFeatureFlags {
    VibeTimelineFeatureFlags(
      vibeTimelineShadowCompareEnabled: true, shadowEligibleChatClasses: classes)
  }

  func testSavedMessagesIsNotADirectMessage() {
    // A device run caught this: `saved_messages` answers false to
    // `isGroupOrChannel`, so it armed under a DM-only allowlist. It has its own
    // dual-id ordering history and deserves its own soak.
    XCTAssertNil(
      VibeTimelineShadowProbe.makeIfEligible(
        chatId: "saved_messages", isGroupOrChannel: false, flags: flags(.directMessage)))

    XCTAssertNotNil(
      VibeTimelineShadowProbe.makeIfEligible(
        chatId: "saved_messages", isGroupOrChannel: false, flags: flags(.savedMessages)))
  }

  func testAnOrdinaryDirectMessageStillArms() {
    XCTAssertNotNil(
      VibeTimelineShadowProbe.makeIfEligible(
        chatId: "47157fce5863", isGroupOrChannel: false, flags: flags(.directMessage)))
  }

  func testASavedMessagesAllowlistDoesNotArmOrdinaryDMs() {
    XCTAssertNil(
      VibeTimelineShadowProbe.makeIfEligible(
        chatId: "47157fce5863", isGroupOrChannel: false, flags: flags(.savedMessages)))
  }
}
