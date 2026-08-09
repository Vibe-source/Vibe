import UIKit

private let chatContextHoldDebugLogs = true
/// Near-zero scale for picker/menu birth and collapse; animate to/from identity.
private let chatContextMenuCollapsedScale: CGFloat = 0.001

public protocol ChatContextMenuOverlayDelegate: AnyObject {
  func contextMenuDidDismiss(overlay: ChatContextMenuOverlay)
  func contextMenuDidSelectReaction(_ reaction: String, messageId: String, sourcePoint: CGPoint?)
  func contextMenuDidSelectAction(_ actionId: String, messageId: String)
}

// MARK: - Glass Helper

/// Creates a UIVisualEffectView that uses real UIGlassEffect on iOS 26+,
/// and falls back to UIBlurEffect on older iOS versions.
func makeChatContextLiquidGlassView(
  style: UIBlurEffect.Style = .systemMaterial,
  cornerRadius: CGFloat,
  capsuleCorners: Bool = false,
  interactive: Bool = false
) -> UIVisualEffectView {
  let view = UIVisualEffectView(effect: nil)
  if #available(iOS 26.0, *) {
    let effect = UIGlassEffect(style: .regular)
    effect.isInteractive = interactive
    effect.tintColor = nil
    view.effect = effect
    if capsuleCorners {
      view.cornerConfiguration = .capsule()
    } else {
      view.layer.cornerRadius = cornerRadius
      view.layer.cornerCurve = .continuous
    }
  } else {
    view.effect = UIBlurEffect(style: style)
    view.layer.cornerRadius = cornerRadius
    view.layer.cornerCurve = .continuous
  }
  view.clipsToBounds = true
  return view
}

private func makeBlurMaterialView(
  style: UIBlurEffect.Style,
  cornerRadius: CGFloat
) -> UIVisualEffectView {
  let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
  view.layer.cornerRadius = cornerRadius
  view.layer.cornerCurve = .continuous
  view.clipsToBounds = true
  return view
}

// MARK: - ChatContextMenuOverlay

public final class ChatContextMenuOverlay: UIView {
  weak var delegate: ChatContextMenuOverlayDelegate?

  let messageId: String

  // The bubble snapshot (bubble+tail only, already positioned in window coords)
  private let bubbleSnapshot: UIView
  // Stable pre-extraction pixels. Capturing after the overlay dismisses races
  // Core Animation's hidden extracted state and can produce a transparent image.
  private let deletionBubbleImage: UIImage?
  // The bubble's original frame in window coords (before any shifting)
  private let originalBubbleFrame: CGRect
  private let bubbleIsMe: Bool

  private let appearance: ChatListAppearance

  // Full-screen native glass background (same as Telegram / UIContextMenuInteraction)
  private let backgroundGlassView: UIVisualEffectView

  // Reaction picker pill
  private let reactionPicker: ReactionPickerView
  /// Suppresses the emoji row entirely — see the failed-send note in `init`.
  private var hidesReactionPicker = false

  // Action menu card
  private let contextMenu: ContextMenuView

  private var isDismissing = false
  private var ignoreBackgroundTapUntil: CFTimeInterval = 0
  private var enableControlsWorkItem: DispatchWorkItem?
  private var isSelectingReaction = false

  private func holdDebugLog(_ message: String) {
    guard chatContextHoldDebugLogs else { return }
    NSLog("[ChatContextHold] %@", message)
  }

  // MARK: - Init

