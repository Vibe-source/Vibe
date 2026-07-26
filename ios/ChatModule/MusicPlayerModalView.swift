import SwiftUI
import UIKit

// MARK: - Now-playing waveform visualizer (native SF Symbol)

/// Smooth "now playing" visualizer built on the native `waveform` SF Symbol with the
/// system `.variableColor` animation (iOS 17+) — Apple's own equalizer motion, far
/// smoother than hand-rolled bars. Animates only while playing; holds a dim static
/// waveform when paused. `showsScrim` draws a circular dark scrim for use over artwork.
private final class EqualizerBarsView: UIView {
  private let scrimView = UIView()
  private let waveformView = UIImageView()
  private let showsScrim: Bool
  private var pointSize: CGFloat
  private var isAnimating = false
  private var fallbackLink: CADisplayLink?
  private var fallbackPhase: CGFloat = 0.0

  init(showsScrim: Bool = true, pointSize: CGFloat = 20.0, tint: UIColor = .white) {
    self.showsScrim = showsScrim
    self.pointSize = pointSize
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    clipsToBounds = true
    backgroundColor = .clear

    scrimView.backgroundColor = UIColor.black.withAlphaComponent(0.42)
    scrimView.isUserInteractionEnabled = false
    scrimView.isHidden = !showsScrim
    addSubview(scrimView)

    waveformView.contentMode = .center
    waveformView.tintColor = tint
    waveformView.image = UIImage(systemName: "waveform")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
    addSubview(waveformView)
  }

  required init?(coder: NSCoder) { nil }

  deinit { fallbackLink?.invalidate() }

  func setTint(_ color: UIColor) { waveformView.tintColor = color }

  func setActive(_ active: Bool, playing: Bool) {
    isHidden = !active
    if active, playing {
      startAnimating()
    } else {
      stopAnimating()
    }
  }

  private func startAnimating() {
    guard !isAnimating else { return }
    isAnimating = true
    if #available(iOS 17.0, *) {
      waveformView.addSymbolEffect(
        .variableColor.iterative.dimInactiveLayers, options: .repeating, animated: true)
    } else {
      // Pre-iOS17 fallback: gentle opacity pulse via display link.
      fallbackLink?.invalidate()
      let link = CADisplayLink(target: self, selector: #selector(pulse))
      link.preferredFramesPerSecond = 20
      link.add(to: .main, forMode: .common)
      fallbackLink = link
    }
  }

  private func stopAnimating() {
    isAnimating = false
    if #available(iOS 17.0, *) {
      waveformView.removeAllSymbolEffects()
    }
    fallbackLink?.invalidate()
    fallbackLink = nil
    waveformView.alpha = 1.0
  }

  @objc private func pulse(_ link: CADisplayLink) {
    fallbackPhase += 0.08
    waveformView.alpha = 0.55 + 0.45 * (0.5 + 0.5 * sin(fallbackPhase))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    scrimView.frame = bounds
    layer.cornerRadius = showsScrim ? min(bounds.width, bounds.height) * 0.5 : 0.0
    waveformView.frame = bounds
  }
}

// MARK: - Queue row

private final class NativeMusicPlayerModalQueueRowView: UIControl {
  private let leadingContainerView = UIView()
  private let leadingArtworkView = UIImageView()
  private let leadingFallbackIconView = UIImageView()
  private let equalizerView = EqualizerBarsView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let separatorView = UIView()
  private let textStack = UIStackView()
  private let removeButton = UIButton(type: .system)
  private let gripView = UIImageView()
  private let gripHitTarget = UIControl()
  private var theme = NativeMusicPlayerTheme()
  private(set) var trackId: String?
  private var imageTask: URLSessionDataTask?
  private var isActive = false
  private var isPlaying = false
  private var configuredCoverURL: String?

  var onSelectTrack: ((String) -> Void)?
  var onRemoveTrack: ((String) -> Void)?
  /// Long-press / drag on the trailing grip. Gesture is recognized on the grip hit area.
  var onGripLongPress: ((NativeMusicPlayerModalQueueRowView, UILongPressGestureRecognizer) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear

    leadingContainerView.layer.cornerCurve = .continuous
    leadingContainerView.clipsToBounds = true
    addSubview(leadingContainerView)

    leadingArtworkView.contentMode = .scaleAspectFill
    leadingArtworkView.clipsToBounds = true
    leadingContainerView.addSubview(leadingArtworkView)

    leadingFallbackIconView.contentMode = .scaleAspectFit
    leadingFallbackIconView.image = UIImage(systemName: "play.fill")
    leadingContainerView.addSubview(leadingFallbackIconView)

    equalizerView.isHidden = true
    leadingContainerView.addSubview(equalizerView)

    titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    titleLabel.numberOfLines = 1
    subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    subtitleLabel.numberOfLines = 2

    textStack.axis = .vertical
    textStack.alignment = .fill
    textStack.spacing = 3.0
    textStack.isUserInteractionEnabled = false
    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(subtitleLabel)
    addSubview(textStack)

    removeButton.setImage(
      UIImage(systemName: "minus.circle.fill")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)),
      for: .normal
    )
    removeButton.tintColor = .systemRed
    removeButton.addTarget(self, action: #selector(handleRemove), for: .touchUpInside)
    addSubview(removeButton)

    gripView.contentMode = .scaleAspectFit
    gripView.image = UIImage(systemName: "line.3.horizontal")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
    gripView.isUserInteractionEnabled = false
    addSubview(gripView)

    gripHitTarget.backgroundColor = .clear
    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleGripLongPress(_:)))
    longPress.minimumPressDuration = 0.12
    gripHitTarget.addGestureRecognizer(longPress)
    // Also allow continuous drag after press by keeping the recognizer.
    addSubview(gripHitTarget)

    separatorView.isUserInteractionEnabled = false
    addSubview(separatorView)

    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    imageTask?.cancel()
  }

  func applyTheme(_ theme: NativeMusicPlayerTheme) {
    self.theme = theme
    titleLabel.textColor = theme.text
    subtitleLabel.textColor = theme.secondaryText
    leadingFallbackIconView.tintColor = UIColor.white
    separatorView.backgroundColor = theme.text.withAlphaComponent(theme.isDark ? 0.10 : 0.08)
    gripView.tintColor = theme.secondaryText.withAlphaComponent(0.85)
    removeButton.tintColor = .systemRed
  }

  func configure(
    track: NativeMusicPlayerTrack,
    isActive: Bool,
    isPlaying: Bool,
    artworkImage: UIImage? = nil,
    showsSeparator: Bool
  ) {
    self.isActive = isActive
    self.isPlaying = isPlaying
    trackId = track.trackId
    titleLabel.text = track.title
    subtitleLabel.text = detailText(for: track)
    separatorView.isHidden = !showsSeparator

    titleLabel.textColor = isActive ? theme.text : theme.text.withAlphaComponent(0.96)
    subtitleLabel.textColor =
      isActive ? theme.secondaryText.withAlphaComponent(0.92) : theme.secondaryText

    equalizerView.setActive(isActive, playing: isActive && isPlaying)
    loadImage(urlString: track.cover, directImage: artworkImage, trackId: track.trackId)
  }

  /// Updates play/pause equalizer without reloading artwork.
  func setPlaying(_ playing: Bool) {
    isPlaying = playing
    equalizerView.setActive(isActive, playing: isActive && playing)
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let trailingControlsW: CGFloat = 72.0
    let leadingSide: CGFloat = 56.0

    leadingContainerView.frame = CGRect(
      x: 0.0,
      y: floor((bounds.height - leadingSide) * 0.5),
      width: leadingSide,
      height: leadingSide
    )
    leadingContainerView.layer.cornerRadius = leadingSide * 0.5
    leadingArtworkView.frame = leadingContainerView.bounds
    leadingArtworkView.layer.cornerRadius = 0
    leadingFallbackIconView.frame = leadingContainerView.bounds.insetBy(dx: 17.0, dy: 17.0)
    equalizerView.frame = leadingContainerView.bounds
    equalizerView.layer.cornerRadius = leadingSide * 0.5

    let gripSide: CGFloat = 28.0
    let removeSide: CGFloat = 28.0
    gripView.frame = CGRect(
      x: bounds.width - gripSide - 2.0,
      y: floor((bounds.height - gripSide) * 0.5),
      width: gripSide,
      height: gripSide
    )
    removeButton.frame = CGRect(
      x: gripView.frame.minX - 8.0 - removeSide,
      y: floor((bounds.height - removeSide) * 0.5),
      width: removeSide,
      height: removeSide
    )
    // Generous hit area for the grip (covers grip + a bit of padding).
    gripHitTarget.frame = CGRect(
      x: gripView.frame.minX - 6.0,
      y: 0.0,
      width: bounds.width - (gripView.frame.minX - 6.0),
      height: bounds.height
    )

    let textX = leadingContainerView.frame.maxX + 14.0
    let textRight = removeButton.frame.minX - 10.0
    textStack.frame = CGRect(
      x: textX,
      y: floor((bounds.height - 40.0) * 0.5),
      width: max(0.0, textRight - textX),
      height: 40.0
    )

    separatorView.frame = CGRect(
      x: textX,
      y: bounds.height - (1.0 / UIScreen.main.scale),
      width: max(0.0, bounds.width - textX - trailingControlsW * 0.25),
      height: 1.0 / UIScreen.main.scale
    )
  }

  @objc private func handleTap() {
    guard let trackId else { return }
    onSelectTrack?(trackId)
  }

  @objc private func handleRemove() {
    guard let trackId else { return }
    onRemoveTrack?(trackId)
  }

  @objc private func handleGripLongPress(_ gesture: UILongPressGestureRecognizer) {
    onGripLongPress?(self, gesture)
  }

  private func detailText(for track: NativeMusicPlayerTrack) -> String {
    let components = [track.duration, track.artist].compactMap { value -> String? in
      guard let value, !value.isEmpty else { return nil }
      return value
    }
    return components.isEmpty ? "Audio" : components.joined(separator: " • ")
  }

  private func loadImage(urlString: String?, directImage: UIImage? = nil, trackId: String) {
    let normalized = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)
    // Keep current image if same URL + already shown (avoids flash on queue refresh).
    if leadingArtworkView.image != nil,
      configuredCoverURL == normalized,
      directImage == nil
    {
      return
    }

    imageTask?.cancel()
    imageTask = nil
    configuredCoverURL = normalized

    let fallbackBackground =
      theme.primary.withAlphaComponent(theme.isDark ? 0.96 : 0.90)

    if let directImage {
      leadingArtworkView.image = directImage
      leadingContainerView.backgroundColor = .clear
      leadingFallbackIconView.isHidden = true
      return
    }

    // Don't clear existing image until a new one arrives (prevents flash).
    if leadingArtworkView.image == nil {
      leadingContainerView.backgroundColor = fallbackBackground
      leadingFallbackIconView.isHidden = false
    }

    guard let normalized, !normalized.isEmpty else {
      leadingArtworkView.image = nil
      leadingContainerView.backgroundColor = fallbackBackground
      leadingFallbackIconView.isHidden = false
      return
    }

    imageTask = chatLoadMusicCover(urlString: normalized) { [weak self] image in
      guard let self else { return }
      // Cell-reuse guard: only apply if this row still represents the same track/URL.
      guard self.trackId == trackId, self.configuredCoverURL == normalized else { return }
      self.leadingArtworkView.image = image
      self.leadingContainerView.backgroundColor = .clear
      self.leadingFallbackIconView.isHidden = true
    }
  }
}

