import Combine
import PencilKit
import SwiftUI
import UIKit

/// Full-screen image open + markup (PencilKit draw, text, stickers).
/// Opaque black canvas — never shows chat cells underneath.
final class ChatImageEditViewController: UIViewController, UITextFieldDelegate,
  UIGestureRecognizerDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
  PKCanvasViewDelegate
{
  private let messageId: String?
  private var mediaURL: String
  private let initialImage: UIImage?
  private let initialCaption: String
  private let headerTitleText: String
  private let dismissPresenterOnSend: Bool
  private let startInEditMode: Bool
  private var captionText: String
  private var galleryPages: [ChatImageEditGalleryPage]
  private var galleryIndex: Int

  var onAction: ((ChatImageEditActionPayload) -> Void)?

  // MARK: Canvas

  private let stageView = UIView()
  private let renderSurfaceView = UIView()
  private let imageView = UIImageView()
  private let canvasView = PKCanvasView()
  private let overlayContainer = UIView()

  // MARK: AI edit

  private let aiSelectionView = ChatImageAISelectionView()
  /// Images replaced by an AI edit, newest last — powers the Undo chip.
  private var aiUndoStack: [UIImage] = []
  private var aiTask: Task<Void, Never>?

  // MARK: Top chrome

  private let topContainer = UIView()
  private let closeGlass = UIVisualEffectView(effect: nil)
  private let clearAllGlass = UIVisualEffectView(effect: nil)
  private let editGlass = UIVisualEffectView(effect: nil)
  private let closeButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let editButton = UIButton(type: .system)
  private let sendButton = UIButton(type: .system)
  private let clearAllButton = UIButton(type: .system)

  // MARK: Bottom

  private let bottomContainer = UIView()
  private let captionField = UITextField()
  private let markupModel = ChatImageMarkupModel()
  private lazy var markupHost = ChatImageMarkupToolbarHost(model: markupModel)
  private let viewerBarHost = ChatImageViewerBottomBarHost()
  private var markupCancellable: AnyCancellable?

  /// Sticker/GIF library (reuse chat GIF panel — not a custom emoji tray).
  private var gifPanel: ChatGifPanelView?
  private let gifPanelContainer = UIView()
  private let gifGrabber = UIView()
  private var isGifPanelVisible = false
  /// 0…1 expand factor; 0 = default height, 1 = nearly full.
  private var gifPanelExpand: CGFloat = 0
  private var gifPanStartExpand: CGFloat = 0

  /// Inline text entry overlay (Cancel / Done flow).
  private var isTextEntryActive = false
  private let textDimView = UIView()
  private let textEntryField = UITextField()
  private let textCancelButton = UIButton(type: .system)
  private let textDoneButton = UIButton(type: .system)
  private weak var editingTextShell: MarkupTextShellView?

  // MARK: Filmstrip

  private let filmstripLayout = UICollectionViewFlowLayout()
  private lazy var filmstrip: UICollectionView = {
    filmstripLayout.scrollDirection = .horizontal
    filmstripLayout.minimumLineSpacing = 8
    filmstripLayout.itemSize = CGSize(width: 52, height: 52)
    let cv = UICollectionView(frame: .zero, collectionViewLayout: filmstripLayout)
    cv.backgroundColor = .clear
    cv.showsHorizontalScrollIndicator = false
    cv.dataSource = self
    cv.delegate = self
    cv.register(
      ChatImageEditFilmstripCell.self,
      forCellWithReuseIdentifier: ChatImageEditFilmstripCell.reuseId)
    cv.isHidden = true
    return cv
  }()

  private var remoteImageTask: URLSessionDataTask?
  private var originalImage: UIImage?
  private var isHighQuality = false
  private var keyboardHeight: CGFloat = 0
  private var isMarkupActive = false
  private var undoManagerProxy = UndoManager()

  private var showsFilmstrip: Bool { galleryPages.count > 1 }

  // MARK: Init

  init(
    messageId: String?,
    mediaURL: String,
    initialImage: UIImage?,
    initialCaption: String?,
    headerTitle: String?,
    dismissPresenterOnSend: Bool,
    galleryPages: [ChatImageEditGalleryPage] = [],
    startIndex: Int = 0,
    startInEditMode: Bool = false
  ) {
    self.messageId = messageId
    let pages: [ChatImageEditGalleryPage] = {
      if galleryPages.count > 1 { return galleryPages }
      if !galleryPages.isEmpty { return galleryPages }
      return [ChatImageEditGalleryPage(mediaURL: mediaURL, image: initialImage)]
    }()
    self.galleryPages = pages
    let idx = max(0, min(startIndex, max(0, pages.count - 1)))
    self.galleryIndex = idx
    let page = pages[idx]
    self.mediaURL = page.mediaURL.isEmpty ? mediaURL : page.mediaURL
    self.initialImage = page.image ?? initialImage
    // Do NOT prefill bubble message text as caption — user adds caption only if they want.
    let _ = initialCaption
    self.initialCaption = ""
    self.captionText = ""
    let normalizedHeaderTitle = headerTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.headerTitleText = normalizedHeaderTitle.isEmpty ? "Photo" : normalizedHeaderTitle
    self.dismissPresenterOnSend = dismissPresenterOnSend
    self.startInEditMode = startInEditMode
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    remoteImageTask?.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    // Solid black — never show chat / message cells underneath.
    view.backgroundColor = .black
    view.isOpaque = true

    stageView.backgroundColor = .black
    stageView.clipsToBounds = true
    view.addSubview(stageView)

    renderSurfaceView.backgroundColor = .black
    renderSurfaceView.clipsToBounds = true
    stageView.addSubview(renderSurfaceView)

    imageView.contentMode = .scaleAspectFit
    imageView.clipsToBounds = true
    imageView.backgroundColor = .black
    // Full-bleed: no letterbox “wrapper” tint on the canvas
    stageView.backgroundColor = .black
    renderSurfaceView.backgroundColor = .clear
    renderSurfaceView.addSubview(imageView)

    canvasView.backgroundColor = .clear
    canvasView.isOpaque = false
    canvasView.drawingPolicy = .anyInput
    canvasView.delegate = self
    canvasView.isUserInteractionEnabled = false
    // Hide default PencilKit tool picker — we use SwiftUI chrome.
    canvasView.overrideUserInterfaceStyle = .dark
    renderSurfaceView.addSubview(canvasView)

    overlayContainer.backgroundColor = .clear
    overlayContainer.isUserInteractionEnabled = true
    renderSurfaceView.addSubview(overlayContainer)

    // Sits on the image at exactly the fitted rect, so its bounds map 1:1 onto
    // the picture. Hidden until the AI tab is selected.
    aiSelectionView.isHidden = true
    aiSelectionView.isUserInteractionEnabled = false
    aiSelectionView.onSelectionChanged = { [weak self] rect in
      guard let self else { return }
      self.markupModel.aiHasSelection = rect != nil
      self.markupHost.refresh()
    }
    renderSurfaceView.addSubview(aiSelectionView)

    setupTopBar()
    setupBottomBar()
    loadImage()
    applyToolFromModel()

    markupCancellable = markupModel.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async {
        self?.applyToolFromModel()
        self?.view.setNeedsLayout()
      }
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillChangeFrame(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification,
      object: nil
    )

    // Long-press image to enter markup (tap Edit also works).
    let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleImageHold(_:)))
    hold.minimumPressDuration = 0.35
    renderSurfaceView.addGestureRecognizer(hold)
    renderSurfaceView.isUserInteractionEnabled = true

    if startInEditMode {
      setMarkupActive(true, animated: false)
    } else {
      setMarkupActive(false, animated: false)
    }
  }

  @objc private func handleImageHold(_ gr: UILongPressGestureRecognizer) {
    guard gr.state == .began, !isMarkupActive else { return }
    setMarkupActive(true, animated: true)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    applyThemeToChrome()
  }

  private func setupTopBar() {
    // Transparent top — glass pills only (matches system Markup screenshots).
    topContainer.backgroundColor = .clear
    view.addSubview(topContainer)

    configureGlassPill(closeGlass, diameter: 40)
    topContainer.addSubview(closeGlass)
    closeButton.setImage(
      UIImage(
        systemName: "chevron.left",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)),
      for: .normal)
    closeButton.tintColor = .white
    closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    closeGlass.contentView.addSubview(closeButton)

    // Center title pill (ref #1 “Saved Messages”)
    titleLabel.text = headerTitleText
    titleLabel.textColor = .white
    titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    titleLabel.textAlignment = .center
    titleLabel.backgroundColor = UIColor.white.withAlphaComponent(0.12)
    titleLabel.layer.cornerRadius = 16
    titleLabel.clipsToBounds = true
    topContainer.addSubview(titleLabel)

    configureGlassPill(clearAllGlass, diameter: 36)
    topContainer.addSubview(clearAllGlass)
    clearAllButton.setTitle("Clear All", for: .normal)
    clearAllButton.setTitleColor(.white, for: .normal)
    clearAllButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    clearAllButton.addTarget(self, action: #selector(handleClearAll), for: .touchUpInside)
    clearAllButton.isHidden = true
    clearAllGlass.contentView.addSubview(clearAllButton)
    clearAllGlass.isHidden = true

    configureGlassPill(editGlass, diameter: 36)
    topContainer.addSubview(editGlass)
    editButton.setTitle("Edit", for: .normal)
    editButton.setTitleColor(.white, for: .normal)
    editButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    editButton.addTarget(self, action: #selector(handleEditToggle), for: .touchUpInside)
    editGlass.contentView.addSubview(editButton)

    sendButton.setImage(
      UIImage(
        systemName: "arrow.up.circle.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)),
      for: .normal)
    sendButton.tintColor = .systemBlue
    sendButton.addTarget(self, action: #selector(handleSend), for: .touchUpInside)
    topContainer.addSubview(sendButton)

    applyThemeToChrome()
  }

  private func configureGlassPill(_ glass: UIVisualEffectView, diameter: CGFloat) {
    glass.clipsToBounds = true
    glass.layer.cornerRadius = diameter * 0.5
    glass.layer.cornerCurve = .continuous
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = true
      glass.effect = effect
    } else {
      glass.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    }
    glass.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
  }

  private func setupBottomBar() {
    bottomContainer.backgroundColor = .black
    view.addSubview(bottomContainer)

    // View-mode bar: share · edit · delete (ref #1)
    viewerBarHost.onShare = { [weak self] in self?.handleShare() }
    viewerBarHost.onEdit = { [weak self] in self?.setMarkupActive(true, animated: true) }
    viewerBarHost.onDelete = { [weak self] in self?.handleClose() }
    bottomContainer.addSubview(viewerBarHost)

    captionField.isHidden = true
    captionField.delegate = self
    bottomContainer.addSubview(captionField)
    bottomContainer.addSubview(filmstrip)

    markupHost.onCancel = { [weak self] in
      self?.hideGifPanel()
      self?.endTextEntry(commit: false)
      self?.handleClearAll()
      self?.setMarkupActive(false, animated: true)
    }
    markupHost.onConfirm = { [weak self] in
      guard let self else { return }
      self.hideGifPanel()
      self.endTextEntry(commit: true)
      if self.hasVisualEdits() {
        self.handleSend()
      } else {
        self.setMarkupActive(false, animated: true)
      }
    }
    markupHost.onColorWheel = { [weak self] in self?.presentSystemColorPicker() }
    markupHost.onAddText = { [weak self] in self?.beginTextEntry() }
    markupHost.onOpenStickers = { [weak self] in self?.showGifPanel() }
    markupHost.onPickShape = { [weak self] kind in self?.addShape(kind) }
    markupHost.onAIGenerate = { [weak self] in self?.handleAIGenerate() }
    markupHost.onAIClearSelection = { [weak self] in self?.aiSelectionView.clearSelection() }
    markupHost.onAIUndo = { [weak self] in self?.handleAIUndo() }
    bottomContainer.addSubview(markupHost)
    markupHost.isHidden = true

    // GIF / sticker panel — starts off-screen bottom, slides up.
    gifPanelContainer.backgroundColor = UIColor(white: 0.12, alpha: 1)
    gifPanelContainer.isHidden = true
    gifPanelContainer.layer.cornerRadius = 18
    gifPanelContainer.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    gifPanelContainer.clipsToBounds = true
    view.addSubview(gifPanelContainer)

    gifGrabber.backgroundColor = UIColor.white.withAlphaComponent(0.35)
    gifGrabber.layer.cornerRadius = 2.5
    gifGrabber.isUserInteractionEnabled = true
    gifPanelContainer.addSubview(gifGrabber)
    // Grabber-only pan so scrolling inside the GIF panel still works.
    let grabPan = UIPanGestureRecognizer(target: self, action: #selector(handleGifGrabPan(_:)))
    gifGrabber.addGestureRecognizer(grabPan)

    // Dim backdrop while typing text (ref #1)
    textDimView.backgroundColor = UIColor.black.withAlphaComponent(0.45)
    textDimView.isHidden = true
    textDimView.alpha = 0
    view.addSubview(textDimView)

    // Text entry Cancel / Done — glass pills
    for b in [textCancelButton, textDoneButton] {
      b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
      b.setTitleColor(.white, for: .normal)
      b.isHidden = true
      if #available(iOS 26.0, *) {
        // glass configured in layout
      }
      b.backgroundColor = UIColor.white.withAlphaComponent(0.16)
      b.layer.cornerRadius = 18
      b.clipsToBounds = true
      topContainer.addSubview(b)
    }
    textCancelButton.setTitle("  Cancel  ", for: .normal)
    textDoneButton.setTitle("  Done  ", for: .normal)
    textCancelButton.addTarget(self, action: #selector(handleTextCancel), for: .touchUpInside)
    textDoneButton.addTarget(self, action: #selector(handleTextDone), for: .touchUpInside)

    textEntryField.isHidden = true
    textEntryField.textAlignment = .center
    textEntryField.textColor = .white
    textEntryField.font = .systemFont(ofSize: 28, weight: .bold)
    textEntryField.backgroundColor = .clear
    textEntryField.returnKeyType = .done
    textEntryField.delegate = self
    textEntryField.keyboardAppearance = .dark
    textEntryField.tintColor = .white
    textEntryField.autocorrectionType = .yes
    installTextKeyboardAccessory()
    view.addSubview(textEntryField)
  }

  private func installTextKeyboardAccessory() {
    let host = UIHostingController(
      rootView: ChatImageTextKeyboardBar(
        model: markupModel,
        onColor: { [weak self] in self?.presentSystemColorPicker() },
        onEmoji: { [weak self] in
          self?.textEntryField.resignFirstResponder()
          // Re-focus with emoji keyboard is OS-controlled; open sticker panel as fallback.
          self?.showGifPanel()
        }
      ))
    host.view.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 48)
    host.view.backgroundColor = .clear
    textEntryField.inputAccessoryView = host.view
  }

  private func applyThemeToChrome() {
    // Top is glass-only; no solid bar fill so the image/canvas shows through.
    topContainer.backgroundColor = .clear
  }

  private func presentSystemColorPicker() {
    if #available(iOS 14.0, *) {
      let picker = UIColorPickerViewController()
      picker.selectedColor = markupModel.uiColor
      picker.supportsAlpha = true
      picker.delegate = self
      picker.modalPresentationStyle = .pageSheet
      if let sheet = picker.sheetPresentationController {
        sheet.detents = [.medium(), .large()]
        sheet.prefersGrabberVisible = true
      }
      present(picker, animated: true)
    }
  }

  // MARK: Layout

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let safe = view.safeAreaInsets
    let w = view.bounds.width
    let h = view.bounds.height

    let topH = safe.top + 52
    topContainer.frame = CGRect(x: 0, y: 0, width: w, height: topH)

    // Glass back
    closeGlass.frame = CGRect(x: 14, y: safe.top + 4, width: 40, height: 40)
    closeButton.frame = closeGlass.contentView.bounds

    editGlass.isHidden = true
    editButton.isHidden = true
    sendButton.isHidden = true

    if isTextEntryActive {
      clearAllGlass.isHidden = true
      titleLabel.isHidden = true
      closeGlass.isHidden = true
      textCancelButton.isHidden = false
      textDoneButton.isHidden = false
      textCancelButton.sizeToFit()
      textDoneButton.sizeToFit()
      let cancelW = max(84, textCancelButton.bounds.width + 28)
      let doneW = max(72, textDoneButton.bounds.width + 28)
      textCancelButton.frame = CGRect(x: 14, y: safe.top + 6, width: cancelW, height: 36)
      textDoneButton.frame = CGRect(x: w - 14 - doneW, y: safe.top + 6, width: doneW, height: 36)
    } else if isMarkupActive {
      textCancelButton.isHidden = true
      textDoneButton.isHidden = true
      closeGlass.isHidden = false
      titleLabel.isHidden = true
      clearAllGlass.isHidden = false
      clearAllButton.isHidden = false
      clearAllButton.sizeToFit()
      let clearW = max(96, clearAllButton.bounds.width + 28)
      clearAllGlass.frame = CGRect(
        x: w - 14 - clearW, y: safe.top + 6, width: clearW, height: 36)
      clearAllGlass.layer.cornerRadius = 18
      clearAllButton.frame = clearAllGlass.contentView.bounds
    } else {
      textCancelButton.isHidden = true
      textDoneButton.isHidden = true
      closeGlass.isHidden = false
      clearAllGlass.isHidden = true
      titleLabel.isHidden = false
      // Title pill centered
      let titleW = min(w - 120, max(140, headerTitleText.size(withAttributes: [
        .font: titleLabel.font as Any
      ]).width + 28))
      titleLabel.frame = CGRect(
        x: (w - titleW) * 0.5, y: safe.top + 6, width: titleW, height: 36)
      // More menu button area uses right glass as empty for now — mirror ref with close only
      sendButton.isHidden = true
    }

    let markupH: CGFloat =
      isMarkupActive ? markupHost.preferredHeight(for: w) : 0
    let viewerH: CGFloat = isMarkupActive ? 0 : viewerBarHost.preferredHeight
    let filmH: CGFloat = (!isMarkupActive && showsFilmstrip) ? 56 : 0
    let baseGifH: CGFloat = min(320, h * 0.42)
    let maxGifH: CGFloat = min(h * 0.78, h - safe.top - 80)
    let gifH: CGFloat =
      isGifPanelVisible
      ? (baseGifH + (maxGifH - baseGifH) * gifPanelExpand)
      : 0
    let bottomContent = isMarkupActive ? markupH : (viewerH + filmH)
    // When GIF is open it replaces the markup strip height visually.
    let bottomTotal: CGFloat = {
      if isGifPanelVisible { return gifH + safe.bottom }
      return bottomContent + safe.bottom
    }()

    bottomContainer.backgroundColor = .black
    if isGifPanelVisible {
      // Hide mode bar under panel; panel owns the bottom.
      bottomContainer.frame = CGRect(x: 0, y: h, width: w, height: bottomContent + safe.bottom)
    } else {
      bottomContainer.frame = CGRect(x: 0, y: h - bottomTotal, width: w, height: bottomTotal)
    }

    if isMarkupActive {
      viewerBarHost.isHidden = true
      markupHost.isHidden = isGifPanelVisible
      filmstrip.isHidden = true
      markupHost.frame = CGRect(x: 0, y: 0, width: w, height: markupH)
    } else {
      markupHost.isHidden = true
      viewerBarHost.isHidden = false
      var y: CGFloat = 0
      if showsFilmstrip {
        filmstrip.isHidden = false
        filmstrip.frame = CGRect(x: 0, y: y, width: w, height: filmH)
        centerFilmstripContentIfNeeded()
        y += filmH
      } else {
        filmstrip.isHidden = true
      }
      viewerBarHost.frame = CGRect(x: 0, y: y, width: w, height: viewerH)
    }

    // GIF panel: full width, bottom-aligned (slide animation sets transform separately)
    if isGifPanelVisible {
      gifPanelContainer.isHidden = false
      let panelH = gifH + safe.bottom
      gifPanelContainer.frame = CGRect(x: 0, y: h - panelH, width: w, height: panelH)
      gifGrabber.frame = CGRect(x: (w - 40) * 0.5, y: 8, width: 40, height: 5)
      gifPanel?.frame = CGRect(x: 0, y: 16, width: w, height: gifH - 8)
    }

    // Canvas: full area between top chrome and bottom bar — no letterbox gap
    let stageTop = topContainer.frame.maxY
    let stageBottom =
      isGifPanelVisible ? gifPanelContainer.frame.minY : bottomContainer.frame.minY
    stageView.frame = CGRect(x: 0, y: stageTop, width: w, height: max(1, stageBottom - stageTop))
    view.bringSubviewToFront(topContainer)
    view.bringSubviewToFront(bottomContainer)
    if isGifPanelVisible { view.bringSubviewToFront(gifPanelContainer) }

    if let image = imageView.image, image.size.width > 1, image.size.height > 1 {
      let rect = fittingRect(container: stageView.bounds, mediaSize: image.size)
      renderSurfaceView.frame = rect
    } else {
      renderSurfaceView.frame = stageView.bounds
    }
    imageView.frame = renderSurfaceView.bounds
    canvasView.frame = renderSurfaceView.bounds
    overlayContainer.frame = renderSurfaceView.bounds
    aiSelectionView.frame = renderSurfaceView.bounds

    textDimView.frame = view.bounds
    if isTextEntryActive {
      textDimView.isHidden = false
      textEntryField.isHidden = false
      // Center field above keyboard
      let kb = max(keyboardHeight, 280)
      let fieldY = max(stageTop + 40, h - kb - 80)
      textEntryField.frame = CGRect(x: 24, y: fieldY, width: w - 48, height: 56)
      view.bringSubviewToFront(textDimView)
      view.bringSubviewToFront(topContainer)
      view.bringSubviewToFront(textEntryField)
    } else {
      textDimView.isHidden = true
      textEntryField.isHidden = true
    }
  }

  private func fittingRect(container: CGRect, mediaSize: CGSize) -> CGRect {
    let scale = min(
      container.width / max(mediaSize.width, 1),
      container.height / max(mediaSize.height, 1))
    let fitted = CGSize(width: mediaSize.width * scale, height: mediaSize.height * scale)
    return CGRect(
      x: container.minX + (container.width - fitted.width) * 0.5,
      y: container.minY + (container.height - fitted.height) * 0.5,
      width: fitted.width,
      height: fitted.height
    )
  }

  // MARK: Markup mode

  private func setMarkupActive(_ active: Bool, animated: Bool) {
    isMarkupActive = active
    markupModel.isEditing = active
    if active {
      markupModel.mode = .draw
    } else {
      hideGifPanel()
      endTextEntry(commit: false)
    }
    canvasView.isUserInteractionEnabled = active && markupModel.mode == .draw
    overlayContainer.isUserInteractionEnabled = active
    applyToolFromModel()
    markupHost.refresh()

    let changes = {
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    }
    if animated {
      UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseInOut], animations: changes)
    } else {
      changes()
    }
  }

  private func applyToolFromModel() {
    guard isMarkupActive else {
      canvasView.isUserInteractionEnabled = false
      setAISelectionActive(false)
      return
    }
    switch markupModel.mode {
    case .draw:
      setAISelectionActive(false)
      canvasView.isUserInteractionEnabled = true
      overlayContainer.isUserInteractionEnabled = false
      if markupModel.drawTool == .eraser {
        canvasView.tool = PKEraserTool(.vector)
      } else {
        canvasView.tool = markupModel.makeInk()
      }
    case .text, .sticker:
      setAISelectionActive(false)
      canvasView.isUserInteractionEnabled = false
      overlayContainer.isUserInteractionEnabled = true
    case .ai:
      // Drawing and overlay editing are muted so a drag reads as a region
      // selection rather than a stroke.
      canvasView.isUserInteractionEnabled = false
      overlayContainer.isUserInteractionEnabled = false
      setAISelectionActive(true)
    }
  }

  private func setAISelectionActive(_ active: Bool) {
    guard aiSelectionView.isHidden == active || aiSelectionView.isUserInteractionEnabled != active
    else { return }
    aiSelectionView.isUserInteractionEnabled = active
    if !active { aiSelectionView.clearSelection() }

    if active {
      aiSelectionView.isHidden = false
      aiSelectionView.alpha = 0
      renderSurfaceView.bringSubviewToFront(aiSelectionView)
      UIView.animate(withDuration: 0.22) { self.aiSelectionView.alpha = 1 }
    } else {
      UIView.animate(
        withDuration: 0.18,
        animations: { self.aiSelectionView.alpha = 0 },
        completion: { _ in self.aiSelectionView.isHidden = true })
    }
  }

  // MARK: AI edit

  private func handleAIGenerate() {
    let prompt = markupModel.aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, !markupModel.aiIsWorking else { return }
    guard let source = imageView.image else { return }

    // Disclosure before a single byte leaves the device.
    ChatAIMediaConsent.ensureConsent(for: .openAI, from: self) { [weak self] accepted in
      guard let self, accepted else { return }
      self.runAIEdit(prompt: prompt, source: source)
    }
  }

  private func runAIEdit(prompt: String, source: UIImage) {
    // The mask must be the same pixel size as the image we upload, so both are
    // derived from one normalized source here.
    guard let imageData = source.pngData() else { return }
    let maskData = aiSelectionView.normalizedSelection.flatMap {
      Self.makeMaskPNG(imageSize: source.size, scale: source.scale, normalizedHole: $0)
    }

    markupModel.aiIsWorking = true
    markupHost.refresh()
    view.endEditing(true)

    aiTask?.cancel()
    aiTask = Task { [weak self] in
      do {
        let edited = try await ChatAIMediaEditService.editImage(
          image: imageData,
          mimeType: "image/png",
          mask: maskData,
          prompt: prompt
        )
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard let self else { return }
          self.finishAIEdit(with: UIImage(data: edited.data), error: nil, previous: source)
        }
      } catch {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard let self else { return }
          self.finishAIEdit(with: nil, error: error, previous: source)
        }
      }
    }
  }

  private func finishAIEdit(with image: UIImage?, error: Error?, previous: UIImage) {
    markupModel.aiIsWorking = false

    if let image {
      aiUndoStack.append(previous)
      markupModel.aiCanUndo = true
      markupModel.aiPrompt = ""
      aiSelectionView.clearSelection()
      applyImage(image)
      UIView.transition(
        with: imageView, duration: 0.28, options: [.transitionCrossDissolve], animations: nil)
    } else {
      let message =
        (error as? LocalizedError)?.errorDescription ?? "That edit didn't go through."
      presentAIError(message)
    }

    markupHost.refresh()
  }

  private func handleAIUndo() {
    guard let previous = aiUndoStack.popLast() else { return }
    markupModel.aiCanUndo = !aiUndoStack.isEmpty
    applyImage(previous)
    UIView.transition(
      with: imageView, duration: 0.24, options: [.transitionCrossDissolve], animations: nil)
    markupHost.refresh()
  }

  private func presentAIError(_ message: String) {
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  /// Builds the OpenAI edit mask: opaque everywhere, **transparent over the
  /// region to replace**, at the source image's pixel dimensions.
  private static func makeMaskPNG(
    imageSize: CGSize, scale: CGFloat, normalizedHole: CGRect
  ) -> Data? {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = scale
    format.opaque = false

    let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
    let image = renderer.image { ctx in
      UIColor.black.setFill()
      ctx.fill(CGRect(origin: .zero, size: imageSize))

      let hole = CGRect(
        x: normalizedHole.minX * imageSize.width,
        y: normalizedHole.minY * imageSize.height,
        width: normalizedHole.width * imageSize.width,
        height: normalizedHole.height * imageSize.height)

      ctx.cgContext.setBlendMode(.clear)
      ctx.cgContext.fill(hole)
    }
    return image.pngData()
  }

  // MARK: Image load

  private func loadImage() {
    if let pageImage = galleryPages[safeIndex: galleryIndex]?.image {
      applyImage(pageImage)
      return
    }
    if let initialImage, galleryPages.count <= 1 {
      applyImage(initialImage)
      return
    }
    let trimmed = mediaURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    if let parsed = URL(string: trimmed), parsed.isFileURL {
      if let image = UIImage(contentsOfFile: parsed.path) { applyImage(image) }
      return
    }
    if trimmed.hasPrefix("/"), let image = UIImage(contentsOfFile: trimmed) {
      applyImage(image)
      return
    }
    if let diskData = chatMediaDiskCacheLoad(trimmed), let diskImage = UIImage(data: diskData) {
      applyImage(diskImage)
      return
    }
    guard let remoteURL = URL(string: trimmed) else { return }
    remoteImageTask?.cancel()
    remoteImageTask = URLSession.shared.dataTask(with: remoteURL) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      chatMediaDiskCacheSave(data, forKey: trimmed)
      DispatchQueue.main.async {
        self.applyImage(image)
      }
    }
    remoteImageTask?.resume()
  }

  private func applyImage(_ image: UIImage) {
    originalImage = image
    imageView.image = image
    view.setNeedsLayout()
  }

  // MARK: Snapshot + send

  private func hasVisualEdits() -> Bool {
    // An AI edit replaces the image itself and leaves no stroke or overlay
    // behind, so it has to count here or confirm would silently discard it.
    !canvasView.drawing.strokes.isEmpty || !overlayContainer.subviews.isEmpty
      || !aiUndoStack.isEmpty
  }

  private func snapshotEditedImage() -> UIImage? {
    guard let base = imageView.image else { return nil }
    // Flatten image + PencilKit drawing + overlays into one image at base pixel size.
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = base.scale
    let size = base.size
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { ctx in
      base.draw(in: CGRect(origin: .zero, size: size))
      let drawing = canvasView.drawing
      if !drawing.strokes.isEmpty {
        let bounds = canvasView.bounds
        if bounds.width > 1, bounds.height > 1 {
          let pkImage = drawing.image(from: bounds, scale: format.scale)
          pkImage.draw(in: CGRect(origin: .zero, size: size))
        }
      }
      // Render overlays (text/stickers) scaled from view coords → image coords.
      if !overlayContainer.subviews.isEmpty,
        overlayContainer.bounds.width > 1,
        overlayContainer.bounds.height > 1
      {
        let sx = size.width / overlayContainer.bounds.width
        let sy = size.height / overlayContainer.bounds.height
        ctx.cgContext.saveGState()
        ctx.cgContext.scaleBy(x: sx, y: sy)
        overlayContainer.layer.render(in: ctx.cgContext)
        ctx.cgContext.restoreGState()
      }
    }
  }

  private func writeJPEGToTemp(_ image: UIImage) -> URL? {
    let maxDimension: CGFloat = isHighQuality ? 2048 : 1440
    let scale = min(1.0, maxDimension / max(image.size.width, image.size.height, 1))
    let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
    guard let data = resized.jpegData(compressionQuality: isHighQuality ? 0.88 : 0.78) else {
      return nil
    }
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("chat-edit-\(UUID().uuidString).jpg")
    do {
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  private func emit(_ eventType: ChatImageEditEventType) {
    captionText = captionField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let editedImageURL: URL? = {
      if hasVisualEdits(), let snapshot = snapshotEditedImage() {
        return writeJPEGToTemp(snapshot)
      }
      // Resend without edits: still provide a local file if we only have a UIImage seed.
      if let originalImage, mediaURL.isEmpty || mediaURL.hasPrefix("file") == false {
        // Prefer original remote mediaURL for resend when no visual edits.
        if eventType == .resend { return nil }
      }
      if hasVisualEdits() == false, eventType == .sendNew, let originalImage {
        return writeJPEGToTemp(originalImage)
      }
      if hasVisualEdits(), let originalImage {
        return writeJPEGToTemp(originalImage)
      }
      return nil
    }()

    // Always attach snapshot when user was in markup and has strokes/overlays.
    let finalEdited: URL? = {
      if let editedImageURL { return editedImageURL }
      if hasVisualEdits(), let snap = snapshotEditedImage() {
        return writeJPEGToTemp(snap)
      }
      return nil
    }()

    onAction?(
      ChatImageEditActionPayload(
        eventType: eventType,
        messageId: messageId,
        mediaURL: mediaURL,
        caption: captionText.isEmpty ? nil : captionText,
        editedImageURL: finalEdited
      ))

    let shouldDismissPresenter = dismissPresenterOnSend && eventType == .sendNew
    let dismissTarget = shouldDismissPresenter ? (presentingViewController ?? self) : self
    dismissTarget.dismiss(animated: true)
  }

  // MARK: Actions

  @objc private func handleClose() {
    hideGifPanel()
    endTextEntry(commit: false)
    dismiss(animated: true)
  }

  @objc private func handleEditToggle() {
    setMarkupActive(!isMarkupActive, animated: true)
  }

  @objc private func handleClearAll() {
    canvasView.drawing = PKDrawing()
    overlayContainer.subviews.forEach { $0.removeFromSuperview() }
  }

  private func handleShare() {
    guard let image = snapshotEditedImage() ?? imageView.image else { return }
    let ac = UIActivityViewController(activityItems: [image], applicationActivities: nil)
    present(ac, animated: true)
  }

  // MARK: - GIF / sticker panel (slide up from bottom, expandable)

  private func showGifPanel() {
    if gifPanel == nil {
      let panel = ChatGifPanelView()
      panel.delegate = self
      // Required for GiphyGridController embed (same as ChatInputBar).
      panel.hostViewController = self
      gifPanelContainer.insertSubview(panel, belowSubview: gifGrabber)
      gifPanel = panel
    } else {
      gifPanel?.hostViewController = self
    }
    markupModel.mode = .sticker
    markupHost.refresh()
    endTextEntry(commit: false)

    // Size at bottom first (real non-zero frame), activate Giphy, then short slide-up.
    isGifPanelVisible = true
    gifPanelExpand = 0
    gifPanelContainer.isHidden = false
    gifPanelContainer.transform = .identity
    gifPanelContainer.alpha = 1
    view.setNeedsLayout()
    view.layoutIfNeeded()

    gifPanel?.setPanelVisible(true)
    gifPanel?.prepareIfNeeded()
    gifPanel?.setNeedsLayout()
    gifPanel?.layoutIfNeeded()

    let offset = max(24, min(56, max(gifPanelContainer.bounds.height, 280) * 0.12))
    gifPanelContainer.transform = CGAffineTransform(translationX: 0, y: offset)
    gifPanelContainer.alpha = 0
    UIView.animate(
      withDuration: 0.28,
      delay: 0,
      options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.gifPanelContainer.transform = .identity
      self.gifPanelContainer.alpha = 1
    }
  }

  private func hideGifPanel() {
    guard isGifPanelVisible else { return }
    let h = view.bounds.height
    UIView.animate(
      withDuration: 0.28,
      delay: 0,
      options: [.curveEaseIn, .allowUserInteraction]
    ) {
      self.gifPanelContainer.transform = CGAffineTransform(translationX: 0, y: h * 0.55)
    } completion: { _ in
      self.isGifPanelVisible = false
      self.gifPanelExpand = 0
      self.gifPanelContainer.transform = .identity
      self.gifPanelContainer.isHidden = true
      self.gifPanel?.setPanelVisible(false)
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    }
  }

  @objc private func handleGifGrabPan(_ gr: UIPanGestureRecognizer) {
    guard isGifPanelVisible else { return }
    let dy = gr.translation(in: view).y
    switch gr.state {
    case .began:
      gifPanStartExpand = gifPanelExpand
    case .changed:
      // Drag up expands, drag down collapses.
      let delta = -dy / 280
      gifPanelExpand = min(1, max(0, gifPanStartExpand + delta))
      view.setNeedsLayout()
      view.layoutIfNeeded()
    case .ended, .cancelled:
      let v = gr.velocity(in: view).y
      if v < -400 {
        gifPanelExpand = 1
      } else if v > 400 {
        if gifPanelExpand < 0.25 {
          hideGifPanel()
          return
        }
        gifPanelExpand = 0
      } else {
        gifPanelExpand = gifPanelExpand > 0.45 ? 1 : 0
      }
      UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut]) {
        self.view.setNeedsLayout()
        self.view.layoutIfNeeded()
      }
    default:
      break
    }
  }

  // MARK: - Text entry (Cancel / Done + dim + keyboard bar)

  private func beginTextEntry(editing shell: MarkupTextShellView? = nil) {
    hideGifPanel()
    editingTextShell = shell
    isTextEntryActive = true
    if let shell {
      textEntryField.text = shell.currentText
      shell.isHidden = true
    } else {
      textEntryField.text = ""
    }
    applyTextFieldStyleFromModel()
    view.setNeedsLayout()
    textDimView.alpha = 0
    textDimView.isHidden = false
    UIView.animate(withDuration: 0.22) {
      self.textDimView.alpha = 1
      self.view.layoutIfNeeded()
    }
    textEntryField.becomeFirstResponder()
  }

  private func applyTextFieldStyleFromModel() {
    let size = markupModel.textFontSize
    let weight: UIFont.Weight = markupModel.textBold ? .bold : .regular
    if markupModel.textFontName == "San Francisco" {
      textEntryField.font = .systemFont(ofSize: size, weight: weight)
    } else if let face = UIFont(name: markupModel.textFontName, size: size) {
      textEntryField.font = face
    } else {
      textEntryField.font = .systemFont(ofSize: size, weight: weight)
    }
    textEntryField.textColor = .white
  }

  private func endTextEntry(commit: Bool) {
    guard isTextEntryActive else { return }
    isTextEntryActive = false
    textEntryField.resignFirstResponder()
    let t = textEntryField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if commit, !t.isEmpty {
      if let shell = editingTextShell {
        shell.isHidden = false
        shell.updateText(
          t,
          fontSize: markupModel.textFontSize,
          bold: markupModel.textBold,
          fontName: markupModel.textFontName,
          textColor: markupModel.uiColor
        )
      } else {
        addTextLabel(t)
      }
    } else {
      editingTextShell?.isHidden = false
    }
    editingTextShell = nil
    textEntryField.text = nil
    UIView.animate(withDuration: 0.2) {
      self.textDimView.alpha = 0
    } completion: { _ in
      self.textDimView.isHidden = true
    }
    view.setNeedsLayout()
  }

  @objc private func handleTextCancel() {
    endTextEntry(commit: false)
  }

  @objc private func handleTextDone() {
    endTextEntry(commit: true)
  }

  // MARK: - Shapes (+ menu)

  private func addShape(_ kind: ChatImageShapeKind) {
    hideGifPanel()
    let shape = MarkupShapeView(kind: kind, strokeColor: markupModel.uiColor)
    let side = min(overlayContainer.bounds.width, overlayContainer.bounds.height) * 0.42
    shape.bounds = CGRect(x: 0, y: 0, width: max(120, side), height: max(120, side))
    shape.center = CGPoint(
      x: overlayContainer.bounds.midX, y: overlayContainer.bounds.midY)
    shape.isUserInteractionEnabled = true
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOverlayPan(_:)))
    shape.addGestureRecognizer(pan)
    let pin = UIPinchGestureRecognizer(target: self, action: #selector(handleOverlayPinch(_:)))
    shape.addGestureRecognizer(pin)
    overlayContainer.addSubview(shape)
    shape.setNeedsDisplay()
  }

  @objc private func handleSend() {
    let edited = hasVisualEdits()
    let captionChanged =
      !(captionField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let eventType: ChatImageEditEventType = {
      if messageId == nil { return .sendNew }
      if edited || captionChanged { return .edit }
      return .resend
    }()
    emit(eventType)
  }


  private func addTextLabel(_ text: String) {
    // Selection chrome (dashed box + blue handles) wrapping a white text pill — like system Markup.
    let shell = MarkupTextShellView()
    shell.configure(
      text: text,
      fontSize: markupModel.textFontSize,
      bold: markupModel.textBold,
      fontName: markupModel.textFontName,
      textColor: markupModel.uiColor
    )
    shell.sizeToFitContent()
    shell.center = CGPoint(
      x: overlayContainer.bounds.midX,
      y: overlayContainer.bounds.midY)
    shell.isUserInteractionEnabled = true
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOverlayPan(_:)))
    shell.addGestureRecognizer(pan)
    let pin = UIPinchGestureRecognizer(target: self, action: #selector(handleOverlayPinch(_:)))
    shell.addGestureRecognizer(pin)
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTextShellTap(_:)))
    shell.addGestureRecognizer(tap)
    overlayContainer.addSubview(shell)
    markupModel.mode = .text
    markupHost.refresh()
  }

  @objc private func handleTextShellTap(_ gr: UITapGestureRecognizer) {
    guard let shell = gr.view as? MarkupTextShellView else { return }
    // Re-open text entry to edit existing text (ref #1 → #2 flow).
    beginTextEntry(editing: shell)
  }

  private func addStickerEmoji(_ emoji: String) {
    let label = UILabel()
    label.text = emoji
    label.font = .systemFont(ofSize: 64)
    label.sizeToFit()
    label.center = CGPoint(
      x: overlayContainer.bounds.midX, y: overlayContainer.bounds.midY)
    label.isUserInteractionEnabled = true
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOverlayPan(_:)))
    label.addGestureRecognizer(pan)
    let pin = UIPinchGestureRecognizer(target: self, action: #selector(handleOverlayPinch(_:)))
    label.addGestureRecognizer(pin)
    overlayContainer.addSubview(label)
    hideGifPanel()
  }

  private func addStickerImage(from urlString: String) {
    guard let url = URL(string: urlString) else { return }
    URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        let side: CGFloat = 120
        iv.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        iv.center = CGPoint(
          x: self.overlayContainer.bounds.midX, y: self.overlayContainer.bounds.midY)
        iv.isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.handleOverlayPan(_:)))
        iv.addGestureRecognizer(pan)
        let pin = UIPinchGestureRecognizer(
          target: self, action: #selector(self.handleOverlayPinch(_:)))
        iv.addGestureRecognizer(pin)
        self.overlayContainer.addSubview(iv)
        self.hideGifPanel()
      }
    }.resume()
  }

  @objc private func handleOverlayPan(_ gr: UIPanGestureRecognizer) {
    guard let v = gr.view else { return }
    let t = gr.translation(in: overlayContainer)
    v.center = CGPoint(x: v.center.x + t.x, y: v.center.y + t.y)
    gr.setTranslation(.zero, in: overlayContainer)
  }

  @objc private func handleOverlayPinch(_ gr: UIPinchGestureRecognizer) {
    guard let v = gr.view else { return }
    if gr.state == .began || gr.state == .changed {
      v.transform = v.transform.scaledBy(x: gr.scale, y: gr.scale)
      gr.scale = 1
    }
  }

  @objc private func keyboardWillChangeFrame(_ notification: Notification) {
    guard
      let info = notification.userInfo,
      let endFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    else { return }
    let local = view.convert(endFrame, from: nil)
    keyboardHeight = max(0, view.bounds.maxY - local.minY)
    UIView.animate(withDuration: 0.22) {
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    }
  }

  // MARK: UITextField

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if textField === textEntryField {
      endTextEntry(commit: true)
    } else {
      textField.resignFirstResponder()
    }
    return true
  }

  // MARK: PKCanvasViewDelegate

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {}

  // MARK: Filmstrip

  private func centerFilmstripContentIfNeeded() {
    guard showsFilmstrip else { return }
    filmstrip.layoutIfNeeded()
    let contentW = filmstrip.collectionViewLayout.collectionViewContentSize.width
    let boundsW = filmstrip.bounds.width
    let inset = max(0, (boundsW - contentW) * 0.5)
    filmstrip.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
    if contentW < boundsW {
      filmstrip.contentOffset = CGPoint(x: -inset, y: 0)
    }
  }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
    -> Int
  {
    galleryPages.count
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
    -> UICollectionViewCell
  {
    let cell =
      collectionView.dequeueReusableCell(
        withReuseIdentifier: ChatImageEditFilmstripCell.reuseId, for: indexPath)
      as! ChatImageEditFilmstripCell
    let page = galleryPages[indexPath.item]
    cell.configure(image: page.image, selected: indexPath.item == galleryIndex)
    return cell
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard indexPath.item != galleryIndex else { return }
    galleryIndex = indexPath.item
    let page = galleryPages[indexPath.item]
    mediaURL = page.mediaURL
    canvasView.drawing = PKDrawing()
    overlayContainer.subviews.forEach { $0.removeFromSuperview() }
    if let img = page.image {
      applyImage(img)
    } else {
      loadImage()
    }
    filmstrip.reloadData()
    centerFilmstripContentIfNeeded()
  }
}

