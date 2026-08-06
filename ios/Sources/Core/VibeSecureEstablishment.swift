import Foundation

/// Gets an MLS session to exist for a chat, which is the one thing
/// `VibeSecureSessions` cannot do for itself: creating a group means talking to
/// the server to fetch the other side's KeyPackage, and joining one means
/// receiving a Welcome that arrived out of band.
///
/// # Why this is a separate type
///
/// `VibeSecureSessions` is pure custody — it holds the identity, the store, and
/// the per-chat sessions, and every one of its methods is synchronous and
/// local. Establishment is the opposite: network-bound, retryable, and racy.
/// Keeping them apart means the custody layer stays trivially auditable, and
/// this layer never has to reason about the ratchet.
///
/// # Never on the engine queue
///
/// Every entry point here returns immediately and does its work on
/// `establishmentQueue` / `URLSession`. `ChatEngine`'s serial queue is the
/// engine's critical path, and an HTTP round-trip on it freezes messaging —
/// the same rule that governs every other network call in the engine.
///
/// # The first-contact race
///
/// Two devices can both decide to establish the same chat at the same instant,
/// each creating a group and adding the other. Both then hold a valid session
/// for one chat id, and neither can read the other's messages. The tie-break is
/// in `resolveCollision` below: both sides apply the *same* rule to the *same*
/// two group ids, so they converge without another round-trip.
enum VibeSecureEstablishment {

  /// How many KeyPackages this device keeps published.
  ///
  /// Each one is consumed by a single peer adding this device to a group, so
  /// the pool is "how many people can start a conversation with me before I
  /// next come online to top it up". Ten is generous for a first release and
  /// cheap: a KeyPackage is a couple of hundred bytes.
  private static let keyPackagePoolSize = 10

  /// Top the pool up when it falls to here. Deliberately not zero — a peer that
  /// finds an empty pool cannot start a conversation at all, so the pool must
  /// refill before it runs dry, not after.
  private static let keyPackageLowWaterMark = 3

  /// Largest group this will establish an MLS session for. Beyond it the chat
  /// is marked ineligible — see `VibeSecureSessions.isIneligible(chatId:)` for
  /// why that is the only workable signal here and what it costs.
  static let maxGroupMembers = 256

  private static let establishmentQueue = DispatchQueue(
    label: "vibe.secure.establishment", qos: .utility)

  /// Chats with an establishment attempt already in flight.
  ///
  /// Guarded by `establishmentQueue`. Without this, a user hammering send on an
  /// unestablished chat would fire one group creation per tap, and each would
  /// consume one of the peer's finite KeyPackages.
  private static var inFlight: Set<String> = []

  // ── Publishing this device's KeyPackages ────────────────────────────────

  /// Ensures this device has KeyPackages published so peers can add it.
  ///
  /// Safe to call on every launch and every login: it asks the server how many
  /// remain first and does nothing when the pool is healthy.
  static func ensureKeyPackagesPublished(apiBase: URL, token: String?) {
    establishmentQueue.async {
      request(
        method: "GET", path: "api/mls/key-packages/count", apiBase: apiBase, token: token,
        body: nil
      ) { object in
        let remaining = (object?["count"] as? Int) ?? 0
        guard remaining <= keyPackageLowWaterMark else { return }
        publishKeyPackages(count: keyPackagePoolSize - remaining, apiBase: apiBase, token: token)
      }
    }
  }

  private static func publishKeyPackages(count: Int, apiBase: URL, token: String?) {
    guard count > 0, let deviceId = VibeSecureDeviceId.loadOrCreate() else { return }
    var encoded: [String] = []
    encoded.reserveCapacity(count)
    for _ in 0..<count {
      guard let package = VibeSecureSessions.shared.freshKeyPackage() else { break }
      encoded.append(package.base64EncodedString())
    }
    guard !encoded.isEmpty else {
      VibeLog.error("[VibeSecure] could not mint any KeyPackage — MLS unavailable to peers")
      return
    }
    request(
      method: "POST", path: "api/mls/key-packages", apiBase: apiBase, token: token,
      body: ["deviceId": deviceId, "keyPackages": encoded]
    ) { object in
      let published = (object?["count"] as? Int) ?? 0
      VibeLog.info("[VibeSecure] published \(published) KeyPackages")
    }
  }

  // ── Establishing a DM ───────────────────────────────────────────────────

