import Foundation
import Security

/// Pins peer identities in the Keychain and derives comparison codes.
enum VibeSecureTrust {

  /// What a peer's freshly-claimed KeyPackage means for trust.
  enum Verdict: Equatable {
    /// First contact; the key is now pinned.
    case pinnedOnFirstContact
    /// Same key as last time. Nothing has changed.
    case matchesPin
    /// Key changed; callers fail closed until the user verifies it.
    case changed(pinned: Data, offered: Data)
  }

  private static let service = "vibe.secure.trust"
  private static let transportService = "vibe.secure.trust.transport"
  private static let pendingService = "vibe.secure.trust.pending"
  private static let pendingTransportService = "vibe.secure.trust.pending.transport"
  private static let queue = DispatchQueue(label: "vibe.secure.trust")


  /// Pins on first contact and stages changed keys for user verification.
  static func evaluate(signatureKey: Data, userId: String) -> Verdict {
    queue.sync {
      guard let pinned = loadKey(userId: userId) else {
        _ = storeKey(signatureKey, userId: userId)
        deleteKey(userId: userId, service: pendingService)
        return .pinnedOnFirstContact
      }
      if pinned == signatureKey {
        deleteKey(userId: userId, service: pendingService)
        return .matchesPin
      }
      _ = storeKey(signatureKey, userId: userId, service: pendingService)
      return .changed(pinned: pinned, offered: signatureKey)
    }
  }

  /// The key currently pinned for `userId`, if any.
  static func pinnedKey(userId: String) -> Data? {
    queue.sync { loadKey(userId: userId) }
  }

  /// Replaces the MLS pin only after explicit user verification.
  @discardableResult
  static func acceptChange(signatureKey: Data, userId: String) -> Bool {
    queue.sync { storeKey(signatureKey, userId: userId) }
  }

  // Legacy RSA transport pin for peers without MLS support.

  /// Compares the peer's hybrid RSA public key against its pin, pinning on first contact.
  static func evaluateTransport(publicKeyPem: String, userId: String) -> Verdict {
    let offered = transportKeyBytes(publicKeyPem)
    guard !offered.isEmpty else { return .matchesPin }
    return queue.sync {
      guard let pinned = loadKey(userId: userId, service: transportService) else {
        _ = storeKey(offered, userId: userId, service: transportService)
        deleteKey(userId: userId, service: pendingTransportService)
        return .pinnedOnFirstContact
      }
      if pinned == offered {
        deleteKey(userId: userId, service: pendingTransportService)
        return .matchesPin
      }
      _ = storeKey(offered, userId: userId, service: pendingTransportService)
      return .changed(pinned: pinned, offered: offered)
    }
  }

  /// The hybrid key currently pinned for `userId`, as DER.
  static func pinnedTransportKey(userId: String) -> Data? {
    queue.sync { loadKey(userId: userId, service: transportService) }
  }

  /// Replaces the hybrid pin. Human-accepted changes only, exactly like `acceptChange`.
  @discardableResult
  static func acceptTransportChange(publicKeyPem: String, userId: String) -> Bool {
    let offered = transportKeyBytes(publicKeyPem)
    guard !offered.isEmpty else { return false }
    return queue.sync { storeKey(offered, userId: userId, service: transportService) }
  }

  static func pendingChanges(userId: String) -> (signatureKey: Data?, transportKey: Data?) {
    queue.sync {
      (
        loadKey(userId: userId, service: pendingService),
        loadKey(userId: userId, service: pendingTransportService)
      )
    }
  }

  /// Promotes only the exact identity keys the user verified.
  @discardableResult
  static func acceptPendingChanges(
    userId: String,
    expectedSignatureKey: Data?,
    expectedTransportKey: Data?
  ) -> Bool {
    queue.sync {
      let signature = loadKey(userId: userId, service: pendingService)
      let transport = loadKey(userId: userId, service: pendingTransportService)
      guard expectedSignatureKey != nil || expectedTransportKey != nil else { return false }
      guard signature == expectedSignatureKey, transport == expectedTransportKey else { return false }

      var succeeded = true
      if let signature {
        let stored = storeKey(signature, userId: userId)
        if stored { deleteKey(userId: userId, service: pendingService) }
        succeeded = succeeded && stored
      }
      if let transport {
        let stored = storeKey(transport, userId: userId, service: transportService)
        if stored { deleteKey(userId: userId, service: pendingTransportService) }
        succeeded = succeeded && stored
      }
      return succeeded
    }
  }

  /// DER behind a PEM, so header and line-break drift is not read as a key change.
  private static func transportKeyBytes(_ pem: String) -> Data {
    let body = pem.split(whereSeparator: \.isNewline)
      .filter { !$0.hasPrefix("-----") }
      .joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let der = Data(base64Encoded: body), !der.isEmpty { return der }
    let raw = pem.trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? Data() : Data(raw.utf8)
  }

  /// Clears all pins only when this device retires its own identity.
  static func clearAllPins() {
    queue.sync {
      for pinService in [service, transportService, pendingService, pendingTransportService] {
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: pinService,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
          VibeLog.error("[VibeSecure] could not clear peer pins: OSStatus \(status)")
          return
        }
      }
      VibeLog.notice("[VibeSecure] cleared every peer identity pin — they re-pin on next contact")
    }
  }

  /// Returns the 60-digit comparison code in groups of five.
  static func safetyNumber(myKey: Data, peerKey: Data) -> String {
    let digits = vibeSafetyNumber(keyA: myKey, keyB: peerKey)
    return stride(from: 0, to: digits.count, by: 5)
      .map { offset -> String in
        let start = digits.index(digits.startIndex, offsetBy: offset)
        let end = digits.index(start, offsetBy: min(5, digits.count - offset))
        return String(digits[start..<end])
      }
      .joined(separator: " ")
  }


  private static func loadKey(userId: String, service: String = service) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: userId,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data, !data.isEmpty
    else { return nil }
    return data
  }

  private static func deleteKey(userId: String, service: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: userId,
    ]
    SecItemDelete(query as CFDictionary)
  }

  private static func storeKey(_ key: Data, userId: String, service: String = service) -> Bool {
    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: userId,
      kSecValueData as String: key,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    SecItemDelete(attributes as CFDictionary)
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }
}