  init(
    messageId: String,
    bubbleSnapshot: UIView,
    deletionBubbleImage: UIImage?,
    bubbleFrame: CGRect,
    bubbleIsMe: Bool,
    appearance: ChatListAppearance,
    showResendAction: Bool,
    showRegenerateAction: Bool = false,
    showEditAction: Bool = false,
    showEditedInfo: Bool = false,
    editedAtMs: Int64? = nil,
    showSaveImageAction: Bool = false,
    showCopyLinkAction: Bool = false,
    showForwardAction: Bool = false,
    showReportAction: Bool = false,
    restrictSavingContent: Bool = false,
    failedSendOnly: Bool = false
  ) {
    self.messageId = messageId
    self.bubbleSnapshot = bubbleSnapshot
    self.deletionBubbleImage = deletionBubbleImage
    self.originalBubbleFrame = bubbleFrame
    self.bubbleIsMe = bubbleIsMe
    self.appearance = appearance

    // Full-screen background: native system glass blur
    self.backgroundGlassView = UIVisualEffectView(
      effect: UIBlurEffect(style: .systemUltraThinMaterialDark))

    let colorOverlay = UIView()
    let isDarkMode = appearance.isDark
    let overlayBaseColor: UIColor = .black
    let overlayAlpha: CGFloat = isDarkMode ? 0.64 : 0.52
    colorOverlay.backgroundColor = overlayBaseColor.withAlphaComponent(overlayAlpha)
    colorOverlay.translatesAutoresizingMaskIntoConstraints = false
    self.backgroundGlassView.contentView.addSubview(colorOverlay)
    NSLayoutConstraint.activate([
      colorOverlay.topAnchor.constraint(equalTo: self.backgroundGlassView.contentView.topAnchor),
      colorOverlay.bottomAnchor.constraint(
        equalTo: self.backgroundGlassView.contentView.bottomAnchor),
      colorOverlay.leadingAnchor.constraint(
        equalTo: self.backgroundGlassView.contentView.leadingAnchor),
      colorOverlay.trailingAnchor.constraint(
        equalTo: self.backgroundGlassView.contentView.trailingAnchor),
    ])

    self.reactionPicker = ReactionPickerView(appearance: appearance, messageId: messageId)
    self.contextMenu = ContextMenuView(
      appearance: appearance,
      messageId: messageId,
      showResendAction: showResendAction,
      showRegenerateAction: showRegenerateAction,
      showEditAction: showEditAction,
      showEditedInfo: showEditedInfo,
      editedAtMs: editedAtMs,
      showSaveImageAction: showSaveImageAction,
      showCopyLinkAction: showCopyLinkAction,
      showForwardAction: showForwardAction,
      showReportAction: showReportAction,
      restrictSavingContent: restrictSavingContent,
      failedSendOnly: failedSendOnly
    )
    // No reactions on a message that was never delivered — there is nobody on the other
    // end to have reacted to, and a picker above a two-item menu is most of the chrome
    // for none of the meaning.
    self.hidesReactionPicker = failedSendOnly

    super.init(frame: .zero)

    setupViews()
    setupGestures()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupViews() {
    // Keep the resolved backdrop stable while glass is visible above it.
    backgroundGlassView.alpha = 1
    addSubview(backgroundGlassView)

    // 2. Bubble snapshot (already has correct frame in window coords)
    bubbleSnapshot.alpha = 0
    addSubview(bubbleSnapshot)

    // 3. Reaction picker (above bubble)
    reactionPicker.alpha = 0
    reactionPicker.delegate = self
    reactionPicker.onContentSizeChange = { [weak self] in
      guard let self, !self.isDismissing else { return }
      _ = self.layoutMenus()
    }
    let pickerSize = reactionPicker.intrinsicContentSize
    reactionPicker.frame = CGRect(origin: .zero, size: pickerSize)
    reactionPicker.isHidden = hidesReactionPicker
    if !hidesReactionPicker { addSubview(reactionPicker) }

    // 4. Context menu (below or above bubble)
    contextMenu.alpha = 1
    contextMenu.delegate = self
    contextMenu.frame = CGRect(x: 0, y: 0, width: 220, height: 1)
    addSubview(contextMenu)
  }

  private func setupGestures() {
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap(_:)))
    tap.delegate = self
    tap.cancelsTouchesInView = false
    tap.delaysTouchesBegan = false
    tap.delaysTouchesEnded = false
    addGestureRecognizer(tap)
  }

  @objc private func handleBackgroundTap(_ gesture: UITapGestureRecognizer) {
    if isSelectingReaction { return }
    let now = CACurrentMediaTime()
    let point = gesture.location(in: self)
    if now < ignoreBackgroundTapUntil {
      holdDebugLog(
        "backgroundTap ignored point=\(NSCoder.string(for: point)) now=\(String(format: "%.3f", now)) until=\(String(format: "%.3f", ignoreBackgroundTapUntil))"
      )
      return
    }
    holdDebugLog("backgroundTap accepted point=\(NSCoder.string(for: point))")
    animateOut(reason: "backgroundTap")
  }

  // MARK: - Layout

  private func layoutMenus() -> CGRect {
    let safeTop = safeAreaInsets.top + 10
    let safeBottom = bounds.height - safeAreaInsets.bottom - 10
    let safeLeft: CGFloat = 16
    let safeRight = bounds.width - 16

    // Measure reaction picker. Zero height and zero gap when it is suppressed, so the
    // menu sits against the bubble instead of leaving a hole where the emoji row was.
    let pickerSize = hidesReactionPicker ? .zero : reactionPicker.intrinsicContentSize
    let pickerHeight = pickerSize.height
    let pickerGap: CGFloat = hidesReactionPicker ? 0 : 8

    // Measure context menu
    let menuWidth: CGFloat = min(220, bounds.width - 32)
    let menuHeight = contextMenu.systemLayoutSizeFitting(
      CGSize(width: menuWidth, height: UIView.layoutFittingCompressedSize.height)
    ).height
    // Keep the action menu visually attached to the bubble (Telegram-like spacing).
    let menuGap: CGFloat = 4

    // Horizontal alignment: align to bubble edge, then clamp to viewport.
    let isRightAligned = bubbleIsMe || originalBubbleFrame.midX > bounds.midX
    reactionPicker.setThinkingBlobDirection(isRightAligned: isRightAligned)

    // Reaction picker: align to bubble edge, clamped strictly to safe viewport
    let pickerWidth = min(pickerSize.width, bounds.width - 24)
    let targetPickerX =
      isRightAligned ? originalBubbleFrame.maxX - pickerWidth : originalBubbleFrame.minX
    let pickerX = max(safeLeft, min(safeRight - pickerWidth, targetPickerX))

    // Vertical placement prefers original bubble Y, then shifts minimally to fit picker+menu.
    var bubbleY = originalBubbleFrame.minY
    var pickerY = bubbleY - pickerHeight - pickerGap
    var menuY = bubbleY + originalBubbleFrame.height + menuGap

    let totalBottom = menuY + menuHeight
    // First, shift UP to ensure the context menu stays fully inside the safe area.
    if totalBottom > safeBottom {
      let shiftUp = totalBottom - safeBottom
      bubbleY -= shiftUp
      pickerY -= shiftUp
      menuY -= shiftUp
    }

    // Next, shift DOWN to ensure the reaction picker stays fully inside the safe area.
    // However, if we shift down too much, we will push the context menu back out of bounds,
    // which results in overlapping the bubble. Limit the shift down to the available space.
    if pickerY < safeTop {
      let desiredShiftDown = safeTop - pickerY
      let availableBottomSpace = max(0, safeBottom - (menuY + menuHeight))
      let allowedShiftDown = min(desiredShiftDown, availableBottomSpace)

      bubbleY += allowedShiftDown
      pickerY += allowedShiftDown
      menuY += allowedShiftDown
    }

    reactionPicker.frame = CGRect(
      x: pickerX,
      y: max(safeTop, pickerY),  // Ensure picker doesn't go off-screen even if bubble is huge
      width: pickerWidth,
      height: pickerHeight
    )

    // Bubble: keep original X, shift Y to computed safe position.
    let finalBubbleFrame = CGRect(
      x: originalBubbleFrame.minX,
      y: bubbleY,
      width: originalBubbleFrame.width,
      height: originalBubbleFrame.height
    )
    bubbleSnapshot.frame = finalBubbleFrame

    // Context menu: align to bubble edge
    let menuX: CGFloat
    if isRightAligned {
      menuX = max(safeLeft, finalBubbleFrame.maxX - menuWidth)
    } else {
      menuX = min(safeRight - menuWidth, finalBubbleFrame.minX)
    }
    contextMenu.frame = CGRect(
      x: max(safeLeft, min(safeRight - menuWidth, menuX)),
      y: max(safeTop, min(safeBottom - menuHeight, menuY)),
      width: menuWidth,
      height: menuHeight
    )

    return finalBubbleFrame
  }

  /// Keep the extracted bubble and the existing glass card on-screen while the
  /// action list drills into delete scope. Only the card's inner content moves;
  /// its frame is remeasured in the same animation so this never reads as a
  /// second modal appearing on top of the context menu.
  func presentDeleteConfirmation(deleteForEveryoneTitle: String?) {
    guard !isDismissing else { return }
    holdDebugLog(
      "delete confirmation begin everyone=\(deleteForEveryoneTitle == nil ? "N" : "Y")")
    contextMenu.transitionToDeleteConfirmation(
      deleteForEveryoneTitle: deleteForEveryoneTitle
    ) { [weak self] in
      guard let self else { return }
      _ = self.layoutMenus()
      self.layoutIfNeeded()
    }
  }

  /// Returns the original bubble pixels at the original list slot, even though
  /// the extracted context-menu copy may have shifted vertically to fit menus.
  func deletionBubbleCapture(in targetView: UIView) -> (image: UIImage, frame: CGRect)? {
    guard let deletionBubbleImage else { return nil }
    let frameInTarget = convert(originalBubbleFrame, to: targetView)
    return (deletionBubbleImage, frameInTarget)
  }

  // MARK: - Animate In / Out

  private func setAnchorPoint(_ anchorPoint: CGPoint, for view: UIView) {
    let oldOrigin = view.frame.origin
    view.layer.anchorPoint = anchorPoint
    let newOrigin = view.frame.origin
    let transition = CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y)
    view.center = CGPoint(x: view.center.x - transition.x, y: view.center.y - transition.y)
  }

  func animateIn() {
    guard let window = window else { return }
    frame = window.bounds
    backgroundGlassView.frame = bounds

    // Place bubble at original position first (before layout shifts it)
    bubbleSnapshot.frame = originalBubbleFrame
    bubbleSnapshot.alpha = 1

    layoutIfNeeded()

    // Compute final layout (this shifts the bubble)
    let finalBubbleFrame = layoutMenus()
    let isRightAligned = bubbleIsMe || finalBubbleFrame.midX > bounds.midX
    let pickerFinalFrame = reactionPicker.frame
    let menuFinalFrame = contextMenu.frame

    // Keep interactions disabled briefly so the long-press release does not
    // immediately dismiss/select while the menu is animating in.
    let now = CACurrentMediaTime()
    ignoreBackgroundTapUntil = now + 0.65
    reactionPicker.isUserInteractionEnabled = false
    contextMenu.isUserInteractionEnabled = false
    enableControlsWorkItem?.cancel()
    let enableWork = DispatchWorkItem { [weak self] in
      guard let self = self, !self.isDismissing else { return }
      self.reactionPicker.isUserInteractionEnabled = true
      self.contextMenu.isUserInteractionEnabled = true
      self.holdDebugLog("controls enabled")
    }
    enableControlsWorkItem = enableWork
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: enableWork)
    holdDebugLog(
      "animateIn arm interactions now=\(String(format: "%.3f", now)) until=\(String(format: "%.3f", ignoreBackgroundTapUntil))"
    )

    // --- Bubble: continue from the cell's settled sink (0.95) — the menus
    // morph out of that state on the SAME spring, so nothing pops.
    let startCenter = CGPoint(x: originalBubbleFrame.midX, y: originalBubbleFrame.midY)
    let endCenter = CGPoint(x: finalBubbleFrame.midX, y: finalBubbleFrame.midY)
    bubbleSnapshot.bounds = CGRect(origin: .zero, size: originalBubbleFrame.size)
    bubbleSnapshot.center = startCenter
    bubbleSnapshot.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
    holdDebugLog(
      "animateIn start frame=\(NSCoder.string(for: originalBubbleFrame)) startCenter=\(NSCoder.string(for: startCenter)) endCenter=\(NSCoder.string(for: endCenter))"
    )

    // Anchor X is biased toward the bubble side but never pinned to the corner:
    // a 0/1 anchor with a small birth scale makes the far edge sweep almost the
    // whole width — that read as the menu "entering from the side" instead of
    // growing. A soft bias keeps the left/right identity while both edges
    // expand outward, so the motion reads as scale-up, not lateral entry.
    let pickerAnchorX: CGFloat = isRightAligned ? 0.65 : 0.35
    let menuAnchorX: CGFloat = isRightAligned ? 0.6 : 0.4

    // --- Reaction picker: bottom edge pinned just above the bubble, growing
    // upward/outward; the directional cue comes from the emoji cascade.
    reactionPicker.frame = pickerFinalFrame
    setAnchorPoint(CGPoint(x: pickerAnchorX, y: 1.0), for: reactionPicker)
    let pickerFinalCenter = reactionPicker.center
    reactionPicker.center = CGPoint(
      x: pickerFinalCenter.x,
      y: originalBubbleFrame.minY - 8
    )
    reactionPicker.transform = CGAffineTransform(
      scaleX: chatContextMenuCollapsedScale, y: chatContextMenuCollapsedScale)
    reactionPicker.alpha = 0

    // --- Context menu: top edge pinned under the bubble, scaling up in place
    // as it pours downward — no horizontal travel.
    contextMenu.frame = menuFinalFrame
    setAnchorPoint(CGPoint(x: menuAnchorX, y: 0.0), for: contextMenu)
    let menuFinalCenter = contextMenu.center
    contextMenu.center = CGPoint(
      x: menuFinalCenter.x,
      y: originalBubbleFrame.maxY + 4
    )
    contextMenu.transform = CGAffineTransform(
      scaleX: chatContextMenuCollapsedScale, y: chatContextMenuCollapsedScale)
    contextMenu.alpha = 1

    // Only the blur picker fades; the glass card stays at one resolved opacity.
    let fadeAnimator = UIViewPropertyAnimator(duration: 0.12, curve: .easeOut) {
      self.reactionPicker.alpha = 1
    }
    // One under-damped spring drives bubble, picker, and menu together: both
    // menus grow out of the bubble's edges with a visible expansion overshoot.
    let springAnimator = UIViewPropertyAnimator(duration: 0.38, dampingRatio: 0.78) {
      self.bubbleSnapshot.transform = .identity
      self.bubbleSnapshot.center = endCenter
      self.reactionPicker.transform = .identity
      self.reactionPicker.center = pickerFinalCenter
      self.contextMenu.transform = .identity
      self.contextMenu.center = menuFinalCenter
    }
    fadeAnimator.startAnimation()
    springAnimator.startAnimation()
    // Emoji tiles cascade in from the anchored side while the pill grows.
    reactionPicker.animateIconsIn(fromTrailing: isRightAligned)
  }

  func animateOut(reason: String = "unknown", completion: (() -> Void)? = nil) {
    if isDismissing {
      completion?()
      return
    }
    isDismissing = true
    enableControlsWorkItem?.cancel()
    enableControlsWorkItem = nil
    reactionPicker.isUserInteractionEnabled = false
    contextMenu.isUserInteractionEnabled = false
    holdDebugLog("animateOut start reason=\(reason)")

    // Inverse of the open morph: menus collapse back toward their bubble-edge
    // anchors while the bubble returns to its row slot.
    UIView.animate(
      withDuration: 0.18, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]
    ) {
      self.reactionPicker.alpha = 0
      self.bubbleSnapshot.transform = .identity
      self.bubbleSnapshot.bounds = CGRect(origin: .zero, size: self.originalBubbleFrame.size)
      self.bubbleSnapshot.center = CGPoint(
        x: self.originalBubbleFrame.midX,
        y: self.originalBubbleFrame.midY
      )
      self.contextMenu.transform = CGAffineTransform(
        scaleX: chatContextMenuCollapsedScale, y: chatContextMenuCollapsedScale)
      self.contextMenu.center = CGPoint(
        x: self.contextMenu.center.x,
        y: self.originalBubbleFrame.maxY + 4
      )
      self.reactionPicker.transform = CGAffineTransform(
        scaleX: chatContextMenuCollapsedScale, y: chatContextMenuCollapsedScale)
      self.reactionPicker.center = CGPoint(
        x: self.reactionPicker.center.x,
        y: self.originalBubbleFrame.minY - 8
      )
    } completion: { _ in
      self.contextMenu.isHidden = true
      self.reactionPicker.isHidden = true
      UIView.animate(
        withDuration: 0.10, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]
      ) {
        self.backgroundGlassView.alpha = 0
      } completion: { _ in
        self.removeFromSuperview()
        self.delegate?.contextMenuDidDismiss(overlay: self)
        completion?()
      }
    }
  }
}

