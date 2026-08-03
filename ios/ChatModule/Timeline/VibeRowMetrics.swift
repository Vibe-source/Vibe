import CoreGraphics
import Foundation
import UIKit

/// Row heights as arithmetic, with no `UIView` in the call graph.
///
/// # Why this exists
///
/// The list's heights are decided today by `measureMessageBubbleLayout`, which
/// gets its answers by building views and asking them. That is main-thread-only
/// by construction, so chat open pays for measurement during the push — and a
/// push that computes is a push that can be late, which is what a user sees as a
/// stall and then a shift.
///
/// Everything here is `NSAttributedString.boundingRect` plus arithmetic:
/// CoreText over an immutable string, callable from any thread. That makes a
/// transcript measurable **before** it is pushed, and a row measured before the
/// push and never re-measured cannot shift.
///
/// # What is deliberately not here
///
/// **Agent turns.** `VibeAgentTurnContentView.measuredHeight` pins a width
/// constraint on a template view, lays it out, and asks
/// `systemLayoutSizeFitting`, over a `UIStackView` whose arranged subviews are
/// built in a loop over progress items — each itself Auto Layout sized. No
/// arithmetic reproduces that, and rebuilding the stack in order to predict it
/// would cost more than laying it out. Agent turns stay view-measured; they move
/// off the *push* instead of off the *thread*, by being measured at prewarm or
/// at settle and then frozen. At mount time a frozen height and an off-main
/// height are the same thing: a number that already exists.
///
/// # Correctness rule
///
/// Every function here must agree with the view-based path it replaces to within
/// half a point. A disagreement is not a rounding difference — it is a row that
/// changes size after it is on screen, which is the exact defect this whole
/// effort exists to remove. Constants are transcribed from
/// `docs/row-height-formulas.md`, which cites a declaration site for each.
enum VibeRowMetrics {

  // MARK: Constants
  //
  // Transcribed from `ChatListViewConstants.swift` via the audit. A typo in this
  // block is a shift, so each carries its source.

  static let messageHorizontalInset: CGFloat = 8  // ChatListViewConstants:4
  static let bubbleHorizontalPadding: CGFloat = 12  // :9
  static let bubbleTopPadding: CGFloat = 5  // :11
  static let bubbleBottomPadding: CGFloat = 6  // :13
  static let bubbleMetaTopSpacing: CGFloat = 1  // :14
  static let bubbleMetaHeight: CGFloat = 14  // :15
  static let bubbleMaxWidthFactor: CGFloat = 0.85  // :17

  /// Reaction chrome, added to many kinds. Also the size of the unexplained
  /// 28 pt open shift measured on device — worth remembering when one appears.
  static let reactionHeightOffset: CGFloat = 28  // ChatListViewCells:4713

  static let textBubbleFloor: CGFloat = 34  // :5142 — 34, not 36
  static let replyPreviewHeight: CGFloat = 36
  static let replyPreviewSpacing: CGFloat = 6
  static let inlineAttachmentSpacing: CGFloat = 8
  static let inlineAttachmentHeight: CGFloat = 48
  static let linkPreviewSpacing: CGFloat = 8

  static let dayRowHeight: CGFloat = 30  // ChatListView:13344
  static let outOfBoundsRowHeight: CGFloat = 56  // :13339
  static let servicePillBaseHeight: CGFloat = 36  // :13943, :14104
  static let serviceDecisionActionsHeight: CGFloat = 40  // ChatListViewCells:2303
  static let agentActionsRowHeight: CGFloat = 36  // :4669

  static let voiceMediaHeight: CGFloat = 60  // :4855
  static let musicFileMediaHeight: CGFloat = 68  // :4849
  static let voiceTopPadding: CGFloat = 2  // :4978
  static let voiceBottomPadding: CGFloat = 7  // :4981
  static let voiceBubbleFloor: CGFloat = 66  // :4985
  static let mediaBubbleFloor: CGFloat = 48  // :4985
  static let fullBleedMediaFloor: CGFloat = 56  // :4984

  static let videoNoteSide: CGFloat = 200  // :4858
  static let documentRowHeight: CGFloat = 80  // ChatListViewCells:2356

  static let mediaMinWidth: CGFloat = 120  // :4884
  static let mediaMinHeight: CGFloat = 84  // :4885
  static let mediaMaxHeight: CGFloat = 380  // :4888
  static let mediaAspectMin: CGFloat = 0.2  // :4882
  static let mediaAspectMax: CGFloat = 5.0  // :4882

  static let stickerMinSide: CGFloat = 72  // :2344
  static let stickerDefaultSide: CGFloat = 136  // :2345
  static let stickerMaxWidth: CGFloat = 152  // :2346
  static let stickerMaxHeight: CGFloat = 184  // :2347

  // MARK: Widths

  /// The width a bubble's text is laid out in, from the row width.
  static func textMaxWidth(rowWidth: CGFloat) -> CGFloat {
    let maxBubbleWidth = (rowWidth * bubbleMaxWidthFactor).rounded(.down)
    return max(1, maxBubbleWidth - bubbleHorizontalPadding * 2)
  }