  /// Creates the MLS group for a 1:1 chat and hands the peer its Welcome.
  ///
  /// `completion` runs with `true` only when a session is live and sealed
  /// messages will be readable by the peer. The caller's contract is to keep
  /// the message queued until then — never to send it in the clear.
  ///
  /// Groups are deliberately not handled here. A group needs the full member
  /// list to add everyone in one commit, and that list does not exist at this
  /// layer today (see `docs/secure-core-architecture.md` §4).
  static func establishDirectMessage(
    chatId: String,
    peerUserId: String,
    apiBase: URL,
    token: String?,
    completion: @escaping (Bool) -> Void
  ) {
    establishmentQueue.async {
      guard !inFlight.contains(chatId) else { return }
      if VibeSecureSessions.shared.hasSession(chatId: chatId) {
        completion(true)
        return
      }
      inFlight.insert(chatId)

      let finish: (Bool) -> Void = { ok in
        establishmentQueue.async {
          inFlight.remove(chatId)
          completion(ok)
        }
      }

      // Claim one of the peer's published KeyPackages. A 404 here is an
      // ordinary, expected state — that user has not published any, or has run
      // out — and it means this chat cannot be encrypted yet, not that
      // something is broken. The caller must keep the message queued.
      request(
        method: "GET", path: "api/mls/key-packages/\(escaped(peerUserId))", apiBase: apiBase,
        token: token, body: nil
      ) { object in
        guard
          let encoded = object?["keyPackage"] as? String,
          let keyPackage = Data(base64Encoded: encoded)
        else {
          VibeLog.info("[VibeSecure] no KeyPackage available for peer in \(chatId)")
          finish(false)
          return
        }

        // Create only after the claim succeeds. Creating first would leave a
        // real group on disk for a chat that never got a second member, and
        // `hasSession` would then report a session that nobody else can read.
        guard let session = VibeSecureSessions.shared.createSession(chatId: chatId) else {
          finish(false)
          return
        }
        let commit: VibeFfiCommitOutput
        do {
          commit = try session.addMembers(keyPackages: [keyPackage])
        } catch {
          VibeLog.error("[VibeSecure] add_members failed for \(chatId): \(error)")
          VibeSecureSessions.shared.discard(chatId: chatId)
          finish(false)
          return
        }

        // The commit itself has no existing members to go to — this group had
        // exactly one member until now — so only the Welcome is delivered.
        let ratchetTree = (try? session.exportRatchetTree()) ?? Data()
        request(
          method: "POST", path: "api/mls/welcomes", apiBase: apiBase, token: token,
          body: [
            "recipientUserId": peerUserId,
            "chatId": chatId,
            "welcome": commit.welcome.base64EncodedString(),
            "ratchetTree": ratchetTree.base64EncodedString(),
          ]
        ) { response in
          guard response?["success"] as? Bool == true else {
            // The peer will never learn this group exists, so a message sealed
            // under it would be permanently unreadable to them. Drop it and
            // let the next attempt start clean.
            VibeLog.error("[VibeSecure] welcome delivery failed for \(chatId)")
            VibeSecureSessions.shared.discard(chatId: chatId)
            finish(false)
            return
          }
          VibeLog.info("[VibeSecure] established MLS session for \(chatId)")
          finish(true)
        }
      }
    }
  }

  // ── Establishing a group ────────────────────────────────────────────────

