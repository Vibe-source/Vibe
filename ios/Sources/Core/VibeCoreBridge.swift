import Foundation

/// Swift-side owner of the Rust timeline core.
///
/// **P2 status: linked but dark.** Nothing in the app reads from this. The chat
/// list, the engine, and every render path are untouched and remain the sole
/// source of truth. This type exists so the link, the threading model, and the
/// callback boundary can be exercised on a real device before any UI depends on
/// them — which is the entire point of a "linked but dark" stage.
///
/// Rollback is deleting the `framework:` line in `ios/project.yml` and
/// regenerating. There is no data migration to undo, because nothing writes.
///
/// # Threading
///
/// The core owns a worker thread and there is **no synchronous read API** — by
/// construction, not by convention. Calls here return immediately; results
/// arrive on ``VibeCoreDeltaSink`` from the Rust worker thread. Anything that
/// touches UIKit as a result must hop to the main queue itself, which is why the
/// sink re-dispatches rather than assuming a thread.
///
/// This is the structural fix for the `[ChatEngine][MAIN-THREAD-HANG]` class of
/// bug: there is nothing for a UI getter to block on.
enum VibeCoreBridge {

  /// Debug switch. Default **off**, and deliberately not a `UserDefaults` read
  /// at call sites scattered around the app — one gate, one place.
  ///
  /// Even when on, this only constructs the core and logs. It changes no
  /// rendering. Turning it on cannot alter what the user sees.
  static var isEnabled: Bool {
    #if DEBUG
      return UserDefaults.standard.bool(forKey: "vibeCoreBridgeEnabled")
    #else
      return false
    #endif
  }

  /// Flips the switch from the diagnostics screen.
  ///
  /// A gate that can only be set by attaching a debugger or editing a plist is a
  /// gate nobody flips, which makes the self-test behind it dead code. Turning it
  /// off tears the worker down rather than leaving an orphan thread running with
  /// nothing able to reach it.
  ///
  /// Release builds ignore this: ``isEnabled`` is compiled to `false` there, so
  /// persisting `true` would only produce a switch that lies.
  static func setEnabled(_ enabled: Bool) {
    #if DEBUG
      UserDefaults.standard.set(enabled, forKey: "vibeCoreBridgeEnabled")
      VibeLog.notice("[VibeCore] bridge \(enabled ? "enabled" : "disabled")", category: "core")
      if !enabled { shutdown() }
    #endif
  }

  private static let queue = DispatchQueue(label: "com.vibegram.core.bridge")
  private static var handle: VibeCoreHandle?

  /// Constructs the core if it is not already up. Idempotent.
  ///
  /// Returns `nil` when the switch is off, so callers cannot accidentally spin
  /// up a worker thread in a production build.
  @discardableResult
  static func startIfEnabled(ownUserId: String) -> VibeCoreHandle? {
    guard isEnabled else { return nil }
    return queue.sync {
      if let handle { return handle }
      let config = VibeFfiConfig(
        ownUserId: ownUserId,
        // One display frame at 120 Hz. Stream sources coalesce up to this
        // barrier; everything else is an immediate barrier.
        flushFrameIntervalMs: 8
      )
      let created = VibeCoreHandle(config: config, sink: VibeCoreDeltaSink())
      handle = created
      VibeLog.info("[VibeCore] started worker ownUserId=\(ownUserId.isEmpty ? "<empty>" : "set")")
      return created
    }
  }

  /// Flushes and quiesces. Call from `didEnterBackground`.
  ///
  /// Deliberately **not** `willResignActive`: Control Centre and Notification
  /// Centre both fire that, and the engine already learned the hard way that
  /// treating it as backgrounding kills a live socket. The core follows the same
  /// signal the engine does.
  static func suspend() {
    queue.sync {
      guard let handle else { return }
      try? handle.suspend()
    }
  }

  /// Tears the worker down. Safe to call more than once.
  static func shutdown() {
    queue.sync {
      handle?.shutdown()
      handle = nil
    }
  }

  /// Drives one round trip through the FFI and reports what came back.
  ///
  /// This is the P2 acceptance check, and it is user-triggered from the
  /// diagnostics screen rather than run at launch: a "linked but dark" stage
  /// must not add work to the launch path it is not yet paying for.
  ///
  /// It proves, on the real device, that the static library linked, the worker
  /// thread spawned, a frame crossed into Rust, a delta came back across the
  /// callback boundary, and shutdown joined cleanly.
  static func runSelfTest(completion: @escaping (String) -> Void) {
    guard isEnabled else {
      completion("VibeCore bridge is OFF (set vibeCoreBridgeEnabled to test)")
      return
    }
    queue.async {
      let probe = VibeCoreProbeSink()
      let config = VibeFfiConfig(ownUserId: "self-test", flushFrameIntervalMs: 0)
      let probeHandle = VibeCoreHandle(config: config, sink: probe)

      let chatId = "self-test-chat"
      let frame = """
        {"id":"m1","chat_id":"\(chatId)","sender_id":"peer",\
        "timestamp":1000,"content":"hello from rust","type":"text"}
        """
      do {
        try probeHandle.ingestFrame(
          chatId: chatId,
          json: Data(frame.utf8),
          source: .chatTopic,
          receivedAtMs: 1000
        )
        try probeHandle.flush(nowMs: 2000)
      } catch {
        completion("FAIL submit: \(error)")
        probeHandle.shutdown()
        return
      }

      // The worker is asynchronous by design, so this waits rather than reads.
      let arrived = probe.waitForDelta(timeout: 3.0)
      let count = probe.deltaCount
      probeHandle.shutdown()

      let timeline =
        arrived
        ? "PASS — core v\(VibeCoreBridge.coreVersion), \(count) delta(s), worker joined"
        : "FAIL — no delta within 3s"
      let verdict = "\(timeline)\n\(VibeCoreBridge.sealSelfTestVerdict())"
      VibeLog.info("[VibeCore] self-test \(verdict)")
      completion(verdict)
    }
  }