struct VoiceSnapshotDownloadInfo {
  let fraction: CGFloat?
  let downloadedBytes: Int64?
  let totalBytes: Int64?

  static func extract(from snapshot: VoiceBubblePlaybackSnapshot?) -> VoiceSnapshotDownloadInfo {
    guard let snapshot else {
      return VoiceSnapshotDownloadInfo(fraction: nil, downloadedBytes: nil, totalBytes: nil)
    }
    // The snapshot now carries these directly (Slice A). Prefer the byte-derived
    // fraction; fall back to the coarse downloadProgress while a download is in flight.
    var frac = snapshot.downloadFraction
    if frac == nil && snapshot.isDownloading {
      frac = snapshot.downloadProgress
    }

    return VoiceSnapshotDownloadInfo(
      fraction: frac,
      downloadedBytes: snapshot.downloadedBytes,
      totalBytes: snapshot.totalBytes
    )
  }

  var isDownloading: Bool {
    fraction != nil || downloadedBytes != nil || totalBytes != nil
  }
}

private final class ShimmerProgressView: UIView {
  private let trackView = UIView()
  private let fillView = UIView()
  private let shimmerLayer = CAGradientLayer()
  private var isShimmering = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear

    trackView.layer.cornerCurve = .continuous
    trackView.layer.cornerRadius = 3.0
    trackView.clipsToBounds = true
    addSubview(trackView)

    fillView.layer.cornerCurve = .continuous
    fillView.layer.cornerRadius = 3.0
    fillView.clipsToBounds = true
    trackView.addSubview(fillView)

    shimmerLayer.colors = [
      UIColor.white.withAlphaComponent(0.0).cgColor,
      UIColor.white.withAlphaComponent(0.70).cgColor,
      UIColor.white.withAlphaComponent(0.0).cgColor
    ]
    shimmerLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
    shimmerLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
    shimmerLayer.locations = [0.0, 0.5, 1.0]
    trackView.layer.addSublayer(shimmerLayer)
  }

  required init?(coder: NSCoder) { nil }

  func applyTheme(_ theme: NativeMusicPlayerTheme) {
    trackView.backgroundColor = theme.text.withAlphaComponent(theme.isDark ? 0.18 : 0.12)
    fillView.backgroundColor = theme.primary
  }

  func setProgress(_ fraction: CGFloat) {
    let clamped = max(0.05, min(1.0, fraction))
    fillView.frame = CGRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
  }

  func startShimmer() {
    guard !isShimmering else { return }
    isShimmering = true
    shimmerLayer.removeAllAnimations()
    let anim = CABasicAnimation(keyPath: "transform.translation.x")
    anim.fromValue = -bounds.width
    anim.toValue = bounds.width
    anim.duration = 1.3
    anim.repeatCount = .infinity
    shimmerLayer.add(anim, forKey: "shimmer")
  }

  func stopShimmer() {
    isShimmering = false
    shimmerLayer.removeAllAnimations()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    trackView.frame = bounds
    shimmerLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * 0.6, height: bounds.height)
  }
}

final class NativeMusicPlayerModalView: UIViewController, UIScrollViewDelegate, UISheetPresentationControllerDelegate {
  var onTogglePlayback: (() -> Void)?
  var onDismiss: (() -> Void)?
  var onPlayNext: (() -> Void)?
  var onPlayPrev: (() -> Void)?
  var onToggleQueueOrder: (() -> Void)?
  var onToggleRepeat: (() -> Void)?
  var onSeek: ((Double) -> Void)?
  var onSelectTrack: ((String) -> Void)?
  /// Persist a new Next-Up order (all displayed trackIds in drop order).
  var onReorderQueue: (([String]) -> Void)?
  /// Remove a track from the Next-Up list.
  var onRemoveTrack: ((String) -> Void)?

  private let sheetContent = UIView()
  private let backdropBlurView = UIVisualEffectView(effect: nil)
  private let blurredBackdropView = UIImageView()

  private let coverTapControl = UIControl()
  private let coverView = UIImageView()
  private let coverFallbackView = UIImageView()
  private let shareButton = UIButton(type: .system)
  /// Native animated waveform at the title's trailing edge (now-playing indicator).
  private let heroWaveformView = EqualizerBarsView(showsScrim: false, pointSize: 22.0)
  private let titleLabel = UILabel()
  private let artistLabel = UILabel()
  private let currentTimeLabel = UILabel()
  private let durationLabel = UILabel()
  private let progressSlider = UISlider()
  private let shimmerProgressView = ShimmerProgressView()
  private let rateButton = UIButton(type: .system)
  private let prevButton = UIButton(type: .system)
  private let playButton = UIButton(type: .system)
  private let nextButton = UIButton(type: .system)
  private let artworkModeButton = UIButton(type: .system)
  private let primaryActionButton = UIButton(type: .system)
  private let queueTitleLabel = UILabel()
  /// Native SwiftUI "Next Up" list (swipe: leading = Play Next, trailing = Delete; drag
  /// to reorder). Hosted inside the UIKit modal so the morph/glass chrome stays UIKit.
  private let queueModel = NativeMusicPlayerQueueModel()
  private lazy var queueHostingController = UIHostingController(
    rootView: NativeMusicPlayerQueueListView(model: queueModel))

