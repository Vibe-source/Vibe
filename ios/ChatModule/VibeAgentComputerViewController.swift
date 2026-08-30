import UIKit

/// The live Computer sheet (agent-computer-v1 §2): Screen is live in this slice,
/// Terminal and Files are labelled placeholders until their phase lands.
@available(iOS 13.0, *)
final class VibeAgentComputerViewController: UIViewController {

  private enum Tab: Int {
    case screen = 0
    case terminal = 1
    case files = 2
  }

  private let session: VibeAgentComputerSession
  private let appearance: VibeAgentKitChatAppearance
  private let agentTitle: String

  private let headerBar = UIView()
  private let closeButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let tabControl = UISegmentedControl(items: ["Screen", "Terminal", "Files"])

  private let screenContainer = UIView()
  private let terminalPlaceholder = VibeAgentComputerPlaceholderView()
  private let filesPlaceholder = VibeAgentComputerPlaceholderView()

  // Natively drawn browser chrome — a 12pt captured browser control is untappable on a
  // phone, so the URL pill, title, load bar and LIVE dot are real views over the pixels.
  private let chromeBar = UIView()
  private let chromeBackButton = UIButton(type: .system)
  private let urlPill = UIControl()
  private let urlGlyph = UIImageView()
  private let urlLabel = UILabel()
  private let liveBadge = UIView()
  private let liveDot = UIView()
  private let liveLabel = UILabel()
  private let pageTitleLabel = UILabel()
  private let loadTrack = UIView()
  private let loadFill = UIView()

  private let viewportView = VibeAgentComputerViewportView()
  private let statusLabel = UILabel()
  private let bottomBar = UIView()
  private let controlButton = UIButton(type: .system)
  private let stopButton = UIButton(type: .system)

  private var contentBottomConstraint: NSLayoutConstraint?
  private var keyboardObservers: [NSObjectProtocol] = []
  private var loading = false
  private var linkUp = false
  private var endedReason: String?
  private var hasFrame = false

  init(
    session: VibeAgentComputerSession,
    agentTitle: String,
    appearance: VibeAgentKitChatAppearance
  ) {
    self.session = session
    self.agentTitle = agentTitle
    self.appearance = appearance
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) { return nil }

  deinit {
    for observer in keyboardObservers { NotificationCenter.default.removeObserver(observer) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = appearance.background
    buildHeader()
    buildScreenTab()
    buildPlaceholders()
    layout()
    observeKeyboard()
    wireSession()
    applyTab(.screen)
    applyControlState()
    session.start()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // The sheet is the session's whole lifetime: leaving it can never leave a poller up.
    if isBeingDismissed || presentingViewController == nil { session.stop() }
  }

  // MARK: - Build

  private func buildHeader() {
    headerBar.translatesAutoresizingMaskIntoConstraints = false

    closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
    closeButton.tintColor = appearance.textSecondary
    closeButton.accessibilityLabel = "Close"
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    closeButton.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.text = "Computer"
    titleLabel.font = .systemFont(ofSize: 17.0, weight: .semibold)
    titleLabel.textColor = appearance.text
    titleLabel.textAlignment = .center
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    subtitleLabel.text = agentTitle
    subtitleLabel.font = .systemFont(ofSize: 12.0, weight: .regular)
    subtitleLabel.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.8)
    subtitleLabel.textAlignment = .center
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

    tabControl.selectedSegmentIndex = 0
    tabControl.selectedSegmentTintColor = appearance.surfaceElevated
    tabControl.backgroundColor = vibeAgentKitColorWithAlpha(appearance.surface, 0.9)
    tabControl.setTitleTextAttributes([.foregroundColor: appearance.textSecondary], for: .normal)
    tabControl.setTitleTextAttributes([.foregroundColor: appearance.text], for: .selected)
    tabControl.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
    tabControl.translatesAutoresizingMaskIntoConstraints = false

    headerBar.addSubview(closeButton)
    headerBar.addSubview(titleLabel)
    headerBar.addSubview(subtitleLabel)
    view.addSubview(headerBar)
    view.addSubview(tabControl)
  }

