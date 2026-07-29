import UIKit

/// The avatar shown when someone has no profile image.
///
/// Compiled into both the app and the notification service extension, because
/// they must agree: a notification that colours someone differently from the
/// chat list reads as a different person. Keeping two copies in sync by hand is
/// how this codebase lost its notification extension in the first place, so the
/// palette lives here once and `ChatAvatarFallbackStyle` reads it from here.
enum VibeAvatarFallback {
  /// Light/dark gradient pairs, indexed by a stable hash of the identity seed.
  static let palettes: [(lightStart: String, lightEnd: String, darkStart: String, darkEnd: String)] = [
    ("#5B8DEF", "#3D6BC6", "#6EA2FF", "#355EAA"),
    ("#1FA97A", "#167A60", "#3BC99A", "#126B55"),
    ("#D66A5A", "#AF493F", "#E98574", "#963B33"),
    ("#A06AD8", "#7C4EB2", "#B984EA", "#6E45A0"),
    ("#D59A2E", "#AF741D", "#E6B24A", "#966418"),
    ("#2F9AA8", "#207585", "#4BB6C4", "#1B6575"),
    ("#E05A8A", "#B83E6A", "#F178A4", "#9C345B"),
    ("#6078D6", "#4659AE", "#7A91EA", "#3A4E9C"),
  ]

  /// First non-empty of user id, then title, then chat id. The user id leads so
  /// a person keeps their colour even when their display name changes.
  static func stableSeed(title: String?, peerUserId: String?, chatId: String?) -> String {
    [peerUserId, title, chatId]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? ""
  }

  static func paletteIndex(for seed: String) -> Int {
    abs(seed.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % palettes.count
  }

  static func gradient(
    title: String?,
    peerUserId: String?,
    chatId: String? = nil,
    isDark: Bool
  ) -> (UIColor, UIColor) {
    let seed = stableSeed(title: title, peerUserId: peerUserId, chatId: chatId)
    let palette = palettes[paletteIndex(for: seed.isEmpty ? "user" : seed)]
    return (
      color(hex: isDark ? palette.darkStart : palette.lightStart),
      color(hex: isDark ? palette.darkEnd : palette.lightEnd)
    )
  }

  /// Matches the app: one word yields one letter, two or more yield two.
  static func initials(from name: String) -> String {
    let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
    if parts.isEmpty { return "" }
    if parts.count == 1 { return String(parts[0].prefix(1)).uppercased() }
    return (String(parts[0].prefix(1)) + String(parts[1].prefix(1))).uppercased()
  }

  static func color(hex raw: String) -> UIColor {
    var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    var value: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&value)
    return UIColor(
      red: CGFloat((value >> 16) & 0xff) / 255.0,
      green: CGFloat((value >> 8) & 0xff) / 255.0,
      blue: CGFloat(value & 0xff) / 255.0,
      alpha: 1.0
    )
  }

  /// Renders the gradient disc with initials, or a person glyph when the name
  /// yields nothing usable.
  ///
  /// `isDark` defaults to false: a notification is composed by an extension that
  /// has no window and cannot read the user's interface style, and the light
  /// pair reads correctly against both banner backgrounds.
  static func image(
    displayName: String?,
    userId: String?,
    diameter: CGFloat = 120,
    isDark: Bool = false
  ) -> UIImage {
    let name = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let text = initials(from: name)
    let (start, end) = gradient(title: name.isEmpty ? nil : name, peerUserId: userId, isDark: isDark)
    let size = CGSize(width: diameter, height: diameter)

    return UIGraphicsImageRenderer(size: size).image { context in
      let rect = CGRect(origin: .zero, size: size)
      context.cgContext.saveGState()
      context.cgContext.addEllipse(in: rect)
      context.cgContext.clip()

      if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [start.cgColor, end.cgColor] as CFArray,
        locations: [0, 1]
      ) {
        context.cgContext.drawLinearGradient(
          gradient,
          start: CGPoint(x: 0, y: 0),
          end: CGPoint(x: 0, y: diameter),
          options: []
        )
      } else {
        start.setFill()
        context.cgContext.fill(rect)
      }
      context.cgContext.restoreGState()

      if text.isEmpty {
        let config = UIImage.SymbolConfiguration(pointSize: diameter * 0.48, weight: .medium)
        if let glyph = UIImage(systemName: "person.fill", withConfiguration: config)?
          .withTintColor(.white, renderingMode: .alwaysOriginal)
        {
          let side = diameter * 0.48
          glyph.draw(in: CGRect(
            x: (diameter - side) / 2, y: (diameter - side) / 2, width: side, height: side))
        }
        return
      }

      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: diameter * 0.4, weight: .semibold),
        .foregroundColor: UIColor.white,
      ]
      let bounds = (text as NSString).size(withAttributes: attributes)
      (text as NSString).draw(
        at: CGPoint(x: (diameter - bounds.width) / 2, y: (diameter - bounds.height) / 2),
        withAttributes: attributes
      )
    }
  }

  static func imageData(displayName: String?, userId: String?, diameter: CGFloat = 120) -> Data? {
    let image = image(displayName: displayName, userId: userId, diameter: diameter)
    return image.pngData() ?? image.jpegData(compressionQuality: 0.92)
  }
}