  /// Creates the MLS group backing a many-member chat and hands every other
  /// member its Welcome.
  ///
  /// Unlike a DM this needs the membership list, which the client cannot infer
  /// — hence the extra round-trip to `/mls/chats/:id/members`.
  ///
  /// **All-or-nothing.** If any member has no KeyPackage to claim, this gives
  /// up rather than establishing a group that silently excludes them. A member
  /// left out would not fail loudly; they would simply never see the
  /// conversation again, which is far worse than the sender waiting. The
  /// message stays queued and a later attempt retries.
  static func establishGroup(
    chatId: String,
    myUserId: String,
    apiBase: URL,
    token: String?,
    completion: @escaping (Bool) -> Void
  ) {
    establishmentQueue.async {
      guard !inFlight.contains(chatId) else { return }
      if VibeSecureSessions.shared.hasSession(chatId: chatId) {
        completion(true)
        return
      }
      inFlight.insert(chatId)

      let finish: (Bool) -> Void = { ok in
        establishmentQueue.async {
          inFlight.remove(chatId)
          completion(ok)
        }
      }

      request(
        method: "GET", path: "api/mls/chats/\(escaped(chatId))/members", apiBase: apiBase,
        token: token, body: nil
      ) { object in
        guard let memberIds = object?["memberIds"] as? [String] else {
          VibeLog.info("[VibeSecure] no member list for \(chatId)")
          finish(false)
          return
        }
        let peers = memberIds.filter { $0 != myUserId }

        // Above this, treat the chat as a broadcast surface rather than a
        // group. Establishing would mean claiming a KeyPackage per member and
        // then a commit every member must process on each join or leave — a
        // storm, not a conversation. WhatsApp caps encrypted groups at 1024
        // for the same reason; this sits well below that because the failure
        // here is a stuck send, not a slow one.
        guard peers.count <= maxGroupMembers else {
          VibeLog.info(
            "[VibeSecure] \(chatId) has \(peers.count) members — over the MLS cap, marking ineligible"
          )
          VibeSecureSessions.shared.markIneligible(chatId: chatId)
          // `true` means "state changed, retry the send" — not "encrypted".
          // The retry now skips the gate and takes the existing path.
          finish(true)
          return
        }

        guard !peers.isEmpty else {
          // A group with only us in it has nobody to encrypt to. Establishing
          // would produce a session no one else can ever join.
          VibeLog.info("[VibeSecure] \(chatId) has no peers to add")
          finish(false)
          return
        }
        claimKeyPackages(for: peers, apiBase: apiBase, token: token) { claimed in
          guard claimed.count == peers.count else {
            VibeLog.info(
              "[VibeSecure] \(chatId) only \(claimed.count)/\(peers.count) KeyPackages — not establishing"
            )
            finish(false)
            return
          }
          guard let session = VibeSecureSessions.shared.createSession(chatId: chatId) else {
            finish(false)
            return
          }
          let commit: VibeFfiCommitOutput
          do {
            // One commit adds everyone, producing a single Welcome that
            // carries each joiner's secrets keyed to their own KeyPackage —
            // so the same bytes go to every recipient.
            commit = try session.addMembers(keyPackages: peers.compactMap { claimed[$0] })
          } catch {
            VibeLog.error("[VibeSecure] group add_members failed for \(chatId): \(error)")
            VibeSecureSessions.shared.discard(chatId: chatId)
            finish(false)
            return
          }

          let ratchetTree = (try? session.exportRatchetTree()) ?? Data()
          deliverWelcome(
            commit.welcome, ratchetTree: ratchetTree, to: peers, chatId: chatId,
            apiBase: apiBase, token: token
          ) { delivered in
            guard delivered else {
              // Some member will never learn the group exists. Drop it rather
              // than seal messages they can never read.
              VibeLog.error("[VibeSecure] group welcome delivery incomplete for \(chatId)")
              VibeSecureSessions.shared.discard(chatId: chatId)
              finish(false)
              return
            }
            VibeLog.info("[VibeSecure] established group MLS session for \(chatId)")
            finish(true)
          }
        }
      }
    }
  }

  /// Claims one KeyPackage per user, sequentially.
  ///
  /// Sequential rather than concurrent on purpose: each claim consumes a
  /// one-time key server-side, and a burst of parallel claims against the same
  /// user during a retry storm would drain their pool for no benefit. Groups
  /// are established once, so the latency does not sit on a hot path.
  private static func claimKeyPackages(
    for userIds: [String],
    apiBase: URL,
    token: String?,
    completion: @escaping ([String: Data]) -> Void
  ) {
    var claimed: [String: Data] = [:]
    var remaining = userIds

    func next() {
      guard !remaining.isEmpty else {
        completion(claimed)
        return
      }
      let userId = remaining.removeFirst()
      request(
        method: "GET", path: "api/mls/key-packages/\(escaped(userId))", apiBase: apiBase,
        token: token, body: nil
      ) { object in
        if let encoded = object?["keyPackage"] as? String,
          let data = Data(base64Encoded: encoded)
        {
          claimed[userId] = data
        }
        next()
      }
    }
    next()
  }

  /// Posts one Welcome to each recipient, reporting success only if every one
  /// was accepted.
  private static func deliverWelcome(
    _ welcome: Data,
    ratchetTree: Data,
    to userIds: [String],
    chatId: String,
    apiBase: URL,
    token: String?,
    completion: @escaping (Bool) -> Void
  ) {
    var remaining = userIds
    var allOk = true

    func next() {
      guard !remaining.isEmpty else {
        completion(allOk)
        return
      }
      let userId = remaining.removeFirst()
      request(
        method: "POST", path: "api/mls/welcomes", apiBase: apiBase, token: token,
        body: [
          "recipientUserId": userId,
          "chatId": chatId,
          "welcome": welcome.base64EncodedString(),
          "ratchetTree": ratchetTree.base64EncodedString(),
        ]
      ) { response in
        if response?["success"] as? Bool != true { allOk = false }
        next()
      }
    }
    next()
  }

  // ── Joining from a Welcome ──────────────────────────────────────────────