// MARK: - UIGestureRecognizerDelegate

extension ChatContextMenuOverlay: UIGestureRecognizerDelegate {
  public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer)
    -> Bool
  {
    if isSelectingReaction { return false }
    let now = CACurrentMediaTime()
    if now < ignoreBackgroundTapUntil {
      holdDebugLog(
        "gestureShouldBegin ignored now=\(String(format: "%.3f", now)) until=\(String(format: "%.3f", ignoreBackgroundTapUntil))"
      )
      return false
    }
    let point = gestureRecognizer.location(in: self)
    // Only dismiss if tap is outside the bubble, picker, and menu
    if bubbleSnapshot.frame.contains(point) { return false }
    if reactionPicker.frame.contains(point) { return false }
    if contextMenu.frame.contains(point) { return false }
    return true
  }
}

// MARK: - ChatContextMenuOverlayDelegate (self-forwarding)

extension ChatContextMenuOverlay: ChatContextMenuOverlayDelegate {
  public func contextMenuDidDismiss(overlay: ChatContextMenuOverlay) {}

  public func contextMenuDidSelectReaction(
    _ reaction: String,
    messageId _: String,
    sourcePoint: CGPoint?
  ) {
    guard !isDismissing, !isSelectingReaction else { return }
    isSelectingReaction = true

    reactionPicker.isUserInteractionEnabled = false
    contextMenu.isUserInteractionEnabled = false

    // Prefer the tapped icon's window point; list coordinator owns the only flight.
    let sourceInWindow: CGPoint = {
      if let sourcePoint { return sourcePoint }
      let fallback = CGPoint(
        x: reactionPicker.frame.midX,
        y: reactionPicker.frame.minY + (reactionPicker.frame.height * 0.4)
      )
      return convert(fallback, to: nil)
    }()
    let captureMessageId = self.messageId

    delegate?.contextMenuDidSelectReaction(
      reaction,
      messageId: captureMessageId,
      sourcePoint: sourceInWindow
    )

    animateOut(reason: "reactionSelected") {
      self.isSelectingReaction = false
    }
  }