// MARK: - GIF panel delegate

extension ChatImageEditViewController: ChatGifPanelViewDelegate {
  func chatGifPanel(_ panel: ChatGifPanelView, didSelectGif gif: ChatGifSelection) {
    addStickerImage(from: gif.url.isEmpty ? gif.previewUrl : gif.url)
  }

  func chatGifPanel(_ panel: ChatGifPanelView, didSelectSticker sticker: ChatStickerSelection) {
    if let remote = sticker.remoteUrl, !remote.isEmpty {
      addStickerImage(from: remote)
    } else if let emoji = sticker.emoji, !emoji.isEmpty {
      addStickerEmoji(emoji)
    } else if let bundle = sticker.bundleFileName {
      // Best-effort: treat as emoji-less image path via remote only
      _ = bundle
    }
  }

  func chatGifPanel(_ panel: ChatGifPanelView, didSelectEmoji emoji: String) {
    addStickerEmoji(emoji)
  }

  func chatGifPanelDidRequestClose(_ panel: ChatGifPanelView) {
    hideGifPanel()
  }
}

// MARK: - System color picker

extension ChatImageEditViewController: UIColorPickerViewControllerDelegate {
  func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
    applyPickedColor(viewController.selectedColor)
  }

  func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
    applyPickedColor(viewController.selectedColor)
  }

  private func applyPickedColor(_ color: UIColor) {
    markupModel.inkColor = Color(color)
    var alpha: CGFloat = 1
    color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
    markupModel.inkOpacity = Double(alpha)
    applyToolFromModel()
    markupHost.refresh()
  }
}