  private var theme = NativeMusicPlayerTheme()
  private var isShowing = false
  /// Settled detent only — never gates layout geometry (morph is pure `expandProgress`).
  private var isLargeDetent = false
  /// Continuous 0…1 morph progress (compact → hero), driven by live sheet height.
  private var expandProgress: CGFloat = 0.0
  private var hasSeededExpandProgress = false
  private var morphDisplayLink: CADisplayLink?
  private var cachedMediumSheetHeight: CGFloat = 0.0
  private var cachedLargeSheetHeight: CGFloat = 0.0
  private var lastAppliedExpandProgress: CGFloat = -1.0
  private var queueCanScroll = false
  private var coverImageTask: URLSessionDataTask?
  private var pendingSeekValue: Float?

  private var currentTrack: NativeMusicPlayerTrack?
  private var currentState: (progressMs: Double, durationMs: Double, isPlaying: Bool) =
    (0.0, 0.0, false)
  private var currentQueue: [NativeMusicPlayerTrack] = []
  private var currentLibrary: [NativeMusicPlayerTrack] = []
  private var currentArtwork: UIImage?
  private var currentDownloadInfo = VoiceSnapshotDownloadInfo(fraction: nil, downloadedBytes: nil, totalBytes: nil)
  private var queueOrderMode: NativeMusicPlayerQueueOrderMode = .forward
  private var isRepeatEnabled = false
  private var renderedPlayButtonIsPlaying: Bool?
  private var renderedCoverTrackId: String?
  private var renderedCoverURL: String?
  private var renderedCoverImageIdentifier: ObjectIdentifier?
  private var renderedQueueTracks: [NativeMusicPlayerTrack] = []
  /// Session-local hides from a swipe-Delete (until rebuild forces a full refresh).
  private var suppressedTrackIds = Set<String>()
  /// When true, `renderedQueueTracks` is the authoritative display order (post-drag / remove).
  private var hasLocalQueueOrderOverride = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    sheetContent.clipsToBounds = false
    view.addSubview(sheetContent)

    // Album-art reflection sits at the very back; the frosted glass material is a
    // full-bleed SIBLING on top of it (not a child) so the whole sheet reads as one
    // translucent glass surface — like the native Now Playing sheet. Both are always
    // present (no alpha tied to the morph), which is what removes the collapse jank
    // where the reflection faded out and exposed the chat behind.
    blurredBackdropView.contentMode = .scaleAspectFill
    blurredBackdropView.clipsToBounds = true
    blurredBackdropView.alpha = 1.0
    sheetContent.addSubview(blurredBackdropView)

    backdropBlurView.isUserInteractionEnabled = false
    sheetContent.addSubview(backdropBlurView)

