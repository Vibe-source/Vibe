import SwiftUI
import UIKit

// MARK: - Sample rows (real ChatListRow payloads)

enum ChatAppearancePreviewSamples {
  static func themRow(text: String, radius: CGFloat, withTail: Bool = true) -> ChatListRow {
    ChatListRow(raw: [
      "kind": "message",
      "key": "appearance-preview-them-\(text.hashValue)",
      "message": [
        "id": "appearance-preview-them-\(abs(text.hashValue))",
        "text": text,
        "timestamp": "22:20",
        "isMe": false,
        "type": "text",
        "bubbleShape": shapeDict(isMe: false, radius: radius, showTail: withTail),
      ],
    ])!
  }

  static func meRow(text: String, radius: CGFloat) -> ChatListRow {
    ChatListRow(raw: [
      "kind": "message",
      "key": "appearance-preview-me-\(text.hashValue)",
      "message": [
        "id": "appearance-preview-me-\(abs(text.hashValue))",
        "text": text,
        "timestamp": "22:20",
        "isMe": true,
        "type": "text",
        "status": "read",
        "bubbleShape": shapeDict(isMe: true, radius: radius, showTail: true),
      ],
    ])!
  }

  static func voiceRow(radius: CGFloat) -> ChatListRow {
    ChatListRow(raw: [
      "kind": "message",
      "key": "appearance-preview-voice",
      "message": [
        "id": "appearance-preview-voice",
        "text": "",
        "timestamp": "22:20",
        "isMe": false,
        "type": "voice",
        "mediaDuration": 23,
        "bubbleShape": shapeDict(isMe: false, radius: radius, showTail: false),
      ],
    ])!
  }

  private static func shapeDict(isMe: Bool, radius: CGFloat, showTail: Bool) -> [String: Any] {
    let r = Double(radius)
    // Match live chat: consecutive/merged corner ≈ 12 when primary is 18 (~0.67×).
    let tight = max(8.0, r * (12.0 / 18.0))
    if isMe {
      return [
        "showTail": showTail,
        "borderTopLeftRadius": r,
        "borderTopRightRadius": r,
        "borderBottomLeftRadius": r,
        "borderBottomRightRadius": tight,
      ]
    }
    return [
      "showTail": showTail,
      "borderTopLeftRadius": r,
      "borderTopRightRadius": r,
      "borderBottomLeftRadius": tight,
      "borderBottomRightRadius": r,
    ]
  }
}

// MARK: - UIKit host (production wallpaper + ChatListCell)

/// Renders appearance previews with the **same** wallpaper pipeline as `ChatListView`
/// and real `ChatListCell` instances (not SwiftUI mock bubbles).
final class ChatAppearanceLiveHostView: UIView {
  private let wallpaperLayer = CAGradientLayer()
  private let patternLayer = CAGradientLayer()
  private let patternMaskLayer = CALayer()
  private let stack = UIStackView()
  private var cells: [ChatListCell] = []
  private var appearance = ChatListAppearance.fallback
  private var mode: Mode = .full

  enum Mode {
    /// Hub / create-theme: 2 message cells
    case compact
    /// Color editor / corners: them + voice + me
    case full
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true

    wallpaperLayer.startPoint = CGPoint(x: 0, y: 0)
    wallpaperLayer.endPoint = CGPoint(x: 1, y: 1)
    layer.insertSublayer(wallpaperLayer, at: 0)

    patternLayer.startPoint = CGPoint(x: 0, y: 0)
    patternLayer.endPoint = CGPoint(x: 1, y: 1)
    patternLayer.mask = patternMaskLayer
    patternMaskLayer.contentsGravity = .resizeAspectFill
    layer.insertSublayer(patternLayer, at: 1)

    stack.axis = .vertical
    stack.spacing = 8
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(draft: ChatAppearanceDraft, mode: Mode) {
    self.mode = mode
    appearance = ChatListAppearance.from(draft: draft)
    applyWallpaper()
    rebuildCellsIfNeeded()
    reconfigureCells()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    wallpaperLayer.frame = bounds
    patternLayer.frame = bounds
    patternMaskLayer.frame = patternLayer.bounds
    layoutCells()
  }

  // MARK: Wallpaper (mirrors ChatListView.applyWallpaperAppearance)

  private func applyWallpaper() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    wallpaperLayer.colors = appearance.wallpaperGradient.map(\.cgColor)
    wallpaperLayer.opacity = Float(max(0, min(1, appearance.wallpaperOpacity)))
    wallpaperLayer.isHidden = appearance.backgroundMode == "transparent"

    let canShowPattern =
      appearance.backgroundMode != "transparent"
      && appearance.wallpaperPatternGradient.count >= 2
      && appearance.wallpaperPatternOpacity > 0.001
      && (appearance.wallpaperMaskKey?.isEmpty == false)