// MARK: - Shape overlay

private final class MarkupShapeView: UIView {
  private let kind: ChatImageShapeKind
  private let strokeColor: UIColor
  private let border = CAShapeLayer()
  private var handleViews: [UIView] = []

  init(kind: ChatImageShapeKind, strokeColor: UIColor) {
    self.kind = kind
    self.strokeColor = strokeColor
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    border.fillColor = UIColor.clear.cgColor
    border.strokeColor = strokeColor.cgColor
    border.lineWidth = 5
    border.lineJoin = .round
    border.lineCap = .round
    layer.addSublayer(border)

    for _ in 0..<8 {
      let h = UIView()
      h.backgroundColor = .systemBlue
      h.layer.cornerRadius = 5
      h.layer.borderWidth = 1.5
      h.layer.borderColor = UIColor.white.cgColor
      addSubview(h)
      handleViews.append(h)
    }
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    border.frame = bounds
    border.path = shapePath(in: bounds.insetBy(dx: 10, dy: 10)).cgPath
    let pts = handlePoints(in: bounds.insetBy(dx: 6, dy: 6))
    for (i, hv) in handleViews.enumerated() {
      guard i < pts.count else {
        hv.isHidden = true
        continue
      }
      hv.isHidden = false
      hv.frame = CGRect(x: pts[i].x - 5, y: pts[i].y - 5, width: 10, height: 10)
    }
  }