  private func buildScreenTab() {
    screenContainer.translatesAutoresizingMaskIntoConstraints = false

    chromeBar.backgroundColor = appearance.surface
    chromeBar.layer.cornerRadius = 14.0
    chromeBar.layer.borderWidth = 1.0
    chromeBar.layer.borderColor = vibeAgentKitColorWithAlpha(appearance.border, 0.7).cgColor
    chromeBar.clipsToBounds = true
    chromeBar.translatesAutoresizingMaskIntoConstraints = false

    chromeBackButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    chromeBackButton.tintColor = appearance.textSecondary
    chromeBackButton.accessibilityLabel = "Back"
    chromeBackButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
    chromeBackButton.translatesAutoresizingMaskIntoConstraints = false

    urlPill.backgroundColor = appearance.surfaceElevated
    urlPill.layer.cornerRadius = 15.0
    urlPill.addTarget(self, action: #selector(urlTapped), for: .touchUpInside)
    urlPill.translatesAutoresizingMaskIntoConstraints = false

    urlGlyph.image = UIImage(systemName: "globe")
    urlGlyph.tintColor = vibeAgentKitColorWithAlpha(appearance.textTertiary, 0.9)
    urlGlyph.contentMode = .scaleAspectFit
    urlGlyph.translatesAutoresizingMaskIntoConstraints = false

    urlLabel.text = "about:blank"
    urlLabel.font = .systemFont(ofSize: 13.0, weight: .medium)
    urlLabel.textColor = appearance.text
    urlLabel.lineBreakMode = .byTruncatingTail
    urlLabel.translatesAutoresizingMaskIntoConstraints = false

    liveBadge.backgroundColor = vibeAgentKitColorWithAlpha(appearance.surfaceElevated, 0.9)
    liveBadge.layer.cornerRadius = 11.0
    liveBadge.translatesAutoresizingMaskIntoConstraints = false

    liveDot.backgroundColor = UIColor(red: 0.16, green: 0.78, blue: 0.45, alpha: 1.0)
    liveDot.layer.cornerRadius = 3.5
    liveDot.translatesAutoresizingMaskIntoConstraints = false

    liveLabel.text = "LIVE"
    liveLabel.font = .systemFont(ofSize: 10.0, weight: .bold)
    liveLabel.textColor = appearance.textSecondary
    liveLabel.translatesAutoresizingMaskIntoConstraints = false

    pageTitleLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
    pageTitleLabel.textColor = vibeAgentKitColorWithAlpha(appearance.textTertiary, 0.95)
    pageTitleLabel.lineBreakMode = .byTruncatingTail
    pageTitleLabel.translatesAutoresizingMaskIntoConstraints = false

    loadTrack.backgroundColor = .clear
    loadTrack.clipsToBounds = true
    loadTrack.translatesAutoresizingMaskIntoConstraints = false
    loadFill.backgroundColor = appearance.primary
    loadFill.isHidden = true

    liveBadge.addSubview(liveDot)
    liveBadge.addSubview(liveLabel)
    loadTrack.addSubview(loadFill)
    chromeBar.addSubview(chromeBackButton)
    chromeBar.addSubview(urlPill)
    chromeBar.addSubview(liveBadge)
    chromeBar.addSubview(pageTitleLabel)
    chromeBar.addSubview(loadTrack)
    urlPill.addSubview(urlGlyph)
    urlPill.addSubview(urlLabel)

    viewportView.apply(appearance: appearance)
    viewportView.translatesAutoresizingMaskIntoConstraints = false
    viewportView.onPoint = { [weak self] point in self?.session.sendClick(at: point) }
    viewportView.onText = { [weak self] text in self?.session.sendText(text) }
    viewportView.onKey = { [weak self] key in self?.session.sendKey(key) }
    viewportView.onScroll = { [weak self] delta in self?.session.sendScroll(deltaY: delta) }

    statusLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
    statusLabel.textColor = appearance.textSecondary
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 2
    statusLabel.translatesAutoresizingMaskIntoConstraints = false

    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    styleFilled(controlButton, title: "Take control")
    controlButton.addTarget(self, action: #selector(controlTapped), for: .touchUpInside)
    styleOutlined(stopButton, title: "Stop")
    stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
    bottomBar.addSubview(controlButton)
    bottomBar.addSubview(stopButton)

    screenContainer.addSubview(chromeBar)
    screenContainer.addSubview(viewportView)
    screenContainer.addSubview(statusLabel)
    screenContainer.addSubview(bottomBar)
    view.addSubview(screenContainer)
  }

  private func buildPlaceholders() {
    terminalPlaceholder.configure(
      appearance: appearance,
      glyph: "terminal",
      title: "Terminal",
      body: "The read-only console of the agent's `computer_run` commands lands with the "
        + "Terminal phase. Nothing is recorded here yet.")
    filesPlaceholder.configure(
      appearance: appearance,
      glyph: "folder",
      title: "Files",
      body: "A read-only browser for the agent's /home/agent volume lands with the Files "
        + "phase. Nothing is listed here yet.")
    terminalPlaceholder.translatesAutoresizingMaskIntoConstraints = false
    filesPlaceholder.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(terminalPlaceholder)
    view.addSubview(filesPlaceholder)
  }

  private func layout() {
    let guide = view.safeAreaLayoutGuide
    let contentBottom = screenContainer.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
    contentBottomConstraint = contentBottom

    NSLayoutConstraint.activate([
      headerBar.topAnchor.constraint(equalTo: guide.topAnchor),
      headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      headerBar.heightAnchor.constraint(equalToConstant: 52.0),

      closeButton.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 16.0),
      closeButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 32.0),
      closeButton.heightAnchor.constraint(equalToConstant: 32.0),

      titleLabel.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),
      titleLabel.topAnchor.constraint(equalTo: headerBar.topAnchor, constant: 8.0),
      subtitleLabel.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),
      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1.0),
      subtitleLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8.0),

      tabControl.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 6.0),
      tabControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16.0),
      tabControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16.0),

      screenContainer.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 12.0),
      screenContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      screenContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      contentBottom,

      chromeBar.topAnchor.constraint(equalTo: screenContainer.topAnchor),
      chromeBar.leadingAnchor.constraint(equalTo: screenContainer.leadingAnchor, constant: 12.0),
      chromeBar.trailingAnchor.constraint(equalTo: screenContainer.trailingAnchor, constant: -12.0),
      chromeBar.heightAnchor.constraint(equalToConstant: 68.0),

      chromeBackButton.leadingAnchor.constraint(equalTo: chromeBar.leadingAnchor, constant: 8.0),
      chromeBackButton.topAnchor.constraint(equalTo: chromeBar.topAnchor, constant: 6.0),
      chromeBackButton.widthAnchor.constraint(equalToConstant: 30.0),
      chromeBackButton.heightAnchor.constraint(equalToConstant: 30.0),

      urlPill.leadingAnchor.constraint(equalTo: chromeBackButton.trailingAnchor, constant: 6.0),
      urlPill.centerYAnchor.constraint(equalTo: chromeBackButton.centerYAnchor),
      urlPill.heightAnchor.constraint(equalToConstant: 30.0),
      urlPill.trailingAnchor.constraint(equalTo: liveBadge.leadingAnchor, constant: -8.0),

      urlGlyph.leadingAnchor.constraint(equalTo: urlPill.leadingAnchor, constant: 10.0),
      urlGlyph.centerYAnchor.constraint(equalTo: urlPill.centerYAnchor),
      urlGlyph.widthAnchor.constraint(equalToConstant: 13.0),
      urlGlyph.heightAnchor.constraint(equalToConstant: 13.0),
      urlLabel.leadingAnchor.constraint(equalTo: urlGlyph.trailingAnchor, constant: 6.0),
      urlLabel.trailingAnchor.constraint(equalTo: urlPill.trailingAnchor, constant: -10.0),
      urlLabel.centerYAnchor.constraint(equalTo: urlPill.centerYAnchor),

      liveBadge.trailingAnchor.constraint(equalTo: chromeBar.trailingAnchor, constant: -8.0),
      liveBadge.centerYAnchor.constraint(equalTo: urlPill.centerYAnchor),
      liveBadge.heightAnchor.constraint(equalToConstant: 22.0),
      liveBadge.widthAnchor.constraint(equalToConstant: 56.0),
      liveDot.leadingAnchor.constraint(equalTo: liveBadge.leadingAnchor, constant: 8.0),
      liveDot.centerYAnchor.constraint(equalTo: liveBadge.centerYAnchor),
      liveDot.widthAnchor.constraint(equalToConstant: 7.0),
      liveDot.heightAnchor.constraint(equalToConstant: 7.0),
      liveLabel.leadingAnchor.constraint(equalTo: liveDot.trailingAnchor, constant: 5.0),
      liveLabel.centerYAnchor.constraint(equalTo: liveBadge.centerYAnchor),

      pageTitleLabel.leadingAnchor.constraint(equalTo: urlPill.leadingAnchor, constant: 2.0),
      pageTitleLabel.trailingAnchor.constraint(equalTo: liveBadge.trailingAnchor),
      pageTitleLabel.topAnchor.constraint(equalTo: urlPill.bottomAnchor, constant: 4.0),

      loadTrack.leadingAnchor.constraint(equalTo: chromeBar.leadingAnchor),
      loadTrack.trailingAnchor.constraint(equalTo: chromeBar.trailingAnchor),
      loadTrack.bottomAnchor.constraint(equalTo: chromeBar.bottomAnchor),
      loadTrack.heightAnchor.constraint(equalToConstant: 2.0),

      viewportView.topAnchor.constraint(equalTo: chromeBar.bottomAnchor, constant: 10.0),
      viewportView.leadingAnchor.constraint(equalTo: screenContainer.leadingAnchor, constant: 12.0),
      viewportView.trailingAnchor.constraint(
        equalTo: screenContainer.trailingAnchor, constant: -12.0),
      viewportView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10.0),

      statusLabel.leadingAnchor.constraint(equalTo: screenContainer.leadingAnchor, constant: 20.0),
      statusLabel.trailingAnchor.constraint(
        equalTo: screenContainer.trailingAnchor, constant: -20.0),
      statusLabel.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -10.0),

      bottomBar.leadingAnchor.constraint(equalTo: screenContainer.leadingAnchor, constant: 12.0),
      bottomBar.trailingAnchor.constraint(equalTo: screenContainer.trailingAnchor, constant: -12.0),
      bottomBar.bottomAnchor.constraint(equalTo: screenContainer.bottomAnchor, constant: -10.0),
      bottomBar.heightAnchor.constraint(equalToConstant: 48.0),

      controlButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
      controlButton.topAnchor.constraint(equalTo: bottomBar.topAnchor),
      controlButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
      stopButton.leadingAnchor.constraint(equalTo: controlButton.trailingAnchor, constant: 10.0),
      stopButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
      stopButton.topAnchor.constraint(equalTo: bottomBar.topAnchor),
      stopButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
      stopButton.widthAnchor.constraint(equalTo: controlButton.widthAnchor, multiplier: 0.55),
    ])

    for placeholder in [terminalPlaceholder, filesPlaceholder] {
      NSLayoutConstraint.activate([
        placeholder.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 12.0),
        placeholder.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16.0),
        placeholder.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16.0),
        placeholder.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16.0),
      ])
    }
  }

  private func styleFilled(_ button: UIButton, title: String) {
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 15.0, weight: .semibold)
    button.setTitleColor(appearance.isDark ? .black : .white, for: .normal)
    button.backgroundColor = appearance.primary
    button.layer.cornerRadius = 14.0
    button.translatesAutoresizingMaskIntoConstraints = false
  }

  private func styleOutlined(_ button: UIButton, title: String) {
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 15.0, weight: .semibold)
    button.setTitleColor(appearance.textSecondary, for: .normal)
    button.backgroundColor = .clear
    button.layer.cornerRadius = 14.0
    button.layer.borderWidth = 1.0
    button.layer.borderColor = appearance.border.cgColor
    button.translatesAutoresizingMaskIntoConstraints = false
  }

  // MARK: - Session

  private func wireSession() {
    session.onFrame = { [weak self] frame in self?.render(frame) }
    session.onState = { [weak self] state in self?.render(state) }
    session.onLinkChanged = { [weak self] up in
      guard let self else { return }
      self.linkUp = up
      self.applyControlState()
    }
    session.onEnded = { [weak self] reason in
      guard let self else { return }
      self.endedReason = reason
      self.linkUp = false
      self.viewportView.isInteractive = false
      self.viewportView.resignFirstResponder()
      self.applyControlState()
    }
  }

  private func render(_ frame: VibeAgentComputerSession.Frame) {
    hasFrame = true
    viewportView.render(image: frame.image, viewport: frame.viewport)
    applyChrome(url: frame.url, title: frame.title, loading: frame.loading)
    applyControlState()
  }

  private func render(_ state: VibeAgentComputerSession.State) {
    applyChrome(url: state.url, title: state.title, loading: state.loading)
    applyControlState()
  }

  private func applyChrome(url: String, title: String, loading: Bool) {
    if !url.isEmpty {
      let host = URL(string: url)?.host ?? url
      urlLabel.text = host
      urlPill.accessibilityLabel = url
    }
    pageTitleLabel.text = title.isEmpty ? " " : title
    setLoading(loading)
  }

  private func setLoading(_ next: Bool) {
    guard loading != next else { return }
    loading = next
    loadFill.layer.removeAllAnimations()
    loadFill.isHidden = !next
    guard next else { return }
    let width = max(60.0, loadTrack.bounds.width * 0.32)
    loadFill.frame = CGRect(x: -width, y: 0.0, width: width, height: 2.0)
    UIView.animate(
      withDuration: 0.9, delay: 0.0, options: [.repeat, .curveEaseInOut],
      animations: { [weak self] in
        guard let self else { return }
        self.loadFill.frame.origin.x = self.loadTrack.bounds.width
      })
  }

  /// One place decides what the bar says and whether the pixels accept touches.
  private func applyControlState() {
    let userDriving = session.control == "user"
    let live = linkUp && endedReason == nil
    viewportView.isInteractive = userDriving && live
    if !viewportView.isInteractive { viewportView.resignFirstResponder() }

    controlButton.setTitle(userDriving ? "Give back" : "Take control", for: .normal)
    controlButton.isEnabled = live
    controlButton.alpha = live ? 1.0 : 0.5
    liveBadge.alpha = live ? 1.0 : 0.35
    liveDot.backgroundColor =
      live
      ? UIColor(red: 0.16, green: 0.78, blue: 0.45, alpha: 1.0)
      : vibeAgentKitColorWithAlpha(appearance.textTertiary, 0.8)

    if let endedReason {
      statusLabel.text = "Session ended — \(endedReason). Close and reopen to watch again."
    } else if !live {
      statusLabel.text = "Connecting to the agent's computer…"
    } else if !hasFrame {
      statusLabel.text = "Waiting for the first frame…"
    } else if userDriving {
      statusLabel.text = "You're driving. Tap the screen to click, type to send keys."
    } else {
      statusLabel.text = "The agent is driving — the screen is read-only."
    }
  }

  // MARK: - Actions

  @objc private func closeTapped() {
    session.stop()
    dismiss(animated: true)
  }

  @objc private func tabChanged() {
    applyTab(Tab(rawValue: tabControl.selectedSegmentIndex) ?? .screen)
  }

  private func applyTab(_ tab: Tab) {
    screenContainer.isHidden = tab != .screen
    terminalPlaceholder.isHidden = tab != .terminal
    filesPlaceholder.isHidden = tab != .files
    if tab != .screen { viewportView.resignFirstResponder() }
  }

  @objc private func controlTapped() {
    if session.control == "user" {
      session.releaseControl()
    } else {
      session.takeControl(ttlSeconds: 300)
    }
  }

  @objc private func stopTapped() {
    session.stop()
    dismiss(animated: true)
  }

  @objc private func backTapped() {
    guard session.control == "user" else { return }
    session.sendBack()
  }

  @objc private func urlTapped() {
    guard session.control == "user" else { return }
    let alert = UIAlertController(title: "Go to", message: nil, preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = "https://"
      field.keyboardType = .URL
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Open", style: .default) { [weak self, weak alert] _ in
        let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return }
        self?.session.sendNavigate(text.contains("://") ? text : "https://\(text)")
      })
    present(alert, animated: true)
  }

  // MARK: - Keyboard

  private func observeKeyboard() {
    let center = NotificationCenter.default
    let handler: (Notification) -> Void = { [weak self] note in
      guard let self,
        let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
      else { return }
      let overlap = max(0.0, self.view.bounds.maxY - self.view.convert(frame, from: nil).minY)
      let inset = max(0.0, overlap - self.view.safeAreaInsets.bottom)
      self.contentBottomConstraint?.constant = -inset
      UIView.animate(withDuration: 0.22) { self.view.layoutIfNeeded() }
    }
    keyboardObservers = [
      center.addObserver(
        forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main,
        using: handler),
      center.addObserver(
        forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main,
        using: { [weak self] _ in
          guard let self else { return }
          self.contentBottomConstraint?.constant = 0.0
          UIView.animate(withDuration: 0.22) { self.view.layoutIfNeeded() }
        }),
    ]
  }
}

