import UIKit

enum ChatReactionCatalog {
  static let collapsedEmojis: [String] = ["⭐️", "❤️", "👍", "👎", "🔥", "🥰", "👏"]

  static let allEmojis: [String] = collapsedEmojis + [
    "😁", "😂", "🤣", "😢", "😭", "😡", "🤯", "😱", "🤔", "😍", "🤩", "😎", "🙏",
    "💪", "🤝", "👌", "💯", "⚡️", "🚀", "🎂", "🍾", "🎉", "💩",
  ]
}

final class ChatReactionTransitionCoordinator {
  static let shared = ChatReactionTransitionCoordinator()

  struct Token: Hashable {
    fileprivate let chatId: String
    fileprivate let messageId: String
    fileprivate let id: UUID
  }

  private struct MessageKey: Hashable {
    let chatId: String
    let messageId: String
  }

  private struct Flight {
    let id: UUID
    let emoji: String
    var isFlying: Bool
    var transportAccepted: Bool
  }

  private let lock = NSLock()
  private var flights: [MessageKey: Flight] = [:]

  private init() {}

  func begin(chatId: String, messageId: String, emoji: String) -> Token {
    let token = Token(chatId: chatId, messageId: messageId, id: UUID())
    withLock {
      flights[MessageKey(chatId: chatId, messageId: messageId)] = Flight(
        id: token.id, emoji: emoji, isFlying: true, transportAccepted: false)
    }
    return token
  }

  func isCurrent(_ token: Token) -> Bool {
    withLock {
      flights[MessageKey(chatId: token.chatId, messageId: token.messageId)]?.id == token.id
    }
  }

  func isFlying(chatId: String, messageId: String, emoji: String) -> Bool {
    withLock {
      guard let flight = flights[MessageKey(chatId: chatId, messageId: messageId)] else {
        return false
      }
      return flight.emoji == emoji && flight.isFlying
    }
  }

  func finishFlight(_ token: Token) {
    withLock {
      let key = MessageKey(chatId: token.chatId, messageId: token.messageId)
      guard var flight = flights[key], flight.id == token.id else { return }
      flight.isFlying = false
      if flight.transportAccepted {
        flights.removeValue(forKey: key)
      } else {
        flights[key] = flight
      }
    }
  }