    coverTapControl.addTarget(self, action: #selector(handleArtworkModeToggle), for: .touchUpInside)
    sheetContent.addSubview(coverTapControl)

    coverView.contentMode = .scaleAspectFill
    coverView.clipsToBounds = true
    coverView.layer.cornerCurve = .continuous
    coverTapControl.addSubview(coverView)

    coverFallbackView.contentMode = .scaleAspectFit
    coverFallbackView.image = UIImage(systemName: "music.note")
    coverTapControl.addSubview(coverFallbackView)

    shareButton.configuration = .plain()
    shareButton.configuration?.contentInsets = .zero
    shareButton.addTarget(self, action: #selector(handleShare), for: .touchUpInside)
    sheetContent.addSubview(shareButton)

    heroWaveformView.isHidden = true
    sheetContent.addSubview(heroWaveformView)

    titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
    titleLabel.numberOfLines = 2
    titleLabel.lineBreakMode = .byTruncatingTail
    sheetContent.addSubview(titleLabel)

    artistLabel.font = .systemFont(ofSize: 14, weight: .medium)
    artistLabel.numberOfLines = 2
    artistLabel.lineBreakMode = .byTruncatingTail
    sheetContent.addSubview(artistLabel)

    currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    durationLabel.textAlignment = .right
    sheetContent.addSubview(currentTimeLabel)
    sheetContent.addSubview(durationLabel)

    progressSlider.minimumValue = 0.0
    progressSlider.maximumValue = 1.0
    progressSlider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
    progressSlider.addTarget(self, action: #selector(sliderCommit), for: .touchUpInside)
    progressSlider.addTarget(self, action: #selector(sliderCommit), for: .touchUpOutside)
    progressSlider.addTarget(self, action: #selector(sliderCommit), for: .touchCancel)
    sheetContent.addSubview(progressSlider)

    shimmerProgressView.isHidden = true
    sheetContent.addSubview(shimmerProgressView)

    rateButton.addTarget(self, action: #selector(handleQueueOrderToggle), for: .touchUpInside)
    prevButton.addTarget(self, action: #selector(handlePrev), for: .touchUpInside)
    playButton.addTarget(self, action: #selector(handlePlay), for: .touchUpInside)
    nextButton.addTarget(self, action: #selector(handleNext), for: .touchUpInside)
    artworkModeButton.addTarget(self, action: #selector(handleRepeatToggle), for: .touchUpInside)
    [rateButton, prevButton, playButton, nextButton, artworkModeButton].forEach {
      sheetContent.addSubview($0)
    }

    primaryActionButton.isHidden = true
    sheetContent.addSubview(primaryActionButton)

    queueTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    queueTitleLabel.text = "AUDIO IN THIS CHAT"
    queueTitleLabel.isHidden = true
    sheetContent.addSubview(queueTitleLabel)

    // Native SwiftUI "Next Up" list hosted inside the sheet.
    queueModel.onSelect = { [weak self] trackId in self?.onSelectTrack?(trackId) }
    queueModel.onPlayNext = { [weak self] trackId in self?.handlePlayNextTrack(trackId) }
    queueModel.onRemove = { [weak self] trackId in self?.handleRemoveTrack(trackId) }
    queueModel.onMove = { [weak self] orderedIds in self?.handleReorderTracks(orderedIds) }
    queueHostingController.view.backgroundColor = .clear
    queueHostingController.view.clipsToBounds = true
    if #available(iOS 16.4, *) {
      queueHostingController.safeAreaRegions = []
    }
    addChild(queueHostingController)
    sheetContent.addSubview(queueHostingController.view)
    queueHostingController.didMove(toParent: self)

    applyTheme(theme)
  }

  required init?(coder: NSCoder) { nil }

  init() {
    super.init(nibName: nil, bundle: nil)
  }

  deinit {
    coverImageTask?.cancel()
    stopMorphDisplayLink()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Seed progress from the initial detent BEFORE the first layout pass so
    // compact title/artist frames land exactly on frame one (no 3–5px jump).
    seedExpandProgressFromDetentIfNeeded()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    isShowing = true
    seedExpandProgressFromDetentIfNeeded()
    captureSettledSheetHeightsIfNeeded()
    startMorphDisplayLink()
    updateExpandProgressFromSheetHeight()
    view.setNeedsLayout()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stopMorphDisplayLink()
  }

  func sheetPresentationControllerDidChangeSelectedDetentIdentifier(
    _ sheetPresentationController: UISheetPresentationController
  ) {
    // Record settled detent only — continuous morph is driven by CADisplayLink.
    let isLarge = (sheetPresentationController.selectedDetentIdentifier == .large)
    isLargeDetent = isLarge
    captureSettledSheetHeightsIfNeeded()
  }

  private func setExpandedDetent(_ isLarge: Bool, animated: Bool) {
    // Prefer real sheet detent change so the display-link morph follows height.
    if let sheet = sheetPresentationController {
      let target: UISheetPresentationController.Detent.Identifier = isLarge ? .large : .medium
      if sheet.selectedDetentIdentifier != target {
        if animated {
          sheet.animateChanges {
            sheet.selectedDetentIdentifier = target
          }
        } else {
          sheet.selectedDetentIdentifier = target
        }
      }
    }
    isLargeDetent = isLarge
  }

  /// Seeds `expandProgress` from the presentation detent so progress→0 matches the
  /// compact layout exactly on the first layout pass (no title/artist jump).
  private func seedExpandProgressFromDetentIfNeeded() {
    guard !hasSeededExpandProgress else { return }
    let isLarge = sheetPresentationController?.selectedDetentIdentifier == .large
    isLargeDetent = isLarge
    expandProgress = isLarge ? 1.0 : 0.0
    lastAppliedExpandProgress = expandProgress
    hasSeededExpandProgress = true
  }

  private func startMorphDisplayLink() {
    guard morphDisplayLink == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(handleMorphDisplayLink))
    link.add(to: .main, forMode: .common)
    morphDisplayLink = link
  }

  private func stopMorphDisplayLink() {
    morphDisplayLink?.invalidate()
    morphDisplayLink = nil
  }

  @objc private func handleMorphDisplayLink() {
    let previous = expandProgress
    updateExpandProgressFromSheetHeight()
    // Skip work when the sheet height is stable (settled detent / idle).
    if abs(expandProgress - previous) < 0.0005,
      abs(expandProgress - lastAppliedExpandProgress) < 0.0005
    {
      return
    }
    view.setNeedsLayout()
  }

  private func updateExpandProgressFromSheetHeight() {
    let presentedHeight =
      presentationController?.presentedView?.bounds.height
      ?? presentationController?.presentedView?.frame.height
      ?? view.bounds.height
    guard presentedHeight > 1.0 else { return }

    // Until we have a measured medium height, keep the seeded detent progress so
    // fallback fractions (0.5 / 0.94 of screen) cannot shift compact chrome by a few px.
    if cachedMediumSheetHeight <= 1.0 {
      if cachedLargeSheetHeight <= 1.0 {
        // Still seeding — capture current as the medium (or large) settled height.
        if isLargeDetent {
          cachedLargeSheetHeight = presentedHeight
        } else {
          cachedMediumSheetHeight = presentedHeight
        }
        expandProgress = isLargeDetent ? 1.0 : 0.0
        return
      }
    }

    let containerHeight =
      view.window?.bounds.height
      ?? presentingViewController?.view.bounds.height
      ?? UIScreen.main.bounds.height

    let mediumH =
      cachedMediumSheetHeight > 1.0
      ? cachedMediumSheetHeight
      : max(240.0, containerHeight * 0.5)
    let largeH =
      cachedLargeSheetHeight > 1.0
      ? cachedLargeSheetHeight
      : max(mediumH + 80.0, containerHeight * 0.94)

    let span = max(1.0, largeH - mediumH)
    let raw = (presentedHeight - mediumH) / span
    expandProgress = min(1.0, max(0.0, raw))
  }

  private func captureSettledSheetHeightsIfNeeded() {
    let presentedHeight =
      presentationController?.presentedView?.bounds.height
      ?? presentationController?.presentedView?.frame.height
      ?? 0.0
    guard presentedHeight > 1.0 else { return }
    // Only capture when near a settled detent so mid-drag heights don't poison caches.
    let settledTarget: CGFloat = isLargeDetent ? 1.0 : 0.0
    if abs(expandProgress - settledTarget) > 0.12, morphDisplayLink != nil {
      return
    }
    if isLargeDetent {
      cachedLargeSheetHeight = presentedHeight
    } else {
      cachedMediumSheetHeight = presentedHeight
    }
  }

  func applyTheme(_ theme: NativeMusicPlayerTheme) {
    self.theme = theme
    view.backgroundColor = .clear

    // Thick material = the "glass, not solid" sheet surface (frosts the album-art
    // reflection beneath + the chat behind at medium detent), matching native.
    backdropBlurView.effect = UIBlurEffect(
      style: theme.isDark ? .systemThickMaterialDark : .systemThickMaterial)

    coverView.backgroundColor = theme.text.withAlphaComponent(theme.isDark ? 0.08 : 0.06)
    coverFallbackView.tintColor = theme.secondaryText

    titleLabel.textColor = theme.text
    artistLabel.textColor = theme.primary
    currentTimeLabel.textColor = theme.secondaryText
    durationLabel.textColor = theme.secondaryText
    queueTitleLabel.textColor = theme.secondaryText.withAlphaComponent(0.92)

    // Thumbless, clean rounded line (native Now Playing style) — no dot, no "tick-tock".
    progressSlider.setThumbImage(UIImage(), for: .normal)
    progressSlider.setThumbImage(UIImage(), for: .highlighted)
    let trackH: CGFloat = 5.0
    progressSlider.setMinimumTrackImage(
      capsuleTrackImage(color: theme.primary, height: trackH), for: .normal)
    progressSlider.setMaximumTrackImage(
      capsuleTrackImage(
        color: theme.text.withAlphaComponent(theme.isDark ? 0.20 : 0.14), height: trackH),
      for: .normal)
    shimmerProgressView.applyTheme(theme)

    shareButton.tintColor = theme.secondaryText
    shareButton.setImage(
      UIImage(systemName: "square.and.arrow.up")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 16.0, weight: .semibold)),
      for: .normal
    )
    shareButton.adjustsImageWhenHighlighted = true

    heroWaveformView.setTint(theme.primary)

    updateQueueControlButtons(animated: false)
    applyTransportButtonStyle(
      prevButton,
      systemName: "backward.fill",
      pointSize: 29.0,
      tintColor: theme.text
    )
    applyTransportButtonStyle(
      nextButton,
      systemName: "forward.fill",
      pointSize: 29.0,
      tintColor: theme.text
    )
    applyPrimaryPlayButtonStyle(forceImageRefresh: true)
    primaryActionButton.backgroundColor = theme.primary
    primaryActionButton.setTitleColor(.white, for: .normal)
    primaryActionButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
    primaryActionButton.layer.cornerCurve = .continuous
    primaryActionButton.layer.cornerRadius = 26.0
    primaryActionButton.setImage(
      UIImage(systemName: "list.bullet")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 18.0, weight: .semibold)),
      for: .normal
    )
    primaryActionButton.adjustsImageWhenHighlighted = false
    primaryActionButton.tintColor = .white

    queueModel.applyTheme(
      text: theme.text, secondary: theme.secondaryText, accent: theme.primary,
      isDark: theme.isDark)
    view.setNeedsLayout()
  }

  func updateState(
    track: NativeMusicPlayerTrack?,
    queue: [NativeMusicPlayerTrack],
    library: [NativeMusicPlayerTrack],
    isPlaying: Bool,
    progressMs: Double,
    durationMs: Double,
    queueOrderMode: NativeMusicPlayerQueueOrderMode,
    isRepeatEnabled: Bool,
    artworkImage: UIImage?,
    voiceSnapshot: VoiceBubblePlaybackSnapshot? = nil
  ) {
    let previousQueueHidden = queueTitleLabel.isHidden
    currentTrack = track
    currentQueue = queue
    currentLibrary = library
    currentArtwork = artworkImage
    self.queueOrderMode = queueOrderMode
    self.isRepeatEnabled = isRepeatEnabled

    let downloadInfo = VoiceSnapshotDownloadInfo.extract(from: voiceSnapshot)
    currentDownloadInfo = downloadInfo

    guard let track else {
      heroWaveformView.setActive(false, playing: false)
      let clearedQueue = clearQueueRowsIfNeeded()
      queueTitleLabel.isHidden = true
      if !previousQueueHidden || clearedQueue {
        view.setNeedsLayout()
      }
      return
    }

    titleLabel.text = track.title
    artistLabel.text = track.artist

    let effectiveDuration = max(durationMs, (track.durationSeconds ?? 0.0) * 1000.0)
    currentState = (progressMs, effectiveDuration, isPlaying)
    let remainingMs = max(0.0, effectiveDuration - progressMs)

    currentTimeLabel.text = Self.format(ms: progressMs)

    if downloadInfo.isDownloading {
      shimmerProgressView.isHidden = false
      progressSlider.isHidden = true
      shimmerProgressView.setProgress(downloadInfo.fraction ?? 0.0)
      shimmerProgressView.startShimmer()
      durationLabel.text = Self.formatBytes(downloaded: downloadInfo.downloadedBytes, total: downloadInfo.totalBytes)
    } else {
      shimmerProgressView.isHidden = false
      progressSlider.isHidden = false
      shimmerProgressView.stopShimmer()
      durationLabel.text = "-" + Self.format(ms: remainingMs)
      if !progressSlider.isTracking {
        let dur = max(effectiveDuration, 1.0)
        let target = Float(max(0.0, min(1.0, progressMs / dur)))
        let delta = target - progressSlider.value
        // Glide small forward ticks so the fill flows smoothly; snap on seek /
        // track change (large jump) or any backward move.
        let animate = delta > 0.0001 && delta < 0.08
        progressSlider.setValue(target, animated: animate)
      }
    }

    updatePlayButton(isPlaying: isPlaying)
    heroWaveformView.setActive(true, playing: isPlaying)
    updateCoverIfNeeded(for: track, directImage: artworkImage)
    let queueDidChange = updateQueueRowsIfNeeded(
      track: track,
      queue: queue,
      library: library,
      artworkImage: artworkImage
    )
    updateQueueControlButtons()

    if queueDidChange || previousQueueHidden != queueTitleLabel.isHidden {
      view.setNeedsLayout()
    }
  }

  var isModalVisible: Bool { isShowing }

  func show(animated: Bool = true) {
    guard !isShowing else { return }
    isShowing = true
    guard let controller = topMostViewController() else { return }
    controller.present(self, animated: animated)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    stopMorphDisplayLink()
    if isBeingDismissed {
      isShowing = false
      onDismiss?()
    }
  }

  @objc func dismissModal(animated: Bool = true) {
    dismiss(animated: animated)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()

    let width = view.bounds.width
    let height = view.bounds.height
    let pad: CGFloat = 24.0
    let usableWidth = max(0.0, width - (pad * 2.0))

    // Settled-detent bookkeeping only — NEVER gates layout geometry below.
    if let sheet = sheetPresentationController {
      let isLarge = (sheet.selectedDetentIdentifier == .large)
      if isLargeDetent != isLarge {
        isLargeDetent = isLarge
        captureSettledSheetHeightsIfNeeded()
      }
    }

    // Ensure first layout uses seeded compact progress (0) before height sampling.
    if !hasSeededExpandProgress {
      seedExpandProgressFromDetentIfNeeded()
    } else if morphDisplayLink != nil || isShowing {
      updateExpandProgressFromSheetHeight()
    }
    lastAppliedExpandProgress = expandProgress
    let t = expandProgress

    sheetContent.frame = view.bounds
    blurredBackdropView.frame = sheetContent.bounds
    // Frosted glass is full-bleed over the reflection — always present, never morph-faded.
    backdropBlurView.frame = sheetContent.bounds

    let topY: CGFloat = 16.0

    // Compact geometry (progress = 0)
    let compactSide: CGFloat = 72.0
    let compactCover = CGRect(x: pad, y: topY, width: compactSide, height: compactSide)
    let compactRadius: CGFloat = 14.0
    let compactShareSide: CGFloat = 22.0
    let compactTitleH: CGFloat = 20.0
    let compactArtistH: CGFloat = 18.0
    let compactTextBlockH = compactTitleH + 4.0 + compactArtistH
    let compactLabelX = compactCover.maxX + 16.0
    let compactLabelW = max(0.0, width - pad - compactLabelX - compactShareSide - 16.0)
    let compactTitleY = topY + floor((compactSide - compactTextBlockH) * 0.5)
    let compactTitleFrame = CGRect(
      x: compactLabelX, y: compactTitleY, width: compactLabelW, height: compactTitleH)
    let compactArtistFrame = CGRect(
      x: compactLabelX, y: compactTitleFrame.maxY + 4.0, width: compactLabelW, height: compactArtistH)
    let compactTitleDisplayW = min(titleLabel.intrinsicContentSize.width, compactLabelW)
    // Waveform visualizer rides the title's trailing edge (native now-playing indicator).
    let compactWaveW: CGFloat = 24.0
    let compactWaveH: CGFloat = 16.0
    let compactWaveFrame = CGRect(
      x: min(compactLabelX + compactTitleDisplayW + 8.0, width - pad - compactWaveW),
      y: compactTitleFrame.midY - compactWaveH * 0.5,
      width: compactWaveW,
      height: compactWaveH
    )
    let compactNextY = compactCover.maxY + 20.0

    // Hero geometry (progress = 1)
    let heroSide = min(usableWidth, min(width - 48.0, height * 0.38))
    let heroCover = CGRect(
      x: floor((width - heroSide) * 0.5), y: topY, width: heroSide, height: heroSide)
    let heroRadius: CGFloat = 24.0
    let heroShareSide: CGFloat = 24.0
    let heroTitleH: CGFloat = 22.0
    let heroArtistH: CGFloat = 20.0
    let heroTextY = heroCover.maxY + 24.0
    let heroTextW = max(0.0, usableWidth - heroShareSide - 12.0)
    let heroTitleFrame = CGRect(x: pad, y: heroTextY, width: heroTextW, height: heroTitleH)
    let heroArtistFrame = CGRect(
      x: pad, y: heroTitleFrame.maxY + 4.0, width: heroTextW, height: heroArtistH)
    let heroTitleDisplayW = min(titleLabel.intrinsicContentSize.width, heroTextW)
    let heroWaveW: CGFloat = 30.0
    let heroWaveH: CGFloat = 20.0
    let heroWaveFrame = CGRect(
      x: min(pad + heroTitleDisplayW + 8.0, width - pad - heroWaveW),
      y: heroTitleFrame.midY - heroWaveH * 0.5,
      width: heroWaveW,
      height: heroWaveH
    )
    let heroNextY = max(heroArtistFrame.maxY, heroWaveFrame.maxY) + 20.0

    // Continuous morph — interpolate, never branch on isLargeDetent.
    let coverFrame = Self.lerpRect(compactCover, heroCover, t: t)
    let cornerRadius = compactRadius + (heroRadius - compactRadius) * t
    coverTapControl.frame = coverFrame
    coverView.frame = coverTapControl.bounds
    coverView.layer.cornerRadius = cornerRadius
    let fallbackInset = 20.0 + (heroSide * 0.28 - 20.0) * t
    coverFallbackView.frame = coverTapControl.bounds.insetBy(dx: fallbackInset, dy: fallbackInset)

    titleLabel.textAlignment = .left
    artistLabel.textAlignment = .left
    titleLabel.frame = Self.lerpRect(compactTitleFrame, heroTitleFrame, t: t)
    artistLabel.frame = Self.lerpRect(compactArtistFrame, heroArtistFrame, t: t)
    heroWaveformView.frame = Self.lerpRect(compactWaveFrame, heroWaveFrame, t: t)

    // Share is a subtle top-right affordance, only present when expanded (fades with t).
    let shareSide: CGFloat = 30.0
    shareButton.frame = CGRect(
      x: width - pad - shareSide, y: topY - 2.0, width: shareSide, height: shareSide)
    shareButton.alpha = t
    shareButton.isUserInteractionEnabled = t > 0.5

    var y = compactNextY + (heroNextY - compactNextY) * t

    currentTimeLabel.frame = CGRect(x: pad, y: y, width: 64.0, height: 16.0)
    durationLabel.frame = CGRect(x: width - pad - 120.0, y: y, width: 120.0, height: 16.0)
    y = currentTimeLabel.frame.maxY + 6.0

    let sliderFrame = CGRect(x: pad, y: y, width: usableWidth, height: 20.0)
    progressSlider.frame = sliderFrame
    shimmerProgressView.frame = CGRect(x: pad, y: y + 8.0, width: usableWidth, height: 4.0)
    y = sliderFrame.maxY + 16.0

    let utilitySide: CGFloat = 44.0
    let navSide: CGFloat = 54.0
    let playSide: CGFloat = 72.0
    let outerGap: CGFloat = 18.0
    let centerGap: CGFloat = 26.0
    let controlRowWidth = utilitySide + outerGap + navSide + centerGap + playSide + centerGap + navSide + outerGap + utilitySide
    let controlStartX = floor((width - controlRowWidth) * 0.5)

    rateButton.frame = CGRect(
      x: controlStartX,
      y: y + floor((playSide - utilitySide) * 0.5),
      width: utilitySide,
      height: utilitySide
    )
    prevButton.frame = CGRect(
      x: rateButton.frame.maxX + outerGap,
      y: y + floor((playSide - navSide) * 0.5),
      width: navSide,
      height: navSide
    )
    playButton.frame = CGRect(
      x: prevButton.frame.maxX + centerGap,
      y: y,
      width: playSide,
      height: playSide
    )
    nextButton.frame = CGRect(
      x: playButton.frame.maxX + centerGap,
      y: prevButton.frame.minY,
      width: navSide,
      height: navSide
    )
    artworkModeButton.frame = CGRect(
      x: nextButton.frame.maxX + outerGap,
      y: rateButton.frame.minY,
      width: utilitySide,
      height: utilitySide
    )
    y = playButton.frame.maxY + 20.0

    queueTitleLabel.font = .systemFont(ofSize: 12, weight: .bold)
    queueTitleLabel.text = "AUDIO IN THIS CHAT"
    queueTitleLabel.frame = CGRect(x: pad, y: y, width: usableWidth, height: 16.0)
    y = queueTitleLabel.frame.maxY + 10.0

    let bottomInset = view.safeAreaInsets.bottom + 8.0
    let queueHeight = max(0.0, height - y - bottomInset)
    // SwiftUI List's own default row insets already pad the leading edge, so bleed the
    // host to full width and let the list handle its own inset + scrolling.
    queueHostingController.view.frame = CGRect(
      x: pad - 4.0, y: y, width: usableWidth + 8.0, height: queueHeight)
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) { }

  @objc private func handlePlay() { onTogglePlayback?() }
  @objc private func handlePrev() { onPlayPrev?() }
  @objc private func handleNext() { onPlayNext?() }
  @objc private func handleQueueOrderToggle() { onToggleQueueOrder?() }
  @objc private func handleRepeatToggle() { onToggleRepeat?() }

  @objc private func handleArtworkModeToggle() {
    setExpandedDetent(!isLargeDetent, animated: true)
  }

  @objc private func handleShare() {
    guard let currentTrack else { return }
    var items: [Any] = []
    let shareText = [currentTrack.title, currentTrack.artist]
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: " • ")
    if !shareText.isEmpty { items.append(shareText) }
    if let url = shareURL(for: currentTrack) { items.append(url) }
    guard !items.isEmpty, let controller = topMostViewController() else { return }
    let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
    if let popover = activity.popoverPresentationController {
      popover.sourceView = shareButton
      popover.sourceRect = shareButton.bounds
    }
    controller.present(activity, animated: true)
  }

  @objc private func sliderChanged() {
    pendingSeekValue = progressSlider.value
    let duration = max(currentState.durationMs, 1.0)
    currentTimeLabel.text = Self.format(ms: Double(progressSlider.value) * duration)
  }

  @objc private func sliderCommit() {
    guard let pendingSeekValue else { return }
    self.pendingSeekValue = nil
    onSeek?(Double(pendingSeekValue) * max(currentState.durationMs, 1.0))
  }

  private func applyTransportButtonStyle(
    _ button: UIButton,
    systemName: String,
    pointSize: CGFloat,
    tintColor: UIColor,
    animated: Bool = false
  ) {
    let update = {
      button.configuration = .plain()
      button.configuration?.contentInsets = .zero
      button.tintColor = tintColor
      button.setImage(
        UIImage(systemName: systemName)?.withConfiguration(
          UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        ),
        for: .normal
      )
      button.adjustsImageWhenHighlighted = true
    }
    // No crossfade on icon swaps anywhere in the transport row — the dissolve ghosts
    // badly (same reason the primary play/pause button no longer fades). Swap directly.
    _ = animated
    update()
  }

  private func applyPrimaryPlayButtonStyle(forceImageRefresh: Bool) {
    playButton.configuration = .plain()
    playButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 0.0, leading: 0.0, bottom: 0.0, trailing: 0.0)
    playButton.tintColor = theme.text
    playButton.backgroundColor = UIColor.clear
    playButton.layer.cornerRadius = 36.0
    playButton.layer.cornerCurve = .continuous
    playButton.adjustsImageWhenHighlighted = false
    updatePlayButtonImage(animated: false, force: forceImageRefresh)
  }

  private func updatePlayButton(isPlaying: Bool) {
    currentState.isPlaying = isPlaying
    updatePlayButtonImage(animated: renderedPlayButtonIsPlaying != nil)
  }

  private func updatePlayButtonImage(animated: Bool, force: Bool = false) {
    let targetIsPlaying = currentState.isPlaying
    guard force || renderedPlayButtonIsPlaying != targetIsPlaying else { return }
    renderedPlayButtonIsPlaying = targetIsPlaying

    let iconName = targetIsPlaying ? "pause.fill" : "play.fill"
    let image = UIImage(systemName: iconName)?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 38.0, weight: .bold)
    )
    // Direct swap — no crossfade / opacity dissolve (reads muddy on transport).
    playButton.setImage(image, for: .normal)
    if animated {
      playButton.layer.removeAnimation(forKey: "playSymbolBounce")
      playButton.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
      UIView.animate(
        withDuration: 0.18,
        delay: 0.0,
        usingSpringWithDamping: 0.62,
        initialSpringVelocity: 0.9,
        options: [.allowUserInteraction, .beginFromCurrentState]
      ) {
        self.playButton.transform = .identity
      }
    }
  }

  private func queueOrderIconName() -> String {
    switch queueOrderMode {
    case .forward: return "chevron.down"
    case .reverse: return "chevron.up"
    case .random: return "shuffle"
    }
  }

  private func queueOrderTintColor() -> UIColor {
    switch queueOrderMode {
    case .forward: return theme.secondaryText
    case .reverse, .random: return theme.primary
    }
  }

  private func updateQueueControlButtons(animated: Bool = true) {
    applyTransportButtonStyle(
      rateButton,
      systemName: queueOrderIconName(),
      pointSize: 16.0,
      tintColor: queueOrderTintColor(),
      animated: animated
    )
    applyTransportButtonStyle(
      artworkModeButton,
      systemName: isRepeatEnabled ? "repeat.1" : "repeat",
      pointSize: 16.0,
      tintColor: isRepeatEnabled ? theme.primary : theme.secondaryText.withAlphaComponent(0.8),
      animated: animated
    )
  }

  private func updateCoverIfNeeded(for track: NativeMusicPlayerTrack, directImage: UIImage?) {
    let normalizedCoverURL = track.cover?.trimmingCharacters(in: .whitespacesAndNewlines)
    let imageIdentifier = directImage.map(ObjectIdentifier.init)
    guard
      renderedCoverTrackId != track.trackId
        || renderedCoverURL != normalizedCoverURL
        || renderedCoverImageIdentifier != imageIdentifier
    else { return }

    renderedCoverTrackId = track.trackId
    renderedCoverURL = normalizedCoverURL
    renderedCoverImageIdentifier = imageIdentifier
    updateCover(urlString: normalizedCoverURL, directImage: directImage)
  }

  private func updateCover(urlString: String?, directImage: UIImage?) {
    coverImageTask?.cancel()
    coverImageTask = nil

    let applyImage: (UIImage) -> Void = { [weak self] image in
      guard let self else { return }
      self.coverView.image = image
      self.blurredBackdropView.image = image
      self.coverFallbackView.isHidden = true
    }

    if let directImage {
      applyImage(directImage)
      return
    }

    guard
      let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      coverView.image = nil
      blurredBackdropView.image = nil
      coverFallbackView.isHidden = false
      return
    }

    // Keep previous cover visible until the cached/network image arrives (no flash).
    if coverView.image == nil {
      coverFallbackView.isHidden = false
    }

    let expectedURL = trimmed
    let expectedTrackId = renderedCoverTrackId
    coverImageTask = chatLoadMusicCover(urlString: trimmed) { [weak self] image in
      guard let self else { return }
      guard self.renderedCoverURL == expectedURL,
        self.renderedCoverTrackId == expectedTrackId
      else { return }
      applyImage(image)
    }
  }

  private func updateQueueRowsIfNeeded(
    track: NativeMusicPlayerTrack,
    queue: [NativeMusicPlayerTrack],
    library: [NativeMusicPlayerTrack],
    artworkImage: UIImage?
  ) -> Bool {
    let tracks: [NativeMusicPlayerTrack]
    if hasLocalQueueOrderOverride, !renderedQueueTracks.isEmpty {
      // Keep drag/remove order; drop suppressed; append any newly-arrived tracks.
      var seen = Set(renderedQueueTracks.map(\.trackId))
      var merged = renderedQueueTracks.filter { !suppressedTrackIds.contains($0.trackId) }
      let fresh = resolvedDisplayTracks(currentTrack: track, queue: queue, library: library)
      for candidate in fresh where !seen.contains(candidate.trackId) {
        seen.insert(candidate.trackId)
        merged.append(candidate)
      }
      // Prefer fresher metadata (cover/title) for matching ids while keeping order.
      let byId = Dictionary(uniqueKeysWithValues: fresh.map { ($0.trackId, $0) })
      merged = merged.map { byId[$0.trackId] ?? $0 }
      tracks = merged
    } else {
      tracks = resolvedDisplayTracks(currentTrack: track, queue: queue, library: library)
    }

    let queueWasHidden = queueTitleLabel.isHidden
    queueTitleLabel.isHidden = tracks.isEmpty

    let structureChanged = tracks.map(\.trackId) != renderedQueueTracks.map(\.trackId)
    renderedQueueTracks = tracks

    // Push the whole list into the SwiftUI model; its @Published diffing animates rows.
    let vms: [NativeMusicPlayerQueueRowVM] = tracks.map { candidate in
      let cover = candidate.cover?.trimmingCharacters(in: .whitespacesAndNewlines)
      let directArt =
        ChatAudioQueueRegistry.shared.artwork(for: candidate.trackId, in: candidate.links["chat_id"])
        ?? (candidate.trackId == track.trackId ? artworkImage : nil)
      return NativeMusicPlayerQueueRowVM(
        id: candidate.trackId,
        title: candidate.title,
        subtitle: queueSubtitle(for: candidate),
        coverURL: (cover?.isEmpty == false) ? cover : nil,
        directArtwork: directArt
      )
    }
    queueModel.update(
      items: vms, activeTrackId: track.trackId, isPlaying: currentState.isPlaying)

    return structureChanged || queueWasHidden != queueTitleLabel.isHidden
  }

  private func queueSubtitle(for track: NativeMusicPlayerTrack) -> String {
    let parts = [track.duration, track.artist].compactMap { value -> String? in
      guard let value, !value.isEmpty else { return nil }
      return value
    }
    return parts.isEmpty ? "Audio" : parts.joined(separator: " • ")
  }

  private func clearQueueRowsIfNeeded() -> Bool {
    guard !renderedQueueTracks.isEmpty else { return false }
    renderedQueueTracks = []
    suppressedTrackIds.removeAll()
    hasLocalQueueOrderOverride = false
    queueModel.update(items: [], activeTrackId: nil, isPlaying: false)
    return true
  }

  /// Chat music list: store tracks for the active chat (incl. not-downloaded),
  /// merged with the coordinator/engine queue + library, always containing the
  /// currently-playing track (highlighted by the caller). Deduped by trackId and
  /// by exact title+artist so the same song never appears twice.
  private func resolvedDisplayTracks(
    currentTrack: NativeMusicPlayerTrack,
    queue: [NativeMusicPlayerTrack],
    library: [NativeMusicPlayerTrack]
  ) -> [NativeMusicPlayerTrack] {
    var seenIds = Set<String>()
    var seenTitleArtist = Set<String>()
    var tracks: [NativeMusicPlayerTrack] = []

    func identityKey(_ track: NativeMusicPlayerTrack) -> String {
      let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return "\(title)|\(artist)"
    }

    func append(_ candidates: [NativeMusicPlayerTrack]) {
      for candidate in candidates {
        if suppressedTrackIds.contains(candidate.trackId) { continue }
        guard seenIds.insert(candidate.trackId).inserted else { continue }
        let key = identityKey(candidate)
        // Drop exact title+artist duplicates (different ids for the same song).
        if !key.hasPrefix("|"), !seenTitleArtist.insert(key).inserted { continue }
        tracks.append(candidate)
      }
    }

    let chatId =
      currentTrack.links["chat_id"]
      ?? currentTrack.links["chatId"]
    if let chatId, !chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      // Fully merge every chat track from the shared store.
      append(NativeMusicPlayerStore.shared.tracks(forChatId: chatId))
      // Registry is the live chat transcript source (also cached into the store).
      append(ChatAudioQueueRegistry.shared.tracks(for: chatId))
    }
    append(queue)
    append(library)
    // Currently-playing track must always appear (even if missing from store/queue).
    if !suppressedTrackIds.contains(currentTrack.trackId),
      seenIds.insert(currentTrack.trackId).inserted
    {
      let key = identityKey(currentTrack)
      if key.hasPrefix("|") || seenTitleArtist.insert(key).inserted {
        tracks.insert(currentTrack, at: 0)
      }
    } else if !suppressedTrackIds.contains(currentTrack.trackId) {
      // Already present by id — prefer richer cover metadata on the playing row.
      if let idx = tracks.firstIndex(where: { $0.trackId == currentTrack.trackId }),
        tracks[idx].cover == nil, currentTrack.cover != nil
      {
        tracks[idx] = currentTrack
      }
    }
    return tracks
  }

  // MARK: - Next-Up swipe actions (SwiftUI list callbacks)

  /// Trailing swipe → Delete: hide the track locally and persist the remaining order.
  private func handleRemoveTrack(_ trackId: String) {
    suppressedTrackIds.insert(trackId)
    hasLocalQueueOrderOverride = true
    renderedQueueTracks.removeAll { $0.trackId == trackId }
    onRemoveTrack?(trackId)
    onReorderQueue?(renderedQueueTracks.map(\.trackId))
    queueModel.update(
      items: queueModel.items.filter { $0.id != trackId },
      activeTrackId: queueModel.activeTrackId,
      isPlaying: queueModel.isPlaying)
  }

  /// Leading swipe → Play Next: move the track to immediately after the current one.
  private func handlePlayNextTrack(_ trackId: String) {
    guard let currentId = renderedQueueTracks.first?.trackId, currentId != trackId else { return }
    var order = renderedQueueTracks.map(\.trackId)
    guard let from = order.firstIndex(of: trackId),
      let currentIndex = order.firstIndex(of: currentId)
    else { return }
    order.remove(at: from)
    let insertAt = min(currentIndex + 1, order.count)
    order.insert(trackId, at: insertAt)
    applyLocalOrder(order)
  }

  /// Drag-to-reorder (SwiftUI `.onMove`): adopt the new order and persist it.
  private func handleReorderTracks(_ orderedIds: [String]) {
    applyLocalOrder(orderedIds)
  }

  private func applyLocalOrder(_ orderedIds: [String]) {
    let byId = Dictionary(renderedQueueTracks.map { ($0.trackId, $0) }, uniquingKeysWith: { a, _ in a })
    renderedQueueTracks = orderedIds.compactMap { byId[$0] }
    hasLocalQueueOrderOverride = true
    onReorderQueue?(orderedIds)
    // Reflect the new order in the list immediately (keep active + playing state).
    let orderRank = Dictionary(uniqueKeysWithValues: orderedIds.enumerated().map { ($1, $0) })
    let reordered = queueModel.items.sorted {
      (orderRank[$0.id] ?? Int.max) < (orderRank[$1.id] ?? Int.max)
    }
    queueModel.update(
      items: reordered, activeTrackId: queueModel.activeTrackId, isPlaying: queueModel.isPlaying)
  }

  private static func lerpRect(_ a: CGRect, _ b: CGRect, t: CGFloat) -> CGRect {
    let clamped = min(1.0, max(0.0, t))
    return CGRect(
      x: a.origin.x + (b.origin.x - a.origin.x) * clamped,
      y: a.origin.y + (b.origin.y - a.origin.y) * clamped,
      width: a.size.width + (b.size.width - a.size.width) * clamped,
      height: a.size.height + (b.size.height - a.size.height) * clamped
    )
  }

  /// A horizontally-resizable rounded capsule used as a UISlider track image, giving a
  /// thick rounded line with no thumb (matches the native Now Playing progress bar).
  private func capsuleTrackImage(color: UIColor, height: CGFloat) -> UIImage {
    let radius = height / 2.0
    let size = CGSize(width: height, height: height)
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { _ in
      color.setFill()
      UIBezierPath(
        roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius
      ).fill()
    }
    let cap = max(0.0, radius - 0.5)
    return image
      .resizableImage(
        withCapInsets: UIEdgeInsets(top: 0.0, left: cap, bottom: 0.0, right: cap),
        resizingMode: .stretch
      )
      .withRenderingMode(.alwaysOriginal)
  }

  private func shareURL(for track: NativeMusicPlayerTrack) -> URL? {
    let candidates = [track.localURI, track.streamURL, track.previewURL, track.cover]
    for candidate in candidates {
      guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { continue }
      if let url = URL(string: trimmed) { return url }
      if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
    }
    return nil
  }

  private func topMostViewController() -> UIViewController? {
    guard
      let root =
        view.window?.rootViewController
        ?? UIApplication.shared.connectedScenes
        .compactMap({ scene -> UIViewController? in
          guard let windowScene = scene as? UIWindowScene else { return nil }
          return windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        })
        .first
    else { return nil }
    var top = root
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }

  static func format(ms: Double) -> String {
    guard ms.isFinite, ms > 0.0 else { return "0:00" }
    let seconds = Int((ms / 1000.0).rounded())
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  static func formatBytes(downloaded: Int64?, total: Int64?) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useMB, .useKB, .useBytes]
    if let downloaded = downloaded, let total = total, total > 0 {
      return "\(formatter.string(fromByteCount: downloaded)) / \(formatter.string(fromByteCount: total))"
    } else if let downloaded = downloaded {
      return formatter.string(fromByteCount: downloaded)
    } else if let total = total, total > 0 {
      return formatter.string(fromByteCount: total)
    }
    return "Downloading…"
  }
}

