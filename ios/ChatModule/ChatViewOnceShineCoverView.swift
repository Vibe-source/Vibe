import CoreImage
import Metal
import UIKit

/// View-once media cover: blurred still plus a tiny animated sparkle field.
/// Snapshot-friendly (UIImageViews) so the existing delete disintegration captures it.
final class ChatViewOnceShineCoverView: UIView {
  private let blurredImageView = UIImageView()
  private let dimView = UIView()
  private let sparkleImageView = UIImageView()
  private let flameView = UIImageView()

  private let renderer = SparkleRenderer.shared
  private let tickProxy = TickProxy()
  private var displayLink: CADisplayLink?
  private var blurGeneration: UInt = 0
  private var lastBlurSource: ObjectIdentifier?
  private var lastSparkleSize = CGSize.zero
  private var showsFlame = false
  private var isActive = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true
    isOpaque = false
    backgroundColor = UIColor(white: 0.10, alpha: 1.0)

    blurredImageView.contentMode = .scaleAspectFill
    blurredImageView.clipsToBounds = true
    addSubview(blurredImageView)

    dimView.backgroundColor = UIColor(white: 0.0, alpha: 0.22)
    addSubview(dimView)

    sparkleImageView.contentMode = .scaleToFill
    sparkleImageView.clipsToBounds = true
    sparkleImageView.layer.compositingFilter = "plusLighter"
    addSubview(sparkleImageView)

