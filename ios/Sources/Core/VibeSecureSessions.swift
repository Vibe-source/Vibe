import Foundation
import Security

/// MLS session custody for the chat engine: one device identity, one session per
/// chat, and the two entry points the send/receive path calls.
///
/// # State is persistent
///
/// Ratchet state lives in a SQLite store on disk (`VibeSecureProvider`), and
/// `chat id -> group id` is remembered so a relaunch reloads the *same* group
/// rather than minting a new one and orphaning everything sealed before the
/// restart. That reload happens lazily in `sessionLocked(chatId:)`, which is why
/// nothing else in this type reads the `sessions` dictionary directly.
///
/// # The send gate
///
/// A `vmls1.` envelope is unreadable to a client that has not shipped this code,
/// so sending was gated while an install base might exist. **Receiving is always
/// on** — it costs nothing when no `vmls1.` arrives, and read-before-write is
/// the state a staged rollout needs every device to pass through first.
///
/// # Establishment lives next door
///
/// Sessions are created and joined by `VibeSecureEstablishment`, which is the
/// only part of MLS that needs the network. This type stays purely local and
/// synchronous so that custody of the ratchet is auditable on its own.
///
/// # Callers must fail closed
///
/// `seal` returning `nil` means *this chat has no session*, and the only safe
/// response is to keep the message queued — never to fall through to the
/// plaintext branch. `ChatEngine` does that by reusing the queue-and-replay
/// path it already had for a missing friend key. A caller that treats `nil` as
/// "send it some other way" silently un-encrypts the conversation, which is the
/// one failure mode this whole layer exists to prevent.
///
/// Groups are not established yet, so `seal` still returns `nil` for them and
/// they continue on their existing path. That is a known gap, tracked in
/// docs/secure-core-architecture.md §4 — not a property of this type.
final class VibeSecureSessions {

  static let shared = VibeSecureSessions()

  /// Whether outbound DMs are sealed with MLS. **On by default.**
  ///
  /// This was off while a `vmls1.` envelope might reach a client too old to
  /// read it — that does not degrade a conversation, it splits it, and there is
  /// no recovering from it after the fact. There is no such install base: the
  /// app has not shipped, so every device that exists understands this format
  /// and the safe default is the secure one.
  ///
  /// The key remains an explicit off switch (`false` disables sealing) so a
  /// build can be dropped back without a code change if establishment turns out
  /// to misbehave in the field. Absent key means on — a fresh install must not
  /// have to opt in to encryption.
  ///
  /// Read every time rather than cached, so the switch takes effect without a
  /// relaunch; the read is a dictionary lookup.
  static var isSendEnabled: Bool {
    guard UserDefaults.standard.object(forKey: "vibe.mls.sendEnabled") != nil else { return true }
    return UserDefaults.standard.bool(forKey: "vibe.mls.sendEnabled")
  }

  /// Chats whose peer has confirmed it applied our Welcome.
  ///
  /// # Why sealing is gated on this and not just on "a session exists"
  ///
  /// MLS gives a sender **no feedback whatsoever**. `create_message` succeeds
  /// whether or not the other side ever joined, and — because a sender cannot
  /// decrypt its own message — a device can seal, store and display an entire
  /// conversation that nobody alive can open. Nothing in the protocol notices,
  /// and nothing in the UI does either: the messages look sent, they ack, they
  /// get delivery ticks.
  ///
  /// That is not hypothetical. On 2026-08-06 sealing was switched on before
  /// establishment had been confirmed end-to-end and every DM went blank on both
  /// sides simultaneously. The server knows the answer — it records `delivered_at`
  /// when the recipient acks the Welcome — the sender simply had no way to ask.
  /// Now it asks, and until the answer is yes it uses the path that already
  /// works.
  ///
  /// Persisted rather than in-memory: confirmation is a fact about the peer's
  /// device, not about this process, and re-deriving it on every launch would
  /// mean a relaunch silently drops back to the older envelope.
  private static let peerConfirmedKey = "vibe.mls.peerConfirmed"

  /// True when the peer for `chatId` has applied our Welcome and can therefore
  /// read what we seal.
  func isPeerConfirmed(chatId: String) -> Bool {
    let confirmed =
      UserDefaults.standard.array(forKey: Self.peerConfirmedKey) as? [String] ?? []
    return confirmed.contains(chatId)
  }