  func resolveTransport(_ token: Token, accepted: Bool) -> Bool {
    withLock {
      let key = MessageKey(chatId: token.chatId, messageId: token.messageId)
      guard var flight = flights[key], flight.id == token.id else { return false }
      if !accepted || !flight.isFlying {
        flights.removeValue(forKey: key)
      } else {
        flight.transportAccepted = true
        flights[key] = flight
      }
      return true
    }
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

private struct ChatReactionFxStyle {
  let accent: UIColor
  let ring: UIColor
  let replicaGlowColors: [UIColor]
  let replicaCount: Int
  let spread: ClosedRange<CGFloat>
  let rise: ClosedRange<CGFloat>
  let ringEndScale: CGFloat
  let bubblePulseScale: CGFloat
  let flightRotation: CGFloat
}

final class ChatReactionFxModule {
  static let shared = ChatReactionFxModule()

  private init() {}

  func animateReactionFlight(
    emoji: String,
    from sourcePoint: CGPoint,
    to targetPoint: CGPoint,
    in hostView: UIView,
    bubbleView: UIView?,
    completion: @escaping () -> Void
  ) {
    let style = style(for: emoji, tintOverride: nil)
    let duration: TimeInterval = 0.30

    let container = UIView(frame: hostView.bounds)
    container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.backgroundColor = .clear
    container.isUserInteractionEnabled = false
    container.clipsToBounds = false
    hostView.addSubview(container)

    let source = container.convert(sourcePoint, from: hostView)
    let target = container.convert(targetPoint, from: hostView)
    let wrapper = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
    wrapper.center = source
    wrapper.alpha = 1
    wrapper.isUserInteractionEnabled = false
    container.addSubview(wrapper)

    let label = UILabel()
    label.text = emoji
    label.font = UIFont.systemFont(ofSize: 30)
    label.textAlignment = .center
    label.frame = wrapper.bounds
    label.alpha = 1
    label.layer.contentsScale = UIScreen.main.scale
    label.layer.shadowColor = UIColor.black.withAlphaComponent(0.26).cgColor
    label.layer.shadowRadius = 5.0
    label.layer.shadowOffset = CGSize(width: 0.0, height: 2.0)
    label.layer.shadowOpacity = 1.0
    wrapper.addSubview(label)

    let dx = target.x - source.x
    let dy = target.y - source.y
    let arcLift = max(18.0, min(48.0, abs(dx) * 0.16 + abs(dy) * 0.10))
    let control = CGPoint(
      x: source.x + (dx * 0.5),
      y: min(source.y, target.y) - arcLift
    )

    let travelPath = UIBezierPath()
    travelPath.move(to: source)
    travelPath.addQuadCurve(to: target, controlPoint: control)

    let position = CAKeyframeAnimation(keyPath: "position")
    position.path = travelPath.cgPath
    position.duration = duration
    position.calculationMode = .paced
    position.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    scale.values = [1.0, 1.12, 1.0]
    scale.keyTimes = [0.0, 0.38, 1.0]
    scale.duration = duration

    let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
    rotation.values = [0.0, style.flightRotation, 0.0]
    rotation.keyTimes = [0.0, 0.48, 1.0]
    rotation.duration = duration
    rotation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

    let group = CAAnimationGroup()
    group.animations = [position, scale, rotation]
    group.duration = duration
    wrapper.layer.position = target
    wrapper.layer.add(group, forKey: "reactionFlight")

    if let bubbleView {
      let base = bubbleView.transform
      DispatchQueue.main.asyncAfter(deadline: .now() + (duration * 0.58)) { [weak bubbleView] in
        guard let bubbleView else { return }
        UIView.animate(
          withDuration: 0.08,
          delay: 0.0,
          options: [.curveEaseOut, .beginFromCurrentState]
        ) {
          bubbleView.transform = base.scaledBy(x: style.bubblePulseScale, y: style.bubblePulseScale)
        } completion: { _ in
          UIView.animate(
            withDuration: 0.10,
            delay: 0.0,
            options: [.curveEaseOut, .beginFromCurrentState]
          ) {
            bubbleView.transform = base
          }
        }
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
      wrapper.layer.removeAllAnimations()
      wrapper.removeFromSuperview()
      container.removeFromSuperview()
      completion()
    }
  }

  func playLandingEffect(
    emoji: String,
    at point: CGPoint,
    in hostView: UIView,
    tintOverride: UIColor?
  ) {
    let style = style(for: emoji, tintOverride: tintOverride)

    let effectView = UIView(frame: hostView.bounds)
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.backgroundColor = .clear
    effectView.isUserInteractionEnabled = false
    effectView.clipsToBounds = false
    hostView.addSubview(effectView)
    let arrival = effectView.convert(point, from: hostView)

    let ringRadius: CGFloat = 8.0
    let ringLayer = CAShapeLayer()
    ringLayer.path =
      UIBezierPath(
        ovalIn: CGRect(
          x: -ringRadius, y: -ringRadius, width: ringRadius * 2.0, height: ringRadius * 2.0)
      ).cgPath
    ringLayer.position = arrival
    ringLayer.fillColor = UIColor.clear.cgColor
    ringLayer.strokeColor = style.ring.withAlphaComponent(0.42).cgColor
    ringLayer.lineWidth = 1.0
    ringLayer.shadowColor = style.accent.withAlphaComponent(0.18).cgColor
    ringLayer.shadowOpacity = 1
    ringLayer.shadowRadius = 3
    ringLayer.shadowOffset = .zero
    effectView.layer.addSublayer(ringLayer)

    let ringScale = CABasicAnimation(keyPath: "transform.scale")
    ringScale.fromValue = 0.72
    ringScale.toValue = min(style.ringEndScale, 2.15)
    ringScale.duration = 0.34
    ringScale.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let ringOpacity = CABasicAnimation(keyPath: "opacity")
    ringOpacity.fromValue = 0.42
    ringOpacity.toValue = 0.0
    ringOpacity.duration = 0.34
    ringOpacity.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let ringGroup = CAAnimationGroup()
    ringGroup.animations = [ringScale, ringOpacity]
    ringGroup.duration = 0.34
    ringGroup.fillMode = .forwards
    ringGroup.isRemovedOnCompletion = false
    ringLayer.add(ringGroup, forKey: "ringPulse")

    let count = max(5, style.replicaCount)
    for idx in 0..<count {
      let glow = style.replicaGlowColors[idx % style.replicaGlowColors.count]
      addReplica(
        emoji: emoji,
        index: idx,
        total: count,
        from: arrival,
        glowColor: glow,
        style: style,
        in: effectView
      )
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) {
      effectView.removeFromSuperview()
    }
  }

  private func addReplica(
    emoji: String,
    index: Int,
    total: Int,
    from point: CGPoint,
    glowColor: UIColor,
    style: ChatReactionFxStyle,
    in effectView: UIView
  ) {
    let replica = UILabel(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
    replica.text = emoji
    replica.font = UIFont.systemFont(ofSize: random(10.0...14.0))
    replica.textAlignment = .center
    replica.center = point
    replica.alpha = 1
    replica.layer.contentsScale = UIScreen.main.scale
    replica.layer.shadowColor = glowColor.withAlphaComponent(0.32).cgColor
    replica.layer.shadowOpacity = 1
    replica.layer.shadowRadius = 3
    replica.layer.shadowOffset = .zero
    effectView.addSubview(replica)

    let baseAngle = (CGFloat(index) / CGFloat(max(1, total))) * .pi * 2.0
    let jitter = random(-0.16...0.16)
    let angle = baseAngle + jitter
    let travel = random(style.spread)
    let rise = random(style.rise)
    let endPoint = CGPoint(
      x: point.x + (cos(angle) * travel),
      y: point.y + (sin(angle) * travel) - rise
    )

    let move = CABasicAnimation(keyPath: "position")
    move.fromValue = point
    move.toValue = endPoint
    move.duration = 0.40
    move.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let opacity = CAKeyframeAnimation(keyPath: "opacity")
    opacity.values = [1.0, 1.0, 0.0]
    opacity.keyTimes = [0.0, 0.62, 1.0]
    opacity.duration = 0.40

    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    scale.values = [0.55, 1.0, 0.78]
    scale.keyTimes = [0.0, 0.30, 1.0]
    scale.duration = 0.40
    scale.timingFunctions = [
      CAMediaTimingFunction(name: .easeOut),
      CAMediaTimingFunction(name: .easeIn),
    ]

    let group = CAAnimationGroup()
    group.animations = [move, opacity, scale]
    group.duration = 0.40
    group.fillMode = .forwards
    group.isRemovedOnCompletion = false
    replica.layer.add(group, forKey: "replicaBurst")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
      replica.removeFromSuperview()
    }
  }

  private func style(for emoji: String, tintOverride: UIColor?) -> ChatReactionFxStyle {
    let fallback = tintOverride ?? UIColor(red: 0.25, green: 0.67, blue: 0.99, alpha: 1.0)
    return Self.styleRegistry[Self.normalizedEmoji(emoji)]
      ?? Self.makeStyle(
        accent: fallback,
        ring: fallback.withAlphaComponent(0.74),
        replicaGlows: [fallback, fallback.withAlphaComponent(0.76)]
      )
  }

  private static let styleRegistry: [String: ChatReactionFxStyle] = {
    let star = makeStyle(
      accent: UIColor(red: 1.00, green: 0.74, blue: 0.10, alpha: 1.0),
      ring: UIColor(red: 1.00, green: 0.87, blue: 0.38, alpha: 1.0),
      replicaGlows: [
        UIColor(red: 1.00, green: 0.65, blue: 0.08, alpha: 1.0),
        UIColor(red: 1.00, green: 0.88, blue: 0.30, alpha: 1.0),
        UIColor(red: 1.00, green: 0.97, blue: 0.67, alpha: 1.0),
      ],
      count: 13, spread: 18.0...38.0, rise: 8.0...22.0, ringScale: 2.6,
      bubbleScale: 1.028, rotation: 0.24
    )
    let heart = makeStyle(
      accent: UIColor(red: 1.00, green: 0.30, blue: 0.47, alpha: 1.0),
      ring: UIColor(red: 1.00, green: 0.56, blue: 0.69, alpha: 1.0),
      replicaGlows: [
        UIColor(red: 1.00, green: 0.25, blue: 0.43, alpha: 1.0),
        UIColor(red: 1.00, green: 0.56, blue: 0.69, alpha: 1.0),
        UIColor(red: 1.00, green: 0.74, blue: 0.82, alpha: 1.0),
      ],
      count: 10, spread: 14.0...32.0, rise: 6.0...18.0, ringScale: 2.4,
      bubbleScale: 1.022, rotation: -0.10
    )
    let positive = makeStyle(
      accent: UIColor(red: 0.22, green: 0.63, blue: 0.99, alpha: 1.0),
      ring: UIColor(red: 0.53, green: 0.77, blue: 1.00, alpha: 1.0),
      replicaGlows: [
        UIColor(red: 0.27, green: 0.66, blue: 1.00, alpha: 1.0),
        UIColor(red: 0.62, green: 0.85, blue: 1.00, alpha: 1.0),
      ],
      spread: 14.0...30.0, rise: 2.0...10.0, rotation: 0.08
    )
    let negative = makeStyle(
      accent: UIColor(red: 0.58, green: 0.64, blue: 0.78, alpha: 1.0),
      ring: UIColor(red: 0.72, green: 0.77, blue: 0.88, alpha: 1.0),
      replicaGlows: [
        UIColor(red: 0.54, green: 0.59, blue: 0.71, alpha: 1.0),
        UIColor(red: 0.72, green: 0.77, blue: 0.88, alpha: 1.0),
      ],
      count: 7, spread: 12.0...25.0, rise: 1.0...8.0, ringScale: 1.9,
      bubbleScale: 1.017, rotation: -0.07
    )
    let fire = makeStyle(
      accent: UIColor(red: 1.00, green: 0.49, blue: 0.16, alpha: 1.0),
      ring: UIColor(red: 1.00, green: 0.68, blue: 0.29, alpha: 1.0),
      replicaGlows: [
        UIColor(red: 1.00, green: 0.42, blue: 0.12, alpha: 1.0),
        UIColor(red: 1.00, green: 0.70, blue: 0.24, alpha: 1.0),
        UIColor(red: 1.00, green: 0.86, blue: 0.42, alpha: 1.0),
      ],
      count: 11, spread: 12.0...28.0, rise: 12.0...30.0, ringScale: 2.2,
      bubbleScale: 1.025, rotation: -0.14
    )
    let love = makeStyle(
      accent: UIColor(red: 1.00, green: 0.43, blue: 0.60, alpha: 1.0),
      ring: UIColor(red: 1.00, green: 0.67, blue: 0.76, alpha: 1.0),
      replicaGlows: [
        UIColor(red: 1.00, green: 0.35, blue: 0.54, alpha: 1.0),
        UIColor(red: 1.00, green: 0.70, blue: 0.78, alpha: 1.0),
      ],
      count: 12, spread: 16.0...34.0, rise: 8.0...22.0, ringScale: 2.4,
      bubbleScale: 1.024, rotation: -0.12
    )
    let applause = makeStyle(
      accent: UIColor(red: 1.00, green: 0.68, blue: 0.23, alpha: 1.0),
      ring: UIColor(red: 1.00, green: 0.82, blue: 0.47, alpha: 1.0),
      replicaGlows: [
        UIColor(red: 1.00, green: 0.59, blue: 0.16, alpha: 1.0),
        UIColor(red: 1.00, green: 0.86, blue: 0.45, alpha: 1.0),
      ],
      count: 10, spread: 20.0...40.0, rise: 2.0...12.0, ringScale: 2.2,
      bubbleScale: 1.03, rotation: 0.16
    )
    let happy = makeStyle(
      accent: UIColor(red: 0.98, green: 0.76, blue: 0.12, alpha: 1.0),
      ring: UIColor(red: 1.00, green: 0.88, blue: 0.40, alpha: 1.0),
      replicaGlows: [
        UIColor(red: 0.99, green: 0.70, blue: 0.08, alpha: 1.0),
        UIColor(red: 1.00, green: 0.92, blue: 0.48, alpha: 1.0),
      ],
      count: 9, spread: 14.0...31.0, rise: 4.0...15.0, ringScale: 2.1,
      bubbleScale: 1.022, rotation: 0.09
    )
    let celebration = makeStyle(
      accent: UIColor(red: 0.95, green: 0.29, blue: 0.53, alpha: 1.0),
      ring: UIColor(red: 0.98, green: 0.69, blue: 0.25, alpha: 1.0),
      replicaGlows: [
        UIColor(red: 1.00, green: 0.27, blue: 0.51, alpha: 1.0),
        UIColor(red: 1.00, green: 0.81, blue: 0.20, alpha: 1.0),
        UIColor(red: 0.31, green: 0.83, blue: 0.95, alpha: 1.0),
        UIColor(red: 0.56, green: 0.78, blue: 0.30, alpha: 1.0),
      ],
      count: 14, spread: 18.0...36.0, rise: 4.0...14.0, ringScale: 2.5,
      bubbleScale: 1.026, rotation: 0.11
    )
    let earthy = makeStyle(
      accent: UIColor(red: 0.62, green: 0.45, blue: 0.30, alpha: 1.0),
      ring: UIColor(red: 0.74, green: 0.59, blue: 0.42, alpha: 1.0),
      replicaGlows: [
        UIColor(red: 0.56, green: 0.40, blue: 0.27, alpha: 1.0),
        UIColor(red: 0.72, green: 0.55, blue: 0.37, alpha: 1.0),
      ],
      count: 6, spread: 10.0...22.0, rise: 2.0...9.0, ringScale: 1.8,
      bubbleScale: 1.015, rotation: 0.06
    )

    return [
      "⭐": star, "❤": heart, "👍": positive, "👎": negative, "🔥": fire,
      "🥰": love, "👏": applause, "😁": happy, "😂": happy, "🤣": happy,
      "😢": negative, "😭": negative, "😡": fire, "🤯": celebration,
      "😱": celebration, "🤔": earthy, "😍": love, "🤩": celebration,
      "😎": happy, "🙏": applause, "💪": positive, "🤝": positive, "👌": positive,
      "💯": fire, "⚡": fire, "🚀": fire, "🎂": celebration, "🍾": celebration,
      "🎉": celebration, "💩": earthy,
    ]
  }()

  private static func normalizedEmoji(_ emoji: String) -> String {
    emoji
      .replacingOccurrences(of: "\u{FE0E}", with: "")
      .replacingOccurrences(of: "\u{FE0F}", with: "")
  }

  private static func makeStyle(
    accent: UIColor,
    ring: UIColor,
    replicaGlows: [UIColor],
    count: Int = 8,
    spread: ClosedRange<CGFloat> = 13.0...29.0,
    rise: ClosedRange<CGFloat> = 3.0...12.0,
    ringScale: CGFloat = 2.0,
    bubbleScale: CGFloat = 1.018,
    rotation: CGFloat = 0.05
  ) -> ChatReactionFxStyle {
    ChatReactionFxStyle(
      accent: accent,
      ring: ring,
      replicaGlowColors: replicaGlows,
      replicaCount: count,
      spread: spread,
      rise: rise,
      ringEndScale: ringScale,
      bubblePulseScale: bubbleScale,
      flightRotation: rotation
    )
  }

  private func random(_ range: ClosedRange<CGFloat>) -> CGFloat {
    range.lowerBound + CGFloat.random(in: 0.0...1.0) * (range.upperBound - range.lowerBound)
  }
}
