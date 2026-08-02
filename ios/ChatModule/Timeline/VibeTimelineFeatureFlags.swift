import Foundation

// MARK: - Chat-class eligibility

/// Rollout classes are deliberately separate because their ordering, encryption,
/// and event sources have different risk. A regression in one class must not force
/// an all-or-nothing renderer rollout.
enum VibeTimelineChatClass: UInt8, Sendable, Equatable, CaseIterable {
  case directMessage = 0
  case group = 1
  case channel = 2
  case savedMessages = 3
  case agentDirect = 4
}

struct VibeTimelineChatClassEligibility: OptionSet, Sendable, Equatable {
  let rawValue: UInt32

  init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  static let directMessage = Self(rawValue: 1 << VibeTimelineChatClass.directMessage.rawValue)
  static let group = Self(rawValue: 1 << VibeTimelineChatClass.group.rawValue)
  static let channel = Self(rawValue: 1 << VibeTimelineChatClass.channel.rawValue)
  static let savedMessages = Self(rawValue: 1 << VibeTimelineChatClass.savedMessages.rawValue)
  static let agentDirect = Self(rawValue: 1 << VibeTimelineChatClass.agentDirect.rawValue)

  static let all: Self = [
    .directMessage,
    .group,
    .channel,
    .savedMessages,
    .agentDirect,
  ]

  func contains(_ chatClass: VibeTimelineChatClass) -> Bool {
    contains(Self(rawValue: 1 << chatClass.rawValue))
  }
}

// MARK: - Feature flags

/// Rollout gates for the async timeline stack.
///
/// **Default-off:** `vibeAsyncTimelineV1Enabled` is `false` unless explicitly set.
/// Debug builds must not flip this on implicitly — qualification requires an intentional
/// enable (UserDefaults key, remote config injection, or test override).
struct VibeTimelineFeatureFlags: Sendable, Equatable {
  /// Parallel `VibeMessageListHost` path. Default `false` until board gates pass.
  var vibeAsyncTimelineV1Enabled: Bool
  /// Dual-apply shadow comparison (ids/metrics only). Independent of async host.
  var vibeTimelineShadowCompareEnabled: Bool
  /// Explicit per-class rollout allowlist. Empty by default, including when the
  /// umbrella flag is accidentally enabled.
  var eligibleChatClasses: VibeTimelineChatClassEligibility
  /// Active window override; `nil` uses `VibeTimelineWindowPolicy.defaultActiveWindowCount`.
  var activeWindowOverride: Int?

  init(
    vibeAsyncTimelineV1Enabled: Bool = false,
    vibeTimelineShadowCompareEnabled: Bool = false,
    eligibleChatClasses: VibeTimelineChatClassEligibility = [],
    activeWindowOverride: Int? = nil
  ) {
    self.vibeAsyncTimelineV1Enabled = vibeAsyncTimelineV1Enabled
    self.vibeTimelineShadowCompareEnabled = vibeTimelineShadowCompareEnabled
    self.eligibleChatClasses = eligibleChatClasses
    self.activeWindowOverride = activeWindowOverride
  }

  /// Production defaults: async host off, shadow off, policy default window.
  static let `default` = VibeTimelineFeatureFlags()

  /// Resolved active window after policy clamp.
  var resolvedActiveWindowCount: Int {
    let proposed = activeWindowOverride ?? VibeTimelineWindowPolicy.defaultActiveWindowCount
    return VibeTimelineWindowPolicy.clampActiveWindow(proposed)
  }

  /// The new host is active only when both gates agree. This intentionally fails
  /// closed for unknown/missing remote-config values.
  func isAsyncTimelineEnabled(for chatClass: VibeTimelineChatClass) -> Bool {
    vibeAsyncTimelineV1Enabled && eligibleChatClasses.contains(chatClass)
  }
}

// MARK: - Injectable provider