  private func shapePath(in rect: CGRect) -> UIBezierPath {
    switch kind {
    case .rectangle:
      return UIBezierPath(roundedRect: rect, cornerRadius: 4)
    case .ellipse:
      return UIBezierPath(ovalIn: rect)
    case .bubble:
      let path = UIBezierPath(
        roundedRect: CGRect(
          x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.72),
        cornerRadius: 12)
      path.move(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.72))
      path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.72))
      path.close()
      return path
    case .star:
      return starPath(in: rect)
    case .arrow:
      let path = UIBezierPath()
      let midY = rect.midY
      path.move(to: CGPoint(x: rect.minX, y: midY))
      path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.28, y: midY))
      path.move(to: CGPoint(x: rect.maxX - rect.width * 0.35, y: rect.minY + rect.height * 0.22))
      path.addLine(to: CGPoint(x: rect.maxX, y: midY))
      path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.35, y: rect.maxY - rect.height * 0.22))
      return path
    }
  }

  private func starPath(in rect: CGRect) -> UIBezierPath {
    let path = UIBezierPath()
    let cx = rect.midX
    let cy = rect.midY
    let r = min(rect.width, rect.height) * 0.5
    let inner = r * 0.42
    for i in 0..<10 {
      let angle = CGFloat(i) * .pi / 5 - .pi / 2
      let rad = i % 2 == 0 ? r : inner
      let p = CGPoint(x: cx + cos(angle) * rad, y: cy + sin(angle) * rad)
      if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.close()
    return path
  }

  private func handlePoints(in rect: CGRect) -> [CGPoint] {
    [
      CGPoint(x: rect.minX, y: rect.minY),
      CGPoint(x: rect.midX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.midY),
      CGPoint(x: rect.maxX, y: rect.maxY),
      CGPoint(x: rect.midX, y: rect.maxY),
      CGPoint(x: rect.minX, y: rect.maxY),
      CGPoint(x: rect.minX, y: rect.midY),
    ]
  }
}

