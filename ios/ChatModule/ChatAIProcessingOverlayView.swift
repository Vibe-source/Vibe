import MetalKit
import UIKit

/// Full-screen "the model is working" surface for AI media edits.
///
/// Instead of a spinner over a static sheet, this takes the frame the user is
/// looking at and keeps it on screen the whole time, under a Metal blur that
/// travels across it in a slow wave. The picture stays recognisable, so the wait
/// reads as *this clip is being worked on* rather than *something is loading*.
///
/// Same family as `MetalKeyMaskView` (the agent secret-key reveal): one inline
/// shader source, a single full-screen quad, animation driven entirely by a
/// `time` uniform so there is no CADisplayLink on the UI run loop.
final class ChatAIProcessingOverlayView: UIView {

  private let renderer = Renderer()
  private var metalView: MTKView?
  private let fallbackImageView = UIImageView()
  private let fallbackBlur = UIVisualEffectView(effect: nil)

  private let captionLabel = UILabel()
  private let detailLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let cancelButton = UIButton(type: .system)

  var onCancel: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    isUserInteractionEnabled = true

    if let device = renderer.device {
      let view = MTKView(frame: .zero, device: device)
      view.delegate = renderer
      view.colorPixelFormat = .bgra8Unorm
      view.framebufferOnly = false
      view.isOpaque = true
      view.enableSetNeedsDisplay = false
      view.isPaused = false
      view.preferredFramesPerSecond = 60
      view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
      addSubview(view)
      metalView = view
    } else {
      // No Metal device (simulator edge cases): the still frame under a UIKit
      // blur is a plain but honest stand-in.
      fallbackImageView.contentMode = .scaleAspectFill
      fallbackImageView.clipsToBounds = true
      addSubview(fallbackImageView)
      addSubview(fallbackBlur)
    }

    captionLabel.font = .systemFont(ofSize: 17.0, weight: .semibold)
    captionLabel.textColor = .white
    captionLabel.textAlignment = .center
    captionLabel.text = "Editing with AI"
    addSubview(captionLabel)

    detailLabel.font = .systemFont(ofSize: 13.0, weight: .medium)
    detailLabel.textColor = UIColor(white: 1.0, alpha: 0.6)
    detailLabel.textAlignment = .center
    detailLabel.numberOfLines = 2
    addSubview(detailLabel)

    spinner.color = .white
    spinner.hidesWhenStopped = true
    addSubview(spinner)

    cancelButton.setTitle("Cancel", for: .normal)
    cancelButton.titleLabel?.font = .systemFont(ofSize: 15.0, weight: .semibold)
    cancelButton.setTitleColor(.white, for: .normal)
    cancelButton.backgroundColor = UIColor(white: 1.0, alpha: 0.14)
    cancelButton.layer.cornerRadius = 18.0
    cancelButton.layer.cornerCurve = .continuous
    cancelButton.addTarget(self, action: #selector(handleCancel), for: .touchUpInside)
    addSubview(cancelButton)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: Presentation

  /// `frame` is the still the user was looking at; it becomes the thing being
  /// blurred. `detail` names the provider so the disclosure stays visible for
  /// the whole call, not only at the consent step.
  func present(in host: UIView, frame image: UIImage?, detail: String) {
    detailLabel.text = detail
    renderer.setImage(image)
    fallbackImageView.image = image

    self.frame = host.bounds
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.addSubview(self)
    host.bringSubviewToFront(self)
    setNeedsLayout()
    layoutIfNeeded()

    spinner.startAnimating()
    alpha = 0.0
    captionLabel.transform = CGAffineTransform(translationX: 0.0, y: 8.0)
    detailLabel.transform = captionLabel.transform

    renderer.setIntensity(0.0)
    UIView.animate(withDuration: 0.32, delay: 0.0, options: [.curveEaseOut]) {
      self.alpha = 1.0
      self.captionLabel.transform = .identity
      self.detailLabel.transform = .identity
    }
    renderer.rampIntensity(to: 1.0, duration: 0.7)

    if metalView == nil {
      UIView.animate(withDuration: 0.5) {
        self.fallbackBlur.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
      }
    }
  }

  func dismiss() {
    renderer.rampIntensity(to: 0.0, duration: 0.28)
    UIView.animate(
      withDuration: 0.3, delay: 0.05, options: [.curveEaseIn],
      animations: {
        self.alpha = 0.0
        if self.metalView == nil { self.fallbackBlur.effect = nil }
      },
      completion: { _ in
        self.spinner.stopAnimating()
        self.removeFromSuperview()
      })
  }

  func setCaption(_ text: String) {
    captionLabel.text = text
  }

  // MARK: Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    metalView?.frame = bounds
    fallbackImageView.frame = bounds
    fallbackBlur.frame = bounds
    renderer.setViewportAspect(
      viewSize: bounds.size, scale: window?.screen.scale ?? UIScreen.main.scale)

    let width = bounds.width - 64.0
    captionLabel.frame = CGRect(
      x: 32.0, y: bounds.midY - 40.0, width: width, height: 22.0)
    detailLabel.frame = CGRect(
      x: 32.0, y: captionLabel.frame.maxY + 6.0, width: width, height: 34.0)
    spinner.center = CGPoint(x: bounds.midX, y: captionLabel.frame.minY - 26.0)

    let cancelWidth: CGFloat = 110.0
    cancelButton.frame = CGRect(
      x: (bounds.width - cancelWidth) * 0.5,
      y: detailLabel.frame.maxY + 26.0,
      width: cancelWidth,
      height: 36.0)
  }