/// Read-only flag source. Injected by app composition or tests — no process-global singleton.
protocol VibeTimelineFeatureFlagProviding {
  var flags: VibeTimelineFeatureFlags { get }
}

/// Fixed flags for tests and previews.
struct VibeTimelineFixedFeatureFlags: VibeTimelineFeatureFlagProviding {
  let flags: VibeTimelineFeatureFlags

  init(_ flags: VibeTimelineFeatureFlags = .default) {
    self.flags = flags
  }
}

/// UserDefaults-backed provider. Missing keys resolve to **false** / policy default.
///
/// Does not write defaults on read. Enabling the async path requires an explicit write
/// elsewhere (settings, remote config bridge, or test setup).
struct VibeTimelineUserDefaultsFeatureFlags: VibeTimelineFeatureFlagProviding {
  static let asyncTimelineKey = "vibeAsyncTimelineV1Enabled"
  static let shadowCompareKey = "vibeTimelineShadowCompareEnabled"
  static let activeWindowKey = "vibeTimelineActiveWindowCount"
  static let eligibleChatClassesKey = "vibeTimelineEligibleChatClassesMask"

  private let defaults: UserDefaults
  private let asyncKey: String
  private let shadowKey: String
  private let windowKey: String
  private let eligibilityKey: String

  init(
    defaults: UserDefaults = .standard,
    asyncKey: String = VibeTimelineUserDefaultsFeatureFlags.asyncTimelineKey,
    shadowKey: String = VibeTimelineUserDefaultsFeatureFlags.shadowCompareKey,
    windowKey: String = VibeTimelineUserDefaultsFeatureFlags.activeWindowKey,
    eligibilityKey: String = VibeTimelineUserDefaultsFeatureFlags.eligibleChatClassesKey
  ) {
    self.defaults = defaults
    self.asyncKey = asyncKey
    self.shadowKey = shadowKey
    self.windowKey = windowKey
    self.eligibilityKey = eligibilityKey
  }

  var flags: VibeTimelineFeatureFlags {
    // `bool(forKey:)` returns false when unset — correct default-off semantics.
    // Still use `object(forKey:)` so we never treat an accidental non-bool as true.
    let asyncEnabled = defaults.object(forKey: asyncKey) as? Bool ?? false
    let shadowEnabled = defaults.object(forKey: shadowKey) as? Bool ?? false
    let eligibilityRaw: UInt32
    if let value = defaults.object(forKey: eligibilityKey) as? Int {
      eligibilityRaw = value >= 0 && UInt64(value) <= UInt64(UInt32.max) ? UInt32(value) : 0
    } else {
      eligibilityRaw = 0
    }
    let windowOverride: Int?
    if let number = defaults.object(forKey: windowKey) as? Int {
      windowOverride = number
    } else if let number = defaults.object(forKey: windowKey) as? NSNumber {
      windowOverride = number.intValue
    } else {
      windowOverride = nil
    }
    return VibeTimelineFeatureFlags(
      vibeAsyncTimelineV1Enabled: asyncEnabled,
      vibeTimelineShadowCompareEnabled: shadowEnabled,
      eligibleChatClasses: VibeTimelineChatClassEligibility(rawValue: eligibilityRaw),
      activeWindowOverride: windowOverride
    )
  }
}

// MARK: - Mutable test store

/// Thread-safe-enough test double (mutate on the test thread only).
/// Not a global singleton — callers hold the instance.
final class VibeTimelineMutableFeatureFlags: @unchecked Sendable, VibeTimelineFeatureFlagProviding {
  private let lock = NSLock()
  private var storage: VibeTimelineFeatureFlags

  init(_ flags: VibeTimelineFeatureFlags = .default) {
    self.storage = flags
  }

  var flags: VibeTimelineFeatureFlags {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func update(_ body: (inout VibeTimelineFeatureFlags) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&storage)
  }

  func setAsyncTimelineEnabled(_ enabled: Bool) {
    update { $0.vibeAsyncTimelineV1Enabled = enabled }
  }
}
