import UIKit

private let chatContextHoldDebugLogs = true

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
  interactive: Bool = false,
  // A non-nil tint mutes the glass: pure UIGlassEffect(.regular) REFRACTS moving
  // content behind it (the home preview's scrolling bubbles swam through the
  // menu). A tint gives it a stable, Telegram-style surface that reads through
  // the refraction instead of the live content. Ignored on the < iOS 26 blur.
  glassTint: UIColor? = nil
) -> UIVisualEffectView {
  let view = UIVisualEffectView(effect: nil)
  if #available(iOS 26.0, *) {
    let effect = UIGlassEffect(style: .regular)
    effect.isInteractive = interactive
    if let glassTint { effect.tintColor = glassTint }
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
    restrictSavingContent: Bool = false
  ) {
    self.messageId = messageId
    self.bubbleSnapshot = bubbleSnapshot
    self.deletionBubbleImage = deletionBubbleImage
    self.originalBubbleFrame = bubbleFrame
    self.bubbleIsMe = bubbleIsMe
    self.appearance = appearance

    // Full-screen background: native system glass blur
    let bgStyle: UIBlurEffect.Style =
      appearance.isDark
      ? .systemMaterialDark
      : .systemMaterialLight
    self.backgroundGlassView = UIVisualEffectView(effect: UIBlurEffect(style: bgStyle))

    let colorOverlay = UIView()
    let isDarkMode = appearance.isDark
    let overlayBaseColor: UIColor = .black
    let overlayAlpha: CGFloat = isDarkMode ? 0.38 : 0.28
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
      restrictSavingContent: restrictSavingContent
    )

    super.init(frame: .zero)

    setupViews()
    setupGestures()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupViews() {
    // 1. Full-screen glass background
    backgroundGlassView.alpha = 0
    addSubview(backgroundGlassView)

    // 2. Bubble snapshot (already has correct frame in window coords)
    bubbleSnapshot.alpha = 0
    addSubview(bubbleSnapshot)

    // 3. Reaction picker (above bubble)
    reactionPicker.alpha = 0
    reactionPicker.delegate = self
    let pickerSize = reactionPicker.intrinsicContentSize
    reactionPicker.frame = CGRect(origin: .zero, size: pickerSize)
    addSubview(reactionPicker)

    // 4. Context menu (below or above bubble)
    contextMenu.alpha = 0
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

  private func reactionLandingPointInWindow() -> CGPoint {
    guard let window = self.window else { return .zero }
    let frame = originalBubbleFrame
    let badgeSize = CGSize(width: 34.0, height: 24.0)
    let insetLeft: CGFloat = 8.0
    let insetBottom: CGFloat = 6.0
    let incomingTailInset: CGFloat = bubbleIsMe ? 0.0 : 24.0
    let bodyMinX = frame.minX + incomingTailInset
    let badgeX = min(
      max(bodyMinX + insetLeft, bodyMinX + 2.0),
      frame.maxX - badgeSize.width - 4.0
    )
    let pointInOverlay = CGPoint(
      x: badgeX + (badgeSize.width * 0.5),
      y: frame.maxY - insetBottom - (badgeSize.height * 0.5)
    )
    return self.convert(pointInOverlay, to: window)
  }

  // MARK: - Layout

  private func layoutMenus() -> CGRect {
    let safeTop = safeAreaInsets.top + 10
    let safeBottom = bounds.height - safeAreaInsets.bottom - 10
    let safeLeft: CGFloat = 16
    let safeRight = bounds.width - 16

    // Measure reaction picker
    let pickerSize = reactionPicker.intrinsicContentSize
    let pickerHeight = pickerSize.height
    let pickerGap: CGFloat = 8

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

    // --- Background glass fade in ---
    UIView.animate(withDuration: 0.20, delay: 0, options: .curveEaseOut) {
      self.backgroundGlassView.alpha = 1
    }

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
    reactionPicker.transform = CGAffineTransform(scaleX: 0.35, y: 0.35)
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
    contextMenu.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
    contextMenu.alpha = 0

    // Alpha resolves quickly so the entire remaining flight is pure geometry —
    // a small-scale birth with a bouncy spring reads as a morph, never a fade.
    let fadeAnimator = UIViewPropertyAnimator(duration: 0.12, curve: .easeOut) {
      self.reactionPicker.alpha = 1
      self.contextMenu.alpha = 1
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
      self.backgroundGlassView.alpha = 0
      self.reactionPicker.alpha = 0
      self.contextMenu.alpha = 0
      self.bubbleSnapshot.transform = .identity
      self.bubbleSnapshot.bounds = CGRect(origin: .zero, size: self.originalBubbleFrame.size)
      self.bubbleSnapshot.center = CGPoint(
        x: self.originalBubbleFrame.midX,
        y: self.originalBubbleFrame.midY
      )
      self.contextMenu.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
      self.contextMenu.center = CGPoint(
        x: self.contextMenu.center.x,
        y: self.originalBubbleFrame.maxY + 4
      )
      self.reactionPicker.transform = CGAffineTransform(scaleX: 0.35, y: 0.35)
      self.reactionPicker.center = CGPoint(
        x: self.reactionPicker.center.x,
        y: self.originalBubbleFrame.minY - 8
      )
    } completion: { _ in
      self.removeFromSuperview()
      self.delegate?.contextMenuDidDismiss(overlay: self)
      completion?()
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

    let fallbackSource = CGPoint(
      x: reactionPicker.frame.midX,
      y: reactionPicker.frame.minY + (reactionPicker.frame.height * 0.4)
    )
    let sourcePointInView = sourcePoint ?? fallbackSource
    let sourceInWindow = self.convert(sourcePointInView, to: nil)
    let targetInWindow = reactionLandingPointInWindow()

    // Immediately dismiss the menu UI and snap cell back
    self.animateOut(reason: "reactionSelected")

    if let window = self.window {
      let captureMessageId = self.messageId
      ChatReactionFxModule.shared.animateReactionFlight(
        emoji: reaction,
        from: sourceInWindow,
        to: targetInWindow,
        in: window,
        bubbleView: nil
      ) { [weak self] in
        self?.isSelectingReaction = false
        self?.delegate?.contextMenuDidSelectReaction(
          reaction,
          messageId: captureMessageId,
          sourcePoint: targetInWindow
        )
      }
    } else {
      isSelectingReaction = false
      delegate?.contextMenuDidSelectReaction(
        reaction, messageId: self.messageId, sourcePoint: targetInWindow)
    }
  }

  public func contextMenuDidSelectAction(_ actionId: String, messageId _: String) {
    delegate?.contextMenuDidSelectAction(actionId, messageId: messageId)
  }
}

// MARK: - Reaction Picker View

final class ReactionPickerView: UIView {
  weak var delegate: ChatContextMenuOverlayDelegate?

  private let blurView: UIVisualEffectView
  private let blurTintView = UIView()
  private let tailBlobLarge: UIVisualEffectView
  private let tailBlobSmall: UIVisualEffectView
  private let stack: UIStackView
  private let emojis = ["👍", "❤️", "👎", "🔥", "🥰", "👏", "😁"]
  private static let pickerButtonSize: CGFloat = 44.0
  private static let pickerSpacing: CGFloat = 4.0
  private static let pickerPadding: CGFloat = 12.0
  private static let pickerPillHeight: CGFloat = 52.0
  private static let pickerTailHeight: CGFloat = 12.0
  private var blobsOnRightSide = false

  let messageId: String

  override var intrinsicContentSize: CGSize {
    let emojiCount = CGFloat(emojis.count)
    let width =
      emojiCount * Self.pickerButtonSize
      + (emojiCount - 1.0) * Self.pickerSpacing
      + Self.pickerPadding * 2.0
    return CGSize(width: width, height: Self.pickerPillHeight + Self.pickerTailHeight)
  }

  init(appearance: ChatListAppearance, messageId: String) {
    self.messageId = messageId
    let blurStyle: UIBlurEffect.Style =
      appearance.isDark ? .systemMaterialDark : .systemMaterialLight
    self.blurView = makeChatContextLiquidGlassView(
      style: blurStyle,
      cornerRadius: Self.pickerPillHeight * 0.5,
      capsuleCorners: true
    )
    self.tailBlobLarge = makeChatContextLiquidGlassView(
      style: blurStyle,
      cornerRadius: 5.5,
      capsuleCorners: false
    )
    self.tailBlobSmall = makeChatContextLiquidGlassView(
      style: blurStyle,
      cornerRadius: 3.5,
      capsuleCorners: false
    )
    self.stack = UIStackView()

    super.init(frame: .zero)

    clipsToBounds = false

    blurView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blurView)
    addSubview(tailBlobLarge)
    addSubview(tailBlobSmall)

    stack.axis = .horizontal
    stack.distribution = .fillEqually
    stack.spacing = Self.pickerSpacing
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false

    blurTintView.backgroundColor = .clear
    blurTintView.translatesAutoresizingMaskIntoConstraints = false
    blurView.contentView.addSubview(blurTintView)

    // Add stack to blur view's contentView so it renders above the blur.
    blurView.contentView.addSubview(stack)

    let stackTop = stack.topAnchor.constraint(
      greaterThanOrEqualTo: blurView.contentView.topAnchor,
      constant: 4
    )
    let stackBottom = stack.bottomAnchor.constraint(
      lessThanOrEqualTo: blurView.contentView.bottomAnchor,
      constant: -4
    )
    let stackCenterY = stack.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor)
    stackTop.priority = .defaultHigh
    stackBottom.priority = .defaultHigh
    stackCenterY.priority = .defaultHigh

    NSLayoutConstraint.activate([
      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.heightAnchor.constraint(equalToConstant: Self.pickerPillHeight),

      blurTintView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
      blurTintView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor),
      blurTintView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
      blurTintView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),

      stackTop,
      stackBottom,
      stackCenterY,
      stack.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -12),
    ])

    tailBlobLarge.bounds = CGRect(x: 0.0, y: 0.0, width: 11.0, height: 11.0)
    tailBlobSmall.bounds = CGRect(x: 0.0, y: 0.0, width: 7.0, height: 7.0)
    tailBlobLarge.layer.borderWidth = 0
    tailBlobSmall.layer.borderWidth = 0

    for emoji in emojis {
      let btn = UIButton(type: .system)
      btn.setTitle(emoji, for: .normal)
      btn.titleLabel?.font = UIFont.systemFont(ofSize: 28)
      btn.translatesAutoresizingMaskIntoConstraints = false
      let width = btn.widthAnchor.constraint(equalToConstant: Self.pickerButtonSize)
      width.priority = .defaultHigh
      width.isActive = true
      let height = btn.heightAnchor.constraint(equalToConstant: Self.pickerButtonSize)
      height.priority = .defaultHigh
      height.isActive = true
      btn.addTarget(self, action: #selector(didTapEmoji(_:)), for: .touchUpInside)
      stack.addArrangedSubview(btn)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    let largeX = blobsOnRightSide ? (bounds.width - 24.0) : 24.0
    let smallX = blobsOnRightSide ? (bounds.width - 14.0) : 14.0
    let largeCenter = CGPoint(x: largeX, y: Self.pickerPillHeight + 1.5)
    let smallCenter = CGPoint(x: smallX, y: Self.pickerPillHeight + 9.0)
    tailBlobLarge.center = largeCenter
    tailBlobSmall.center = smallCenter
  }

  func setThinkingBlobDirection(isRightAligned: Bool) {
    guard blobsOnRightSide != isRightAligned else { return }
    blobsOnRightSide = isRightAligned
    setNeedsLayout()
  }

  /// Emoji tiles cascade in from the pill's anchored side while it morph-grows:
  /// each springs up from a small scale, staggered in the growth direction.
  func animateIconsIn(fromTrailing: Bool) {
    let buttons = fromTrailing ? Array(stack.arrangedSubviews.reversed()) : stack.arrangedSubviews
    for (index, button) in buttons.enumerated() {
      button.alpha = 0
      button.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
      UIView.animate(
        withDuration: 0.34,
        delay: 0.05 + 0.04 * Double(index),
        usingSpringWithDamping: 0.68,
        initialSpringVelocity: 0,
        options: [.beginFromCurrentState, .allowUserInteraction]
      ) {
        button.alpha = 1
        button.transform = .identity
      }
    }
  }

  @objc private func didTapEmoji(_ sender: UIButton) {
    guard let emoji = sender.title(for: .normal) else { return }
    // Spring bounce on tap
    UIView.animate(
      withDuration: 0.12, delay: 0, options: .curveEaseIn,
      animations: { sender.transform = CGAffineTransform(scaleX: 1.3, y: 1.3) }
    ) { _ in
      UIView.animate(withDuration: 0.18, delay: 0, options: .curveEaseOut) {
        sender.transform = .identity
      }
    }
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
    restrictSavingContent: Bool = false
  ) {
    self.messageId = messageId
    var resolvedActions: [ActionItem] = [
      ActionItem(
        id: "reply", title: "Reply", iconName: "arrowshape.turn.up.left", isDestructive: false),
      ActionItem(id: "pin", title: "Pin", iconName: "pin", isDestructive: false),
    ]
    if !restrictSavingContent {
      resolvedActions.insert(
        ActionItem(id: "copy", title: "Copy", iconName: "doc.on.doc", isDestructive: false),
        at: 1
      )
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
    self.actions = resolvedActions
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

  private func installActions(_ actions: [ActionItem]) {
    for arranged in stack.arrangedSubviews {
      stack.removeArrangedSubview(arranged)
      arranged.removeFromSuperview()
    }

    for (index, action) in actions.enumerated() {
      if action.id == "select" && index > 0 {
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
      row.addTarget(self, action: #selector(didTapAction(_:)), for: .touchUpInside)
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

  init(action: ContextMenuView.ActionItem) {
    self.actionId = action.id
    self.titleLabel = UILabel()
    self.iconView = UIImageView()
    super.init(frame: .zero)

    backgroundColor = .clear

    titleLabel.text = action.title
    titleLabel.font = UIFont.systemFont(ofSize: 17.5, weight: .regular)
    titleLabel.textColor = action.isDestructive ? .systemRed : .label
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
    if !action.iconName.isEmpty,
      let image = UIImage(systemName: action.iconName, withConfiguration: config)
    {
      iconView.image = image
      iconView.tintColor = action.isDestructive ? .systemRed : .label
    } else {
      iconView.isHidden = true
    }
    iconView.contentMode = .scaleAspectFit

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
      UIView.animate(withDuration: 0.1) {
        self.backgroundColor =
          self.isHighlighted
          ? UIColor.label.withAlphaComponent(0.08)
          : .clear
      }
    }
  }
}
