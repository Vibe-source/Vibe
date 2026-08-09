import SwiftUI

enum AppVectorGlyph {
  case story
  case compose
}

struct AppVectorIcon: View {
  let glyph: AppVectorGlyph
  let tint: Color
  var lineWidth: CGFloat = 1.5

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        switch glyph {
        case .story:
          storyPath(in: geometry.size)
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        case .compose:
          composePaths(in: geometry.size)
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
      }
    }
    .aspectRatio(1, contentMode: .fit)
  }

  private func storyPath(in size: CGSize) -> Path {
    let scale = min(size.width, size.height) / 24.0
    let rect = CGRect(
      x: (size.width - 24.0 * scale) * 0.5,
      y: (size.height - 24.0 * scale) * 0.5,
      width: 24.0 * scale,
      height: 24.0 * scale
    )

    var path = Path()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    path.addArc(
      center: center,
      radius: 9.0 * scale,
      startAngle: .degrees(-39),
      endAngle: .degrees(-70),
      clockwise: false
    )
    path.move(to: CGPoint(x: rect.minX + 12.0 * scale, y: rect.minY + 8.0 * scale))
    path.addLine(to: CGPoint(x: rect.minX + 12.0 * scale, y: rect.minY + 16.0 * scale))
    path.move(to: CGPoint(x: rect.minX + 8.0 * scale, y: rect.minY + 12.0 * scale))
    path.addLine(to: CGPoint(x: rect.minX + 16.0 * scale, y: rect.minY + 12.0 * scale))
    return path
  }

  private func composePaths(in size: CGSize) -> Path {
    let scale = min(size.width, size.height) / 21.0
    let rect = CGRect(
      x: (size.width - 21.0 * scale) * 0.5,
      y: (size.height - 21.0 * scale) * 0.5,
      width: 21.0 * scale,
      height: 21.0 * scale
    )

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }

    var path = Path()
    path.move(to: point(14.0, 1.0))
    path.addQuadCurve(to: point(14.0, 4.0), control: point(15.25, 2.25))
    path.addLine(to: point(4.5, 13.5))
    path.addLine(to: point(1.5, 14.5))
    path.addLine(to: point(2.5, 10.6))
    path.addLine(to: point(12.0, 1.1))
    path.addQuadCurve(to: point(14.0, 1.0), control: point(13.0, 0.25))

    path.move(to: point(6.5, 14.5))
    path.addLine(to: point(14.5, 14.5))

    path.move(to: point(12.5, 3.5))
    path.addLine(to: point(13.5, 4.5))
    return path
  }
}

/// The proxy shield, traced from the shipped 24×24 artwork. Active fills the crest and
/// knocks the check out of it; off strokes the same outlines.
struct AppProxyShieldIcon: View {
  let isActive: Bool
  let tint: Color

  var body: some View {
    GeometryReader { geometry in
      let scale = min(geometry.size.width, geometry.size.height) / 24
      let origin = CGPoint(
        x: (geometry.size.width - 24 * scale) / 2,
        y: (geometry.size.height - 24 * scale) / 2
      )

      if isActive {
        ZStack {
          shieldPath(scale: scale, origin: origin).fill(tint)
          checkPath(scale: scale, origin: origin)
            .stroke(
              style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round, lineJoin: .round)
            )
            .blendMode(.destinationOut)
        }
        .compositingGroup()
      } else {
        ZStack {
          shieldPath(scale: scale, origin: origin)
            .stroke(
              tint,
              style: StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round)
            )
          checkPath(scale: scale, origin: origin)
            .stroke(
              tint,
              style: StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round)
            )
        }
      }
    }
    .aspectRatio(1, contentMode: .fit)
  }

  private func shieldPath(scale: CGFloat, origin: CGPoint) -> Path {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }
    var path = Path()
    path.move(to: point(11.887, 21.98))
    path.addCurve(
      to: point(12.113, 21.98), control1: point(11.963, 22.006), control2: point(12.037, 22.007))
    path.addCurve(to: point(20, 11.253), control1: point(13.084, 21.65), control2: point(20, 19.018))
    path.addLine(to: point(20, 4.304))
    path.addCurve(
      to: point(19.697, 3.915), control1: point(20, 4.12), control2: point(19.875, 3.96))
    path.addLine(to: point(12.097, 2.012))
    path.addCurve(
      to: point(11.903, 2.012), control1: point(12.033, 1.996), control2: point(11.967, 1.996))
    path.addLine(to: point(4.303, 3.915))
    path.addCurve(to: point(4, 4.304), control1: point(4.125, 3.96), control2: point(4, 4.12))
    path.addLine(to: point(4, 11.252))
    path.addCurve(
      to: point(11.887, 21.98), control1: point(4, 18.939), control2: point(10.918, 21.639))
    path.closeSubpath()
    return path
  }

  private func checkPath(scale: CGFloat, origin: CGPoint) -> Path {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }
    var path = Path()
    path.move(to: point(8, 12))
    path.addLine(to: point(11, 15))
    path.addLine(to: point(16, 8))
    return path
  }
}