  @objc private func handleCancel() {
    onCancel?()
  }

  // MARK: - Renderer

  private final class Renderer: NSObject, MTKViewDelegate {

    let device: MTLDevice?

    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private let quadBuffer: MTLBuffer?
    private var texture: MTLTexture?
    private let sampler: MTLSamplerState?

    private let startTime = CACurrentMediaTime()
    private var textureSize = CGSize(width: 1.0, height: 1.0)
    private var viewSize = CGSize(width: 1.0, height: 1.0)
    private var uvScale = SIMD2<Float>(1.0, 1.0)

    private var intensity: Float = 0.0
    private var intensityStart: Float = 0.0
    private var intensityTarget: Float = 0.0
    private var intensityStartTime = CACurrentMediaTime()
    private var intensityDuration: CFTimeInterval = 0.0

    override init() {
      device = MTLCreateSystemDefaultDevice()
      commandQueue = device?.makeCommandQueue()

      let quad: [SIMD2<Float>] = [
        SIMD2(-1.0, -1.0), SIMD2(1.0, -1.0), SIMD2(-1.0, 1.0), SIMD2(1.0, 1.0),
      ]
      quadBuffer = device?.makeBuffer(
        bytes: quad, length: MemoryLayout<SIMD2<Float>>.stride * quad.count)

      let samplerDescriptor = MTLSamplerDescriptor()
      samplerDescriptor.minFilter = .linear
      samplerDescriptor.magFilter = .linear
      samplerDescriptor.sAddressMode = .clampToEdge
      samplerDescriptor.tAddressMode = .clampToEdge
      sampler = device?.makeSamplerState(descriptor: samplerDescriptor)

      super.init()
      setupPipeline()
    }

