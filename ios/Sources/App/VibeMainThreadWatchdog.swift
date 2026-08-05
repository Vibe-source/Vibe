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

  private init() {}

  /// Installs the observer and starts watching. Safe to call once, from the main thread.
  func start() {
    guard observer == nil else { return }

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
    os_unfair_lock_lock(lock)
    let since = busySince
    let mode = busyMode
    os_unfair_lock_unlock(lock)

    guard since > 0 else {
      // Main is idle. If it was hanging, this is the recovery.
      if reportedHangStart > 0 {
        let duration = CACurrentMediaTime() - reportedHangStart
        NSLog("[MainHang] RECOVERED after %.2fs", duration)
        reportedHangStart = 0
        lastOngoingReport = 0
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
      NSLog(
        "[MainHang] BLOCKED %.2fs mode=%@ — main thread is not advancing; no touches or frames are being serviced",
        blockedFor, mode.isEmpty ? "?" : mode)
      return
    }

    if now - lastOngoingReport >= ongoingReportInterval {
      lastOngoingReport = now
      NSLog(
        "[MainHang] STILL BLOCKED %.2fs mode=%@", blockedFor, mode.isEmpty ? "?" : mode)
    }
  }
}