  public func contextMenuDidSelectAction(_ actionId: String, messageId _: String) {
    delegate?.contextMenuDidSelectAction(actionId, messageId: messageId)
  }
}

// MARK: - Reaction Picker View

final class ChatReactionIconNode: UIControl {
  let emoji: String
  private let label = UILabel()

  init(emoji: String) {
    self.emoji = emoji
    super.init(frame: .zero)
    label.text = emoji
    label.font = UIFont.systemFont(ofSize: 28)
    label.textAlignment = .center
    label.isUserInteractionEnabled = false
    addSubview(label)
    accessibilityLabel = emoji
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    label.frame = bounds
  }

  func playIntro(delay: TimeInterval) {
    alpha = 0.0
    transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
    UIView.animate(
      withDuration: 0.34, delay: delay, usingSpringWithDamping: 0.68,
      initialSpringVelocity: 0.0, options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.alpha = 1.0
      self.transform = .identity
    }
  }

  func playSelectionEffect() {
    // Pulse only — list coordinator owns flight and landing FX.
    UIView.animate(
      withDuration: 0.12, delay: 0.0, options: [.curveEaseIn, .beginFromCurrentState]
    ) {
      self.transform = CGAffineTransform(scaleX: 1.28, y: 1.28)
    } completion: { _ in
      UIView.animate(withDuration: 0.18, delay: 0.0, options: .curveEaseOut) {
        self.transform = .identity
      }
    }
  }
}

