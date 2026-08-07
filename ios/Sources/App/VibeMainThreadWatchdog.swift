import Foundation
import UIKit

/// Reports, from outside the main thread, every stretch where the main thread stopped
/// answering — how long, and what run-loop mode it was in when it happened.
///
/// # Why this exists
///
/// Everything that measures main-thread cost in this app measures *itself*:
/// `setRows took 196ms`, `MAIN-THREAD-SYNC-STALL blocked … 109ms`, `ScrollHitch 10ms`.
/// Each one is a stopwatch inside a function that already suspected it was slow. A
/// freeze that happens anywhere else — in a path nobody instrumented, or in UIKit, or
/// spread across a dozen small pieces that are individually under every threshold —
/// produces no line at all. Device session 2026-08-04: the list felt like it hung on
/// open, and the entire log for that window contained one `ScrollHitch 10ms`. The
/// instrumentation said the app was fine while the user was looking at a frozen screen.
///
/// This cannot happen here, because this observer is not inside the work. A background
/// thread watches the main run loop and notices that it stopped advancing. It does not
/// need to know which function is slow, or to have been added to it.
///
/// # How the detection works
///
/// A `CFRunLoopObserver` on the main run loop fires on every activity transition. Two
/// of those activities — `beforeSources` and `afterWaiting` — mean "about to run, or
/// now running, application code". If the run loop sits in one of them for longer than
/// the threshold, the main thread is busy and not servicing anything else: no touches,
/// no frames. That is exactly what a user calls a hang, and it is the same signal a
/// system watchdog uses before it kills an app.
///
/// The observer costs one lock and two stores per run-loop iteration, which is why it
/// can be left on rather than being something to remember to enable.
///
/// # What it prints
///
/// A hang in progress reports *while it is still happening*, once a second. That is
/// deliberate: a hang long enough to be killed produces no "recovered" line, so a
/// design that only logged on recovery would go silent in precisely the worst case.
///
///     [MainHang] STILL BLOCKED 1.0s mode=UITrackingRunLoopMode — main thread has not
///                advanced; no touches or frames are being serviced
///     [MainHang] RECOVERED after 1.34s mode=UITrackingRunLoopMode
///
/// `mode` is the part that assigns blame without any further work: `UITracking…` means
/// it happened under the user's finger mid-scroll, `kCFRunLoopDefaultMode` means it did
/// not. Correlate the recovery timestamp with the surrounding logs to name the function.
final class VibeMainThreadWatchdog {

  static let shared = VibeMainThreadWatchdog()

  /// Below this, a busy main thread is ordinary work — a frame at 120Hz has 8ms, and
  /// a single heavy commit landing at 200ms is already reported by its own stopwatch.
  /// This is looking for the class of stall a person perceives as the app stopping,
  /// which starts around a third of a second.
  private let hangThreshold: CFTimeInterval = 0.35
  /// How often the watcher samples. Fine enough to time a hang usefully, coarse enough
  /// to be free.
  private let sampleInterval: CFTimeInterval = 0.05
  /// Repeat interval for the "still blocked" line during one continuous hang.
  private let ongoingReportInterval: CFTimeInterval = 1.0
  /// A gap between watcher ticks larger than this means the process was suspended.
  /// Generous relative to the 50ms interval: a `.utility` queue on a loaded device can
  /// legitimately be late by a wide margin, and the cost of being wrong in this
  /// direction is one discarded hang report, while being wrong the other way is a
  /// minute of pocket time logged as a freeze.
  private static let suspensionSampleGap: CFTimeInterval = 2.0