  /// Records that the peer for `chatId` confirmed the join.
  ///
  /// One-way on purpose. A peer that joined stays joined; a transient failure to
  /// reach the status endpoint must not revoke a conversation's encryption,
  /// because that would silently downgrade an established chat back to the older
  /// envelope on a bad network.
  func markPeerConfirmed(chatId: String) {
    queue.sync {
      var confirmed =
        UserDefaults.standard.array(forKey: Self.peerConfirmedKey) as? [String] ?? []
      guard !confirmed.contains(chatId) else { return }
      confirmed.append(chatId)
      UserDefaults.standard.set(confirmed, forKey: Self.peerConfirmedKey)
      VibeLog.notice("[VibeSecure] peer confirmed for \(chatId) — sealing with MLS from now on")
    }
  }

  private let queue = DispatchQueue(label: "vibe.secure.sessions")
  private var identityCache: VibeSecureIdentityHandle?
  private var sessions: [String: VibeSecureSessionHandle] = [:]

  private init() {}

  /// This device's MLS identity, generated once per process.
  ///
  /// The device id is Keychain-backed and stable across launches, because it is
  /// carried in the MLS credential and is what a safety-number UI will hash. A
  /// per-launch UUID would make this device look like a different party to every
  /// peer on every launch.
  ///
  /// The handle is constructed against the on-disk store at `storePath()`, so
  /// key material and group state outlive the process.
  private func identityHandleLocked() -> VibeSecureIdentityHandle? {
    if let identityCache = identityCache { return identityCache }
    guard let deviceId = VibeSecureDeviceId.loadOrCreate() else {
      VibeLog.error("[VibeSecure] no stable device id — MLS unavailable")
      return nil
    }
    guard let dbPath = Self.storePath() else {
      VibeLog.error("[VibeSecure] no store path — MLS unavailable")
      return nil
    }
    do {
      let handle = try VibeSecureIdentityHandle.generate(deviceId: deviceId, dbPath: dbPath)
      identityCache = handle
      return handle
    } catch {
      VibeLog.error("[VibeSecure] identity generation failed: \(error)")
      return nil
    }
  }

  /// Where the MLS ratchet state lives.
  ///
  /// Application Support rather than Caches: the OS may evict Caches under
  /// pressure, and losing this file means losing the ability to read every
  /// message in every established conversation. Excluded from backups for the
  /// same reason the store key is `ThisDeviceOnly` — a restored backup carrying
  /// stale ratchet state is worse than one that re-establishes cleanly.
  private static func storePath() -> String? {
    guard
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { return nil }
    var dir = base.appendingPathComponent("VibeSecure", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      var resourceValues = URLResourceValues()
      resourceValues.isExcludedFromBackup = true
      try? dir.setResourceValues(resourceValues)
    } catch {
      VibeLog.error("[VibeSecure] store directory unavailable: \(error)")
      return nil
    }
    return dir.appendingPathComponent("mls-state.sqlite").path
  }

  /// `chat id -> MLS group id`, so a relaunch can reload the right group.
  ///
  /// Group ids are not secret — they are the address of a group, not a key — so
  /// `UserDefaults` is the right weight here. The secrets are all in the SQLite
  /// store, which the OS sandboxes, and the device identity is in the Keychain.
  private static func storedGroupId(chatId: String) -> Data? {
    UserDefaults.standard.data(forKey: "vibe.mls.group.\(chatId)")
  }

  private static func storeGroupId(_ groupId: Data, chatId: String) {
    UserDefaults.standard.set(groupId, forKey: "vibe.mls.group.\(chatId)")
  }

  /// Returns the session for `chatId`, reloading it from disk on first use
  /// after a relaunch.
  ///
  /// Without this the in-memory registry would be empty at launch and every
  /// chat would look unestablished, so the app would mint a brand-new group and
  /// orphan every message sealed before the restart.
  private func sessionLocked(chatId: String) -> VibeSecureSessionHandle? {
    if let live = sessions[chatId] { return live }
    guard
      let groupId = Self.storedGroupId(chatId: chatId),
      let identity = identityHandleLocked()
    else { return nil }
    do {
      guard let restored = try identity.loadSession(groupId: groupId)
      else {
        VibeLog.info("[VibeSecure] no persisted group for \(chatId)")
        return nil
      }
      sessions[chatId] = restored
      return restored
    } catch {
      VibeLog.error("[VibeSecure] session reload failed for \(chatId): \(error)")
      return nil
    }
  }