    if canShowPattern,
      let maskKey = appearance.wallpaperMaskKey,
      let maskImage = ChatWallpaperMaskStore.image(forKey: maskKey)
    {
      patternLayer.colors = appearance.wallpaperPatternGradient.map(\.cgColor)
      patternLayer.locations = appearance.wallpaperPatternLocations
      patternLayer.opacity = Float(max(0, min(1, appearance.wallpaperPatternOpacity)))
      patternMaskLayer.contents = maskImage
      patternLayer.isHidden = false
    } else {
      patternLayer.isHidden = true
      patternLayer.colors = nil
      patternMaskLayer.contents = nil
      patternLayer.opacity = 0
    }
    CATransaction.commit()
  }

  // MARK: Cells

  private func rebuildCellsIfNeeded() {
    let count = mode == .compact ? 2 : 3
    if cells.count == count { return }
    cells.forEach { $0.removeFromSuperview() }
    stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    cells = (0..<count).map { _ in
      let cell = ChatListCell(frame: .zero)
      cell.isUserInteractionEnabled = false
      cell.backgroundColor = .clear
      cell.contentView.backgroundColor = .clear
      // Height container for the cell inside the stack
      let host = UIView()
      host.backgroundColor = .clear
      host.addSubview(cell)
      cell.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        cell.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        cell.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        cell.topAnchor.constraint(equalTo: host.topAnchor),
        cell.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        host.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      ])
      stack.addArrangedSubview(host)
      return cell
    }
  }

  private func reconfigureCells() {
    let r = appearance.messageCornerRadius
    let rows: [ChatListRow]
    switch mode {
    case .compact:
      rows = [
        ChatAppearancePreviewSamples.themRow(
          text: "How does it work?", radius: r, withTail: false),
        ChatAppearancePreviewSamples.meRow(
          text: "Use your current colors", radius: r),
      ]
    case .full:
      rows = [
        ChatAppearancePreviewSamples.themRow(
          text: "Does he want me to turn from the right or turn from the left? 🤔",
          radius: r),
        ChatAppearancePreviewSamples.voiceRow(radius: r),
        ChatAppearancePreviewSamples.meRow(
          text: "Is that everything? It seemed like he said quite a bit more than that. 😮",
          radius: r),
      ]
    }
    for (cell, row) in zip(cells, rows) {
      cell.applyAppearance(appearance)
      cell.configure(
        row: row,
        hiddenMessageId: nil,
        skipRemoteMediaLoad: true
      )
    }
  }

  private func layoutCells() {
    let width = bounds.width - 24
    guard width > 1 else { return }
    for cell in cells {
      guard let host = cell.superview else { continue }
      // Force layout pass so bubble metrics match production
      cell.bounds = CGRect(x: 0, y: 0, width: width, height: max(host.bounds.height, 60))
      cell.contentView.frame = cell.bounds
      cell.setNeedsLayout()
      cell.layoutIfNeeded()
      // Prefer intrinsic height after layout
      let target = cell.systemLayoutSizeFitting(
        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
      )
      let h = max(48, min(160, target.height))
      host.constraints.filter { $0.firstAttribute == .height }.forEach { host.removeConstraint($0) }
      host.heightAnchor.constraint(equalToConstant: h).isActive = true
      cell.frame = CGRect(x: 0, y: 0, width: width, height: h)
      cell.contentView.frame = cell.bounds
    }
  }
}

// MARK: - SwiftUI bridge

struct ChatAppearanceLiveHost: UIViewRepresentable {
  let draft: ChatAppearanceDraft
  var mode: ChatAppearanceLiveHostView.Mode = .full

  func makeUIView(context: Context) -> ChatAppearanceLiveHostView {
    let view = ChatAppearanceLiveHostView()
    view.apply(draft: draft, mode: mode)
    return view
  }

  func updateUIView(_ uiView: ChatAppearanceLiveHostView, context: Context) {
    uiView.apply(draft: draft, mode: mode)
  }
}

// MARK: - Abstract theme / wallpaper thumbs (no message text)

/// Compact tile: wallpaper wash + two bubble capsules + optional emoji.
/// Used in theme grids — never full mock message text.
struct AppearanceThemeThumbView: View {
  let draft: ChatAppearanceDraft
  var emoji: String? = nil
  var selected: Bool = false