  private let queue = DispatchQueue(label: "vibe.mainthread.watchdog", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var observer: CFRunLoopObserver?

  // MARK: Shared state
  //
  // Written by the run-loop observer on main, read by the watcher off it. Guarded by
  // the cheapest lock available, because the write side runs on every single run-loop
  // iteration of the main thread and must not become the thing it is measuring.

  /// Heap-allocated rather than a stored `os_unfair_lock_s`. Taking `&someProperty` of
  /// a lock yields a pointer Swift is allowed to move, which silently breaks the
  /// mutual exclusion — a class of bug that would show up here as corrupted timings
  /// rather than a crash, in the one component whose whole job is to be trustworthy
  /// about timings.
  private let lock: UnsafeMutablePointer<os_unfair_lock> = {
    let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    pointer.initialize(to: os_unfair_lock())
    return pointer
  }()
  private var busySince: CFTimeInterval = 0
  private var busyMode: String = ""
  /// Longest hang seen, for a one-line summary when the app backgrounds.
  private var worstHang: CFTimeInterval = 0

  // MARK: Watcher state (watchdog queue only)

  private var reportedHangStart: CFTimeInterval = 0
  private var lastOngoingReport: CFTimeInterval = 0
  /// Captured when the hang is first detected, not at recovery: by the time the main
  /// thread comes back it has moved on, and the interesting breadcrumb is the one it
  /// was standing on when it stopped.
  private var reportedHangActivity = "?"
  private var reportedHangMode = "?"
  /// The main thread's own stack, sampled at the moment the hang was detected. This is
  /// the line that names the function; `reportedHangActivity` is only a breadcrumb and
  /// says `idle` for everything that is not a chat open.
  private var reportedHangStack: [String] = []
  /// When the watcher itself last ran. A main-thread hang does not stop this queue —
  /// that is the entire premise of watching from off the main thread — so a gap here
  /// means the *process* stopped, not the main thread. See `sample`.
  private var lastSampleAt: CFTimeInterval = 0

  /// The main thread's mach port, captured on `start()`. Suspending and reading a
  /// thread requires its port, and `pthread_mach_thread_np` must be asked on the thread
  /// itself — there is no "give me the main thread's port" call from elsewhere.
  private var mainThreadPort: mach_port_t = 0

  private init() {}

  /// Installs the observer and starts watching. Safe to call once, from the main thread.
  func start() {
    guard observer == nil else { return }

    // Must be read here, on main. `mach_thread_self()` would hand back a send right that
    // needs deallocating; the pthread form is a borrowed name with no ownership.
    mainThreadPort = pthread_mach_thread_np(pthread_self())

    let activities: CFRunLoopActivity = [.beforeSources, .afterWaiting, .beforeWaiting, .exit]
    let observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, activities.rawValue, true, 0
    ) { [weak self] _, activity in
      guard let self else { return }
      // `beforeSources` / `afterWaiting` = the main thread is about to run, or is
      // running, application code. Anything else means it went back to waiting, which
      // is the run loop being healthy.
      let isBusy = activity.contains(.beforeSources) || activity.contains(.afterWaiting)
      let now = CACurrentMediaTime()
      // The mode has to be read here, on the main thread, while the loop is in it —
      // it is what separates "froze while you were dragging" from "froze on its own".
      let mode =
        isBusy
        ? ((CFRunLoopCopyCurrentMode(CFRunLoopGetMain())?.rawValue as String?) ?? "?") : ""
      os_unfair_lock_lock(self.lock)
      if isBusy {
        // Only stamp the START of a busy stretch. Overwriting it each iteration would
        // restart the clock constantly and no hang would ever be long enough to see.
        if self.busySince == 0 {
          self.busySince = now
          self.busyMode = mode
        }
      } else {
        self.busySince = 0
        self.busyMode = ""
      }
      os_unfair_lock_unlock(self.lock)
    }
    guard let observer else { return }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    self.observer = observer

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + sampleInterval, repeating: sampleInterval)
    timer.setEventHandler { [weak self] in self?.sample() }
    timer.resume()
    self.timer = timer

