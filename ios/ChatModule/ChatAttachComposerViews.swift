import PhotosUI
import SwiftUI
import UIKit

// MARK: - Keep policy / send options

enum ChatMediaKeepPolicy: Equatable {
  case persist
  case viewOnce
  case seconds(Int)

  var title: String {
    switch self {
    case .persist: return "Do Not Delete"
    case .viewOnce: return "View Once"
    case .seconds(let s): return "\(s) Seconds"
    }
  }

  var viewOnce: Bool {
    switch self {
    case .persist: return false
    default: return true
    }
  }

  var mediaTtlSeconds: Int? {
    switch self {
    case .persist: return nil
    case .viewOnce: return 0
    case .seconds(let s): return s
    }
  }

  static let menuOrder: [ChatMediaKeepPolicy] = [
    .viewOnce, .seconds(3), .seconds(10), .seconds(30), .persist,
  ]
}

struct ChatAttachmentSendOptions {
  var viewOnce: Bool = false
  var mediaTtlSeconds: Int? = nil
  var isHighQuality: Bool = false

  static func from(_ policy: ChatMediaKeepPolicy, highQuality: Bool) -> ChatAttachmentSendOptions {
    ChatAttachmentSendOptions(
      viewOnce: policy.viewOnce,
      mediaTtlSeconds: policy.mediaTtlSeconds,
      isHighQuality: highQuality)
  }
}

enum ChatAttachSendContext {
  static var pending: ChatAttachmentSendOptions?

  static func take() -> ChatAttachmentSendOptions? {
    let value = pending
    pending = nil
    return value
  }
}

// MARK: - Composer model

@MainActor
final class ChatAttachComposerModel: ObservableObject {
  @Published var recipientName: String
  @Published var pickCount: Int
  @Published var pageIndex: Int
  @Published var caption: String
  @Published var keepPolicy: ChatMediaKeepPolicy = .persist
  @Published var isHighQuality: Bool = false
  @Published var showKeepMenu: Bool = false
  @Published var showAdjustments: Bool = false
  @Published var brightness: Double = 0
  @Published var contrast: Double = 0
  @Published var saturation: Double = 0
  @Published var isCropping: Bool = false

  var hasAdjustments: Bool {
    abs(brightness) > 0.004 || abs(contrast) > 0.004 || abs(saturation) > 0.004
  }

  init(recipientName: String, pickCount: Int, pageIndex: Int, caption: String) {
    self.recipientName = recipientName
    self.pickCount = pickCount
    self.pageIndex = pageIndex
    self.caption = caption
  }

  func resetAdjustments() {
    brightness = 0
    contrast = 0
    saturation = 0
  }
}

// MARK: - Chrome