// MARK: - Markup text shell (dashed selection + white pill)

private final class MarkupTextShellView: UIView {
  private let label = UILabel()
  private let border = CAShapeLayer()
  private let leftHandle = UIView()
  private let rightHandle = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear

    label.backgroundColor = .white
    label.textColor = .black
    label.textAlignment = .center
    label.layer.cornerRadius = 8
    label.clipsToBounds = true
    addSubview(label)

    border.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
    border.fillColor = UIColor.clear.cgColor
    border.lineWidth = 1.5
    border.lineDashPattern = [5, 4]
    layer.addSublayer(border)

    for handle in [leftHandle, rightHandle] {
      handle.backgroundColor = .white
      handle.layer.borderColor = UIColor.systemBlue.cgColor
      handle.layer.borderWidth = 2
      handle.layer.cornerRadius = 7
      addSubview(handle)
    }
  }

  required init?(coder: NSCoder) { nil }

  var currentText: String { label.text ?? "" }

  func configure(
    text: String, fontSize: CGFloat, bold: Bool, fontName: String, textColor: UIColor
  ) {
    apply(text: text, fontSize: fontSize, bold: bold, fontName: fontName, textColor: textColor)
  }

  func updateText(
    _ text: String, fontSize: CGFloat, bold: Bool, fontName: String, textColor: UIColor
  ) {
    apply(text: text, fontSize: fontSize, bold: bold, fontName: fontName, textColor: textColor)
    sizeToFitContent()
  }

  private func apply(
    text: String, fontSize: CGFloat, bold: Bool, fontName: String, textColor: UIColor
  ) {
    label.text = text
    let weight: UIFont.Weight = bold ? .bold : .regular
    if fontName == "San Francisco" {
      label.font = .systemFont(ofSize: fontSize, weight: weight)
    } else if let face = UIFont(name: fontName, size: fontSize) {
      label.font = face
    } else {
      label.font = .systemFont(ofSize: fontSize, weight: weight)
    }
    // System Markup: black type on white pill.
    label.textColor = .black
    _ = textColor
  }

  func sizeToFitContent() {
    label.sizeToFit()
    let padX: CGFloat = 16
    let padY: CGFloat = 10
    let labelSize = CGSize(
      width: label.bounds.width + padX * 2,
      height: label.bounds.height + padY * 2)
    let inset: CGFloat = 10
    bounds = CGRect(
      x: 0, y: 0,
      width: labelSize.width + inset * 2,
      height: labelSize.height + inset * 2)
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let inset: CGFloat = 10
    label.frame = bounds.insetBy(dx: inset, dy: inset)
    let path = UIBezierPath(
      roundedRect: label.frame.insetBy(dx: -4, dy: -4), cornerRadius: 10)
    border.path = path.cgPath
    border.frame = bounds

    let handle: CGFloat = 14
    leftHandle.frame = CGRect(
      x: label.frame.minX - handle * 0.5 - 4,
      y: bounds.midY - handle * 0.5,
      width: handle, height: handle)
    rightHandle.frame = CGRect(
      x: label.frame.maxX - handle * 0.5 + 4,
      y: bounds.midY - handle * 0.5,
      width: handle, height: handle)
  }
}