// MARK: - SwiftUI "Next Up" queue (native swipe + drag-reorder)

struct NativeMusicPlayerQueueRowVM: Identifiable, Equatable {
  let id: String
  let title: String
  let subtitle: String
  let coverURL: String?
  let directArtwork: UIImage?

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
      && lhs.coverURL == rhs.coverURL && lhs.directArtwork === rhs.directArtwork
  }
}

/// Drives the hosted SwiftUI list. The modal pushes state in; the list calls back for
/// select / play-next / delete / reorder.
final class NativeMusicPlayerQueueModel: ObservableObject {
  @Published fileprivate var items: [NativeMusicPlayerQueueRowVM] = []
  @Published fileprivate var activeTrackId: String?
  @Published fileprivate var isPlaying: Bool = false
  @Published fileprivate var textColor: Color = .primary
  @Published fileprivate var secondaryColor: Color = .secondary
  @Published fileprivate var accentColor: Color = .accentColor

  var onSelect: ((String) -> Void)?
  var onPlayNext: ((String) -> Void)?
  var onRemove: ((String) -> Void)?
  var onMove: (([String]) -> Void)?

  func applyTheme(text: UIColor, secondary: UIColor, accent: UIColor, isDark: Bool) {
    textColor = Color(uiColor: text)
    secondaryColor = Color(uiColor: secondary)
    accentColor = Color(uiColor: accent)
  }