  /// A fresh KeyPackage to publish so peers can add this device to a group.
  ///
  /// Each one is single-use: MLS consumes a KeyPackage's one-time init key when
  /// it adds a member, so the same package must never be handed out twice.
  func freshKeyPackage() -> Data? {
    queue.sync {
      guard let identity = identityHandleLocked() else { return nil }
      do {
        return try identity.keyPackage()
      } catch {
        VibeLog.error("[VibeSecure] key package failed: \(error)")
        return nil
      }
    }
  }

  /// Validates a peer's KeyPackage and reads the identity it claims.
  ///
  /// `nil` means the bytes did not survive validation — malformed, wrong
  /// ciphersuite, bad signature. A non-nil result is *not* proof the key
  /// belongs to the person you asked for; that is what `VibeSecureTrust` is
  /// for.
  func inspectKeyPackage(_ keyPackage: Data) -> VibeFfiKeyPackageIdentity? {
    queue.sync {
      guard let identity = identityHandleLocked() else { return nil }
      do {
        return try identity.inspectKeyPackage(keyPackage: keyPackage)
      } catch {
        VibeLog.error("[VibeSecure] key package inspect failed: \(error)")
        return nil
      }
    }
  }

  /// This device's public signature key — our half of any safety number.
  func mySignatureKey() -> Data? {
    queue.sync {
      guard let identity = identityHandleLocked() else { return nil }
      return try? identity.signatureKey()
    }
  }

  /// The safety number to compare with `peerUserId`, or `nil` before either
  /// side's key is known.
  func safetyNumber(peerUserId: String) -> String? {
    guard
      let mine = mySignatureKey(),
      let theirs = VibeSecureTrust.pinnedKey(userId: peerUserId)
    else { return nil }
    return VibeSecureTrust.safetyNumber(myKey: mine, peerKey: theirs)
  }

  /// Registers a session established elsewhere (group creation or a Welcome).
  func register(session: VibeSecureSessionHandle, chatId: String) {
    queue.sync { sessions[chatId] = session }
  }

  func hasSession(chatId: String) -> Bool {
    queue.sync { sessionLocked(chatId: chatId) != nil }
  }

  /// The MLS group id currently bound to `chatId`, if any.
  ///
  /// Exposed for the first-contact tie-break in `VibeSecureEstablishment`,
  /// which needs to compare our group against an incoming Welcome's without
  /// touching the ratchet.
  func groupId(chatId: String) -> Data? {
    queue.sync {
      guard sessionLocked(chatId: chatId) != nil else { return nil }
      return Self.storedGroupId(chatId: chatId)
    }
  }

  /// Whether this chat has been determined unable to use MLS.
  ///
  /// Today this means exactly one thing: it has more members than
  /// `VibeSecureEstablishment.maxGroupMembers`. Broadcast channels are
  /// indistinguishable from groups at this layer — iOS folds `isChannel` into
  /// `isGroup` before the engine sees it — so the member count is the only
  /// signal available, and without it a channel would queue every message
  /// forever waiting on an establishment that cannot succeed.
  ///
  /// **These chats are not end-to-end encrypted and do not fail closed.** They
  /// keep their existing behaviour, which for a group means plaintext to the
  /// server. That is a deliberate, documented gap — see
  /// docs/secure-core-architecture.md §4 — not an accident.
  ///
  /// Persisted so a relaunch does not re-probe a chat that will never qualify.
  func isIneligible(chatId: String) -> Bool {
    UserDefaults.standard.bool(forKey: "vibe.mls.ineligible.\(chatId)")
  }

  func markIneligible(chatId: String) {
    UserDefaults.standard.set(true, forKey: "vibe.mls.ineligible.\(chatId)")
  }