// MARK: - Filmstrip cell

private final class ChatImageEditFilmstripCell: UICollectionViewCell {
  static let reuseId = "ChatImageEditFilmstripCell"
  private let imageView = UIImageView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.clipsToBounds = true
    contentView.layer.cornerRadius = 10
    contentView.layer.cornerCurve = .continuous
    contentView.backgroundColor = UIColor(white: 0.18, alpha: 1)
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    contentView.addSubview(imageView)
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = contentView.bounds
  }

  func configure(image: UIImage?, selected: Bool) {
    imageView.image = image
    contentView.layer.borderWidth = selected ? 2 : 0
    contentView.layer.borderColor = UIColor.white.cgColor
    contentView.alpha = selected ? 1 : 0.72
  }
}

private extension Array {
  subscript(safeIndex index: Int) -> Element? {
    guard index >= 0, index < count else { return nil }
    return self[index]
  }
}

// MARK: - SwiftUI bridge (optional host)

struct ChatImageEditSwiftUIView: UIViewControllerRepresentable {
  let messageId: String?
  let mediaURL: String
  let initialImage: UIImage?
  let initialCaption: String?
  let headerTitle: String?
  let dismissPresenterOnSend: Bool
  var onAction: ((ChatImageEditActionPayload) -> Void)?

  func makeUIViewController(context: Context) -> ChatImageEditViewController {
    let vc = ChatImageEditViewController(
      messageId: messageId,
      mediaURL: mediaURL,
      initialImage: initialImage,
      initialCaption: initialCaption,
      headerTitle: headerTitle,
      dismissPresenterOnSend: dismissPresenterOnSend
    )
    vc.onAction = onAction
    return vc
  }

  func updateUIViewController(_ uiViewController: ChatImageEditViewController, context: Context) {}
}
