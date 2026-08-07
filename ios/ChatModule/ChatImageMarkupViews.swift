import PencilKit
import SwiftUI
import UIKit

// MARK: - Model

enum ChatImageMarkupMode: String, CaseIterable, Identifiable {
  case draw, sticker, text, ai
  var id: String { rawValue }
  var title: String {
    switch self {
    case .draw: return "Draw"
    case .sticker: return "Sticker"
    case .text: return "Text"
    case .ai: return "AI"
    }
  }
}

enum ChatImageDrawTool: String, CaseIterable, Identifiable {
  case pen, marker, highlighter, pencil, mono, eraser
  var id: String { rawValue }

  var tipColor: Color {
    switch self {
    case .pen: return Color(red: 0.2, green: 0.45, blue: 1.0)
    case .marker: return Color(red: 1.0, green: 0.55, blue: 0.12)
    case .highlighter: return Color(red: 0.98, green: 0.86, blue: 0.12)
    case .pencil: return Color(red: 0.2, green: 0.85, blue: 0.35)
    case .mono: return Color(white: 0.95)
    case .eraser: return Color(red: 1.0, green: 0.55, blue: 0.72)
    }
  }

  var inkWidth: CGFloat {
    switch self {
    case .pen: return 5
    case .marker: return 14
    case .highlighter: return 26
    case .pencil: return 3.5
    case .mono: return 4
    case .eraser: return 20
    }
  }

  var systemSymbol: String {
    switch self {
    case .pen: return "pencil.tip"
    case .marker: return "paintbrush.pointed.fill"
    case .highlighter: return "highlighter"
    case .pencil: return "pencil"
    case .mono: return "pencil.and.scribble"
    case .eraser: return "eraser.fill"
    }
  }
}

enum ChatImageShapeKind: String, CaseIterable, Identifiable {
  case rectangle, ellipse, bubble, star, arrow
  var id: String { rawValue }
  var title: String {
    switch self {
    case .rectangle: return "Rectangle"
    case .ellipse: return "Ellipse"
    case .bubble: return "Bubble"
    case .star: return "Star"
    case .arrow: return "Arrow"
    }
  }
  var systemImage: String {
    switch self {
    case .rectangle: return "rectangle"
    case .ellipse: return "circle"
    case .bubble: return "bubble.left"
    case .star: return "star"
    case .arrow: return "arrow.up.right"
    }
  }
}

@MainActor
final class ChatImageMarkupModel: ObservableObject {
  @Published var mode: ChatImageMarkupMode = .draw
  @Published var drawTool: ChatImageDrawTool = .pen
  @Published var inkColor: Color = .blue
  @Published var inkOpacity: Double = 1.0
  @Published var textFontSize: CGFloat = 28
  @Published var textBold = true
  @Published var textFontName: String = "San Francisco"
  @Published var isEditing = false
  @Published var showShapeMenu = false

  // AI editing. `aiHasSelection` reflects whether the user has dragged a region
  // on the image — when false the edit applies to the whole picture.
  @Published var aiPrompt: String = ""
  @Published var aiIsWorking = false
  @Published var aiHasSelection = false
  @Published var aiCanUndo = false

  var uiColor: UIColor {
    UIColor(inkColor).withAlphaComponent(inkOpacity)
  }

  func makeInk() -> PKInkingTool {
    let color = uiColor
    switch drawTool {
    case .pen, .mono:
      return PKInkingTool(.pen, color: color, width: drawTool.inkWidth)
    case .marker:
      return PKInkingTool(.marker, color: color, width: drawTool.inkWidth)
    case .highlighter:
      return PKInkingTool(
        .marker, color: color.withAlphaComponent(min(0.4, inkOpacity)), width: drawTool.inkWidth)
    case .pencil:
      return PKInkingTool(.pencil, color: color, width: drawTool.inkWidth)
    case .eraser:
      return PKInkingTool(.pen, color: .clear, width: 1)
    }
  }
}

// MARK: - Markup bottom chrome (solid black, no wrapper gap — matches system Markup)

struct ChatImageMarkupToolbar: View {
  @ObservedObject var model: ChatImageMarkupModel
  var onCancel: () -> Void
  var onConfirm: () -> Void
  var onColorWheel: () -> Void
  var onAddText: () -> Void
  var onOpenStickers: () -> Void
  var onPickShape: (ChatImageShapeKind) -> Void
  var onAIGenerate: () -> Void = {}
  var onAIClearSelection: () -> Void = {}
  var onAIUndo: () -> Void = {}