struct ChatAttachComposerChrome: View {
  @ObservedObject var model: ChatAttachComposerModel
  var sendColor: Color
  var onClose: () -> Void
  var onPick: () -> Void
  var onCrop: () -> Void
  var onDraw: () -> Void
  var onToggleAdjust: () -> Void
  var onToggleHD: () -> Void
  var onSend: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
      Spacer(minLength: 0)
      if model.showAdjustments {
        adjustPanel
          .padding(.horizontal, 16)
          .padding(.bottom, 10)
      }
      if model.pickCount > 0 {
        HStack {
          Spacer()
          Text("\(min(model.pageIndex + 1, max(model.pickCount, 1)))")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.4))
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
      }
      captionRow
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
      toolbar
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
    .overlay { if model.showKeepMenu { keepMenu } }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Button(action: onClose) {
        HStack(spacing: 5) {
          Image(systemName: "arrow.up")
            .font(.system(size: 13, weight: .semibold))
          Text(model.recipientName.isEmpty ? "Send" : model.recipientName)
            .font(.system(size: 16, weight: .semibold))
            .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .frame(height: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      Spacer(minLength: 8)
      Button(action: onPick) {
        ZStack {
          if model.pickCount > 0 {
            Circle().fill(Color(red: 0.32, green: 0.82, blue: 0.47))
            Text("\(model.pickCount)")
              .font(.system(size: 15, weight: .bold))
              .foregroundStyle(.white)
          } else {
            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.6)
          }
        }
        .frame(width: 32, height: 32)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Pick more photos")
    }
    .padding(.horizontal, 16)
    .padding(.top, 2)
  }

  private var captionRow: some View {
    HStack(spacing: 8) {
      TextField(
        "",
        text: $model.caption,
        prompt: Text("Add a caption…").foregroundStyle(.white.opacity(0.45))
      )
      .font(.system(size: 16))
      .foregroundStyle(.white)
      .tint(.white)
      Button {
        model.showKeepMenu = true
      } label: {
        Image(systemName: model.keepPolicy == .persist ? "timer" : "timer.circle.fill")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .frame(width: 32, height: 32)
      }
      .buttonStyle(.plain)
    }
    .padding(.leading, 16)
    .padding(.trailing, 8)
    .frame(height: 44)
    .background(.white.opacity(0.12), in: Capsule())
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      glassCircle(system: "chevron.backward", action: onClose)
      HStack(spacing: 0) {
        toolButton(system: "crop", selected: model.isCropping, action: onCrop)
        toolButton(system: "textformat", selected: false, action: onDraw)
        toolButton(system: "slider.horizontal.3", selected: model.showAdjustments, action: onToggleAdjust)
        Button(action: onToggleHD) {
          Text(model.isHighQuality ? "HD" : "SD")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .frame(height: 44)
      .padding(.horizontal, 4)
      .glassEffect(.regular.interactive(true), in: .capsule)
      Button(action: onSend) {
        Image(systemName: "paperplane.fill")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 48, height: 48)
          .background(sendColor, in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Send")
    }
  }

  private func glassCircle(system: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: system)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .glassEffect(.regular.interactive(true), in: .circle)
    }
    .buttonStyle(.plain)
  }

  private func toolButton(system: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: system)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.92))
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var adjustPanel: some View {
    VStack(spacing: 10) {
      adjustSlider(title: "Brightness", value: $model.brightness)
      adjustSlider(title: "Contrast", value: $model.contrast)
      adjustSlider(title: "Saturation", value: $model.saturation)
    }
    .padding(14)
    .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func adjustSlider(title: String, value: Binding<Double>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.7))
      Slider(value: value, in: -0.7...0.7)
        .tint(.white)
    }
  }

  private var keepMenu: some View {
    ZStack {
      Color.black.opacity(0.35)
        .ignoresSafeArea()
        .onTapGesture { model.showKeepMenu = false }
      VStack(spacing: 0) {
        Text("Choose how long the media will be kept after opening.")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 20)
          .padding(.top, 18)
          .padding(.bottom, 10)
        ForEach(Array(ChatMediaKeepPolicy.menuOrder.enumerated()), id: \.offset) { _, policy in
          Button {
            model.keepPolicy = policy
            model.showKeepMenu = false
          } label: {
            HStack {
              if model.keepPolicy == policy {
                Image(systemName: "checkmark")
                  .font(.system(size: 15, weight: .semibold))
                  .frame(width: 22)
              } else {
                Color.clear.frame(width: 22, height: 1)
              }
              Text(policy.title)
                .font(.system(size: 17, weight: .regular))
              Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 48)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.bottom, 8)
      .frame(maxWidth: 320)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
      .offset(y: 80)
    }
  }
}

@MainActor
final class ChatAttachComposerChromeHost: UIView {
  let model: ChatAttachComposerModel
  private var hosting: UIHostingController<ChatAttachComposerChrome>?

  var onClose: (() -> Void)?
  var onPick: (() -> Void)?
  var onCrop: (() -> Void)?
  var onDraw: (() -> Void)?
  var onToggleAdjust: (() -> Void)?
  var onToggleHD: (() -> Void)?
  var onSend: (() -> Void)?