    private func setupPipeline() {
      guard let device else { return }

      let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float2 uvScale;
            float time;
            float intensity;
            float hasTexture;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertexOut vertex_main(
            uint vertexID [[vertex_id]],
            constant float2 *quad [[buffer(0)]],
            constant Uniforms &uniforms [[buffer(1)]]
        ) {
            float2 p = quad[vertexID];
            VertexOut out;
            out.position = float4(p, 0.0, 1.0);
            // Flip vertically: Metal's clip space is y-up, image data is y-down.
            out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
            return out;
        }

        fragment float4 fragment_main(
            VertexOut in [[stage_in]],
            texture2d<float> image [[texture(0)]],
            sampler samp [[sampler(0)]],
            constant Uniforms &uniforms [[buffer(1)]]
        ) {
            float t = uniforms.time;
            float k = uniforms.intensity;

            // Aspect-fill the still into the viewport, so a portrait clip does
            // not letterbox behind the blur.
            float2 uv = (in.uv - 0.5) * uniforms.uvScale + 0.5;

            // Two waves at different frequencies travelling in opposite
            // directions — one alone reads as a wobble, two read as motion.
            float waveA = sin(uv.y * 9.0 - t * 1.6);
            float waveB = cos(uv.x * 7.0 + t * 1.1);
            float amp = 0.016 * k;
            uv += float2(waveA, waveB) * amp;

            if (uniforms.hasTexture < 0.5) {
                float g = 0.05 + 0.03 * (waveA * 0.5 + 0.5);
                return float4(g, g, g, 1.0);
            }

            // Ring-tap blur. Radius rides the same wave so the softness itself
            // travels across the frame instead of sitting flat over it.
            float radius = (0.006 + 0.010 * (0.5 + 0.5 * waveA)) * k;
            float3 sum = image.sample(samp, uv).rgb;
            float weight = 1.0;

            for (int ring = 1; ring <= 3; ring++) {
                float r = radius * float(ring) / 3.0;
                float w = 1.0 / float(ring);
                for (int i = 0; i < 8; i++) {
                    float a = (float(i) / 8.0) * 6.2831853 + float(ring) * 0.7 + t * 0.25;
                    float2 offset = float2(cos(a), sin(a)) * r;
                    sum += image.sample(samp, uv + offset).rgb * w;
                    weight += w;
                }
            }
            float3 color = sum / weight;

            // Pull it down and desaturate slightly so white chrome stays legible.
            float luma = dot(color, float3(0.299, 0.587, 0.114));
            color = mix(color, float3(luma), 0.25 * k);
            color *= mix(1.0, 0.55, k);

            // Slow sheen sweeping down the frame, keyed to the same clock.
            float sheen = smoothstep(0.35, 0.0, abs(fract(t * 0.14) - in.uv.y));
            color += sheen * 0.05 * k;

            // Vignette keeps the eye at the centre copy.
            float d = distance(in.uv, float2(0.5, 0.5));
            color *= mix(1.0, 1.0 - smoothstep(0.35, 0.95, d) * 0.55, k);

            return float4(color, 1.0);
        }
        """

      do {
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
      } catch {
        NSLog("[ChatAIProcessingOverlay] pipeline build failed: %@", String(describing: error))
      }
    }

    func setImage(_ image: UIImage?) {
      guard let device, let cgImage = image?.cgImage else {
        texture = nil
        return
      }
      let loader = MTKTextureLoader(device: device)
      texture = try? loader.newTexture(
        cgImage: cgImage,
        options: [
          .SRGB: false,
          .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
          .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ])
      textureSize = CGSize(width: cgImage.width, height: cgImage.height)
      recomputeUVScale()
    }

    func setViewportAspect(viewSize: CGSize, scale: CGFloat) {
      self.viewSize = CGSize(
        width: max(1.0, viewSize.width * scale), height: max(1.0, viewSize.height * scale))
      recomputeUVScale()
    }

    /// Aspect-fill: shrink the sampled window on the axis that would otherwise
    /// show bars.
    private func recomputeUVScale() {
      let textureAspect = textureSize.width / max(1.0, textureSize.height)
      let viewAspect = viewSize.width / max(1.0, viewSize.height)
      if textureAspect > viewAspect {
        uvScale = SIMD2(Float(viewAspect / textureAspect), 1.0)
      } else {
        uvScale = SIMD2(1.0, Float(textureAspect / viewAspect))
      }
    }

    func setIntensity(_ value: Float) {
      intensity = value
      intensityTarget = value
      intensityDuration = 0.0
    }

    func rampIntensity(to target: Float, duration: CFTimeInterval) {
      let now = CACurrentMediaTime()
      intensity = resolvedIntensity(at: now)
      intensityStart = intensity
      intensityTarget = target
      intensityStartTime = now
      intensityDuration = duration
    }

    private func resolvedIntensity(at now: CFTimeInterval) -> Float {
      guard intensityDuration > 0.0 else { return intensity }
      let linear = Float(min(max((now - intensityStartTime) / intensityDuration, 0.0), 1.0))
      let eased = linear * linear * (3.0 - 2.0 * linear)
      intensity = intensityStart + (intensityTarget - intensityStart) * eased
      if linear >= 1.0 {
        intensity = intensityTarget
        intensityDuration = 0.0
      }
      return intensity
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
      viewSize = CGSize(width: max(1.0, size.width), height: max(1.0, size.height))
      recomputeUVScale()
    }

    func draw(in view: MTKView) {
      guard
        let drawable = view.currentDrawable,
        let descriptor = view.currentRenderPassDescriptor,
        let pipelineState,
        let commandQueue,
        let quadBuffer
      else { return }

      let now = CACurrentMediaTime()
      var uniforms = Uniforms(
        uvScale: uvScale,
        time: Float(now - startTime),
        intensity: resolvedIntensity(at: now),
        hasTexture: texture == nil ? 0.0 : 1.0
      )

      let commandBuffer = commandQueue.makeCommandBuffer()
      let encoder = commandBuffer?.makeRenderCommandEncoder(descriptor: descriptor)
      encoder?.setRenderPipelineState(pipelineState)
      encoder?.setVertexBuffer(quadBuffer, offset: 0, index: 0)
      encoder?.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
      encoder?.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
      encoder?.setFragmentTexture(texture, index: 0)
      encoder?.setFragmentSamplerState(sampler, index: 0)
      encoder?.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      encoder?.endEncoding()

      commandBuffer?.present(drawable)
      commandBuffer?.commit()
    }
  }

  private struct Uniforms {
    let uvScale: SIMD2<Float>
    let time: Float
    let intensity: Float
    let hasTexture: Float
  }
}