final class ReactionPickerView: UIView {
  weak var delegate: ChatContextMenuOverlayDelegate?
  /// Called inside expand/collapse animation so the overlay can relayout safely.
  var onContentSizeChange: (() -> Void)?

  private let blurView: UIVisualEffectView
  private let blurTintView = UIView()
  private let tailBlobLarge: UIVisualEffectView
  private let tailBlobSmall: UIVisualEffectView
  private let iconsHost = UIView()
  private var iconNodes: [ChatReactionIconNode] = []
  private let expandControl = UIButton(type: .system)
  private var blurHeightConstraint: NSLayoutConstraint!
  private var isExpanded = false
  private var blobsOnRightSide = false

  private static let pickerButtonSize: CGFloat = 40.0
  private static let pickerSpacing: CGFloat = 4.0
  private static let pickerPadding: CGFloat = 8.0
  private static let pickerPillHeight: CGFloat = 52.0
  private static let pickerTailHeight: CGFloat = 12.0
  private static let pickerVerticalInset: CGFloat = 6.0

  let messageId: String

  private var gridColumns: Int {
    max(1, ChatReactionCatalog.collapsedEmojis.count + 1)
  }

  private var contentRowCount: Int {
    let primary = ChatReactionCatalog.collapsedEmojis.count
    guard isExpanded else { return 1 }
    let remaining = max(0, ChatReactionCatalog.allEmojis.count - primary)
    let extraRows = remaining == 0 ? 0 : Int(ceil(Double(remaining) / Double(gridColumns)))
    return 1 + extraRows
  }

  private var blurContentHeight: CGFloat {
    let rows = CGFloat(contentRowCount)
    let gridH =
      rows * Self.pickerButtonSize
      + max(0, rows - 1) * Self.pickerSpacing
      + Self.pickerVerticalInset * 2.0
    return max(Self.pickerPillHeight, gridH)
  }