  // MARK: Text

  /// Laid-out height of an attributed string at a given width.
  ///
  /// `boundingRect` is CoreText over an immutable string and is safe off the
  /// main thread — unlike `UILabel.sizeThatFits`, which is the reason the
  /// existing path cannot leave it. `.usesLineFragmentOrigin` and
  /// `.usesFontLeading` match what the cell measures with; dropping either
  /// changes the answer for multi-line text.
  ///
  /// `ceil` matches the existing path, which rounds up before it commits.
  static func textHeight(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
    guard width > 0, attributed.length > 0 else { return 0 }
    let bounds = attributed.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil)
    return ceil(bounds.height)
  }

  // MARK: Bubbles

  /// Where the meta (time + ticks) sits, which changes how the body stacks.
  enum MetaLayout {
    /// Meta on its own line under the body — rich text, previews, RTL, tall.
    case bottom
    /// Meta inline beside short LTR text.
    case inline
  }

  /// Height of a plain or rich text bubble.
  ///
  /// Mirrors `measureMessageBubbleLayout` `:5124–5143`. Pass `textHeight`
  /// already collapsed when the row is tall-collapsed — the cap is line-count
  /// based (`floor(420 / lineHeight) * lineHeight`), not a raw 420, so it cannot
  /// be applied here without the font.
  static func textBubbleHeight(
    textHeight: CGFloat,
    metaLayout: MetaLayout,
    hasReplyPreview: Bool = false,
    inlineAttachmentHeight: CGFloat = 0,
    linkPreviewHeight: CGFloat = 0,
    hasReaction: Bool = false
  ) -> CGFloat {
    let replyBlock = hasReplyPreview ? replyPreviewHeight + replyPreviewSpacing : 0
    let metaBlock = bubbleMetaTopSpacing + bubbleMetaHeight

    let bodyHeight: CGFloat
    if inlineAttachmentHeight > 0 {
      bodyHeight =
        replyBlock + max(textHeight, 0) + inlineAttachmentSpacing + inlineAttachmentHeight
        + metaBlock
    } else {
      switch metaLayout {
      case .bottom:
        let preview = linkPreviewHeight > 0 ? linkPreviewSpacing + linkPreviewHeight : 0
        bodyHeight = replyBlock + max(textHeight, 0) + preview + metaBlock
      case .inline:
        // The meta sits beside the text, so a one-line bubble is not taller for
        // having a timestamp in it.
        bodyHeight = replyBlock + max(textHeight, bubbleMetaHeight)
      }
    }

    let padded =
      bodyHeight + bubbleTopPadding + bubbleBottomPadding
      + (hasReaction ? reactionHeightOffset : 0)
    return max(textBubbleFloor, padded)
  }

  // MARK: Fixed kinds

  static func daySeparatorHeight() -> CGFloat { dayRowHeight }

  static func servicePillHeight(hasLiveDecisionActions: Bool) -> CGFloat {
    servicePillBaseHeight + (hasLiveDecisionActions ? serviceDecisionActionsHeight : 0)
  }

  static func agentActionsHeight() -> CGFloat { agentActionsRowHeight }

  static func voiceBubbleHeight(hasReaction: Bool = false, isMusicFile: Bool = false) -> CGFloat {
    let media = isMusicFile ? musicFileMediaHeight : voiceMediaHeight
    let padded =
      media + voiceTopPadding + voiceBottomPadding + (hasReaction ? reactionHeightOffset : 0)
    return max(voiceBubbleFloor, padded)
  }

  // MARK: Media

  /// Displayed height of a media attachment at a given bubble width.
  ///
  /// The aspect clamp is what stops a malformed or hostile attachment from
  /// claiming a screen — and the durable natural-size store exists because an
  /// *unknown* aspect defaulting to square and then being corrected after decode
  /// is one of the list's real shifts. Callers must pass the stored natural size
  /// rather than a guess; `nil` here is honest about not knowing.
  static func mediaDisplayHeight(
    naturalSize: CGSize?,
    bubbleWidth: CGFloat,
    isSticker: Bool = false
  ) -> CGFloat? {
    guard let naturalSize, naturalSize.width > 0, naturalSize.height > 0 else { return nil }
    let rawAspect = naturalSize.height / naturalSize.width
    let aspect = min(max(rawAspect, mediaAspectMin), mediaAspectMax)

    if isSticker {
      let side = min(stickerMaxWidth, max(stickerMinSide, bubbleWidth))
      return min(stickerMaxHeight, side * aspect)
    }

    let width = max(mediaMinWidth, bubbleWidth)
    return min(mediaMaxHeight, max(mediaMinHeight, width * aspect))
  }

  static func stickerFallbackSide() -> CGFloat { stickerDefaultSide }

  static func videoNoteHeight() -> CGFloat { videoNoteSide }

  static func documentHeight(hasReaction: Bool = false) -> CGFloat {
    documentRowHeight + (hasReaction ? reactionHeightOffset : 0)
  }
}