  /// Fetches and applies every Welcome waiting for this device.
  ///
  /// Called on launch and on socket join. Each Welcome is acked only after the
  /// join succeeds, so a crash mid-join leaves it pending and it is retried
  /// rather than silently lost — losing a Welcome means losing the ability to
  /// read that conversation entirely.
  /// `completion` receives the chat ids that gained a session, so the caller can
  /// release any drafts queued behind the send gate for those chats. Nothing
  /// else would release them — the sender is blocked waiting on exactly this.
  static func drainPendingWelcomes(
    apiBase: URL, token: String?, completion: (([String]) -> Void)? = nil
  ) {
    establishmentQueue.async {
      request(
        method: "GET", path: "api/mls/welcomes", apiBase: apiBase, token: token, body: nil
      ) { object in
        guard let welcomes = object?["welcomes"] as? [[String: Any]], !welcomes.isEmpty else {
          completion?([])
          return
        }
        var joined: [String] = []
        for entry in welcomes {
          guard
            let id = entry["id"] as? String,
            let chatId = entry["chatId"] as? String,
            let encoded = entry["welcome"] as? String,
            let welcome = Data(base64Encoded: encoded)
          else { continue }
          let ratchetTree = (entry["ratchetTree"] as? String).flatMap { Data(base64Encoded: $0) }

          if let existing = VibeSecureSessions.shared.groupId(chatId: chatId) {
            guard resolveCollision(existing: existing, incoming: welcome) else {
              // Our group wins the tie-break. Ack so the server stops
              // redelivering; the peer is applying the same rule and will
              // adopt ours from the Welcome we sent them.
              ack(id: id, apiBase: apiBase, token: token)
              continue
            }
            VibeSecureSessions.shared.discard(chatId: chatId)
          }

          guard
            VibeSecureSessions.shared.joinSession(
              chatId: chatId, welcome: welcome, ratchetTree: ratchetTree) != nil
          else {
            VibeLog.error("[VibeSecure] welcome join failed for \(chatId) — left pending")
            continue
          }
          VibeLog.info("[VibeSecure] joined MLS session for \(chatId)")
          joined.append(chatId)
          ack(id: id, apiBase: apiBase, token: token)
        }
        completion?(joined)
      }
    }
  }

  /// Decides whether an incoming Welcome should replace the session we already
  /// hold for that chat. Returns `true` to adopt the incoming group.
  ///
  /// Both devices run this on the same pair of groups, so the rule only has to
  /// be *deterministic and symmetric* — not clever. Lowest group id wins.
  ///
  /// Messages sealed under the losing group before convergence are unreadable
  /// afterwards. That is a first-contact-only window, and losing a handful of
  /// opening messages is strictly better than the alternative, which is two
  /// devices talking past each other in a conversation that never converges.
  private static func resolveCollision(existing: Data, incoming: Data) -> Bool {
    incoming.lexicographicallyPrecedes(existing)
  }

  private static func ack(id: String, apiBase: URL, token: String?) {
    request(
      method: "POST", path: "api/mls/welcomes/\(escaped(id))/ack", apiBase: apiBase, token: token,
      body: nil, completion: { _ in })
  }

  // ── HTTP ────────────────────────────────────────────────────────────────

  /// Percent-encodes a value being spliced into a URL path.
  ///
  /// Deliberately *not* `.urlPathAllowed`, which leaves `/` untouched — an id
  /// containing one would then add path segments rather than be a single
  /// component, and `request` splits the path on `/` to build the URL. These
  /// ids are server-issued UUIDs today, so this is defence rather than a live
  /// bug, but the encoding has to be right for the splice to be safe at all.
  private static func escaped(_ raw: String) -> String {
    let unreserved = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return raw.addingPercentEncoding(withAllowedCharacters: unreserved) ?? raw
  }

  /// One JSON round-trip against the API, on the app's pinned session.
  ///
  /// `completion` receives `nil` for every failure — transport, non-2xx, or
  /// unparseable body. Callers here treat "no answer" and "no" identically:
  /// both mean the session is not established, and the only safe response to
  /// that is to keep the message queued.
  private static func request(
    method: String,
    path: String,
    apiBase: URL,
    token: String?,
    body: [String: Any]?,
    completion: @escaping ([String: Any]?) -> Void
  ) {
    var url = apiBase
    for component in path.split(separator: "/") {
      url = url.appendingPathComponent(String(component))
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let token = token, !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body = body {
      guard let data = try? JSONSerialization.data(withJSONObject: body) else {
        completion(nil)
        return
      }
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = data
    }
    ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { data, response, error in
      establishmentQueue.async {
        guard
          error == nil,
          let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
          let data = data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          completion(nil)
          return
        }
        completion(object)
      }
    }.resume()
  }
}