  static var coreVersion: String { "0.1.0" }

  /// Builds a sealer over the per-install Keychain store key.
  ///
  /// Returns `nil` when the Keychain refuses to hold a key. A device that cannot
  /// custody a key must keep using the legacy plaintext path — sealing under
  /// anything predictable would be worse than not sealing, because the column is
  /// named `sealed_body` and every reader downstream would trust it.
  ///
  /// `ChatMessageStore` calls this once at open and seals every message body it
  /// writes. A `nil` here is the documented plaintext fallback, not a silent one:
  /// the store logs it and `ChatMessageStore.sealSummary` reports it.
  static func makeSealer() -> VibeStoreSealerHandle? {
    guard let key = VibeCoreStoreKey.loadOrCreate() else {
      VibeLog.error("[VibeCore] no store key available — sealing unavailable")
      return nil
    }
    do {
      return try VibeStoreSealerHandle(storeKey: key)
    } catch {
      VibeLog.error("[VibeCore] sealer construction failed: \(error)")
      return nil
    }
  }

  /// Seals and reopens one row, and proves a relocated row is refused.
  ///
  /// The relocation check is the part worth running on a real device: it is the
  /// difference between "the bytes are encrypted" and "the bytes are bound to
  /// the row they belong to", and it is the property that stops a tampered or
  /// mis-restored database from rendering one chat's message inside another.
  static func sealSelfTestVerdict() -> String {
    guard let sealer = makeSealer() else { return "seal: NO KEY" }
    let probe = Data("store seal probe".utf8)
    do {
      let sealed = try sealer.seal(
        userId: "u-selftest", chatId: "c-selftest", messageId: "m-selftest", plaintext: probe)
      let opened = try sealer.open(
        userId: "u-selftest", chatId: "c-selftest", messageId: "m-selftest",
        sealedBody: sealed.sealedBody, sealNonce: sealed.sealNonce)
      guard opened == probe else { return "seal: ROUND-TRIP MISMATCH" }

      // Same bytes, different address. This must fail.
      let relocated = try? sealer.open(
        userId: "u-selftest", chatId: "c-selftest", messageId: "m-OTHER",
        sealedBody: sealed.sealedBody, sealNonce: sealed.sealNonce)
      guard relocated == nil else { return "seal: RELOCATION NOT REFUSED" }

      return "seal: PASS (round-trip + relocation refused)"
    } catch {
      return "seal: FAIL \(error)"
    }
  }
}

/// Receives deltas from the Rust worker thread.
///
/// Every callback arrives on the core's worker thread, never the main thread.
/// While the bridge is dark this only counts and logs; when P4 lands, this is
/// where a delta is handed to the render host — and it must hop to main there,
/// not here, so the worker is never blocked by UIKit.
private final class VibeCoreDeltaSink: VibeDeltaSink {
  func onDelta(delta: VibeFfiDelta) {
    let opCount: Int
    switch delta.body {
    case .ops(let ops): opCount = ops.count
    case .reset(let window): opCount = window.messages.count
    }
    VibeLog.debug(
      "[VibeCore] delta chat=\(delta.chatId) gen=\(delta.baseGeneration)->\(delta.generation) ops=\(opCount)"
    )
  }

  func onWindow(window: VibeFfiWindow) {
    VibeLog.debug(
      "[VibeCore] window chat=\(window.chatId) rows=\(window.messages.count) total=\(window.bounds.totalKnown)"
    )
  }

  func onError(message: String) {
    // Never fatal on its own. A non-zero rate here is the signal to keep the
    // rollout flag off for that chat class.
    VibeLog.error("[VibeCore] error \(message)")
  }
}

/// Sink used only by ``VibeCoreBridge/runSelfTest(completion:)``.
private final class VibeCoreProbeSink: VibeDeltaSink {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var count = 0

  var deltaCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func waitForDelta(timeout: TimeInterval) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
  }

  func onDelta(delta: VibeFfiDelta) {
    lock.lock()
    count += 1
    lock.unlock()
    semaphore.signal()
  }

  func onWindow(window: VibeFfiWindow) {}
  func onError(message: String) {
    VibeLog.error("[VibeCore] self-test error \(message)")
  }
}
