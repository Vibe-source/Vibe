import Foundation
import UIKit
import XCTest

@testable import Vibe

/// Row heights as arithmetic, and the one property that makes them worth having.
///
/// These heights replace measurements that are taken today by building a view
/// and asking it. The replacement is only safe if it agrees with what it
/// replaces — a disagreement is not a rounding difference, it is a row that
/// changes size after the user can see it.
final class VibeRowMetricsTests: XCTestCase {

  private func attributed(_ text: String, size: CGFloat = 16) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: size)])
  }

  // MARK: The property this exists for

  func testMeasurementRunsOffTheMainThread() {
    // The whole point. `UILabel.sizeThatFits` would trap here; `boundingRect`
    // does not, and that difference is what lets a transcript be measured before
    // it is pushed instead of during.
    let text = attributed(String(repeating: "the quick brown fox ", count: 40))
    let done = expectation(description: "measured off main")
    var offMainHeight: CGFloat = 0

    DispatchQueue.global(qos: .userInitiated).async {
      XCTAssertFalse(Thread.isMainThread)
      offMainHeight = VibeRowMetrics.textHeight(text, width: 300)
      done.fulfill()
    }
    wait(for: [done], timeout: 5)

    XCTAssertGreaterThan(offMainHeight, 0)
    XCTAssertEqual(
      offMainHeight, VibeRowMetrics.textHeight(text, width: 300),
      "the same string at the same width must measure the same on any thread")
  }

  func testConcurrentMeasurementIsStable() {
    // A prepared transcript measures many rows at once. If `boundingRect` were
    // thread-hostile this is where it would show up as flaky heights rather than
    // as a crash — which would be a shift nobody could reproduce.
    let text = attributed("a reasonably long message that will wrap at this width")
    let expected = VibeRowMetrics.textHeight(text, width: 220)
    let done = expectation(description: "concurrent")
    done.expectedFulfillmentCount = 8
    for _ in 0..<8 {
      DispatchQueue.global().async {
        for _ in 0..<50 {
          XCTAssertEqual(VibeRowMetrics.textHeight(text, width: 220), expected)
        }
        done.fulfill()
      }
    }
    wait(for: [done], timeout: 20)
  }

  // MARK: Text measurement

  func testEmptyAndZeroWidthMeasureToNothingRatherThanCrashing() {
    XCTAssertEqual(VibeRowMetrics.textHeight(attributed(""), width: 300), 0)
    XCTAssertEqual(VibeRowMetrics.textHeight(attributed("hello"), width: 0), 0)
    XCTAssertEqual(VibeRowMetrics.textHeight(attributed("hello"), width: -10), 0)
  }

  func testWrappingIncreasesHeightAndNarrowerIsTaller() {
    let text = attributed(String(repeating: "wrap me please ", count: 20))
    let wide = VibeRowMetrics.textHeight(text, width: 400)
    let narrow = VibeRowMetrics.textHeight(text, width: 120)
    XCTAssertGreaterThan(narrow, wide)
  }

  func testHeightIsRoundedUp() {
    // The existing path ceils before it commits. A fractional height that
    // disagrees with the frozen one by 0.4pt is still a shift.
    let height = VibeRowMetrics.textHeight(attributed("one line"), width: 300)
    XCTAssertEqual(height, height.rounded(.up))
  }

  // MARK: Bubble composition

  func testInlineMetaDoesNotMakeABubbleTaller() {
    // The meta sits beside short LTR text, so a timestamp costs nothing there.
    // Measured above the 34pt floor on purpose: at small text heights the floor
    // clamps the inline case and the difference stops being the meta block —
    // which is a real property, pinned separately below.
    let inline = VibeRowMetrics.textBubbleHeight(textHeight: 100, metaLayout: .inline)
    let bottom = VibeRowMetrics.textBubbleHeight(textHeight: 100, metaLayout: .bottom)
    XCTAssertLessThan(inline, bottom)
    XCTAssertEqual(
      bottom - inline, VibeRowMetrics.bubbleMetaTopSpacing + VibeRowMetrics.bubbleMetaHeight)
  }

  func testTheFloorHidesTheMetaDifferenceOnShortBubbles() {
    // A one-line inline bubble is already at the floor, so moving the meta to
    // its own line grows it by less than the meta block. Worth pinning: it is
    // the case where the arithmetic and the intuition disagree.
    let inline = VibeRowMetrics.textBubbleHeight(textHeight: 20, metaLayout: .inline)
    XCTAssertEqual(inline, VibeRowMetrics.textBubbleFloor)
    let bottom = VibeRowMetrics.textBubbleHeight(textHeight: 20, metaLayout: .bottom)
    XCTAssertEqual(bottom - inline, 12)
  }

  func testAVeryShortBubbleIsHeldAtTheFloor() {
    // 34, not 36 — the audit caught this one; the wrong constant is a 2pt shift
    // on every short message in the transcript.
    XCTAssertEqual(
      VibeRowMetrics.textBubbleHeight(textHeight: 1, metaLayout: .inline),
      VibeRowMetrics.textBubbleFloor)
    XCTAssertEqual(VibeRowMetrics.textBubbleFloor, 34)
  }

  func testAReactionAddsExactlyItsChrome() {
    let plain = VibeRowMetrics.textBubbleHeight(textHeight: 100, metaLayout: .bottom)
    let reacted = VibeRowMetrics.textBubbleHeight(
      textHeight: 100, metaLayout: .bottom, hasReaction: true)
    XCTAssertEqual(reacted - plain, VibeRowMetrics.reactionHeightOffset)
    XCTAssertEqual(VibeRowMetrics.reactionHeightOffset, 28)
  }

  func testAReplyPreviewAddsItsHeightPlusItsSpacing() {
    let plain = VibeRowMetrics.textBubbleHeight(textHeight: 100, metaLayout: .bottom)
    let replied = VibeRowMetrics.textBubbleHeight(
      textHeight: 100, metaLayout: .bottom, hasReplyPreview: true)
    XCTAssertEqual(
      replied - plain, VibeRowMetrics.replyPreviewHeight + VibeRowMetrics.replyPreviewSpacing)
  }

  func testAnInlineAttachmentSuppressesTheLinkPreviewBranch() {
    // The measure path is an if/else, not additive: a row with an attachment
    // takes the attachment branch and never adds preview height. Getting this
    // wrong would double-count.
    let withBoth = VibeRowMetrics.textBubbleHeight(
      textHeight: 50, metaLayout: .bottom, inlineAttachmentHeight: 48, linkPreviewHeight: 200)
    let withAttachmentOnly = VibeRowMetrics.textBubbleHeight(
      textHeight: 50, metaLayout: .bottom, inlineAttachmentHeight: 48)
    XCTAssertEqual(withBoth, withAttachmentOnly)
  }

  func testALinkPreviewAddsItsSpacingOnlyWhenPresent() {
    let none = VibeRowMetrics.textBubbleHeight(
      textHeight: 50, metaLayout: .bottom, linkPreviewHeight: 0)
    let some = VibeRowMetrics.textBubbleHeight(
      textHeight: 50, metaLayout: .bottom, linkPreviewHeight: 120)
    XCTAssertEqual(some - none, VibeRowMetrics.linkPreviewSpacing + 120)
  }

  // MARK: Fixed kinds

  func testFixedKindsMatchTheirConstants() {
    XCTAssertEqual(VibeRowMetrics.daySeparatorHeight(), 30)
    XCTAssertEqual(VibeRowMetrics.agentActionsHeight(), 36)
    XCTAssertEqual(VibeRowMetrics.videoNoteHeight(), 200)
    XCTAssertEqual(VibeRowMetrics.documentHeight(), 80)
    XCTAssertEqual(VibeRowMetrics.servicePillHeight(hasLiveDecisionActions: false), 36)
    XCTAssertEqual(VibeRowMetrics.servicePillHeight(hasLiveDecisionActions: true), 76)
  }

  func testVoiceIsHeldAtItsOwnFloor() {
    // 60 + 2 + 7 = 69, above the 66 floor, so the floor only bites with the
    // shorter chrome — but it must still be the voice floor, not the text one.
    XCTAssertEqual(VibeRowMetrics.voiceBubbleHeight(), 69)
    XCTAssertGreaterThanOrEqual(VibeRowMetrics.voiceBubbleHeight(), VibeRowMetrics.voiceBubbleFloor)
  }

  // MARK: Media

  func testAnUnknownNaturalSizeRefusesToGuess() {
    // The square-fallback-then-correct pattern is a documented real shift in
    // this app. `nil` means "ask the natural-size store", not "assume square".
    XCTAssertNil(VibeRowMetrics.mediaDisplayHeight(naturalSize: nil, bubbleWidth: 260))
    XCTAssertNil(
      VibeRowMetrics.mediaDisplayHeight(naturalSize: CGSize(width: 0, height: 10), bubbleWidth: 260))
    XCTAssertNil(
      VibeRowMetrics.mediaDisplayHeight(naturalSize: CGSize(width: 10, height: 0), bubbleWidth: 260))
  }

  func testAnOrdinaryPhotoScalesByItsAspect() {
    let height = VibeRowMetrics.mediaDisplayHeight(
      naturalSize: CGSize(width: 1000, height: 500), bubbleWidth: 260)
    XCTAssertEqual(height, 130)
  }

  func testAHostileAspectIsClampedRatherThanHonoured() {
    // A 1×10000 attachment must not claim the screen.
    let tall = VibeRowMetrics.mediaDisplayHeight(
      naturalSize: CGSize(width: 1, height: 10_000), bubbleWidth: 260)
    XCTAssertEqual(tall, VibeRowMetrics.mediaMaxHeight)

    let wide = VibeRowMetrics.mediaDisplayHeight(
      naturalSize: CGSize(width: 10_000, height: 1), bubbleWidth: 260)
    XCTAssertEqual(wide, max(VibeRowMetrics.mediaMinHeight, 260 * VibeRowMetrics.mediaAspectMin))
  }

  func testMediaIsNeverNarrowerThanTheMinimumWhenSizing() {
    // A tiny bubble width still lays media out at the minimum, so the height
    // follows the minimum rather than collapsing.
    let height = VibeRowMetrics.mediaDisplayHeight(
      naturalSize: CGSize(width: 100, height: 100), bubbleWidth: 10)
    XCTAssertEqual(height, VibeRowMetrics.mediaMinWidth)
  }

  func testStickersUseTheirOwnEnvelope() {
    let height = VibeRowMetrics.mediaDisplayHeight(
      naturalSize: CGSize(width: 100, height: 200), bubbleWidth: 300, isSticker: true)
    XCTAssertEqual(height, VibeRowMetrics.stickerMaxHeight)
    XCTAssertLessThanOrEqual(height ?? .infinity, VibeRowMetrics.stickerMaxHeight)
  }

  // MARK: Widths

  func testTextWidthFollowsTheBubbleFactorAndPadding() {
    // 440 * 0.85 = 374, floor 374, minus 24 padding = 350.
    XCTAssertEqual(VibeRowMetrics.textMaxWidth(rowWidth: 440), 350)
  }

  func testAnAbsurdlyNarrowRowStillYieldsAUsableWidth() {
    XCTAssertGreaterThan(VibeRowMetrics.textMaxWidth(rowWidth: 1), 0)
  }
}