  private var preferredWidth: CGFloat {
    let cols = CGFloat(gridColumns)
    return cols * Self.pickerButtonSize
      + max(0, cols - 1) * Self.pickerSpacing
      + Self.pickerPadding * 2.0
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: preferredWidth, height: blurContentHeight + Self.pickerTailHeight)
  }

  init(appearance: ChatListAppearance, messageId: String) {
    self.messageId = messageId
    let blurStyle: UIBlurEffect.Style =
      appearance.isDark ? .systemMaterialDark : .systemMaterialLight
    self.blurView = makeBlurMaterialView(
      style: blurStyle,
      cornerRadius: Self.pickerPillHeight * 0.5
    )
    self.tailBlobLarge = makeBlurMaterialView(
      style: blurStyle,
      cornerRadius: 5.5
    )
    self.tailBlobSmall = makeBlurMaterialView(
      style: blurStyle,
      cornerRadius: 3.5
    )

    super.init(frame: .zero)

    clipsToBounds = false

    blurView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blurView)
    addSubview(tailBlobLarge)
    addSubview(tailBlobSmall)

    blurTintView.backgroundColor = .clear
    blurTintView.translatesAutoresizingMaskIntoConstraints = false
    blurView.contentView.addSubview(blurTintView)

    iconsHost.translatesAutoresizingMaskIntoConstraints = false
    iconsHost.backgroundColor = .clear
    blurView.contentView.addSubview(iconsHost)

    blurHeightConstraint = blurView.heightAnchor.constraint(equalToConstant: Self.pickerPillHeight)

    NSLayoutConstraint.activate([
      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurHeightConstraint,

      blurTintView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
      blurTintView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor),
      blurTintView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
      blurTintView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),

      iconsHost.topAnchor.constraint(
        equalTo: blurView.contentView.topAnchor, constant: Self.pickerVerticalInset),
      iconsHost.bottomAnchor.constraint(
        equalTo: blurView.contentView.bottomAnchor, constant: -Self.pickerVerticalInset),
      iconsHost.leadingAnchor.constraint(
        equalTo: blurView.contentView.leadingAnchor, constant: Self.pickerPadding),
      iconsHost.trailingAnchor.constraint(
        equalTo: blurView.contentView.trailingAnchor, constant: -Self.pickerPadding),
    ])

    tailBlobLarge.bounds = CGRect(x: 0.0, y: 0.0, width: 11.0, height: 11.0)
    tailBlobSmall.bounds = CGRect(x: 0.0, y: 0.0, width: 7.0, height: 7.0)
    tailBlobLarge.layer.borderWidth = 0
    tailBlobSmall.layer.borderWidth = 0

    for emoji in ChatReactionCatalog.allEmojis {
      let node = ChatReactionIconNode(emoji: emoji)
      node.addTarget(self, action: #selector(didTapEmoji(_:)), for: .touchUpInside)
      iconsHost.addSubview(node)
      iconNodes.append(node)
    }

    configureExpandControl(isDark: appearance.isDark)
    iconsHost.addSubview(expandControl)
    applyCollapsedVisibility()
  }

  required init?(coder: NSCoder) { fatalError() }

  private func configureExpandControl(isDark: Bool) {
    let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    expandControl.setImage(UIImage(systemName: "chevron.down", withConfiguration: config), for: .normal)
    expandControl.tintColor = isDark ? UIColor.white.withAlphaComponent(0.72) : .secondaryLabel
    expandControl.backgroundColor = UIColor.label.withAlphaComponent(0.08)
    expandControl.layer.cornerRadius = Self.pickerButtonSize * 0.5
    expandControl.clipsToBounds = true
    expandControl.accessibilityTraits = .button
    expandControl.addTarget(self, action: #selector(didTapExpand), for: .touchUpInside)
    updateExpandControlChrome()
  }

  private func updateExpandControlChrome() {
    let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    let symbol = isExpanded ? "chevron.up" : "chevron.down"
    expandControl.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
    expandControl.accessibilityLabel = isExpanded ? "Show fewer reactions" : "Show more reactions"
    expandControl.accessibilityHint = isExpanded
      ? "Collapses the reaction list"
      : "Expands the full reaction list"
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layoutIconGrid()
    let blurH = blurView.bounds.height
    let largeX = blobsOnRightSide ? (bounds.width - 24.0) : 24.0
    let smallX = blobsOnRightSide ? (bounds.width - 14.0) : 14.0
    tailBlobLarge.center = CGPoint(x: largeX, y: blurH + 1.5)
    tailBlobSmall.center = CGPoint(x: smallX, y: blurH + 9.0)
  }

  private func layoutIconGrid() {
    let button = Self.pickerButtonSize
    let spacing = Self.pickerSpacing
    let cols = gridColumns
    let primaryCount = ChatReactionCatalog.collapsedEmojis.count
    let hostBounds = iconsHost.bounds
    guard hostBounds.width > 0, hostBounds.height > 0 else { return }

    // First row: primary emojis + trailing expand control.
    for index in 0..<primaryCount {
      guard index < iconNodes.count else { break }
      let col = index
      let x = CGFloat(col) * (button + spacing)
      iconNodes[index].frame = CGRect(x: x, y: 0, width: button, height: button)
    }
    let expandCol = min(primaryCount, cols - 1)
    expandControl.frame = CGRect(
      x: CGFloat(expandCol) * (button + spacing),
      y: 0,
      width: button,
      height: button
    )

    guard isExpanded else { return }

    // Extra rows: remaining catalog emojis, width-bounded columns.
    let remaining = iconNodes.dropFirst(primaryCount)
    for (offset, node) in remaining.enumerated() {
      let col = offset % cols
      let row = 1 + offset / cols
      let x = CGFloat(col) * (button + spacing)
      let y = CGFloat(row) * (button + spacing)
      node.frame = CGRect(x: x, y: y, width: button, height: button)
    }
  }

  private func applyCollapsedVisibility() {
    let primaryCount = ChatReactionCatalog.collapsedEmojis.count
    for (index, node) in iconNodes.enumerated() {
      let isPrimary = index < primaryCount
      node.isHidden = !isPrimary
      node.alpha = isPrimary ? 1 : 0
      node.transform = .identity
    }
    updateExpandControlChrome()
    blurHeightConstraint.constant = blurContentHeight
    blurView.layer.cornerRadius = min(blurContentHeight * 0.5, 26)
    invalidateIntrinsicContentSize()
  }

  @objc private func didTapExpand() {
    setExpanded(!isExpanded, animated: true)
  }

  /// Height-morph expand/collapse; new rows spring in with scale/alpha.
  func setExpanded(_ expanded: Bool, animated: Bool) {
    guard expanded != isExpanded else { return }
    isExpanded = expanded
    updateExpandControlChrome()

    let primaryCount = ChatReactionCatalog.collapsedEmojis.count
    let extra = Array(iconNodes.dropFirst(primaryCount))

    if expanded {
      for node in extra {
        node.isHidden = false
        node.alpha = 0
        node.transform = CGAffineTransform(
          scaleX: chatContextMenuCollapsedScale, y: chatContextMenuCollapsedScale)
      }
    }

    invalidateIntrinsicContentSize()
    setNeedsLayout()

    let animations = {
      self.blurHeightConstraint.constant = self.blurContentHeight
      self.blurView.layer.cornerRadius = min(self.blurContentHeight * 0.5, 26)
      self.layoutIfNeeded()
      self.onContentSizeChange?()
      if expanded {
        for node in extra {
          node.alpha = 1
          node.transform = .identity
        }
      } else {
        for node in extra {
          node.alpha = 0
          node.transform = CGAffineTransform(
            scaleX: chatContextMenuCollapsedScale, y: chatContextMenuCollapsedScale)
        }
      }
    }

    if animated {
      UIView.animate(
        withDuration: 0.38,
        delay: 0,
        usingSpringWithDamping: 0.82,
        initialSpringVelocity: 0.2,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: animations
      ) { _ in
        if !expanded {
          for node in extra {
            node.isHidden = true
            node.transform = .identity
          }
        }
      }
    } else {
      animations()
      if !expanded {
        for node in extra {
          node.isHidden = true
          node.transform = .identity
        }
      }
    }
  }

  func setThinkingBlobDirection(isRightAligned: Bool) {
    guard blobsOnRightSide != isRightAligned else { return }
    blobsOnRightSide = isRightAligned
    setNeedsLayout()
  }

  /// Emoji tiles cascade in from the pill's anchored side while it morph-grows.
  func animateIconsIn(fromTrailing: Bool) {
    let primaryCount = min(ChatReactionCatalog.collapsedEmojis.count, iconNodes.count)
    let visible = Array(iconNodes.prefix(primaryCount))
    let ordered = fromTrailing ? Array(visible.reversed()) : visible
    for (index, node) in ordered.enumerated() {
      node.playIntro(delay: 0.05 + 0.04 * Double(index))
    }
    expandControl.alpha = 0
    expandControl.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
    UIView.animate(
      withDuration: 0.34, delay: 0.05 + 0.04 * Double(primaryCount),
      usingSpringWithDamping: 0.68, initialSpringVelocity: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.expandControl.alpha = 1
      self.expandControl.transform = .identity
    }
  }

  @objc private func didTapEmoji(_ sender: ChatReactionIconNode) {
    let emoji = sender.emoji
    sender.playSelectionEffect()
    // Window coordinates for the list coordinator's single flight.
    let sourcePoint = sender.convert(
      CGPoint(x: sender.bounds.midX, y: sender.bounds.midY),
      to: nil
    )
    delegate?.contextMenuDidSelectReaction(emoji, messageId: messageId, sourcePoint: sourcePoint)
  }
}

