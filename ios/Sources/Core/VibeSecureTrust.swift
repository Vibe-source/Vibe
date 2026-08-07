import Foundation
import Security

/// Remembers which signing key each peer showed us, so the server cannot
/// quietly swap one in.
///
/// # The attack this exists for
///
/// Establishment asks the server for a peer's KeyPackage. MLS does not make the
/// server honest: it can mint its own KeyPackage, hand that over instead, join
/// the group as the "peer", and relay messages to the real one. Everything stays
/// encrypted the whole time — to the attacker. Nothing in the protocol notices.
///
/// Two things stop it, and this type is both:
///
/// * **Pinning** — remember the key seen on first contact and refuse if it ever
///   changes. This does not stop a server that lies from the very first
///   message, but it collapses the attack window from "any time, repeatedly" to
///   "first contact only, once".
/// * **Safety numbers** — a short string derived from both identity keys. Two
///   people who read it aloud and find it matching know there is nobody
///   between them, which is the only thing that closes first-contact
///   substitution.
///
/// # Why the Keychain
///
/// A pin is only as good as its storage. `UserDefaults` is a plist any process
/// with file access can rewrite; an attacker who can edit the pin can erase it
/// and re-pin their own key, and pinning becomes decoration. The Keychain is
/// `ThisDeviceOnly` for the same reason the MLS store is — a pin restored onto
/// a different device is a claim about a trust decision that device never made.
enum VibeSecureTrust {

  /// What a peer's freshly-claimed KeyPackage means for trust.
  enum Verdict: Equatable {
    /// Never seen this peer. The key is now pinned.
    ///
    /// Not "safe" — merely "not yet contradicted". A server lying from the
    /// first message lands here, which is exactly why the safety number
    /// exists and why the UI should offer to verify.
    case pinnedOnFirstContact
    /// Same key as last time. Nothing has changed.
    case matchesPin
    /// **Different key than the one pinned.** Either the peer reinstalled, or
    /// someone is in the middle. The two are indistinguishable from here, so
    /// the caller must fail closed and let a human decide.
    case changed(pinned: Data, offered: Data)
  }

  private static let service = "vibe.secure.trust"
  private static let queue = DispatchQueue(label: "vibe.secure.trust")

  /// Compares `signatureKey` against what we pinned for `userId`, pinning it if
  /// this is the first time.
  ///
  /// Deliberately returns a verdict rather than a `Bool`: `changed` is not
  /// "invalid", it is "a human has to look at this", and collapsing it to false
  /// would lose the distinction between a benign reinstall and an attack.
  static func evaluate(signatureKey: Data, userId: String) -> Verdict {
    queue.sync {
      guard let pinned = loadKey(userId: userId) else {
        _ = storeKey(signatureKey, userId: userId)
        return .pinnedOnFirstContact
      }
      if pinned == signatureKey { return .matchesPin }
      return .changed(pinned: pinned, offered: signatureKey)
    }
  }

  /// The key currently pinned for `userId`, if any.
  static func pinnedKey(userId: String) -> Data? {
    queue.sync { loadKey(userId: userId) }
  }

  /// Replaces the pin for `userId`.
  ///
  /// Only ever call this because a *human* accepted the change — after
  /// comparing a safety number, or explicitly choosing to trust a reinstall.
  /// Calling it automatically on `changed` would undo the entire mechanism:
  /// the point of a pin is that software cannot silently move it.
  @discardableResult
  static func acceptChange(signatureKey: Data, userId: String) -> Bool {
    queue.sync { storeKey(signatureKey, userId: userId) }
  }

  /// Forgets every pin this device holds.
  ///
  /// **Only for the one case where every pin is known-dead**: this device's own
  /// signing key was retired, which means it was minted per launch — and so were
  /// its peers'. Every stored pin then names a key its owner will never sign
  /// with again, `evaluate` returns `changed` for all of them, and `verifyPeer`
  /// fails closed, so no conversation can re-establish. See
  /// `VibeSecureSessions.retireStateForNewIdentityLocked`.
  ///
  /// This is the one operation that undoes what pinning is for, so it must never
  /// become a general-purpose "reset trust" convenience: an attacker who can
  /// provoke it gets a fresh first-contact window against every peer at once.
  /// Nothing calls it except identity retirement, and that runs at most once per
  /// key change.
  static func clearAllPins() {
    queue.sync {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
      ]
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        VibeLog.error("[VibeSecure] could not clear peer pins: OSStatus \(status)")
        return
      }
      VibeLog.notice("[VibeSecure] cleared every peer identity pin — they re-pin on next contact")
    }
  }

  /// The digits two people compare out of band, or `nil` if either side's key
  /// is unknown.
  ///
  /// Formatted in groups of five for reading aloud — losing your place in a
  /// 60-digit run is how comparisons get abandoned halfway, and an abandoned
  /// comparison protects nothing.
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

  // ── Keychain ────────────────────────────────────────────────────────────

  private static func loadKey(userId: String) -> Data? {
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

  private static func storeKey(_ key: Data, userId: String) -> Bool {
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