  init(model: ChatAttachComposerModel, sendColor: UIColor) {
    self.model = model
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    let root = ChatAttachComposerChrome(
      model: model,
      sendColor: Color(sendColor),
      onClose: { [weak self] in self?.onClose?() },
      onPick: { [weak self] in self?.onPick?() },
      onCrop: { [weak self] in self?.onCrop?() },
      onDraw: { [weak self] in self?.onDraw?() },
      onToggleAdjust: { [weak self] in self?.onToggleAdjust?() },
      onToggleHD: { [weak self] in self?.onToggleHD?() },
      onSend: { [weak self] in self?.onSend?() }
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

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    if hit === self || hit === hosting?.view { return nil }
    return hit
  }
}

final class ChatAttachCropOverlay: UIView {
  var cropRectInView: CGRect = .zero
  private let shade = CAShapeLayer()
  private let border = CAShapeLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    shade.fillRule = .evenOdd
    shade.fillColor = UIColor.black.withAlphaComponent(0.45).cgColor
    border.strokeColor = UIColor.white.cgColor
    border.fillColor = UIColor.clear.cgColor
    border.lineWidth = 1.2
    layer.addSublayer(shade)
    layer.addSublayer(border)
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    addGestureRecognizer(pan)
  }

  required init?(coder: NSCoder) { nil }

  func install(over imageFrame: CGRect) {
    let inset = min(imageFrame.width, imageFrame.height) * 0.08
    cropRectInView = imageFrame.insetBy(dx: inset, dy: inset)
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    shade.frame = bounds
    border.frame = bounds
    let path = UIBezierPath(rect: bounds)
    path.append(UIBezierPath(rect: cropRectInView))
    shade.path = path.cgPath
    border.path = UIBezierPath(rect: cropRectInView).cgPath
  }

  @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
    let delta = gr.translation(in: self)
    gr.setTranslation(.zero, in: self)
    var next = cropRectInView.offsetBy(dx: delta.x, dy: delta.y)
    next.origin.x = min(max(0, next.origin.x), bounds.width - next.width)
    next.origin.y = min(max(0, next.origin.y), bounds.height - next.height)
    cropRectInView = next
    setNeedsLayout()
  }

  func croppedImage(from image: UIImage, drawnIn imageFrame: CGRect) -> UIImage? {
    guard imageFrame.width > 1, imageFrame.height > 1 else { return image }
    let sx = image.size.width / imageFrame.width
    let sy = image.size.height / imageFrame.height
    let crop = CGRect(
      x: (cropRectInView.minX - imageFrame.minX) * sx,
      y: (cropRectInView.minY - imageFrame.minY) * sy,
      width: cropRectInView.width * sx,
      height: cropRectInView.height * sy
    ).integral
    guard let cg = image.cgImage?.cropping(to: crop) else { return image }
    return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
  }
}

enum ChatAttachImageAdjust {
  static func apply(_ image: UIImage, brightness: Double, contrast: Double, saturation: Double)
    -> UIImage
  {
    guard abs(brightness) > 0.004 || abs(contrast) > 0.004 || abs(saturation) > 0.004 else {
      return image
    }
    guard let ciImage = CIImage(image: image) else { return image }
    let filter = CIFilter(name: "CIColorControls")
    filter?.setValue(ciImage, forKey: kCIInputImageKey)
    filter?.setValue(brightness, forKey: kCIInputBrightnessKey)
    filter?.setValue(1.0 + contrast, forKey: kCIInputContrastKey)
    filter?.setValue(1.0 + saturation, forKey: kCIInputSaturationKey)
    guard let output = filter?.outputImage else { return image }
    let context = CIContext(options: nil)
    guard let cg = context.createCGImage(output, from: output.extent) else { return image }
    return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
  }
}