// MARK: - Context Menu View

final class ContextMenuView: UIView {
  weak var delegate: ChatContextMenuOverlayDelegate?

  private let glassView: UIVisualEffectView
  private let stack: UIStackView

  struct ActionItem {
    let id: String
    let title: String
    let iconName: String
    let isDestructive: Bool
    let isInformational: Bool

    init(
      id: String, title: String, iconName: String, isDestructive: Bool,
      isInformational: Bool = false
    ) {
      self.id = id
      self.title = title
      self.iconName = iconName
      self.isDestructive = isDestructive
      self.isInformational = isInformational
    }
  }

  private let actions: [ActionItem]
  private var showsDeleteConfirmation = false

  let messageId: String

  init(
    appearance: ChatListAppearance,
    messageId: String,
    showResendAction: Bool,
    showRegenerateAction: Bool = false,
    showEditAction: Bool = false,
    showEditedInfo: Bool = false,
    editedAtMs: Int64? = nil,
    showSaveImageAction: Bool = false,
    showCopyLinkAction: Bool = false,
    showForwardAction: Bool = false,
    showReportAction: Bool = false,
    restrictSavingContent: Bool = false,
    failedSendOnly: Bool = false
  ) {
    self.messageId = messageId
    var resolvedActions: [ActionItem] = []
    if showEditedInfo {
      resolvedActions.append(
        ActionItem(
          id: "editedInfo", title: editedAtMs.map(Self.editedTitle) ?? "edited",
          iconName: "clock.arrow.circlepath", isDestructive: false, isInformational: true))
    }
    resolvedActions.append(
      ActionItem(
        id: "reply", title: "Reply", iconName: "arrowshape.turn.up.left", isDestructive: false))
    if !restrictSavingContent {
      resolvedActions.append(
        ActionItem(id: "copy", title: "Copy", iconName: "doc.on.doc", isDestructive: false))
      if showSaveImageAction {
        resolvedActions.append(
          ActionItem(
            id: "saveImage", title: "Save Image", iconName: "square.and.arrow.down",
            isDestructive: false))
      }
      if showCopyLinkAction {
        resolvedActions.append(
          ActionItem(id: "copyLink", title: "Copy Link", iconName: "link", isDestructive: false))
      }
      if showForwardAction {
        resolvedActions.append(
          ActionItem(
            id: "forward", title: "Forward", iconName: "arrowshape.turn.up.right",
            isDestructive: false))
      }
    }
    if showReportAction {
      resolvedActions.append(
        ActionItem(
          id: "report", title: "Report", iconName: "exclamationmark.circle",
          isDestructive: false))
    }
    if showEditAction {
      resolvedActions.append(
        ActionItem(id: "edit", title: "Edit", iconName: "pencil", isDestructive: false)
      )
    }
    if showResendAction {
      resolvedActions.append(
        ActionItem(
          id: "resend",
          title: "Resend",
          iconName: "arrow.clockwise",
          isDestructive: false
        )
      )
    }
    if showRegenerateAction {
      resolvedActions.append(
        ActionItem(
          id: "regenerate",
          title: "Regenerate",
          iconName: "arrow.trianglehead.2.counterclockwise",
          isDestructive: false
        )
      )
    }
    resolvedActions.append(
      ActionItem(id: "delete", title: "Delete", iconName: "trash", isDestructive: true)
    )
    if !restrictSavingContent {
      resolvedActions.append(
        ActionItem(
          id: "select", title: "Select", iconName: "checkmark.circle", isDestructive: false)
      )
    }
    // A message that never left the device has exactly two things you can do with it.
    //
    // Reply, Pin, Copy, Forward and Select all address a message that EXISTS for the
    // other person; offering them on a failed send is offering to act on something that
    // is not there. Send it again, or throw it away. Replaces the whole list rather than
    // filtering it, so the order is deliberate instead of whatever survived.
    self.actions =
      failedSendOnly
      ? [
        ActionItem(
          id: "resend", title: "Resend", iconName: "arrow.clockwise", isDestructive: false),
        ActionItem(id: "delete", title: "Delete", iconName: "trash", isDestructive: true),
      ]
      : resolvedActions
    self.glassView = makeChatContextLiquidGlassView(
      style: appearance.isDark ? .systemMaterialDark : .systemMaterial,
      cornerRadius: 24,
      capsuleCorners: false
    )

    self.stack = UIStackView()

    super.init(frame: .zero)

    glassView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glassView)

    stack.axis = .vertical
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    glassView.contentView.addSubview(stack)

    glassView.layer.borderWidth = 0

    NSLayoutConstraint.activate([
      glassView.topAnchor.constraint(equalTo: topAnchor),
      glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
      glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
      glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.leadingAnchor.constraint(equalTo: glassView.contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: glassView.contentView.trailingAnchor),
    ])
    let stackTop = stack.topAnchor.constraint(
      greaterThanOrEqualTo: glassView.contentView.topAnchor,
      constant: 6
    )
    let stackBottom = stack.bottomAnchor.constraint(
      lessThanOrEqualTo: glassView.contentView.bottomAnchor,
      constant: -6
    )
    let stackCenterY = stack.centerYAnchor.constraint(equalTo: glassView.contentView.centerYAnchor)
    stackTop.priority = .defaultHigh
    stackBottom.priority = .defaultHigh
    stackCenterY.priority = .defaultHigh
    NSLayoutConstraint.activate([stackTop, stackBottom, stackCenterY])