  private var appearance: ChatListAppearance {
    ChatListAppearance.from(draft: draft)
  }

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      // Wallpaper (same colors as production model)
      LinearGradient(
        colors: appearance.wallpaperGradient.map { Color(uiColor: $0) },
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      WallpaperPatternPreview(appearance: appearance)

      // Bubble mockups: bounded `HStack` + `Spacer(minLength:)` rows so a
      // narrow tile (the 72pt COLOR THEME strip) never reports an intrinsic
      // width larger than what it was offered. The previous
      // `.frame(width: 44/54).frame(maxWidth: .infinity).padding(20)` chain
      // let the fixed-width capsule win over a tight proposal, inflating
      // this view's (and its clipShape's) width past the frame the caller
      // assigned — which is what bled tiles into their neighbors.
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 0) {
          Capsule()
            .fill(
              LinearGradient(
                colors: appearance.bubbleThemGradient.map { Color(uiColor: $0) },
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(width: 26, height: 14)
          Spacer(minLength: 6)
        }
        HStack(spacing: 0) {
          Spacer(minLength: 6)
          Capsule()
            .fill(
              LinearGradient(
                colors: appearance.bubbleMeGradient.map { Color(uiColor: $0) },
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(width: 32, height: 14)
        }
      }
      .padding(10)

      if let emoji {
        Text(emoji)
          .font(.system(size: 16))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          .padding(8)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(
          selected
            ? Color(uiColor: ChatListAppearance.brandAccentFallback)
            : Color.white.opacity(0.12),
          lineWidth: selected ? 2.5 : 1
        )
    )
    .shadow(
      color: selected
        ? Color(uiColor: ChatListAppearance.brandAccentFallback).opacity(0.35)
        : .clear,
      radius: selected ? 6 : 0, x: 0, y: selected ? 2 : 0
    )
  }
}

// MARK: - Wallpaper pattern preview (mask over gradient, mirrors ChatWallpaperView)

/// SwiftUI mirror of `ChatWallpaperView`'s `patternLayer` + `patternMaskLayer`: the
/// pattern's own gradient is masked by the wallpaper mask image, never drawn as
/// ordinary image content. The mask (device-resolution SVG rasterization used for
/// `doodles`/`hearts`) is alpha-only — it has no color channels, so treating it as
/// image content (as this used to via `.blendMode(.overlay)`) reads it as solid
/// black with only alpha varying, crushing every swatch toward black. Using it as
/// a `.mask()` reads only its alpha, which is all a mask should ever contribute.
struct WallpaperPatternPreview: View {
  let appearance: ChatListAppearance

  var body: some View {
    if appearance.backgroundMode != "transparent",
      appearance.wallpaperPatternGradient.count >= 2,
      appearance.wallpaperPatternOpacity > 0.001,
      let maskKey = appearance.wallpaperMaskKey, !maskKey.isEmpty,
      let cgImage = ChatWallpaperMaskStore.image(forKey: maskKey)
    {
      patternGradient
        .mask(
          Image(decorative: cgImage, scale: 1, orientation: .up)
            .resizable()
            .scaledToFill()
        )
        .opacity(Double(max(0.04, appearance.wallpaperPatternOpacity)))
        .allowsHitTesting(false)
    }
  }

  private var patternGradient: LinearGradient {
    LinearGradient(
      gradient: patternGradientStops, startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  private var patternGradientStops: Gradient {
    let colors = appearance.wallpaperPatternGradient.map { Color(uiColor: $0) }
    if let locations = appearance.wallpaperPatternLocations, locations.count == colors.count {
      return Gradient(
        stops: zip(colors, locations).map {
          Gradient.Stop(color: $0, location: CGFloat($1.doubleValue))
        }
      )
    }
    return Gradient(colors: colors)
  }
}

// MARK: - Wallpaper catalog

struct AppearanceWallpaperOption: Identifiable, Equatable {
  let id: String
  let title: String
  /// nil = solid / no pattern
  let maskKey: String?
  let emoji: String
}

enum AppearanceWallpaperCatalog {
  static let all: [AppearanceWallpaperOption] = [
    .init(id: "doodles", title: "Doodles", maskKey: "doodles", emoji: "✏️"),
    .init(id: "music", title: "Music", maskKey: "music", emoji: "🎵"),
    .init(id: "music2", title: "Pulse", maskKey: "music2", emoji: "🎧"),
    .init(id: "food", title: "Food", maskKey: "food", emoji: "🍕"),
    .init(id: "animals", title: "Animals", maskKey: "animals", emoji: "🐱"),
    .init(id: "cosmos", title: "Cosmos", maskKey: "cosmos", emoji: "🚀"),
    .init(id: "none", title: "None", maskKey: nil, emoji: "⬛"),
  ]
}

struct ChatWallpaperPickerView: View {
  @Binding var draft: ChatAppearanceDraft
  @Environment(\.colorScheme) private var colorScheme
  @State private var previewOption: AppearanceWallpaperOption?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private let columns = [
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10),
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // Live production preview
        ChatAppearanceLiveHost(draft: draft, mode: .compact)
          .frame(height: 160)
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .stroke(palette.border, lineWidth: 1)
          )

        Text("SELECT A WALLPAPER")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(palette.secondaryText.opacity(0.7))

        LazyVGrid(columns: columns, spacing: 10) {
          ForEach(AppearanceWallpaperCatalog.all) { option in
            let selected = selectedId == option.id
            Button {
              previewOption = option
            } label: {
              wallpaperThumb(option: option, selected: selected)
            }
            .buttonStyle(.plain)
          }
        }

        Text("PATTERN OPACITY")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(palette.secondaryText.opacity(0.7))
          .padding(.top, 4)

        HStack {
          Slider(
            value: Binding(
              get: { draft.wallpaperPatternOpacity },
              set: {
                draft.wallpaperPatternOpacity = $0
                ChatAppearanceDraftStore.save(draft)
              }
            ),
            in: 0...0.4
          )
          .tint(Color(uiColor: ChatListAppearance.brandAccentFallback))
          Text("\(Int(draft.wallpaperPatternOpacity * 100))%")
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(palette.secondaryText)
            .frame(width: 44, alignment: .trailing)
        }
      }
      .padding(16)
    }
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Chat Wallpaper")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $previewOption) { option in
      WallpaperPreviewSheet(option: option, baseDraft: draft) {
        apply(option)
      }
      .presentationDetents([.fraction(0.92), .large])
      .presentationDragIndicator(.visible)
    }
  }

  private var selectedId: String {
    if let key = draft.wallpaperPatternMaskKey, !key.isEmpty {
      return key
    }
    return "none"
  }

  /// Commits a wallpaper selection into the real draft and persists it.
  /// Only ever called from the preview sheet's "Set" button — tapping a
  /// grid tile just opens the preview, it never mutates `draft` itself.
  private func apply(_ option: AppearanceWallpaperOption) {
    draft.wallpaperPatternMaskKey = option.maskKey
    if option.maskKey == nil {
      draft.wallpaperPatternOpacity = 0
    } else if draft.wallpaperPatternOpacity < 0.05 {
      draft.wallpaperPatternOpacity = 0.17
    }
    draft.wallpaperKind = option.maskKey == nil ? "solid" : "gradient"
    ChatAppearanceDraftStore.save(draft)
  }

  private func wallpaperThumb(option: AppearanceWallpaperOption, selected: Bool) -> some View {
    var thumbDraft = draft
    thumbDraft.wallpaperPatternMaskKey = option.maskKey
    thumbDraft.wallpaperPatternOpacity = option.maskKey == nil ? 0 : max(0.12, draft.wallpaperPatternOpacity)
    return ZStack(alignment: .bottomLeading) {
      AppearanceThemeThumbView(draft: thumbDraft, emoji: option.emoji, selected: selected)
      Text(option.title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .padding(8)
    }
    // Portrait 3:4 tile — matches how a wallpaper actually reads behind a
    // full chat column, rather than the old near-square crop.
    .aspectRatio(3.0 / 4.0, contentMode: .fit)
  }
}

