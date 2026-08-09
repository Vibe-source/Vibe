import UIKit

private struct ChatReactionFxStyle {
  let accent: UIColor
  let ring: UIColor
  let particleColors: [UIColor]
  let particleCount: Int
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
    let duration: TimeInterval = 0.55

    let container = UIView(frame: hostView.bounds)
    container.backgroundColor = .clear
    container.isUserInteractionEnabled = false
    container.clipsToBounds = false
    hostView.addSubview(container)

    let label = UILabel()
    label.text = emoji
    label.font = UIFont.systemFont(ofSize: 30)
    label.sizeToFit()
    label.center = sourcePoint
    label.layer.shadowColor = UIColor.black.withAlphaComponent(0.26).cgColor
    label.layer.shadowRadius = 8.0
    label.layer.shadowOffset = CGSize(width: 0.0, height: 3.0)
    label.layer.shadowOpacity = 1.0
    container.addSubview(label)

    let dx = targetPoint.x - sourcePoint.x
    let dy = targetPoint.y - sourcePoint.y
    let arcLift = max(34.0, min(100.0, abs(dx) * 0.35 + abs(dy) * 0.25))
    let control = CGPoint(
      x: sourcePoint.x + (dx * 0.5),
      y: min(sourcePoint.y, targetPoint.y) - arcLift
    )

    let travelPath = UIBezierPath()
    travelPath.move(to: sourcePoint)
    travelPath.addQuadCurve(to: targetPoint, controlPoint: control)

    let position = CAKeyframeAnimation(keyPath: "position")
    position.path = travelPath.cgPath
    position.duration = duration
    position.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    scale.values = [1.0, 1.18, 0.98, 0.88]
    scale.keyTimes = [0.0, 0.22, 0.76, 1.0]
    scale.duration = duration

    let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
    rotation.values = [0.0, style.flightRotation, 0.0]
    rotation.keyTimes = [0.0, 0.48, 1.0]
    rotation.duration = duration
    rotation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

    let group = CAAnimationGroup()
    group.animations = [position, scale, rotation]
    group.duration = duration
    group.fillMode = .forwards
    group.isRemovedOnCompletion = false
    label.layer.add(group, forKey: "reactionFlight")
    label.layer.position = targetPoint

    UIView.animateKeyframes(
      withDuration: duration,
      delay: 0.0,
      options: [.calculationModeCubic, .beginFromCurrentState]
    ) {
      UIView.addKeyframe(withRelativeStartTime: 0.0, relativeDuration: 0.76) {
        label.alpha = 1.0
      }
      UIView.addKeyframe(withRelativeStartTime: 0.72, relativeDuration: 0.28) {
        label.alpha = 0.0
      }
    }