  func update(items: [NativeMusicPlayerQueueRowVM], activeTrackId: String?, isPlaying: Bool) {
    if self.items != items { self.items = items }
    if self.activeTrackId != activeTrackId { self.activeTrackId = activeTrackId }
    if self.isPlaying != isPlaying { self.isPlaying = isPlaying }
  }
}

struct NativeMusicPlayerQueueListView: View {
  @ObservedObject var model: NativeMusicPlayerQueueModel

  var body: some View {
    List {
      ForEach(model.items) { item in
        NativeMusicPlayerQueueRow(
          item: item,
          isActive: item.id == model.activeTrackId,
          isPlaying: model.isPlaying,
          textColor: model.textColor,
          secondaryColor: model.secondaryColor,
          accentColor: model.accentColor
        )
        .contentShape(Rectangle())
        .onTapGesture { model.onSelect?(item.id) }
        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(model.textColor.opacity(0.10))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
          Button {
            model.onPlayNext?(item.id)
          } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
          }
          .tint(model.accentColor)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
          Button(role: .destructive) {
            model.onRemove?(item.id)
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
      }
      .onMove { indices, newOffset in
        var arr = model.items
        arr.move(fromOffsets: indices, toOffset: newOffset)
        model.items = arr
        model.onMove?(arr.map(\.id))
      }
    }
    .listStyle(.plain)
    .clearListBackground()
    .background(Color.clear)
    .environment(\.defaultMinListRowHeight, 64)
  }
}