/// The pixels plus the touch → remote-viewport mapping. Aspect-fit inside the view, so a
/// tap converts through the drawn rect and lands in the FRAME's own coordinate space.
@available(iOS 13.0, *)
final class VibeAgentComputerViewportView: UIView, UIKeyInput {

  var onPoint: ((CGPoint) -> Void)?
  var onText: ((String) -> Void)?
  var onKey: ((String) -> Void)?
  var onScroll: ((CGFloat) -> Void)?

  var isInteractive = false {
    didSet {
      imageView.alpha = isInteractive ? 1.0 : 0.92
      lockBadge.isHidden = isInteractive
    }
  }

  private let imageView = UIImageView()
  private let lockBadge = UIImageView()
  private var viewport: CGSize = .zero
  private var scrollAccumulator: CGFloat = 0.0

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    layer.cornerRadius = 16.0
    clipsToBounds = true

    imageView.contentMode = .scaleAspectFit
    imageView.backgroundColor = .black
    imageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)

    lockBadge.image = UIImage(systemName: "lock.fill")
    lockBadge.contentMode = .scaleAspectFit
    lockBadge.alpha = 0.55
    lockBadge.translatesAutoresizingMaskIntoConstraints = false
    addSubview(lockBadge)

    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
      lockBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10.0),
      lockBadge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10.0),
      lockBadge.widthAnchor.constraint(equalToConstant: 14.0),
      lockBadge.heightAnchor.constraint(equalToConstant: 14.0),
    ])

    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
    addGestureRecognizer(pan)
  }

  required init?(coder: NSCoder) { return nil }

  func apply(appearance: VibeAgentKitChatAppearance) {
    lockBadge.tintColor = appearance.textTertiary
  }

  func render(image: UIImage, viewport size: CGSize) {
    imageView.image = image
    viewport = size
  }

  // MARK: - Input

  override var canBecomeFirstResponder: Bool { isInteractive }

  var hasText: Bool { true }
  var keyboardAppearance: UIKeyboardAppearance = .dark
  var autocorrectionType: UITextAutocorrectionType = .no
  var autocapitalizationType: UITextAutocapitalizationType = .none
  var spellCheckingType: UITextSpellCheckingType = .no

  func insertText(_ text: String) {
    guard isInteractive else { return }
    if text == "\n" {
      onKey?("Enter")
      return
    }
    onText?(text)
  }

  func deleteBackward() {
    guard isInteractive else { return }
    onKey?("Backspace")
  }

  @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
    guard isInteractive else { return }
    if !isFirstResponder { becomeFirstResponder() }
    guard let point = remotePoint(from: recognizer.location(in: imageView)) else { return }
    onPoint?(point)
  }

  @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
    guard isInteractive else { return }
    switch recognizer.state {
    case .began:
      scrollAccumulator = 0.0
    case .changed:
      let translation = recognizer.translation(in: self).y
      recognizer.setTranslation(.zero, in: self)
      scrollAccumulator -= translation
      guard abs(scrollAccumulator) >= 12.0 else { return }
      onScroll?(scrollAccumulator)
      scrollAccumulator = 0.0
    default:
      scrollAccumulator = 0.0
    }
  }

  /// view point → drawn-image point → remote viewport point, using the FRAME's size.
  private func remotePoint(from point: CGPoint) -> CGPoint? {
    guard viewport.width > 0.0, viewport.height > 0.0 else { return nil }
    let bounds = imageView.bounds
    guard bounds.width > 0.0, bounds.height > 0.0 else { return nil }
    let scale = min(bounds.width / viewport.width, bounds.height / viewport.height)
    let drawn = CGSize(width: viewport.width * scale, height: viewport.height * scale)
    let origin = CGPoint(
      x: (bounds.width - drawn.width) / 2.0, y: (bounds.height - drawn.height) / 2.0)
    let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    guard local.x >= 0.0, local.y >= 0.0, local.x <= drawn.width, local.y <= drawn.height
    else { return nil }
    return CGPoint(x: local.x / scale, y: local.y / scale)
  }
}