  /// Forgets the session bound to `chatId`.
  ///
  /// Used when an establishment attempt cannot be completed — the peer never
  /// received its Welcome, or we lost the first-contact tie-break — so the
  /// chat looks unestablished again and the next attempt starts clean. Leaving
  /// a half-established group in place is worse than dropping it: `hasSession`
  /// would report a session nobody else can read, and the send path trusts
  /// that answer.
  ///
  /// The group's state is left in the SQLite store rather than deleted. It is
  /// unreachable once the `chat id -> group id` mapping is gone, so this leaks
  /// a small amount of dead state per abandoned attempt; deleting it means
  /// reaching into OpenMLS's storage keyspace, which is a worse trade than
  /// leaking a few kilobytes in a rare path.
  func discard(chatId: String) {
    queue.sync {
      sessions.removeValue(forKey: chatId)
      UserDefaults.standard.removeObject(forKey: "vibe.mls.group.\(chatId)")
    }
  }

  /// Creates a new group for `chatId` with this device as its only member.
  func createSession(chatId: String) -> VibeSecureSessionHandle? {
    queue.sync {
      guard let identity = identityHandleLocked() else { return nil }
      do {
        let session = try VibeSecureSessionHandle.create(identity: identity)
        sessions[chatId] = session
        // Persist the address immediately: a crash between here and the first
        // send would otherwise strand a real group on disk that nothing can
        // ever look up again.
        Self.storeGroupId(try session.groupId(), chatId: chatId)
        return session
      } catch {
        VibeLog.error("[VibeSecure] session create failed for \(chatId): \(error)")
        return nil
      }
    }
  }

  /// Joins `chatId`'s group from a Welcome produced by another member.
  func joinSession(chatId: String, welcome: Data, ratchetTree: Data?) -> VibeSecureSessionHandle? {
    queue.sync {
      guard let identity = identityHandleLocked() else { return nil }
      do {
        let session = try VibeSecureSessionHandle.joinFromWelcome(
          identity: identity, welcome: welcome, ratchetTree: ratchetTree)
        sessions[chatId] = session
        Self.storeGroupId(try session.groupId(), chatId: chatId)
        return session
      } catch {
        VibeLog.error("[VibeSecure] session join failed for \(chatId): \(error)")
        return nil
      }
    }
  }

  // ── Own-message plaintext ───────────────────────────────────────────────
  //
  // A sender cannot decrypt its own MLS message. `create_message` encrypts to
  // the group's *other* members and OpenMLS refuses to process a message the
  // caller authored — pinned by
  // `a_sender_cannot_open_its_own_message_so_platforms_must_keep_the_plaintext`.
  //
  // The old hybrid envelope hid this: it was dual-wrapped, so the sender could
  // open its own. MLS is not, so when the server echoes a sent message back and
  // the engine re-parses `encryptedContent`, `open` fails and the row renders
  // empty. That is not corruption — the peer reads it fine — it is the sender
  // asking a question that has no answer.
  //
  // So the plaintext is kept here at seal time. Persisted, because the echo can
  // arrive after a relaunch and because scrolling back through your own history
  // must not go blank.

  /// How many of our own messages keep a retained plaintext.
  ///
  /// Bounded because this grows with every message sent and never shrinks on
  /// its own. Beyond the bound the oldest entries drop and those rows fall back
  /// to the locally cached history row, which already carries the text — the
  /// bound costs fidelity in a rare path, not correctness.
  private static let ownPlaintextLimit = 5000

  private static let ownPlaintextKey = "vibe.mls.ownPlaintext"
  private static let ownPlaintextOrderKey = "vibe.mls.ownPlaintext.order"

  /// Retains our own plaintext for `messageId`.
  func rememberOwnPlaintext(_ plaintext: String, messageId: String) {
    queue.sync {
      var store = UserDefaults.standard.dictionary(forKey: Self.ownPlaintextKey) as? [String: String] ?? [:]
      var order = UserDefaults.standard.stringArray(forKey: Self.ownPlaintextOrderKey) ?? []
      if store[messageId] == nil { order.append(messageId) }
      store[messageId] = plaintext
      while order.count > Self.ownPlaintextLimit {
        let evicted = order.removeFirst()
        store.removeValue(forKey: evicted)
      }
      UserDefaults.standard.set(store, forKey: Self.ownPlaintextKey)
      UserDefaults.standard.set(order, forKey: Self.ownPlaintextOrderKey)
    }
  }

  /// The plaintext we retained for one of our own messages, if we still have it.
  func ownPlaintext(messageId: String) -> String? {
    queue.sync {
      (UserDefaults.standard.dictionary(forKey: Self.ownPlaintextKey) as? [String: String])?[
        messageId]
    }
  }