    installActions(actions)
  }

  required init?(coder: NSCoder) { fatalError() }

  private static func editedTitle(_ timestamp: Int64) -> String {
    let seconds = Double(timestamp) / (timestamp > 100_000_000_000 ? 1_000.0 : 1.0)
    let date = Date(timeIntervalSince1970: seconds)
    let time = DateFormatter()
    time.locale = .current
    time.dateStyle = .none
    time.timeStyle = .short
    if Calendar.current.isDateInToday(date) {
      return "edited today at \(time.string(from: date))"
    }
    let day = DateFormatter()
    day.locale = .current
    day.setLocalizedDateFormatFromTemplate("MMM d")
    return "edited \(day.string(from: date)) at \(time.string(from: date))"
  }

  private func installActions(_ actions: [ActionItem]) {
    for arranged in stack.arrangedSubviews {
      stack.removeArrangedSubview(arranged)
      arranged.removeFromSuperview()
    }

    for (index, action) in actions.enumerated() {
      let startsActions = index > 0 && actions[index - 1].isInformational
      if (action.id == "select" || startsActions) && index > 0 {
        let sepContainer = UIView()
        sepContainer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sepContainer)

        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        line.translatesAutoresizingMaskIntoConstraints = false
        sepContainer.addSubview(line)

        let sepHeight = sepContainer.heightAnchor.constraint(
          equalToConstant: 1.0 / UIScreen.main.scale)
        sepHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
          sepHeight,
          line.leadingAnchor.constraint(equalTo: sepContainer.leadingAnchor, constant: 16),
          line.trailingAnchor.constraint(equalTo: sepContainer.trailingAnchor, constant: -16),
          line.topAnchor.constraint(equalTo: sepContainer.topAnchor),
          line.bottomAnchor.constraint(equalTo: sepContainer.bottomAnchor),
        ])
      }
      let row = ContextMenuRow(action: action)
      if !action.isInformational {
        row.addTarget(self, action: #selector(didTapAction(_:)), for: .touchUpInside)
      }
      stack.addArrangedSubview(row)
    }
  }

  /// Telegram-style drill-in: the original rows travel left, the delete choices
  /// enter from the right, and the same glass card changes height around them.
  func transitionToDeleteConfirmation(
    deleteForEveryoneTitle: String?,
    alongsideLayout: @escaping () -> Void
  ) {
    guard !showsDeleteConfirmation else { return }
    showsDeleteConfirmation = true
    layoutIfNeeded()

    let oldRowsSnapshot = stack.snapshotView(afterScreenUpdates: false)
    if let oldRowsSnapshot {
      oldRowsSnapshot.frame = stack.frame
      oldRowsSnapshot.isUserInteractionEnabled = false
      glassView.contentView.addSubview(oldRowsSnapshot)
    }

    var deleteActions: [ActionItem] = []
    if let title = deleteForEveryoneTitle,
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      deleteActions.append(
        ActionItem(
          id: "deleteForEveryone",
          title: title,
          iconName: "",
          isDestructive: true
        ))
    }
    deleteActions.append(
      ActionItem(
        id: "deleteForMe",
        title: "Delete for me",
        iconName: "",
        isDestructive: true
      ))
    installActions(deleteActions)

    let travel = max(bounds.width, 220)
    stack.transform = CGAffineTransform(translationX: travel, y: 0)
    stack.alpha = 0

    UIView.animate(
      withDuration: 0.30,
      delay: 0,
      usingSpringWithDamping: 0.92,
      initialSpringVelocity: 0,
      options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
    ) {
      alongsideLayout()
      self.layoutIfNeeded()
      oldRowsSnapshot?.transform = CGAffineTransform(translationX: -travel, y: 0)
      oldRowsSnapshot?.alpha = 0
      self.stack.transform = .identity
      self.stack.alpha = 1
    } completion: { _ in
      oldRowsSnapshot?.removeFromSuperview()
    }
  }

  @objc private func didTapAction(_ sender: ContextMenuRow) {
    delegate?.contextMenuDidSelectAction(sender.actionId, messageId: messageId)
  }
}

// MARK: - Context Menu Row

final class ContextMenuRow: UIControl {
  let actionId: String
  private let titleLabel: UILabel
  private let iconView: UIImageView
  private let isInformational: Bool

  init(action: ContextMenuView.ActionItem) {
    self.actionId = action.id
    self.titleLabel = UILabel()
    self.iconView = UIImageView()
    self.isInformational = action.isInformational
    super.init(frame: .zero)

    backgroundColor = .clear

    titleLabel.text = action.title
    titleLabel.font = UIFont.systemFont(
      ofSize: action.isInformational ? 15.0 : 17.5,
      weight: action.isInformational ? .medium : .regular)
    titleLabel.textColor = action.isInformational
      ? UIColor.secondaryLabel : (action.isDestructive ? .systemRed : .label)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
    if !action.iconName.isEmpty,
      let image = UIImage(systemName: action.iconName, withConfiguration: config)
    {
      iconView.image = image
      iconView.tintColor = action.isInformational
        ? UIColor.secondaryLabel : (action.isDestructive ? .systemRed : .label)
    } else {
      iconView.isHidden = true
    }
    iconView.contentMode = .scaleAspectFit
    isUserInteractionEnabled = !action.isInformational

    addSubview(titleLabel)
    addSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    iconView.translatesAutoresizingMaskIntoConstraints = false

    let rowHeight = heightAnchor.constraint(equalToConstant: 46)
    rowHeight.priority = .defaultHigh

    NSLayoutConstraint.activate([
      rowHeight,

      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 20),
      iconView.heightAnchor.constraint(equalToConstant: 20),

      titleLabel.leadingAnchor.constraint(
        equalTo: action.iconName.isEmpty ? leadingAnchor : iconView.trailingAnchor,
        constant: action.iconName.isEmpty ? 18 : 14
      ),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isHighlighted: Bool {
    didSet {
      guard !isInformational else { return }
      UIView.animate(withDuration: 0.1) {
        self.backgroundColor =
          self.isHighlighted
          ? UIColor.label.withAlphaComponent(0.08)
          : .clear
      }
    }
  }
}
