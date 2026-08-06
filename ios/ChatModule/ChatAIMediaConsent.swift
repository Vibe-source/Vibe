import UIKit

/// One-time, per-provider disclosure before any media leaves the device for an
/// AI model.
///
/// This exists because AI editing is the one place in the app where a user's
/// media deliberately steps outside the encryption envelope. The sheet says that
/// plainly rather than burying it — it is shown once per provider, and after
/// that the editors carry a permanent visible badge instead.
enum ChatAIMediaConsent {

  enum Provider {
    case openAI
    case google

    var displayName: String {
      switch self {
      case .openAI: return "OpenAI"
      case .google: return "Google"
      }
    }

    fileprivate var defaultsKey: String {
      switch self {
      case .openAI: return "vibe.ai.media.consent.openai"
      case .google: return "vibe.ai.media.consent.google"
      }
    }

    /// Shown on the badge that stays visible in the editor afterwards.
    var badgeText: String {
      "Sent to \(displayName)"
    }

    fileprivate var mediaNoun: String {
      switch self {
      case .openAI: return "photo"
      case .google: return "video clip"
      }
    }

    fileprivate var points: [(String, String)] {
      switch self {
      case .openAI:
        return [
          ("lock.open", "This photo leaves your device unencrypted. This one step is not end-to-end encrypted."),
          ("person.crop.circle.badge.xmark", "OpenAI processes it on their servers to make the edit."),
          ("clock.arrow.circlepath", "The original in your chat is untouched — only the copy you send here is used."),
        ]
      case .google:
        return [
          ("lock.open", "This clip leaves your device unencrypted. This one step is not end-to-end encrypted."),
          ("person.crop.circle.badge.xmark", "Google processes it on their servers to make the edit."),
          ("water.waves", "Edited video carries an invisible SynthID watermark identifying it as AI-generated."),
        ]
      }
    }
  }

  static func hasConsented(to provider: Provider) -> Bool {
    UserDefaults.standard.bool(forKey: provider.defaultsKey)
  }

  /// Presents the disclosure if it has not been accepted yet, then calls
  /// `completion(true)` if the user agreed (or had already agreed).
  static func ensureConsent(
    for provider: Provider,
    from presenter: UIViewController,
    completion: @escaping (Bool) -> Void
  ) {
    guard !hasConsented(to: provider) else {
      completion(true)
      return
    }

    let sheet = ConsentSheetViewController(provider: provider) { accepted in
      if accepted {
        UserDefaults.standard.set(true, forKey: provider.defaultsKey)
      }
      completion(accepted)
    }
    sheet.modalPresentationStyle = .overFullScreen
    sheet.modalTransitionStyle = .crossDissolve
    presenter.present(sheet, animated: true)
  }

  /// Clears consent — used by the Settings row so the decision is reversible.
  static func revokeAll() {
    for key in [Provider.openAI.defaultsKey, Provider.google.defaultsKey] {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
}

// MARK: - Sheet

private final class ConsentSheetViewController: UIViewController {

  private let provider: ChatAIMediaConsent.Provider
  private let completion: (Bool) -> Void

  private let dimView = UIView()
  private let card = UIView()

  init(provider: ChatAIMediaConsent.Provider, completion: @escaping (Bool) -> Void) {
    self.provider = provider
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    dimView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    dimView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(dimView)

    card.backgroundColor = UIColor(white: 0.11, alpha: 1)
    card.layer.cornerRadius = 28
    card.layer.cornerCurve = .continuous
    card.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(card)

    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 18
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)

    let icon = UIImageView(
      image: UIImage(systemName: "sparkles")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)))
    icon.tintColor = .white
    icon.contentMode = .scaleAspectFit
    stack.addArrangedSubview(icon)

    let title = UILabel()
    title.text = "Edit this \(provider.mediaNoun) with AI"
    title.font = .systemFont(ofSize: 22, weight: .bold)
    title.textColor = .white
    title.numberOfLines = 0
    stack.addArrangedSubview(title)

    for (symbol, text) in provider.points {
      stack.addArrangedSubview(makePoint(symbol: symbol, text: text))
    }

    let footnote = UILabel()
    footnote.text = "You'll only be asked once for \(provider.displayName)."
    footnote.font = .systemFont(ofSize: 13)
    footnote.textColor = UIColor(white: 1, alpha: 0.45)
    footnote.numberOfLines = 0
    stack.addArrangedSubview(footnote)

    let buttons = UIStackView()
    buttons.axis = .horizontal
    buttons.spacing = 12
    buttons.distribution = .fillEqually

    let cancel = makeButton(title: "Not now", filled: false)
    cancel.addTarget(self, action: #selector(handleCancel), for: .touchUpInside)
    let accept = makeButton(title: "Continue", filled: true)
    accept.addTarget(self, action: #selector(handleAccept), for: .touchUpInside)
    buttons.addArrangedSubview(cancel)
    buttons.addArrangedSubview(accept)
    stack.addArrangedSubview(buttons)
    stack.setCustomSpacing(24, after: footnote)

    NSLayoutConstraint.activate([
      dimView.topAnchor.constraint(equalTo: view.topAnchor),
      dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
      card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

      buttons.heightAnchor.constraint(equalToConstant: 50),
    ])

    card.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
    card.alpha = 0
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
      self.card.transform = .identity
      self.card.alpha = 1
    }
  }

  private func makePoint(symbol: String, text: String) -> UIView {
    let row = UIStackView()
    row.axis = .horizontal
    row.spacing = 12
    row.alignment = .top

    let icon = UIImageView(
      image: UIImage(systemName: symbol)?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)))
    icon.tintColor = UIColor(white: 1, alpha: 0.7)
    icon.contentMode = .scaleAspectFit
    icon.setContentHuggingPriority(.required, for: .horizontal)
    icon.widthAnchor.constraint(equalToConstant: 22).isActive = true

    let label = UILabel()
    label.text = text
    label.font = .systemFont(ofSize: 15)
    label.textColor = UIColor(white: 1, alpha: 0.82)
    label.numberOfLines = 0

    row.addArrangedSubview(icon)
    row.addArrangedSubview(label)
    return row
  }

  private func makeButton(title: String, filled: Bool) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
    button.setTitleColor(filled ? .black : .white, for: .normal)
    button.backgroundColor = filled ? .white : UIColor(white: 1, alpha: 0.14)
    button.layer.cornerRadius = 16
    button.layer.cornerCurve = .continuous
    return button
  }

  @objc private func handleCancel() { finish(accepted: false) }
  @objc private func handleAccept() { finish(accepted: true) }

  private func finish(accepted: Bool) {
    dismiss(animated: true) { [completion] in completion(accepted) }
  }
}