  /// Seals a payload for `chatId`, or `nil` if this chat has no MLS session.
  ///
  /// `nil` is the ordinary case today and the caller must fall back to the
  /// existing envelope — it is not an error worth surfacing to the user.
  func seal(chatId: String, plaintext: String) -> String? {
    queue.sync {
      guard let session = sessionLocked(chatId: chatId) else { return nil }
      do {
        return try session.seal(plaintext: Data(plaintext.utf8))
      } catch {
        VibeLog.error("[VibeSecure] seal failed for \(chatId): \(error)")
        return nil
      }
    }
  }

  /// Opens a `vmls1.` envelope for `chatId`.
  ///
  /// Returns `nil` on every failure — no session, wrong session, tampered
  /// ciphertext — and the caller renders the existing decryption-failed state.
  /// Failures are deliberately indistinguishable *to the caller*; the Rust side
  /// already collapses them so that "wrong key" and "tampered" cannot be told
  /// apart.
  ///
  /// `isMine` and `messageId` exist only for the log line, and they matter more
  /// than they look. A self-authored message can never be opened — MLS encrypts
  /// to the group's *other* members — so a failure on our own message is
  /// **expected** and means the retained plaintext was missing, while a failure
  /// on a peer's message means the session genuinely disagrees and is a real
  /// bug. Without that distinction the log is a wall of identical "open failed"
  /// lines that cannot tell those two apart, which is exactly what it was on
  /// 2026-08-06.
  func open(chatId: String, envelope: String, isMine: Bool = false, messageId: String? = nil)
    -> String?
  {
    queue.sync {
      let who = isMine ? "own" : "peer"
      let mid = messageId.map { String($0.prefix(8)) } ?? "?"
      guard let session = sessionLocked(chatId: chatId) else {
        VibeLog.info(
          "[VibeSecure] vmls1 for \(chatId) mid=\(mid) from=\(who) — NO SESSION"
            + " (group=\(groupIdHexLocked(chatId: chatId) ?? "none"))")
        return nil
      }
      do {
        return String(decoding: try session.open(envelope: envelope), as: UTF8.self)
      } catch {
        // Split by author, because the two mean completely different things.
        if isMine {
          VibeLog.info(
            "[VibeSecure] own message \(mid) in \(chatId) is not self-openable (expected);"
              + " retained plaintext missing")
        } else {
          VibeLog.error(
            "[VibeSecure] PEER open failed chat=\(chatId) mid=\(mid)"
              + " group=\(groupIdHexLocked(chatId: chatId) ?? "none") — session disagrees: \(error)"
          )
        }
        return nil
      }
    }
  }

  /// The MLS group id for a chat, hex-truncated, for logs only.
  ///
  /// Two devices that each created their own group for the same chat is the
  /// failure that looks identical to every other decrypt failure from the
  /// outside — both sides hold a valid session, both seal happily, and neither
  /// can read the other. Printing the group id is what makes that visible
  /// instead of merely suspected.
  private func groupIdHexLocked(chatId: String) -> String? {
    guard let id = groupId(chatId: chatId) else { return nil }
    return id.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  /// True when `raw` is an MLS envelope. Prefix test only — matches how the Rust
  /// classifier and the shipped `arte1.` detection both work.
  static func isMlsEnvelope(_ raw: String?) -> Bool {
    guard let raw = raw else { return false }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("vmls1.")
  }
}

/// A stable per-install device identifier for the MLS credential.
///
/// Keychain-backed rather than a `UserDefaults` string so it survives an app
/// reinstall the way the user expects an identity to, and `ThisDeviceOnly` so it
/// never rides a backup onto a second device — two devices sharing one MLS
/// credential is exactly the confusion the credential exists to prevent.
enum VibeSecureDeviceId {

  private static let service = "vibe.secure.identity"
  private static let account = "mls_device_id_v1"
  private static let queue = DispatchQueue(label: "vibe.secure.deviceid")

  static func loadOrCreate() -> String? {
    queue.sync {
      if let existing = load() { return existing }
      let fresh = UUID().uuidString
      return store(fresh) ? fresh : nil
    }
  }

  private static func load() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let value = String(data: data, encoding: .utf8),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }

  private static func store(_ value: String) -> Bool {
    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    SecItemDelete(attributes as CFDictionary)
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }
}