    NSLog(
      "[MainHang] watchdog armed — reporting main-thread blocks over %.0fms",
      hangThreshold * 1000)
  }

  /// One-line summary of the worst hang seen so far. Called when the app leaves the
  /// foreground, so a session that felt bad leaves a number behind even if nobody was
  /// reading the stream at the time.
  func reportSessionSummary(reason: String) {
    os_unfair_lock_lock(lock)
    let worst = worstHang
    os_unfair_lock_unlock(lock)
    guard worst > 0 else { return }
    NSLog("[MainHang] session summary (%@) — worst main-thread block %.2fs", reason, worst)
  }

  // MARK: Watching

  private func sample() {
    let sampledAt = CACurrentMediaTime()
    let sinceLastSample = lastSampleAt > 0 ? sampledAt - lastSampleAt : 0
    lastSampleAt = sampledAt
    // The process was frozen, not the main thread. When iOS suspends an app it stops
    // every thread, including this one; on resume the run loop's `busySince` stamp is
    // still whatever it was before the freeze, and subtracting it from now measures how
    // long the app was in the reader's pocket. The first device export reported
    // `main thread blocked 61.54s` on exactly this — a minute in which nothing was
    // wrong, filed at the same severity as a real half-second stall.
    //
    // The tell is that this watcher missed its own 50ms tick: a genuine main-thread hang
    // never delays it, because it is not on the main thread. Discard the stale stamp and
    // start the next window clean rather than reporting a hang that did not happen.
    if sinceLastSample > Self.suspensionSampleGap {
      os_unfair_lock_lock(lock)
      busySince = 0
      busyMode = ""
      os_unfair_lock_unlock(lock)
      reportedHangStart = 0
      lastOngoingReport = 0
      return
    }

    os_unfair_lock_lock(lock)
    let since = busySince
    let mode = busyMode
    os_unfair_lock_unlock(lock)

    guard since > 0 else {
      // Main is idle. If it was hanging, this is the recovery.
      if reportedHangStart > 0 {
        let duration = CACurrentMediaTime() - reportedHangStart
        NSLog("[MainHang] RECOVERED after %.2fs", duration)
        // Durable copy. `NSLog` exists only while a console is attached, and a hang
        // that a user notices is by definition one that happened while they were just
        // using the app. This is the version that is still there afterwards.
        VibeLog.warning(
          "main thread blocked \(String(format: "%.2f", duration))s during \(reportedHangActivity)",
          category: "mainhang",
          metadata: [
            "seconds": String(format: "%.2f", duration),
            "mode": reportedHangMode,
            "during": reportedHangActivity,
            // Trimmed to the app's own frames: a diagnostics export is a ring buffer,
            // and 40 lines of UIKit trampolines per hang would push out the rest of the
            // session. The full trace is in `NSLog` for anyone with a console attached.
            "stack": Self.compactStack(reportedHangStack),
          ])
        VibeOpenTrace.shared.noteHang(
          seconds: duration, mode: reportedHangMode, activity: reportedHangActivity)
        reportedHangStart = 0
        lastOngoingReport = 0
        reportedHangStack = []
      }
      return
    }

    let now = CACurrentMediaTime()
    let blockedFor = now - since
    guard blockedFor >= hangThreshold else { return }

    os_unfair_lock_lock(lock)
    if blockedFor > worstHang { worstHang = blockedFor }
    os_unfair_lock_unlock(lock)

    if reportedHangStart != since {
      // A new hang. Announce it as soon as it crosses the threshold rather than
      // waiting to see how long it runs — a hang that ends in a kill never gets to
      // report its own length.
      reportedHangStart = since
      lastOngoingReport = now
      // The run-loop mode says *when* ("under the finger" vs "not"), never *what*.
      // `VibeOpenTrace` keeps the main thread's last recorded stage, which is as close
      // to a stack as this can get without suspending the thread to walk it.
      reportedHangMode = mode.isEmpty ? "?" : mode
      reportedHangActivity = VibeOpenTrace.shared.activity
      // The stack is the whole point. `activity` reports `idle` for every stall that is
      // not a chat open, which is most of them, and a run-loop mode cannot distinguish
      // a wallpaper rasterize from a synchronous SQLite read. Sampled while the thread
      // is stopped, so it is the real frame list and not a guess.
      reportedHangStack = captureMainThreadStack()
      NSLog(
        "[MainHang] BLOCKED %.2fs mode=%@ during=%@ — main thread is not advancing; no touches or frames are being serviced",
        blockedFor, reportedHangMode, reportedHangActivity)
      for line in reportedHangStack { NSLog("[MainHang]   %@", line) }
      return
    }

    if now - lastOngoingReport >= ongoingReportInterval {
      lastOngoingReport = now
      // Re-sample. One stack says where it started; a second one a second later says
      // whether it is stuck in one call or grinding through a loop of them, which are
      // different bugs with different fixes.
      let ongoing = captureMainThreadStack()
      NSLog(
        "[MainHang] STILL BLOCKED %.2fs mode=%@ during=%@", blockedFor,
        mode.isEmpty ? "?" : mode, reportedHangActivity)
      for line in ongoing { NSLog("[MainHang]   %@", line) }
      // A hang long enough to repeat is one the reader definitely felt, and it may end
      // in a kill that never reaches the recovery path. Put this one in the durable log
      // where a diagnostics export will still find it.
      VibeLog.warning(
        "main thread STILL blocked \(String(format: "%.2f", blockedFor))s during \(reportedHangActivity)",
        category: "mainhang",
        metadata: [
          "seconds": String(format: "%.2f", blockedFor),
          "mode": mode.isEmpty ? "?" : mode,
          "during": reportedHangActivity,
          "stack": Self.compactStack(ongoing),
        ])
    }
  }

  // MARK: Sampling the main thread's stack
  //
  // Everything above can say a hang happened, how long it lasted and which run-loop mode
  // it was in. None of it can say *what ran*. `VibeOpenTrace.activity` was the stand-in,
  // and it answers `idle` for anything that is not a chat open — so a device export
  // showing four 0.4-1.0s blocks on the home screen attributed all four to "idle" and
  // named nothing. This closes that: stop the main thread, read its registers, walk its
  // frame pointers, resume, and symbolicate afterwards.
  //
  // The ordering is not incidental. While the main thread is suspended it may be holding
  // the malloc lock or the dyld lock, so nothing between `thread_suspend` and
  // `thread_resume` is allowed to allocate or to call `dladdr` — that is a self-inflicted
  // deadlock in the one component that exists to diagnose freezes. Only register reads
  // and `vm_read_overwrite` happen inside the window; symbolication happens after.
  //
  // Frames are read with `vm_read_overwrite` rather than dereferenced. A corrupt or
  // mid-prologue frame pointer is normal — the leaf frame is often half-built — and a
  // raw load on a bad address crashes the app. `vm_read_overwrite` returns a failure
  // code instead, which ends the walk with a short stack rather than a crash report.

  /// Max frames to walk. Deep enough to cross UIKit and reach app code, bounded so a
  /// cyclic frame chain cannot spin.
  private static let maxStackDepth = 48

  private func captureMainThreadStack() -> [String] {
    #if arch(arm64)
      let thread = mainThreadPort
      guard thread != MACH_PORT_NULL else { return ["<no main-thread port>"] }

      var addresses: [UInt64] = []

      guard thread_suspend(thread) == KERN_SUCCESS else {
        return ["<thread_suspend failed>"]
      }

      var state = arm_thread_state64_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
      let readState = withUnsafeMutablePointer(to: &state) { statePointer in
        statePointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
          thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), rebound, &count)
        }
      }

      if readState == KERN_SUCCESS {
        addresses.append(Self.stripPointerAuth(state.__pc))
        // Frame records are { saved FP, saved LR } at [fp], [fp+8].
        var frame = state.__fp
        var previousFrame: UInt64 = 0
        var slot = (next: UInt64(0), returnAddress: UInt64(0))
        while addresses.count < Self.maxStackDepth {
          let framePointer = Self.stripPointerAuth(frame)
          // Stacks grow down, so each caller's record sits at a HIGHER address than the
          // callee's. A next-frame that is not strictly above the current one is either
          // garbage or a cycle; either way the walk is over.
          guard framePointer != 0, framePointer % 8 == 0, framePointer > previousFrame else {
            break
          }
          guard Self.readMemory(at: framePointer, into: &slot) else { break }
          let returnAddress = Self.stripPointerAuth(slot.returnAddress)
          guard returnAddress != 0 else { break }
          addresses.append(returnAddress)
          previousFrame = framePointer
          frame = slot.next
        }
      }

      thread_resume(thread)

      guard readState == KERN_SUCCESS else { return ["<thread_get_state failed>"] }
      return Self.symbolicate(addresses)
    #else
      return ["<stack sampling requires arm64>"]
    #endif
  }

  /// arm64e signs return addresses and frame pointers. The app itself builds arm64, but
  /// a frame that passed through a system library can still carry signature bits in the
  /// high half. Masking to the 47-bit user-space range is what makes those addresses
  /// resolvable; it is a no-op for unsigned ones.
  private static func stripPointerAuth(_ value: UInt64) -> UInt64 {
    value & 0x0000_7FFF_FFFF_FFFF
  }

  /// Reads one frame record out of the suspended thread's stack. Returns false rather
  /// than trapping when the address is not mapped.
  private static func readMemory(
    at address: UInt64, into slot: inout (next: UInt64, returnAddress: UInt64)
  ) -> Bool {
    var readSize: vm_size_t = 0
    let wanted = vm_size_t(MemoryLayout<UInt64>.size * 2)
    let result = withUnsafeMutablePointer(to: &slot) { destination -> kern_return_t in
      vm_read_overwrite(
        mach_task_self_,
        vm_address_t(address),
        wanted,
        vm_address_t(UInt(bitPattern: destination)),
        &readSize)
    }
    return result == KERN_SUCCESS && readSize == wanted
  }

  private static func symbolicate(_ addresses: [UInt64]) -> [String] {
    addresses.enumerated().map { index, address in
      var info = Dl_info()
      guard let pointer = UnsafeRawPointer(bitPattern: UInt(address)),
        dladdr(pointer, &info) != 0
      else {
        return String(format: "%2d  ??? 0x%016llx", index, address)
      }
      let image =
        info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "???"
      guard let nameCString = info.dli_sname else {
        return String(format: "%2d  %@ 0x%016llx", index, image, address)
      }
      let symbol = demangle(String(cString: nameCString))
      let offset = address &- UInt64(UInt(bitPattern: info.dli_saddr))
      return String(format: "%2d  %@ %@ + %llu", index, image, symbol, offset)
    }
  }

  /// `swift_demangle` lives in the Swift runtime the app is already linked against, but
  /// it is not exposed to Swift source. Resolving it by name keeps the pretty names
  /// without a bridging header, and falls back to the mangled form if it ever moves.
  private typealias SwiftDemangleFunction = @convention(c) (
    UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
  ) -> UnsafeMutablePointer<CChar>?

  private static let swiftDemangle: SwiftDemangleFunction? = {
    // RTLD_DEFAULT — search every loaded image.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else {
      return nil
    }
    return unsafeBitCast(symbol, to: SwiftDemangleFunction.self)
  }()

  private static func demangle(_ name: String) -> String {
    guard name.hasPrefix("$s") || name.hasPrefix("_$s"), let demangler = swiftDemangle,
      let output = demangler(name, name.utf8.count, nil, nil, 0)
    else { return name }
    defer { free(output) }
    return String(cString: output)
  }

  /// The version that goes in the durable log: this app's own frames, innermost first,
  /// capped. Everything the reader needs to name the culprit, in one field.
  private static func compactStack(_ frames: [String]) -> String {
    guard !frames.isEmpty else { return "<none>" }
    let appFrames = frames.filter { $0.contains("Vibe") }
    let chosen = appFrames.isEmpty ? Array(frames.prefix(4)) : Array(appFrames.prefix(6))
    return
      chosen
      .map { line in
        // Drop the leading index and the image name — the frames are already in order
        // and they are all the same image once filtered.
        line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).last
          .map(String.init) ?? line
      }
      .joined(separator: " ← ")
  }
}