  private let palette: [Color] = [
    .red, .orange, .yellow, .green, .cyan, .blue, .purple, .white,
  ]

  var body: some View {
    VStack(spacing: 0) {
      // Tool strip — solid black, no material “wrapper”
      Group {
        switch model.mode {
        case .draw: drawStrip
        case .text: textStrip
        case .sticker: stickerHintStrip
        case .ai: aiStrip
        }
      }
      .frame(minHeight: 72)
      .padding(.horizontal, 10)
      .padding(.top, 8)
      .padding(.bottom, 6)

      // X · Draw/Sticker/Text · ✓
      HStack(spacing: 12) {
        Button(action: onCancel) {
          Image(systemName: "xmark")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(Color.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)

        HStack(spacing: 0) {
          ForEach(ChatImageMarkupMode.allCases) { mode in
            Button {
              withAnimation(.easeInOut(duration: 0.15)) { model.mode = mode }
              if mode == .sticker { onOpenStickers() }
            } label: {
              Text(mode.title)
                .font(.system(size: 15, weight: model.mode == mode ? .semibold : .medium))
                .foregroundStyle(model.mode == mode ? Color.white : Color.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background {
                  if model.mode == mode {
                    Capsule().fill(Color.white.opacity(0.16))
                  }
                }
            }
            .buttonStyle(.plain)
          }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.10)))

        Button(action: onConfirm) {
          Image(systemName: "checkmark")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(Color.accentColor, in: Circle())
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 14)
      .padding(.bottom, 10)
    }
    .background(Color.black)  // solid — no gap / no material wrapper
    .confirmationDialog("Shapes", isPresented: $model.showShapeMenu, titleVisibility: .hidden) {
      ForEach(ChatImageShapeKind.allCases) { kind in
        Button {
          onPickShape(kind)
        } label: {
          Label(kind.title, systemImage: kind.systemImage)
        }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  // MARK: Draw strip — pens + color row (like ref #2 / #6)

  private var drawStrip: some View {
    VStack(spacing: 8) {
      HStack(alignment: .bottom, spacing: 2) {
        colorWheelButton
        ForEach(ChatImageDrawTool.allCases) { tool in
          Button {
            model.drawTool = tool
          } label: {
            MarkupMarkerView(tool: tool, selected: model.drawTool == tool)
              .frame(width: 40, height: 58)
          }
          .buttonStyle(.plain)
        }
        Spacer(minLength: 2)
        Button {
          model.showShapeMenu = true
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
      }

      HStack(spacing: 9) {
        ForEach(Array(palette.enumerated()), id: \.offset) { _, c in
          Button {
            model.inkColor = c
            model.inkOpacity = 1
          } label: {
            Circle()
              .fill(c)
              .frame(width: 20, height: 20)
              .overlay(
                Circle().strokeBorder(
                  Color.white.opacity(colorEq(model.inkColor, c) ? 1 : 0.2),
                  lineWidth: colorEq(model.inkColor, c) ? 2.2 : 0.6
                )
              )
          }
          .buttonStyle(.plain)
        }
        Spacer(minLength: 0)
      }
    }
  }

  // MARK: Text strip

  private var textStrip: some View {
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        colorWheelButton
        toolChip(system: "textformat", selected: model.textBold) {
          model.textBold.toggle()
        }
        toolChip(system: "text.aligncenter", selected: false) {}
        Menu {
          ForEach(
            ["San Francisco", "Helvetica Neue", "Georgia", "Courier New", "Avenir Next"],
            id: \.self
          ) { name in
            Button(name) { model.textFontName = name }
          }
        } label: {
          HStack(spacing: 4) {
            Text(model.textFontName)
              .font(.system(size: 13, weight: .semibold))
              .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
              .font(.system(size: 9, weight: .semibold))
          }
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(Color.white.opacity(0.12), in: Capsule())
        }
        Spacer(minLength: 0)
        Button(action: onAddText) {
          Image(systemName: "plus")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
      }

      HStack(spacing: 9) {
        ForEach(Array(palette.enumerated()), id: \.offset) { _, c in
          Button {
            model.inkColor = c
            model.inkOpacity = 1
          } label: {
            Circle()
              .fill(c)
              .frame(width: 20, height: 20)
              .overlay(
                Circle().strokeBorder(
                  Color.white.opacity(colorEq(model.inkColor, c) ? 1 : 0.2),
                  lineWidth: colorEq(model.inkColor, c) ? 2.2 : 0.6
                )
              )
          }
          .buttonStyle(.plain)
        }
        Spacer(minLength: 0)
      }
    }
  }

  private var stickerHintStrip: some View {
    HStack {
      Text("Pick a sticker or GIF")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
      Spacer()
      Button("Open library", action: onOpenStickers)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.accentColor)
    }
    .frame(maxWidth: .infinity, minHeight: 56)
  }

  // MARK: AI strip — prompt + scope chip, same height as the other strips so
  // switching tabs never resizes the bar.

  private var aiStrip: some View {
    HStack(spacing: 10) {
      scopeChip

      HStack(spacing: 8) {
        TextField("Describe the edit…", text: $model.aiPrompt)
          .textFieldStyle(.plain)
          .font(.system(size: 15))
          .foregroundStyle(.white)
          .tint(.white)
          .submitLabel(.go)
          .disabled(model.aiIsWorking)
          .onSubmit { if canGenerate { onAIGenerate() } }

        if model.aiIsWorking {
          ProgressView()
            .controlSize(.small)
            .tint(.white)
            .transition(.opacity)
        } else {
          Button(action: onAIGenerate) {
            Image(systemName: "arrow.up")
              .font(.system(size: 14, weight: .bold))
              .foregroundStyle(canGenerate ? Color.black : Color.white.opacity(0.4))
              .frame(width: 28, height: 28)
              .background(
                Circle().fill(canGenerate ? Color.white : Color.white.opacity(0.12))
              )
          }
          .buttonStyle(.plain)
          .disabled(!canGenerate)
        }
      }
      .padding(.leading, 14)
      .padding(.trailing, 6)
      .padding(.vertical, 6)
      .background(Capsule().fill(Color.white.opacity(0.10)))

      if model.aiCanUndo && !model.aiIsWorking {
        Button(action: onAIUndo) {
          Image(systemName: "arrow.uturn.backward")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
      }
    }
    .frame(maxWidth: .infinity, minHeight: 56)
    .animation(.easeInOut(duration: 0.18), value: model.aiIsWorking)
    .animation(.easeInOut(duration: 0.18), value: model.aiCanUndo)
    .animation(.easeInOut(duration: 0.18), value: model.aiHasSelection)
  }

  /// Tapping the chip when a region is set clears it back to whole-image.
  private var scopeChip: some View {
    Button {
      if model.aiHasSelection { onAIClearSelection() }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: model.aiHasSelection ? "viewfinder" : "photo")
          .font(.system(size: 12, weight: .semibold))
        Text(model.aiHasSelection ? "Area" : "All")
          .font(.system(size: 13, weight: .semibold))
        if model.aiHasSelection {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .opacity(0.7)
        }
      }
      .foregroundStyle(model.aiHasSelection ? Color.black : Color.white.opacity(0.75))
      .padding(.horizontal, 11)
      .padding(.vertical, 9)
      .background(
        Capsule().fill(model.aiHasSelection ? Color.white : Color.white.opacity(0.10))
      )
    }
    .buttonStyle(.plain)
    .disabled(model.aiIsWorking)
  }

  private var canGenerate: Bool {
    !model.aiIsWorking
      && !model.aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var colorWheelButton: some View {
    Button(action: onColorWheel) {
      ZStack {
        Circle()
          .fill(
            AngularGradient(
              colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
              center: .center)
          )
          .frame(width: 26, height: 26)
        Circle()
          .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
          .frame(width: 26, height: 26)
      }
      .frame(width: 36, height: 56)
    }
    .buttonStyle(.plain)
  }

  private func toolChip(system: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: system)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(selected ? Color.accentColor : Color.white)
        .frame(width: 34, height: 34)
        .background(
          Color.white.opacity(selected ? 0.22 : 0.12),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private func colorEq(_ a: Color, _ b: Color) -> Bool {
    let ua = UIColor(a)
    let ub = UIColor(b)
    var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
    var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
    ua.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
    ub.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
    return abs(ar - br) < 0.05 && abs(ag - bg) < 0.05 && abs(ab - bb) < 0.05
  }
}

// MARK: - Marker silhouette (closer to system pens)

struct MarkupMarkerView: View {
  let tool: ChatImageDrawTool
  let selected: Bool

  var body: some View {
    VStack(spacing: 0) {
      // Tip
      UnevenRoundedRectangle(
        topLeadingRadius: tipRadius,
        bottomLeadingRadius: 1,
        bottomTrailingRadius: 1,
        topTrailingRadius: tipRadius
      )
      .fill(tool.tipColor)
      .frame(width: tipW, height: tipH)

      // Barrel
      RoundedRectangle(cornerRadius: 2.5, style: .continuous)
        .fill(
          LinearGradient(
            colors: [Color(white: 0.18), Color(white: 0.08)],
            startPoint: .leading,
            endPoint: .trailing)
        )
        .frame(width: barrelW, height: selected ? 40 : 34)
        .overlay(alignment: .top) {
          Rectangle()
            .fill(tool.tipColor)
            .frame(height: 3.5)
        }
        .overlay(
          RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .strokeBorder(Color.white.opacity(selected ? 0.35 : 0.1), lineWidth: selected ? 1 : 0.5)
        )
    }
    .offset(y: selected ? -5 : 0)
    .shadow(color: .black.opacity(selected ? 0.5 : 0.2), radius: selected ? 5 : 2, y: 1)
    .animation(.easeInOut(duration: 0.14), value: selected)
  }

  private var tipW: CGFloat {
    switch tool {
    case .highlighter: return 15
    case .marker: return 12
    case .eraser: return 13
    default: return 8
    }
  }
  private var tipH: CGFloat {
    switch tool {
    case .pencil: return 9
    case .mono: return 10
    default: return 7
    }
  }
  private var tipRadius: CGFloat { tool == .highlighter || tool == .marker ? 2 : 3 }
  private var barrelW: CGFloat {
    switch tool {
    case .highlighter: return 15
    case .marker: return 12
    case .eraser: return 13
    default: return 10
    }
  }
}

// MARK: - View-mode bottom actions (share / markup / delete) — glass SwiftUI

struct ChatImageViewerBottomBar: View {
  var onShare: () -> Void
  var onMarkup: () -> Void
  var onAI: () -> Void
  var onDelete: () -> Void

  /// One control size for every slot in the bar. Previously the side circles
  /// were 48pt with 18pt glyphs while the centre capsule sized itself from its
  /// own padding, so the three groups never sat on a shared baseline.
  static let controlSide: CGFloat = 48.0
  static let glyphSize: CGFloat = 19.0
  static let verticalPadding: CGFloat = 12.0
  static let barHeight: CGFloat = controlSide + verticalPadding * 2.0

  var body: some View {
    HStack(spacing: 0) {
      // Forward-arrow share, matching the send/forward affordance used in the
      // chat itself rather than the system box-and-arrow.
      circleButton(system: "arrowshape.turn.up.right.fill", action: onShare)

      Spacer(minLength: 12)

      HStack(spacing: 0) {
        capsuleButton(system: "pencil.tip.crop.circle", action: onMarkup)
        capsuleButton(system: "sparkles", action: onAI)
      }
      .frame(height: Self.controlSide)
      .padding(.horizontal, 6)
      .background {
        Capsule()
          .fill(.ultraThinMaterial)
          .environment(\.colorScheme, .dark)
          .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
      }

      Spacer(minLength: 12)

      circleButton(system: "trash", action: onDelete)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, Self.verticalPadding)
    .frame(maxWidth: .infinity)
  }

  private func circleButton(system: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: system)
        .font(.system(size: Self.glyphSize, weight: .medium))
        .foregroundStyle(.white)
        .frame(width: Self.controlSide, height: Self.controlSide)
        .background {
          Circle()
            .fill(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        }
    }
    .buttonStyle(.plain)
  }

  private func capsuleButton(system: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: system)
        .font(.system(size: Self.glyphSize, weight: .medium))
        .foregroundStyle(.white)
        .frame(width: Self.controlSide, height: Self.controlSide)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Text keyboard accessory (ref: color · A · align · emoji · San Francisco)

struct ChatImageTextKeyboardBar: View {
  @ObservedObject var model: ChatImageMarkupModel
  var onColor: () -> Void
  var onEmoji: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button(action: onColor) {
        ZStack {
          Circle()
            .fill(
              AngularGradient(
                colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)
            )
            .frame(width: 24, height: 24)
          Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.2).frame(width: 24, height: 24)
        }
      }
      .buttonStyle(.plain)

      Button {
        model.textBold.toggle()
      } label: {
        Image(systemName: "textformat")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(model.textBold ? Color.accentColor : Color.primary)
          .frame(width: 34, height: 34)
          .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)

      Image(systemName: "text.aligncenter")
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 34, height: 34)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

      Button(action: onEmoji) {
        Image(systemName: "face.smiling")
          .font(.system(size: 15, weight: .semibold))
          .frame(width: 34, height: 34)
          .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)

      Spacer(minLength: 4)

      Menu {
        ForEach(
          ["San Francisco", "Helvetica Neue", "Georgia", "Courier New", "Avenir Next"],
          id: \.self
        ) { name in
          Button(name) { model.textFontName = name }
        }
      } label: {
        HStack(spacing: 4) {
          Text(model.textFontName)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity)
    .background(.bar)
  }
}

// MARK: - Hosts

final class ChatImageMarkupToolbarHost: UIView {
  private let model: ChatImageMarkupModel
  private var hosting: UIHostingController<ChatImageMarkupToolbar>?

  var onCancel: (() -> Void)?
  var onConfirm: (() -> Void)?
  var onColorWheel: (() -> Void)?
  var onAddText: (() -> Void)?
  var onOpenStickers: (() -> Void)?
  var onPickShape: ((ChatImageShapeKind) -> Void)?
  var onAIGenerate: (() -> Void)?
  var onAIClearSelection: (() -> Void)?
  var onAIUndo: (() -> Void)?

  init(model: ChatImageMarkupModel) {
    self.model = model
    super.init(frame: .zero)
    backgroundColor = .black
    installRoot()
  }

  required init?(coder: NSCoder) { nil }

  private func installRoot() {
    hosting?.view.removeFromSuperview()
    let root = makeRoot()
    let host = UIHostingController(rootView: root)
    host.view.backgroundColor = .black
    host.view.isOpaque = true
    addSubview(host.view)
    hosting = host
  }

  private func makeRoot() -> ChatImageMarkupToolbar {
    ChatImageMarkupToolbar(
      model: model,
      onCancel: { [weak self] in self?.onCancel?() },
      onConfirm: { [weak self] in self?.onConfirm?() },
      onColorWheel: { [weak self] in self?.onColorWheel?() },
      onAddText: { [weak self] in self?.onAddText?() },
      onOpenStickers: { [weak self] in self?.onOpenStickers?() },
      onPickShape: { [weak self] k in self?.onPickShape?(k) },
      onAIGenerate: { [weak self] in self?.onAIGenerate?() },
      onAIClearSelection: { [weak self] in self?.onAIClearSelection?() },
      onAIUndo: { [weak self] in self?.onAIUndo?() }
    )
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    hosting?.view.frame = bounds
  }

  func preferredHeight(for width: CGFloat) -> CGFloat {
    max(150, hosting?.sizeThatFits(in: CGSize(width: width, height: 240)).height ?? 158)
  }

  func refresh() {
    hosting?.rootView = makeRoot()
  }
}

final class ChatImageViewerBottomBarHost: UIView {
  private var hosting: UIHostingController<ChatImageViewerBottomBar>?
  var onShare: (() -> Void)?
  var onMarkup: (() -> Void)?
  var onAI: (() -> Void)?
  var onDelete: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    // Transparent: the bar floats over a full-bleed photo now, so an opaque
    // black plate here would crop the picture it sits on.
    backgroundColor = .clear
    isOpaque = false
    let root = ChatImageViewerBottomBar(
      onShare: { [weak self] in self?.onShare?() },
      onMarkup: { [weak self] in self?.onMarkup?() },
      onAI: { [weak self] in self?.onAI?() },
      onDelete: { [weak self] in self?.onDelete?() }
    )
    let host = UIHostingController(rootView: root)
    host.view.backgroundColor = .clear
    host.view.isOpaque = false
    addSubview(host.view)
    hosting = host
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    hosting?.view.frame = bounds
  }

  var preferredHeight: CGFloat { ChatImageViewerBottomBar.barHeight }
}
