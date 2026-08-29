import UIKit

/// Full-screen "computer" preview sheet for an isolated-runtime run (agent-platform-v1 §3.4).
/// Shows the latest `agent-preview` screenshot and live-updates while the sheet is on screen.
final class VibeAgentComputerPreviewViewController: UIViewController {
  private let chatId: String
  private let appearance: VibeAgentKitChatAppearance
  private var changeObserver: NSObjectProtocol?

  private let imageView: UIImageView = {
    let iv = UIImageView()
    iv.contentMode = .scaleAspectFit
    iv.backgroundColor = .black
    iv.translatesAutoresizingMaskIntoConstraints = false
    return iv
  }()

  private let liveDot: UIView = {
    let v = UIView()
    v.backgroundColor = UIColor(red: 0.16, green: 0.78, blue: 0.45, alpha: 1)
    v.layer.cornerRadius = 4
    v.isHidden = true
    v.translatesAutoresizingMaskIntoConstraints = false
    return v
  }()

  private let labelView: UILabel = {
    let l = UILabel()
    l.font = .systemFont(ofSize: 15, weight: .semibold)
    l.textColor = .white
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
  }()

  private let closeButton: UIButton = {
    let btn = UIButton(type: .system)
    btn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
    btn.tintColor = UIColor.white.withAlphaComponent(0.85)
    btn.translatesAutoresizingMaskIntoConstraints = false
    return btn
  }()

  init(chatId: String, appearance: VibeAgentKitChatAppearance) {
    self.chatId = chatId
    self.appearance = appearance
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) { return nil }

  deinit {
    if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    view.addSubview(imageView)
    view.addSubview(liveDot)
    view.addSubview(labelView)
    view.addSubview(closeButton)
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 52),
      imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

      labelView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      labelView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      labelView.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),

      liveDot.centerYAnchor.constraint(equalTo: labelView.centerYAnchor),
      liveDot.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: 8),
      liveDot.widthAnchor.constraint(equalToConstant: 8),
      liveDot.heightAnchor.constraint(equalToConstant: 8),

      closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      closeButton.widthAnchor.constraint(equalToConstant: 32),
      closeButton.heightAnchor.constraint(equalToConstant: 32),
    ])

    refresh()
    changeObserver = NotificationCenter.default.addObserver(
      forName: ChatEngine.didChangeNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self else { return }
      guard (note.userInfo?["reason"] as? String) == "agentPreview",
        (note.userInfo?["chatId"] as? String) == self.chatId
      else { return }
      self.refresh()
    }
  }

  @objc private func closeTapped() {
    dismiss(animated: true)
  }

  // Re-pulls the latest decoded frame + run-liveness from the engine (one-shot, sheet-only).
  private func refresh() {
    guard let preview = ChatEngine.shared.latestAgentPreview(chatId: chatId) else { return }
    imageView.image = preview.image
    labelView.text = preview.label
    liveDot.isHidden = ChatEngine.shared.activeIsolatedRunId(chatId: chatId) != preview.runId
  }
}