/// The Terminal / Files tabs before their phase ships: visible and named, never fake data.
@available(iOS 13.0, *)
final class VibeAgentComputerPlaceholderView: UIView {

  private let glyphView = UIImageView()
  private let titleLabel = UILabel()
  private let bodyLabel = UILabel()
  private let stack = UIStackView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    glyphView.contentMode = .scaleAspectFit
    glyphView.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 16.0, weight: .semibold)
    titleLabel.textAlignment = .center
    bodyLabel.font = .systemFont(ofSize: 13.0, weight: .regular)
    bodyLabel.textAlignment = .center
    bodyLabel.numberOfLines = 0

    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 10.0
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(glyphView)
    stack.addArrangedSubview(titleLabel)
    stack.addArrangedSubview(bodyLabel)
    addSubview(stack)

    NSLayoutConstraint.activate([
      glyphView.widthAnchor.constraint(equalToConstant: 30.0),
      glyphView.heightAnchor.constraint(equalToConstant: 30.0),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24.0),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24.0),
    ])
  }

  required init?(coder: NSCoder) { return nil }

  func configure(
    appearance: VibeAgentKitChatAppearance, glyph: String, title: String, body: String
  ) {
    layer.cornerRadius = 18.0
    layer.borderWidth = 1.0
    layer.borderColor = vibeAgentKitColorWithAlpha(appearance.border, 0.6).cgColor
    backgroundColor = vibeAgentKitColorWithAlpha(appearance.surface, 0.6)
    glyphView.image = UIImage(systemName: glyph)
    glyphView.tintColor = vibeAgentKitColorWithAlpha(appearance.textTertiary, 0.9)
    titleLabel.text = title
    titleLabel.textColor = appearance.text
    bodyLabel.text = body
    bodyLabel.textColor = appearance.textSecondary
  }
}