    flameView.contentMode = .center
    flameView.tintColor = .white
    flameView.image = UIImage(systemName: "flame.fill")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 46, weight: .medium))
    flameView.layer.shadowColor = UIColor.white.cgColor
    flameView.layer.shadowRadius = 10
    flameView.layer.shadowOpacity = 0.55
    flameView.layer.shadowOffset = .zero
    flameView.isHidden = true
    addSubview(flameView)

    tickProxy.owner = self
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit {
    displayLink?.invalidate()
  }

  func apply(image: UIImage?, showsFlame: Bool, circular: Bool) {
    self.showsFlame = showsFlame
    flameView.isHidden = !showsFlame
    layer.cornerCurve = circular ? .circular : .continuous
    layer.cornerRadius = circular ? floor(min(bounds.width, bounds.height) * 0.5) : 0
    updateBlurredImage(image)
    if showsFlame { startFlamePulse() } else { stopFlamePulse() }
  }

  func setActive(_ active: Bool) {
    guard isActive != active else {
      if active { ensureDisplayLink() }
      return
    }
    isActive = active
    if active {
      ensureDisplayLink()
    } else {
      displayLink?.invalidate()
      displayLink = nil
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    blurredImageView.frame = bounds
    dimView.frame = bounds
    sparkleImageView.frame = bounds
    let flameSide = min(72.0, min(bounds.width, bounds.height) * 0.42)
    flameView.frame = CGRect(
      x: floor((bounds.width - flameSide) * 0.5),
      y: floor((bounds.height - flameSide) * 0.5),
      width: flameSide,
      height: flameSide)
    if layer.cornerCurve == .circular {
      layer.cornerRadius = floor(min(bounds.width, bounds.height) * 0.5)
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    setActive(window != nil && !isHidden)
  }

  override var isHidden: Bool {
    didSet {
      if isHidden {
        setActive(false)
      } else if window != nil {
        setActive(true)
      }
    }
  }

  fileprivate func tick(_ link: CADisplayLink) {
    let scale = min(window?.screen.scale ?? UIScreen.main.scale, 2.0)
    let pixelW = max(1, Int(ceil(bounds.width * scale * 0.55)))
    let pixelH = max(1, Int(ceil(bounds.height * scale * 0.55)))
    let size = CGSize(width: min(pixelW, 384), height: min(pixelH, 384))
    guard size.width >= 8, size.height >= 8 else { return }
    lastSparkleSize = size
    renderer.render(size: size, time: Float(link.timestamp)) { [weak self] image in
      self?.sparkleImageView.image = image
    }
  }

  private func updateBlurredImage(_ image: UIImage?) {
    guard let image else {
      lastBlurSource = nil
      blurredImageView.image = nil
      return
    }
    let token = ObjectIdentifier(image)
    if token == lastBlurSource, blurredImageView.image != nil { return }
    lastBlurSource = token
    blurGeneration &+= 1
    let generation = blurGeneration
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let blurred = Self.blurredStill(from: image)
      DispatchQueue.main.async {
        guard let self, self.blurGeneration == generation else { return }
        self.blurredImageView.image = blurred
      }
    }
  }

  private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  private static func blurredStill(from image: UIImage) -> UIImage {
    guard let cg = image.cgImage else { return image }
    let ci = CIImage(cgImage: cg)
    let maxEdge = max(ci.extent.width, ci.extent.height)
    let scale = maxEdge > 240 ? 240 / maxEdge : 1
    let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let blur = CIFilter(name: "CIGaussianBlur")
    blur?.setValue(scaled, forKey: kCIInputImageKey)
    blur?.setValue(14.0, forKey: kCIInputRadiusKey)
    let controls = CIFilter(name: "CIColorControls")
    controls?.setValue(blur?.outputImage?.cropped(to: scaled.extent), forKey: kCIInputImageKey)
    controls?.setValue(0.55, forKey: kCIInputSaturationKey)
    controls?.setValue(-0.08, forKey: kCIInputBrightnessKey)
    controls?.setValue(0.92, forKey: kCIInputContrastKey)
    guard let output = controls?.outputImage?.cropped(to: scaled.extent),
      let outCG = ciContext.createCGImage(output, from: scaled.extent)
    else { return image }
    return UIImage(cgImage: outCG, scale: image.scale, orientation: image.imageOrientation)
  }

  private func ensureDisplayLink() {
    guard displayLink == nil else { return }
    let link = CADisplayLink(target: tickProxy, selector: #selector(TickProxy.tick(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 12, maximum: 20, preferred: 15)
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func startFlamePulse() {
    guard flameView.layer.animation(forKey: "pulse") == nil else { return }
    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 0.94
    scale.toValue = 1.08
    scale.duration = 1.55
    scale.autoreverses = true
    scale.repeatCount = .infinity
    scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    flameView.layer.add(scale, forKey: "pulse")
    let glow = CABasicAnimation(keyPath: "opacity")
    glow.fromValue = 0.78
    glow.toValue = 1.0
    glow.duration = 1.55
    glow.autoreverses = true
    glow.repeatCount = .infinity
    flameView.layer.add(glow, forKey: "glow")
  }

  private func stopFlamePulse() {
    flameView.layer.removeAnimation(forKey: "pulse")
    flameView.layer.removeAnimation(forKey: "glow")
    flameView.layer.opacity = 1
    flameView.transform = .identity
  }

  private final class TickProxy: NSObject {
    weak var owner: ChatViewOnceShineCoverView?
    @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
  }
}

private final class SparkleRenderer {
  static let shared = SparkleRenderer()

  private let device: MTLDevice?
  private let queue: MTLCommandQueue?
  private var pipeline: MTLRenderPipelineState?
  private let quad: MTLBuffer?
  private var texture: MTLTexture?
  private var textureSize = MTLSize(width: 0, height: 0, depth: 1)
  private var bytes: UnsafeMutableRawPointer?
  private var bytesCapacity = 0
  private var fallbackImage: UIImage?
  private let start = CACurrentMediaTime()

  private init() {
    device = MTLCreateSystemDefaultDevice()
    queue = device?.makeCommandQueue()
    let verts: [SIMD2<Float>] = [
      SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(1, 1),
    ]
    quad = device?.makeBuffer(bytes: verts, length: MemoryLayout<SIMD2<Float>>.stride * 4)
    buildPipeline()
  }

  deinit {
    bytes?.deallocate()
  }

  func render(size: CGSize, time: Float, completion: @escaping (UIImage?) -> Void) {
    let w = max(8, Int(size.width.rounded()))
    let h = max(8, Int(size.height.rounded()))
    guard let device, let queue, let pipeline, let quad, let command = queue.makeCommandBuffer()
    else {
      DispatchQueue.main.async { completion(self.fallbackSparkles(size: size)) }
      return
    }
    if texture == nil || textureSize.width != w || textureSize.height != h {
      let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
      desc.usage = [.renderTarget, .shaderRead]
      desc.storageMode = .shared
      texture = device.makeTexture(descriptor: desc)
      textureSize = MTLSize(width: w, height: h, depth: 1)
    }
    guard let texture else {
      DispatchQueue.main.async { completion(self.fallbackSparkles(size: size)) }
      return
    }

    var uniforms = SparkleUniforms(
      time: time - Float(start),
      pad: 0,
      resolution: SIMD2(Float(w), Float(h)))
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(quad, offset: 0, index: 0)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SparkleUniforms>.stride, index: 1)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
    command.addCompletedHandler { [weak self] _ in
      guard let self else { return }
      let image = self.image(from: texture, width: w, height: h)
      DispatchQueue.main.async { completion(image) }
    }
    command.commit()
  }

  private func image(from texture: MTLTexture, width: Int, height: Int) -> UIImage? {
    let row = width * 4
    let length = row * height
    if bytesCapacity < length {
      bytes?.deallocate()
      bytes = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
      bytesCapacity = length
    }
    guard let bytes else { return nil }
    texture.getBytes(
      bytes, bytesPerRow: row,
      from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let data = Data(bytes: bytes, count: length)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    guard
      let cg = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    return UIImage(cgImage: cg)
  }

  private func fallbackSparkles(size: CGSize) -> UIImage {
    if let fallbackImage { return fallbackImage }
    let side = max(size.width, size.height, 160)
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
      .image { ctx in
        let cg = ctx.cgContext
        cg.setFillColor(UIColor.white.cgColor)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<520 {
          seed = seed &* 6_364_136_223_846_793_005 &+ 1
          let n = Double(seed >> 33) / Double(1 << 31)
          let x = CGFloat(seed % 10_007) / 10_007 * side
          let y = CGFloat((seed / 10_007) % 10_007) / 10_007 * side
          let r: CGFloat = n > 0.93 ? 1.6 : (n > 0.7 ? 0.9 : 0.45)
          cg.setAlpha(CGFloat(0.25 + n * 0.75))
          cg.fillEllipse(in: CGRect(x: x, y: y, width: r * 2, height: r * 2))
        }
      }
    fallbackImage = image
    return image
  }

  private func buildPipeline() {
    guard let device else { return }
    let source = """
      #include <metal_stdlib>
      using namespace metal;

      struct Uniforms {
        float time;
        float pad;
        float2 resolution;
      };

      struct VertexOut {
        float4 position [[position]];
        float2 uv;
      };

      vertex VertexOut vertex_main(uint vid [[vertex_id]], constant float2 *quad [[buffer(0)]]) {
        float2 p = quad[vid];
        VertexOut out;
        out.position = float4(p, 0.0, 1.0);
        out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
        return out;
      }

      float hash21(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
      }

      float sparkleAt(float2 uv, float t, float density, float seed) {
        float2 p = uv * density;
        float2 id = floor(p);
        float2 gv = fract(p) - 0.5;
        float n = hash21(id + seed);
        float tw = smoothstep(0.42, 1.0, 0.5 + 0.5 * sin(t * (1.6 + n * 6.5) + n * 38.0));
        float2 a = abs(gv);
        float cross = max(0.0, 1.0 - (a.x * 22.0 + a.y * 2.4));
        float cross2 = max(0.0, 1.0 - (a.y * 22.0 + a.x * 2.4));
        float core = pow(max(0.0, 1.0 - length(gv) * 8.0), 5.0);
        float glint = n > 0.955 ? pow(max(0.0, 1.0 - length(gv) * 2.1), 3.0) * 1.6 : 0.0;
        float keep = step(0.22, n);
        return (core * 1.15 + 0.7 * max(cross, cross2) + glint) * tw * keep;
      }

      fragment float4 fragment_main(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        float t = u.time;
        float aspect = u.resolution.x / max(u.resolution.y, 1.0);
        float2 uv = in.uv;
        uv.x *= aspect;
        float s = 0.0;
        s += sparkleAt(uv, t, 38.0, 0.7) * 0.95;
        s += sparkleAt(uv + float2(0.13, 0.07), t * 1.17, 26.0, 19.0) * 0.72;
        s += sparkleAt(uv * float2(1.15, 1.0), t * 0.83, 54.0, 41.0) * 0.55;
        s += sparkleAt(uv.yx, t * 0.61, 18.0, 7.0) * 0.35;
        float3 color = float3(s);
        color += float3(0.10, 0.07, 0.04) * s;
        return float4(color, saturate(s));
      }
      """
    do {
      let library = try device.makeLibrary(source: source, options: nil)
      let desc = MTLRenderPipelineDescriptor()
      desc.vertexFunction = library.makeFunction(name: "vertex_main")
      desc.fragmentFunction = library.makeFunction(name: "fragment_main")
      desc.colorAttachments[0].pixelFormat = .bgra8Unorm
      desc.colorAttachments[0].isBlendingEnabled = false
      pipeline = try device.makeRenderPipelineState(descriptor: desc)
    } catch {
      NSLog("[ViewOnceShine] pipeline failed: %@", String(describing: error))
    }
  }
}

private struct SparkleUniforms {
  var time: Float
  var pad: Float
  var resolution: SIMD2<Float>
}