    if let bubbleView {
      let base = bubbleView.transform
      DispatchQueue.main.asyncAfter(deadline: .now() + (duration * 0.64)) { [weak bubbleView] in
        guard let bubbleView else { return }
        UIView.animate(
          withDuration: 0.10,
          delay: 0.0,
          options: [.curveEaseOut, .beginFromCurrentState]
        ) {
          bubbleView.transform = base.scaledBy(x: style.bubblePulseScale, y: style.bubblePulseScale)
        } completion: { _ in
          UIView.animate(
            withDuration: 0.14,
            delay: 0.0,
            options: [.curveEaseOut, .beginFromCurrentState]
          ) {
            bubbleView.transform = base
          }
        }
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
      label.layer.removeAllAnimations()
      label.removeFromSuperview()
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

    let effectLayer = CALayer()
    effectLayer.frame = hostView.bounds
    effectLayer.masksToBounds = false
    hostView.layer.addSublayer(effectLayer)

    let centerDot = CALayer()
    centerDot.bounds = CGRect(x: 0.0, y: 0.0, width: 10.0, height: 10.0)
    centerDot.cornerRadius = 5.0
    centerDot.position = point
    centerDot.backgroundColor = style.accent.withAlphaComponent(0.92).cgColor
    effectLayer.addSublayer(centerDot)

    let dotScale = CABasicAnimation(keyPath: "transform.scale")
    dotScale.fromValue = 0.55
    dotScale.toValue = 2.1
    dotScale.duration = 0.32
    dotScale.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let dotOpacity = CABasicAnimation(keyPath: "opacity")
    dotOpacity.fromValue = 0.9
    dotOpacity.toValue = 0.0
    dotOpacity.duration = 0.32
    dotOpacity.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let dotGroup = CAAnimationGroup()
    dotGroup.animations = [dotScale, dotOpacity]
    dotGroup.duration = 0.32
    dotGroup.fillMode = .forwards
    dotGroup.isRemovedOnCompletion = false
    centerDot.add(dotGroup, forKey: "dotPulse")

    let ringRadius: CGFloat = 8.0
    let ringLayer = CAShapeLayer()
    ringLayer.path =
      UIBezierPath(
        ovalIn: CGRect(
          x: -ringRadius, y: -ringRadius, width: ringRadius * 2.0, height: ringRadius * 2.0)
      ).cgPath
    ringLayer.position = point
    ringLayer.fillColor = UIColor.clear.cgColor
    ringLayer.strokeColor = style.ring.cgColor
    ringLayer.lineWidth = 2.0
    effectLayer.addSublayer(ringLayer)

    let ringScale = CABasicAnimation(keyPath: "transform.scale")
    ringScale.fromValue = 0.72
    ringScale.toValue = style.ringEndScale
    ringScale.duration = 0.44
    ringScale.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let ringOpacity = CABasicAnimation(keyPath: "opacity")
    ringOpacity.fromValue = 1.0
    ringOpacity.toValue = 0.0
    ringOpacity.duration = 0.44
    ringOpacity.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let ringGroup = CAAnimationGroup()
    ringGroup.animations = [ringScale, ringOpacity]
    ringGroup.duration = 0.44
    ringGroup.fillMode = .forwards
    ringGroup.isRemovedOnCompletion = false
    ringLayer.add(ringGroup, forKey: "ringPulse")

    let count = max(4, style.particleCount)
    for idx in 0..<count {
      let color = style.particleColors[idx % style.particleColors.count]
      addParticle(
        index: idx,
        total: count,
        from: point,
        color: color,
        style: style,
        in: effectLayer
      )
    }

    let emojiPop = UILabel()
    emojiPop.text = emoji
    emojiPop.font = UIFont.systemFont(ofSize: 24)
    emojiPop.sizeToFit()
    emojiPop.center = point
    emojiPop.alpha = 0.0
    emojiPop.transform = CGAffineTransform(scaleX: 0.56, y: 0.56)
    hostView.addSubview(emojiPop)

    UIView.animateKeyframes(
      withDuration: 0.56,
      delay: 0.0,
      options: [.calculationModeCubic, .beginFromCurrentState]
    ) {
      UIView.addKeyframe(withRelativeStartTime: 0.0, relativeDuration: 0.28) {
        emojiPop.alpha = 1.0
        emojiPop.transform = CGAffineTransform(scaleX: 1.15, y: 1.15)
      }
      UIView.addKeyframe(withRelativeStartTime: 0.28, relativeDuration: 0.72) {
        emojiPop.alpha = 0.0
        emojiPop.center = CGPoint(x: point.x, y: point.y - 12.0)
        emojiPop.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.90) {
      effectLayer.removeFromSuperlayer()
      emojiPop.removeFromSuperview()
    }
  }

  private func addParticle(
    index: Int,
    total: Int,
    from point: CGPoint,
    color: UIColor,
    style: ChatReactionFxStyle,
    in effectLayer: CALayer
  ) {
    let particle = CALayer()
    let size = random(3.0...6.0)
    particle.bounds = CGRect(x: 0.0, y: 0.0, width: size, height: size)
    particle.cornerRadius = size * 0.5
    particle.position = point
    particle.backgroundColor = color.withAlphaComponent(0.96).cgColor
    effectLayer.addSublayer(particle)

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
    move.duration = 0.48
    move.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 1.0
    opacity.toValue = 0.0
    opacity.duration = 0.48
    opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    scale.values = [0.4, 1.0, 0.2]
    scale.keyTimes = [0.0, 0.35, 1.0]
    scale.duration = 0.48
    scale.timingFunctions = [
      CAMediaTimingFunction(name: .easeOut),
      CAMediaTimingFunction(name: .easeIn),
    ]

    let group = CAAnimationGroup()
    group.animations = [move, opacity, scale]
    group.duration = 0.48
    group.fillMode = .forwards
    group.isRemovedOnCompletion = false
    particle.add(group, forKey: "burst")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
      particle.removeFromSuperlayer()
    }
  }

  private func style(for emoji: String, tintOverride: UIColor?) -> ChatReactionFxStyle {
    let fallback = tintOverride ?? UIColor(red: 0.25, green: 0.67, blue: 0.99, alpha: 1.0)
    switch emoji {
    case "⭐️", "⭐":
      return ChatReactionFxStyle(
        accent: UIColor(red: 1.00, green: 0.74, blue: 0.10, alpha: 1.0),
        ring: UIColor(red: 1.00, green: 0.87, blue: 0.38, alpha: 1.0),
        particleColors: [
          UIColor(red: 1.00, green: 0.65, blue: 0.08, alpha: 1.0),
          UIColor(red: 1.00, green: 0.88, blue: 0.30, alpha: 1.0),
          UIColor(red: 1.00, green: 0.97, blue: 0.67, alpha: 1.0),
        ],
        particleCount: 13,
        spread: 18.0...38.0,
        rise: 8.0...22.0,
        ringEndScale: 2.6,
        bubblePulseScale: 1.028,
        flightRotation: 0.24
      )
    case "❤️":
      return ChatReactionFxStyle(
        accent: UIColor(red: 1.00, green: 0.30, blue: 0.47, alpha: 1.0),
        ring: UIColor(red: 1.00, green: 0.56, blue: 0.69, alpha: 1.0),
        particleColors: [
          UIColor(red: 1.00, green: 0.25, blue: 0.43, alpha: 1.0),
          UIColor(red: 1.00, green: 0.56, blue: 0.69, alpha: 1.0),
          UIColor(red: 1.00, green: 0.74, blue: 0.82, alpha: 1.0),
        ],
        particleCount: 10,
        spread: 14.0...32.0,
        rise: 6.0...18.0,
        ringEndScale: 2.4,
        bubblePulseScale: 1.022,
        flightRotation: -0.10
      )
    case "👍":
      return ChatReactionFxStyle(
        accent: UIColor(red: 0.22, green: 0.63, blue: 0.99, alpha: 1.0),
        ring: UIColor(red: 0.53, green: 0.77, blue: 1.00, alpha: 1.0),
        particleColors: [
          UIColor(red: 0.27, green: 0.66, blue: 1.00, alpha: 1.0),
          UIColor(red: 0.62, green: 0.85, blue: 1.00, alpha: 1.0),
        ],
        particleCount: 8,
        spread: 14.0...30.0,
        rise: 2.0...10.0,
        ringEndScale: 2.0,
        bubblePulseScale: 1.019,
        flightRotation: 0.08
      )
    case "🔥":
      return ChatReactionFxStyle(
        accent: UIColor(red: 1.00, green: 0.49, blue: 0.16, alpha: 1.0),
        ring: UIColor(red: 1.00, green: 0.68, blue: 0.29, alpha: 1.0),
        particleColors: [
          UIColor(red: 1.00, green: 0.42, blue: 0.12, alpha: 1.0),
          UIColor(red: 1.00, green: 0.70, blue: 0.24, alpha: 1.0),
          UIColor(red: 1.00, green: 0.86, blue: 0.42, alpha: 1.0),
        ],
        particleCount: 11,
        spread: 12.0...28.0,
        rise: 12.0...30.0,
        ringEndScale: 2.2,
        bubblePulseScale: 1.025,
        flightRotation: -0.14
      )
    case "🎉":
      return ChatReactionFxStyle(
        accent: UIColor(red: 0.95, green: 0.29, blue: 0.53, alpha: 1.0),
        ring: UIColor(red: 0.98, green: 0.69, blue: 0.25, alpha: 1.0),
        particleColors: [
          UIColor(red: 1.00, green: 0.27, blue: 0.51, alpha: 1.0),
          UIColor(red: 1.00, green: 0.81, blue: 0.20, alpha: 1.0),
          UIColor(red: 0.31, green: 0.83, blue: 0.95, alpha: 1.0),
          UIColor(red: 0.56, green: 0.78, blue: 0.30, alpha: 1.0),
        ],
        particleCount: 14,
        spread: 18.0...36.0,
        rise: 4.0...14.0,
        ringEndScale: 2.5,
        bubblePulseScale: 1.026,
        flightRotation: 0.11
      )
    case "👎":
      return ChatReactionFxStyle(
        accent: UIColor(red: 0.58, green: 0.64, blue: 0.78, alpha: 1.0),
        ring: UIColor(red: 0.72, green: 0.77, blue: 0.88, alpha: 1.0),
        particleColors: [
          UIColor(red: 0.54, green: 0.59, blue: 0.71, alpha: 1.0),
          UIColor(red: 0.72, green: 0.77, blue: 0.88, alpha: 1.0),
        ],
        particleCount: 7,
        spread: 12.0...25.0,
        rise: 1.0...8.0,
        ringEndScale: 1.9,
        bubblePulseScale: 1.017,
        flightRotation: -0.07
      )
    case "💩":
      return ChatReactionFxStyle(
        accent: UIColor(red: 0.62, green: 0.45, blue: 0.30, alpha: 1.0),
        ring: UIColor(red: 0.74, green: 0.59, blue: 0.42, alpha: 1.0),
        particleColors: [
          UIColor(red: 0.56, green: 0.40, blue: 0.27, alpha: 1.0),
          UIColor(red: 0.72, green: 0.55, blue: 0.37, alpha: 1.0),
        ],
        particleCount: 6,
        spread: 10.0...22.0,
        rise: 2.0...9.0,
        ringEndScale: 1.8,
        bubblePulseScale: 1.015,
        flightRotation: 0.06
      )
    case "🥰":
      return ChatReactionFxStyle(
        accent: UIColor(red: 1.00, green: 0.43, blue: 0.60, alpha: 1.0),
        ring: UIColor(red: 1.00, green: 0.67, blue: 0.76, alpha: 1.0),
        particleColors: [
          UIColor(red: 1.00, green: 0.35, blue: 0.54, alpha: 1.0),
          UIColor(red: 1.00, green: 0.70, blue: 0.78, alpha: 1.0),
        ],
        particleCount: 12,
        spread: 16.0...34.0,
        rise: 8.0...22.0,
        ringEndScale: 2.4,
        bubblePulseScale: 1.024,
        flightRotation: -0.12
      )
    case "👏":
      return ChatReactionFxStyle(
        accent: UIColor(red: 1.00, green: 0.68, blue: 0.23, alpha: 1.0),
        ring: UIColor(red: 1.00, green: 0.82, blue: 0.47, alpha: 1.0),
        particleColors: [
          UIColor(red: 1.00, green: 0.59, blue: 0.16, alpha: 1.0),
          UIColor(red: 1.00, green: 0.86, blue: 0.45, alpha: 1.0),
        ],
        particleCount: 10,
        spread: 20.0...40.0,
        rise: 2.0...12.0,
        ringEndScale: 2.2,
        bubblePulseScale: 1.03,
        flightRotation: 0.16
      )
    case "😁":
      return ChatReactionFxStyle(
        accent: UIColor(red: 0.98, green: 0.76, blue: 0.12, alpha: 1.0),
        ring: UIColor(red: 1.00, green: 0.88, blue: 0.40, alpha: 1.0),
        particleColors: [
          UIColor(red: 0.99, green: 0.70, blue: 0.08, alpha: 1.0),
          UIColor(red: 1.00, green: 0.92, blue: 0.48, alpha: 1.0),
        ],
        particleCount: 9,
        spread: 14.0...31.0,
        rise: 4.0...15.0,
        ringEndScale: 2.1,
        bubblePulseScale: 1.022,
        flightRotation: 0.09
      )
    default:
      return ChatReactionFxStyle(
        accent: fallback,
        ring: fallback.withAlphaComponent(0.74),
        particleColors: [fallback, fallback.withAlphaComponent(0.76)],
        particleCount: 8,
        spread: 13.0...29.0,
        rise: 3.0...12.0,
        ringEndScale: 2.0,
        bubblePulseScale: 1.018,
        flightRotation: 0.05
      )
    }
  }

  private func random(_ range: ClosedRange<CGFloat>) -> CGFloat {
    range.lowerBound + CGFloat.random(in: 0.0...1.0) * (range.upperBound - range.lowerBound)
  }
}