// MARK: - Wallpaper full-screen preview sheet

/// Large preview of a single wallpaper option, rendered with the same
/// gradient + mask recipe as `WallpaperPatternPreview`/`ChatAppearanceCanvas`
/// (a couple of sample bubbles included) so what you see here is exactly
/// what the chat will look like. `baseDraft` is a snapshot, not the live
/// binding — dismissing without tapping "Set" never touches the real draft.
private struct WallpaperPreviewSheet: View {
  let option: AppearanceWallpaperOption
  let baseDraft: ChatAppearanceDraft
  var onSet: () -> Void

  @Environment(\.dismiss) private var dismiss

  private var previewDraft: ChatAppearanceDraft {
    var next = baseDraft
    next.wallpaperPatternMaskKey = option.maskKey
    next.wallpaperPatternOpacity =
      option.maskKey == nil ? 0 : max(0.12, baseDraft.wallpaperPatternOpacity)
    next.wallpaperKind = option.maskKey == nil ? "solid" : "gradient"
    return next
  }

  var body: some View {
    ZStack {
      ChatAppearanceCanvas(draft: previewDraft)
        .ignoresSafeArea()

      VStack {
        HStack {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 14, weight: .bold))
              .foregroundColor(.white)
              .frame(width: 34, height: 34)
              .background(Circle().fill(Color.black.opacity(0.4)))
          }
          Spacer()
          Text(option.title)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.4), radius: 4)
          Spacer()
          Color.clear.frame(width: 34, height: 34)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)

        Spacer()

        Button {
          onSet()
          dismiss()
        } label: {
          Text("Set")
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.black.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Capsule().fill(Color.white.opacity(0.92)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
      }
    }
    .preferredColorScheme(.dark)
  }
}
