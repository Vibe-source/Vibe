import UIKit

let listBottomThreshold: CGFloat = 88.0
let messageHorizontalInset: CGFloat = 8.0
let messageSelectionLeadingInset: CGFloat = 38.0
let sectionTopInset: CGFloat = 10.0
let sectionBottomInset: CGFloat = 14.0
let bubbleSideMargin: CGFloat = 2.0
let bubbleHorizontalPadding: CGFloat = 12.0
// Telegram text bubbles sit a bit tighter vertically than 7/8.
let bubbleTopPadding: CGFloat = 5.0
// Slightly more bottom pad so meta/time clear the lower Telegram-aligned tail join.
let bubbleBottomPadding: CGFloat = 6.0
let bubbleMetaTopSpacing: CGFloat = 1.0
let bubbleMetaHeight: CGFloat = 14.0
let bubbleMinWidth: CGFloat = 26.0
let bubbleMaxWidthFactor: CGFloat = 0.85
// The inline agent-turn bubble must read as a NORMAL them-bubble: its answer prose is a
// bare edge-to-edge label inside the body view (no internal leading inset), so the shell
// has to supply the SAME inset a plain text bubble uses or the text hugs the bubble edge
// and looks misaligned against every other incoming message. Keep these equal to the
// plain-bubble constants — do not tighten them (the earlier 6/4 tightening is what made the
// agent text sit ~6pt further left + higher than a real them-bubble).
let agentTurnHorizontalPadding: CGFloat = bubbleHorizontalPadding
let agentTurnVerticalPadding: CGFloat = bubbleTopPadding
// Match the plain-bubble width so an agent turn is the same shape as any other incoming
// message. Rich content (diff cards / step lists) scrolls/wraps inside this width rather
// than widening the whole bubble past its neighbours.
let agentTurnMaxWidthFactor: CGFloat = bubbleMaxWidthFactor
/// One rendered line of agent-turn body text, measured on device: the streaming label's
/// bounds step 20 → 44 → 68 → 92 as it wraps.
let agentTurnStreamingLineStep: CGFloat = 24.0
/// Height granularity for a LIVE agent turn: two lines of headroom.
///
/// A streaming turn used to be sized to the exact measured height of the text it had SO
/// FAR, so every wrapped line was a real height change — `requiresLayoutReload` saw the
/// delta, reconfigured the cell, invalidated layout and re-pinned the bottom. Measured on
/// one 5s answer: ten separate `[LayoutShift] path=heightReload` steps (Δ19, Δ24, Δ24,
/// Δ24, …), each one a visible nudge of the whole transcript.
///
/// Quantising the live plate up to the next block instead means the text streams into
/// space the cell ALREADY has: the plate grows once per two lines, and between those steps
/// nothing in the list moves at all. The reserve is dropped the instant the turn settles
/// (`isLiveStreaming == false`), so a finished bubble is still sized exactly to its
/// content — the collapse at settle is bounded by one block, which is why this is two
/// lines and not five.
let agentTurnStreamingHeightBlock: CGFloat = agentTurnStreamingLineStep * 2.0

/// Plate height for a live agent turn: `measured` rounded up to the next block, never
/// below one block. Deterministic on purpose — the list's sizing pass and the cell's own
/// `layoutSubviews` both call `measureMessageBubbleLayout`, and they must agree to the
/// pixel or the plate and its slot disagree (empty air above a bottom-pinned bubble).
func agentTurnStreamingReservedHeight(_ measured: CGFloat) -> CGFloat {
  guard measured > 0.0 else { return measured }
  let block = agentTurnStreamingHeightBlock
  return max(block, (measured / block).rounded(.up) * block)
}
// Telegram-style date chip: a clean solid capsule — slightly wider and shorter than the
// old bordered pill. Shared by the in-list day separators AND the sticky header pill so
// the stick/hand-off between them reads as one element.
let dayPillHorizontalPadding: CGFloat = 14.0
let dayPillVerticalPadding: CGFloat = 3.5
// One shared tall-content rule for BOTH user and agent bubbles: content taller than
// the trigger collapses to the capped height and gains a glass expand/collapse chip
// OUTSIDE the plate (list overlay): them = top-trailing outside, me = top-leading
// outside. Collapsed content keeps full text and soft-fades at the bottom (no hard
// clip). Expand/collapse is height-only in Y — no content fade. The trigger sits well
// above the cap so borderline content never gets a control that saves almost nothing.
let tallBubbleCollapseTriggerHeight: CGFloat = 560.0
let tallBubbleCollapsedContentHeight: CGFloat = 420.0
/// Gap between the bubble's outer side edge and the glass toggle chip.
let tallBubbleToggleSpacing: CGFloat = 6.0
/// Soft fade band at the bottom of collapsed tall content ("there's more").
let tallBubbleCollapseFadeHeight: CGFloat = 56.0
/// Visible glass circle diameter (icon sits inside).
let tallBubbleGlassToggleSize: CGFloat = 34.0
/// Hit target for the outer glass expand/collapse control.
let tallBubbleChevronHitSize: CGFloat = 40.0
/// Cell height reserved for the outer glass chip (overlay sits outside the plate).
let tallBubbleGlassOuterReserve: CGFloat = 0.0