private struct NativeMusicPlayerQueueRow: View {
  let item: NativeMusicPlayerQueueRowVM
  let isActive: Bool
  let isPlaying: Bool
  let textColor: Color
  let secondaryColor: Color
  let accentColor: Color

  var body: some View {
    HStack(spacing: 12) {
      NativeMusicPlayerQueueArtwork(
        coverURL: item.coverURL, directArtwork: item.directArtwork, accent: accentColor)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(isActive ? accentColor : textColor)
          .lineLimit(1)
        Text(item.subtitle)
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(secondaryColor)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      if isActive {
        NowPlayingWaveformSymbol(isPlaying: isPlaying, tint: accentColor)
      }
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct NativeMusicPlayerQueueArtwork: View {
  let coverURL: String?
  let directArtwork: UIImage?
  let accent: Color
  @State private var loaded: UIImage?

  var body: some View {
    ZStack {
      if let image = directArtwork ?? loaded {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        accent.opacity(0.9)
        Image(systemName: "music.note")
          .font(.system(size: 18, weight: .semibold))
          .foregroundColor(.white)
      }
    }
    .frame(width: 52, height: 52)
    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    .onAppear(perform: load)
    .onChange(of: coverURL) { _ in
      loaded = nil
      load()
    }
  }

  private func load() {
    guard directArtwork == nil, let coverURL, !coverURL.isEmpty else { return }
    _ = chatLoadMusicCover(urlString: coverURL) { image in
      self.loaded = image
    }
  }
}

/// Native SF Symbol equalizer for the now-playing row (variableColor animation, iOS 17+).
private struct NowPlayingWaveformSymbol: View {
  let isPlaying: Bool
  let tint: Color

  var body: some View {
    Image(systemName: "waveform")
      .font(.system(size: 18, weight: .semibold))
      .foregroundColor(tint)
      .modifier(WaveformSymbolEffect(isPlaying: isPlaying))
  }
}

private struct WaveformSymbolEffect: ViewModifier {
  let isPlaying: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if #available(iOS 17.0, *) {
      content.symbolEffect(
        .variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: isPlaying)
    } else {
      content.opacity(isPlaying ? 1.0 : 0.55)
    }
  }
}

extension View {
  /// Clears the List's default opaque background where supported (iOS 16+).
  @ViewBuilder fileprivate func clearListBackground() -> some View {
    if #available(iOS 16.0, *) {
      self.scrollContentBackground(.hidden)
    } else {
      self
    }
  }
}
