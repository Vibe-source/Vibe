import CryptoKit
import Foundation
import Network
import OSLog
import Security
import UIKit

private let chatEngineUITraceLogger = Logger(
  subsystem: "com.mohammadshayani.vibe.native",
  category: "UITrace"
)

private func chatEngineUITrace(_ message: String) {
  VibeDebugLog.notice(logger: chatEngineUITraceLogger, message)
  VibeDebugLog.log("[VibeUITrace] %@", message)
}

private struct ChatEngineHybridPayload: Decodable {
  let iv: String
  let c: String
  let k: String?
  let s: String?
  let g: String?
}

private struct ChatIngestDelta {
  let insertedIds: [String]
  let updatedIds: [String]
  let deletedIds: [String]
}

/// Message-dict keys whose ABSENCE means "off" — the ingest merge must never carry
/// them forward from an older copy (see ingestHistoryRowsLocked's merge policy).
extension ChatEngine {
  fileprivate static let ingestTransientMessageKeys: Set<String> = [
    "isStreaming", "is_streaming", "uploadProgress", "upload_progress",
  ]
}

private func chatEngineReadDERLength(bytes: [UInt8], offset: inout Int) -> Int? {
  guard offset < bytes.count else { return nil }
  let first = Int(bytes[offset])
  offset += 1
  if (first & 0x80) == 0 { return first }
  let count = first & 0x7f
  guard count > 0, count <= 4, offset + count <= bytes.count else { return nil }
  var value = 0
  for _ in 0..<count {
    value = (value << 8) | Int(bytes[offset])
    offset += 1
  }
  return value
}

private func chatEngineExtractPKCS1FromPKCS8(_ data: Data) -> Data? {
  let bytes = [UInt8](data)
  var offset = 0
  guard offset < bytes.count, bytes[offset] == 0x30 else { return nil }
  offset += 1
  guard let seqLength = chatEngineReadDERLength(bytes: bytes, offset: &offset) else { return nil }
  let seqEnd = offset + seqLength
  guard seqEnd <= bytes.count else { return nil }
  guard offset < seqEnd, bytes[offset] == 0x02 else { return nil }
  offset += 1
  guard let versionLength = chatEngineReadDERLength(bytes: bytes, offset: &offset) else {
    return nil
  }
  offset += versionLength
  guard offset < seqEnd, bytes[offset] == 0x30 else { return nil }
  offset += 1
  guard let algLength = chatEngineReadDERLength(bytes: bytes, offset: &offset) else { return nil }
  offset += algLength
  guard offset < seqEnd, bytes[offset] == 0x04 else { return nil }
  offset += 1
  guard let keyLength = chatEngineReadDERLength(bytes: bytes, offset: &offset) else { return nil }
  let start = offset
  let end = start + keyLength
  guard end <= seqEnd else { return nil }
  return data.subdata(in: start..<end)
}

private func chatEngineDecodePEM(_ pem: String) -> Data? {
  // Turn literal escape sequences that arrive from JSON serialisation
  // (e.g. the two-character sequence \n) into real newlines.
  let normalized =
    pem
    .replacingOccurrences(of: "\\r\\n", with: "\n")
    .replacingOccurrences(of: "\\r", with: "\n")
    .replacingOccurrences(of: "\\n", with: "\n")
  let sanitized =
    normalized
    .replacingOccurrences(of: "-----BEGIN [^-]+-----", with: "", options: .regularExpression)
    .replacingOccurrences(of: "-----END [^-]+-----", with: "", options: .regularExpression)
  // Use .ignoreUnknownCharacters so whitespace/newlines in the base64 body
  // are silently skipped — Data(base64Encoded:) rejects them by default.
  return Data(base64Encoded: sanitized, options: .ignoreUnknownCharacters)
}

private func chatEnginePrivateKey(from pem: String) -> SecKey? {
  guard let keyData = chatEngineDecodePEM(pem) else {
    print(
      "[ChatEngine] chatEnginePrivateKey — PEM decode returned nil, pemLen=\(pem.count) prefix=\(pem.prefix(50))"
    )
    return nil
  }
  let attrs: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    kSecAttrKeySizeInBits as String: 2048,
  ]
  var error: Unmanaged<CFError>?

  let isPKCS8 = pem.contains("BEGIN PRIVATE KEY") && !pem.contains("BEGIN RSA PRIVATE KEY")
  let targetData = (isPKCS8 ? chatEngineExtractPKCS1FromPKCS8(keyData) : nil) ?? keyData

  // Attempt 1: standard
  if let key = SecKeyCreateWithData(targetData as CFData, attrs as CFDictionary, &error) {
    return key
  }

  // Attempt 2: retry without explicit key-size (in case it's non-2048)
  let attrsNoSize: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
  ]
  error = nil
  if let key = SecKeyCreateWithData(targetData as CFData, attrsNoSize as CFDictionary, &error) {
    return key
  }

  // Safe logging — use takeUnretainedValue to avoid over-releasing CFError
  let errDesc: String
  if let e = error {
    errDesc = String(describing: e.takeUnretainedValue())
  } else {
    errDesc = "nil"
  }
  let firstBytes = keyData.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
  print(
    "[ChatEngine] chatEnginePrivateKey FAILED — derLen=\(keyData.count) firstBytes=[\(firstBytes)] pemPrefix=\(pem.prefix(40)) error=\(errDesc)"
  )
  return nil
}

private func chatEngineRSADecryptOAEP(privateKey: SecKey, encrypted: Data) -> Data? {
  var error: Unmanaged<CFError>?
  let decrypted =
    SecKeyCreateDecryptedData(
      privateKey,
      .rsaEncryptionOAEPSHA256,
      encrypted as CFData,
      &error
    ) as Data?
  _ = error?.takeRetainedValue()
  return decrypted
}

private func chatEnginePublicKey(from pem: String) -> SecKey? {
  guard let keyData = chatEngineDecodePEM(pem) else { return nil }
  let attrs: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
  ]
  var error: Unmanaged<CFError>?
  let key = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, &error)
  _ = error?.takeRetainedValue()
  return key
}

private func chatEngineRSAEncryptOAEP(publicKey: SecKey, plain: Data) -> Data? {
  var error: Unmanaged<CFError>?
  let encrypted =
    SecKeyCreateEncryptedData(
      publicKey,
      .rsaEncryptionOAEPSHA256,
      plain as CFData,
      &error
    ) as Data?
  _ = error?.takeRetainedValue()
  return encrypted
}

private func chatEngineRandomBytes(count: Int) throws -> Data {
  var data = Data(count: count)
  let status = data.withUnsafeMutableBytes { buffer in
    guard let baseAddress = buffer.baseAddress else { return errSecParam }
    return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
  }
  if status != errSecSuccess {
    throw NSError(
      domain: "ChatEngine",
      code: Int(status),
      userInfo: [NSLocalizedDescriptionKey: "Secure random generation failed (\(status))"]
    )
  }
  return data
}

private func chatEngineEncryptHybridMessage(
  recipientPublicKeyPem: String,
  message: String,
  myPublicKeyPem: String?
) throws -> String {
  guard let recipientKey = chatEnginePublicKey(from: recipientPublicKeyPem) else {
    throw NSError(
      domain: "ChatEngine", code: 10,
      userInfo: [NSLocalizedDescriptionKey: "Invalid recipient public key"])
  }

  let aesKey = try chatEngineRandomBytes(count: 32)
  let iv = try chatEngineRandomBytes(count: 12)
  let nonce = try AES.GCM.Nonce(data: iv)
  let sealed = try AES.GCM.seal(Data(message.utf8), using: SymmetricKey(data: aesKey), nonce: nonce)

  guard let encryptedRecipientKey = chatEngineRSAEncryptOAEP(publicKey: recipientKey, plain: aesKey)
  else {
    throw NSError(
      domain: "ChatEngine", code: 11,
      userInfo: [NSLocalizedDescriptionKey: "Recipient RSA encrypt failed"])
  }

  var senderEncryptedKeyB64: String?
  if let myPublicKeyPem, let myPublicKey = chatEnginePublicKey(from: myPublicKeyPem) {
    if let encryptedSenderKey = chatEngineRSAEncryptOAEP(publicKey: myPublicKey, plain: aesKey) {
      senderEncryptedKeyB64 = encryptedSenderKey.base64EncodedString()
    }
  }

  let combinedCipher = sealed.ciphertext + sealed.tag
  var json: [String: Any] = [
    "v": 1,
    "iv": iv.base64EncodedString(),
    "c": combinedCipher.base64EncodedString(),
    "k": encryptedRecipientKey.base64EncodedString(),
  ]
  if let senderEncryptedKeyB64 { json["s"] = senderEncryptedKeyB64 }
  let serialized = try JSONSerialization.data(withJSONObject: json, options: [])
  guard let payloadString = String(data: serialized, encoding: .utf8) else {
    throw NSError(
      domain: "ChatEngine", code: 12,
      userInfo: [NSLocalizedDescriptionKey: "Could not encode payload"])
  }
  return payloadString
}

private func chatEngineDecryptHybridMessage(
  privateKey: SecKey,
  ciphertext: String,
  isMyMessage: Bool
) -> String {
  let trimmed = ciphertext.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return "" }
  guard let payload = try? JSONDecoder().decode(ChatEngineHybridPayload.self, from: data) else {
    NSLog(
      "[ChatEngine] Decrypt failed: Payload decode error on JSON (isMyMessage: %@)",
      isMyMessage ? "Y" : "N")
    return ""
  }
  guard
    let iv = Data(base64Encoded: payload.iv),
    let cipherAndTag = Data(base64Encoded: payload.c),
    cipherAndTag.count >= 16
  else {
    NSLog("[ChatEngine] Decrypt failed: Invalid iv or ciphertext structure")
    return ""
  }

  var keyCandidates = [Data]()

  if let g = payload.g, let gBlob = Data(base64Encoded: g) {
    keyCandidates.append(gBlob)
  }

  if isMyMessage {
    if let s = payload.s, let senderBlob = Data(base64Encoded: s) {
      keyCandidates.append(senderBlob)
    }
    if let k = payload.k, let recipientBlob = Data(base64Encoded: k) {
      keyCandidates.append(recipientBlob)
    }
  } else {
    if let k = payload.k, let recipientBlob = Data(base64Encoded: k) {
      keyCandidates.append(recipientBlob)
    }
    if let s = payload.s, let senderBlob = Data(base64Encoded: s) {
      keyCandidates.append(senderBlob)
    }
  }

  var aesKeyData: Data?
  for blob in keyCandidates {
    if let decrypted = chatEngineRSADecryptOAEP(privateKey: privateKey, encrypted: blob) {
      aesKeyData = decrypted
      break
    }
  }
  guard let aesKeyData else {
    NSLog(
      "[ChatEngine] Decrypt failed: Could not decrypt AES key. Candidates count: %d",
      keyCandidates.count)
    return ""
  }

  let ciphertextData = cipherAndTag.dropLast(16)
  let tagData = cipherAndTag.suffix(16)
  do {
    let nonce = try AES.GCM.Nonce(data: iv)
    let sealedBox = try AES.GCM.SealedBox(
      nonce: nonce,
      ciphertext: ciphertextData,
      tag: tagData
    )
    let plaintextData = try AES.GCM.open(sealedBox, using: SymmetricKey(data: aesKeyData))
    return String(data: plaintextData, encoding: .utf8) ?? ""
  } catch {
    NSLog("[ChatEngine] Decrypt failed (AES): %@", error.localizedDescription)
    return ""
  }
}

private func chatEngineEncryptMediaData(_ plainData: Data) throws -> (encryptedData: Data, keyBase64: String) {
  let aesKey = try chatEngineRandomBytes(count: 32)
  let iv = try chatEngineRandomBytes(count: 12)
  let nonce = try AES.GCM.Nonce(data: iv)
  let sealed = try AES.GCM.seal(plainData, using: SymmetricKey(data: aesKey), nonce: nonce)

  var combined = Data()
  combined.append(iv)
  combined.append(sealed.ciphertext)
  combined.append(sealed.tag)

  return (combined, aesKey.base64EncodedString())
}

private func chatEngineDecryptMediaData(_ encryptedData: Data, keyBase64: String) throws -> Data {
  guard
    let aesKey = Data(base64Encoded: keyBase64),
    encryptedData.count > 28
  else {
    throw NSError(
      domain: "ChatEngine",
      code: 40,
      userInfo: [NSLocalizedDescriptionKey: "Invalid encrypted media payload"]
    )
  }

  let iv = encryptedData.prefix(12)
  let ciphertext = encryptedData.dropFirst(12).dropLast(16)
  let tag = encryptedData.suffix(16)
  let nonce = try AES.GCM.Nonce(data: iv)
  let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
  return try AES.GCM.open(sealed, using: SymmetricKey(data: aesKey))
}

final class ChatEngine {
  static let shared = ChatEngine()
  static let didChangeNotification = Notification.Name("Vibe.ChatEngine.didChange")
  private static let bridgeSessionPageLimit = 40

  private struct SurfaceBinding: Equatable {
    let surfaceId: String
    let chatId: String?
    let myUserId: String?
    let peerUserId: String?
    let peerAgentId: String?
  }

  private struct AgentProgressState: Equatable {
    let label: String
    let tool: String?
    let status: String
    let updatedAtMs: Int64
  }

  private struct PendingCallSignal {
    let id: String
    let event: String
    let payload: [String: Any]
    let createdAtMs: Int
  }

  private let queue = DispatchQueue(label: "vibe.chat.engine")
  // Dedicated low-priority queue for the main-thread-hang watchdog timer so it
  // can fire even while the main thread (and engine queue) are blocked.
  private static let syncWatchdogQueue = DispatchQueue(
    label: "vibe.chat.engine.sync-watchdog", qos: .utility)
  private let queueSpecificKey = DispatchSpecificKey<UInt8>()
  private let queueSpecificValue: UInt8 = 1
  private let store = ChatEngineStore.shared

  private var state: [String: Any] = [
    "state": "idle",
    "connected": false,
    "updatedAt": 0,
    "note": "ChatEngine scaffold (shadow mode)",
  ]
  private var journalEntryCount = 0
  private var onlineUsers = Set<String>()
  private var lastSeenByUserId: [String: Int64] = [:]
  private var surfaceBindings: [String: SurfaceBinding] = [:]
  private var openChatChannels: [String: Int] = [:]
  // chatId -> messageId -> "delivered" | "read"
  private var receiptIndex: [String: [String: String]] = [:]
  private var localStatusIndex: [String: [String: String]] = [:]
  private var phoenixClient: ChatRealtimeTransport?
  private var nativePresenceActive = false
  private var nativeUserTopic: String?
  private var nativeUserJoinRef: String?
  private var nativeSocketSignature: String?
  private var nativeChatJoinRefsByRef: [String: String] = [:]
  private var nativeJoinedChatIds = Set<String>()
  private var nativePendingMessagePushRefs: [String: (chatId: String, messageId: String)] = [:]
  /// Wall-clock ms at which each outbound message push was handed to the socket,
  /// keyed by push ref. Lets us log the true send→server-ack (checkmark) latency.
  private var nativeMessagePushSentAtMs: [String: Int] = [:]
  private var nativePendingEditPushRefs: [String: (chatId: String, messageId: String)] = [:]
  private var nativePendingDeletePushRefs: [
    String: (chatId: String, messageId: String, forEveryone: Bool)
  ] = [:]
  private var nativePendingCallSignals: [PendingCallSignal] = []
  private var nativePendingCallPushRefs: [String: String] = [:]
  private var nativeUserChannelDemandUntilMs = 0
  /// True while the app is active in the foreground. Starts true: a cold launch runs this
  /// initializer while becoming active, and the first willResignActive corrects it.
  private var appIsForeground = true
  /// Native reachability. Without it, a network flap (Wi-Fi↔cellular, tunnel, walking
  /// between APs, airplane-mode toggle) is only noticed when a heartbeat write fails, and
  /// then recovery waits out the reconnect backoff — up to ~8s of dead socket with no
  /// live delivery. The path monitor fires the instant the OS has a usable route again, so
  /// we can reset backoff and reconnect immediately. Touched only on `pathMonitorQueue`.
  private var nwPathMonitor: NWPathMonitor?
  private let pathMonitorQueue = DispatchQueue(label: "com.vibegram.chat.pathmonitor")
  /// Last path satisfaction we acted on, so we kick a reconnect only on the
  /// unsatisfied→satisfied EDGE, not on every interface reshuffle while already online.
  private var lastNetworkPathSatisfied = true
  private var pendingOutboundDraftsByMessageId: [String: [String: Any]] = [:]
  private var pendingOutboundQueueByChat: [String: [String]] = [:]
  /// Retryable Phoenix push errors replay the same message id. One work item
  /// per message prevents socket-open/chat-join/error triggers from creating
  /// parallel retry loops.
  private var outboundReplayWorkItemsByMessageId: [String: DispatchWorkItem] = [:]
  private var outboundReplayAttemptsByMessageId: [String: Int] = [:]
  private var packetRuntimeStartInFlight = false
  private var activeMediaUploadTasksByMessageId: [String: URLSessionTask] = [:]
  private var canceledOutboundMessageIds = Set<String>()
  private var nativeTypingStateByChatId: [String: Bool] = [:]
  private var peerTypingUserIdsByChatId: [String: Set<String>] = [:]

  /// Lock-guarded copy of the small state the UI polls, so those reads never
  /// queue behind engine work. Published from ``postChangeLocked``; see
  /// ``ChatEngineUIMirror`` for why the direction is inverted.
  let uiMirror = ChatEngineUIMirror()

  /// Decrypted Home previews, so laying out the chat list never waits on a decrypt.
  ///
  /// The decrypt inside it is Swift today only because the FFI does not expose the
  /// core's. `VibeKeyUnwrapper` (`core/vibe_core/src/crypto.rs:222`) and
  /// `envelope.open` (`core/vibe_core/src/envelope.rs:147`) both exist; what is missing
  /// is the UniFFI callback interface and `VibeKeychainKeyUnwrapper` on this side. When
  /// those land, only ``homePreviewTextLocked`` changes — the async shape here is
  /// already what the core requires, because the core has no synchronous read API at all.
  let homePreviewMemo = ChatEngineHomePreviewMemo()
  private var agentProgressByChatId: [String: AgentProgressState] = [:]
  // Last time this chat's transcript showed a RUNNING agent turn (ms). A watch-mirrored
  // session (e.g. one running in the IDE) re-pushes its whole transcript every watch
  // tick, and the bridge's `running` flag flip-flops across those pushes; without a
  // grace window a single non-running push would idle the header to "Start session" and
  // collapse the live row, only to snap back on the next push. We hold the working state
  // for a short grace after the last running push so a transient blip doesn't blank it.
  private var agentTurnRunningAtMsByChatId: [String: Int64] = [:]
  private static let agentTurnRunningGraceMs: Int64 = 12_000
  // Per-session terminal latch: chatId -> (sessionId -> the tail item's content signature
  // at the moment we saw the run finish). Presence of a sessionId key == "this session is
  // settled; do NOT re-light its tail cell from the chat-wide running grace." Needed because
  // the tail cell's streaming/collapsed state is otherwise widened by `agentTurnRunningAtMsByChatId`
  // (which is chat-wide and re-stamped by transcript growth), so a post-finish runtime-card
  // re-push would keep a done turn shimmering ~12s. The stored content sig lets a GENUINE
  // resume (new running content) clear the latch while a stale `running=true` flip-flop with
  // identical content does NOT (no flicker). Cleared on live evidence, set on every terminal.
  private var bridgeSettledSessionSigByChatId: [String: [String: String]] = [:]
  // Signature of the last agent-bridge session transcript applied per chat. The bridge
  // already dedups identical pushes WITHIN a watch (rec.lastSig), but a socket flap resets
  // that and forces a full re-push of unchanged state on every reconnect — which on the
  // client meant re-decrypting all N rows + a reloadData storm every ~50s. When the incoming
  // transcript matches what we already applied we skip that churn (and only re-assert the
  // live header, cheaply). Mirrors the bridge's sig granularity so a genuine change never skips.
  private var lastIngestedBridgeSessionSigByChatId: [String: String] = [:]
  // Stable first-seen timestamp for each live agent stream (keyed chatId -> streamId)
  // so the streaming bubble keeps its position while its text grows.
  private var agentStreamTimestampsByChat: [String: [String: Int64]] = [:]
  // Settled agent replies adopt the list slot of the live stream bubble they replaced,
  // so a multi-agent group keeps "who responded first" order instead of reshuffling
  // every reply to the bottom at settle. Keyed by the persisted messageId; re-applied
  // on every merge so a later history refetch (server copy, server timestamps) cannot
  // bounce the row back down. Bounded FIFO — old entries only matter while the session
  // is alive; after a relaunch server order is authoritative anyway.
  private var agentSettleSlotTsByMessageId: [String: Int64] = [:]
  private var agentSettleSlotTsOrder: [String] = []
  // LAN dual-path: last applied progress sequence per task so cloud frames that
  // arrive later (or earlier) don't double-apply. Keyed "provider:chatId:taskId".
  private var lanProgressSeqByTask: [String: Int] = [:]
  // Accumulated raw CLI lines received over LAN for a task (used to keep the live
  // bubble moving when the cloud socket is mid-flap).
  private var lanProgressLinesByTask: [String: [String]] = [:]
  // Cloud is the AUTHORITATIVE painter of a live turn's visible row: its frames
  // carry the server-reparsed progress nodes (tool/read/edit steps), while the LAN
  // direct mirror only carries lightweight accumulated text (progressNodes: []).
  // If BOTH paint the same row the cell flip-flops between "text, no nodes" and
  // "short text + N nodes" every frame → height oscillation + setRows churn. So we
  // record when cloud last painted each task ("chatId:taskId") and let the LAN
  // mirror paint only as a FALLBACK once cloud has gone silent past the reclaim
  // window (bridge→server relay dead but the direct link still alive).
  private var cloudProgressAtMsByTask: [String: Int64] = [:]
  // A long agent turn goes minutes between cloud frames while the model thinks or
  // runs a tool (observed gaps: 17s, 36s, 53s, 134s). At 8s the LAN mirror reclaimed
  // the row during every one of those gaps and repainted it text-only, so the cell
  // flip-flopped between cloud's node feed and a LAN text blob for the whole run.
  // The window must exceed a normal think/tool gap; cloud genuinely dying still
  // hands over within a minute.
  private static let lanReclaimAfterCloudSilenceMs: Int64 = 60000

  // Canonical row id for each in-flight bridge task (chatId -> taskId -> first-seen
  // streamId). The server's per-connection stream state is NOT durable across a
  // bridge↔server reconnect (a fresh channel process has no memory of the prior
  // stream), so a mid-run reconnect mints a brand-new streamId with a reset buffer for
  // the SAME logical turn. taskId is assigned once at dispatch and stays stable across
  // any reconnect on either side, so every frame for a taskId is folded into the row
  // keyed by the FIRST streamId seen for it — never a second, duplicate row. Survives
  // socket resets by design; only cleared when the task reaches a terminal status.
  private var liveStreamTaskRowIdByChatId: [String: [String: String]] = [:]
  /// Tasks whose live row has already been retired by the settled server message (chatId →
  /// taskId → retiredAtMs). Frames keep arriving for a few seconds after a turn settles —
  /// the bridge's own `done`, a slower cloud relay of a frame the LAN path already
  /// delivered — and by then the taskId→row mapping is gone, so each late frame minted a
  /// BRAND-NEW live row for a turn that is already on screen as a real message. That is the
  /// duplicate reply per agent in a group (every model answering twice until the chat is
  /// reopened, which drops the volatile rows). A retired task never gets a new row again;
  /// updates to a row that still exists are unaffected.
  private var retiredAgentTaskIdsByChatId: [String: [String: Int64]] = [:]
  /// How long a retired taskId keeps refusing new rows. Comfortably longer than the
  /// straggler window (seconds), far shorter than any chance of taskId reuse (task ids are
  /// minted per dispatch from the outgoing messageId, so they are never reused at all).
  private static let retiredAgentTaskTtlMs: Int64 = 15 * 60 * 1000
  /// teamRunId → teamWorkersStatus list when under-hood workers report before the lead cell exists.
  private var pendingTeamWorkersStatusByChatId: [String: [String: [[String: Any]]]] = [:]
  /// teamRunId → worker handle → progress node dicts (for multi-agent sheet).
  private var teamWorkerProgressNodesByChatId: [String: [String: [String: [[String: Any]]]]] = [:]
  // Latest agent-bridge history payload (Claude/Codex/Grok local session logs) per
  // chat, keyed chatId -> payload. The Claude/Codex profile requests it and
  // observes `didChangeNotification` with reason "agentBridgeHistory".
  private var agentBridgeHistoryByChat: [String: [String: Any]] = [:]
  // List and detail replies share the same event. Preserve the last list
  // independently so opening a transcript cannot evict the rows used by the
  // History screen on its next appearance.
  private var agentBridgeHistoryListByChatProvider: [String: [String: Any]] = [:]
  // Request ids for history reads sent over the direct LAN link, awaiting their first LAN
  // reply. If the reply lands the id is removed; a 2s fallback re-issues over cloud so a
  // silent LAN drop never leaves either the History list or a transcript empty. Detail
  // watcher re-pushes keep working through the separate live-ingest request-id mapping.
  private var lanHistoryPendingRequestIds: Set<String> = []
  // History can be requested while the native chat topic is still joining. Keep
  // those wire payloads here and flush them on the successful JOIN instead of
  // rejecting the view with `chat_not_joined` and making it poll.
  private var pendingAgentBridgeHistoryRequestsByChat: [String: [[String: Any]]] = [:]
  // Full-file-open replies from the bridge, keyed requestId -> payload (holds the
  // sealed `agentFileEnc`). Observers watch `didChangeNotification` reason
  // "agentBridgeFile" and read it via `latestAgentBridgeFile(requestId:)`.
  private var agentBridgeFileByRequestId: [String: [String: Any]] = [:]
  // Structured usage-snapshot replies from the bridge, keyed requestId -> payload
  // (holds the plaintext `report`: Claude 5h/7-day buckets + this chat's tokens).
  // Observers watch `didChangeNotification` reason "agentBridgeUsage" and read it
  // via `latestAgentBridgeUsage(requestId:)`.
  private var agentBridgeUsageByRequestId: [String: [String: Any]] = [:]
  /// Latest OK usage report per `chatId|provider` so the Usage sheet can open
  /// pre-filled (prefetch) instead of blank-then-fetch.
  private var agentBridgeUsageByChatProvider: [String: [String: Any]] = [:]
  // Agent-bridge DM row persistence (see storeVolatileBridgeRowsLocked): pending
  // debounced store per chatId + chats already seeded from disk this launch.
  private var volatileBridgeRowsStoreTimers: [String: DispatchWorkItem] = [:]
  private var volatileBridgeRowsRestoredChats: Set<String> = []
  // Pending "ask" requests from the bridge (plan approval / mid-run question),
  // keyed requestId -> payload (holds the sealed `askEnc`). Observers watch
  // `didChangeNotification` reason "agentBridgeAsk" and read it via
  // `latestAgentBridgeAsk(requestId:)`, then reply with `sendAgentBridgeAskResponse`.
  private var agentBridgeAskByRequestId: [String: [String: Any]] = [:]
  // RequestIds already claimed for sheet presentation, so the two surfaces that can both
  // be alive at once (chat bubble view + full-page agent view / profile session view)
  // never double-prompt the same ask. Claimed via `claimAgentBridgeAskPresentation`.
  private var presentedAskRequestIds: Set<String> = []
  // Pending "open this past session into the chat as bubbles" requests, keyed by
  // the detail requestId we pushed -> the target chat/provider. When the matching
  // "detail" reply lands we synthesize its transcript into chat rows.
  private var pendingBridgeSessionIngestByRequestId: [String: (chatId: String, provider: String)] = [:]
  // While an agent session view is open, the bridge live-tails the transcript and
  // re-pushes `history_result` (same requestId) as it grows. Unlike the one-shot
  // map above, this stays registered for the chat so every re-push upserts the
  // (now longer) transcript in place. Cleared when the chat channel closes.
  private var liveBridgeSessionIngestByChatId: [String: (provider: String, sessionId: String, requestId: String)] = [:]
  /// Throttle rearmLiveBridgeSession so open/join/stream don't spam detail reloads.
  private var lastBridgeRearmAtMsByChatId: [String: Int64] = [:]
  /// In-flight loadCurrentAgentBridgeSession (before live-tail registration lands).
  private var currentSessionLoadInflightByChatId: [String: (requestId: String, atMs: Int64)] = [:]
  /// After bridge answers no_current_session, don't re-poll for a while (idle DMs were
  /// spamming the bridge every ~1.5s with no useful work).
  private var noCurrentSessionUntilMsByChatId: [String: Int64] = [:]
  /// In-flight explicit history session load (by chat) — coalesces triple-fire picks.
  private var sessionLoadInflightByChatId: [String: (sessionId: String, requestId: String, atMs: Int64)] = [:]
  private var bridgeSessionPagingByChatId: [String: (
    provider: String, sessionId: String, nextBefore: String?, hasMoreBefore: Bool, loadingOlder: Bool
  )] = [:]
  // The current session's human title ("topic") per chat — the same label the History
  // panel shows for it. Seeded from a History pick's row and refreshed by every detail
  // (re-)push (the bridge derives it from the transcript's ai-title / first user turn),
  // so an IDE-mirrored or resumed session names itself too. The chat header shows it
  // while the session is idle instead of the bare "Start session"; cleared with the
  // live-tail registration on New Chat.
  private var bridgeSessionTopicByChatId: [String: String] = [:]
  private var nativeRecordingStateByChatId: [String: Bool] = [:]
  private var pinnedMessagesByChatId: [String: [[String: Any]]] = [:]
  private var pinnedFetchInFlightChatIds = Set<String>()
  private var historyRowsByChat: [String: [[String: Any]]] = [:]
  private var chatIngestGenerationByChat: [String: Int] = [:]
  private var historyFullyLoadedChats = Set<String>()
  private var historyRowsRestoredFromCacheChats = Set<String>()
  /// Last successful *network* history sync (ms). Restores from SQLite used to force a
  /// full re-fetch on every cold open even when merge was unchanged — that was the
  /// "network remount on every reopen" cost. Soft TTL skips revalidation while fresh.
  private var historyLastNetworkSyncAtByChat: [String: Int] = [:]
  /// Soft revalidation window after a successful network history load.
  private let historyRevalidationTTLMs: Int = 20 * 60 * 1000
  // Run-scoped memo of chats whose SQLite store is known-empty, so repeated restore
  // calls stop re-querying the store. Cleared by any successful store write.
  private var historyRestoreMissChats = Set<String>()
  // Agent/bridge DMs are VOLATILE-per-session: their transcript must be empty on every
  // cold launch and only live for the duration of a running app process. The single
  // reliable cross-launch signal is a durable set of "this chatId is an agent DM",
  // stamped whenever a provider resolves during a run (peer→provider maps are still
  // empty at the cold-launch restore call, so we can't classify from them there). See
  // isAgentDMForPersistenceLocked / markAgentDMChatForPersistenceLocked.
  private var agentDMChatIdsPersisted = Set<String>()
  private var agentDMChatIdsLoaded = false
  // One-shot per-run guard so the durable-era transcript (persisted while agent DMs were
  // durable) is deleted from SQLite exactly once per chat, not on every restore probe.
  private var agentDMStorePurgedChats = Set<String>()
  private static let agentDMChatIdsDefaultsKey = "VibeAgentDMChatIds"
  private var cachedSavedMessagesResponse: [[String: Any]]?
  private var historyLoadingChats = Set<String>()
  private var historyOlderExhaustedChats = Set<String>()
  private var historyLoadingOlderChats = Set<String>()
  private var historyBackfillingChats = Set<String>()
  private var historyBackfillAtMsByChat: [String: Int64] = [:]
  private var historyHasMoreByChat: [String: Bool] = [:]
  private var historyNextCursorByChat: [String: String] = [:]
  private var historyNextCursorBoundaryByChat: [String: (messageId: String, timestampMs: Int64)] =
    [:]
  private let nativeCallSignalDemandMs = 60_000
  private let nativeCallSignalMaxAgeMs = 45_000
  private var liveMessageRowsByChat: [String: [String: [String: Any]]] = [:]
  private var deletedMessageIdsByChat: [String: Set<String>] = [:]
  private var chatPeerUserIdsByChatId: [String: String] = [:]
  private var chatPeerAgentIdsByChatId: [String: String] = [:]
  private var agentIdsByPeerUserId: [String: String] = [:]
  private var friendPublicKeysByUserId: [String: String] = [:]

  /// When MLS provisioning last ran, so a reconnect that rejoins every open
  /// chat does not fire one KeyPackage top-up per chat. See
  /// `ensureMlsProvisionedLocked`.
  private var mlsProvisionedAtMs: Int64 = 0
  private var pendingFriendKeyChatIdsByUserId: [String: Set<String>] = [:]
  private var friendKeyFetchInFlightUserIds = Set<String>()
  private var friendKeyRetryWorkItemsByUserId: [String: DispatchWorkItem] = [:]
  private var configuredUserId: String?
  private var reconnectWorkItem: DispatchWorkItem?
  private var reconnectAttempt: Int = 0
  private var autoReconnectEnabled = true
  private var cachedDecryptPrivateKeyPem: String?
  private var cachedDecryptPrivateKey: SecKey?
  private var cachedDecryptKeyTimestamp: Date?
  private static let fallbackApiBaseURL = "https://api.vibegram.io"
  private let nativeConnectStaleTimeoutMs = 5_000
  private let queuedOutboundVisibleErrorDelayMs = 20_000
  private let outboundReplayDelays: [TimeInterval] = [0.45, 0.9, 1.8, 3.5, 6.0, 10.0]
  /// Oldest a queued bridge-agent draft may be and still auto-send on reconnect.
  /// Past this, replay marks it failed instead — a prompt from minutes ago must
  /// not silently dispatch an agent run the user is no longer watching for.
  private let bridgeQueuedReplayMaxAgeMs = 120_000
  /// Time-to-live for the cached private key in memory (seconds).
  /// After this period of inactivity the key is cleared and re-derived from Keychain on next use.
  private let keyTTL: TimeInterval = 300
  private let chatHistoryCacheKeyPrefix = "vibe.ios.chatHistory.rows.v1"
  private let chatHistoryFetchLimit = 100
  /// How many rows one older-history page pulls out of SQLite.
  ///
  /// Was 60, which is why a conversation that has been on this device for months still
  /// opened like a brand-new one: the restore painted a bounded slice and everything
  /// above it arrived as a stream of 60-row pages, each its own commit, each its own
  /// visible shift, on every single open. The rows were already on disk the whole time —
  /// the pipeline just refused to read them.
  ///
  /// A local SQLite read is not the network. Pulling a thousand rows costs one query and
  /// a JSON decode per row on the engine queue; the reason to page at all was the
  /// renderer's O(mounted) commit, and that is now O(changed).
  private let chatOlderHistoryFetchLimit = 2_000
  /// Rows the restore paints from disk on open.
  ///
  /// Was 120. That single number is what made every open feel cold: 120 rows on screen
  /// and the rest of a three-month transcript dribbling in behind it.
  private let chatHistoryCacheRowLimit = 2_000
  /// Durable SQLite store behind restore/store/clearCachedHistoryRowsLocked.
  /// Only touched on `queue` (the store is not internally synchronized).
  private let messageStore = ChatMessageStore()

  private init() {
    queue.setSpecific(key: queueSpecificKey, value: queueSpecificValue)
    // Arm the lock-free main-thread reads before anything can ask for them.
    //
    // `getStatus` and `liveBridgeSessionId` both answer from a published snapshot on
    // main and only fall through to `queue.sync` when nothing has been published yet.
    // That "yet" is the whole problem: the window where nothing is published is the
    // first seconds after launch, which is also when the queue is decrypting the entire
    // backlog. One device session, one second after launch, ingesting 1,229 rows across
    // four chats, opening one chat:
    //   [engine] main-thread stall … callSite=liveBridgeSessionId ms=151
    //   [engine] main-thread stall … callSite=getChatRows          ms=168
    //   [engine] main-thread stall … callSite=getChatRows          ms=139
    //   [chatopen] chat=saved_messag tap→content=361ms hang=0.87s DEGRADED
    // Publishing the initial (empty/disconnected) snapshots here makes the fast path
    // live from the first read. Empty is the correct answer at t=0 — there are no live
    // bridge sessions and the socket is not up — and every consumer re-reads on the
    // change notification that follows.
    queue.async { [weak self] in
      guard let self else { return }
      self.publishBridgeSessionIds()
      self.publishStatus(self.statusSnapshotLocked())
    }
    // Clear cached private key when the app moves to the background
    // to reduce the window of exposure to memory dump attacks.
    NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.clearCachedKeyOnBackground()
    }
    // Foreground truth for the realtime-demand gate. Deliberately NOT willResignActive /
    // willEnterForeground: resign-active fires for a Control Center pull or a banner, and
    // willEnterForeground does not fire on a cold launch — that pairing would strand the
    // flag false and silently kill the socket. didBecomeActive/didEnterBackground are the
    // pair that always brackets a real background trip.
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      self.queue.async {
        self.appIsForeground = true
        self.ensureNativeTransportIfDemandedLocked(trigger: "app_active")
      }
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
    ) { [weak self] _ in
      self?.queue.async { self?.appIsForeground = false }
    }
    // Reconnect immediately when the app returns to the foreground.
    // Without this, the reconnect backoff timer (up to 8s) plus the
    // WebSocket connect timeout (8s) can delay reconnection by 10-13s.
    NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.reconnectOnForeground()
    }
    startNetworkPathMonitor()
    queue.async { [weak self] in
      self?.restoreOutboundStateLocked()
      // A COLD launch (app was fully terminated) must open every agent DM CLEAN — no
      // stale transcript from the previous run. The on-disk bridge-rows cache exists only
      // to repaint instantly across CONNECTION loss within a single app run, but it also
      // survived full termination, which restored an old session into the DM and was a
      // source of the "history bled into another chatId" family. Purge it once here at
      // process start: the in-memory rows (a still-running app, backgrounded/foregrounded)
      // are untouched, so a warm reopen still shows the ongoing session; a fresh launch
      // finds nothing to restore and starts clean. The cache re-fills within this run.
      self?.purgeVolatileBridgeRowsCacheOnLaunchLocked()
    }
    // Native-owned transport bootstrap:
    // if config already exists (or can be reconstructed from native session),
    // connect without waiting for any JS route lifecycle.
    DispatchQueue.global(qos: .utility).async { [weak self] in
      self?.ensureNativeTransport(trigger: "engine_init")
    }
  }

  private func currentOutboundUserIdLocked() -> String? {
    normalizedString(store.getConfig()["userId"])
  }

  private func bridgeProviderForOutboundDraftLocked(_ draft: [String: Any], fallbackChatId: String? = nil) -> String? {
    let metadata = draft["metadata"] as? [String: Any] ?? [:]
    let chatId =
      normalizedString(draft["chatId"] ?? draft["chat_id"])
      ?? normalizedString(fallbackChatId)
    let peerUserId = normalizedString(draft["peerUserId"] ?? draft["peer_user_id"])
    let peerAgentId =
      normalizedString(
        draft["peerAgentId"] ?? draft["peer_agent_id"] ?? draft["mentionedAgentId"]
          ?? draft["mentioned_agent_id"])
    return bridgeProviderForChatLocked(
      chatId: chatId,
      peerUserId: peerUserId,
      peerAgentId: peerAgentId,
      metadata: metadata
    )
  }

  private func persistOutboundStateLocked() {
    guard let userId = currentOutboundUserIdLocked() else { return }
    let persistedDrafts = pendingOutboundDraftsByMessageId.filter { _, draft in
      guard bridgeProviderForOutboundDraftLocked(draft) == nil else { return false }
      let chatId = normalizedString(draft["chatId"] ?? draft["chat_id"])
      return !isBuiltInAgentChatId(chatId)
    }
    var persistedQueues: [String: [String]] = [:]
    for (chatId, ids) in pendingOutboundQueueByChat {
      if isBuiltInAgentChatId(chatId) || isVolatileBridgeAgentChatLocked(chatId: chatId) {
        continue
      }
      let keptIds = ids.filter { persistedDrafts[$0] != nil }
      if !keptIds.isEmpty { persistedQueues[chatId] = keptIds }
    }
    if persistedDrafts.isEmpty && persistedQueues.isEmpty {
      store.clearOutboundState()
      return
    }
    store.setOutboundState([
      "userId": userId,
      "updatedAt": nowMs(),
      "draftsByMessageId": persistedDrafts,
      "queueByChat": persistedQueues,
    ])
  }

  private func restoreOutboundStateLocked() {
    guard pendingOutboundDraftsByMessageId.isEmpty, pendingOutboundQueueByChat.isEmpty else { return }
    let payload = store.getOutboundState()
    guard !payload.isEmpty else { return }
    guard let storedUserId = normalizedString(payload["userId"]) else { return }
    guard let currentUserId = currentOutboundUserIdLocked(), currentUserId == storedUserId else {
      store.clearOutboundState()
      return
    }

    let rawDrafts = payload["draftsByMessageId"] as? [String: Any] ?? [:]
    var restoredDrafts: [String: [String: Any]] = [:]
    var skippedBridgeDrafts = 0
    for (messageId, value) in rawDrafts {
      if let draft = value as? [String: Any] {
        if bridgeProviderForOutboundDraftLocked(draft) != nil {
          skippedBridgeDrafts += 1
          continue
        }
        let draftChatId = normalizedString(draft["chatId"] ?? draft["chat_id"])
        if isBuiltInAgentChatId(draftChatId) {
          skippedBridgeDrafts += 1
          continue
        }
        restoredDrafts[messageId] = draft
      }
    }

    let rawQueues = payload["queueByChat"] as? [String: Any] ?? [:]
    var restoredQueues: [String: [String]] = [:]
    var healedFanOutDrafts = 0
    for (chatId, value) in rawQueues {
      if let ids = value as? [String], !ids.isEmpty {
        if isBuiltInAgentChatId(chatId) || isVolatileBridgeAgentChatLocked(chatId: chatId) {
          skippedBridgeDrafts += ids.count
          continue
        }
        var keptIds = ids.filter { restoredDrafts[$0] != nil }
        // Heal a fan-out queue rather than restoring it intact.
        //
        // A replay bug fixed on 2026-08-03 could mint a new message per replay pass
        // instead of retrying the queued one; a single send to a peer with an
        // unresolved key reached 3,310 drafts and the watchdog killed the app. Those
        // drafts outlive the fix because they are persisted, so a device that hit it
        // would restore straight back into an unusable state.
        //
        // The oldest are kept because those are the ones the user actually typed; the
        // tail is the duplication. Dropping is safe in the sense that matters — every
        // one of them is unsent, and an unsent duplicate is not a message anyone is
        // waiting on.
        if keptIds.count > Self.maxHealedOutboundQueue {
          let dropped = keptIds.count - Self.maxHealedOutboundQueue
          let survivors = Array(keptIds.prefix(Self.maxHealedOutboundQueue))
          for id in keptIds.dropFirst(Self.maxHealedOutboundQueue) {
            restoredDrafts.removeValue(forKey: id)
            // Resolve the STATUS too, in the same breath as dropping the draft.
            //
            // This used to drop the draft alone, and that is how 512 rows in one chat
            // ended up showing a clock that nothing on earth was going to clear: the
            // message still said `pending`, the thing that makes a pending message
            // eventually send was gone, and no code compared the two. A row is not
            // "queued" because its status string says so — it is queued because a draft
            // exists. When the draft goes, the status is a lie, and it must be corrected
            // here rather than left for someone to notice months later.
            upsertLocalStatusLocked(chatId: chatId, messageId: id, status: "error")
          }
          keptIds = survivors
          healedFanOutDrafts += dropped
          NSLog(
            "[ChatEngine] restoreOutboundState HEALED chatId=%@ dropped=%d kept=%d — queue was a replay fan-out, not a backlog",
            String(chatId.prefix(12)), dropped, keptIds.count)
        }
        if !keptIds.isEmpty { restoredQueues[chatId] = keptIds }
      }
    }

    pendingOutboundDraftsByMessageId = restoredDrafts
    pendingOutboundQueueByChat = restoredQueues
    if healedFanOutDrafts > 0 {
      appendJournalLocked(
        event: "native-outgoing-restore-healed",
        payload: ["dropped": healedFanOutDrafts])
      persistOutboundStateLocked()
    }
    if skippedBridgeDrafts > 0 {
      appendJournalLocked(
        event: "native-bridge-outgoing-restore-skip",
        payload: ["drafts": skippedBridgeDrafts]
      )
      persistOutboundStateLocked()
    }
    if !restoredDrafts.isEmpty || !restoredQueues.isEmpty {
      appendJournalLocked(
        event: "native-outgoing-restored",
        payload: ["drafts": restoredDrafts.count, "chats": restoredQueues.count]
      )
    }
  }

  private func dropQueuedOutboundForChatLocked(chatId: String, reason: String) {
    let ids = pendingOutboundQueueByChat.removeValue(forKey: chatId) ?? []
    guard !ids.isEmpty else { return }
    for id in ids {
      pendingOutboundDraftsByMessageId.removeValue(forKey: id)
      removeMessageIndicesLocked(chatId: chatId, messageId: id)
      markLiveMessageDeletedLocked(chatId: chatId, messageId: id)
    }
    persistOutboundStateLocked()
    appendJournalLocked(
      event: "native-bridge-outgoing-drop-queue",
      payload: ["chatId": chatId, "count": ids.count, "reason": reason]
    )
    postChatDeltaLocked(
      chatId: chatId, inserted: [], updated: [], deleted: ids, source: "delete")
  }

  /// A bridge send that may already have reached the wire failed (ack timeout,
  /// socket drop mid-flight, server rejection). Keep the user's bubble with an
  /// error badge — tap-to-retry re-arms the same id — instead of deleting their
  /// text, and never auto-replay: re-dispatching an agent prompt the server may
  /// have already run must stay a user decision.
  private func markVolatileBridgeSendErrorLocked(
    chatId: String,
    messageId: String,
    reason: String,
    provider: String?
  ) {
    // Leave the queue (no auto-replay) but KEEP the draft: tap-to-retry goes
    // through retryOutgoingMessage, which needs it. A draft outside the queue
    // never auto-sends, and bridge drafts are never persisted to disk.
    removeQueuedOutboundDraftLocked(chatId: chatId, messageId: messageId, dropDraft: false)
    nativePendingMessagePushRefs = nativePendingMessagePushRefs.filter { _, pending in
      !(pending.chatId == chatId && pending.messageId == messageId)
    }
    setLiveMessageUploadProgressLocked(chatId: chatId, messageId: messageId, progress: nil)
    upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
    appendJournalLocked(
      event: "native-bridge-send-failed",
      payload: [
        "chatId": chatId,
        "messageId": messageId,
        "provider": provider ?? "",
        "reason": reason,
        "rowKept": true,
      ]
    )
    let displayProvider = provider.map { $0.capitalized } ?? "Bridge"
    let snapshot = statusSnapshotLocked()
    postChangeLocked(
      reason: "messageStatusChanged",
      userInfo: [
        "chatId": chatId,
        "messageId": messageId,
        "status": "error",
        "state": snapshot,
      ])
    postChangeLocked(
      reason: "engineError",
      userInfo: [
        "chatId": chatId,
        "messageId": messageId,
        "category": "bridgeSendFailed",
        "provider": provider ?? "",
        "reason": reason,
        "error": "\(displayProvider) message did not reach the bridge. Tap it to retry.",
        "state": snapshot,
      ])
  }

  private func clearCachedKeyOnBackground() {
    queue.async {
      self.cachedDecryptPrivateKey = nil
      self.cachedDecryptPrivateKeyPem = nil
      self.cachedDecryptKeyTimestamp = nil
    }
  }

  private func reconnectOnForeground() {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      // Reset backoff and cancel pending reconnect timer so we connect
      // immediately instead of waiting for the next backoff tick.
      self.syncOnQueue {
        self.reconnectAttempt = 0
        self.cancelReconnectLocked()
        self.appendJournalLocked(
          event: "foreground-reconnect",
          payload: ["state": self.normalizedString(self.state["state"]) ?? "unknown"])
      }
      // ensureNativeTransport checks connected/connecting state internally
      // and only initiates a connection when actually needed.
      self.ensureNativeTransport(trigger: "app_foreground")
    }
  }

  /// Watch the OS network path and reconnect the moment a usable route returns.
  /// This is the "native helper for the network issue": a flap (Wi-Fi↔cellular,
  /// VPN toggle, roaming between APs, airplane mode) otherwise sits undetected until a
  /// heartbeat write fails, then waits out the reconnect backoff. The monitor closes that
  /// gap — on the unsatisfied→satisfied edge we reset backoff and kick a connect at once.
  private func startNetworkPathMonitor() {
    guard #available(iOS 13.0, *) else { return }
    guard nwPathMonitor == nil else { return }
    let monitor = NWPathMonitor()
    nwPathMonitor = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      self?.handleNetworkPathUpdate(satisfied: path.status == .satisfied)
    }
    monitor.start(queue: pathMonitorQueue)
  }

  /// Called on `pathMonitorQueue` for every path change; hops to the engine queue to touch
  /// state. Acts only on the satisfaction EDGE so an interface reshuffle while already online
  /// (a Wi-Fi handoff that never dropped the route) does not thrash reconnects.
  private func handleNetworkPathUpdate(satisfied: Bool) {
    queue.async { [weak self] in
      guard let self else { return }
      let previouslySatisfied = self.lastNetworkPathSatisfied
      guard satisfied != previouslySatisfied else { return }
      self.lastNetworkPathSatisfied = satisfied

      if !satisfied {
        // Route just went away. A URLSession WebSocket does not survive a path loss, but the
        // failure only surfaces when a read/write finally times out — seconds later — during
        // which `state` still reads "connected" and would make the restore-edge reconnect
        // below bail out. Mark the socket down NOW, reusing the transport's own network-error
        // teardown so in-flight sends are requeued for replay (never lost) and the restore
        // edge always finds clean state to reconnect from. Skip if we already know we're down.
        let currentState = self.normalizedString(self.state["state"])?.lowercased() ?? ""
        let liveish =
          (self.state["connected"] as? Bool) == true
          || currentState == "native-socket-open"
          || currentState == "connecting-native-presence"
        NSLog("[ChatEngine] network path lost — liveSocket=%@", liveish ? "Y" : "N")
        if liveish {
          self.handleNativeSocketError("network path unsatisfied")
        }
        return
      }

      // Route restored. The old socket is stale; reconnect on THIS tick rather than waiting
      // out the backoff. Reset attempts, drop any pending timer, and kick a connect. If the
      // route-loss teardown above already ran, state is disconnected and this reconnects; if
      // it never ran (a brief blip that stayed "connected"), ensureNativeTransport no-ops.
      let connected = (self.state["connected"] as? Bool) == true
      NSLog(
        "[ChatEngine] network path restored — kicking reconnect (wasConnected=%@)",
        connected ? "Y" : "N")
      self.appendJournalLocked(event: "network-path-restored", payload: ["connected": connected])
      self.reconnectAttempt = 0
      self.cancelReconnectLocked()
      self.ensureNativeTransportIfDemandedLocked(trigger: "network_restored")
    }
  }

  private func loadNativeAuthSessionFromKeychain() -> [String: Any]? {
    // Expo SecureStore stores items with:
    //   kSecAttrService  = "<keychainService>:no-auth"  (default keychainService = "app")
    //   kSecAttrAccount  = Data(key.utf8)                (NOT a plain String)
    //   kSecAttrGeneric  = Data(key.utf8)
    let keyData = Data("user_session_v2".utf8)

    // Try Expo SecureStore format first (with service suffix)
    for service in ["app:no-auth", "app:auth", "app"] {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: keyData,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: AnyObject?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecSuccess, let data = result as? Data,
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      {
        return json
      }
    }

    // Fallback: try legacy format without service (in case an older build stored it)
    let legacyQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: "user_session_v2",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data {
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    return nil
  }

  private func hasNativeSocketConfigLocked() -> Bool {
    let config = store.getConfig()
    let transportMode = transportModeLocked(config: config)
    let socketUrl = normalizedString(config["socketUrl"] ?? config["url"])
    let userId = normalizedString(config["userId"])
    let token = normalizedString(config["authToken"] ?? config["token"])
    if transportMode == "offline" {
      return userId != nil && token != nil
    }
    if transportMode == "bridge_text" {
      return bridgeBaseURLLocked(config: config) != nil && userId != nil && token != nil
    }
    // A UUID is an identity, not a login token. Older bootstrap code stored userId as
    // the token fallback; that makes the WebSocket upgrade fail while HTTP/LAN still
    // work, creating an endless false "Connecting" loop. Force a keychain repair.
    return socketUrl != nil && userId != nil && token != nil && token != userId
  }

  @discardableResult
  private func bootstrapConfigFromNativeSessionIfNeededLocked(trigger: String) -> Bool {
    if hasNativeSocketConfigLocked() { return true }

    let existing = store.getConfig()
    let nativeCallConfig = VibeNativeCallStore.shared.getNativeEngineConfig()
    let session = loadNativeAuthSessionFromKeychain()

    guard
      let userId = normalizedString(
        existing["userId"] ?? nativeCallConfig["userId"] ?? session?["userId"])
    else {
      appendJournalLocked(
        event: "native-config-bootstrap-skip",
        payload: [
          "trigger": trigger,
          "reason": "missing_user_id",
        ])
      return false
    }

    let apiBase =
      normalizedString(
        existing["apiBaseUrl"] ?? existing["baseUrl"] ?? nativeCallConfig["baseUrl"]
          ?? nativeCallConfig["apiBaseUrl"])
      ?? Self.fallbackApiBaseURL
    let socketUrl =
      normalizedString(existing["socketUrl"] ?? existing["url"] ?? nativeCallConfig["socketUrl"])
      ?? (apiBase.replacingOccurrences(of: "^http", with: "ws", options: .regularExpression)
        + "/socket")
    let token = [
      normalizedString(session?["loginToken"]),
      normalizedString(nativeCallConfig["authToken"]),
      normalizedString(existing["authToken"] ?? existing["token"]),
    ].compactMap { $0 }.first { $0 != userId && $0.lowercased() != "undefined" }
    guard let token else {
      appendJournalLocked(
        event: "native-config-bootstrap-skip",
        payload: ["trigger": trigger, "reason": "missing_login_token"])
      return false
    }

    var merged = existing
    merged["apiBaseUrl"] = apiBase
    merged["socketUrl"] = socketUrl
    merged["authToken"] = token
    merged["userId"] = userId
    if normalizedString(existing["userChannelTopic"]) == nil {
      merged["userChannelTopic"] = "user:\(userId)"
    }
    if normalizedString(existing["privateKeyPem"] ?? existing["privateKey"]) == nil,
      let privateKeyPem = normalizedString(session?["privateKeyPem"] ?? session?["privateKey"])
    {
      merged["privateKeyPem"] = privateKeyPem
    }
    if normalizedString(existing["publicKeyPem"] ?? existing["publicKey"]) == nil,
      let publicKeyPem = normalizedString(session?["publicKeyPem"] ?? session?["publicKey"])
    {
      merged["publicKeyPem"] = publicKeyPem
    }

    store.setConfig(merged)
    state["state"] = "configured-native-bootstrap"
    state["updatedAt"] = nowMs()
    state["configuredAt"] = state["updatedAt"]
    state["configKeys"] = Array(merged.keys).sorted()
    state["note"] = "ChatEngine configured from native session"
    state["presenceSource"] = nativePresenceActive ? "native" : "shadow"
    appendJournalLocked(
      event: "native-config-bootstrap",
      payload: [
        "trigger": trigger,
        "hasSocketUrl": normalizedString(merged["socketUrl"] ?? merged["url"]) != nil,
        "hasUserId": normalizedString(merged["userId"]) != nil,
        "hasToken": normalizedString(merged["authToken"] ?? merged["token"]) != nil,
        "hasPrivateKey": normalizedString(merged["privateKeyPem"] ?? merged["privateKey"]) != nil,
        "hasPublicKey": normalizedString(merged["publicKeyPem"] ?? merged["publicKey"]) != nil,
      ])
    return true
  }

  /// Queue-side connect kick: `ensureNativeTransport` hops queues itself, so a caller
  /// already on the engine queue uses this to avoid re-entering it synchronously.
  private func ensureNativeTransportIfDemandedLocked(trigger: String) {
    guard hasRealtimeDemandLocked() else { return }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      self?.ensureNativeTransport(trigger: trigger)
    }
  }

  private func ensureNativeTransport(trigger: String) {
    guard #available(iOS 13.0, *) else { return }
    var clientToDisconnect: ChatRealtimeTransport?
    let shouldConnect = syncOnQueue {
      if !hasRealtimeDemandLocked() {
        return false
      }
      autoReconnectEnabled = true
      let connected = (state["connected"] as? Bool) == true
      var currentState = normalizedString(state["state"])?.lowercased() ?? ""
      let now = nowMs()
      let updatedAt = parseLongValue(state["updatedAt"]) ?? 0
      let stateAge = updatedAt > 0 ? now - Int(updatedAt) : -1
      if currentState == "connecting-native-presence" && stateAge >= nativeConnectStaleTimeoutMs {
        NSLog(
          "[ChatEngine] ensureNativeTransport resetting stale connect trigger=%@ stateAgeMs=%d hasClient=%@",
          trigger,
          stateAge,
          phoenixClient == nil ? "N" : "Y"
        )
        clientToDisconnect = phoenixClient
        phoenixClient = nil
        nativeSocketSignature = nil
        nativePresenceActive = false
        nativeUserJoinRef = nil
        nativeUserTopic = nil
        nativeChatJoinRefsByRef.removeAll()
        nativeJoinedChatIds.removeAll()
        nativePendingMessagePushRefs.removeAll()
        nativePendingEditPushRefs.removeAll()
        nativePendingDeletePushRefs.removeAll()
        nativePendingCallPushRefs.removeAll()
        nativeTypingStateByChatId.removeAll()
        peerTypingUserIdsByChatId.removeAll()
        agentProgressByChatId.removeAll()
        nativeRecordingStateByChatId.removeAll()
        pinnedFetchInFlightChatIds.removeAll()
        historyLoadingChats.removeAll()
        state["connected"] = false
        state["state"] = "native-connect-stale"
        state["updatedAt"] = now
        state["presenceSource"] = "shadow"
        appendJournalLocked(
          event: "native-connect-stale-reset",
          payload: ["trigger": trigger, "stateAgeMs": stateAge]
        )
        postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": statusSnapshotLocked()])
        currentState = "native-connect-stale"
      }
      if connected || currentState == "connecting-native-presence"
        || currentState == "native-socket-open"
      {
        return false
      }
      if transportModeLocked() == "offline" {
        return false
      }
      return bootstrapConfigFromNativeSessionIfNeededLocked(trigger: trigger)
    }
    clientToDisconnect?.disconnect()
    guard shouldConnect else { return }
    _ = connectNativePresence()
  }

  @discardableResult
  private func ensurePacketRuntimeAsync(trigger: String) -> Bool {
    var shouldStart = false
    var handled = false
    let configPayload = syncOnQueue { () -> [String: Any]? in
      let config = store.getConfig()
      if transportModeLocked(config: config) == "packet_mesh" && packetProxyPortLocked(config: config) == nil {
        handled = true
        if !packetRuntimeStartInFlight {
          packetRuntimeStartInFlight = true
          shouldStart = true
          state["state"] = "starting-packet-mesh"
          state["connected"] = false
          state["updatedAt"] = nowMs()
          state["transportMode"] = "packet_mesh"
          state["note"] = "Starting Packet mesh for native chat transport"
          appendJournalLocked(event: "packet-runtime-start", payload: ["trigger": trigger])
          postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": statusSnapshotLocked()])
        }
        return config
      }
      return nil
    }

    guard handled else { return false }
    guard shouldStart else { return true }
    guard let configPayload, let config = AppSessionConfig(payload: configPayload) else {
      queue.async {
        self.packetRuntimeStartInFlight = false
        self.appendJournalLocked(
          event: "packet-runtime-start-skip",
          payload: ["trigger": trigger, "reason": "missing_native_auth_config"]
        )
      }
      return true
    }

    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      do {
        let snapshot = try await PacketRuntime.shared.ensureStarted(config: config)
        self.queue.async {
          self.packetRuntimeStartInFlight = false
          self.state["state"] = "packet-runtime-ready"
          self.state["connected"] = false
          self.state["updatedAt"] = self.nowMs()
          self.state["transportMode"] = "packet_mesh"
          self.state["note"] = "Packet mesh ready for native chat transport"
          self.state["packetProxyPort"] = snapshot.proxyPort
          self.appendJournalLocked(
            event: "packet-runtime-ready",
            payload: [
              "trigger": trigger,
              "proxyHost": snapshot.proxyHost,
              "proxyPort": snapshot.proxyPort,
              "activeBridgeId": snapshot.activeBridgeID as Any,
            ]
          )
          self.postChangeLocked(
            reason: "connectionStateChanged",
            userInfo: ["state": self.statusSnapshotLocked()]
          )
        }
        self.ensureNativeTransport(trigger: "packet_runtime_ready:\(trigger)")
        let queuedChatIds = self.syncOnQueue { Array(self.pendingOutboundQueueByChat.keys) }
        for chatId in queuedChatIds {
          self.queue.async {
            self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "packet_runtime_ready")
          }
        }
      } catch {
        let errorText = error.localizedDescription
        NSLog("[ChatEngine] Packet runtime start failed trigger=%@ error=%@", trigger, errorText)
        self.store.updateConfig([
          "transportMode": "direct",
          "packetStatus": "failed",
          "packetProxyPort": nil,
          "packetLastError": errorText,
        ])
        self.queue.async {
          self.packetRuntimeStartInFlight = false
          self.state["state"] = "packet-runtime-direct-fallback"
          self.state["connected"] = false
          self.state["updatedAt"] = self.nowMs()
          self.state["transportMode"] = "direct"
          self.state["note"] = "Packet mesh failed; falling back to direct native chat transport"
          self.appendJournalLocked(
            event: "packet-runtime-direct-fallback",
            payload: ["trigger": trigger, "error": String(errorText.prefix(180))]
          )
          self.postChangeLocked(
            reason: "connectionStateChanged",
            userInfo: ["state": self.statusSnapshotLocked()]
          )
        }
        self.ensureNativeTransport(trigger: "packet_runtime_direct_fallback:\(trigger)")
      }
    }
    return true
  }

  private func chatNeedsRealtimeLocked(_ rawChatId: String?) -> Bool {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else {
      return true
    }
    return chatId != "saved_messages" && !isBuiltInAgentChatId(chatId)
  }

  private func isBuiltInAgentChatId(_ rawChatId: String?) -> Bool {
    guard let chatId = normalizedString(rawChatId)?.lowercased() else { return false }
    switch chatId {
    case "vibe_agent", "vibeagent", "vibe-ai", "vibe_ai":
      return true
    default:
      return false
    }
  }

  private func hasRealtimeDemandLocked() -> Bool {
    // A foregrounded, signed-in app IS realtime demand — this is the whole point of the
    // user channel. Demand used to require a bound CHAT surface, so sitting on Home meant
    // no socket at all: measured on device, the socket opened 25s after launch and only
    // because a chat was opened. Until then nothing could be delivered, which is exactly
    // "a new message doesn't show in the list until I open the chat". Home is the surface
    // that most needs the live feed, and it was the one surface that never asked for it.
    if appIsForeground, normalizedString(getConfigValueLocked("userId")) != nil {
      return true
    }
    if nativeUserChannelDemandUntilMs > nowMs() {
      return true
    }
    if pendingOutboundQueueByChat.keys.contains(where: { chatNeedsRealtimeLocked($0) }) {
      return true
    }
    if openChatChannels.keys.contains(where: { chatNeedsRealtimeLocked($0) }) {
      return true
    }
    if surfaceBindings.values.contains(where: { binding in
      chatNeedsRealtimeLocked(binding.chatId)
    }) {
      return true
    }
    return false
  }

  private func cancelReconnectLocked() {
    reconnectWorkItem?.cancel()
    reconnectWorkItem = nil
  }

  private func reconnectDelayLocked() -> TimeInterval {
    // Keep retries fast when we have pending outbound work, otherwise back off more.
    let hasPendingOutbound = !pendingOutboundQueueByChat.isEmpty
    let sequence: [TimeInterval] =
      hasPendingOutbound
      ? [0.15, 0.35, 0.75, 1.5, 2.5, 4.0]
      : [0.35, 0.9, 2.0, 4.0, 6.0, 8.0]
    let index = min(max(0, reconnectAttempt), sequence.count - 1)
    return sequence[index]
  }

  private func scheduleReconnectLocked(reason: String) {
    guard #available(iOS 13.0, *) else { return }
    guard autoReconnectEnabled else { return }
    guard hasRealtimeDemandLocked() else { return }
    guard reconnectWorkItem == nil else { return }
    let connected = (state["connected"] as? Bool) == true
    let currentState = normalizedString(state["state"])?.lowercased() ?? ""
    guard !connected, currentState != "connecting-native-presence",
      currentState != "native-socket-open"
    else { return }

    let delay = reconnectDelayLocked()
    appendJournalLocked(
      event: "native-reconnect-scheduled",
      payload: [
        "reason": reason,
        "attempt": reconnectAttempt + 1,
        "delayMs": Int(delay * 1000),
      ])

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.queue.async {
        self.reconnectWorkItem = nil
        guard self.autoReconnectEnabled else { return }
        let connected = (self.state["connected"] as? Bool) == true
        let currentState = self.normalizedString(self.state["state"])?.lowercased() ?? ""
        guard !connected, currentState != "connecting-native-presence",
          currentState != "native-socket-open"
        else {
          self.reconnectAttempt = 0
          return
        }
        self.reconnectAttempt = min(self.reconnectAttempt + 1, 64)
        self.appendJournalLocked(
          event: "native-reconnect-attempt",
          payload: [
            "attempt": self.reconnectAttempt,
            "state": currentState,
          ])
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "auto_reconnect")
        }
      }
    }

    reconnectWorkItem = workItem
    queue.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  func configure(_ payload: [String: Any]) -> [String: Any] {
    let existingPayload = store.getConfig()
    let nextUserId = normalizedString(payload["userId"])
    let existingUserId = normalizedString(existingPayload["userId"])
    let mergedPayload: [String: Any] =
      !existingPayload.isEmpty && (existingUserId == nil || existingUserId == nextUserId)
      ? existingPayload.merging(payload) { _, new in new }
      : payload
    store.setConfig(mergedPayload)
    let now = nowMs()
    let snapshot = syncOnQueue {
      if configuredUserId != nil, configuredUserId != nextUserId {
        outboundReplayWorkItemsByMessageId.values.forEach { $0.cancel() }
        outboundReplayWorkItemsByMessageId.removeAll()
        outboundReplayAttemptsByMessageId.removeAll()
        pendingOutboundDraftsByMessageId.removeAll()
        pendingOutboundQueueByChat.removeAll()
        store.clearOutboundState()
      }
      configuredUserId = nextUserId
      restoreOutboundStateLocked()
      state["state"] = "configured"
      state["updatedAt"] = now
      state["configuredAt"] = now
      state["configKeys"] = Array(mergedPayload.keys).sorted()
      state["note"] =
        "ChatEngine configured (native Phoenix presence enabled, shadow fallback active)"
      state["presenceSource"] = nativePresenceActive ? "native" : "shadow"
      let snapshot = statusSnapshotLocked()
      appendJournalLocked(event: "configure", payload: ["keys": Array(mergedPayload.keys).sorted()])
      for chatId in openChatChannels.keys {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
      }
      postChangeLocked(reason: "configure", userInfo: ["state": snapshot])
      return snapshot
    }
    ensureNativeTransport(trigger: "configure")
    return snapshot
  }

  /// Last status published, readable without entering the engine queue.
  private let publishedStatusLock = NSLock()
  private var publishedStatus: [String: Any]?

  /// Connection/transport status. Same contract as `getChatRows`: the main thread reads
  /// the last published snapshot and asks for a refresh rather than waiting for one.
  ///
  /// This is a pure read of a dictionary the engine already maintains, and yet it blocked
  /// the main thread for 299ms in a device session — not because building the snapshot is
  /// slow, but because getting *to* it means queueing behind a send or a decrypt.
  /// `ChatsViewModel` polls it while Home is on screen, so that cost lands squarely on
  /// scrolling.
  func getStatus() -> [String: Any] {
    if Thread.isMainThread {
      publishedStatusLock.lock()
      let published = publishedStatus
      publishedStatusLock.unlock()
      if let published {
        queue.async { [weak self] in
          guard let self else { return }
          self.publishStatus(self.statusSnapshotLocked())
        }
        return published
      }
    }
    return syncOnQueue {
      let snapshot = statusSnapshotLocked()
      publishStatus(snapshot)
      return snapshot
    }
  }

  func getTransportStatus() -> [String: Any] {
    getStatus()
  }

  /// Records the current status for the lock-free read above. Engine queue only.
  private func publishStatus(_ snapshot: [String: Any]) {
    publishedStatusLock.lock()
    publishedStatus = snapshot
    publishedStatusLock.unlock()
  }

  func resolveURLForOpen(_ raw: String?) -> String? {
    syncOnQueue { resolveURLForOpenLocked(raw) }
  }

  func authorizationHeaderForAPI() -> String? {
    syncOnQueue {
      guard let token = authHeaderTokenLocked(), !token.isEmpty else { return nil }
      return "Bearer \(token)"
    }
  }

  func decryptMediaDataIfNeeded(_ data: Data, mediaKey: String?) -> Data? {
    let trimmedKey = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmedKey.isEmpty else { return data }
    return try? chatEngineDecryptMediaData(data, keyBase64: trimmedKey)
  }

  func isUserOnline(userId: String?) -> Bool {
    guard let normalized = normalizedUpper(userId), !normalized.isEmpty else { return false }
    // Mirror first — presence is polled from header refresh, which runs on the
    // main thread during scroll. See `ChatEngineUIMirror`.
    if let published = uiMirror.isUserOnline(userId: normalized) { return published }
    return syncOnQueue { onlineUsers.contains(normalized) }
  }

  func lastSeenTimestampMs(userId: String?) -> Int64? {
    guard let normalized = normalizedUpper(userId), !normalized.isEmpty else { return nil }
    if let published = uiMirror.lastSeenTimestampMs(userId: normalized) { return published }
    return syncOnQueue { lastSeenByUserId[normalized] }
  }

  func connect() -> [String: Any] {
    if #available(iOS 13.0, *) {
      syncOnQueue {
        autoReconnectEnabled = true
        cancelReconnectLocked()
      }
      return connectNativePresence()
    }
    let now = nowMs()
    return syncOnQueue {
      state["connected"] = true
      state["state"] = "connected-shadow"
      state["updatedAt"] = now
      state["note"] = "ChatEngine shadow connect (native WebSocket unavailable on this iOS version)"
      appendJournalLocked(event: "connect-shadow", payload: [:])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
      return snapshot
    }
  }

  func disconnect() -> [String: Any] {
    let clientToClose: ChatRealtimeTransport? = syncOnQueue {
      let now = nowMs()
      autoReconnectEnabled = false
      cancelReconnectLocked()
      reconnectAttempt = 0
      let client = phoenixClient
      phoenixClient = nil
      nativePresenceActive = false
      nativeUserJoinRef = nil
      nativeUserTopic = nil
      nativeChatJoinRefsByRef.removeAll()
      nativeJoinedChatIds.removeAll()
      nativePendingMessagePushRefs.removeAll()
      nativePendingEditPushRefs.removeAll()
      nativePendingDeletePushRefs.removeAll()
      nativePendingCallSignals.removeAll()
      nativePendingCallPushRefs.removeAll()
      nativeUserChannelDemandUntilMs = 0
      outboundReplayWorkItemsByMessageId.values.forEach { $0.cancel() }
      outboundReplayWorkItemsByMessageId.removeAll()
      outboundReplayAttemptsByMessageId.removeAll()
      pendingOutboundDraftsByMessageId.removeAll()
      pendingOutboundQueueByChat.removeAll()
      onlineUsers.removeAll()
      lastSeenByUserId.removeAll()
      surfaceBindings.removeAll()
      openChatChannels.removeAll()
      receiptIndex.removeAll()
      localStatusIndex.removeAll()
      nativeTypingStateByChatId.removeAll()
      peerTypingUserIdsByChatId.removeAll()
      agentProgressByChatId.removeAll()
      agentBridgeHistoryByChat.removeAll()
      agentBridgeHistoryListByChatProvider.removeAll()
      pendingAgentBridgeHistoryRequestsByChat.removeAll()
      nativeRecordingStateByChatId.removeAll()
      pinnedMessagesByChatId.removeAll()
      pinnedFetchInFlightChatIds.removeAll()
      liveMessageRowsByChat.removeAll()
      deletedMessageIdsByChat.removeAll()
      historyRowsByChat.removeAll()
      historyFullyLoadedChats.removeAll()
      historyRowsRestoredFromCacheChats.removeAll()
      historyLoadingChats.removeAll()
      historyOlderExhaustedChats.removeAll()
      historyLoadingOlderChats.removeAll()
      historyHasMoreByChat.removeAll()
      historyNextCursorByChat.removeAll()
      historyNextCursorBoundaryByChat.removeAll()
      cachedSavedMessagesResponse = nil
      chatPeerUserIdsByChatId.removeAll()
      friendPublicKeysByUserId.removeAll()
      pendingFriendKeyChatIdsByUserId.removeAll()
      friendKeyFetchInFlightUserIds.removeAll()
      for (_, item) in friendKeyRetryWorkItemsByUserId {
        item.cancel()
      }
      friendKeyRetryWorkItemsByUserId.removeAll()
      configuredUserId = nil
      // Clear cached private key on disconnect to reduce memory exposure.
      cachedDecryptPrivateKey = nil
      cachedDecryptPrivateKeyPem = nil
      cachedDecryptKeyTimestamp = nil
      state["connected"] = false
      state["state"] = "disconnected"
      state["updatedAt"] = now
      state["presenceSource"] = "shadow"
      appendJournalLocked(event: "disconnect", payload: [:])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
      return client
    }
    if #available(iOS 13.0, *) {
      clientToClose?.disconnect()
    }
    return getStatus()
  }

  func bindSurface(_ payload: [String: Any]) -> [String: Any] {
    let surfaceId =
      normalizedString(payload["surfaceId"]) ?? normalizedString(payload["engineSurfaceId"]) ?? ""
    let chatId = normalizedString(payload["chatId"])
    let myUserId = normalizedUpper(payload["myUserId"])
    let peerUserId = normalizedUpper(payload["peerUserId"])
    let peerAgentId =
      normalizedString(payload["peerAgentId"] ?? payload["peer_agent_id"])
    guard !surfaceId.isEmpty else { return getStatus() }

    let result = syncOnQueue { () -> (snapshot: [String: Any], shouldEnsureTransport: Bool) in
      let nextBinding = SurfaceBinding(
        surfaceId: surfaceId,
        chatId: chatId,
        myUserId: myUserId,
        peerUserId: peerUserId,
        peerAgentId: peerAgentId
      )
      let previousBinding = surfaceBindings[surfaceId]
      guard previousBinding != nextBinding else {
        return (statusSnapshotLocked(), false)
      }

      surfaceBindings[surfaceId] = nextBinding
      let peerBindingChanged =
        previousBinding?.chatId != nextBinding.chatId
        || previousBinding?.peerUserId != nextBinding.peerUserId
        || previousBinding?.peerAgentId != nextBinding.peerAgentId
      if peerBindingChanged, let chatId, !chatId.isEmpty, let peerUserId, !peerUserId.isEmpty {
        chatPeerUserIdsByChatId[chatId] = peerUserId
        if let peerAgentId, !peerAgentId.isEmpty {
          chatPeerAgentIdsByChatId[chatId] = peerAgentId
          agentIdsByPeerUserId[peerUserId] = peerAgentId
        }
        scheduleFriendPublicKeyFetchLocked(
          chatId: chatId,
          peerUserIdHint: peerUserId,
          trigger: "bind_surface"
        )
        scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "surface_peer_bound")
      }
      state["updatedAt"] = nowMs()
      appendJournalLocked(
        event: "bind-surface",
        payload: [
          "surfaceId": surfaceId,
          "chatId": chatId as Any,
          "peerUserId": peerUserId as Any,
          "peerAgentId": peerAgentId as Any,
        ])
      let snapshot = statusSnapshotLocked()
      if peerBindingChanged {
        postChangeLocked(reason: "surfaceBindingChanged", userInfo: ["surfaceId": surfaceId])
      }
      return (snapshot, peerBindingChanged)
    }
    if result.shouldEnsureTransport {
      ensureNativeTransport(trigger: "bind_surface")
    }
    return result.snapshot
  }

  func unbindSurface(_ payload: [String: Any]) -> [String: Any] {
    let surfaceId =
      normalizedString(payload["surfaceId"]) ?? normalizedString(payload["engineSurfaceId"]) ?? ""
    guard !surfaceId.isEmpty else { return getStatus() }
    return syncOnQueue {
      surfaceBindings.removeValue(forKey: surfaceId)
      state["updatedAt"] = nowMs()
      appendJournalLocked(event: "unbind-surface", payload: ["surfaceId": surfaceId])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "surfaceBindingChanged", userInfo: ["surfaceId": surfaceId])
      return snapshot
    }
  }

  func openChatChannel(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let peerUserIdHint = normalizedUpper(payload["peerUserId"] ?? payload["peer_user_id"])
    if isBuiltInAgentChatId(chatId) {
      return syncOnQueue {
        if let chatId {
          openChatChannels.removeValue(forKey: chatId)
          nativeJoinedChatIds.remove(chatId)
          historyLoadingChats.remove(chatId)
          appendJournalLocked(
            event: "open-chat-channel-skip",
            payload: ["chatId": chatId, "reason": "built_in_agent_surface"]
          )
          VibeDebugLog.log(
            "[ChatEngine][Route] skip normal chat channel for built-in agent chatId=%@",
            chatId
          )
        }
        return statusSnapshotLocked()
      }
    }
    let snapshot = syncOnQueue {
      if let chatId, !chatId.isEmpty {
        if let peerUserIdHint {
          chatPeerUserIdsByChatId[chatId] = peerUserIdHint
          if !isVolatileBridgeAgentChatLocked(chatId: chatId, peerUserId: peerUserIdHint) {
            scheduleFriendPublicKeyFetchLocked(
              chatId: chatId,
              peerUserIdHint: peerUserIdHint,
              trigger: "open_chat_channel"
            )
          }
        }
        let nextCount = (openChatChannels[chatId] ?? 0) + 1
        openChatChannels[chatId] = nextCount
        VibeDebugLog.log(
          "[ChatEngine][Route] openChatChannel chatId=%@ peerUserId=%@ count=%d savedMessages=%@",
          chatId,
          peerUserIdHint ?? "",
          nextCount,
          chatId == "saved_messages" ? "Y" : "N"
        )
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
      }
      appendJournalLocked(event: "open-chat-channel", payload: payload)
      state["updatedAt"] = nowMs()
      let snapshot = statusSnapshotLocked()
      return snapshot
    }
    ensureNativeTransport(trigger: "open_chat_channel")
    return snapshot
  }

  func closeChatChannel(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    return syncOnQueue {
      if let chatId, !chatId.isEmpty, let current = openChatChannels[chatId] {
        if current <= 1 {
          openChatChannels.removeValue(forKey: chatId)
          nativeJoinedChatIds.remove(chatId)
          peerTypingUserIdsByChatId.removeValue(forKey: chatId)
          agentProgressByChatId.removeValue(forKey: chatId)
          // Intentionally KEEP liveBridgeSessionIngestByChatId[chatId] here: the chat
          // "remembers" the bridge session it had loaded for as long as the app is alive.
          // Leaving the view (navigating away) or the socket dropping in the background used
          // to silently kill the live tail, so returning showed a stale feed that only
          // refreshed once the user manually re-opened History. Now the subscription
          // survives the detach and is re-armed automatically the next time this chat's
          // topic (re)joins — see rearmLiveBridgeSessionLocked. It is only dropped on a
          // deliberate New Chat (clearLiveBridgeSessionIngest) or full teardown/logout.
          if let client = phoenixClient {
            client.leave(topic: chatTopic(for: chatId))
          }
        } else {
          openChatChannels[chatId] = current - 1
        }
      }
      if !hasRealtimeDemandLocked() {
        cancelReconnectLocked()
        reconnectAttempt = 0
      }
      appendJournalLocked(event: "close-chat-channel", payload: payload)
      state["updatedAt"] = nowMs()
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "chatChannelStateChanged", userInfo: ["chatId": chatId as Any])
      return snapshot
    }
  }

  /// Triggers background history loading for a list of chat IDs so messages
  /// are cached before the user taps into a chat.
  func prefetchChatHistories(chatIds: [String]) {
    queue.async { [weak self] in
      guard let self else { return }
      let startedAt = ProcessInfo.processInfo.systemUptime
      var kicked = 0
      defer {
        NSLog(
          "[Launch] history prefetch kicked=%d of %d in %dms",
          kicked, chatIds.count,
          Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))
      }
      for rawChatId in chatIds {
        guard let chatId = self.normalizedString(rawChatId), !chatId.isEmpty else { continue }
        // Only the built-in surface has no server-side chat behind it. Bridge DMs DO
        // (their settled turns are canonical server messages) and prefetch like any chat.
        guard !self.isBuiltInAgentChatId(chatId) else {
          self.appendJournalLocked(
            event: "native-chat-history-skip",
            payload: ["chatId": chatId, "reason": "agent_surface"]
          )
          continue
        }
        kicked += 1
        self.loadChatHistoryIfNeededLocked(chatId: chatId)
      }
    }
  }

  /// Seeds a small, recent slice from the home payload so opening a heavy chat
  /// never has to decrypt or normalize a large history synchronously on tap.
  func seedRecentChatHistory(chatId rawChatId: String, messages: [[String: Any]], limit: Int = 5) {
    queue.async { [weak self] in
      guard let self else { return }
      guard let chatId = self.normalizedString(rawChatId), !chatId.isEmpty else { return }
      guard !self.isBuiltInAgentChatId(chatId) else { return }
      _ = self.restoreCachedHistoryRowsLocked(chatId: chatId)
      guard !messages.isEmpty, !self.historyFullyLoadedChats.contains(chatId) else { return }

      // Saved-messages dicts must go through their normalizer first: it re-keys each row
      // to `original_message_id` (the id every other saved path uses — seeding raw server
      // dicts here persisted a second id-generation of the same transcript, i.e. the
      // duplicated cells) and parses the plaintext `extra` blob the generic builder
      // doesn't know about.
      let sourceMessages =
        chatId == "saved_messages" ? self.normalizeSavedMessagesLocked(messages) : messages
      let sortedMessages = sourceMessages.sorted { lhs, rhs in
        self.transcriptOrderPrecedes(
          lhsTs: self.transcriptTimestampMs(lhs),
          lhsId: self.rawMessageIdForOrdering(lhs, chatId: chatId),
          rhsTs: self.transcriptTimestampMs(rhs),
          rhsId: self.rawMessageIdForOrdering(rhs, chatId: chatId))
      }
      let recentMessages = Array(sortedMessages.suffix(max(1, min(limit, sortedMessages.count))))
      let rows = self.buildHistoryRowsLocked(chatId: chatId, rawMessages: recentMessages)
      guard !rows.isEmpty else { return }

      let existingCount = self.historyRowsByChat[chatId]?.count ?? 0
      guard existingCount < rows.count else { return }
      self.historyRowsByChat[chatId] = rows
      // If a row is good enough to paint, it is good enough to persist. These came from
      // the Home payload — for a chat the user never opens they may be the only rows we
      // ever hold, and without this they died with the process.
      self.storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
      self.appendJournalLocked(
        event: "native-chat-history-seed-recent",
        payload: ["chatId": chatId, "rows": rows.count]
      )
      self.postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId])
    }
  }

  /// Seeds lightweight preview rows from the Home API payload without triggering
  /// background full-history fetches for every chat.
  func seedChatHistories(_ payload: [String: Any]) -> [String: Any] {
    guard let histories = payload["chatHistories"] as? [String: [[String: Any]]] else {
      return ["seeded": 0]
    }

    var triggered = 0
    syncOnQueue {
      for (rawChatId, messagesArray) in histories {
        guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else { continue }
        _ = restoreCachedHistoryRowsLocked(chatId: chatId)
        // We only seed if the full history hasn't already been loaded.
        if !historyFullyLoadedChats.contains(chatId) {
          // Same rule as seedRecentChatHistory: saved-messages dicts re-key through their
          // normalizer so this path can never mint a second id-generation of a message.
          let sourceMessages =
            chatId == "saved_messages"
            ? normalizeSavedMessagesLocked(messagesArray) : messagesArray
          let rows = buildHistoryRowsLocked(chatId: chatId, rawMessages: sourceMessages)
          // A home payload that carries no messages for this chat must not install an
          // empty transcript, and a 5-row preview must not replace a longer slice some
          // other seed already put there. The in-memory entry is nil (unknown) or real.
          guard !rows.isEmpty, rows.count > (historyRowsByChat[chatId]?.count ?? 0) else {
            continue
          }
          historyRowsByChat[chatId] = rows
          historyRowsRestoredFromCacheChats.remove(chatId)
          // Same rule as seedRecentChatHistory: paintable ⇒ persisted. This is what gives
          // a never-opened chat a durable tail to paint from on the next cold launch.
          storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
          triggered += 1
        }
      }
    }

    NSLog(
      "[ChatEngine] seedChatHistories injected %d chats without eager history fetch", triggered)
    return ["seeded": triggered]
  }

  func sendDeliveryReceipt(_ payload: [String: Any]) -> [String: Any] {
    sendReceipt(
      payload,
      status: "delivered",
      eventName: "delivery-receipt",
      wireEvent: "delivery-receipt"
    )
  }

  func sendReadReceipt(_ payload: [String: Any]) -> [String: Any] {
    sendReceipt(
      payload,
      status: "read",
      eventName: "read-receipt",
      wireEvent: "read-receipt"
    )
  }

  func sendCallSignal(_ payload: [String: Any]) -> [String: Any] {
    guard #available(iOS 13.0, *) else {
      return ["accepted": false, "reason": "ios_unavailable"]
    }
    let event = normalizedString(payload["event"]) ?? "call-start"
    guard ["call-start", "call-accepted", "call-end", "webrtc-signal"].contains(event) else {
      return ["accepted": false, "reason": "unsupported_call_event", "event": event]
    }
    guard
      let toUserId = normalizedString(
        payload["toUserId"] ?? payload["to_user_id"] ?? payload["remoteUserId"]
          ?? payload["remote_user_id"])
    else {
      return ["accepted": false, "reason": "missing_to_user_id", "event": event]
    }

    let now = nowMs()
    let callId =
      normalizedString(payload["callId"] ?? payload["call_id"])
      ?? "call_\(now)_\(UUID().uuidString.prefix(8))"
    var wirePayload = makeJSONSafeMap(payload)
    wirePayload["event"] = event
    wirePayload["callId"] = callId
    wirePayload["toUserId"] = toUserId
    let signalId = "\(event):\(callId):\(toUserId):\(now)"
    var shouldConnect = false

    let result = syncOnQueue {
      nativeUserChannelDemandUntilMs = max(nativeUserChannelDemandUntilMs, now + nativeCallSignalDemandMs)
      expirePendingCallSignalsLocked(now: now)

      guard let client = phoenixClient,
        let topic = nativeUserTopic,
        (state["connected"] as? Bool) == true,
        nativePresenceActive
      else {
        nativePendingCallSignals.append(
          PendingCallSignal(id: signalId, event: event, payload: wirePayload, createdAtMs: now))
        appendJournalLocked(
          event: "native-call-signal-queued",
          payload: ["id": signalId, "event": event, "callId": callId, "toUserId": toUserId]
        )
        shouldConnect = true
        state["updatedAt"] = now
        let snapshot = statusSnapshotLocked()
        postChangeLocked(reason: "callSignalQueued", userInfo: ["event": event, "state": snapshot])
        return [
          "accepted": true,
          "transport": "native",
          "event": event,
          "callId": callId,
          "queued": true,
          "reason": "user_channel_not_ready",
        ]
      }

      let ref = client.push(topic: topic, event: event, payload: wirePayload)
      nativePendingCallPushRefs[ref] = signalId
      appendJournalLocked(
        event: "native-call-signal-push",
        payload: [
          "id": signalId,
          "event": event,
          "callId": callId,
          "toUserId": toUserId,
          "ref": ref,
          "topic": topic,
        ])
      state["updatedAt"] = now
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "callSignalSent", userInfo: ["event": event, "state": snapshot])
      return [
        "accepted": true,
        "transport": "native",
        "event": event,
        "callId": callId,
        "queued": false,
        "ref": ref,
      ]
    }

    if shouldConnect {
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "call_signal:\(event)")
      }
    }
    return result
  }

  func sendTypingState(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    guard let chatId, !chatId.isEmpty else { return ["accepted": false, "reason": "invalid_chat"] }
    let typing: Bool = {
      switch payload["typing"] {
      case let value as Bool:
        return value
      case let value as NSNumber:
        return value.boolValue
      case let value as String:
        return ["1", "true", "yes", "on"].contains(value.lowercased())
      default:
        return false
      }
    }()
    return syncOnQueue {
      if isBridgeTextModeLocked() {
        return ["accepted": false, "reason": "typing_disabled_in_blackout", "typing": typing]
      }
      if nativeTypingStateByChatId[chatId] == typing {
        return ["accepted": true, "transport": "native", "deduped": true, "typing": typing]
      }
      guard let client = phoenixClient else {
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "typing_no_socket")
        }
        return ["accepted": false, "reason": "no_native_socket", "typing": typing]
      }
      guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "typing_chat_not_joined")
        }
        return ["accepted": false, "reason": "chat_not_joined", "typing": typing]
      }
      nativeTypingStateByChatId[chatId] = typing
      let userId = normalizedString(getConfigValueLocked("userId")) ?? "me"
      let event = typing ? "typing" : "stop-typing"
      let ref = client.push(
        topic: chatTopic(for: chatId), event: event, payload: ["userId": userId])
      appendJournalLocked(
        event: "native-\(event)", payload: ["chatId": chatId, "ref": ref, "typing": typing])
      state["updatedAt"] = nowMs()
      postChangeLocked(reason: "typingStateSent", userInfo: ["chatId": chatId, "typing": typing])
      return ["accepted": true, "transport": "native", "ref": ref, "typing": typing]
    }
  }

  func sendRecordingState(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    guard let chatId, !chatId.isEmpty else { return ["accepted": false, "reason": "invalid_chat"] }
    let isRecording: Bool = {
      switch payload["isRecording"] ?? payload["recording"] {
      case let value as Bool:
        return value
      case let value as NSNumber:
        return value.boolValue
      case let value as String:
        return ["1", "true", "yes", "on"].contains(value.lowercased())
      default:
        return false
      }
    }()
    let isLocked: Bool = {
      switch payload["isLocked"] ?? payload["locked"] {
      case let value as Bool:
        return value
      case let value as NSNumber:
        return value.boolValue
      case let value as String:
        return ["1", "true", "yes", "on"].contains(value.lowercased())
      default:
        return false
      }
    }()
    let mode = normalizedString(payload["mode"]) ?? "voice"
    return syncOnQueue {
      if isBridgeTextModeLocked() {
        return [
          "accepted": false,
          "reason": "recording_disabled_in_blackout",
          "isRecording": isRecording,
        ]
      }
      if nativeRecordingStateByChatId[chatId] == isRecording {
        return [
          "accepted": true, "transport": "native", "deduped": true, "isRecording": isRecording,
        ]
      }
      nativeRecordingStateByChatId[chatId] = isRecording
      guard let client = phoenixClient else {
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "recording_no_socket")
        }
        return ["accepted": false, "reason": "no_native_socket", "isRecording": isRecording]
      }
      guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "recording_chat_not_joined")
        }
        return ["accepted": false, "reason": "chat_not_joined", "isRecording": isRecording]
      }
      let userId = normalizedString(getConfigValueLocked("userId")) ?? "me"
      let event = isRecording ? "recording" : "stop-recording"
      var wirePayload: [String: Any] = ["userId": userId]
      if isRecording {
        wirePayload["mode"] = mode
        wirePayload["isLocked"] = isLocked
        if let vad = payload["vad"] { wirePayload["vad"] = vad }
      }
      let ref = client.push(topic: chatTopic(for: chatId), event: event, payload: wirePayload)
      appendJournalLocked(
        event: "native-\(event)",
        payload: [
          "chatId": chatId,
          "ref": ref,
          "isRecording": isRecording,
          "isLocked": isLocked,
          "mode": mode,
        ])
      state["updatedAt"] = nowMs()
      postChangeLocked(
        reason: "recordingStateSent",
        userInfo: [
          "chatId": chatId,
          "isRecording": isRecording,
          "isLocked": isLocked,
          "mode": mode,
        ])
      return ["accepted": true, "transport": "native", "ref": ref, "isRecording": isRecording]
    }
	  }

  func sendAgentBridgeControl(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let provider = normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])
    let action = normalizedString(payload["action"] ?? payload["type"]) ?? "cancel"
    let taskId = normalizedString(payload["taskId"] ?? payload["agentTaskId"] ?? payload["messageId"])
    let teamRunId = normalizedString(payload["teamRunId"] ?? payload["team_run_id"])

    guard let chatId, !chatId.isEmpty else {
      return ["accepted": false, "reason": "invalid_chat"]
    }
    // Team-wide cancel may omit provider (server expands all workers).
    if provider == nil || provider?.isEmpty == true {
      guard let teamRunId, !teamRunId.isEmpty, action == "cancel" || action == "stop" else {
        return ["accepted": false, "reason": "invalid_provider"]
      }
      return syncOnQueue {
        sendAgentBridgeControlLocked(
          chatId: chatId,
          provider: "codex",
          action: action,
          taskId: taskId,
          teamRunId: teamRunId,
          attempt: 0)
      }
    }

    return syncOnQueue {
      sendAgentBridgeControlLocked(
        chatId: chatId,
        provider: provider!,
        action: action,
        taskId: taskId,
        teamRunId: teamRunId,
        attempt: 0)
    }
  }

  /// Progress node payloads for under-hood workers in a supervisor team run (sheet).
  func latestTeamWorkerProgressNodes(chatId: String, teamRunId: String) -> [String: [[String: Any]]]?
  {
    guard !chatId.isEmpty, !teamRunId.isEmpty else { return nil }
    return syncOnQueue {
      teamWorkerProgressNodesByChatId[chatId]?[teamRunId]
    }
  }

  /// Max times a control (cancel/revert) is re-attempted while the chat channel is
  /// still (re)joining. A cancel is idempotent, and the agent bridge connection drops
  /// constantly (recurring code=1006/1012), so a STOP tapped during a reconnect window
  /// must NOT be silently dropped — it has to ride through once the socket is back, or
  /// the run keeps streaming with no way to interrupt it.
  private static let bridgeControlMaxAttempts = 8

  private func sendAgentBridgeControlLocked(
    chatId: String,
    provider: String,
    action: String,
    taskId: String?,
    teamRunId: String? = nil,
    attempt: Int
  ) -> [String: Any] {
    let willRetry = attempt + 1 < Self.bridgeControlMaxAttempts
    guard let client = phoenixClient else {
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "bridge_control_no_socket")
      }
      scheduleAgentBridgeControlRetryLocked(
        chatId: chatId,
        provider: provider,
        action: action,
        taskId: taskId,
        teamRunId: teamRunId,
        attempt: attempt)
      return ["accepted": false, "reason": "no_native_socket", "willRetry": willRetry]
    }
    guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
      joinNativeChatTopicIfNeededLocked(chatId: chatId)
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "bridge_control_chat_not_joined")
      }
      scheduleAgentBridgeControlRetryLocked(
        chatId: chatId,
        provider: provider,
        action: action,
        taskId: taskId,
        teamRunId: teamRunId,
        attempt: attempt)
      return ["accepted": false, "reason": "chat_not_joined", "willRetry": willRetry]
    }

    var wirePayload: [String: Any] = [
      "action": action,
      "provider": provider,
    ]
    if let taskId, !taskId.isEmpty {
      wirePayload["taskId"] = taskId
    }
    if let teamRunId, !teamRunId.isEmpty {
      wirePayload["teamRunId"] = teamRunId
    }
    if let computerId = AgentBridgeSelectionStore.selectedRepository(chatId: chatId)?.computerId,
      !computerId.isEmpty
    {
      wirePayload["computerId"] = computerId
    }
    let ref = client.push(
      topic: chatTopic(for: chatId),
      event: "agent-bridge-control",
      payload: wirePayload
    )
    appendJournalLocked(
      event: "native-agent-bridge-control",
      payload: [
        "chatId": chatId, "provider": provider, "action": action, "ref": ref, "attempt": attempt,
        "teamRunId": teamRunId as Any,
      ]
    )
    state["updatedAt"] = nowMs()
    postChangeLocked(
      reason: "agentBridgeControlSent",
      userInfo: ["chatId": chatId, "provider": provider, "action": action]
    )
    return ["accepted": true, "transport": "native", "ref": ref]
  }

  /// Re-attempt a control push after a short backoff when the channel wasn't ready.
  /// Bounded by `bridgeControlMaxAttempts`; stops as soon as a push actually goes out
  /// (a delivered cancel that races a natural finish is a harmless no-op on the bridge).
  private func scheduleAgentBridgeControlRetryLocked(
    chatId: String,
    provider: String,
    action: String,
    taskId: String?,
    teamRunId: String? = nil,
    attempt: Int
  ) {
    let nextAttempt = attempt + 1
    guard nextAttempt < Self.bridgeControlMaxAttempts else { return }
    // ~0.75s, 1.5s, 2.25s, 3s… covering the typical 3–15s reconnect window.
    let delay = min(0.75 * Double(nextAttempt), 3.0)
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      _ = self.syncOnQueue {
        self.sendAgentBridgeControlLocked(
          chatId: chatId,
          provider: provider,
          action: action,
          taskId: taskId,
          teamRunId: teamRunId,
          attempt: nextAttempt)
      }
    }
  }

  /// Ask the connected computer for the agent's own Claude/Codex conversation
  /// history. `mode` is "list" (topic summaries) or "detail" (a transcript for
  /// `sessionId`). The reply arrives asynchronously as a `didChange`
  /// notification with reason "agentBridgeHistory"; read it via
  /// `latestAgentBridgeHistory(chatId:)`.
  func requestAgentBridgeHistory(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let provider = normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])
    let mode = normalizedString(payload["mode"]) ?? "list"
    let sessionId = normalizedString(payload["sessionId"] ?? payload["session_id"])
    let requestId = normalizedString(payload["requestId"]) ?? UUID().uuidString
    let before = normalizedString(payload["before"] ?? payload["beforeCursor"] ?? payload["before_cursor"])

    guard let chatId, !chatId.isEmpty else {
      return ["accepted": false, "reason": "invalid_chat"]
    }
    guard let provider, !provider.isEmpty else {
      return ["accepted": false, "reason": "invalid_provider"]
    }

    return syncOnQueue {
      var wirePayload: [String: Any] = [
        "provider": provider,
        "mode": mode,
        "requestId": requestId,
      ]
      if let sessionId, !sessionId.isEmpty {
        wirePayload["sessionId"] = sessionId
      }
      if let before, !before.isEmpty {
        wirePayload["before"] = before
      }
      if let limit = payload["limit"] as? Int, limit > 0 {
        wirePayload["limit"] = limit
      } else if let limit = normalizedString(payload["limit"]), let parsed = Int(limit), parsed > 0 {
        wirePayload["limit"] = parsed
      }
      if let computerId = AgentBridgeSelectionStore.selectedRepository(chatId: chatId)?.computerId,
        !computerId.isEmpty
      {
        wirePayload["computerId"] = computerId
      }

      // History reads are idempotent and the bridge daemon supports both one-shot list
      // reads and watched detail reads over its authenticated LAN transport. Every mode
      // therefore gets the same direct fast path; cloud remains the bounded fallback.
      if AgentBridgeTransport.preference != .cloud,
        sendAgentBridgeHistoryOverLanLocked(
          chatId: chatId, wirePayload: wirePayload, requestId: requestId)
      {
        return ["accepted": true, "transport": "lan", "requestId": requestId]
      }

      return sendAgentBridgeHistoryOverCloudLocked(
        chatId: chatId, wirePayload: wirePayload, requestId: requestId)
    }
  }

  /// Direct authenticated-LAN path for any history mode. The pending set only owns the
  /// initial reply/fallback race; detail watcher ownership lives in
  /// `liveBridgeSessionIngestByChatId` and deliberately survives the first response.
  private func sendAgentBridgeHistoryOverLanLocked(
    chatId: String, wirePayload: [String: Any], requestId: String
  ) -> Bool {
    var lanPayload = wirePayload
    lanPayload["chatId"] = chatId
    guard LanBridgeService.shared.send(type: "history_request", payload: lanPayload) else {
      return false
    }

    lanHistoryPendingRequestIds.insert(requestId)
    let cloudFallback = wirePayload
    let mode = normalizedString(wirePayload["mode"]) ?? "list"
    queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      guard let self else { return }
      guard self.lanHistoryPendingRequestIds.remove(requestId) != nil else { return }
      NSLog(
        "[LanBridge] history %@ over LAN timed out req=%@ — cloud fallback",
        mode, String(requestId.prefix(8)))
      _ = self.sendAgentBridgeHistoryOverCloudLocked(
        chatId: chatId, wirePayload: cloudFallback, requestId: requestId)
    }
    NSLog(
      "[LanBridge] history %@ sent over LAN req=%@ chat=%@",
      mode, String(requestId.prefix(8)), String(chatId.prefix(12)))
    return true
  }

  /// Cloud (Phoenix) path for a history request — the persistence-backed source of truth.
  /// Split out so the direct-LAN fast path can fall back here on timeout.
  private func sendAgentBridgeHistoryOverCloudLocked(
    chatId: String, wirePayload: [String: Any], requestId: String
  ) -> [String: Any] {
    guard let client = phoenixClient else {
      queueAgentBridgeHistoryRequestLocked(chatId: chatId, payload: wirePayload)
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "bridge_history_no_socket")
      }
      return [
        "accepted": true,
        "transport": "native_queued",
        "reason": "joining_transport",
        "requestId": requestId,
      ]
    }
    guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
      queueAgentBridgeHistoryRequestLocked(chatId: chatId, payload: wirePayload)
      joinNativeChatTopicIfNeededLocked(chatId: chatId)
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "bridge_history_chat_not_joined")
      }
      return [
        "accepted": true,
        "transport": "native_queued",
        "reason": "joining_chat",
        "requestId": requestId,
      ]
    }

    let ref = client.push(
      topic: chatTopic(for: chatId),
      event: "agent-bridge-history",
      payload: wirePayload
    )
    appendJournalLocked(
      event: "native-agent-bridge-history-request",
      payload: [
        "chatId": chatId,
        "provider": normalizedString(wirePayload["provider"]) ?? "",
        "mode": normalizedString(wirePayload["mode"]) ?? "list",
        "before": normalizedString(wirePayload["before"]) ?? "",
        "ref": ref,
      ]
    )
    return ["accepted": true, "transport": "native", "ref": ref, "requestId": requestId]
  }

  private func queueAgentBridgeHistoryRequestLocked(chatId: String, payload: [String: Any]) {
    var queued = pendingAgentBridgeHistoryRequestsByChat[chatId] ?? []
    queued.append(payload)
    if queued.count > 12 {
      queued.removeFirst(queued.count - 12)
    }
    pendingAgentBridgeHistoryRequestsByChat[chatId] = queued
    NSLog(
      "[ChatEngine][BridgeHistory] queued chat=%@ mode=%@ request=%@ pending=%d",
      String(chatId.prefix(12)),
      normalizedString(payload["mode"]) ?? "list",
      String((normalizedString(payload["requestId"]) ?? "-").prefix(8)),
      queued.count)
  }

  private func flushPendingAgentBridgeHistoryRequestsLocked(chatId: String) {
    guard
      let client = phoenixClient,
      nativeJoinedChatIds.contains(chatId),
      (state["connected"] as? Bool) == true,
      let queued = pendingAgentBridgeHistoryRequestsByChat.removeValue(forKey: chatId),
      !queued.isEmpty
    else { return }

    for wirePayload in queued {
      let ref = client.push(
        topic: chatTopic(for: chatId),
        event: "agent-bridge-history",
        payload: wirePayload
      )
      appendJournalLocked(
        event: "native-agent-bridge-history-request",
        payload: [
          "chatId": chatId,
          "provider": normalizedString(wirePayload["provider"]) ?? "",
          "mode": normalizedString(wirePayload["mode"]) ?? "list",
          "before": normalizedString(wirePayload["before"]) ?? "",
          "ref": ref,
          "queued": true,
        ]
      )
    }
    NSLog(
      "[ChatEngine][BridgeHistory] flushed chat=%@ requests=%d",
      String(chatId.prefix(12)), queued.count)
  }

  /// The most recent agent-bridge history payload relayed for a chat, if any.
  func latestAgentBridgeHistory(chatId rawChatId: String) -> [String: Any]? {
    let chatId = normalizedString(rawChatId) ?? rawChatId
    return syncOnQueue { agentBridgeHistoryByChat[chatId] }
  }

  /// The most recent history list for this chat+provider. A later transcript
  /// detail response for the same chat does not overwrite this cache.
  func latestAgentBridgeHistoryList(chatId rawChatId: String, provider rawProvider: String) -> [String: Any]? {
    let chatId = normalizedString(rawChatId) ?? rawChatId
    let provider = (normalizedString(rawProvider) ?? rawProvider).lowercased()
    let key = "\(chatId)|\(provider)"
    return syncOnQueue { agentBridgeHistoryListByChatProvider[key] }
  }

  /// Ask the bridge for the full contents of a file the agent touched. The reply
  /// arrives over the chat topic as `agent-bridge-file`; observe
  /// `didChangeNotification` reason "agentBridgeFile" + matching requestId, then
  /// read it via `latestAgentBridgeFile(requestId:)` (decrypt `agentFileEnc`).
  func requestAgentBridgeFile(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let provider = normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])
    let filePath = normalizedString(payload["path"] ?? payload["file"])
    let requestId = normalizedString(payload["requestId"]) ?? UUID().uuidString

    guard let chatId, !chatId.isEmpty else { return ["accepted": false, "reason": "invalid_chat"] }
    guard let provider, !provider.isEmpty else { return ["accepted": false, "reason": "invalid_provider"] }
    guard let filePath, !filePath.isEmpty else { return ["accepted": false, "reason": "invalid_path"] }

    return syncOnQueue {
      guard let client = phoenixClient else {
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "bridge_file_no_socket")
        }
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "bridge_file_chat_not_joined")
        }
        return ["accepted": false, "reason": "chat_not_joined"]
      }

      var wirePayload: [String: Any] = [
        "provider": provider, "path": filePath, "requestId": requestId,
      ]
      if let computerId = AgentBridgeSelectionStore.selectedRepository(chatId: chatId)?.computerId,
        !computerId.isEmpty
      {
        wirePayload["computerId"] = computerId
      }
      let ref = client.push(
        topic: chatTopic(for: chatId),
        event: "agent-bridge-file",
        payload: wirePayload
      )
      appendJournalLocked(
        event: "native-agent-bridge-file-request",
        payload: ["chatId": chatId, "provider": provider, "path": filePath, "ref": ref]
      )
      return ["accepted": true, "transport": "native", "ref": ref, "requestId": requestId]
    }
  }

  /// The most recent full-file reply for a requestId, if it has arrived.
  func latestAgentBridgeFile(requestId rawRequestId: String) -> [String: Any]? {
    let requestId = normalizedString(rawRequestId) ?? rawRequestId
    return syncOnQueue { agentBridgeFileByRequestId[requestId] }
  }

  /// Ask the connected bridge for a structured usage snapshot (Claude 5h/7-day
  /// limits + this chat's last-run tokens) for the inline Usage panel. The reply
  /// arrives over the chat topic as `agent-bridge-usage`; observe
  /// `didChangeNotification` reason "agentBridgeUsage" and read it via
  /// `latestAgentBridgeUsage(requestId:)`.
  func requestAgentBridgeUsage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let provider = normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])
    let requestId = normalizedString(payload["requestId"]) ?? UUID().uuidString

    guard let chatId, !chatId.isEmpty else { return ["accepted": false, "reason": "invalid_chat"] }
    guard let provider, !provider.isEmpty else { return ["accepted": false, "reason": "invalid_provider"] }

    return syncOnQueue {
      guard let client = phoenixClient else {
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "bridge_usage_no_socket")
        }
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "bridge_usage_chat_not_joined")
        }
        return ["accepted": false, "reason": "chat_not_joined"]
      }

      var wirePayload: [String: Any] = ["provider": provider, "requestId": requestId]
      if let computerId = AgentBridgeSelectionStore.selectedRepository(chatId: chatId)?.computerId,
        !computerId.isEmpty
      {
        wirePayload["computerId"] = computerId
      }
      let ref = client.push(
        topic: chatTopic(for: chatId),
        event: "agent-bridge-usage",
        payload: wirePayload
      )
      appendJournalLocked(
        event: "native-agent-bridge-usage-request",
        payload: ["chatId": chatId, "provider": provider, "ref": ref]
      )
      return ["accepted": true, "transport": "native", "ref": ref, "requestId": requestId]
    }
  }

  /// The most recent usage snapshot reply for a requestId, if it has arrived.
  func latestAgentBridgeUsage(requestId rawRequestId: String) -> [String: Any]? {
    let requestId = normalizedString(rawRequestId) ?? rawRequestId
    return syncOnQueue { agentBridgeUsageByRequestId[requestId] }
  }

  /// Prefetched usage payload for a chat+provider (report already inside).
  func cachedAgentBridgeUsage(chatId rawChatId: String, provider rawProvider: String) -> [String: Any]? {
    let chatId = normalizedString(rawChatId) ?? rawChatId
    let provider = (normalizedString(rawProvider) ?? rawProvider).lowercased()
    guard !chatId.isEmpty, !provider.isEmpty else { return nil }
    let key = "\(chatId)|\(provider)"
    return syncOnQueue { agentBridgeUsageByChatProvider[key] }
  }

  /// The most recent ask request (plan approval / question) for a requestId.
  /// Decrypt its `askEnc` blob with `AgentRuntimeCrypto.decrypt` to read the body.
  func latestAgentBridgeAsk(requestId rawRequestId: String) -> [String: Any]? {
    let requestId = normalizedString(rawRequestId) ?? rawRequestId
    return syncOnQueue { agentBridgeAskByRequestId[requestId] }
  }

  /// Atomically claim an ask requestId for sheet presentation. Returns `true` exactly
  /// once per requestId — that caller should present the sheet; every later caller gets
  /// `false` and must skip. This is the cross-surface dedup: the chat bubble view and a
  /// full-page agent view (incl. the profile session view) can both observe the same
  /// `agentBridgeAsk`, and without this they'd each present a sheet.
  func claimAgentBridgeAskPresentation(requestId rawRequestId: String) -> Bool {
    let requestId = normalizedString(rawRequestId) ?? rawRequestId
    guard !requestId.isEmpty else { return false }
    return syncOnQueue {
      if presentedAskRequestIds.contains(requestId) { return false }
      presentedAskRequestIds.insert(requestId)
      return true
    }
  }

  /// Release a presentation claim for an ask that was shown but NOT answered (the user
  /// swiped the sheet away, or the surface was torn down). Keeps the cached request so
  /// the ask can be presented again — the bridge re-emits still-blocked asks when the
  /// chat is reopened, and without releasing the claim `claimAgentBridgeAskPresentation`
  /// would refuse to re-present it. A no-op once the ask has been answered (its cached
  /// payload is already dropped in `sendAgentBridgeAskResponse`).
  func releaseAgentBridgeAskPresentation(requestId rawRequestId: String) {
    let requestId = normalizedString(rawRequestId) ?? rawRequestId
    guard !requestId.isEmpty else { return }
    syncOnQueue {
      // Only release while the request is still outstanding; if it was answered the
      // payload is gone and we must not re-arm a resolved ask.
      guard agentBridgeAskByRequestId[requestId] != nil else { return }
      presentedAskRequestIds.remove(requestId)
    }
  }

  /// The `agentBridgeAsk` userInfo for a still-outstanding, not-yet-claimed ask/command on
  /// `chatId` (matching `provider` when both sides name one), or nil. A chat surface calls this
  /// when it becomes visible to re-present an ask that arrived while it was off-screen: the
  /// on-screen-chat presentation gate skips asks for a chat that isn't front, and a plain DM
  /// open doesn't reload history, so the bridge's history-open re-emit never fires for it.
  /// Typically at most one ask blocks a chat at a time; returns the first outstanding match.
  func outstandingAgentBridgeAskInfo(chatId rawChatId: String, provider rawProvider: String?)
    -> [AnyHashable: Any]?
  {
    let chatId = normalizedString(rawChatId) ?? ""
    guard !chatId.isEmpty else { return nil }
    let provider = (rawProvider ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // A device run caught this blocking the main thread for 90 ms while opening a Codex
    // DM. The scan below is a handful of dictionary reads — the 90 ms was spent *waiting*
    // for the engine queue, which happened to be loading history. Any main-thread reader
    // is exposed to the duration of whatever the queue is running, so the fix is to stop
    // being a main-thread reader rather than to make the scan quicker.
    if let published = uiMirror.pendingBridgeAsk(chatId: chatId, provider: provider) {
      return published?.payload
    }
    return syncOnQueue {
      for (rid, payload) in agentBridgeAskByRequestId {
        guard (normalizedString(payload["chatId"]) ?? "") == chatId else { continue }
        if presentedAskRequestIds.contains(rid) { continue }
        let p = (normalizedString(payload["provider"]) ?? "").lowercased()
        if !provider.isEmpty, !p.isEmpty, p != provider { continue }
        return [
          "chatId": chatId,
          "requestId": rid,
          "kind": normalizedString(payload["kind"]) ?? "ask",
          "provider": normalizedString(payload["provider"]) ?? provider,
          "sessionId": normalizedString(payload["sessionId"] ?? payload["session_id"]) ?? "",
          "resumedFromSessionId": normalizedString(
            payload["resumedFromSessionId"] ?? payload["resumed_from_session_id"]) ?? "",
          "reason": "agentBridgeAsk",
        ]
      }
      return nil
    }
  }

  /// Whether an ask/command approval is still outstanding (sent, not yet answered) for
  /// `chatId` — unlike `outstandingAgentBridgeAskInfo`, this ignores the presentation
  /// claim, so it stays true for the whole time a sheet could be showing, not just the
  /// window before it's first claimed. Used by chat headers to show a lightweight
  /// "Waiting for approval" status without racing the sheet-presentation dedup.
  func hasOutstandingAgentBridgeAsk(chatId rawChatId: String, provider rawProvider: String?) -> Bool {
    let chatId = normalizedString(rawChatId) ?? ""
    guard !chatId.isEmpty else { return false }
    let provider = (rawProvider ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return syncOnQueue {
      agentBridgeAskByRequestId.values.contains { payload in
        guard (normalizedString(payload["chatId"]) ?? "") == chatId else { return false }
        let p = (normalizedString(payload["provider"]) ?? "").lowercased()
        return provider.isEmpty || p.isEmpty || p == provider
      }
    }
  }

  /// Reply to a bridge-issued ask. `decision` ∈ "approve" | "reject" | "answer".
  /// `answer` (any JSON-serializable dict) is sealed E2E with the pairing key so
  /// the server only relays an opaque blob; the bridge resolves the pending ask.
  @discardableResult
  func sendAgentBridgeAskResponse(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let requestId = normalizedString(payload["requestId"] ?? payload["request_id"])
    let decisionRaw = normalizedString(payload["decision"] ?? payload["action"]) ?? "answer"
    let decision = ["approve", "reject", "answer"].contains(decisionRaw) ? decisionRaw : "answer"
    let provider = normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])

    guard let chatId, !chatId.isEmpty else { return ["accepted": false, "reason": "invalid_chat"] }
    guard let requestId, !requestId.isEmpty else {
      return ["accepted": false, "reason": "invalid_request_id"]
    }

    var wirePayload: [String: Any] = ["requestId": requestId, "decision": decision]
    if let provider, !provider.isEmpty { wirePayload["provider"] = provider }
    if let computerId = AgentBridgeSelectionStore.selectedRepository(chatId: chatId)?.computerId,
      !computerId.isEmpty
    {
      wirePayload["computerId"] = computerId
    }
    if let answer = payload["answer"] as? [String: Any], !answer.isEmpty,
      let sealed = AgentRuntimeCrypto.encrypt(["answer": answer])
    {
      wirePayload["answerEnc"] = sealed
    }

    // The ask is resolved once; drop the cached request so a stale sheet can't
    // re-answer it. Refresh the running mark too: the CLI takes a beat to resume
    // streaming after an approval, and the outstanding-ask hold just ended — without
    // this the settle-clear's grace could expire in that resume gap.
    syncOnQueue {
      _ = agentBridgeAskByRequestId.removeValue(forKey: requestId)
      agentTurnRunningAtMsByChatId[chatId] = Int64(nowMs())
    }

    return syncOnQueue {
      guard let client = phoenixClient else {
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "bridge_ask_no_socket")
        }
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "bridge_ask_chat_not_joined")
        }
        return ["accepted": false, "reason": "chat_not_joined"]
      }

      let ref = client.push(
        topic: chatTopic(for: chatId),
        event: "agent-bridge-ask-response",
        payload: wirePayload
      )
      appendJournalLocked(
        event: "native-agent-bridge-ask-response",
        payload: ["chatId": chatId, "requestId": requestId, "decision": decision, "ref": ref]
      )
      return ["accepted": true, "transport": "native", "ref": ref, "requestId": requestId]
    }
  }

  /// Open a Claude/Codex/Grok past session into the DEFAULT chat as bubbles: request
  /// the session transcript over the bridge and, when it arrives, synthesize it
  /// into chat rows (user prompt -> right bubble, agent reply -> agent cell) via
  /// the normal incoming-message path. Replaces the old in-profile transcript.
  @discardableResult
  func loadAgentBridgeSessionIntoChat(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]) ?? ""
    let provider = normalizedString(payload["provider"]) ?? ""
    let sessionId = normalizedString(payload["sessionId"] ?? payload["session_id"]) ?? ""
    let topicHint = normalizedString(payload["topic"]) ?? ""
    guard !chatId.isEmpty, !provider.isEmpty, !sessionId.isEmpty else {
      return ["accepted": false, "reason": "invalid_session"]
    }

    // History picks originate from SwiftUI/UIKit on the main thread. The engine queue
    // can be busy ingesting/decrypting a large bridge transcript, so synchronously
    // entering it here freezes the tap (observed at 11s). This API is already
    // completion-by-notification; enqueue the complete state transition so its
    // single-flight check, topic seed, request, and live-tail registration remain
    // ordered without ever making the caller wait for the engine queue.
    let requestId = UUID().uuidString
    queue.async { [weak self] in
      self?.loadAgentBridgeSessionIntoChatLocked(
        chatId: chatId,
        provider: provider,
        sessionId: sessionId,
        topicHint: topicHint,
        requestId: requestId
      )
    }
    return [
      "accepted": true,
      "transport": "engine_queued",
      "requestId": requestId,
    ]
  }

  private func loadAgentBridgeSessionIntoChatLocked(
    chatId: String,
    provider: String,
    sessionId: String,
    topicHint: String,
    requestId: String
  ) {
    dispatchPrecondition(condition: .onQueue(queue))

    // Seed the History-row title immediately (including already_loaded / inflight
    // short-circuits). Without this the header stays on "Start session" while the
    // list is empty/loading under historical isolation.
    seedBridgeSessionTopicLocked(chatId: chatId, topic: topicHint)

    // Same session already mounted and ingested — don't re-fetch (history sheet
    // re-taps and open-path races were reloading 019f45b0 repeatedly). Still re-emit
    // a rows signal so the chat list re-applies its session filter and paints the
    // already-ingested `bridge-<sessionId>-…` rows instead of an empty feed.
    if let live = liveBridgeSessionIngestByChatId[chatId],
      live.sessionId == sessionId,
      lastIngestedBridgeSessionSigByChatId[chatId] != nil
    {
      NSLog(
        "[ChatEngine][BridgeMount] loadSession SKIP same session chat=%@ session=%@",
        String(chatId.suffix(12)), String(sessionId.prefix(12))
      )
      postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId])
      return
    }
    // Single-flight: history UI can fire pick + open + join for the same session
    // before the first detail returns (3 concurrent details for 019f4644).
    let now = Int64(nowMs())
    if let inflight = sessionLoadInflightByChatId[chatId],
      inflight.sessionId == sessionId,
      now - inflight.atMs < 5000
    {
      NSLog(
        "[ChatEngine][BridgeMount] loadSession SKIP inflight chat=%@ session=%@",
        String(chatId.suffix(12)), String(sessionId.prefix(12))
      )
      return
    }
    sessionLoadInflightByChatId[chatId] = (
      sessionId: sessionId,
      requestId: requestId,
      atMs: Int64(nowMs())
    )

    let result = requestAgentBridgeHistory([
      "chatId": chatId,
      "provider": provider,
      "mode": "detail",
      "sessionId": sessionId,
      "requestId": requestId,
      "limit": Self.bridgeSessionPageLimit,
    ])
    if (result["accepted"] as? Bool) == true {
      pendingBridgeSessionIngestByRequestId[requestId] = (chatId: chatId, provider: provider)
      // Stay subscribed: the bridge re-pushes this requestId as the transcript
      // grows, and each re-push upserts new turns in place (live tail).
      liveBridgeSessionIngestByChatId[chatId] = (
        provider: provider,
        sessionId: sessionId,
        requestId: requestId
      )
      // Switching sessions invalidates prior ingest sig so the new transcript applies.
      lastIngestedBridgeSessionSigByChatId.removeValue(forKey: chatId)
      bridgeSessionPagingByChatId[chatId] = (
        provider: provider, sessionId: sessionId, nextBefore: nil, hasMoreBefore: true,
        loadingOlder: false
      )
    } else {
      if sessionLoadInflightByChatId[chatId]?.requestId == requestId {
        sessionLoadInflightByChatId.removeValue(forKey: chatId)
      }
    }
  }

  /// Apply a History-row title as soon as a session is picked (before the detail
  /// transcript lands). Must run on the engine queue; no-ops on empty topic.
  private func seedBridgeSessionTopicLocked(chatId: String, topic: String) {
    dispatchPrecondition(condition: .onQueue(queue))
    let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if bridgeSessionTopicByChatId[chatId] != trimmed {
      bridgeSessionTopicByChatId[chatId] = trimmed
      postChangeLocked(reason: "agentBridgeSessionTopic", userInfo: ["chatId": chatId])
    }
  }

  /// A plain agent DM may begin an automatic current-session read while the user is
  /// already composing a brand-new task. Once that fresh send wins, a late detail reply
  /// must not mount an old transcript into the new thread and reorder visible bubbles.
  /// Explicit History picks use the separate session-load path and are unaffected.
  func cancelAutomaticAgentBridgeSessionLoad(chatId rawChatId: String) {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else { return }
    syncOnQueue {
      guard let inflight = currentSessionLoadInflightByChatId.removeValue(forKey: chatId) else {
        return
      }
      pendingBridgeSessionIngestByRequestId.removeValue(forKey: inflight.requestId)
      NSLog(
        "[ChatEngine][BridgeMount] cancel automatic current-session load chat=%@ requestId=%@ after fresh send",
        String(chatId.suffix(12)), String(inflight.requestId.prefix(8))
      )
    }
  }

  @discardableResult
  func loadOlderAgentBridgeSessionChunk(chatId rawChatId: String) -> [String: Any] {
    let chatId = normalizedString(rawChatId) ?? rawChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else { return ["accepted": false, "reason": "invalid_chat"] }

    let spec: (provider: String, sessionId: String, before: String)? = syncOnQueue {
      guard var paging = bridgeSessionPagingByChatId[chatId],
        paging.hasMoreBefore,
        !paging.loadingOlder,
        let before = paging.nextBefore,
        !before.isEmpty
      else {
        return nil
      }
      paging.loadingOlder = true
      bridgeSessionPagingByChatId[chatId] = paging
      return (provider: paging.provider, sessionId: paging.sessionId, before: before)
    }
    guard let spec else { return ["accepted": false, "reason": "no_older_page"] }

    let requestId = UUID().uuidString
    let result = requestAgentBridgeHistory([
      "chatId": chatId,
      "provider": spec.provider,
      "mode": "detail",
      "sessionId": spec.sessionId,
      "before": spec.before,
      "requestId": requestId,
      "limit": Self.bridgeSessionPageLimit,
    ])
    if (result["accepted"] as? Bool) == true {
      syncOnQueue {
        pendingBridgeSessionIngestByRequestId[requestId] = (chatId: chatId, provider: spec.provider)
      }
    } else {
      syncOnQueue {
        if var paging = bridgeSessionPagingByChatId[chatId], paging.sessionId == spec.sessionId {
          paging.loadingOlder = false
          bridgeSessionPagingByChatId[chatId] = paging
        }
      }
    }
    return result
  }

  /// Forget the bridge history session a chat had loaded (its live-tail subscription).
  /// Called on a deliberate New Chat so a subsequent topic re-join can't resurrect the
  /// old transcript into the fresh thread. Normal view-detach / backgrounding does NOT
  /// call this — the session is retained so the live tail resumes on return.
  func clearLiveBridgeSessionIngest(chatId rawChatId: String) {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else { return }
    queue.async { [weak self] in
      guard let self else { return }
      self.liveBridgeSessionIngestByChatId.removeValue(forKey: chatId)
      self.bridgeSettledSessionSigByChatId.removeValue(forKey: chatId)
      self.bridgeSessionPagingByChatId.removeValue(forKey: chatId)
      self.pendingBridgeSessionIngestByRequestId = self.pendingBridgeSessionIngestByRequestId.filter {
        $0.value.chatId != chatId
      }
      if self.bridgeSessionTopicByChatId.removeValue(forKey: chatId) != nil {
        self.postChangeLocked(reason: "agentBridgeSessionTopic", userInfo: ["chatId": chatId])
      }
    }
  }

  /// The History-panel title of the session this chat is currently on (loaded, resumed,
  /// or live-tailed), if known. The chat header shows it as the idle subtitle in place
  /// of "Start session".
  func agentBridgeSessionTopic(chatId rawChatId: String) -> String? {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else { return nil }
    return syncOnQueue { bridgeSessionTopicByChatId[chatId] }
  }

  /// The bridge history session this chat is currently live-tailing, if any. Retained
  /// across view-detach/background (only dropped by New Chat / logout), so the chat view
  /// can keep the session's rows visible even when its own per-instance loaded-session id
  /// was reset by a rebind — the root cause of the feed collapsing to empty on foreground.
  /// Live bridge session ids, readable without entering the engine queue.
  private let publishedBridgeSessionLock = NSLock()
  private var publishedBridgeSessionIds: [String: String] = [:]
  private var publishedBridgeSessionsReady = false

  /// The live bridge session for a chat, if any.
  ///
  /// Reads a single dictionary value — and blocked the main thread for 160ms on device,
  /// because getting to that value means queueing behind whatever the engine is doing.
  /// `ChatListView` asks in ten places, several of them on render paths, so the cost
  /// lands directly on the list. Same contract as `getChatRows` and `getStatus`: main
  /// reads the last published map and asks for a refresh instead of waiting for one.
  ///
  /// `publishedBridgeSessionsReady` is what keeps this honest — an empty map before the
  /// first publish is not the same statement as "this chat has no live session", and
  /// answering nil from it would silently drop a live agent feed. Until the engine has
  /// published once, main takes the blocking path exactly as before.
  func liveBridgeSessionId(chatId rawChatId: String) -> String? {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else { return nil }
    if Thread.isMainThread {
      publishedBridgeSessionLock.lock()
      let ready = publishedBridgeSessionsReady
      let published = publishedBridgeSessionIds[chatId]
      publishedBridgeSessionLock.unlock()
      if ready {
        queue.async { [weak self] in self?.publishBridgeSessionIds() }
        return published
      }
    }
    return syncOnQueue {
      publishBridgeSessionIds()
      return liveBridgeSessionIngestByChatId[chatId]?.sessionId
    }
  }

  /// Snapshots the live-session map for the lock-free read above. Engine queue only.
  private func publishBridgeSessionIds() {
    var snapshot: [String: String] = [:]
    snapshot.reserveCapacity(liveBridgeSessionIngestByChatId.count)
    for (chatId, ingest) in liveBridgeSessionIngestByChatId {
      snapshot[chatId] = ingest.sessionId
    }
    publishedBridgeSessionLock.lock()
    publishedBridgeSessionIds = snapshot
    publishedBridgeSessionsReady = true
    publishedBridgeSessionLock.unlock()
  }

  /// A chat that had a bridge history session loaded just (re)joined its topic — either
  /// after the user returned to the view or after a socket reconnect in the background.
  /// Re-issue the detail request so the bridge re-watches the transcript and re-pushes
  /// the current turns; this resumes live updates and refreshes the feed in place
  /// (upsert) rather than leaving it frozen until History is manually re-opened.
  private func rearmLiveBridgeSessionLocked(chatId: String, trigger: String) {
    guard let live = liveBridgeSessionIngestByChatId[chatId] else { return }
    let now = Int64(nowMs())
    let lastArm = lastBridgeRearmAtMsByChatId[chatId] ?? 0
    // Soft triggers (open / join / already_live) must not re-download an already
    // ingested transcript — each detail re-push was remounting the Grok feed.
    // Only force_recover / socket recovery re-pull when content may have changed.
    let softTriggers: Set<String> = [
      "current_session_load", "chat_joined", "open", "poll", "already_live",
    ]
    let soft = softTriggers.contains(trigger) || trigger.hasPrefix("poll#")
    if soft, trigger != "force_recover" {
      if lastIngestedBridgeSessionSigByChatId[chatId] != nil, !live.sessionId.isEmpty {
        NSLog(
          "[ChatEngine][BridgeMount] rearm SKIP soft chat=%@ trigger=%@ session=%@ (already ingested)",
          String(chatId.suffix(12)), trigger, String(live.sessionId.prefix(12))
        )
        return
      }
    }
    // Hard throttle for any remaining path (reconnect recovery still allowed after 1.2s).
    if now - lastArm < 1200, trigger != "force_recover" {
      NSLog(
        "[ChatEngine][BridgeMount] rearm SKIPPED chat=%@ trigger=%@ ageMs=%lld (coalesce)",
        String(chatId.suffix(12)), trigger, now - lastArm
      )
      return
    }
    let requestId = UUID().uuidString
    var wirePayload: [String: Any] = [
      "provider": live.provider,
      "mode": "detail",
      "requestId": requestId,
      "limit": Self.bridgeSessionPageLimit,
    ]
    if !live.sessionId.isEmpty { wirePayload["sessionId"] = live.sessionId }

    let result: [String: Any]
    if AgentBridgeTransport.preference != .cloud,
      sendAgentBridgeHistoryOverLanLocked(
        chatId: chatId, wirePayload: wirePayload, requestId: requestId)
    {
      result = ["accepted": true, "transport": "lan", "requestId": requestId]
    } else {
      // Preserve the original Phoenix readiness guards when LAN is unavailable or cloud
      // is explicitly selected. A later chat join/reconnect trigger will try again.
      guard phoenixClient != nil, nativeJoinedChatIds.contains(chatId),
        (state["connected"] as? Bool) == true
      else { return }
      result = sendAgentBridgeHistoryOverCloudLocked(
        chatId: chatId, wirePayload: wirePayload, requestId: requestId)
    }
    guard (result["accepted"] as? Bool) == true else { return }

    lastBridgeRearmAtMsByChatId[chatId] = now
    liveBridgeSessionIngestByChatId[chatId] = (
      provider: live.provider, sessionId: live.sessionId, requestId: requestId
    )
    // Keep lastIngestedBridgeSessionSig so an identical re-push is a no-op (avoids
    // reloadData / layout jump). Only force_recover clears the sig for stuck shells.
    if trigger == "force_recover" {
      lastIngestedBridgeSessionSigByChatId.removeValue(forKey: chatId)
    }
    pendingBridgeSessionIngestByRequestId[requestId] = (chatId: chatId, provider: live.provider)
    let transport = normalizedString(result["transport"]) ?? "native"
    let ref = normalizedString(result["ref"]) ?? ""
    NSLog(
      "[ChatEngine][BridgeMount] rearm chat=%@ provider=%@ session=%@ trigger=%@ transport=%@ phoenix=%@",
      String(chatId.suffix(12)),
      live.provider,
      String(live.sessionId.prefix(12)),
      trigger,
      transport,
      (state["connected"] as? Bool) == true ? "ws-up" : "ws-down"
    )
    appendJournalLocked(
      event: "rearm-live-bridge-session",
      payload: [
        "chatId": chatId, "provider": live.provider, "trigger": trigger, "ref": ref,
      ]
    )
  }

  /// Render a bridge "detail" transcript payload into the chat as message rows.
  /// Runs on the engine queue (called from the socket-frame handler). Message ids
  /// are derived from the session id so re-opening the same session upserts in
  /// place rather than duplicating.
  /// The bridge daemon prepends an instruction preamble ("Vibe bridge startup
  /// prepared these instruction files… User task:\n<text>") to every prompt it hands
  /// the CLI. The CLI transcript records the full prompt, so when we re-ingest that
  /// transcript as history the user's own bubble would show the preamble. Strip it
  /// back to just the user's text. Only triggers on the exact preamble prefix, so a
  /// normal message that happens to mention "User task:" is untouched.
  static func strippedBridgeInstructionPreamble(_ text: String) -> String {
    guard text.hasPrefix("Vibe bridge startup prepared these instruction files"),
      let marker = text.range(of: "User task:")
    else { return text }
    return String(text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Canonical form of a transcript user turn for comparing against the phone's own
  /// sent row. Strips BOTH daemon-added preambles — the instruction-files preamble and
  /// the attachment pointer ("The user attached N image file(s)… \n\n<text>") — then
  /// trims. Two prompts are the "same send" when their comparable forms match.
  static func bridgeMirrorComparableText(_ text: String) -> String {
    var body = strippedBridgeInstructionPreamble(text)
    if body.hasPrefix("The user attached "), let marker = body.range(of: "\n\n") {
      body = String(body[marker.upperBound...])
    }
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// How far apart (ms) an own sent row and its transcript mirror may sit and still be
  /// treated as the same prompt. Wide on purpose: transcript timestamps come from the
  /// CLI's clock and history re-ingests can land much later than the original send.
  static let bridgeMirrorDedupWindowMs: Int64 = 48 * 3600 * 1000

  private static let transcriptISO8601MsFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let transcriptISO8601Formatter = ISO8601DateFormatter()

  /// Parse a transcript entry's timestamp — an ISO-8601 string from the CLI session
  /// JSONL (Claude/Codex), or an epoch number — into epoch milliseconds for row
  /// ordering. Returns nil when there's nothing parseable (caller falls back to
  /// ingest order).
  static func parseTranscriptTimestampMs(_ raw: Any?) -> Int64? {
    func fromNumber(_ value: Double) -> Int64? {
      guard value > 0 else { return nil }
      // Heuristic: values below ~1e11 are epoch seconds, above are already ms.
      return value < 100_000_000_000 ? Int64(value * 1000.0) : Int64(value)
    }
    if let value = raw as? Int64 { return fromNumber(Double(value)) }
    if let value = raw as? Int { return fromNumber(Double(value)) }
    if let value = raw as? Double { return fromNumber(value) }
    guard
      let string = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !string.isEmpty
    else { return nil }
    if let numeric = Double(string) { return fromNumber(numeric) }
    if let date = transcriptISO8601MsFormatter.date(from: string) {
      return Int64(date.timeIntervalSince1970 * 1000.0)
    }
    if let date = transcriptISO8601Formatter.date(from: string) {
      return Int64(date.timeIntervalSince1970 * 1000.0)
    }
    return nil
  }

  private func bridgeSessionSignatureText(_ raw: Any?) -> String {
    let text = normalizedString(raw) ?? ""
    guard !text.isEmpty else { return "0" }
    let head = String(text.prefix(32))
    let tail = String(text.suffix(32))
    return "\(text.count):\(head):\(tail)"
  }

  private func bridgeSessionProgressNodesSignature(_ raw: Any?) -> String {
    guard let nodes = raw as? [[String: Any]], !nodes.isEmpty else { return "0" }
    return nodes.enumerated().map { index, node in
      let id = normalizedString(node["id"]) ?? "\(index)"
      let kind = normalizedString(node["kind"] ?? node["itemType"]) ?? ""
      let status = normalizedString(node["status"]) ?? ""
      let label = bridgeSessionSignatureText(
        node["label"] ?? node["title"] ?? node["text"] ?? node["content"] ?? node["message"]
          ?? node["summary"])
      let target = bridgeSessionSignatureText(
        node["target"] ?? node["path"] ?? node["file_path"] ?? node["filePath"])
      let tokens = parseLongValue(node["tokens"]).map(String.init) ?? ""
      let duration = parseLongValue(node["durationMs"] ?? node["duration_ms"]).map(String.init) ?? ""
      let added = parseLongValue(node["added"]).map(String.init) ?? ""
      let removed = parseLongValue(node["removed"]).map(String.init) ?? ""
      return "\(id)|\(kind)|\(status)|\(label)|\(target)|\(tokens)|\(duration)|\(added)|\(removed)"
    }.joined(separator: "||")
  }

  private func ingestAgentBridgeSessionLocked(
    chatId: String,
    provider: String,
    payload: [String: Any]
  ) {
    guard let session = payload["session"] as? [String: Any] else { return }
    let sessionId =
      normalizedString(session["id"]) ?? normalizedString(payload["sessionId"]) ?? UUID().uuidString
    let hasMoreBefore =
      (session["hasMoreBefore"] as? Bool)
      ?? (session["has_more_before"] as? Bool)
      ?? false
    let nextBefore =
      normalizedString(session["nextBefore"] ?? session["next_before"] ?? session["before"])
    let responseBefore =
      normalizedString(payload["before"] ?? payload["beforeCursor"] ?? payload["before_cursor"])
    if var paging = bridgeSessionPagingByChatId[chatId], paging.sessionId == sessionId {
      if responseBefore != nil || paging.nextBefore == nil || paging.loadingOlder {
        paging.nextBefore = nextBefore
        paging.hasMoreBefore = hasMoreBefore
      }
      paging.loadingOlder = false
      bridgeSessionPagingByChatId[chatId] = paging
    } else {
      bridgeSessionPagingByChatId[chatId] = (
        provider: provider, sessionId: sessionId, nextBefore: nextBefore,
        hasMoreBefore: hasMoreBefore, loadingOlder: false
      )
    }
    // The bridge names every detail payload with the session's History-panel title
    // (ai-title / first user turn). Keep it per chat so the idle header can show which
    // session this thread is on. Captured before the empty-window guard: a topic is
    // meaningful even when no new messages rode along.
    if let topic = normalizedString(session["topic"]), !topic.isEmpty,
      bridgeSessionTopicByChatId[chatId] != topic
    {
      bridgeSessionTopicByChatId[chatId] = topic
      postChangeLocked(reason: "agentBridgeSessionTopic", userInfo: ["chatId": chatId])
    }
    let rawMessages = session["messages"] as? [[String: Any]] ?? []
    guard !rawMessages.isEmpty else { return }

    // Idempotent-ingest gate: if this transcript is identical to the last one we applied
    // for this chat (the common case on a socket-flap reconnect re-push), skip the whole
    // per-row re-decrypt + tombstone + reloadData churn. We still cheaply re-assert the
    // live header, in case a socket reset cleared agentProgress while we were down. The
    // signature mirrors the bridge's own dedup granularity (count + last turn identity +
    // progress-node content/status + running), so genuine text growth falls through and
    // re-applies instead of freezing an older/empty cell.
    let lastRaw = rawMessages.last
    let lastRawUid = normalizedString(lastRaw?["uid"] ?? lastRaw?["id"]) ?? ""
    let lastRawTextSig = bridgeSessionSignatureText(lastRaw?["text"])
    let lastRawNodeSig = bridgeSessionProgressNodesSignature(
      lastRaw?["progressNodes"] ?? lastRaw?["progress_nodes"])
    let lastRawRunning = (lastRaw?["running"] as? Bool) == true
    let ingestSig =
      "\(rawMessages.count):\(sessionId):\(lastRawUid):\(lastRawTextSig):\(lastRawNodeSig):\(lastRawRunning)"
    if lastIngestedBridgeSessionSigByChatId[chatId] == ingestSig {
      // Derive header from THIS payload only — never re-assert Thinking from a
      // stale lastRawRunning when the bridge has sealed the turn. Re-asserting on
      // every identical re-push was a root cause of the stuck "Thinking…" header
      // after settle (reopen-later-heals).
      if lastRawRunning {
        agentTurnRunningAtMsByChatId[chatId] = Int64(nowMs())
        // Still running this session → not settled; drop any stale terminal latch so its
        // tail cell tracks the live grace again.
        bridgeClearSessionSettledLocked(chatId: chatId, sessionId: sessionId)
        let nodes =
          (lastRaw?["progressNodes"] as? [[String: Any]])
          ?? (lastRaw?["progress_nodes"] as? [[String: Any]]) ?? []
        setAgentProgressLocked(
          chatId: chatId,
          label: agentProgressLabelFromNodes(nodes) ?? "Thinking",
          tool: nil,
          status: "running")
      } else {
        // Settled identical payload: clear the working header if it is still lit.
        // Do not wipe stream rows mid-grace here — the full settle branch below
        // only runs on a non-matching sig; identical settled re-pushes still need
        // the header cleared after bridge restart recovery.
        agentTurnRunningAtMsByChatId.removeValue(forKey: chatId)
        clearAgentProgressLocked(chatId: chatId, reason: "ingestSigMatch(settled)")
        // Latch this session settled (keyed to the tail's content sig) so a later
        // growth re-push can't re-light the tail via the chat-wide grace, and force
        // the already-ingested tail bridge-… row out of its streaming state now (this
        // path RETURNs before the per-row loop, so nothing else settles the cell).
        let tailContentSig = "\(lastRawUid):\(lastRawTextSig):\(lastRawNodeSig)"
        bridgeMarkSessionSettledLocked(chatId: chatId, sessionId: sessionId, contentSig: tailContentSig)
        settleBridgeTailRowStreamingLocked(chatId: chatId, sessionId: sessionId, uid: lastRawUid)
      }
      return
    }
    // Transcript GROWTH is proof of life, independent of the watcher's flaky `running`
    // flag. A watch-mirrored session (IDE-run; the bridge never spawned it) produces no
    // agent-stream frames at all, and its `running` flag flip-flops across re-pushes —
    // so during a long thinking/tool gap the flag can sit false past the grace and the
    // settle-clear wipes a turn whose content is visibly growing push-over-push. If this
    // push differs from the previous one for the SAME session and its newest item is an
    // agent item, refresh the running mark. First ingest (no prior sig) doesn't count —
    // opening an old, finished chat must not light the working header.
    let previousIngestSig = lastIngestedBridgeSessionSigByChatId[chatId]
    let lastRawRole = (normalizedString(lastRaw?["role"]) ?? "").lowercased()
    if let previousIngestSig, previousIngestSig.contains(":\(sessionId):"),
      previousIngestSig != ingestSig, lastRawRole != "user",
      // …but not once the session is terminally latched: a post-finish re-push (runtime
      // card / final token count) is "growth" too, and re-stamping grace here would keep a
      // done turn's tail shimmering for the whole 12s window (the settle race). A genuine
      // resume clears the latch first (below), so this only suppresses post-finish noise.
      !bridgeSessionIsSettledLocked(chatId: chatId, sessionId: sessionId)
    {
      agentTurnRunningAtMsByChatId[chatId] = Int64(nowMs())
    }
    lastIngestedBridgeSessionSigByChatId[chatId] = ingestSig

    let agentName: String = {
      switch provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "claude": return "Claude"
      case "codex": return "Codex"
      case "grok": return "Grok"
      case "agy", "antigravity": return "Agy"
      default: return provider.capitalized
      }
    }()
    let baseTs = Int64(nowMs())
    let me = currentUserIdLocked()
    var lastMessageId: String?
    var ingestedIds = Set<String>()
    var deltaInsertedIds: [String] = []
    var deltaUpdatedIds: [String] = []
    var deltaDeletedIds: [String] = []
    // Own NON-bridge user rows already in this chat's stores (the optimistic send row
    // and/or its persisted server twin). A transcript user turn matching one of these
    // is the CLI's mirror of a prompt this phone already renders. It must be skipped
    // at INGEST: merging alone can't save us because the chat view's per-message
    // overlay (`nativeEngineRowsById`, fed straight from the live store on
    // chatMessageInserted) bypasses `mergedChatRowsLocked`'s mirror dedup and would
    // resurrect the second bubble — the duplicated "my message" bug.
    var ownUserMirrorTwins: [(text: String, ts: Int64)] = []
    func collectOwnMirrorTwin(_ mid: String, _ row: [String: Any]) {
      guard !mid.hasPrefix("bridge-"), !mid.hasPrefix("stream-"),
        messageIsMe(fromRow: row),
        let message = row["message"] as? [String: Any],
        let rawText = normalizedString(message["text"])
      else { return }
      let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      ownUserMirrorTwins.append((text, messageTimestampMs(fromRow: row)))
    }
    for (mid, row) in liveMessageRowsByChat[chatId] ?? [:] {
      collectOwnMirrorTwin(mid, row)
    }
    for row in historyRowsByChat[chatId] ?? [] {
      if let mid = messageId(fromRow: row) { collectOwnMirrorTwin(mid, row) }
    }
    // The live `agent-stream` path renders the in-flight turn in real time (keyed
    // `stream-…`). If one is active, the session transcript's RUNNING turn is a
    // duplicate of it — skip it here and let the live row own the running turn. The
    // session still owns every FINISHED turn (rich diff/runtime card + scrollback).
    let hasLiveStreamRow =
      (liveMessageRowsByChat[chatId] ?? [:]).keys.contains { $0.hasPrefix("stream-") }
    var sawRunningAgentItem = false
    var ingestedAgentRow = false
    var runningTurnProgressNodes: [[String: Any]] = []
    // Only the LAST agent turn may be widened to "still streaming" through a tool/MCP gap
    // (the per-item `running` flag drops false while a tool executes, with no item actively
    // streaming). Older finished turns must stay collapsed. Track the tail agent item and,
    // as we pass it, its content signature (for the terminal-latch set/clear below).
    let tailAgentIndex = rawMessages.lastIndex {
      (normalizedString($0["role"]) ?? "").lowercased() != "user"
    }
    var tailAgentContentSig = ""

    for (index, item) in rawMessages.enumerated() {
      let role = (normalizedString(item["role"]) ?? "").lowercased()
      let text = (normalizedString(item["text"]) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      // A turn that has only run tools so far (no assistant prose yet) arrives as
      // an empty-text assistant message hosting the progress feed — keep it so the
      // live action stream still renders; otherwise drop empty placeholders.
      let hasProgressNodes = (item["progressNodes"] as? [[String: Any]])?.isEmpty == false
      guard !text.isEmpty || hasProgressNodes else { continue }
      // Skip the transcript's mirror of a prompt this phone already renders as its own
      // sent row (see ownUserMirrorTwins above). Not ingesting it also lets the
      // stale-row tombstone pass below clear any previously-ingested copy, so an
      // existing duplicate self-heals on the next re-push. Prompts typed elsewhere
      // (desktop CLI/IDE) have no own-row twin and still ingest normally.
      if role == "user" {
        let mirrorText = Self.bridgeMirrorComparableText(text)
        let mirrorTs =
          Self.parseTranscriptTimestampMs(item["ts"] ?? item["timestamp"]) ?? baseTs
        if !mirrorText.isEmpty,
          ownUserMirrorTwins.contains(where: {
            $0.text == mirrorText && abs($0.ts - mirrorTs) <= Self.bridgeMirrorDedupWindowMs
          })
        {
          continue
        }
      }
      // Is this the agent's currently-running turn? (the bridge flags it `running`.)
      let isRunningTranscriptItem = role != "user" && (item["running"] as? Bool) == true
      if isRunningTranscriptItem {
        sawRunningAgentItem = true
        runningTurnProgressNodes =
          (item["progressNodes"] as? [[String: Any]])
          ?? (item["progress_nodes"] as? [[String: Any]]) ?? []
        // A live stream row already shows this turn — skip the parallel session row
        // (and let the tombstone below drop any previously-ingested running row) so
        // the chat list never shows two "working" cards for one turn.
        if hasLiveStreamRow { continue }
      }
      let agentBodyText = text
      // A running turn KEEPS its narration "text" nodes inside progressNodes so the
      // live feed renders them interleaved with the tool steps (Read → text → Edit).
      // We used to strip them out here and fold the prose into the body, but the agent
      // view SUPPRESSES the body while a turn is live, so that made live turns show
      // "commands only". The bridge no longer unfolds either (see vibe-bridge.js
      // markDetailLiveTurn); the running-status mark below still leaves text nodes intact.
      let progressNodesPayload: Any? = item["progressNodes"] ?? item["progress_nodes"]
      // Stable id from the transcript's own message identity (claude uuid /
      // codex response-id) so the bridge's live re-pushes upsert in place even
      // as the capped window slides; fall back to array position.
      let stableKey =
        normalizedString(item["uid"]) ?? normalizedString(item["id"]) ?? "\(index)"
      let messageId = "bridge-\(sessionId)-\(stableKey)"
      // Order by the transcript's REAL timestamp so a turn's "Worked" card sits
      // right after its prompt. Before, every live re-ingest re-stamped all rows to
      // `now` (baseTs), so the worked card tied with the user's own follow-up (also
      // ~now) and the sort tiebreaker placed it in the wrong spot. Fall back to
      // ingest order only when the entry carries no parseable timestamp.
      let timestampMs =
        Self.parseTranscriptTimestampMs(item["ts"] ?? item["timestamp"]) ?? (baseTs + Int64(index))

      var synthetic: [String: Any] = [
        "id": messageId,
        "type": "text",
        "timestamp": timestampMs,
      ]
      if role == "user" {
        // isMe is derived from fromId == current user; plain text flows through
        // the non-hybrid `encryptedContent` path as the bubble text. Strip the bridge
        // instruction preamble the daemon prepends to each prompt before handing it to
        // the CLI — the CLI transcript records the WHOLE prompt, so without this the
        // user's bubble reads "Vibe bridge startup prepared these instruction files…
        // User task: <text>" instead of just their message.
        if let me, !me.isEmpty { synthetic["fromId"] = me }
        synthetic["encryptedContent"] = Self.strippedBridgeInstructionPreamble(text)
      } else {
        // Attribute each provider to its reserved shadow-user id so group list
        // layout (name + avatar gutter) can tell Claude/Codex/Grok/Agy apart.
        // The generic agentUserId collapsed every session-ingested row onto one
        // sender key — missing/wrong avatars and same-run grouping across agents.
        let providerAgentUserId =
          Self.bridgeAgentUserId(forProvider: provider) ?? Self.agentUserId
        synthetic["isAgentMessage"] = true
        synthetic["plainContent"] = agentBodyText
        synthetic["agentName"] = agentName
        synthetic["agentUsername"] = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        synthetic["fromId"] = providerAgentUserId
        synthetic["agentUserId"] = providerAgentUserId
        var meta: [String: Any] = [
          "agentWorkerVia": "bridge",
          "bridgeSessionId": sessionId,
          "agentName": agentName,
          "agentUserId": providerAgentUserId,
          "agentUsername": provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ]
        // The bridge flags the in-flight turn `running` while its task is live. Render
        // that turn as the streaming "working" state (shimmer + step feed), NOT a
        // collapsed "Worked · N steps" card — the card only belongs to a finished turn
        // (once the run's result lands the flag clears and it collapses).
        // Always write the flag (true or false) so a settle re-ingest cannot leave a
        // prior `isStreaming=true` stuck on the same bridge-… id (empty cell + Thinking
        // header after the session is already done).
        //
        // WIDEN the TAIL agent turn: the per-item `running` flag GAPS to false during a
        // text→tool/MCP execution window (nothing is actively streaming while the tool
        // runs), which collapsed the live cell to "Worked for Xs · N steps" and shifted
        // the list, then snapped back when the next node arrived. For the last agent turn
        // only, also treat it as streaming while the chat-wide run grace is fresh (the same
        // signal the header already uses through gaps) — unless this session is terminally
        // latched. Older turns keep the raw per-item flag so they stay collapsed.
        let isTailAgentItem = (index == tailAgentIndex)
        if isTailAgentItem {
          let itemUid = normalizedString(item["uid"] ?? item["id"]) ?? "\(index)"
          let itemTextSig = bridgeSessionSignatureText(item["text"])
          let itemNodeSig = bridgeSessionProgressNodesSignature(
            item["progressNodes"] ?? item["progress_nodes"])
          tailAgentContentSig = "\(itemUid):\(itemTextSig):\(itemNodeSig)"
          // Genuine resume: a running tail whose content moved past the latched settle
          // point re-opens the session. A stale `running=true` re-push with the SAME
          // content does not (its sig matches the latch) — so no post-finish flicker.
          if isRunningTranscriptItem,
            let latched = bridgeSettledSessionSigByChatId[chatId]?[sessionId],
            latched != tailAgentContentSig
          {
            bridgeClearSessionSettledLocked(chatId: chatId, sessionId: sessionId)
          }
        }
        let streamingFlag =
          isRunningTranscriptItem
          || (isTailAgentItem && bridgeRunIsLiveLocked(chatId: chatId, sessionId: sessionId))
        meta["isStreaming"] = streamingFlag
        synthetic["isStreaming"] = streamingFlag
        // Carry the per-message E2E runtime card forward so the ingested history
        // shows the same "N files changed +X −Y" card as the live path. The blob
        // stays opaque here; ChatListRow decrypts it with the phone-held key.
        if let enc = normalizedString(item["agentRuntimeEnc"] ?? item["agent_runtime_enc"]) {
          meta["agentRuntimeEnc"] = enc
        }
        if let canRevert = item["canRevert"] ?? item["can_revert"] {
          meta["canRevert"] = canRevert
        }
        // Live-tail per-action detail: the message sub-kind ("action"/"summary")
        // and its E2E-encrypted structured tool detail (command+output/todos).
        if let aKind = normalizedString(item["kind"]) {
          meta["agentMsgKind"] = aKind
        }
        if let aEnc = normalizedString(item["agentActionEnc"] ?? item["agent_action_enc"]) {
          meta["agentActionEnc"] = aEnc
        }
        // A turn's tool actions, folded into this assistant message as native
        // progress nodes (clean plaintext labels) + an E2E-encrypted detail array
        // (command OUTPUT, todo contents). Renders as the compact shimmer feed +
        // tap-to-open tool sheet — same path as the live stream.
        if let nodes = progressNodesPayload {
          if isRunningTranscriptItem, var mutableNodes = nodes as? [[String: Any]] {
            // Live Grok/Agy can stack every interim narration as kind:text — phone
            // logs showed textNodes=2–3 (old Verdict + new reply) in one cell.
            // Keep only the latest text node while the turn is running.
            mutableNodes = Self.collapseLiveTextProgressNodes(mutableNodes)
            for index in mutableNodes.indices.reversed() {
              let kind = (normalizedString(mutableNodes[index]["kind"]) ?? "").lowercased()
              if kind == "text" { continue }
              let rawStatus = normalizedString(mutableNodes[index]["status"])?.lowercased() ?? ""
              if ["failed", "error", "cancelled", "canceled", "stopped"].contains(rawStatus) {
                continue
              }
              mutableNodes[index]["status"] = "running"
              break
            }
            meta["progressNodes"] = mutableNodes
          } else {
            meta["progressNodes"] = nodes
          }
        }
        if let actionsEnc = normalizedString(item["agentActionsEnc"] ?? item["agent_actions_enc"]) {
          meta["agentActionsEnc"] = actionsEnc
        }
        synthetic["metadata"] = meta
      }
      let wasPresent =
        liveMessageRowsByChat[chatId]?[messageId] != nil
        || (historyRowsByChat[chatId] ?? []).contains {
          self.messageId(fromRow: $0) == messageId
        }
      _ = applyNativeIncomingMessageEventLocked(
        chatId: chatId, payload: synthetic, postDelta: false)
      if wasPresent {
        deltaUpdatedIds.append(messageId)
      } else {
        deltaInsertedIds.append(messageId)
      }
      ingestedIds.insert(messageId)
      if role != "user" { ingestedAgentRow = true }
      lastMessageId = messageId
    }

    // When the transcript shows the run fully finished (no running turn), any leftover
    // live `stream-…` bubble is stale — the rich finished `bridge-…` row now supersedes
    // it. Drop it so the finished turn isn't shown twice (mirrors the persisted-message
    // path's removeAgentStreamRowsLocked at the "message" frame).
    if ingestedAgentRow, !sawRunningAgentItem {
      // The transcript settled — the header's working indicator must not linger. BUT a
      // watch-mirrored session's `running` flag flip-flops across the bridge's per-tick
      // re-pushes: a single non-running push does NOT mean the run finished. Hold the
      // working state AND the synthetic live row through a short grace after the last
      // running push so a stale detail snapshot cannot blank the bubble/header and then
      // snap back when the next live tick arrives.
      let sinceRunningMs = Int64(nowMs()) - (agentTurnRunningAtMsByChatId[chatId] ?? 0)
      // An outstanding ask/command approval means the run is PAUSED waiting on the user:
      // the CLI is blocked, so no stream frames flow and no transcript push shows a
      // running turn — the grace expires "legitimately" and would wipe the live turn
      // mid-approval (header flips to "Start session", the working cell collapses, and
      // it all snaps back after Approve). The run is not dead, it's waiting — hold.
      let hasOutstandingAskLocked = agentBridgeAskByRequestId.values.contains { payload in
        (normalizedString(payload["chatId"]) ?? "") == chatId
      }
      if hasOutstandingAskLocked {
        VibeDebugLog.log(
          "[EmptyTrace] ingestSettle HOLD chatId=%@ reason=outstandingAsk sinceRunningMs=%lld",
          String(chatId.suffix(12)), sinceRunningMs)
        agentTurnRunningAtMsByChatId[chatId] = Int64(nowMs())
      } else if sinceRunningMs >= Self.agentTurnRunningGraceMs {
        // Scope to THIS session's own provider. A 1:1 DM has a single agent so this is
        // equivalent to clearing everything; a group can have a SECOND agent concurrently
        // streaming under the same chatId, and clearing indiscriminately would wipe that
        // agent's still-live row out from under it.
        let removal = removeAgentStreamRowsLocked(
          chatId: chatId, agentUserId: Self.bridgeAgentUserId(forProvider: provider))
        deltaDeletedIds.append(contentsOf: removal.removedIds)
        agentTurnRunningAtMsByChatId.removeValue(forKey: chatId)
        clearAgentProgressLocked(chatId: chatId, reason: "ingestSettle(noRunningTurn)")
        // Latch the session settled so a subsequent growth re-push can't re-widen its
        // tail cell (the loop already wrote isStreaming=false this push, since the grace
        // expired). Keyed to the tail's content sig for genuine-resume detection.
        bridgeMarkSessionSettledLocked(
          chatId: chatId, sessionId: sessionId, contentSig: tailAgentContentSig)
      }
    }

    // A transcript with a RUNNING turn is this chat's live session — register it in the
    // live-tail map so (a) `liveBridgeSessionId(chatId:)` reports it and the chat view's
    // fresh-surface filter shows the running conversation instead of hiding it as
    // "phantom history" (the open-mid-run empty-screen bug), and (b) a topic rejoin
    // re-arms this watch. Keyed to THIS reply's requestId — the bridge's transcript
    // watcher re-pushes under the same id, which is what the history handler matches.
    if sawRunningAgentItem {
      // Remember when we last saw this chat actively running so the settle-clear branch
      // above can distinguish a transient non-running re-push from a genuine finish.
      agentTurnRunningAtMsByChatId[chatId] = Int64(nowMs())
      let requestId = normalizedString(payload["requestId"]) ?? UUID().uuidString
      let existing = liveBridgeSessionIngestByChatId[chatId]
      if existing?.sessionId != sessionId || existing?.requestId != requestId {
        liveBridgeSessionIngestByChatId[chatId] = (
          provider: provider, sessionId: sessionId, requestId: requestId
        )
      }
      // Drive the chat header's working state from the ingest too: a watch-driven
      // session (e.g. one running in the IDE, never spawned by the bridge) produces no
      // agent-stream frames, so this is its ONLY live signal. Same label logic as the
      // stream path — latest tool action, or "Thinking · N tokens" for a thinking node.
      setAgentProgressLocked(
        chatId: chatId,
        label: agentProgressLabelFromNodes(runningTurnProgressNodes) ?? "Thinking",
        tool: nil,
        status: "running"
      )
    }

    // Clear rows left over from a PRIOR transcript shape. A previously-ingested row
    // for THIS session that the current transcript no longer contains (e.g. the old
    // one-bubble-per-assistant-text layout, now folded into a single per-turn
    // message) would otherwise linger as an orphan bubble. Tombstone every cached
    // `bridge-<sessionId>-…` row — across BOTH the live store and persisted history —
    // that wasn't just re-ingested. Skip this when the bridge sent a windowed tail
    // (`truncated`): then "absent" only means "older than the window", not "stale",
    // and deleting those would erase valid scrollback.
    let windowTruncated = (session["truncated"] as? Bool) ?? false
    if !windowTruncated {
      let sessionPrefix = "bridge-\(sessionId)-"
      var cachedSessionIds = Set<String>()
      for key in (liveMessageRowsByChat[chatId] ?? [:]).keys where key.hasPrefix(sessionPrefix) {
        cachedSessionIds.insert(key)
      }
      for row in historyRowsByChat[chatId] ?? [] {
        if let mid = messageId(fromRow: row), mid.hasPrefix(sessionPrefix) {
          cachedSessionIds.insert(mid)
        }
      }
      let alreadyDeleted = deletedMessageIdsByChat[chatId] ?? []
      var staleIds = cachedSessionIds.subtracting(ingestedIds).subtracting(alreadyDeleted)
      if !staleIds.isEmpty {
        VibeDebugLog.log(
          "[EmptyTrace] tombstone chatId=%@ stale=%d cached=%d ingested=%d truncated=N",
          String(chatId.suffix(12)), staleIds.count, cachedSessionIds.count, ingestedIds.count)
        // Mid-run mass-removal guard: while this chat's turn is live (running mark within
        // grace, or an ask outstanding), the only legitimate tombstone is the running row
        // superseded by its live stream twin — one or two ids. A push that suddenly lacks
        // MANY previously-ingested rows mid-run is a bad/windowed snapshot missing its
        // `truncated` flag, and honoring it wipes the whole visible transcript. Skip it;
        // the next complete push reconciles for real.
        let sinceRunningMs = Int64(nowMs()) - (agentTurnRunningAtMsByChatId[chatId] ?? 0)
        let askOutstanding = agentBridgeAskByRequestId.values.contains { payload in
          (normalizedString(payload["chatId"]) ?? "") == chatId
        }
        let runIsLive = askOutstanding || sinceRunningMs < Self.agentTurnRunningGraceMs
        if runIsLive, staleIds.count > 2 {
          VibeDebugLog.log(
            "[EmptyTrace] tombstone SKIP chatId=%@ stale=%d (live run — refusing mass removal)",
            String(chatId.suffix(12)), staleIds.count)
          staleIds.removeAll()
        }
      }
      if !staleIds.isEmpty {
        var perChat = liveMessageRowsByChat[chatId] ?? [:]
        var deleted = deletedMessageIdsByChat[chatId] ?? Set<String>()
        for staleId in staleIds {
          perChat.removeValue(forKey: staleId)
          deleted.insert(staleId)
        }
        if perChat.isEmpty {
          liveMessageRowsByChat.removeValue(forKey: chatId)
        } else {
          liveMessageRowsByChat[chatId] = perChat
        }
        deletedMessageIdsByChat[chatId] = deleted
        storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
        deltaDeletedIds.append(contentsOf: staleIds.sorted())
      }
    }

    if let lastMessageId {
      postChangeLocked(
        reason: "chatMessageInserted",
        userInfo: ["chatId": chatId, "messageId": lastMessageId, "state": statusSnapshotLocked()]
      )
    }
    postChatDeltaLocked(
      chatId: chatId,
      inserted: Array(Set(deltaInsertedIds)).sorted(),
      updated: Array(Set(deltaUpdatedIds)).sorted(),
      deleted: Array(Set(deltaDeletedIds)).sorted(),
      source: "bridge")
  }

  func retryOutgoingMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    return syncOnQueue {
      guard let messageId else {
        return ["accepted": false, "reason": "invalid_message"]
      }
      canceledOutboundMessageIds.remove(messageId)
      // Rebuild the draft when the in-memory one is gone, which is the ONLY case a user
      // ever actually retries.
      //
      // `pendingOutboundDraftsByMessageId` is memory plus a persisted mirror, and the
      // mirror is cleared on logout, chat wipes and a dozen other paths. Meanwhile
      // `sweepOrphanedPendingLocked` exists specifically to find pending rows with no
      // draft and mark them `error` "so it can be retried" — and then this guard refused
      // every one of them with `missing_draft`. A failed message showed a retry
      // affordance that could not work, which is exactly what a person reports as
      // "resend does nothing".
      //
      // The draft was never anything but the original send payload, and the message
      // itself is still in the store with its text, its chat and its reply target. So
      // rebuild it from the row rather than declaring the send unrecoverable. Media is
      // deliberately excluded: its bytes may be long gone from the cache, and silently
      // re-sending a caption without its picture is worse than saying no.
      let draft: [String: Any]
      if let existing = pendingOutboundDraftsByMessageId[messageId] {
        draft = existing
      } else if let rebuilt = rebuildOutboundDraftFromStoredRowLocked(
        chatId: chatId, messageId: messageId)
      {
        NSLog(
          "[ChatEngine] retry REBUILT draft chatId=%@ messageId=%@ — in-memory draft was gone",
          String((chatId ?? "-").prefix(12)), String(messageId.prefix(12)))
        pendingOutboundDraftsByMessageId[messageId] = rebuilt
        draft = rebuilt
      } else {
        NSLog(
          "[ChatEngine] retry REFUSED chatId=%@ messageId=%@ — no draft and no re-sendable row",
          String((chatId ?? "-").prefix(12)), String(messageId.prefix(12)))
        return ["accepted": false, "reason": "missing_draft", "messageId": messageId]
      }
      let resolvedChatId = chatId ?? normalizedString(draft["chatId"] ?? draft["chat_id"]) ?? ""
      guard !resolvedChatId.isEmpty else {
        return ["accepted": false, "reason": "invalid_chat", "messageId": messageId]
      }
      upsertLocalStatusLocked(
        chatId: resolvedChatId,
        messageId: messageId,
        status: "pending",
        allowDowngrade: true
      )
      queueOutboundDraftLocked(
        chatId: resolvedChatId, messageId: messageId, payload: draft, reason: "manual_retry")
      scheduleReplayQueuedOutboundLocked(chatId: resolvedChatId, trigger: "manual_retry")
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "manual_retry")
      }
      postChangeLocked(
        reason: "messageStatusChanged",
        userInfo: ["chatId": resolvedChatId, "messageId": messageId, "status": "pending"]
      )
      return ["accepted": true, "queued": true, "messageId": messageId, "state": "pending"]
    }
  }

  func cachePeerPublicKey(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let peerUserId = normalizedUpper(payload["peerUserId"] ?? payload["peer_user_id"] ?? payload["userId"] ?? payload["id"])
    let publicKey = extractPublicKeyValue(from: payload)
    return syncOnQueue {
      guard let chatId, !chatId.isEmpty, let peerUserId, !peerUserId.isEmpty else {
        return ["accepted": false, "reason": "invalid_peer"]
      }
      chatPeerUserIdsByChatId[chatId] = peerUserId
      if let publicKey, !publicKey.isEmpty {
        friendPublicKeysByUserId[peerUserId] = publicKey
        pendingFriendKeyChatIdsByUserId.removeValue(forKey: peerUserId)
        friendKeyRetryWorkItemsByUserId[peerUserId]?.cancel()
        friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerUserId)
        scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "peer_public_key_cached")
      } else {
        scheduleFriendPublicKeyFetchLocked(
          chatId: chatId,
          peerUserIdHint: peerUserId,
          trigger: "cache_peer_missing_key"
        )
      }
      appendJournalLocked(
        event: "peer-public-key-cache",
        payload: [
          "chatId": chatId,
          "peerUserId": peerUserId,
          "hasPublicKey": publicKey != nil,
        ]
      )
      return ["accepted": true, "chatId": chatId, "peerUserId": peerUserId, "hasPublicKey": publicKey != nil]
    }
  }

  func cancelOutgoingMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    return syncOnQueue {
      guard let messageId else {
        return ["accepted": false, "reason": "invalid_message"]
      }
      let resolvedChatId =
        chatId
        ?? pendingOutboundDraftsByMessageId[messageId].flatMap {
          normalizedString($0["chatId"] ?? $0["chat_id"])
        }
        ?? ""
      guard !resolvedChatId.isEmpty else {
        return ["accepted": false, "reason": "invalid_chat", "messageId": messageId]
      }
      // Canceling a media send is a full clean-up: abort the in-flight upload,
      // drop the queued draft, and remove the optimistic bubble entirely (the
      // message was never delivered). Inserting into canceledOutboundMessageIds
      // makes a racing upload completion bail instead of resurrecting the row,
      // and markLiveMessageDeletedLocked records the deletion so a later history
      // merge cannot bring the canceled message back.
      let activeUploadTask = activeMediaUploadTasksByMessageId.removeValue(forKey: messageId)
      let hadActiveUpload = activeUploadTask != nil
      activeUploadTask?.cancel()
      canceledOutboundMessageIds.insert(messageId)
      removeQueuedOutboundDraftLocked(chatId: resolvedChatId, messageId: messageId, dropDraft: true)
      setLiveMessageUploadProgressLocked(chatId: resolvedChatId, messageId: messageId, progress: nil)
      removeMessageIndicesLocked(chatId: resolvedChatId, messageId: messageId)
      markLiveMessageDeletedLocked(chatId: resolvedChatId, messageId: messageId)
      appendJournalLocked(
        event: "native-outgoing-cancel",
        payload: [
          "chatId": resolvedChatId,
          "messageId": messageId,
          "hadActiveUpload": hadActiveUpload,
        ])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(
        reason: "outgoingMessageCanceled",
        userInfo: [
          "chatId": resolvedChatId,
          "messageId": messageId,
          "state": snapshot,
        ])
      postChangeLocked(
        reason: "chatMessageDeleted",
        userInfo: [
          "chatId": resolvedChatId,
          "messageId": messageId,
          "action": "deleted",
          "state": snapshot,
        ])
      postChatDeltaLocked(
        chatId: resolvedChatId, inserted: [], updated: [], deleted: [messageId], source: "delete")
      return ["accepted": true, "messageId": messageId, "state": "removed"]
    }
  }

  func sendMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let providedMessageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    let type = (normalizedString(payload["type"]) ?? "text").lowercased()
    let text = normalizedString(payload["text"]) ?? ""
    let metadata = payload["metadata"] as? [String: Any] ?? [:]
    guard let chatId, !chatId.isEmpty else {
      return ["accepted": false, "reason": "invalid_chat"]
    }
    let supportedTypes: Set<String> = [
      "text", "image", "gif", "file", "voice", "video", "music", "location", "contact",
      "sticker",
    ]
    guard supportedTypes.contains(type) else {
      return ["accepted": false, "reason": "unsupported_type", "type": type]
    }
    let transportMode = syncOnQueue { transportModeLocked() }
    if transportMode == "bridge_text" && type != "text" {
      return ["accepted": false, "reason": "media_disabled_in_blackout", "type": type]
    }
    if transportMode == "packet_mesh", !["text", "voice", "image"].contains(type) {
      return ["accepted": false, "reason": "type_disabled_in_packet_mesh", "type": type]
    }

    let metadataValue: (String, [String]) -> Any? = { key, aliases in
      if let value = payload[key] { return value }
      for alias in aliases {
        if let value = payload[alias] { return value }
      }
      if let value = metadata[key] { return value }
      for alias in aliases {
        if let value = metadata[alias] { return value }
      }
      return nil
    }

    let mediaUrl = normalizedString(
      metadataValue("mediaUrl", ["media_url", "previewUrl", "preview_url"]))
    let localPlaybackMediaUrl = mediaUrl.flatMap { self.isLocalMediaURI($0) ? $0 : nil }
    let fileName = normalizedString(metadataValue("fileName", ["file_name"]))
    let fileSize = parseLongValue(metadataValue("fileSize", ["file_size"]))
    let latitude = parseDoubleValue(metadataValue("latitude", []))
    let longitude = parseDoubleValue(metadataValue("longitude", []))
    let duration = parseDoubleValue(metadataValue("duration", []))
    let width = parseLongValue(metadataValue("width", []))
    let height = parseLongValue(metadataValue("height", []))
    let caption = normalizedString(metadataValue("caption", []))
    let thumbnailBase64 = normalizedString(metadataValue("thumbnailBase64", ["thumbnail_base64"]))
    var mediaKey = normalizedString(metadataValue("mediaKey", ["media_key"]))
    let contact = metadataValue("contact", [])
    let viewOnce = metadataValue("viewOnce", ["view_once"])
    let isVideoNote = metadataValue("isVideoNote", ["is_video_note"])
    let waveform = metadataValue("waveform", [])
    let stickerId = normalizedString(metadataValue("stickerId", []))
    let stickerPackId = normalizedString(metadataValue("stickerPackId", ["packId", "pack_id"]))
    let stickerBundleFileName = normalizedString(
      metadataValue("stickerBundleFileName", ["bundleFileName", "bundle_file_name"]))
    let stickerEmoji = normalizedString(metadataValue("emoji", []))
    let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if type == "text" && !hasText {
      return ["accepted": false, "reason": "empty_text"]
    }
    if ["image", "gif", "file", "voice", "video", "music"].contains(type) {
      guard let mediaUrl, !mediaUrl.isEmpty else {
        return ["accepted": false, "reason": "missing_media_url", "type": type]
      }
    }
    if type == "location" && (latitude == nil || longitude == nil) {
      return ["accepted": false, "reason": "invalid_location"]
    }
    if type == "contact" && contact == nil {
      return ["accepted": false, "reason": "missing_contact"]
    }

    let messageId = providedMessageId ?? UUID().uuidString.lowercased()
    let timestampMs =
      parseLongValue(payload["timestampMs"] ?? payload["timestamp"] ?? payload["timestamp_ms"])
      ?? Int64(nowMs())
    let replyToId =
      normalizedString(payload["replyToId"] ?? payload["reply_to_id"])
      ?? normalizedString(metadata["replyToId"] ?? metadata["reply_to_id"])
    let peerUserIdHint = normalizedUpper(payload["peerUserId"] ?? payload["peer_user_id"])
    let explicitPeerAgentId =
      normalizedString(
        payload["peerAgentId"] ?? payload["peer_agent_id"] ?? payload["mentionedAgentId"]
          ?? payload["mentioned_agent_id"])

    return syncOnQueue {
      canceledOutboundMessageIds.remove(messageId)
      // Stamp the resolved id into the payload BEFORE anything queues it.
      //
      // A queued draft is replayed by handing it back to this function. Without an id
      // in the payload, `providedMessageId` is nil, a fresh UUID is minted, and the
      // replay is a brand-new message rather than a retry of this one — so every replay
      // pass adds another queue entry instead of re-sending the existing one.
      //
      // Measured on device, 2026-08-03: one message sent to a peer whose key had not
      // resolved grew the queue to 3,310 drafts in seconds and blocked the main thread
      // for 31s until the watchdog killed the app. The ids in the log were all distinct
      // UUIDs, which is what gave it away — those were not retries, they were new sends.
      var effectivePayload = payload
      effectivePayload["messageId"] = messageId
      let isGroup =
        (payload["isGroup"] as? Bool) == true || (payload["isGroupOrChannel"] as? Bool) == true
      // A channel arrives with `isGroup` true as well — the UI folds the two
      // together — so this is the only way to tell a conversation from a
      // broadcast, which they need to be for choosing an encryption scheme.
      let isChannel = (payload["isChannel"] as? Bool) == true
      NSLog(
        "[ChatEngine] sendMessage START chatId=%@ messageId=%@ isGroup=%@", chatId, messageId,
        isGroup ? "true" : "false")

      if let peerUserIdHint {
        chatPeerUserIdsByChatId[chatId] = peerUserIdHint
      }
      if let explicitPeerAgentId, !explicitPeerAgentId.isEmpty {
        chatPeerAgentIdsByChatId[chatId] = explicitPeerAgentId
        if let peerUserIdHint {
          agentIdsByPeerUserId[peerUserIdHint] = explicitPeerAgentId
        }
      }
      let peerUserId = peerUserIdHint ?? chatPeerUserIdsByChatId[chatId]
      let peerAgentId = explicitPeerAgentId ?? resolvePeerAgentIdLocked(
        chatId: chatId, peerUserIdHint: peerUserId)
      NSLog(
        "[AgentRoute] sendMessage routing chatId=%@ messageId=%@ explicitPeerAgentId=%@ resolvedPeerAgentId=%@ peerUserId=%@ willRoute=%@",
        chatId, messageId, explicitPeerAgentId ?? "nil", peerAgentId ?? "nil",
        peerUserId ?? "nil",
        (peerAgentId?.isEmpty == false) ? "agent-cleartext" : "e2e-peer")
      let bridgeProvider = bridgeProviderForChatLocked(
        chatId: chatId,
        peerUserId: peerUserId,
        peerAgentId: peerAgentId,
        metadata: metadata
      )
      let isVolatileBridgeSend = bridgeProvider != nil
      // Connection still warming up (cold chat open): don't fail the bridge send —
      // emit the optimistic bubble below, then hold the draft in the in-memory
      // outbound queue. chat_joined replays it; the visible-error timer expires it
      // if the link never comes up. Bridge drafts never persist to disk, so a stale
      // prompt can't dispatch an agent run on a later app launch.
      var deferredBridgeSendReason: String? = nil
      if isVolatileBridgeSend {
        clearVolatileBridgeHistoryLocked(chatId: chatId, reason: "bridge_send_start")
        if phoenixClient == nil || (state["connected"] as? Bool) != true {
          deferredBridgeSendReason = "no_native_socket"
          scheduleReconnectLocked(reason: "bridge_send_no_socket")
          DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.ensureNativeTransport(trigger: "bridge_send_no_socket")
          }
        } else if !nativeJoinedChatIds.contains(chatId) {
          deferredBridgeSendReason = "chat_not_joined"
          joinNativeChatTopicIfNeededLocked(chatId: chatId)
          DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.ensureNativeTransport(trigger: "bridge_send_chat_not_joined")
          }
        }
      }

      // ── Build + emit optimistic row FIRST so message bubble appears instantly ──
      let optimisticStartMs = nowMs()
      var decryptedFields: [String: Any] = ["text": text]
      // Keep the send metadata on the local row. The server strips the sealed image
      // blobs (`agentBridgeAttachmentsEnc`) from the broadcast/persisted copy, so this
      // row is the only place the sender's attached-image thumbnails can render from.
      if !metadata.isEmpty { decryptedFields["metadata"] = makeJSONSafeMap(metadata) }
      if let mediaUrl { decryptedFields["mediaUrl"] = mediaUrl }
      if let localPlaybackMediaUrl { decryptedFields["localMediaUrl"] = localPlaybackMediaUrl }
      if let fileName { decryptedFields["fileName"] = fileName }
      if let fileSize { decryptedFields["fileSize"] = fileSize }
      if let latitude { decryptedFields["latitude"] = latitude }
      if let longitude { decryptedFields["longitude"] = longitude }
      if let duration { decryptedFields["duration"] = duration }
      if let width { decryptedFields["width"] = width }
      if let height { decryptedFields["height"] = height }
      if let replyToId { decryptedFields["replyToId"] = replyToId }
      if let contact { decryptedFields["contact"] = contact }
      if let caption { decryptedFields["caption"] = caption }
      if let thumbnailBase64 { decryptedFields["thumbnailBase64"] = thumbnailBase64 }
      if let mediaKey { decryptedFields["mediaKey"] = mediaKey }
      if let viewOnce { decryptedFields["viewOnce"] = viewOnce }
      if let isVideoNote { decryptedFields["isVideoNote"] = isVideoNote }
      if let waveform { decryptedFields["waveform"] = waveform }
      if let stickerId { decryptedFields["stickerId"] = stickerId }
      if let stickerPackId { decryptedFields["stickerPackId"] = stickerPackId }
      if let stickerBundleFileName {
        decryptedFields["stickerBundleFileName"] = stickerBundleFileName
      }
      if let stickerEmoji { decryptedFields["emoji"] = stickerEmoji }
      var optimisticRow = buildLiveRowPayloadLocked(
        chatId: chatId,
        messageId: messageId,
        fromId: normalizedString(getConfigValueLocked("userId")),
        type: type,
        timestampMs: timestampMs,
        encryptedContent: nil,
        decryptedFields: decryptedFields
      )
      if var message = optimisticRow["message"] as? [String: Any] {
        message["status"] = "sending"
        if let replyToId { message["replyToId"] = replyToId }
        optimisticRow["message"] = message
      }
      // A message queued mid-join (chat_not_joined / missing_friend_key / no_socket)
      // emits this optimistic row once, then REPLAYS through sendMessage on
      // chat_joined — where the row already exists. Emit `inserted` only when the
      // row is genuinely new; on replay downgrade to `updated` so the list does an
      // in-place reload instead of a second insert push-up (the "shifts many times"
      // jump). The payload carries a stable timestampMs, so the replayed row keeps
      // its slot — no re-sort. upsertLiveMessageRowLocked returns true when new.
      let isNewOptimisticRow = upsertLiveMessageRowLocked(
        chatId: chatId, messageId: messageId, row: optimisticRow)
      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "sending")
      postChangeLocked(
        reason: isNewOptimisticRow ? "chatMessageInserted" : "chatMessageChanged",
        userInfo: [
          "chatId": chatId, "messageId": messageId,
          "action": isNewOptimisticRow ? "inserted" : "updated",
        ])
      postChangeLocked(
        reason: "messageStatusChanged",
        userInfo: ["chatId": chatId, "messageId": messageId, "status": "sending"])
      postChatDeltaLocked(
        chatId: chatId,
        inserted: isNewOptimisticRow ? [messageId] : [],
        updated: isNewOptimisticRow ? [] : [messageId],
        deleted: [], source: "optimistic")
      NSLog(
        "[ChatEngine] sendMessage optimistic row emitted in %dms chatId=%@ messageId=%@",
        Int(nowMs() - optimisticStartMs), chatId, messageId)

      if let deferReason = deferredBridgeSendReason {
        upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
        queueOutboundDraftLocked(
          chatId: chatId, messageId: messageId, payload: effectivePayload, reason: deferReason)
        NSLog(
          "[ChatEngine] sendMessage bridge deferred (warm-up) chatId=%@ messageId=%@ reason=%@",
          chatId, messageId, deferReason)
        postChangeLocked(
          reason: "messageStatusChanged",
          userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
        return [
          "accepted": true, "queued": true, "reason": deferReason,
          "messageId": messageId,
          "state": "pending",
          "bridgeProvider": bridgeProvider ?? "",
        ]
      }

      // ── Now resolve friend public key (may do synchronous HTTP — no longer blocks UI) ──
      let keyResolveStartMs = nowMs()
      let isSavedMessagesChat = chatId == "saved_messages"
      let friendPublicKey: String?
      if isGroup || isSavedMessagesChat {
        friendPublicKey = nil
      } else if let peerAgentId, !peerAgentId.isEmpty {
        friendPublicKey = nil
      } else {
        guard
          let key = resolveFriendPublicKeyLocked(
            chatId: chatId, peerUserIdHint: peerUserId)
        else {
          NSLog(
            "[ChatEngine] sendMessage queued reason=missing_friend_key chatId=%@ messageId=%@ keyResolveMs=%d",
            chatId, messageId, Int(nowMs() - keyResolveStartMs))
          upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
          pendingOutboundDraftsByMessageId[messageId] = effectivePayload
          queueOutboundDraftLocked(
            chatId: chatId, messageId: messageId, payload: effectivePayload,
            reason: "missing_friend_key")
          scheduleFriendPublicKeyFetchLocked(
            chatId: chatId,
            peerUserIdHint: peerUserId,
            trigger: "send_missing_friend_key"
          )
          // A forced history load used to run here, and it closed a feedback loop:
          // history completing calls `scheduleReplayQueuedOutboundLocked(trigger:
          // "history_loaded")`, which replays every queued draft, and each replay that
          // still has no key lands back on this branch and forces history again.
          //
          // It was never the right mechanism either — loading a transcript does not
          // resolve a friend's public key. `scheduleFriendPublicKeyFetchLocked` above is
          // what does, and the replay it triggers on success is the one that should send
          // these drafts.
          DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.ensureNativeTransport(trigger: "send_missing_friend_key")
          }
          appendJournalLocked(
            event: "native-send-message-error",
            payload: [
              "chatId": chatId,
              "messageId": messageId,
              "reason": "missing_friend_key",
            ])
          postChangeLocked(
            reason: "messageStatusChanged",
            userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
          return [
            "accepted": true, "queued": true, "reason": "missing_friend_key",
            "messageId": messageId,
            "state": "pending",
          ]
        }
        friendPublicKey = key
      }
      NSLog(
        "[ChatEngine] sendMessage keyResolved in %dms chatId=%@ messageId=%@ hasKey=%@",
        Int(nowMs() - keyResolveStartMs), chatId, messageId,
        friendPublicKey != nil ? "true" : "false")

      let apiBase = self.apiBaseURLLocked()
      let token = self.authHeaderTokenLocked()
      let userId = normalizedString(self.getConfigValueLocked("userId"))
      let myPublicKeyPem = normalizedString(
        self.getConfigValueLocked("publicKeyPem") ?? self.getConfigValueLocked("publicKey"))

      // ── MLS gate: a DM that can be end-to-end encrypted must be ───────────
      //
      // This has to fail closed. The encryption branch further down falls back
      // to `encryptedContent = fullPayloadString` — the payload in the clear —
      // so "no MLS session yet" must never reach it. Instead the draft waits,
      // exactly as it does for a missing friend key above, and establishment
      // is what releases it.
      //
      // Only replay on success: a failed attempt leaves the draft queued for a
      // later trigger to retry. A message stuck as pending is a bad experience;
      // a message silently sent unencrypted in a conversation the user believes
      // is private is a broken promise, and that is the trade being made here.
      //
      // Four kinds of chat are excluded, each for its own reason:
      //   * agent chats — the agent runs server-side and must read the message.
      //   * saved messages — sealed by the store layer, not this path.
      //   * channels — a subscriber expects to scroll back through everything
      //     posted before they joined, and MLS structurally cannot give them
      //     that: a joiner starts at the current epoch. Channels need the
      //     epoch-key scheme in `vibe_core::group`, which can hand a new member
      //     older keys. Until that is wired they keep their existing path.
      //   * chats already found too large — `VibeSecureSessions.isIneligible`.
      //   * chats whose peer has published no KeyPackage — there is no key to
      //     encrypt to, so waiting cannot succeed and the draft would sit
      //     pending forever rather than for a moment. This one is temporary
      //     and re-probed; see `VibeSecureSessions.peerKeysUnavailable`. It
      //     cannot weaken an established chat, because sealing is decided by
      //     `isPeerConfirmed` below and that is one-way.
      if VibeSecureSessions.isSendEnabled,
        !isSavedMessagesChat,
        !isChannel,
        (peerAgentId ?? "").isEmpty,
        !VibeSecureSessions.shared.isIneligible(chatId: chatId),
        !VibeSecureSessions.shared.peerKeysUnavailable(chatId: chatId),
        let mlsApiBase = apiBase,
        isGroup || normalizedString(peerUserId) != nil,
        !VibeSecureSessions.shared.hasSession(chatId: chatId)
      {
        NSLog(
          "[ChatEngine] sendMessage queued reason=mls_establishing chatId=%@ messageId=%@ group=%@",
          chatId, messageId, isGroup ? "Y" : "N")
        upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
        pendingOutboundDraftsByMessageId[messageId] = effectivePayload
        queueOutboundDraftLocked(
          chatId: chatId, messageId: messageId, payload: effectivePayload,
          reason: "mls_establishing")
        appendJournalLocked(
          event: "native-send-message-queued",
          payload: ["chatId": chatId, "messageId": messageId, "reason": "mls_establishing"])
        postChangeLocked(
          reason: "messageStatusChanged",
          userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
        // `retry` means "something changed, try the send again" — which is
        // usually "a session now exists", but is also how an over-cap group
        // reports that it has been marked ineligible. Either way the replay
        // re-evaluates the gate above, so this call site does not need to know
        // which happened. `false` leaves the draft queued for a later trigger.
        let onSettled: (Bool) -> Void = { [weak self] retry in
          guard let self = self, retry else { return }
          self.queue.async {
            self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "mls_established")
          }
        }
        if isGroup {
          if let myUserId = userId {
            VibeSecureEstablishment.establishGroup(
              chatId: chatId, myUserId: myUserId, apiBase: mlsApiBase, token: token,
              completion: onSettled)
          } else {
            // No identity means we cannot tell ourselves apart from the other
            // members, so we would add ourselves to our own group. Leave it
            // queued rather than build a broken session.
            VibeLog.error("[VibeSecure] no userId — cannot establish group \(chatId)")
          }
        } else if let mlsPeerUserId = normalizedString(peerUserId) {
          VibeSecureEstablishment.establishDirectMessage(
            chatId: chatId, peerUserId: mlsPeerUserId, apiBase: mlsApiBase, token: token,
            completion: onSettled)
        }
        return [
          "accepted": true, "queued": true, "reason": "mls_establishing",
          "messageId": messageId,
          "state": "pending",
        ]
      }

      let needsUpload =
        ["image", "gif", "file", "voice", "video", "music"].contains(type)
        && (mediaUrl != nil)
        && isLocalMediaURI(mediaUrl!)

      var uploadTargetUrl: String? = nil
      if needsUpload {
        uploadTargetUrl = mediaUrl
        // Eagerly compute file size from the local file so the UI can display
        // real-time progress (e.g. "1.2 MB / 16 MB") from the very first frame.
        if fileSize == nil, let localUri = mediaUrl, let localURL = localFileURL(from: localUri) {
          let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
          if let size = attrs?[.size] as? Int64, size > 0 {
            let fileSizeChanged = mutateLiveMessagePayloadLocked(
              chatId: chatId, messageId: messageId
            ) { message in
              message["fileSize"] = size
              var meta = (message["metadata"] as? [String: Any]) ?? [:]
              meta["fileSize"] = size
              message["metadata"] = meta
            }
            if fileSizeChanged {
              postChatDeltaLocked(
                chatId: chatId, inserted: [], updated: [messageId], deleted: [],
                source: "optimistic")
            }
          }
        }
        setLiveMessageUploadProgressLocked(chatId: chatId, messageId: messageId, progress: 0.02)
        postChangeLocked(
          reason: "chatMessageChanged",
          userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
        )
      }

      DispatchQueue.global(qos: .userInitiated).async {
        [weak self, friendPublicKey, uploadTargetUrl, myPublicKeyPem] in
        guard let self = self else { return }

        var finalMediaUrl = mediaUrl
        var finalFileName = fileName
        var finalFileSize = fileSize
        var finalMediaKey = mediaKey
        // Same "final" contract as the four above: the caller's value when it had one,
        // otherwise recovered from the uploaded bytes below. These three are what shape
        // the recipient's bubble before the media arrives.
        var finalWidth = width
        var finalHeight = height
        var finalThumbnailBase64 = thumbnailBase64
        var localEffectivePayload = effectivePayload
        var localOptimisticRow = optimisticRow

        if let localMediaUrl = uploadTargetUrl {
          guard let apiBase = apiBase, let token = token, let userId = userId else {
            self.queue.async {
              self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
              self.queueOutboundDraftLocked(
                chatId: chatId, messageId: messageId, payload: localEffectivePayload,
                reason: "missing_upload_config")
              self.appendJournalLocked(
                event: "native-media-upload-error",
                payload: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "reason": "missing_upload_config",
                ])
              self.setLiveMessageUploadProgressLocked(
                chatId: chatId, messageId: messageId, progress: nil)
              self.postChangeLocked(
                reason: "chatMessageChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
              )
              self.postChangeLocked(
                reason: "messageStatusChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
            }
            return
          }

          self.queue.async {
            self.appendJournalLocked(
              event: "native-media-upload-start",
              payload: [
                "chatId": chatId,
                "messageId": messageId,
                "type": type,
              ])
            // Seed 0 (not a fake fraction): the cell shows an indeterminate spinner
            // until real bytes flow, so the size label never claims progress that
            // hasn't happened.
            self.setLiveMessageUploadProgressLocked(
              chatId: chatId, messageId: messageId, progress: 0.0)
            self.postChangeLocked(
              reason: "chatMessageChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
            )
          }

          let uploadOutcome = self.uploadLocalMediaLocked(
            localUri: localMediaUrl,
            messageType: type,
            fileNameHint: fileName,
            userId: userId,
            token: token,
            apiBase: apiBase,
            messageId: messageId
          ) { progress in
            self.queue.async { [weak self] in
              guard let self else { return }
              if self.canceledOutboundMessageIds.contains(messageId) { return }
              let scaledProgress = max(0.0, min(1.0, Double(progress)))
              if self.setLiveMessageUploadProgressLocked(
                chatId: chatId,
                messageId: messageId,
                progress: scaledProgress
              ) {
                // A progress tick is NOT a message change. Posting it as one made every
                // observer that treats "chatMessageChanged" as "something happened in this
                // chat" do its full-refresh work several times a second for the whole
                // upload: Home refetched /api/chats (measured ~30 back-to-back 800ms
                // fetches during one 25s upload, each stealing bandwidth from the very
                // upload being reported) and the open conversation re-read + re-applied
                // its entire 60-row transcript per tick. The bar itself rides the
                // chatDelta above (source=upload), which reconfigures exactly the one
                // cell. This reason exists so a surface can opt IN to ticks; nothing
                // treats it as a content change.
                self.postChangeLocked(
                  reason: "mediaUploadProgress",
                  userInfo: [
                    "chatId": chatId,
                    "messageId": messageId,
                    "progress": scaledProgress,
                  ]
                )
              }
            }
          }

          if let uploadResult = uploadOutcome.result {
            finalMediaUrl = uploadResult.remoteUrl
            if finalFileName == nil { finalFileName = uploadResult.fileName }
            if finalFileSize == nil { finalFileSize = uploadResult.fileSize }
            if finalMediaKey == nil { finalMediaKey = uploadResult.mediaKey }

            // Seed the remote-media disk cache with the file we just uploaded so the
            // sender never re-downloads its own media after a restart/history reload.
            // This is THE moment to do it: the local path and the remote URL are both
            // in hand here and nowhere else — the server echo rebuilds the row from
            // encrypted_content, which carries the remote URL and has never heard of
            // `localMediaUrl`, so the link between message and on-disk file is gone
            // roughly a second later and never comes back.
            if ["image", "gif", "video"].contains(type) {
              chatMediaSeedRemoteCacheFromLocalFile(
                localURI: localMediaUrl,
                remoteURL: uploadResult.remoteUrl,
                mediaKey: finalMediaKey
              )
            }

            // Dimensions and the micro-thumb are the ONLY things that let the recipient
            // shape and paint this bubble before the bytes arrive. Missing both, the cell
            // takes the square fallback (see ChatListViewCells) and paints a blank box,
            // then resizes when the real image decodes — a photo-sized shift on the
            // recipient, every time.
            //
            // Both come from reading the picked file at compose time, so when that read
            // fails they are BOTH nil together, and every `if let` downstream omits them
            // in silence. Nothing errors; the recipient just gets a black square. The
            // bytes are in hand right here — the upload just read them — so recover from
            // the file. They ride inside the same envelope as everything else (sealed to
            // `friendPublicKey`, dual-wrapped so both parties can open it), so this adds
            // nothing to what the server can see.
            if ["image", "gif"].contains(type),
              finalWidth == nil || finalHeight == nil || finalThumbnailBase64 == nil
            {
              let localPath: String? = {
                if let url = URL(string: localMediaUrl), url.isFileURL { return url.path }
                return localMediaUrl.hasPrefix("/") ? localMediaUrl : nil
              }()
              if let localPath {
                if finalWidth == nil || finalHeight == nil,
                  let headerSize = chatMediaImageHeaderSize(atPath: localPath),
                  headerSize.width > 1.0, headerSize.height > 1.0
                {
                  finalWidth = Int64(headerSize.width)
                  finalHeight = Int64(headerSize.height)
                }
                if finalThumbnailBase64 == nil, let image = UIImage(contentsOfFile: localPath) {
                  finalThumbnailBase64 = chatMicroThumbnailJPEGBase64(from: image)
                }
              }
              NSLog(
                "[MediaDims] type=%@ dims=%@ thumb=%@ local=%@",
                type, (finalWidth != nil && finalHeight != nil) ? "Y" : "MISSING",
                finalThumbnailBase64 != nil ? "Y" : "MISSING", localPath ?? "<not-a-file>")
            }

            if ["voice", "audio", "music"].contains(type) {
              // Voice used to be seeded from `applyExternalVoicePlaybackIfNeeded` — a
              // CELL method, so it only ran if a materialized cell happened to be handed
              // playback state during the ~1.5s window between upload-complete and the
              // server echo (measured 18.121 → 19.687 on device). Lose that race, as a
              // cold list or a scrolled-away bubble always does, and the sender
              // re-downloads its own voice note on every relaunch forever. Seeding here
              // instead makes it unconditional. The cache slot holds DECRYPTED audio (the
              // download path decrypts before writing it), which is exactly what the
              // local recording already is.
              let localForSeed = localPlaybackMediaUrl ?? localMediaUrl
              let remoteForSeed = uploadResult.remoteUrl
              let seedFileName = finalFileName ?? fileName
              DispatchQueue.main.async {
                VoiceBubblePlaybackCoordinator.shared.seedRemoteVoiceCacheFromLocal(
                  localMediaURL: localForSeed,
                  remoteMediaURL: remoteForSeed,
                  fileName: seedFileName
                )
              }
            }

            var nextMetadata = (localEffectivePayload["metadata"] as? [String: Any]) ?? [:]
            nextMetadata["mediaUrl"] = uploadResult.remoteUrl
            if let localPlaybackMediaUrl { nextMetadata["localMediaUrl"] = localPlaybackMediaUrl }
            if let finalFileName { nextMetadata["fileName"] = finalFileName }
            if let finalFileSize { nextMetadata["fileSize"] = finalFileSize }
            if let finalMediaKey { nextMetadata["mediaKey"] = finalMediaKey }

            localEffectivePayload["metadata"] = nextMetadata
            localEffectivePayload["chatId"] = chatId
            localEffectivePayload["messageId"] = messageId
            localEffectivePayload["type"] = type
            localEffectivePayload["text"] = text
            // Point the DRAFT's top-level mediaUrl at the durable remote URL now that the
            // upload is done. `needsUpload` keys off mediaUrl being a *local* URI, so a
            // replay/retry of this draft (socket_open, chat_joined) would otherwise
            // re-upload the exact same file — measured 3× on a flapping socket, each adding
            // ~3s to the reconnect ack and firing another full cell reconfigure. The local
            // playback path stays preserved in metadata.localMediaUrl above.
            localEffectivePayload["mediaUrl"] = uploadResult.remoteUrl

            if var message = localOptimisticRow["message"] as? [String: Any] {
              message["mediaUrl"] = uploadResult.remoteUrl
              if let localPlaybackMediaUrl { message["localMediaUrl"] = localPlaybackMediaUrl }
              if let finalFileName { message["fileName"] = finalFileName }
              if let finalFileSize { message["fileSize"] = finalFileSize }
              if let finalMediaKey { message["mediaKey"] = finalMediaKey }
              var metadata = (message["metadata"] as? [String: Any]) ?? [:]
              if let finalMediaKey { metadata["mediaKey"] = finalMediaKey }
              if let localPlaybackMediaUrl { metadata["localMediaUrl"] = localPlaybackMediaUrl }
              message["metadata"] = metadata
              localOptimisticRow["message"] = message
            }

            let threadMediaUrl = finalMediaUrl
            let threadOptimisticRow = localOptimisticRow
            self.queue.async {
              self.upsertLiveMessageRowLocked(
                chatId: chatId, messageId: messageId, row: threadOptimisticRow)
              NSLog(
                "[ChatEngine] voice upload complete chatId=%@ messageId=%@ remoteUrl=%@ localPlayback=%@ type=%@",
                chatId,
                messageId,
                threadMediaUrl ?? "-",
                localPlaybackMediaUrl ?? "-",
                type
              )
              self.setLiveMessageUploadProgressLocked(
                chatId: chatId, messageId: messageId, progress: 1.0, postDelta: false)
              self.postChangeLocked(
                reason: "chatMessageChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
              )
              self.postChatDeltaLocked(
                chatId: chatId, inserted: [], updated: [messageId], deleted: [],
                source: "optimistic")
              self.appendJournalLocked(
                event: "native-media-upload-ok",
                payload: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "url": threadMediaUrl ?? "",
                ])
            }
          } else {
            let reason = uploadOutcome.reason ?? "upload_failed"
            let retryableReasons: Set<String> = [
              "upload_failed", "upload_timeout", "missing_upload_config",
            ]
            let shouldQueue = retryableReasons.contains(reason)

            self.queue.async {
              self.upsertLocalStatusLocked(
                chatId: chatId, messageId: messageId, status: shouldQueue ? "pending" : "error")
              self.appendJournalLocked(
                event: "native-media-upload-error",
                payload: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "reason": reason,
                ])
              self.setLiveMessageUploadProgressLocked(
                chatId: chatId, messageId: messageId, progress: nil)
              self.postChangeLocked(
                reason: "chatMessageChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
              )
              self.postChangeLocked(
                reason: "messageStatusChanged",
                userInfo: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "status": shouldQueue ? "pending" : "error",
                ])
              if shouldQueue {
                self.queueOutboundDraftLocked(
                  chatId: chatId, messageId: messageId, payload: localEffectivePayload,
                  reason: reason)
              } else {
                // Non-retryable failure: keep the draft (without auto-replay) so a
                // manual Retry can re-attempt the send instead of bailing with
                // missing_draft.
                self.pendingOutboundDraftsByMessageId[messageId] = localEffectivePayload
              }
              self.canceledOutboundMessageIds.remove(messageId)
            }
            return
          }
        }

        if self.syncOnQueue({ self.canceledOutboundMessageIds.contains(messageId) }) {
          self.queue.async {
            self.setLiveMessageUploadProgressLocked(
              chatId: chatId, messageId: messageId, progress: nil)
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
            self.postChangeLocked(
              reason: "chatMessageChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
            )
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "error"])
            self.canceledOutboundMessageIds.remove(messageId)
          }
          return
        }

        if isSavedMessagesChat {
          localEffectivePayload["chatId"] = chatId
          localEffectivePayload["messageId"] = messageId
          localEffectivePayload["type"] = type
          localEffectivePayload["text"] = text

          self.queue.async {
            self.removeQueuedOutboundDraftLocked(
              chatId: chatId, messageId: messageId, dropDraft: false)
            self.pendingOutboundDraftsByMessageId[messageId] = localEffectivePayload
            self.appendJournalLocked(
              event: "native-send-saved-message-start",
              payload: [
                "chatId": chatId,
                "messageId": messageId,
                "type": type,
              ])
            NSLog(
              "[ChatEngine] sendMessage saved_messages direct chatId=%@ messageId=%@ type=%@",
              chatId, messageId, type)
          }

          self.sendSavedMessage(localEffectivePayload) { result in
            self.queue.async { [weak self] in
              guard let self else { return }
              let success = (result["success"] as? Bool) == true
              let statusCode = result["status"] as? Int ?? -1
              let failureReason =
                normalizedString(result["reason"])
                ?? normalizedString(result["error"])
                ?? "saved_message_send_failed"
              self.setLiveMessageUploadProgressLocked(
                chatId: chatId, messageId: messageId, progress: nil)
              if success {
                self.removeQueuedOutboundDraftLocked(
                  chatId: chatId, messageId: messageId, dropDraft: true)
              } else {
                self.removeQueuedOutboundDraftLocked(
                  chatId: chatId, messageId: messageId, dropDraft: false)
              }
              self.upsertLocalStatusLocked(
                chatId: chatId,
                messageId: messageId,
                status: success ? "sent" : "error"
              )
              self.appendJournalLocked(
                event: success ? "native-send-saved-message-ok" : "native-send-saved-message-error",
                payload: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "status": statusCode,
                  "reason": success ? "ok" : failureReason,
                ])
              NSLog(
                "[ChatEngine] sendMessage saved_messages %@ chatId=%@ messageId=%@ status=%d reason=%@",
                success ? "OK" : "FAIL",
                chatId,
                messageId,
                statusCode,
                success ? "ok" : failureReason)
              self.postChangeLocked(
                reason: "chatMessageChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
              )
              self.postChangeLocked(
                reason: "messageStatusChanged",
                userInfo: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "status": success ? "sent" : "error",
                ])
            }
          }
          return
        }

        var fullPayloadBase: [String: Any] = ["text": text]
        if let finalMediaUrl { fullPayloadBase["mediaUrl"] = finalMediaUrl }
        if let finalMediaKey { fullPayloadBase["mediaKey"] = finalMediaKey }
        if let finalFileName { fullPayloadBase["fileName"] = finalFileName }
        if let finalFileSize { fullPayloadBase["fileSize"] = finalFileSize }
        if let latitude { fullPayloadBase["latitude"] = latitude }
        if let longitude { fullPayloadBase["longitude"] = longitude }
        if let duration { fullPayloadBase["duration"] = duration }
        if let finalWidth { fullPayloadBase["width"] = finalWidth }
        if let finalHeight { fullPayloadBase["height"] = finalHeight }
        if let replyToId { fullPayloadBase["replyToId"] = replyToId }
        if let contact { fullPayloadBase["contact"] = contact }
        if let caption { fullPayloadBase["caption"] = caption }
        if let finalThumbnailBase64 {
          fullPayloadBase["thumbnailBase64"] = finalThumbnailBase64
        }
        if let viewOnce { fullPayloadBase["viewOnce"] = viewOnce }
        if let isVideoNote { fullPayloadBase["isVideoNote"] = isVideoNote }
        if let waveform { fullPayloadBase["waveform"] = waveform }
        if let stickerId { fullPayloadBase["stickerId"] = stickerId }
        if let stickerPackId { fullPayloadBase["stickerPackId"] = stickerPackId }
        if let stickerBundleFileName {
          fullPayloadBase["stickerBundleFileName"] = stickerBundleFileName
        }
        if let stickerEmoji { fullPayloadBase["emoji"] = stickerEmoji }
        let fullPayload = makeJSONSafeMap(fullPayloadBase)
        guard
          let fullPayloadData = try? JSONSerialization.data(
            withJSONObject: fullPayload, options: []),
          let fullPayloadString = String(data: fullPayloadData, encoding: .utf8)
        else {
          self.queue.async {
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
          }
          return
        }

        let encryptedContent: String
        do {
          // MLS first when this chat has a session. A DM that *should* have one
          // never arrives here without it — the gate earlier in this function
          // queues it and establishes instead — so reaching the fall-through
          // below means this chat is one of the kinds listed there, not a
          // private conversation quietly losing its encryption.
          //
          // The send gate matters because a `vmls1.` envelope is unreadable to
          // any client that has not shipped this code: enabling it early does
          // not degrade a conversation, it splits it, and that is not
          // recoverable after the fact. See `VibeSecureSessions.isSendEnabled`.
          // `isPeerConfirmed` is not belt-and-braces — it is the whole safety
          // property. MLS tells a sender nothing about whether anyone can read
          // what it sealed, and a sender cannot check by decrypting its own
          // message, so without this a chat can go silently unreadable on both
          // sides at once and still look perfectly healthy. It did, on
          // 2026-08-06. Until the peer acks the Welcome we use the path that
          // already works.
          if VibeSecureSessions.isSendEnabled,
            VibeSecureSessions.shared.isPeerConfirmed(chatId: chatId)
          {
            // ── One-way ratchet: confirmed means MLS or nothing ─────────────
            //
            // A failed seal must NOT fall through to the hybrid branch below.
            // Letting it would mean a broken session — or a server that simply
            // stops serving KeyPackages — silently moves an already-private
            // conversation back onto the older envelope. That is a downgrade
            // an attacker can *trigger*, and neither participant would see any
            // sign of it: the message sends, ticks, and renders normally.
            //
            // Refusing is visible and recoverable; a silent downgrade is
            // neither. This is the whole reason `isPeerConfirmed` is one-way —
            // a chat that has ever been readable end-to-end never quietly
            // stops being so.
            guard
              let mlsSealed = VibeSecureSessions.shared.seal(
                chatId: chatId, plaintext: fullPayloadString)
            else {
              throw NSError(
                domain: "VibeSecure", code: 1,
                userInfo: [
                  NSLocalizedDescriptionKey:
                    "mls_seal_failed_on_confirmed_chat — refusing to send this "
                    + "message under a weaker envelope than the one this chat "
                    + "already uses"
                ])
            }
            // Keep our own plaintext: MLS encrypts to the group's *other*
            // members, so we cannot decrypt this back when the server echoes it
            // to us, and the row would render empty. See
            // `VibeSecureSessions.rememberOwnPlaintext`.
            VibeSecureSessions.shared.rememberOwnPlaintext(
              fullPayloadString, messageId: messageId)
            encryptedContent = mlsSealed
          } else if isGroup || friendPublicKey == nil {
            // Server-readable, and only these three cases can get here:
            //   * chats over the MLS member cap — broadcast channels, which
            //     this layer cannot tell apart from groups. The one genuine
            //     gap; see `VibeSecureSessions.isIneligible(chatId:)` and
            //     docs/secure-core-architecture.md §4.
            //   * agent chats — the agent runs server-side and must read the
            //     message to answer it. Encrypting it to ourselves would break
            //     the feature, so this is deliberate, not an oversight.
            //   * saved messages — sealed by the store layer, not this path.
            // A human DM or an ordinary group reaching this line would be a
            // bug in the gate above.
            encryptedContent = fullPayloadString
          } else {
            encryptedContent = try chatEngineEncryptHybridMessage(
              recipientPublicKeyPem: friendPublicKey!,
              message: fullPayloadString,
              myPublicKeyPem: myPublicKeyPem ?? ""
            )
          }
        } catch {
          self.queue.async {
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
            self.appendJournalLocked(
              event: "native-send-message-error",
              payload: [
                "chatId": chatId,
                "messageId": messageId,
                "reason": "encrypt_failed",
                "error": error.localizedDescription,
              ])
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "error"])
          }
          return
        }

        let pushPreview: String = {
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty {
            if trimmed.count <= 160 { return trimmed }
            return String(trimmed.prefix(159)) + "…"
          }
          switch type {
          case "image": return "Photo"
          case "video": return "Video"
          case "voice": return "Voice message"
          case "music": return "Audio"
          case "file": return "File"
          case "location": return "Location"
          case "contact": return "Contact"
          case "gif": return "GIF"
          case "sticker": return "Sticker"
          default: return ""
          }
        }()

        // Content-free stand-in for pushPreview, sent on EVERY path (including the
        // real-E2E one below that no longer gets pushPreview at all) so the server can
        // still shape a push notification / route by kind without reading the message.
        let pushKind: String = supportedTypes.contains(type) ? type : "text"

        // Mirrors the encryptedContent branch above: true only for a 1:1 DM where we
        // actually hold the peer's public key, i.e. the one path where encryptedContent
        // is real ciphertext rather than fullPayloadString in the clear.
        let isRealE2EDM = !isGroup && friendPublicKey != nil

        // CRITICAL: mediaUrl on the wire must be the durable remote URL after upload.
        // Historically this was always NSNull, so the server persisted media_url=NULL.
        // Encrypted payload still carried mediaUrl, but history/profile often only had
        // a dead local path in metadata — images vanished after reopen (esp. agent groups).
        var wirePayload: [String: Any] = [
          "id": messageId,
          "encryptedContent": encryptedContent,
          "timestamp": timestampMs,
          "type": type,
          "pushKind": pushKind,
          "mediaUrl": finalMediaUrl as Any? ?? NSNull(),
          "fileName": finalFileName as Any? ?? NSNull(),
          "latitude": latitude as Any? ?? NSNull(),
          "longitude": longitude as Any? ?? NSNull(),
        ]
        // pushPreview is up to 160 raw chars of the message, in the clear — load-bearing
        // for server-side @agent-mention routing (chat_channel.ex normalize_dispatch_text
        // / reserved_workers_from_text), so groups and agent chats keep it exactly as
        // before: the server already legitimately reads this text. A 1:1 E2E DM is the
        // one path where encryptedContent above is real ciphertext, so it was also the
        // one path where this field was a genuine leak — a cleartext copy of the message
        // riding right next to its own encrypted twin. Omitted there; pushKind is all the
        // server gets on that path.
        if !isRealE2EDM {
          wirePayload["pushPreview"] = pushPreview
        }
        // mediaKey (the media AES key) no longer rides the wire in the clear on ANY path.
        // It is already inside fullPayloadBase above, so it travels as part of
        // encryptedContent instead — real ciphertext for a 1:1 DM, the JSON payload
        // itself for groups/agent chats — and parseDecryptedMessagePayload (~line 9499)
        // reads it back out of that on the receiving end. The media bucket is public, so
        // key + bucket URL sitting together on the wire was equivalent to no encryption
        // at all. Do not re-add this field.
        if let replyToId, !replyToId.isEmpty {
          wirePayload["replyToId"] = replyToId
        }
        if let fromId = userId {
          wirePayload["fromId"] = fromId
        }
        if let peerAgentId, !peerAgentId.isEmpty {
          wirePayload["mentionedAgentId"] = peerAgentId
          if let agentText = payload["agentText"] as? String,
            !agentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            wirePayload["agentText"] = agentText
          } else {
            wirePayload["agentText"] = text
          }
        }
        if let agentMention = payload["agentMention"] as? Bool, agentMention {
          wirePayload["agentMention"] = true
          if let agentText = payload["agentText"] as? String {
            wirePayload["agentText"] = agentText
          }
        }
        if let mentionedAgentUsername = payload["mentionedAgentUsername"] as? String,
          !mentionedAgentUsername.isEmpty
        {
          wirePayload["mentionedAgentUsername"] = mentionedAgentUsername
          if let agentText = payload["agentText"] as? String {
            wirePayload["agentText"] = agentText
          }
        }
        // Prefer post-upload metadata (remote mediaUrl, thumbs) over the pre-upload copy.
        let wireMetadata =
          (localEffectivePayload["metadata"] as? [String: Any]).flatMap { $0.isEmpty ? nil : $0 }
          ?? (metadata.isEmpty ? nil : metadata)
        if let wireMetadata {
          // Never persist local-only file paths as the durable mediaUrl.
          var cleaned = makeJSONSafeMap(wireMetadata)
          if let remote = finalMediaUrl, !self.isLocalMediaURI(remote) {
            cleaned["mediaUrl"] = remote
          } else if let existing = cleaned["mediaUrl"] as? String, self.isLocalMediaURI(existing) {
            cleaned.removeValue(forKey: "mediaUrl")
          }
          // This dict rides the wire in the clear as wirePayload["metadata"] — it is NOT
          // inside encryptedContent. The post-upload block above (~line 4529) stamps
          // mediaKey into this same metadata dict for local retry/draft-replay bookkeeping
          // only; left in here it would re-leak the key through this side door on every
          // fresh media upload even after removing the top-level wirePayload["mediaKey"]
          // below. The recipient already gets the key from encryptedContent — strip both
          // casings so neither rides the wire a second time in the clear.
          cleaned.removeValue(forKey: "mediaKey")
          cleaned.removeValue(forKey: "media_key")
          // Sealed agent blobs stay on the wire for bridge dispatch only — server strips them
          // from broadcast/persist. Keep thumbs for durable list/profile after reopen.
          wirePayload["metadata"] = cleaned
        }

        if var message = localOptimisticRow["message"] as? [String: Any] {
          message["encryptedContent"] = encryptedContent
          localOptimisticRow["message"] = message
        }
        let threadOptimisticRow = localOptimisticRow
        let threadEffectivePayload = localEffectivePayload
        let threadWirePayload = wirePayload

        self.queue.async {
          if self.canceledOutboundMessageIds.contains(messageId) {
            self.setLiveMessageUploadProgressLocked(
              chatId: chatId, messageId: messageId, progress: nil)
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
            self.postChangeLocked(
              reason: "chatMessageChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
            )
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "error"])
            self.canceledOutboundMessageIds.remove(messageId)
            return
          }
          self.upsertLiveMessageRowLocked(
            chatId: chatId, messageId: messageId, row: threadOptimisticRow)
          self.postChatDeltaLocked(
            chatId: chatId, inserted: [], updated: [messageId], deleted: [],
            source: "optimistic")
          self.pendingOutboundDraftsByMessageId[messageId] = threadEffectivePayload

          guard let client = self.phoenixClient else {
            // Bridge sends queue here too — the draft replays on chat_joined and the
            // visible-error timer expires it (queueOutboundDraftLocked stamps it).
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
            self.queueOutboundDraftLocked(
              chatId: chatId, messageId: messageId, payload: threadEffectivePayload,
              reason: "no_native_socket")
            self.scheduleReconnectLocked(reason: "send_no_socket")
            DispatchQueue.global(qos: .utility).async { [weak self] in
              self?.ensureNativeTransport(trigger: "send_no_socket")
            }
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
            return
          }

          guard self.nativeJoinedChatIds.contains(chatId) else {
            self.joinNativeChatTopicIfNeededLocked(chatId: chatId)
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
            self.queueOutboundDraftLocked(
              chatId: chatId, messageId: messageId, payload: threadEffectivePayload,
              reason: "chat_not_joined"
            )
            self.scheduleReconnectLocked(reason: "send_chat_not_joined")
            DispatchQueue.global(qos: .utility).async { [weak self] in
              self?.ensureNativeTransport(trigger: "send_chat_not_joined")
            }
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
            return
          }

          let ref = client.push(
            topic: self.chatTopic(for: chatId), event: "message", payload: threadWirePayload)
          self.nativePendingMessagePushRefs[ref] = (chatId: chatId, messageId: messageId)
          self.nativeMessagePushSentAtMs[ref] = self.nowMs()

          let timeoutRef = ref
          self.queue.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self = self else { return }
            self.nativeMessagePushSentAtMs.removeValue(forKey: timeoutRef)
            if let pending = self.nativePendingMessagePushRefs.removeValue(forKey: timeoutRef) {
              let timeoutProvider = self.bridgeProviderForChatLocked(chatId: pending.chatId)
              if let timeoutProvider {
                // The push was on the wire — the server may have dispatched the agent
                // run. Keep the bubble, mark it failed, let the user decide on retry.
                self.markVolatileBridgeSendErrorLocked(
                  chatId: pending.chatId,
                  messageId: pending.messageId,
                  reason: "send_timeout",
                  provider: timeoutProvider
                )
                self.scheduleReconnectLocked(reason: "bridge_send_timeout")
                DispatchQueue.global(qos: .utility).async { [weak self] in
                  self?.ensureNativeTransport(trigger: "bridge_send_timeout")
                }
                return
              }
              if let draft = self.pendingOutboundDraftsByMessageId[pending.messageId] {
                self.scheduleRetryableOutboundReplayLocked(
                  chatId: pending.chatId,
                  messageId: pending.messageId,
                  draft: draft,
                  reason: "send_timeout",
                  recycleTransport: true
                )
              }
              self.appendJournalLocked(
                event: "native-send-timeout",
                payload: [
                  "chatId": pending.chatId,
                  "messageId": pending.messageId,
                  "ref": timeoutRef,
                ])
            }
          }

          self.appendJournalLocked(
            event: "native-send-message",
            payload: [
              "chatId": chatId,
              "messageId": messageId,
              "ref": ref,
            ])
          self.postChangeLocked(
            reason: "messageStatusChanged", userInfo: ["chatId": chatId, "messageId": messageId])
        }
      }

      return [
        "accepted": true,
        "queued": true,
        "messageId": messageId,
        "state": "sending",
      ]
    }
  }

  func sendDeleteMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    guard let chatId, let messageId else {
      return ["accepted": false, "reason": "invalid_payload"]
    }
    // Saved Messages is an HTTP-backed personal collection, intentionally never
    // joined as a Phoenix chat topic. Routing it through the live-chat delete
    // event always returned `chat_not_joined`, which the UI then mislabeled as a
    // connection problem.
    if chatId == "saved_messages" {
      return sendDeleteSavedMessage(messageId: messageId)
    }
    if syncOnQueue({ isBridgeTextModeLocked() }) {
      return ["accepted": false, "reason": "delete_disabled_in_blackout"]
    }

    let forEveryone: Bool = {
      switch payload["forEveryone"] ?? payload["for_everyone"] {
      case let bool as Bool:
        return bool
      case let str as String:
        return ["true", "1", "yes"].contains(str.lowercased())
      case let num as NSNumber:
        return num.boolValue
      default:
        return true
      }
    }()

    return syncOnQueue {
      guard let client = phoenixClient else {
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId) else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        return ["accepted": false, "reason": "chat_not_joined"]
      }

      let ref = client.push(
        topic: chatTopic(for: chatId), event: "delete-message",
        payload: [
          "messageId": messageId,
          "forEveryone": forEveryone,
        ])
      nativePendingDeletePushRefs[ref] = (
        chatId: chatId, messageId: messageId, forEveryone: forEveryone)
      NSLog(
        "[DeleteTrace] accepted chatId=%@ messageId=%@ forEveryone=%@ ref=%@",
        chatId, messageId, forEveryone ? "true" : "false", ref)
      removeMessageIndicesLocked(chatId: chatId, messageId: messageId)
      markLiveMessageDeletedLocked(chatId: chatId, messageId: messageId)
      applyPinnedUpdateLocked(
        chatId: chatId,
        messageId: messageId,
        pinned: false,
        payload: [:],
        trigger: "delete_optimistic",
        refreshRemote: false
      )
      let snapshot = statusSnapshotLocked()
      postChangeLocked(
        reason: "chatMessageDeleted",
        userInfo: [
          "chatId": chatId,
          "messageId": messageId,
          "action": "deleted",
          "state": snapshot,
        ]
      )
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [], deleted: [messageId],
        source: "deleteOptimistic")
      NSLog(
        "[DeleteTrace] optimistic removal chatId=%@ messageId=%@ forEveryone=%@",
        chatId, messageId, forEveryone ? "true" : "false")
      appendJournalLocked(
        event: "native-send-delete-message",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "forEveryone": forEveryone,
          "ref": ref,
        ])
      return [
        "accepted": true,
        "transport": "native",
        "ref": ref,
        "chatId": chatId,
        "messageId": messageId,
        "forEveryone": forEveryone,
      ]
    }
  }

  private func sendDeleteSavedMessage(messageId: String) -> [String: Any] {
    let requestContext: (apiBase: URL, token: String, userId: String)? = syncOnQueue {
      guard let apiBase = apiBaseURLLocked(),
        let userId = normalizedString(
          getConfigValueLocked("userId") ?? getConfigValueLocked("myUserId"))
      else {
        return nil
      }
      let token = authHeaderTokenLocked() ?? ""
      let chatId = "saved_messages"

      cachedSavedMessagesResponse?.removeAll { row in
        normalizedString(
          row["id"] ?? row["messageId"] ?? row["message_id"]
            ?? row["original_message_id"] ?? row["originalMessageId"]) == messageId
      }
      removeMessageIndicesLocked(chatId: chatId, messageId: messageId)
      markLiveMessageDeletedLocked(chatId: chatId, messageId: messageId)
      let snapshot = statusSnapshotLocked()
      postChangeLocked(
        reason: "chatMessageDeleted",
        userInfo: [
          "chatId": chatId,
          "messageId": messageId,
          "action": "deleted",
          "state": snapshot,
        ])
      postChatDeltaLocked(
        chatId: chatId,
        inserted: [],
        updated: [],
        deleted: [messageId],
        source: "savedDeleteOptimistic"
      )
      appendJournalLocked(
        event: "saved-message-delete-optimistic",
        payload: ["chatId": chatId, "messageId": messageId])
      NSLog("[DeleteTrace] saved accepted messageId=%@ transport=http", messageId)
      return (apiBase, token, userId)
    }

    guard let requestContext else {
      return ["accepted": false, "reason": "saved_messages_not_ready"]
    }
    performSavedMessageDeleteRequest(
      apiBase: requestContext.apiBase,
      token: requestContext.token,
      userId: requestContext.userId,
      messageId: messageId,
      attempt: 1
    )
    return [
      "accepted": true,
      "transport": "http",
      "chatId": "saved_messages",
      "messageId": messageId,
      "forEveryone": false,
    ]
  }

  private func performSavedMessageDeleteRequest(
    apiBase: URL,
    token: String,
    userId: String,
    messageId: String,
    attempt: Int
  ) {
    let url =
      apiBase
      .appendingPathComponent("api")
      .appendingPathComponent("saved_messages")
      .appendingPathComponent(userId)
      .appendingPathComponent(messageId)
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      guard let self else { return }
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      let success = error == nil && (200...299).contains(status)
      let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      NSLog(
        "[DeleteTrace] saved reply messageId=%@ attempt=%d status=%d success=%@ error=%@ body=%@",
        messageId,
        attempt,
        status,
        success ? "Y" : "N",
        error?.localizedDescription ?? "-",
        body.isEmpty ? "-" : body
      )
      if success {
        self.queue.async {
          self.appendJournalLocked(
            event: "saved-message-delete-reply",
            payload: [
              "messageId": messageId,
              "attempt": attempt,
              "status": status,
            ])
        }
        return
      }

      guard attempt < 3 else {
        self.queue.async {
          self.appendJournalLocked(
            event: "saved-message-delete-failed",
            payload: [
              "messageId": messageId,
              "attempts": attempt,
              "status": status,
              "error": error?.localizedDescription ?? "",
            ])
        }
        return
      }
      let retryDelay: TimeInterval = attempt == 1 ? 1.5 : 5.0
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + retryDelay) {
        [weak self] in
        self?.performSavedMessageDeleteRequest(
          apiBase: apiBase,
          token: token,
          userId: userId,
          messageId: messageId,
          attempt: attempt + 1
        )
      }
    }.resume()
  }

  func editMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    let nextText = normalizedString(payload["text"])
    guard let chatId, let messageId, let nextText else {
      return ["accepted": false, "reason": "invalid_payload"]
    }
    let trimmedText = nextText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      return ["accepted": false, "reason": "empty_text"]
    }

    return syncOnQueue {
      guard let existingMessage = findMessagePayloadLocked(chatId: chatId, messageId: messageId)
      else {
        return ["accepted": false, "reason": "message_not_found"]
      }
      let peerUserIdHint =
        normalizedUpper(payload["peerUserId"] ?? payload["peer_user_id"])
        ?? chatPeerUserIdsByChatId[chatId]
      // Agent DMs (Claude/Codex/shadow-agent peers) send cleartext — there is no
      // friend public key to resolve, and requiring one made every edit (e.g. adding
      // a caption to a sent image) fail silently with missing_friend_key.
      let peerAgentId = resolvePeerAgentIdLocked(chatId: chatId, peerUserIdHint: peerUserIdHint)
      let isAgentPeerChat = (peerAgentId?.isEmpty == false)
      let friendPublicKey: String?
      if isAgentPeerChat {
        friendPublicKey = nil
      } else {
        guard
          let key = resolveFriendPublicKeyLocked(
            chatId: chatId, peerUserIdHint: peerUserIdHint)
        else {
          scheduleFriendPublicKeyFetchLocked(
            chatId: chatId,
            peerUserIdHint: peerUserIdHint,
            trigger: "edit_missing_friend_key"
          )
          return ["accepted": false, "reason": "missing_friend_key"]
        }
        friendPublicKey = key
      }

      let editedAt = Int64(nowMs())
      var fullPayloadBase: [String: Any] = [
        "text": trimmedText,
        "isEdited": true,
        "editedAt": editedAt,
      ]
      if let mediaUrl = normalizedString(existingMessage["mediaUrl"]) {
        fullPayloadBase["mediaUrl"] = mediaUrl
        // Media rows render their text as the caption — keep the explicit caption
        // field in sync so history reloads show the edited description too.
        fullPayloadBase["caption"] = trimmedText
      }
      if let fileName = normalizedString(existingMessage["fileName"]) {
        fullPayloadBase["fileName"] = fileName
      }
      if let duration = parseDoubleValue(existingMessage["duration"]) {
        fullPayloadBase["duration"] = duration
      }
      if let replyToId = normalizedString(existingMessage["replyToId"]) {
        fullPayloadBase["replyToId"] = replyToId
      }
      if let metadata = existingMessage["metadata"] as? [String: Any] {
        if let width = metadata["width"] { fullPayloadBase["width"] = width }
        if let height = metadata["height"] { fullPayloadBase["height"] = height }
        if let thumbnailBase64 = metadata["thumbnailBase64"] {
          fullPayloadBase["thumbnailBase64"] = thumbnailBase64
        }
        if let isVideoNote = metadata["isVideoNote"] {
          fullPayloadBase["isVideoNote"] = isVideoNote
        }
        if let waveform = metadata["waveform"] { fullPayloadBase["waveform"] = waveform }
      }
      let fullPayload = makeJSONSafeMap(fullPayloadBase)
      guard
        let payloadData = try? JSONSerialization.data(withJSONObject: fullPayload, options: []),
        let payloadString = String(data: payloadData, encoding: .utf8)
      else {
        return ["accepted": false, "reason": "payload_encode_failed"]
      }
      let myPublicKeyPem = normalizedString(
        getConfigValueLocked("publicKeyPem") ?? getConfigValueLocked("publicKey"))
      let encryptedContent: String
      do {
        if let friendPublicKey {
          encryptedContent = try chatEngineEncryptHybridMessage(
            recipientPublicKeyPem: friendPublicKey,
            message: payloadString,
            myPublicKeyPem: myPublicKeyPem
          )
        } else {
          // Agent-peer chats ride cleartext, same as the send path.
          encryptedContent = payloadString
        }
      } catch {
        appendJournalLocked(
          event: "native-edit-message-error",
          payload: [
            "chatId": chatId,
            "messageId": messageId,
            "reason": "encrypt_failed",
            "error": error.localizedDescription,
          ])
        return ["accepted": false, "reason": "encrypt_failed"]
      }

      guard let client = phoenixClient else {
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId) else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        return ["accepted": false, "reason": "chat_not_joined"]
      }
      let ref = client.push(
        topic: chatTopic(for: chatId), event: "edit-message",
        payload: [
          "messageId": messageId,
          "encryptedContent": encryptedContent,
          "editedAt": editedAt,
        ])
      nativePendingEditPushRefs[ref] = (chatId: chatId, messageId: messageId)
      appendJournalLocked(
        event: "native-send-edit-message",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "ref": ref,
        ])
      let result: [String: Any] = ["accepted": true, "transport": "native", "ref": ref]
      _ = applyNativeChatMutationEventLocked(
        chatId: chatId,
        event: "message-edited",
        payload: [
          "messageId": messageId,
          "encryptedContent": encryptedContent,
          "editedAt": editedAt,
        ]
      )
      postChangeLocked(
        reason: "chatMessageEdited", userInfo: ["chatId": chatId, "messageId": messageId])
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [messageId], deleted: [], source: "edit")
      return result
    }
  }

  func deleteMessage(_ payload: [String: Any]) -> [String: Any] {
    sendDeleteMessage(payload)
  }

  func clearChat(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId, !chatId.isEmpty else {
      return ["accepted": false, "reason": "invalid_chat"]
    }
    let localOnly =
      parseBooleanLike(
        payload["localOnly"] ?? payload["local_only"] ?? payload["skipRemoteDelete"]
          ?? payload["skip_remote_delete"])
      ?? false

    let requestContext: (URL?, String)?
    requestContext = syncOnQueue {
      let apiBase = apiBaseURLLocked()
      let token = authHeaderTokenLocked() ?? ""
      clearChatStateLocked(chatId: chatId, journalEvent: "native-chat-clear-local")
      return (apiBase, token)
    }

    if localOnly {
      return ["accepted": true, "localOnly": true, "chatId": chatId]
    }

    guard let requestContext, let apiBase = requestContext.0 else {
      return ["accepted": false, "reason": "missing_config", "chatId": chatId]
    }
    let token = requestContext.1

    var request = URLRequest(
      url: apiBase.appendingPathComponent("api").appendingPathComponent("chats")
        .appendingPathComponent(chatId))
    request.httpMethod = "DELETE"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let error {
          self.appendJournalLocked(
            event: "native-chat-clear-error",
            payload: [
              "chatId": chatId,
              "error": error.localizedDescription,
            ])
          return
        }
        let success = (200...299).contains(statusCode)
        self.appendJournalLocked(
          event: success ? "native-chat-clear-ok" : "native-chat-clear-error",
          payload: [
            "chatId": chatId,
            "status": statusCode,
          ])
      }
    }.resume()

    return ["accepted": true, "queued": true, "chatId": chatId]
  }

  /// Remove every local projection of a chat. This is shared by the optimistic local
  /// delete path and by the `chat-deleted` event mirrored onto the user's own topic, so
  /// deleting a DM from another device (or for both participants) cannot leave Home,
  /// SQLite, the warm transcript, or receipt state pointing at a chat the server removed.
  /// Must be called on `queue`.
  private func clearChatStateLocked(chatId: String, journalEvent: String) {
    historyRowsByChat.removeValue(forKey: chatId)
    historyFullyLoadedChats.remove(chatId)
    historyRowsRestoredFromCacheChats.remove(chatId)
    historyOlderExhaustedChats.remove(chatId)
    historyLoadingOlderChats.remove(chatId)
    historyHasMoreByChat.removeValue(forKey: chatId)
    historyNextCursorByChat.removeValue(forKey: chatId)
    historyNextCursorBoundaryByChat.removeValue(forKey: chatId)
    clearCachedHistoryRowsLocked(chatId: chatId)
    if chatId == "saved_messages" {
      cachedSavedMessagesResponse = nil
    }
    historyLoadingChats.remove(chatId)
    liveMessageRowsByChat.removeValue(forKey: chatId)
    deletedMessageIdsByChat.removeValue(forKey: chatId)
    receiptIndex.removeValue(forKey: chatId)
    localStatusIndex.removeValue(forKey: chatId)
    pendingOutboundQueueByChat.removeValue(forKey: chatId)
    nativeTypingStateByChatId.removeValue(forKey: chatId)
    peerTypingUserIdsByChatId.removeValue(forKey: chatId)
    agentProgressByChatId.removeValue(forKey: chatId)
    nativeRecordingStateByChatId.removeValue(forKey: chatId)
    pinnedMessagesByChatId.removeValue(forKey: chatId)
    pinnedFetchInFlightChatIds.remove(chatId)
    chatPeerUserIdsByChatId.removeValue(forKey: chatId)
    openChatChannels.removeValue(forKey: chatId)

    let draftIdsToRemove = pendingOutboundDraftsByMessageId.compactMap {
      (messageId, draft) -> String? in
      let draftChatId = normalizedString(draft["chatId"] ?? draft["chat_id"])
      return draftChatId == chatId ? messageId : nil
    }
    draftIdsToRemove.forEach { pendingOutboundDraftsByMessageId.removeValue(forKey: $0) }

    if nativeJoinedChatIds.remove(chatId) != nil, let client = phoenixClient {
      client.leave(topic: chatTopic(for: chatId))
    }

    // Timeline core is a second reader of the same transcript. Wipe it with the
    // same semantics as the engine or a core-authoritative list will repaint the
    // history we just deleted.
    feedCoreClearChatLocked(chatId: chatId)

    appendJournalLocked(event: journalEvent, payload: ["chatId": chatId])
    state["updatedAt"] = nowMs()
    postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId])
    postChangeLocked(reason: "chatCleared", userInfo: ["chatId": chatId])
  }

  func blockUser(_ payload: [String: Any]) -> [String: Any] {
    let blockedUserId =
      normalizedString(
        payload["blockedUserId"] ?? payload["blocked_user_id"] ?? payload["peerUserId"]
          ?? payload["peer_user_id"])
    guard let blockedUserId, !blockedUserId.isEmpty else {
      return ["accepted": false, "reason": "invalid_user"]
    }

    let requestContext: (URL, String)?
    requestContext = syncOnQueue {
      guard let apiBase = apiBaseURLLocked() else { return nil }
      let token = authHeaderTokenLocked() ?? ""
      appendJournalLocked(
        event: "native-user-block-request",
        payload: ["blockedUserId": blockedUserId]
      )
      state["updatedAt"] = nowMs()
      return (apiBase, token)
    }

    guard let (apiBase, token) = requestContext else {
      return ["accepted": false, "reason": "missing_config"]
    }

    var request = URLRequest(
      url: apiBase.appendingPathComponent("api").appendingPathComponent("user")
        .appendingPathComponent("block"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try? JSONSerialization.data(
      withJSONObject: ["blocked_user_id": blockedUserId], options: [])

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let error {
          self.appendJournalLocked(
            event: "native-user-block-error",
            payload: [
              "blockedUserId": blockedUserId,
              "error": error.localizedDescription,
            ])
          return
        }
        let success = (200...299).contains(statusCode)
        self.appendJournalLocked(
          event: success ? "native-user-block-ok" : "native-user-block-error",
          payload: [
            "blockedUserId": blockedUserId,
            "status": statusCode,
          ])
        if success {
          self.postChangeLocked(
            reason: "userBlocked",
            userInfo: ["blockedUserId": blockedUserId]
          )
        }
      }
    }.resume()

    return ["accepted": true, "queued": true, "blockedUserId": blockedUserId]
  }

  func getPinnedMessages(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]) ?? ""
    let shouldRefresh = parseBooleanLike(payload["refresh"]) ?? false
    guard !chatId.isEmpty else {
      VibeDebugLog.log("[ChatEngine][Pin] getPinnedMessages ignored: empty chatId")
      return ["chatId": "", "loading": false, "data": []]
    }

    return syncOnQueue {
      if chatId == "saved_messages" {
        pinnedMessagesByChatId[chatId] = []
        VibeDebugLog.log("[ChatEngine][Pin] getPinnedMessages skip saved_messages")
        return [
          "chatId": chatId,
          "loading": false,
          "data": [],
        ]
      }
      let hasCache = pinnedMessagesByChatId[chatId] != nil
      if !hasCache {
        pinnedMessagesByChatId[chatId] = []
      }
      if (shouldRefresh || !hasCache) && !pinnedFetchInFlightChatIds.contains(chatId) {
        fetchPinnedMessagesLocked(chatId: chatId, trigger: "on_demand")
      }
      let cachedPins = pinnedMessagesByChatId[chatId] ?? []
      let isLoading = pinnedFetchInFlightChatIds.contains(chatId)
      if shouldRefresh || !hasCache || isLoading || !cachedPins.isEmpty {
        VibeDebugLog.log(
          "[ChatEngine][Pin] getPinnedMessages chatId=%@ refresh=%@ hasCache=%@ loading=%@ count=%@",
          chatId,
          shouldRefresh ? "true" : "false",
          hasCache ? "true" : "false",
          isLoading ? "true" : "false",
          String(cachedPins.count)
        )
      }
      return [
        "chatId": chatId,
        "loading": isLoading,
        "data": cachedPins,
      ]
    }
  }

  func pinMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    let pinned = parseBooleanLike(payload["pinned"]) ?? true
    VibeDebugLog.log(
      "[ChatEngine][Pin] pinMessage request chatId=%@ messageId=%@ pinned=%@",
      chatId ?? "(nil)",
      messageId ?? "(nil)",
      pinned ? "true" : "false"
    )
    guard let chatId, !chatId.isEmpty else {
      return ["accepted": false, "reason": "invalid_chat"]
    }
    guard let messageId, !messageId.isEmpty else {
      return ["accepted": false, "reason": "invalid_message"]
    }

    let requestContext: (URL, String)?
    requestContext = syncOnQueue {
      guard let apiBase = apiBaseURLLocked() else { return nil }
      let token = authHeaderTokenLocked() ?? ""
      applyPinnedUpdateLocked(
        chatId: chatId,
        messageId: messageId,
        pinned: pinned,
        payload: [
          "messageId": messageId,
          "chatId": chatId,
          "timestamp": nowMs(),
        ],
        trigger: "local_pin_request",
        refreshRemote: false
      )
      state["updatedAt"] = nowMs()
      postChangeLocked(
        reason: "chatPinnedUpdated",
        userInfo: ["chatId": chatId, "messageId": messageId, "pinned": pinned]
      )
      return (apiBase, token)
    }

    guard let (apiBase, token) = requestContext else {
      NSLog(
        "[ChatEngine][Pin] pinMessage missing config chatId=%@ messageId=%@",
        chatId,
        messageId
      )
      return ["accepted": false, "reason": "missing_config", "chatId": chatId]
    }

    var request = URLRequest(
      url: apiBase.appendingPathComponent("api").appendingPathComponent("chat")
        .appendingPathComponent(chatId).appendingPathComponent("messages")
        .appendingPathComponent(messageId).appendingPathComponent("pin"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["pinned": pinned], options: [])

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let error {
          NSLog(
            "[ChatEngine][Pin] pinMessage network error chatId=%@ messageId=%@ pinned=%@ error=%@",
            chatId,
            messageId,
            pinned ? "true" : "false",
            error.localizedDescription
          )
          self.appendJournalLocked(
            event: "native-pin-message-error",
            payload: [
              "chatId": chatId,
              "messageId": messageId,
              "pinned": pinned,
              "error": error.localizedDescription,
            ])
          self.fetchPinnedMessagesLocked(chatId: chatId, trigger: "pin_error_reconcile")
          return
        }
        let success = (200...299).contains(statusCode)
        NSLog(
          "[ChatEngine][Pin] pinMessage response chatId=%@ messageId=%@ pinned=%@ status=%@ success=%@",
          chatId,
          messageId,
          pinned ? "true" : "false",
          String(statusCode),
          success ? "true" : "false"
        )
        self.appendJournalLocked(
          event: success ? "native-pin-message-ok" : "native-pin-message-error",
          payload: [
            "chatId": chatId,
            "messageId": messageId,
            "pinned": pinned,
            "status": statusCode,
          ])
        self.fetchPinnedMessagesLocked(chatId: chatId, trigger: "pin_request_complete")
      }
    }.resume()

    return [
      "accepted": true, "queued": true, "chatId": chatId, "messageId": messageId, "pinned": pinned,
    ]
  }

  func getChatProfileSummary(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId, !chatId.isEmpty else {
      return [
        "chatId": "",
        "historyLoaded": false,
        "totalMessages": 0,
        "mediaCount": 0,
        "fileCount": 0,
        "linkCount": 0,
        "recentFiles": [],
      ]
    }

    return syncOnQueue {
      _ = restoreCachedHistoryRowsLocked(chatId: chatId)
      let rows = mergedChatRowsLocked(chatId: chatId)
      var totalMessages = 0
      var mediaCount = 0
      var fileCount = 0
      var linkCount = 0
      var recentFiles: [String] = []

      for row in rows {
        guard normalizedString(row["kind"]) == "message" else { continue }
        guard let message = row["message"] as? [String: Any] else { continue }
        totalMessages += 1

        let type = normalizedString(message["type"])?.lowercased() ?? "text"
        let text = normalizedString(message["text"]) ?? ""
        let caption = normalizedString(message["caption"]) ?? ""
        let mediaUrl = normalizedString(message["mediaUrl"])
        let fileName = normalizedString(message["fileName"])

        let isMediaType = ["image", "gif", "video", "voice", "music"].contains(type)
        if isMediaType {
          mediaCount += 1
        }

        let isFileType = type == "file" || (!isMediaType && fileName != nil)
        if isFileType {
          fileCount += 1
          if let fileName, !fileName.isEmpty, recentFiles.count < 3 {
            recentFiles.append(fileName)
          }
        }

        let hasLink =
          containsLinkCandidate(text) || containsLinkCandidate(caption)
          || containsLinkCandidate(mediaUrl)
        if hasLink {
          let agentRegex = try? NSRegularExpression(
            pattern: "(/api/agent/document/|/uploads/agent-docs/)", options: [])
          let isAgentDoc =
            agentRegex?.firstMatch(
              in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) != nil
            || agentRegex?.firstMatch(
              in: caption, options: [], range: NSRange(location: 0, length: caption.utf16.count))
              != nil
            || agentRegex?.firstMatch(
              in: mediaUrl ?? "", options: [],
              range: NSRange(location: 0, length: (mediaUrl ?? "").utf16.count)) != nil

          if !isAgentDoc {
            linkCount += 1
          }
        }
      }

      return [
        "chatId": chatId,
        "historyLoaded": historyRowsByChat[chatId] != nil,
        "totalMessages": totalMessages,
        "mediaCount": mediaCount,
        "fileCount": fileCount,
        "linkCount": linkCount,
        "recentFiles": recentFiles,
      ]
    }
  }

  func getJournal() -> [[String: Any]] {
    store.getJournal()
  }

  func clearJournal() -> [String: Any] {
    store.clearJournal()
    return syncOnQueue {
      journalEntryCount = 0
      state["updatedAt"] = nowMs()
      state["journalCount"] = 0
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "journalCleared", userInfo: [:])
      return snapshot
    }
  }

  /// Records the rows a chat currently has, for the lock-free main-thread read in
  /// `getChatRows`. Always called from the engine queue, where `merged` was produced.
  private func publishChatRows(_ merged: [[String: Any]], for chatId: String) {
    publishedChatRowsLock.lock()
    publishedChatRowsByChat[chatId] = merged
    publishedChatRowsLock.unlock()
  }

  func getLiveMessageRow(_ payload: [String: Any]) -> [String: Any]? {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    guard let chatId, let messageId else { return nil }
    return syncOnQueue {
      liveMessageRowsByChat[chatId]?[messageId]
    }
  }

  func getLiveMessageRows(_ payload: [String: Any]) -> [String: [String: Any]] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId else { return [:] }
    return syncOnQueue {
      liveMessageRowsByChat[chatId] ?? [:]
    }
  }

  /// Last result published for each chat, readable without entering the engine queue.
  /// See the fast path in `getChatRows`.
  private let publishedChatRowsLock = NSLock()
  private var publishedChatRowsByChat: [String: [[String: Any]]] = [:]

  /// Rows for a chat, without ever blocking the caller.
  ///
  /// `getChatRows` still falls back to `queue.sync` when nothing has been published for
  /// this chat yet, and from the main thread that means waiting behind whatever the
  /// engine is doing. One device session logged 31 such stalls, worst 238ms, three of
  /// them inside a single chat open — the biggest single contributor to "opening a chat
  /// blocks the main thread" left in the app.
  ///
  /// Home does not need a synchronous answer. It is projecting a preview into a list
  /// row, and it re-projects on the next change notification regardless. So it asks
  /// here: same-turn when the snapshot exists (the overwhelmingly common case), one
  /// engine turn later when it does not. The completion always runs on the main thread.
  func chatRows(chatId rawChatId: String, completion: @escaping ([[String: Any]]) -> Void) {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else {
      completion([])
      return
    }
    publishedChatRowsLock.lock()
    let published = publishedChatRowsByChat[chatId]
    publishedChatRowsLock.unlock()
    if let published {
      // Same-turn answer keeps Home's ordering identical to the old blocking read.
      // Off-main callers still get main delivery, so the contract holds for everyone.
      if Thread.isMainThread {
        completion(published)
      } else {
        DispatchQueue.main.async { completion(published) }
      }
      queue.async { [weak self] in
        guard let self else { return }
        _ = self.restoreCachedHistoryRowsLocked(chatId: chatId)
        self.restoreVolatileBridgeRowsIfNeededLocked(chatId: chatId)
        self.publishChatRows(self.mergedChatRowsLocked(chatId: chatId), for: chatId)
      }
      return
    }
    queue.async { [weak self] in
      guard let self else {
        DispatchQueue.main.async { completion([]) }
        return
      }
      _ = self.restoreCachedHistoryRowsLocked(chatId: chatId)
      self.restoreVolatileBridgeRowsIfNeededLocked(chatId: chatId)
      let merged = self.mergedChatRowsLocked(chatId: chatId)
      self.publishChatRows(merged, for: chatId)
      DispatchQueue.main.async { completion(merged) }
    }
  }

  func getChatRows(_ payload: [String: Any]) -> [[String: Any]] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId else { return [] }
    // The main thread never waits for this queue.
    //
    // `syncOnQueue` puts the caller behind whatever the engine is doing — a send, an E2E
    // decrypt, a SQLite write — and the callers here are UI. A device session measured 53
    // main-thread stalls in `getChatRows`, the worst at 623ms, which is most of the
    // remaining "the list feels laggy": Home re-projects on every `chatMessageChanged`,
    // and every one of those blocked the thread that was drawing the scroll.
    //
    // So a main-thread read answers from the last published result and asks for a refresh
    // instead of waiting for one. The snapshot is at most one engine turn old, and every
    // consumer already re-reads on the change notification that follows — which is the
    // same guarantee they had before, since the value could go stale the instant the
    // queue released them anyway.
    //
    // The first read of a chat has nothing published and falls through to the blocking
    // path, so a cold open is exactly as correct as it was.
    if Thread.isMainThread {
      publishedChatRowsLock.lock()
      let published = publishedChatRowsByChat[chatId]
      publishedChatRowsLock.unlock()
      if let published {
        queue.async { [weak self] in
          guard let self else { return }
          _ = self.restoreCachedHistoryRowsLocked(chatId: chatId)
          self.restoreVolatileBridgeRowsIfNeededLocked(chatId: chatId)
          self.publishChatRows(self.mergedChatRowsLocked(chatId: chatId), for: chatId)
        }
        return published
      }
    }
    return syncOnQueue {
      _ = restoreCachedHistoryRowsLocked(chatId: chatId)
      restoreVolatileBridgeRowsIfNeededLocked(chatId: chatId)
      let merged = mergedChatRowsLocked(chatId: chatId)
      publishChatRows(merged, for: chatId)
      // [EmptyTrace] The view pulls its rows here. Log when this returns EMPTY — that's the
      // "list jumps to empty" moment. The live/hist breakdown says WHERE the content went:
      // live=0 & hist=0 → both stores wiped (a reset), live=0 & hist>0 → merge/filter drop.
      if merged.isEmpty {
        VibeDebugLog.log(
          "[EmptyTrace] getChatRows EMPTY chatId=%@ live=%d hist=%d progress=%@",
          String(chatId.suffix(12)),
          liveMessageRowsByChat[chatId]?.count ?? 0,
          historyRowsByChat[chatId]?.count ?? 0,
          agentProgressByChatId[chatId] != nil ? "active" : "cleared")
      }
      return merged
    }
  }

  /// Home's decrypted last-message preview. **Never blocks the main thread.**
  ///
  /// This used to be `syncOnQueue { buildHistoryRowsLocked(...) }` — an E2E decrypt, on
  /// the caller's thread, behind the engine's serial queue — and Home calls it once per
  /// visible row while laying out. A device run on 2026-08-03 measured the result:
  ///
  /// ```
  /// syncOnQueue blocked main thread for 772ms at makeHomePreviewText(_:)
  /// main-thread-stall blockedMs=31504 context=ChatHomeNativeListController apply nextRows=15
  /// ```
  ///
  /// Fifteen rows, each waiting on a queue that was busy sending, and Home frozen for
  /// half a minute. Two of the four measured scroll costs in
  /// `docs/production-timeline-core-refactor.md` §0 meet on this one line: per-row
  /// decrypt during parse, and `queue.sync` from main.
  ///
  /// So it answers from a memo and never waits. A miss returns `nil` — the caller
  /// already has a chain of fallbacks for exactly that — and schedules the decrypt off
  /// the main thread. When it lands, Home is told, and the next render has the text.
  ///
  /// Deterministic by message id, so the memo cannot go stale in a way that matters: an
  /// edit mints a new content hash and therefore a new key.
  func makeHomePreviewText(_ payload: [String: Any]) -> String? {
    guard let cacheKey = Self.homePreviewCacheKey(payload) else { return nil }
    if let memo = homePreviewMemo.value(for: cacheKey) { return memo }
    schedulePreviewDecrypt(cacheKey: cacheKey, payload: payload)
    return nil
  }

  /// Computes one preview off the main thread and publishes it.
  ///
  /// In-flight keys are tracked so fifteen rows re-rendering while the first decrypt is
  /// running cannot queue fifteen copies of the same work — the render loop would
  /// otherwise re-ask on every pass and each pass would schedule again.
  private func schedulePreviewDecrypt(cacheKey: String, payload: [String: Any]) {
    guard homePreviewMemo.beginIfNotInFlight(cacheKey) else { return }
    queue.async { [weak self] in
      guard let self else { return }
      let text = self.homePreviewTextLocked(payload)
      self.homePreviewMemo.finish(cacheKey, value: text)
      // Only a *found* preview is worth a redraw. Publishing a miss would tell Home to
      // re-render, which re-asks, which finds the memo holding nil and returns the same
      // fallback text it already drew — a wakeup per undecryptable row, forever.
      guard text != nil else { return }
      self.postChangeLocked(
        reason: "chatPreviewDecrypted", userInfo: ["cacheKey": cacheKey])
    }
  }

  /// The original body, now only ever reached on the engine queue.
  private func homePreviewTextLocked(_ payload: [String: Any]) -> String? {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]) ?? "home_preview"
    guard
      let row = buildHistoryRowsLocked(chatId: chatId, rawMessages: [payload]).first,
      let message = row["message"] as? [String: Any]
    else {
      return nil
    }
    if (message["decryptionFailed"] as? Bool) == true {
      return nil
    }
    guard let text = normalizedString(message["plainContent"] ?? message["text"]),
      !isLikelyHybridCiphertext(text)
    else {
      return nil
    }
    return text
  }

  /// Identity of a preview: the message, plus enough of its ciphertext that an edit
  /// cannot be served from the memo of the version before it.
  private static func homePreviewCacheKey(_ payload: [String: Any]) -> String? {
    let id =
      (payload["messageId"] as? String) ?? (payload["message_id"] as? String)
      ?? (payload["id"] as? String)
    guard let id, !id.isEmpty else { return nil }
    let body =
      (payload["encryptedContent"] as? String) ?? (payload["encrypted_content"] as? String)
      ?? (payload["content"] as? String) ?? (payload["text"] as? String) ?? ""
    return "\(id)|\(body.count)|\(body.suffix(16))"
  }

  func typingUserIds(chatId: String?) -> [String] {
    guard let chatId = normalizedString(chatId), !chatId.isEmpty else { return [] }
    if let published = uiMirror.typingUserIds(chatId: chatId) { return published }
    return syncOnQueue {
      Array(peerTypingUserIdsByChatId[chatId] ?? []).sorted()
    }
  }

  /// The chat's live agent progress, or `nil` when nothing is running.
  ///
  /// This getter is the one a device run caught blocking the main thread for
  /// 64 ms — not because the lookup is slow, but because it queued behind a
  /// decrypt. It reads the mirror now; the queue is only touched before the
  /// first publish.
  ///
  /// The terminal/staleness rules live in
  /// ``ChatEngineAgentProgressSnapshot/activePayload(nowMs:)`` so both paths
  /// share one implementation. Two copies of a "has this gone stale" rule is how
  /// a spinner ends up running forever on one path and not the other.
  func agentProgress(chatId: String?) -> [String: Any]? {
    guard let chatId = normalizedString(chatId), !chatId.isEmpty else { return nil }
    let now = Int64(nowMs())
    if let published = uiMirror.agentProgress(chatId: chatId) {
      return published?.activePayload(nowMs: now)
    }
    return syncOnQueue { () -> [String: Any]? in
      guard let state = agentProgressByChatId[chatId] else { return nil }
      return ChatEngineAgentProgressSnapshot(
        label: state.label,
        tool: state.tool,
        status: state.status,
        updatedAtMs: state.updatedAtMs
      ).activePayload(nowMs: now)
    }
  }

  /// True when the bridge CLI is actively working or paused for user input in this chat.
  /// This intentionally does NOT use `liveBridgeSessionIngestByChatId`: that map also
  /// represents a mounted History transcript subscription, and treating it as "busy"
  /// strands mobile follow-ups in the pending queue for already-settled sessions.
  func bridgeRunIsActive(chatId: String?) -> Bool {
    guard let chatId = normalizedString(chatId), !chatId.isEmpty else { return false }
    return syncOnQueue {
      if agentProgressByChatId[chatId] != nil { return true }
      let now = Int64(nowMs())
      if let lastRunningAt = agentTurnRunningAtMsByChatId[chatId],
        now - lastRunningAt < Self.agentTurnRunningGraceMs
      {
        return true
      }
      return agentBridgeAskByRequestId.values.contains { payload in
        (normalizedString(payload["chatId"]) ?? "") == chatId
      }
    }
  }

  /// Returns true only if native chat history has been successfully fetched
  /// from the server for this chatId. Used by ChatListView to decide whether
  /// native rows can fully replace JS rows.
  /// Per-chat history flags, readable without entering the engine queue.
  ///
  /// The fifth and sixth members of the same family as `getChatRows`, `getStatus` and
  /// `liveBridgeSessionId`: a set-membership test that costs nothing to compute and
  /// 115ms to *reach*, because reaching it means queueing behind a send or a decrypt.
  /// One snapshot serves both flags, refreshed whenever a queued call passes through.
  ///
  /// `ready` distinguishes "published: this chat is not loading" from "nothing has been
  /// published yet", which are different answers and must not both come back as false.
  private struct PublishedChatFlags {
    var loaded = false
    var loading = false
  }
  private let publishedChatFlagsLock = NSLock()
  private var publishedChatFlags: [String: PublishedChatFlags] = [:]
  private var publishedChatFlagsReady = false

  private func publishChatFlags(for chatId: String) {
    var flags = PublishedChatFlags()
    flags.loaded = historyFullyLoadedChats.contains(chatId)
    flags.loading =
      historyLoadingChats.contains(chatId) || historyLoadingOlderChats.contains(chatId)
    publishedChatFlagsLock.lock()
    publishedChatFlags[chatId] = flags
    publishedChatFlagsReady = true
    publishedChatFlagsLock.unlock()
  }

  private func publishedChatFlags(for chatId: String) -> PublishedChatFlags? {
    publishedChatFlagsLock.lock()
    defer { publishedChatFlagsLock.unlock() }
    guard publishedChatFlagsReady else { return nil }
    return publishedChatFlags[chatId] ?? PublishedChatFlags()
  }

  func isChatHistoryLoaded(chatId: String) -> Bool {
    if Thread.isMainThread, let flags = publishedChatFlags(for: chatId) {
      queue.async { [weak self] in
        guard let self else { return }
        _ = self.restoreCachedHistoryRowsLocked(chatId: chatId)
        self.publishChatFlags(for: chatId)
      }
      return flags.loaded
    }
    return syncOnQueue {
      _ = restoreCachedHistoryRowsLocked(chatId: chatId)
      publishChatFlags(for: chatId)
      return historyFullyLoadedChats.contains(chatId)
    }
  }

  /// True while a history fetch (initial or older page) is in flight for this chat.
  /// Drives the chat header "Updating" phase (synced with Home list updates).
  func isChatHistoryLoading(chatId: String) -> Bool {
    guard let normalized = normalizedString(chatId), !normalized.isEmpty else { return false }
    if Thread.isMainThread, let flags = publishedChatFlags(for: normalized) {
      queue.async { [weak self] in self?.publishChatFlags(for: normalized) }
      return flags.loading
    }
    return syncOnQueue {
      publishChatFlags(for: normalized)
      return historyLoadingChats.contains(normalized)
        || historyLoadingOlderChats.contains(normalized)
    }
  }

  /// True when older transcript pages may exist below the currently-loaded window
  /// (local store depth or a live server cursor). Cheap; callable from any thread.
  func hasOlderChatHistory(chatId: String) -> Bool {
    syncOnQueue {
      guard let chatId = normalizedString(chatId), !chatId.isEmpty,
        chatId != "saved_messages",
        !isBuiltInAgentChatId(chatId),
        !historyOlderExhaustedChats.contains(chatId),
        let boundary = oldestHistoryBoundaryLocked(chatId: chatId)
      else { return false }

      let hasStoredOlder: Bool
      if let userId = chatHistoryCacheUserIdLocked(), messageStore.isAvailable {
        hasStoredOlder = messageStore.hasOlderMessages(
          userId: userId,
          chatId: chatId,
          beforeTs: boundary.timestampMs,
          beforeMessageId: boundary.messageId
        )
      } else {
        hasStoredOlder = false
      }
      return hasStoredOlder || historyHasMoreByChat[chatId] != false
    }
  }

  /// Loads one older transcript page from the durable store, then the server.
  @discardableResult
  func loadOlderChatHistory(chatId: String) -> Bool {
    syncOnQueue {
      guard let chatId = normalizedString(chatId), !chatId.isEmpty else { return false }
      return loadOlderChatHistoryLocked(chatId: chatId)
    }
  }

  func isTyping(_ payload: [String: Any]) -> Bool {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId else { return false }
    return syncOnQueue {
      !(peerTypingUserIdsByChatId[chatId]?.isEmpty ?? true)
    }
  }

  func isLiveMessageDeleted(_ payload: [String: Any]) -> Bool {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    guard let chatId, let messageId else { return false }
    return syncOnQueue {
      deletedMessageIdsByChat[chatId]?.contains(messageId) == true
    }
  }

  func resolveDisplayStatus(
    chatId: String?,
    messageId: String?,
    rawStatus: String?,
    isMe: Bool,
    peerUserId: String?
  ) -> String? {
    let normalizedRaw = normalizedString(rawStatus)?.lowercased()
    guard isMe else { return normalizedRaw }

    if normalizedRaw == "read" { return "read" }

    return syncOnQueue {
      var receiptStatus: String?
      var localStatus: String?
      if let chatId, let messageId {
        receiptStatus = receiptIndex[chatId]?[messageId]
        localStatus = localStatusIndex[chatId]?[messageId]
      }
      if receiptStatus == "read" { return "read" }
      if receiptStatus == "delivered" { return "delivered" }
      if normalizedRaw == "delivered" { return "delivered" }

      if let localStatus {
        switch localStatus {
        // `localStatusIndex` is a monotonic high-water mark (see `upsertLocalStatusLocked`
        // → `strongerDisplayStatus`). Honor a retained read/delivered here so display never
        // downgrades to raw "sent" when `receiptIndex` was cleared (reconnect / chat reload)
        // but the local high-water still remembers the peer reached read/delivered.
        case "read":
          return "read"
        case "delivered":
          return "delivered"
        case "error":
          return "error"
        case "sent":
          if let peer = normalizedUpper(peerUserId), onlineUsers.contains(peer) {
            return "delivered"
          }
          return "sent"
        case "pending", "sending":
          if normalizedRaw == nil || normalizedRaw == "sending" || normalizedRaw == "pending" {
            return localStatus
          }
        default:
          break
        }
      }

      if normalizedRaw == "sent",
        let peer = normalizedUpper(peerUserId),
        onlineUsers.contains(peer)
      {
        return "delivered"
      }
      return normalizedRaw
    }
  }

  private func sendReceipt(
    _ payload: [String: Any],
    status: String,
    eventName: String,
    wireEvent: String
  ) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    guard let chatId, let messageId else { return getStatus() }
    return syncOnQueue {
      upsertReceiptLocked(chatId: chatId, messageId: messageId, status: status)

      var accepted = false
      var ref: String?
      if let client = phoenixClient,
        nativeJoinedChatIds.contains(chatId),
        (state["connected"] as? Bool) == true
      {
        ref = client.push(
          topic: chatTopic(for: chatId), event: wireEvent, payload: ["messageId": messageId])
        accepted = true
        appendJournalLocked(
          event: "native-\(eventName)-push",
          payload: [
            "chatId": chatId,
            "messageId": messageId,
            "ref": ref as Any,
          ])
      }

      appendJournalLocked(event: eventName, payload: payload)
      let snapshot = statusSnapshotLocked()
      postChangeLocked(
        reason: "messageStatusChanged",
        userInfo: ["chatId": chatId, "messageId": messageId, "status": status]
      )
      var out = snapshot
      out["accepted"] = accepted
      out["transport"] = accepted ? "native" : "shadow"
      if let ref { out["ref"] = ref }
      return out
    }
  }

  private func upsertReceiptLocked(chatId: String, messageId: String, status: String) {
    var chatMap = receiptIndex[chatId] ?? [:]
    let current = chatMap[messageId]
    let next = strongerStatus(current, status)
    chatMap[messageId] = next
    receiptIndex[chatId] = chatMap
    state["receiptCount"] = receiptIndex.values.reduce(0) { $0 + $1.count }
    state["updatedAt"] = nowMs()
  }

  private func upsertLocalStatusLocked(
    chatId: String,
    messageId: String,
    status: String,
    allowDowngrade: Bool = false
  ) {
    var chatMap = localStatusIndex[chatId] ?? [:]
    let current = chatMap[messageId]
    let next = allowDowngrade ? status : strongerDisplayStatus(current, status)
    chatMap[messageId] = next
    localStatusIndex[chatId] = chatMap
    var rowChanged = setLiveMessageStatusLocked(chatId: chatId, messageId: messageId, status: next)
    if next == "sent" || next == "delivered" || next == "read" || next == "error" {
      rowChanged = setLiveMessageUploadProgressLocked(
        chatId: chatId, messageId: messageId, progress: nil, postDelta: false) || rowChanged
    }
    state["localStatusCount"] = localStatusIndex.values.reduce(0) { $0 + $1.count }
    state["updatedAt"] = nowMs()
    if rowChanged {
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [messageId], deleted: [], source: "status")
    }
  }

  private func removeMessageIndicesLocked(chatId: String, messageId: String) {
    if var receiptChatMap = receiptIndex[chatId] {
      receiptChatMap.removeValue(forKey: messageId)
      if receiptChatMap.isEmpty {
        receiptIndex.removeValue(forKey: chatId)
      } else {
        receiptIndex[chatId] = receiptChatMap
      }
    }
    if var localChatMap = localStatusIndex[chatId] {
      localChatMap.removeValue(forKey: messageId)
      if localChatMap.isEmpty {
        localStatusIndex.removeValue(forKey: chatId)
      } else {
        localStatusIndex[chatId] = localChatMap
      }
    }
    state["receiptCount"] = receiptIndex.values.reduce(0) { $0 + $1.count }
    state["localStatusCount"] = localStatusIndex.values.reduce(0) { $0 + $1.count }
    state["updatedAt"] = nowMs()
  }

  private func strongerStatus(_ lhs: String?, _ rhs: String) -> String {
    func rank(_ value: String?) -> Int {
      switch value {
      case "read": return 2
      case "delivered": return 1
      default: return 0
      }
    }
    return rank(rhs) >= rank(lhs) ? rhs : (lhs ?? rhs)
  }

  private func strongerDisplayStatus(_ lhs: String?, _ rhs: String) -> String {
    func rank(_ value: String?) -> Int {
      switch value {
      case "read": return 6
      case "delivered": return 5
      case "sent": return 4
      case "error": return 3
      case "sending": return 2
      case "pending": return 1
      default: return 0
      }
    }
    return rank(rhs) >= rank(lhs) ? rhs : (lhs ?? rhs)
  }

  private func defaultAgentProgressLabel(tool: String?) -> String {
    switch tool {
    case "search_google":
      return "Thinking..."
    case "analyze_image":
      return "Thinking..."
    case "analyze_document":
      return "Thinking..."
    case "create_document":
      return "Updating file..."
    case "find_rows":
      return "Thinking..."
    case "edit_rows":
      return "Updating file..."
    case "delete_rows":
      return "Updating file..."
    case "export_rows":
      return "Updating file..."
    case "delete_document":
      return "Updating file..."
    case "pin_message":
      return "Pinning..."
    default:
      return "Typing..."
    }
  }

  private func setAgentProgressLocked(
    chatId: String,
    label: String?,
    tool: String?,
    status: String
  ) {
    let normalizedStatus =
      status
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .isEmpty
      ? "running"
      : status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    let shouldClear = Set([
      "done", "complete", "completed", "idle", "stopped", "stop", "error", "failed",
    ]).contains(normalizedStatus)

    if shouldClear {
      clearAgentProgressLocked(
        chatId: chatId, status: normalizedStatus, reason: "setProgress(status=\(normalizedStatus))")
      return
    }

    let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let trimmedToolValue = tool?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let normalizedTool = trimmedToolValue.isEmpty ? nil : trimmedToolValue
    let resolvedLabel =
      trimmedLabel.isEmpty ? defaultAgentProgressLabel(tool: normalizedTool) : trimmedLabel
    let next = AgentProgressState(
      label: resolvedLabel,
      tool: normalizedTool,
      status: normalizedStatus,
      updatedAtMs: Int64(nowMs())
    )
    let previous = agentProgressByChatId[chatId]
    guard previous != next else { return }
    agentProgressByChatId[chatId] = next
    emitAgentProgressChangeLocked(chatId: chatId, state: next)
  }

  private func clearAgentProgressLocked(
    chatId: String, status: String = "done", reason: String = "-"
  ) {
    guard let previous = agentProgressByChatId.removeValue(forKey: chatId) else { return }
    // [EmptyTrace] The header flipping to "Start session" mid-stream = this firing. Log WHO
    // cleared it (reason) + what was showing, so a device log pins the trigger. Pair with
    // the [EmptyTrace] getChatRows/reset lines to see if the row wipe rides the same event.
    VibeDebugLog.log(
      "[EmptyTrace] clearAgentProgress chatId=%@ reason=%@ hadLabel=%@ status=%@",
      String(chatId.suffix(12)), reason, previous.label, status)
    let normalizedStatus =
      status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "done"
      : status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    emitAgentProgressChangeLocked(
      chatId: chatId, state: nil, previous: previous, status: normalizedStatus)
  }

  // MARK: - Live agent streaming (bridge)
  //
  /// Reconcile the phone's synthetic live rows against the bridge daemon's complete task
  /// table. Stream/result frames remain the fast path; this authoritative snapshot is the
  /// hard stop that prevents a missed terminal frame or socket flap from leaving a provider
  /// or supervisor team card permanently marked running.
  func reconcileAgentBridgeStatus(_ status: AgentBridgeStatus, source: String) {
    queue.async { [weak self] in
      self?.reconcileAgentBridgeStatusLocked(status, source: source)
    }
  }

  /// Ingest a frame mirrored over the direct Mac LAN link (progress / result).
  /// Cloud `agent-stream` remains authoritative for full tool/node parse; LAN keeps
  /// the live bubble moving during cloud flaps (sequence-deduped).
  func ingestLanBridgeEvent(type: String, payload: [String: Any]) {
    queue.async { [weak self] in
      self?.ingestLanBridgeEventLocked(type: type, payload: payload)
    }
  }

  private func ingestLanBridgeEventLocked(type: String, payload: [String: Any]) {
    let kind = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch kind {
    case "history_result", "agent-bridge-history":
      applyLanHistoryResultLocked(payload)
    case "progress":
      ingestLanProgressLocked(payload)
    case "result":
      // Final result still lands via cloud→server persistence; clear LAN buffers so a
      // late cloud agent-stream doesn't fight a stale LAN partial.
      if let taskId = normalizedString(payload["taskId"] ?? payload["task_id"]),
        let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]),
        let provider = normalizedString(payload["provider"])
      {
        let key = "\(provider):\(chatId):\(taskId)"
        lanProgressLinesByTask.removeValue(forKey: key)
        cloudProgressAtMsByTask.removeValue(forKey: "\(chatId):\(taskId)")
        // Don't wipe seq immediately — cloud may still deliver frames with lower seq.
        let exitStatus = Int(parseLongValue(payload["exitStatus"] ?? payload["exit_status"]) ?? 0)
        let terminalStatus = exitStatus == 0 ? "done" : (exitStatus == 130 ? "stopped" : "error")
        // A supervisor's lead process can finish while one of its worker processes is
        // still active. The bridge-status snapshot carries the whole team task table and
        // is therefore the terminal authority for team cards; solo tasks can settle from
        // their direct result immediately.
        if normalizedString(payload["teamRunId"] ?? payload["team_run_id"]) == nil {
          settleAgentBridgeTaskLocked(
            chatId: chatId,
            taskId: taskId,
            terminalStatus: terminalStatus,
            reason: "lan-result"
          )
        }
      }
    case "status", "bridge_status":
      DispatchQueue.main.async {
        AgentPairingService.ingestLanStatusSnapshot(payload)
      }
    default:
      break
    }
  }

  private func reconcileAgentBridgeStatusLocked(
    _ status: AgentBridgeStatus,
    source: String
  ) {
    // A disconnected REST snapshot can be a transient relay outage while the CLI is
    // still running. Only a connected daemon can authoritatively say its task table is
    // empty. Authenticated LAN snapshots are published as connected by the parser.
    guard status.connected else { return }

    let activeTaskKeys = Set(status.runningTasks.compactMap { task -> String? in
      let chatId = task.chatId.trimmingCharacters(in: .whitespacesAndNewlines)
      let taskId = task.taskId.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !chatId.isEmpty, !taskId.isEmpty else { return nil }
      return "\(chatId)|\(taskId)"
    })
    let activeTeamKeys = Set(status.runningTasks.compactMap { task -> String? in
      let chatId = task.chatId.trimmingCharacters(in: .whitespacesAndNewlines)
      let teamRunId = task.teamRunId?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !chatId.isEmpty, !teamRunId.isEmpty else { return nil }
      return "\(chatId)|\(teamRunId)"
    })

    var staleRows: [(chatId: String, messageId: String, taskId: String?, teamRunId: String?)] = []
    for (chatId, perChat) in liveMessageRowsByChat {
      for (messageId, row) in perChat {
        guard let message = row["message"] as? [String: Any],
          let metadata = message["metadata"] as? [String: Any]
        else { continue }
        let runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
        let isStreaming =
          (message["isStreaming"] as? Bool) == true
          || (metadata["isStreaming"] as? Bool) == true
        let runtimeStatus = (normalizedString(runtime["status"]) ?? "").lowercased()
        let runtimeIsLive = ["running", "starting", "pending", "active", "streaming"]
          .contains(runtimeStatus)
        guard isStreaming || runtimeIsLive else { continue }

        let taskId = normalizedString(
          runtime["taskId"] ?? runtime["task_id"]
            ?? metadata["agentTaskId"] ?? metadata["agent_task_id"])
        let teamRunId = normalizedString(runtime["teamRunId"] ?? runtime["team_run_id"])
        guard taskId != nil || teamRunId != nil else { continue }
        if let taskId, activeTaskKeys.contains("\(chatId)|\(taskId)") { continue }
        if let teamRunId, activeTeamKeys.contains("\(chatId)|\(teamRunId)") { continue }
        staleRows.append((chatId, messageId, taskId, teamRunId))
      }
    }

    guard !staleRows.isEmpty else { return }
    var changedChats = Set<String>()
    var changedIdsByChat: [String: [String]] = [:]
    for stale in staleRows {
      if settleLiveBridgeMessageLocked(
        chatId: stale.chatId,
        messageId: stale.messageId,
        terminalStatus: "done"
      ) {
        changedChats.insert(stale.chatId)
        changedIdsByChat[stale.chatId, default: []].append(stale.messageId)
      }
      if let taskId = stale.taskId {
        removeBridgeTaskTrackingLocked(chatId: stale.chatId, taskId: taskId)
      }
      if let teamRunId = stale.teamRunId,
        liveStreamTaskRowIdByChatId[stale.chatId]?["team:\(teamRunId)"] == stale.messageId
      {
        liveStreamTaskRowIdByChatId[stale.chatId]?.removeValue(forKey: "team:\(teamRunId)")
      }
    }

    for chatId in changedChats {
      let chatStillActive = status.runningTasks.contains {
        $0.chatId.trimmingCharacters(in: .whitespacesAndNewlines) == chatId
      }
      if !chatStillActive {
        agentTurnRunningAtMsByChatId.removeValue(forKey: chatId)
        clearAgentProgressLocked(
          chatId: chatId,
          status: "done",
          reason: "bridgeStatus(\(source))"
        )
      }
      storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
      postChangeLocked(
        reason: "chatRowsReloaded",
        userInfo: ["chatId": chatId, "state": statusSnapshotLocked()]
      )
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: changedIdsByChat[chatId] ?? [], deleted: [],
        source: "bridgeStatus")
    }
    NSLog(
      "[AgentStatus] reconciled source=%@ staleRows=%d chats=%d activeTasks=%d",
      source, staleRows.count, changedChats.count, status.runningTasks.count)
  }

  /// A history reply that arrived over the direct LAN link. The first reply cancels the
  /// timed cloud fallback; detail watcher re-pushes continue to flow through the live
  /// request-id mapping after that one-shot ownership has been released.
  private func applyLanHistoryResultLocked(_ payload: [String: Any]) {
    guard let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]) else { return }
    let requestId = normalizedString(payload["requestId"]) ?? ""
    if !requestId.isEmpty { lanHistoryPendingRequestIds.remove(requestId) }
    applyAgentBridgeHistoryResultLocked(chatId: chatId, payload: payload, transport: "lan")
  }

  /// Shared result semantics for cloud relay and authenticated LAN history replies.
  /// Must stay on the engine queue: transcript ingest mutates row and paging state.
  private func applyAgentBridgeHistoryResultLocked(
    chatId: String, payload: [String: Any], transport: String
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    agentBridgeHistoryByChat[chatId] = payload
    let mode = normalizedString(payload["mode"]) ?? "list"
    let provider = normalizedString(payload["provider"]) ?? ""
    if !provider.isEmpty {
      if mode == "list" {
        agentBridgeHistoryListByChatProvider["\(chatId)|\(provider.lowercased())"] = payload
      }
    }
    let requestId = normalizedString(payload["requestId"]) ?? ""
    if transport == "lan" {
      NSLog(
        "[LanBridge] history %@ reply over LAN req=%@ chat=%@ provider=%@",
        mode, String(requestId.prefix(8)), String(chatId.prefix(12)), provider)
    }

    let okFlag = payload["ok"]
    let ok: Bool = {
      if let b = okFlag as? Bool { return b }
      if let n = okFlag as? NSNumber { return n.boolValue }
      if let s = okFlag as? String { return s.lowercased() != "false" && s != "0" }
      return true
    }()
    let message = (normalizedString(payload["message"]) ?? "").lowercased()
    let isNoCurrent =
      !ok
      && (message.contains("no_current_session") || message.contains("no session") || message.isEmpty)
    if isNoCurrent, mode == "detail", payload["session"] == nil {
      // Idle DM: bridge has nothing live — stop re-polling for 90s.
      noCurrentSessionUntilMsByChatId[chatId] = Int64(nowMs()) + 90_000
      currentSessionLoadInflightByChatId.removeValue(forKey: chatId)
      pendingBridgeSessionIngestByRequestId.removeValue(forKey: requestId)
      NSLog(
        "[ChatEngine][BridgeMount] no_current_session chat=%@ msg=%@ transport=%@ — suppress polls 90s",
        String(chatId.suffix(12)),
        message.isEmpty ? "<empty>" : message,
        transport
      )
      postChangeLocked(
        reason: "agentBridgeHistory",
        userInfo: [
          "chatId": chatId,
          "provider": provider,
          "mode": mode,
          "requestId": requestId,
          "message": "no_current_session",
        ]
      )
      return
    }
    // Successful current-session load clears the idle suppress.
    if ok { noCurrentSessionUntilMsByChatId.removeValue(forKey: chatId) }
    // If this detail reply was requested to be opened into the chat, render its
    // transcript as bubbles. The one-shot pending map is removed after the first
    // response, while the live map remains registered for watcher re-pushes.
    if mode == "detail" {
      var ingestProvider: String?
      if let target = pendingBridgeSessionIngestByRequestId.removeValue(forKey: requestId) {
        ingestProvider = provider.isEmpty ? target.provider : provider
      } else if let live = liveBridgeSessionIngestByChatId[chatId],
        live.requestId == requestId
      {
        ingestProvider = provider.isEmpty ? live.provider : provider
      }
      if let ingestProvider {
        if payload["session"] is [String: Any] {
          ingestAgentBridgeSessionLocked(
            chatId: chatId,
            provider: ingestProvider,
            payload: payload
          )
          // Clear single-flight gates once a detail payload landed for this chat.
          currentSessionLoadInflightByChatId.removeValue(forKey: chatId)
          sessionLoadInflightByChatId.removeValue(forKey: chatId)
        } else if var paging = bridgeSessionPagingByChatId[chatId] {
          paging.loadingOlder = false
          bridgeSessionPagingByChatId[chatId] = paging
          currentSessionLoadInflightByChatId.removeValue(forKey: chatId)
        }
      }
    }
    postChangeLocked(
      reason: "agentBridgeHistory",
      userInfo: [
        "chatId": chatId,
        "provider": provider,
        "mode": mode,
        "requestId": requestId,
      ]
    )
  }

  private func ingestLanProgressLocked(_ payload: [String: Any]) {
    guard let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]),
      let provider = normalizedString(payload["provider"]),
      let taskId = normalizedString(payload["taskId"] ?? payload["task_id"])
    else { return }
    let seq = parseLongValue(payload["sequence"]) ?? 0
    let key = "\(provider):\(chatId):\(taskId)"
    // Always accumulate the raw line + keep the header alive, even when cloud owns
    // the visible row — so a reclaim (cloud going silent) can paint from a complete
    // buffer and the header never flashes idle mid-run.
    let line = normalizedString(payload["line"]) ?? ""
    if !line.isEmpty {
      var lines = lanProgressLinesByTask[key] ?? []
      lines.append(line)
      if lines.count > 400 { lines = Array(lines.suffix(400)) }
      lanProgressLinesByTask[key] = lines
    }
    agentTurnRunningAtMsByChatId[chatId] = Int64(nowMs())

    // Cloud-authority gate: if cloud painted this task within the reclaim window,
    // stay passive (no seq advance, no paint) so cloud's node-rich frames own the
    // cell and it never flip-flops with the LAN text-only representation.
    let taskKey = "\(chatId):\(taskId)"
    if let lastCloud = cloudProgressAtMsByTask[taskKey],
      Int64(nowMs()) - lastCloud < Self.lanReclaimAfterCloudSilenceMs
    {
      return
    }

    if let prev = lanProgressSeqByTask[key], seq > 0, seq <= prev {
      return  // already applied (cloud or earlier LAN)
    }
    if seq > 0 {
      lanProgressSeqByTask[key] = Int(seq)
    }
    let accumulated = (lanProgressLinesByTask[key] ?? []).joined(separator: "\n")
    let displayText = Self.lightweightStreamText(from: accumulated, provider: provider)
    let agentUserId = Self.bridgeAgentUserId(forProvider: provider)
    let streamId = "lan-\(taskId)"
    // LAN frames are text-only. Reclaiming with an empty node list would wipe a tool
    // feed cloud already painted — the regress guard in applyAgentStreamLocked can't
    // catch it, because LAN carries MORE text than cloud's tail narration and that
    // guard only fires when text regresses too. Carry the nodes forward so a reclaim
    // refreshes narration instead of destroying the feed.
    let existingNodes =
      ((liveMessageRowsByChat[chatId]?[streamId]?["message"] as? [String: Any])?["metadata"]
        as? [String: Any])?["progressNodes"] as? [[String: Any]] ?? []
    var streamPayload: [String: Any] = [
      "streamId": streamId,
      "taskId": taskId,
      "status": "running",
      "text": displayText,
      "progressNodes": existingNodes,
      "userId": agentUserId as Any,
      "sequence": seq,
    ]
    if let reply = normalizedString(payload["replyToId"] ?? payload["reply_to_id"]) {
      streamPayload["sourceMessageId"] = reply
      streamPayload["replyToId"] = reply
    }
    // Reuse the live stream path so group/DM cells grow in place.
    applyAgentStreamLocked(chatId: chatId, payload: streamPayload)
  }

  /// Best-effort text extract from raw CLI stream-json / plain output so LAN
  /// progress can paint a bubble without waiting on the server reparse.
  private static func lightweightStreamText(from accumulated: String, provider: String) -> String {
    let p = provider.lowercased()
    // Prefer last non-empty plain-ish assistant text blocks from stream-json lines.
    var texts: [String] = []
    for rawLine in accumulated.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      guard line.contains("{"), line.contains("}") else {
        // Plain stdout (some Grok/Agy paths): keep non-JSON lines as text.
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, !t.hasPrefix("{"), t.count > 1 { texts.append(t) }
        continue
      }
      // content_block_delta / text deltas
      if let range = line.range(of: #""text"\s*:\s*""#, options: .regularExpression) {
        let after = line[range.upperBound...]
        if let end = after.firstIndex(of: "\"") {
          let chunk = String(after[..<end])
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
          if !chunk.isEmpty { texts.append(chunk) }
        }
      }
      // agent_message style
      if line.contains("\"type\":\"agent_message\"") || line.contains("\"type\": \"agent_message\"")
      {
        if let range = line.range(of: #""text"\s*:\s*""#, options: .regularExpression) {
          let after = line[range.upperBound...]
          if let end = after.firstIndex(of: "\"") {
            let chunk = String(after[..<end])
              .replacingOccurrences(of: "\\n", with: "\n")
            if !chunk.isEmpty { texts.append(chunk) }
          }
        }
      }
    }
    if p == "grok" || p == "agy" || p == "antigravity" {
      // Prefer the joined tail for providers that stream prose chunks.
      let joined = texts.joined()
      if !joined.isEmpty { return joined }
    }
    return texts.joined()
  }

  // A bridge agent (Claude/Codex) running on the user's computer streams its
  // reply back as it is produced. The server reparses the partial output and
  // broadcasts `agent-stream` events. We render that as a synthetic agent
  // message row (keyed by a stable streamId) that updates in place — text grows
  // and tool/progress nodes appear inline in the bubble — instead of showing the
  // execution only in the header and the answer as one final batch. When the
  // real persisted message arrives, the streaming row is removed.
  private func applyAgentStreamLocked(chatId: String, payload: [String: Any]) {
    guard let streamId = normalizedString(payload["streamId"] ?? payload["stream_id"]) else {
      return
    }
    let status = (normalizedString(payload["status"]) ?? "running").lowercased()
    let agentUserId = normalizedString(payload["userId"] ?? payload["user_id"] ?? payload["id"])
    let taskId = normalizedString(payload["taskId"] ?? payload["task_id"])
    let teamRunId = normalizedString(payload["teamRunId"] ?? payload["team_run_id"])
    let teamMode = (normalizedString(payload["teamMode"] ?? payload["team_mode"]) ?? "")
      .lowercased()
    let suppressVisible =
      (payload["suppressVisible"] as? Bool) == true
      || (payload["suppress_visible"] as? Bool) == true
      || (normalizedString(payload["teamRole"] ?? payload["team_role"]) ?? "").lowercased()
        == "worker"
    let isSupervisorTeam =
      teamMode == "supervisor" || teamMode == "group_supervisor"

    // Under-hood supervisor workers never get their own list cell. Fold status
    // into the lead row keyed by teamRunId and keep full nodes for the sheet
    // store only.
    if suppressVisible, isSupervisorTeam, let teamRunId, !teamRunId.isEmpty {
      mergeSuppressedTeamWorkerStreamLocked(
        chatId: chatId,
        teamRunId: teamRunId,
        payload: payload
      )
      return
    }

    // Mark cloud as the authoritative painter of this task's visible row. A cloud
    // relay frame is `stream-…`; the LAN direct mirror is `lan-…`. While cloud keeps
    // painting, the LAN mirror stays passive (ingestLanProgressLocked reclaim gate)
    // so the cell never flip-flops between the two representations.
    if streamId.hasPrefix("stream-"), let taskId, !taskId.isEmpty {
      cloudProgressAtMsByTask["\(chatId):\(taskId)"] = Int64(nowMs())
    }

    // Cloud and LAN both carry sequence; advance the high-water mark so the other
    // path cannot re-apply a staler frame as a second bubble update.
    if let taskId, !taskId.isEmpty,
      let provider = normalizedString(payload["provider"])
        ?? bridgeProviderForAgentIdentifier(agentUserId)
        ?? bridgeProviderForChatLocked(chatId: chatId),
      let seq = parseLongValue(payload["sequence"]), seq > 0
    {
      let key = "\(provider):\(chatId):\(taskId)"
      let prev = lanProgressSeqByTask[key] ?? 0
      if Int(seq) < prev {
        // Strictly older dual-path frame — skip. Equal seq may still carry a
        // richer cloud reparse (progressNodes) so it is allowed through.
        return
      }
      if Int(seq) > prev {
        lanProgressSeqByTask[key] = Int(seq)
      }
    }

    // Resolve the row's canonical identity through taskId, not the raw streamId. The
    // server's per-connection stream state isn't durable across a bridge↔server
    // reconnect (a fresh channel process remembers nothing of the prior stream), so a
    // mid-run reconnect mints a brand-new streamId with a reset (empty) buffer for the
    // SAME logical turn. taskId is assigned once at dispatch and survives any reconnect
    // on either side, so the FIRST streamId seen for a taskId becomes the row's
    // permanent id; later frames for the same taskId fold into that same row instead of
    // spawning a second, duplicate cell.
    // Supervisor lead: pin by teamRunId so worker status merges and reconnects
    // never spawn a second lead cell.
    var effectiveRowId = streamId
    var perTaskRowIds = liveStreamTaskRowIdByChatId[chatId] ?? [:]
    if isSupervisorTeam, let teamRunId, !teamRunId.isEmpty {
      let teamKey = "team:\(teamRunId)"
      if let existingRowId = perTaskRowIds[teamKey] {
        effectiveRowId = existingRowId
      } else {
        perTaskRowIds[teamKey] = streamId
        effectiveRowId = streamId
      }
    } else if let taskId, !taskId.isEmpty {
      if let existingRowId = perTaskRowIds[taskId] {
        effectiveRowId = existingRowId
      } else if isAgentTaskRetiredLocked(chatId: chatId, taskId: taskId),
        liveMessageRowsByChat[chatId]?[streamId] == nil
      {
        // This turn already settled into a real message and its live row was retired.
        // Frames keep trailing in for seconds afterwards (the bridge's own `done`, the
        // cloud relay of a frame LAN already delivered); minting a row for them puts a
        // second identical bubble next to the settled reply — one duplicate per agent in
        // a group, which only "fixed itself" on reopen because the twin is volatile.
        NSLog(
          "[ChatEngine][AgentStream] drop late frame chat=%@ task=%@ stream=%@ — turn already settled",
          String(chatId.suffix(12)), String(taskId.suffix(16)), String(streamId.prefix(24)))
        return
      } else {
        perTaskRowIds[taskId] = streamId
        effectiveRowId = streamId
      }
    }
    if !perTaskRowIds.isEmpty {
      liveStreamTaskRowIdByChatId[chatId] = perTaskRowIds
    }

    // A live turn's sessionId (once the CLI's init/thread-start event has been parsed)
    // registers this chat in the SAME map History uses, so a phone-side reconnect's
    // existing rearmLiveBridgeSessionLocked (chat_joined) proactively re-syncs this
    // turn too — not just turns the user happened to open History on.
    let frameSessionId = normalizedString(payload["sessionId"] ?? payload["session_id"])
    if let sessionId = frameSessionId,
      !sessionId.isEmpty,
      liveBridgeSessionIngestByChatId[chatId]?.sessionId != sessionId
    {
      let provider = bridgeProviderForChatLocked(chatId: chatId) ?? ""
      if !provider.isEmpty {
        liveBridgeSessionIngestByChatId[chatId] = (
          provider: provider, sessionId: sessionId, requestId: UUID().uuidString
        )
      }
    }

    var text = normalizedString(payload["text"]) ?? ""
    var progressNodes = (payload["progressNodes"] as? [[String: Any]]) ?? []
    // Live frames: merge only *adjacent* text streams (not “last text wins globally”).
    if status != "done", status != "error", status != "stopped" {
      progressNodes = Self.collapseLiveTextProgressNodes(progressNodes)
    }
    // Never let the visible feed regress: a reconnect on either side can hand back a
    // freshly-reset accumulation buffer for the SAME task. If this frame carries
    // strictly less than what's already on screen for this row, keep showing the
    // richer content already displayed until the new stream catches back up.
    // Also covers STOP mid-stream: a settle/cancel frame with empty body+nodes must
    // not wipe partial Grok content the user already watched.
    if let existingMessage = liveMessageRowsByChat[chatId]?[effectiveRowId]?["message"] as? [String: Any] {
      let existingText = normalizedString(existingMessage["plainContent"]) ?? ""
      let existingProgressNodes =
        ((existingMessage["metadata"] as? [String: Any])?["progressNodes"] as? [[String: Any]]) ?? []
      let existingHasContent =
        !existingText.isEmpty
        || existingProgressNodes.contains { node in
          let kind = (normalizedString(node["kind"] ?? node["itemType"]) ?? "").lowercased()
          let label = normalizedString(node["label"]) ?? ""
          return kind == "text" || kind == "thinking" || kind == "compacting" || label.count > 2
        }
      let nextHasContent =
        !text.isEmpty
        || progressNodes.contains { node in
          let kind = (normalizedString(node["kind"] ?? node["itemType"]) ?? "").lowercased()
          let label = normalizedString(node["label"]) ?? ""
          return kind == "text" || kind == "thinking" || kind == "compacting" || label.count > 2
        }
      if progressNodes.count < existingProgressNodes.count, text.count <= existingText.count {
        text = existingText
        progressNodes = existingProgressNodes
        if status != "done", status != "error", status != "stopped" {
          progressNodes = Self.collapseLiveTextProgressNodes(progressNodes)
        }
      } else if existingHasContent, !nextHasContent {
        text = existingText.isEmpty ? text : existingText
        progressNodes = existingProgressNodes.isEmpty ? progressNodes : existingProgressNodes
      }
    }
    // Diagnostic: the chronological kind order the server sent for this live frame.
    // A healthy live turn interleaves (e.g. "text,read,text,edit,bash"); a regression
    // back to the old "grouped" bug reads as all tools then all text (or vice-versa).
    let progressKindOrder =
      progressNodes
      .map { node in (normalizedString(node["kind"] ?? node["itemType"]) ?? "step").lowercased() }
      .joined(separator: ",")
    let sourceMessageId = normalizedString(
      payload["sourceMessageId"] ?? payload["source_message_id"] ?? payload["replyToId"] ?? payload["reply_to_id"]
    )
    let sequence = parseLongValue(payload["sequence"])
    let bridgeSentAtMs = parseLongValue(payload["bridgeSentAtMs"] ?? payload["bridge_sent_at_ms"])
    let serverReceivedAtMs = parseLongValue(payload["serverReceivedAtMs"] ?? payload["server_received_at_ms"])
    let serverBroadcastAtMs = parseLongValue(payload["serverBroadcastAtMs"] ?? payload["server_broadcast_at_ms"])
    let phoneReceivedAtMs = Int64(nowMs())
    // Always log first few frames + every 5th + any settle/compacting so layout
    // jumps and Grok interleave order are visible while debugging on device.
    let shouldLogFrame =
      sequence == nil
      || (sequence ?? 0) <= 5
      || (sequence ?? 0) % 5 == 0
      || status == "done" || status == "error" || status == "stopped"
      || progressKindOrder.contains("compacting")
      || progressKindOrder.contains("thinking")
    if shouldLogFrame {
      let bridgeToServer = bridgeSentAtMs.flatMap { sent in serverReceivedAtMs.map { $0 - sent } }
      let serverToPhone = serverBroadcastAtMs.map { phoneReceivedAtMs - $0 }
      let endToEnd = bridgeSentAtMs.map { phoneReceivedAtMs - $0 }
      let mode = transportModeLocked()
      let wsConnected = (state["connected"] as? Bool) == true
      let transport =
        "mode=\(mode) phoenix=\(phoenixClient == nil ? "nil" : (wsConnected ? "ws-up" : "ws-down"))"
      NSLog(
        "[ChatEngine][AgentStream] chat=%@ stream=%@ row=%@ seq=%@ status=%@ text=%d nodes=%d order=[%@] transport=%@ bridgeToServer=%@ms serverToPhone=%@ms e2e=%@ms",
        chatId,
        streamId,
        effectiveRowId == streamId ? "-" : effectiveRowId,
        sequence.map(String.init) ?? "nil",
        status,
        text.count,
        progressNodes.count,
        progressKindOrder,
        transport,
        bridgeToServer.map(String.init) ?? "nil",
        serverToPhone.map(String.init) ?? "nil",
        endToEnd.map(String.init) ?? "nil"
      )
    }

    if status == "done" || status == "error" || status == "stopped" {
      clearAgentProgressLocked(chatId: chatId, status: status, reason: "streamFrame(status=\(status))")
      // The LIVE stream declared this turn finished — drop the running-window mark so the
      // ingest settle-clear can promptly retire the stale stream row once the transcript
      // confirms done, instead of waiting out the full grace.
      agentTurnRunningAtMsByChatId.removeValue(forKey: chatId)
      // Latch THIS frame's own session settled (never the chat's live slot, which in a
      // group may hold a different provider still streaming — Fable's group hole). This
      // gates the imminent post-done transcript re-push from re-widening the tail cell.
      if let doneSessionId = frameSessionId ?? liveBridgeSessionIngestByChatId[chatId]?.sessionId,
        !doneSessionId.isEmpty
      {
        bridgeMarkSessionSettledLocked(chatId: chatId, sessionId: doneSessionId, contentSig: "")
      }
      if let taskId, !taskId.isEmpty {
        removeBridgeTaskTrackingLocked(chatId: chatId, taskId: taskId)
      }
      // If the rich finished session card (a non-streaming `bridge-<session>-` row) has
      // ALREADY been ingested for this turn, this live stream row is now a stale duplicate
      // — the chat would show two "Worked" cards for one turn (a bare "Worked · N steps"
      // stream card next to the full "Worked for Xs · N steps · Y tokens" session card).
      // The ingest settle-clear only removes the stream row when the transcript ingest
      // lands AFTER the run's running-grace; an ingest that arrived DURING the grace held
      // (didn't clear), and this done frame clears the running mark but nothing re-runs the
      // settle — orphaning the stream row. Retire it here instead of keeping it.
      if let agentUserId, !agentUserId.isEmpty,
        hasFinishedBridgeSessionRowLocked(chatId: chatId, agentUserId: agentUserId)
      {
        let removal = removeAgentStreamRowsLocked(chatId: chatId, agentUserId: agentUserId)
        postChangeLocked(
          reason: "chatRowsReloaded",
          userInfo: ["chatId": chatId, "state": statusSnapshotLocked()]
        )
        postChatDeltaLocked(
          chatId: chatId, inserted: [], updated: [], deleted: removal.removedIds,
          source: "streamSettle")
        return
      }
      // Keep the accumulated text but stop the live indicator. The persisted
      // message (or its absence, on failure) takes over from here.
      let changed = settleLiveBridgeMessageLocked(
        chatId: chatId,
        messageId: effectiveRowId,
        terminalStatus: status
      )
      postChangeLocked(
        reason: "chatMessageChanged",
        userInfo: ["chatId": chatId, "messageId": effectiveRowId, "state": statusSnapshotLocked()]
      )
      if changed {
        postChatDeltaLocked(
          chatId: chatId, inserted: [], updated: [effectiveRowId], deleted: [],
          source: "streamSettle")
      }
      return
    }

    // Prefer the most recent TOOL/step node for the working indicator — the feed now
    // carries narration "text" nodes inline, and echoing a wall of prose in the
    // typing/working label reads wrong. Fall back to any label, then to "Thinking" —
    // the bare pre-first-token state (no progress nodes at all yet) — so the chat
    // header reads "Thinking…" instead of a generic "Working…" the instant a turn
    // starts, before anything is renderable in the transcript body.
    let streamProgressLabel = agentProgressLabelFromNodes(progressNodes) ?? "Thinking"
    setAgentProgressLocked(
      chatId: chatId,
      label: streamProgressLabel,
      tool: nil,
      status: "running"
    )
    // Refresh the running-window mark from the LIVE stream too — not just the ingest path.
    // A watch-mirrored transcript re-push can momentarily report the turn as not-running
    // while agent-stream frames are still flowing; without this, the ingest settle-clear's
    // grace (previously measured only from the last INGEST-observed running turn) expires
    // mid-run and wipes the live header → "Start session" flicker + collapsed cell. Every
    // stream frame is proof the turn is alive, so it keeps the grace fresh.
    agentTurnRunningAtMsByChatId[chatId] = Int64(nowMs())
    // A live (non-terminal) frame for this session is genuine proof-of-life — drop any
    // stale terminal latch so the tail cell tracks the grace again (a resumed/continued run).
    if let liveSessionId = frameSessionId, !liveSessionId.isEmpty {
      bridgeClearSessionSettledLocked(chatId: chatId, sessionId: liveSessionId)
    }

    // Stable timestamp so the bubble holds its position as text grows. Stamp it at the
    // FIRST RENDERABLE frame, not the first frame: the empty pre-content shell (text=0,
    // bare Thinking) is suppressed from the list, so a stream-start stamp would order a
    // slow agent's reply ABOVE a faster agent that showed content minutes earlier. The
    // visible order should be "who responded first", i.e. first content wins the slot.
    let hasRenderableStreamContent =
      !text.isEmpty
      || progressNodes.contains { node in
        let kind = (normalizedString(node["kind"] ?? node["itemType"]) ?? "").lowercased()
        let label = (normalizedString(node["label"] ?? node["title"]) ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let detail = (
          normalizedString(node["detail"] ?? node["messageContent"] ?? node["messagePreview"]) ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholderThinking =
          (kind == "thinking" || label == "thinking" || label == "thinking...") && detail.isEmpty
        return !isPlaceholderThinking
      }
    var perChat = agentStreamTimestampsByChat[chatId] ?? [:]
    let timestampMs: Int64
    if let stamped = perChat[effectiveRowId] {
      timestampMs = stamped
    } else if hasRenderableStreamContent {
      timestampMs = Int64(nowMs())
      perChat[effectiveRowId] = timestampMs
      agentStreamTimestampsByChat[chatId] = perChat
    } else {
      // Provisional only — the row is an off-list shell until content arrives.
      timestampMs = Int64(nowMs())
    }

    var metadata: [String: Any] = [
      "progressNodes": progressNodes,
      "agentWorkerVia": "bridge",
      "isStreaming": true,
    ]
    if let sourceMessageId {
      metadata["sourceMessageId"] = sourceMessageId
      metadata["actionSourceId"] = sourceMessageId
    }
    if let taskId {
      metadata["agentTaskId"] = taskId
    }
    if let repoName = normalizedString(payload["repoName"] ?? payload["repo_name"]) {
      metadata["agentRuntimeRepoName"] = repoName
    }
    if let cwd = normalizedString(payload["cwd"]) {
      metadata["agentRuntimeCwd"] = cwd
    }
    if let workMode = normalizedString(payload["workMode"] ?? payload["work_mode"]) {
      metadata["agentRuntimeWorkMode"] = workMode
    }
    if let model = normalizedString(payload["model"]) {
      metadata["agentRuntimeModel"] = model
    }
    if let advisor = normalizedString(payload["advisor"] ?? payload["advisorModel"] ?? payload["advisor_model"]) {
      metadata["agentRuntimeAdvisor"] = advisor
    }
    // The team/solo render is STICKY per run: capture what this row already knew so a
    // later frame that omits the team fields can't strip them (see the backfill below).
    let existingRuntime: [String: Any] = {
      guard let existingRow = liveMessageRowsByChat[chatId]?[effectiveRowId],
        let existingMessage = existingRow["message"] as? [String: Any],
        let existingMeta = existingMessage["metadata"] as? [String: Any]
      else { return [:] }
      return (existingMeta["agentRuntime"] as? [String: Any]) ?? [:]
    }()
    var liveRuntime: [String: Any] = [
      "status": "running",
    ]
    if let taskId { liveRuntime["taskId"] = taskId }
    if let provider = bridgeProviderForChatLocked(chatId: chatId) {
      liveRuntime["provider"] = provider
    }
    for (wireKey, snakeKey, runtimeKey) in [
      ("repoName", "repo_name", "repoName"), ("cwd", "cwd", "cwd"),
      ("workMode", "work_mode", "workMode"), ("model", "model", "model"),
      ("advisor", "advisor_model", "advisor"), ("teamMode", "team_mode", "teamMode"),
      ("teamRunId", "team_run_id", "teamRunId"),
      ("teamWorker", "team_worker", "teamWorker"),
      ("computerId", "computer_id", "computerId"),
      ("computerLabel", "computer_label", "computerLabel"),
    ] {
      if let value = normalizedString(payload[wireKey] ?? payload[snakeKey]) {
        liveRuntime[runtimeKey] = value
      }
    }
    if let workers = payload["teamWorkers"] as? [String], !workers.isEmpty {
      liveRuntime["teamWorkers"] = workers
    }
    if let lead = normalizedString(payload["leadWorker"] ?? payload["lead_worker"]) {
      liveRuntime["leadWorker"] = lead
    }
    if let role = normalizedString(payload["teamRole"] ?? payload["team_role"]) {
      liveRuntime["teamRole"] = role
    }
    var statusList = payload["teamWorkersStatus"] as? [[String: Any]]
    if (statusList == nil || statusList?.isEmpty == true),
      let teamRunId,
      let stashed = pendingTeamWorkersStatusByChatId[chatId]?[teamRunId],
      !stashed.isEmpty
    {
      statusList = stashed
      pendingTeamWorkersStatusByChatId[chatId]?.removeValue(forKey: teamRunId)
      if pendingTeamWorkersStatusByChatId[chatId]?.isEmpty == true {
        pendingTeamWorkersStatusByChatId.removeValue(forKey: chatId)
      }
    }
    if let statusList, !statusList.isEmpty {
      liveRuntime["teamWorkersStatus"] = statusList
      metadata["teamWorkersStatus"] = statusList
    }
    // Sticky team metadata. A frame minted after a bridge/socket reconnect (the ~50s
    // bridge flaps) can arrive as a bare text delta with none of the team fields, and
    // liveRuntime is rebuilt fresh every frame — so without this backfill that one
    // frame would drop teamMode / teamRunId / teamWorkersStatus, flip
    // `bubbleRendersTeamRun` false, and revert a long-running team OR solo cell to its
    // raw agent stream in the main view (and drop it from the socket-reset preserve
    // guard, wiping it on backgrounding). Once a run has shown as a team/solo cell it
    // stays one: carry any team field this row already knew when the frame omits it.
    for key in ["teamMode", "teamRunId", "teamWorker", "teamWorkers", "leadWorker", "teamRole"] {
      if liveRuntime[key] == nil, let carried = existingRuntime[key] {
        liveRuntime[key] = carried
      }
    }
    if (liveRuntime["teamWorkersStatus"] as? [[String: Any]])?.isEmpty != false,
      let carriedStatus = existingRuntime["teamWorkersStatus"] as? [[String: Any]],
      !carriedStatus.isEmpty
    {
      liveRuntime["teamWorkersStatus"] = carriedStatus
      metadata["teamWorkersStatus"] = carriedStatus
    }
    // Live team/single agent runs can always be cancelled from the sheet.
    liveRuntime["controls"] = ["canCancel": true, "canRevert": false]
    metadata["agentRuntime"] = liveRuntime
    if let sequence {
      metadata["agentStreamSequence"] = sequence
    }
    if let bridgeSentAtMs {
      metadata["agentBridgeSentAtMs"] = bridgeSentAtMs
    }
    if let serverReceivedAtMs {
      metadata["agentServerReceivedAtMs"] = serverReceivedAtMs
    }
    if let serverBroadcastAtMs {
      metadata["agentServerBroadcastAtMs"] = serverBroadcastAtMs
    }

    let hadExistingStreamRow = liveMessageRowsByChat[chatId]?[effectiveRowId] != nil
    // Resolve a display name / username for group gutter decoration even when the
    // server frame only carries the shadow userId (no agentName field).
    let streamProvider =
      agentUserId.flatMap { Self.bridgeAgentProvidersByUserId[$0.lowercased()] }
      ?? bridgeProviderForAgentIdentifier(agentUserId)
      ?? bridgeProviderForChatLocked(chatId: chatId)
    let streamAgentName: String? = {
      guard let streamProvider else { return nil }
      switch streamProvider {
      case "claude": return "Claude"
      case "codex": return "Codex"
      case "grok": return "Grok"
      case "agy", "antigravity": return "Agy"
      default: return streamProvider.capitalized
      }
    }()
    if let streamAgentName {
      metadata["agentName"] = streamAgentName
      metadata["agentUsername"] = streamProvider
    }
    if let agentUserId {
      metadata["agentUserId"] = agentUserId
    }
    var synthetic: [String: Any] = [
      "id": effectiveRowId,
      "type": "text",
      "timestamp": timestampMs,
      "isAgentMessage": true,
      "plainContent": text,
      "metadata": metadata,
    ]
    if let sourceMessageId {
      synthetic["replyToId"] = sourceMessageId
    }
    if let agentUserId {
      synthetic["fromId"] = agentUserId
      synthetic["agentUserId"] = agentUserId
    }
    if let streamAgentName {
      synthetic["agentName"] = streamAgentName
      if let streamProvider {
        synthetic["agentUsername"] = streamProvider
      }
    }

    _ = applyNativeIncomingMessageEventLocked(
      chatId: chatId, payload: synthetic, postDelta: false)
    mutateLiveMessagePayloadLocked(chatId: chatId, messageId: effectiveRowId) { message in
      message["isStreaming"] = true
    }
    // This live row now owns the in-flight turn — drop any running session row that a
    // history snapshot may have created for the same turn (order-independent dedup).
    let removedBridgeIds = removeRunningBridgeSessionRowsLocked(
      chatId: chatId, agentUserId: agentUserId)
    postChangeLocked(
      reason: hadExistingStreamRow ? "chatMessageChanged" : "chatMessageInserted",
      userInfo: ["chatId": chatId, "messageId": effectiveRowId, "state": statusSnapshotLocked()]
    )
    postChatDeltaLocked(
      chatId: chatId,
      inserted: hadExistingStreamRow ? [] : [effectiveRowId],
      updated: hadExistingStreamRow ? [effectiveRowId] : [],
      deleted: removedBridgeIds,
      source: "stream")
  }

  /// Fold an under-hood supervisor worker's stream into the lead row for `teamRunId`.
  /// Does not insert a second list cell; updates `teamWorkersStatus` (and optional
  /// per-worker progress cache) on the existing lead synthetic message.
  private func mergeSuppressedTeamWorkerStreamLocked(
    chatId: String,
    teamRunId: String,
    payload: [String: Any]
  ) {
    let teamKey = "team:\(teamRunId)"
    let rowId = liveStreamTaskRowIdByChatId[chatId]?[teamKey]
    let statusList =
      (payload["teamWorkersStatus"] as? [[String: Any]])
      ?? (payload["team_workers_status"] as? [[String: Any]])
      ?? []

    // Keep header typing multi-agent aware even before lead row exists.
    if let worker = normalizedString(payload["teamWorker"] ?? payload["team_worker"]),
      let lastLabel = normalizedString(payload["lastLabel"] ?? payload["last_label"])
        ?? normalizedString(payload["status"])
    {
      let label = "\(worker.capitalized) · \(lastLabel)"
      setAgentProgressLocked(chatId: chatId, label: label, tool: nil, status: "running")
    }

    guard let rowId else {
      // Lead cell not yet created — stash status so the first lead frame can adopt it.
      var stash = pendingTeamWorkersStatusByChatId[chatId] ?? [:]
      if !statusList.isEmpty {
        stash[teamRunId] = statusList
        pendingTeamWorkersStatusByChatId[chatId] = stash
      }
      return
    }

    let changed = mutateLiveMessagePayloadLocked(chatId: chatId, messageId: rowId) { message in
      var metadata = (message["metadata"] as? [String: Any]) ?? [:]
      if !statusList.isEmpty {
        metadata["teamWorkersStatus"] = statusList
        var runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
        runtime["teamWorkersStatus"] = statusList
        runtime["teamRunId"] = teamRunId
        runtime["teamMode"] = normalizedString(payload["teamMode"] ?? payload["team_mode"])
          ?? runtime["teamMode"] as? String ?? "supervisor"
        metadata["agentRuntime"] = runtime
      }
      // Cache full worker progress nodes for the multi-agent sheet (keyed by handle).
      if let worker = normalizedString(payload["teamWorker"] ?? payload["team_worker"]),
        let nodes = payload["progressNodes"] as? [[String: Any]], !nodes.isEmpty
      {
        var byWorker = (metadata["teamWorkerProgressNodes"] as? [String: Any]) ?? [:]
        byWorker[worker] = nodes
        metadata["teamWorkerProgressNodes"] = byWorker
        var chatCache = teamWorkerProgressNodesByChatId[chatId] ?? [:]
        var runCache = chatCache[teamRunId] ?? [:]
        runCache[worker] = nodes
        chatCache[teamRunId] = runCache
        teamWorkerProgressNodesByChatId[chatId] = chatCache
      }
      message["metadata"] = metadata
    }
    if changed {
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [rowId], deleted: [], source: "stream")
    }

    postChangeLocked(
      reason: "chatMessageChanged",
      userInfo: ["chatId": chatId, "messageId": rowId, "state": statusSnapshotLocked()]
    )
  }

  /// Working label for a turn's latest activity — the last non-text node's label, with a
  /// live thinking node formatted as "Thinking · 1.2k tokens" so the chat header ticks in
  /// real time like the desktop CLI. Shared by the agent-stream path and the
  /// session-ingest (watch) path: watch-driven sessions (including IDE-owned ones the
  /// bridge never spawned) get no agent-stream frames at all, so the header state must be
  /// derivable from the ingested transcript too.
  /// Merge only *adjacent* `kind:text` nodes (same continuous stream). Never drop
  /// text that sits between tools — that was the "all tools on top, all text at
  /// bottom" Grok regression. Callers used to keep only the global last text node.
  private static func collapseLiveTextProgressNodes(_ nodes: [[String: Any]]) -> [[String: Any]] {
    func kindOf(_ node: [String: Any]) -> String {
      let raw = (node["kind"] as? String) ?? (node["itemType"] as? String) ?? ""
      return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    guard nodes.count > 1 else { return nodes }
    var out: [[String: Any]] = []
    for node in nodes {
      let kind = kindOf(node)
      if kind == "text", let last = out.last, kindOf(last) == "text" {
        let label = (node["label"] as? String) ?? ""
        let prev = (last["label"] as? String) ?? ""
        // Prefer the longer (growing) stream chunk when adjacent.
        if label.count >= prev.count {
          out[out.count - 1] = node
        }
        continue
      }
      out.append(node)
    }
    return out
  }

  private func agentProgressLabelFromNodes(_ progressNodes: [[String: Any]]) -> String? {
    // Prefer a live compacting node so the chat header reads "Compacting…" mid-run.
    if let compacting = progressNodes.reversed().first(where: { node in
      let kind = (normalizedString(node["kind"] ?? node["itemType"]) ?? "").lowercased()
      let status = (normalizedString(node["status"]) ?? "").lowercased()
      return kind == "compacting" && ["running", "streaming", "in_progress", "active"].contains(status)
    }) {
      return normalizedString(compacting["label"] ?? compacting["title"]) ?? "Compacting conversation…"
    }
    let latestActionNode = progressNodes.reversed().first(where: { node in
      ((normalizedString(node["kind"] ?? node["itemType"]) ?? "").lowercased()) != "text"
    })
    var label = latestActionNode.flatMap { normalizedString($0["label"] ?? $0["title"]) }
    if let node = latestActionNode {
      let kind = (normalizedString(node["kind"] ?? node["itemType"]) ?? "").lowercased()
      if kind == "thinking",
        let tokens = parseLongValue(node["tokens"]), tokens > 0
      {
        let count =
          tokens >= 1000
          ? String(format: "%.1fk tokens", Double(tokens) / 1000.0)
          : "\(tokens) tokens"
        label = "Thinking · \(count)"
      } else if kind == "compacting" {
        label = normalizedString(node["label"] ?? node["title"]) ?? "Compacting conversation…"
      }
    }
    return label
      ?? progressNodes.reversed().compactMap { node in
        normalizedString(node["label"] ?? node["title"])
      }.first
  }

  /// True when this chat's live store already holds a FINISHED (non-streaming) agent
  /// session card — a `bridge-<sessionId>-…` row flagged `isAgentMessage` whose
  /// `isStreaming` is not set. Used to decide whether a settling live `stream-…` row is a
  /// redundant duplicate of an already-rendered "Worked" card. When `agentUserId` is
  /// given (a group with more than one concurrent agent), only that agent's own finished
  /// row counts — otherwise agent A's completion would look like a duplicate of agent B's
  /// still-live turn and wrongly retire it.
  private func hasFinishedBridgeSessionRowLocked(chatId: String, agentUserId: String? = nil) -> Bool {
    guard let perChat = liveMessageRowsByChat[chatId] else { return false }
    let targetAgent = normalizedUpper(agentUserId)
    return perChat.contains { key, value in
      guard key.hasPrefix("bridge-") else { return false }
      guard let message = value["message"] as? [String: Any] else { return false }
      guard (message["isAgentMessage"] as? Bool) == true else { return false }
      if let targetAgent {
        let rowAgent = normalizedUpper(message["agentUserId"] ?? message["fromId"])
        guard let rowAgent, rowAgent == targetAgent else { return false }
      }
      let meta = message["metadata"] as? [String: Any]
      let streaming =
        (message["isStreaming"] as? Bool) == true || (meta?["isStreaming"] as? Bool) == true
      return !streaming
    }
  }

  /// Returns the earliest STAMPED slot timestamp among the removed live rows (nil when
  /// none were stamped/removed) so the persisted reply that supersedes them can adopt
  /// the live bubble's list position instead of re-sorting to the bottom at settle.
  @discardableResult
  private func removeAgentStreamRowsLocked(
    chatId: String, agentUserId: String?
  ) -> (slotTs: Int64?, removedIds: [String]) {
    guard var perChat = liveMessageRowsByChat[chatId], !perChat.isEmpty else {
      return (nil, [])
    }
    let targetAgent = normalizedUpper(agentUserId)
    // Live cloud streams (`stream-…`) AND LAN dual-path rows (`lan-…`) both need
    // to drop when the real agent message lands — leaving either causes a second
    // cell (overlap / empty-gap after height cache drift) next to the final post.
    let streamIds = perChat.keys.filter {
      $0.hasPrefix("stream-") || $0.hasPrefix("lan-")
    }
    guard !streamIds.isEmpty else { return (nil, []) }
    var removedIds = Set<String>()
    var inheritedSlotTs: Int64?
    for streamId in streamIds {
      if let targetAgent {
        let rowAgent = normalizedUpper(
          (perChat[streamId]?["message"] as? [String: Any])?["agentUserId"]
            ?? (perChat[streamId]?["message"] as? [String: Any])?["fromId"])
        // Only remove a streaming row that belongs to the agent that just posted.
        if let rowAgent, rowAgent != targetAgent { continue }
      }
      if let stamped = agentStreamTimestampsByChat[chatId]?[streamId] {
        inheritedSlotTs = min(inheritedSlotTs ?? stamped, stamped)
      }
      perChat.removeValue(forKey: streamId)
      removedIds.insert(streamId)
    }
    guard !removedIds.isEmpty else { return (nil, []) }
    // [EmptyTrace] This wipes the live streaming bubble(s). If it fires mid-stream and leaves
    // the live store empty, the agent list can jump to empty until history rehydrates.
    VibeDebugLog.log(
      "[EmptyTrace] removeAgentStreamRows chatId=%@ removed=%d liveLeft=%d",
      String(chatId.suffix(12)), removedIds.count, perChat.isEmpty ? 0 : perChat.count)
    if perChat.isEmpty {
      liveMessageRowsByChat.removeValue(forKey: chatId)
    } else {
      liveMessageRowsByChat[chatId] = perChat
    }
    // Scope this cleanup to just the rows removed above, not the whole chat. A group can
    // have a SECOND agent concurrently streaming under the same chatId; wiping these
    // chat-keyed maps wholesale would drop that agent's taskId→rowId mapping. Its next
    // stream frame would then find no existing row, mint a brand-new one for the same
    // task, and orphan the first — the duplicate/overlapping agent cell bug in groups.
    if var perChatTimestamps = agentStreamTimestampsByChat[chatId] {
      for id in removedIds { perChatTimestamps.removeValue(forKey: id) }
      if perChatTimestamps.isEmpty {
        agentStreamTimestampsByChat.removeValue(forKey: chatId)
      } else {
        agentStreamTimestampsByChat[chatId] = perChatTimestamps
      }
    }
    if var perChatTaskRowIds = liveStreamTaskRowIdByChatId[chatId] {
      // Tombstone every task whose row just went away: the settled message now represents
      // that turn, so a straggler frame must never re-create a live twin next to it.
      for (taskId, rowId) in perChatTaskRowIds where removedIds.contains(rowId) {
        markAgentTaskRetiredLocked(chatId: chatId, taskId: taskId)
      }
      // A LAN row carries its task in the id itself (`lan-<taskId>`), so it is covered even
      // if the mapping was already pruned by an earlier terminal frame.
      for rowId in removedIds where rowId.hasPrefix("lan-") {
        markAgentTaskRetiredLocked(chatId: chatId, taskId: String(rowId.dropFirst(4)))
      }
      perChatTaskRowIds = perChatTaskRowIds.filter { !removedIds.contains($0.value) }
      if perChatTaskRowIds.isEmpty {
        liveStreamTaskRowIdByChatId.removeValue(forKey: chatId)
      } else {
        liveStreamTaskRowIdByChatId[chatId] = perChatTaskRowIds
      }
    }
    return (inheritedSlotTs, removedIds.sorted())
  }

  /// Drop any session `bridge-…` rows currently flagged running. The live `agent-stream`
  /// row owns the in-flight turn, so a running session row is a duplicate of it. This is
  /// the inverse of the ingest-time skip and makes the dedup order-independent: it covers
  /// the case where a history snapshot lands BEFORE the first stream frame. We remove only
  /// from the live store (no tombstone) so the SAME id can be re-ingested as the rich
  /// FINISHED row once the run completes (the bridge upserts the turn in place). When
  /// `agentUserId` is given (a group running more than one agent concurrently), only that
  /// agent's own running session row is dropped — otherwise agent A's stream frame would
  /// retire agent B's still-legitimately-running session row out from under it.
  private func removeRunningBridgeSessionRowsLocked(
    chatId: String, agentUserId: String? = nil
  ) -> [String] {
    guard var perChat = liveMessageRowsByChat[chatId], !perChat.isEmpty else { return [] }
    let targetAgent = normalizedUpper(agentUserId)
    var removed: [String] = []
    for (key, entry) in perChat where key.hasPrefix("bridge-") {
      let message = entry["message"] as? [String: Any]
      let metaStreaming = (message?["metadata"] as? [String: Any])?["isStreaming"] as? Bool
      let topStreaming = message?["isStreaming"] as? Bool
      guard metaStreaming == true || topStreaming == true else { continue }
      if let targetAgent {
        let rowAgent = normalizedUpper(message?["agentUserId"] ?? message?["fromId"])
        if let rowAgent, rowAgent != targetAgent { continue }
      }
      removed.append(key)
    }
    guard !removed.isEmpty else { return [] }
    for key in removed { perChat.removeValue(forKey: key) }
    if perChat.isEmpty {
      liveMessageRowsByChat.removeValue(forKey: chatId)
    } else {
      liveMessageRowsByChat[chatId] = perChat
    }
    return removed.sorted()
  }

  private func emitAgentProgressChangeLocked(
    chatId: String,
    state: AgentProgressState?,
    previous: AgentProgressState? = nil,
    status: String? = nil
  ) {
    let snapshot = statusSnapshotLocked()
    var userInfo: [String: Any] = [
      "chatId": chatId,
      "state": snapshot,
      "isActive": state != nil,
    ]
    if let state {
      userInfo["label"] = state.label
      userInfo["status"] = state.status
      userInfo["updatedAtMs"] = state.updatedAtMs
      if let tool = state.tool {
        userInfo["tool"] = tool
      }
    } else {
      userInfo["status"] = status ?? previous?.status ?? "done"
      if let previous {
        userInfo["updatedAtMs"] = previous.updatedAtMs
      }
    }
    postChangeLocked(reason: "agentProgress", userInfo: userInfo)
  }

  private func statusSnapshotLocked() -> [String: Any] {
    var snapshot = state
    snapshot["transportMode"] = transportModeLocked()
    snapshot["activeBridgeId"] = normalizedString(getConfigValueLocked("activeBridgeId"))
    snapshot["activePacketBridgeId"] = normalizedString(getConfigValueLocked("activePacketBridgeId"))
    snapshot["bridgeBaseUrl"] = bridgeBaseURLLocked()?.absoluteString
    snapshot["packetProxyPort"] = packetProxyPortLocked()
    snapshot["packetStatus"] = normalizedString(getConfigValueLocked("packetStatus")) ?? state["state"]
    snapshot["packetLastError"] = state["lastError"]
    snapshot["bridgeReachable"] =
      transportModeLocked() == "bridge_text" ? ((state["connected"] as? Bool) == true) : false
    snapshot["disableCalls"] = disableCallsLocked()
    snapshot["disableMedia"] = disableMediaLocked()
    snapshot["disableRemoteAvatars"] = disableRemoteAvatarsLocked()
    snapshot["onlineUserCount"] = onlineUsers.count
    snapshot["onlineUserIds"] = Array(onlineUsers).sorted()
    snapshot["lastSeenUserCount"] = lastSeenByUserId.count
    snapshot["boundSurfaceCount"] = surfaceBindings.count
    snapshot["boundChatCount"] = Set(surfaceBindings.values.compactMap(\.chatId)).count
    snapshot["openChatChannelCount"] = openChatChannels.count
    snapshot["openChatChannels"] = openChatChannels
    snapshot["receiptCount"] = receiptIndex.values.reduce(0) { $0 + $1.count }
    snapshot["localStatusCount"] = localStatusIndex.values.reduce(0) { $0 + $1.count }
    snapshot["nativeJoinedChatCount"] = nativeJoinedChatIds.count
    snapshot["outboundDraftCount"] = pendingOutboundDraftsByMessageId.count
    snapshot["outboundQueuedCount"] = pendingOutboundQueueByChat.values.reduce(0) { $0 + $1.count }
    snapshot["typingChatCount"] = peerTypingUserIdsByChatId.count
    snapshot["typingUserCount"] = peerTypingUserIdsByChatId.values.reduce(0) { $0 + $1.count }
    snapshot["agentProgressChatCount"] = agentProgressByChatId.count
    snapshot["pinnedChatCount"] = pinnedMessagesByChatId.count
    snapshot["pinnedMessageCount"] = pinnedMessagesByChatId.values.reduce(0) { $0 + $1.count }
    snapshot["journalCount"] = journalEntryCount
    return snapshot
  }

  @available(iOS 13.0, *)
  private func connectNativePresence() -> [String: Any] {
    _ = syncOnQueue {
      bootstrapConfigFromNativeSessionIfNeededLocked(trigger: "connect_native_presence")
    }
    let config = store.getConfig()
    let transportMode = transportModeLocked(config: config)
    let socketUrlString = normalizedString(config["socketUrl"]) ?? normalizedString(config["url"])
    let socketURL = socketUrlString.flatMap(URL.init(string:))
    let bridgeBaseURL = bridgeBaseURLLocked(config: config)
    let authToken = normalizedString(config["authToken"]) ?? normalizedString(config["token"])
    let userId = normalizedString(config["userId"])
    let userTopic =
      normalizedString(config["userChannelTopic"])
      ?? (userId != nil ? "user:\(userId!)" : nil)

    if transportMode == "offline" {
      return syncOnQueue {
        state["state"] = "offline"
        state["connected"] = false
        state["updatedAt"] = nowMs()
        state["note"] = "ChatEngine realtime transport disabled"
        state["transportMode"] = transportMode
        state["presenceSource"] = "shadow"
        appendJournalLocked(
          event: "connect-native-offline",
          payload: [
            "hasUserTopic": userTopic != nil,
          ])
        let snapshot = statusSnapshotLocked()
        postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
        return snapshot
      }
    }

    let resolvedTarget =
      transportMode == "bridge_text" ? bridgeBaseURL?.absoluteString : socketUrlString
    let packetProxyPort = packetProxyPortLocked(config: config)
    let packetProxyHost = packetProxyHostLocked(config: config)
    let hasRequiredPacketProxy = transportMode != "packet_mesh" || packetProxyPort != nil
    if transportMode == "packet_mesh", resolvedTarget != nil, userTopic != nil, packetProxyPort == nil {
      _ = ensurePacketRuntimeAsync(trigger: "connect_missing_packet_proxy")
      return getStatus()
    }
    guard resolvedTarget != nil, let userTopic, hasRequiredPacketProxy else {
      return syncOnQueue {
        state["state"] = "native-config-missing"
        state["connected"] = false
        state["updatedAt"] = nowMs()
        state["transportMode"] = transportMode
        state["note"] =
          transportMode == "bridge_text"
          ? "ChatEngine blackout bridge missing bridgeBaseUrl/userTopic config"
          : transportMode == "packet_mesh"
            ? "ChatEngine packet mesh missing socketUrl/userTopic/packetProxyPort config"
            : "ChatEngine native presence missing socketUrl/userTopic config"
        appendJournalLocked(
          event: "connect-native-missing-config",
          payload: [
            "hasSocketUrl": socketUrlString != nil,
            "hasBridgeBaseUrl": bridgeBaseURL != nil,
            "hasPacketProxyPort": packetProxyPort != nil,
            "hasUserTopic": userTopic != nil,
            "hasAuthToken": authToken != nil,
            "transportMode": transportMode,
          ])
        let snapshot = statusSnapshotLocked()
        postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
        return snapshot
      }
    }

    let signature = "\(transportMode)|\(resolvedTarget ?? "")|\(authToken ?? "")|\(userTopic)"
    let callbacks = ChatTransportCallbacks(
      onOpen: { [weak self] in self?.handleNativeSocketOpened(userTopic: userTopic) },
      onClose: { [weak self] code, reason in
        self?.handleNativeSocketClosed(code: code, reason: reason)
      },
      onError: { [weak self] error in self?.handleNativeSocketError(error) },
      onEvent: { [weak self] frame in self?.handleNativeSocketFrame(frame) }
    )

    let clientToReplace: ChatRealtimeTransport? = syncOnQueue {
      autoReconnectEnabled = true
      cancelReconnectLocked()
      var clientToReplace: ChatRealtimeTransport?
      if let existing = phoenixClient, nativeSocketSignature != signature {
        clientToReplace = existing
        phoenixClient = nil
        nativePresenceActive = false
        nativeUserJoinRef = nil
        nativeUserTopic = nil
        nativeChatJoinRefsByRef.removeAll()
        nativeJoinedChatIds.removeAll()
        nativePendingMessagePushRefs.removeAll()
        nativePendingEditPushRefs.removeAll()
        nativePendingDeletePushRefs.removeAll()
        nativePendingCallPushRefs.removeAll()
        pendingOutboundDraftsByMessageId.removeAll()
        pendingOutboundQueueByChat.removeAll()
        nativeTypingStateByChatId.removeAll()
        peerTypingUserIdsByChatId.removeAll()
        agentProgressByChatId.removeAll()
        nativeRecordingStateByChatId.removeAll()
        pinnedMessagesByChatId.removeAll()
        pinnedFetchInFlightChatIds.removeAll()
        historyLoadingChats.removeAll()
        clearSocketResetLiveRowsLocked()
      }
      if phoenixClient == nil {
        if transportMode == "bridge_text", let bridgeBaseURL {
          let client = ChatBlackoutTransport(
            baseURL: bridgeBaseURL,
            authToken: authToken,
            userId: userId ?? userTopic.replacingOccurrences(of: "user:", with: ""),
            activeBridgeId: normalizedString(config["activeBridgeId"]),
            bridgeBundle: config["bridgeBundle"] as? [String: Any],
            callbacks: callbacks
          )
          phoenixClient = client
        } else if transportMode == "packet_mesh",
          let socketURL,
          let packetProxyPort
        {
          let client = ChatPacketTransport(
            socketURL: socketURL,
            authToken: authToken,
            proxyHost: packetProxyHost,
            proxyPort: packetProxyPort,
            callbacks: callbacks
          )
          phoenixClient = client
        } else if transportMode != "packet_mesh", let socketURL {
          // Pass auth token separately so it goes in the Authorization header,
          // not as a URL query parameter (prevents token leakage in logs/proxies).
          let client = ChatPhoenixClient(
            baseURL: socketURL,
            params: [:],
            authToken: authToken,
            callbacks: callbacks
          )
          phoenixClient = client
        }
        nativeSocketSignature = signature
      }
      nativeUserTopic = userTopic
      state["connected"] = false
      state["state"] = "connecting-native-presence"
      state["updatedAt"] = nowMs()
      state["transportMode"] = transportMode
      state["activeBridgeId"] = normalizedString(config["activeBridgeId"])
      state["activePacketBridgeId"] = normalizedString(config["activePacketBridgeId"])
      state["bridgeBaseUrl"] = bridgeBaseURL?.absoluteString
      state["packetProxyPort"] = packetProxyPort
      state["note"] =
        transportMode == "bridge_text"
        ? "ChatEngine blackout bridge connecting"
        : transportMode == "packet_mesh"
          ? "ChatEngine Packet mesh connecting"
          : "ChatEngine native Phoenix presence connecting"
      state["presenceSource"] = nativePresenceActive ? "native" : "shadow"
      var connectPayload: [String: Any] = [
        "topic": userTopic,
        "transportMode": transportMode,
      ]
      if let bridgeBaseURL {
        connectPayload["bridgeBaseUrl"] = bridgeBaseURL.absoluteString
      }
      if let packetProxyPort {
        connectPayload["packetProxyPort"] = packetProxyPort
      }
      appendJournalLocked(event: "connect-native", payload: connectPayload)
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
      return clientToReplace
    }

    clientToReplace?.disconnect()
    (syncOnQueue { phoenixClient })?.connect()
    return getStatus()
  }

  private func handleNativeSocketOpened(userTopic: String) {
    queue.async {
      guard let client = self.phoenixClient else { return }
      self.cancelReconnectLocked()
      self.reconnectAttempt = 0
      self.state["connected"] = true
      self.state["state"] = "native-socket-open"
      self.state["updatedAt"] = self.nowMs()
      self.state["note"] = "ChatEngine native Phoenix socket open"
      NSLog("[ChatEngine] native Phoenix socket open - Triggering reconnects")
      self.appendJournalLocked(event: "native-socket-open", payload: [:])
      self.nativeUserTopic = userTopic
      self.nativeUserJoinRef = client.join(topic: userTopic, payload: [:])
      self.nativeChatJoinRefsByRef.removeAll()
      self.nativeJoinedChatIds.removeAll()
      self.nativePendingMessagePushRefs.removeAll()
      self.nativePendingEditPushRefs.removeAll()
      self.nativePendingDeletePushRefs.removeAll()
      self.nativePendingCallPushRefs.removeAll()
      self.nativeTypingStateByChatId.removeAll()
      self.peerTypingUserIdsByChatId.removeAll()
      self.agentProgressByChatId.removeAll()
      self.nativeRecordingStateByChatId.removeAll()
      self.pinnedMessagesByChatId.removeAll()
      self.pinnedFetchInFlightChatIds.removeAll()
      self.historyLoadingChats.removeAll()
      self.clearSocketResetLiveRowsLocked()
      for chatId in self.openChatChannels.keys {
        self.joinNativeChatTopicIfNeededLocked(chatId: chatId)
      }
      self.expireStaleQueuedOutboundLocked(trigger: "socket_open")
      // Publish KeyPackages as soon as this device is connected, not only once
      // it opens a chat.
      //
      // `chat_joined` used to be the ONLY trigger, which meant a freshly
      // registered account had published nothing and could not be added to an
      // MLS group by anyone — and a new account has no chats to open, so the
      // one event that would have fixed it could not fire. Two people who both
      // signed up and then messaged each other therefore started their first
      // conversation unencryptable, and stayed that way until whoever received
      // the first message happened to open it.
      //
      // Being addressable has nothing to do with having a conversation open,
      // so it should not wait on one. The 60s throttle inside makes the extra
      // trigger free on reconnect churn.
      self.ensureMlsProvisionedLocked(trigger: "socket_open")
      // Pending bubbles with no draft behind them can only be resolved here — the
      // queue-walking paths cannot see a message the queue has forgotten.
      self.sweepOrphanedPendingLocked(trigger: "socket_open")
      let queuedChats = Array(self.pendingOutboundQueueByChat.keys)
      for chatId in queuedChats {
        self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "socket_open")
      }
      let snapshot = self.statusSnapshotLocked()
      self.postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
    }
  }

  private func handleNativeSocketClosed(code: Int, reason: String?) {
    queue.async {
      let inFlightMessages = Array(self.nativePendingMessagePushRefs.values)
      for pending in inFlightMessages {
        // In-flight when the socket died → the message is UN-ACKED (a server ack removes
        // it from this map), so the server never finished handling it. Keep the bubble as
        // "pending" — waiting to reconnect — NEVER a dead-end "error" and NEVER removed,
        // then queue it for auto-replay on reconnect. This holds for AGENT chats too:
        // re-sending an agent turn is safe from a double-run because the bridge dedupes by
        // taskId, and the taskId is the client message id (chat_channel base_task_id =
        // data["id"]) — a replay of the same id collapses to one run. (The old agent-only
        // branch marked "error" and made the user resend manually, which surfaced the
        // confusing "your device is not up — send again"; that manual resend re-pushed the
        // SAME id and relied on the SAME dedup, so auto-replay is no less safe.)
        self.upsertLocalStatusLocked(
          chatId: pending.chatId, messageId: pending.messageId, status: "pending",
          allowDowngrade: true)
        if let draft = self.pendingOutboundDraftsByMessageId[pending.messageId] {
          self.queueOutboundDraftLocked(
            chatId: pending.chatId, messageId: pending.messageId, payload: draft,
            reason: "socket_closed")
        }
      }
      self.nativePresenceActive = false
      self.nativeUserJoinRef = nil
      self.nativeChatJoinRefsByRef.removeAll()
      self.nativeJoinedChatIds.removeAll()
      self.nativePendingMessagePushRefs.removeAll()
      self.nativePendingEditPushRefs.removeAll()
      self.nativePendingDeletePushRefs.removeAll()
      self.nativePendingCallPushRefs.removeAll()
      self.nativeTypingStateByChatId.removeAll()
      self.peerTypingUserIdsByChatId.removeAll()
      self.agentProgressByChatId.removeAll()
      self.nativeRecordingStateByChatId.removeAll()
      self.pinnedMessagesByChatId.removeAll()
      self.pinnedFetchInFlightChatIds.removeAll()
      self.historyLoadingChats.removeAll()
      self.clearSocketResetLiveRowsLocked()
      self.state["connected"] = false
      self.state["state"] = "native-socket-closed"
      self.state["updatedAt"] = self.nowMs()
      self.state["presenceSource"] = "shadow"
      self.appendJournalLocked(
        event: "native-socket-closed",
        payload: ["code": code, "reason": reason as Any]
      )
      self.scheduleReconnectLocked(reason: "socket_closed")
      let snapshot = self.statusSnapshotLocked()
      self.postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
    }
  }

  private func handleNativeSocketError(_ error: String) {
    queue.async {
      let normalizedError = error.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let shouldForceReconnect =
        normalizedError.contains("send_failed")
        || normalizedError.contains("receive_failed")
        || normalizedError.contains("network")
        || normalizedError.contains("timed out")
        || normalizedError.contains("heartbeat")
        || normalizedError.contains("connection")
      if shouldForceReconnect {
        let inFlightMessages = Array(self.nativePendingMessagePushRefs.values)
        for pending in inFlightMessages {
          // Same recoverable contract as socket_closed: un-acked → keep the bubble as
          // "pending" (waiting), never a dead-end error, and queue for auto-replay. Safe
          // for agent chats via the bridge's message-id taskId dedup (see socket_closed).
          self.upsertLocalStatusLocked(
            chatId: pending.chatId, messageId: pending.messageId, status: "pending",
            allowDowngrade: true)
          if let draft = self.pendingOutboundDraftsByMessageId[pending.messageId] {
            self.queueOutboundDraftLocked(
              chatId: pending.chatId, messageId: pending.messageId, payload: draft,
              reason: "socket_error")
          }
        }
        self.nativePresenceActive = false
        self.nativeUserJoinRef = nil
        self.nativeChatJoinRefsByRef.removeAll()
        self.nativeJoinedChatIds.removeAll()
        self.nativePendingMessagePushRefs.removeAll()
        self.nativePendingEditPushRefs.removeAll()
        self.nativePendingDeletePushRefs.removeAll()
        self.nativePendingCallPushRefs.removeAll()
        self.nativeTypingStateByChatId.removeAll()
        self.peerTypingUserIdsByChatId.removeAll()
        self.agentProgressByChatId.removeAll()
        self.nativeRecordingStateByChatId.removeAll()
        self.pinnedMessagesByChatId.removeAll()
        self.pinnedFetchInFlightChatIds.removeAll()
        self.state["connected"] = false
        self.state["state"] = "native-socket-error"
        self.state["presenceSource"] = "shadow"
      }
      self.state["updatedAt"] = self.nowMs()
      self.state["lastNativeSocketError"] = error
      self.appendJournalLocked(event: "native-socket-error", payload: ["error": error])
      if shouldForceReconnect {
        self.scheduleReconnectLocked(reason: "socket_error")
      }
      let snapshot = self.statusSnapshotLocked()
      self.postChangeLocked(reason: "engineError", userInfo: ["state": snapshot, "error": error])
    }
  }

  @available(iOS 13.0, *)
  private func expirePendingCallSignalsLocked(now: Int) {
    let before = nativePendingCallSignals.count
    nativePendingCallSignals.removeAll { signal in
      now - signal.createdAtMs > nativeCallSignalMaxAgeMs
    }
    let expired = before - nativePendingCallSignals.count
    if expired > 0 {
      appendJournalLocked(event: "native-call-signal-expired", payload: ["count": expired])
    }
  }

  @available(iOS 13.0, *)
  private func flushPendingCallSignalsLocked(trigger: String) {
    guard let client = phoenixClient,
      let topic = nativeUserTopic,
      (state["connected"] as? Bool) == true,
      nativePresenceActive
    else { return }

    let now = nowMs()
    expirePendingCallSignalsLocked(now: now)
    guard !nativePendingCallSignals.isEmpty else { return }

    let signals = nativePendingCallSignals
    nativePendingCallSignals.removeAll()
    for signal in signals {
      let ref = client.push(topic: topic, event: signal.event, payload: signal.payload)
      nativePendingCallPushRefs[ref] = signal.id
      appendJournalLocked(
        event: "native-call-signal-flush",
        payload: ["id": signal.id, "event": signal.event, "ref": ref, "topic": topic, "trigger": trigger]
      )
    }
    state["updatedAt"] = now
    let snapshot = statusSnapshotLocked()
    postChangeLocked(
      reason: "callSignalSent",
      userInfo: ["count": signals.count, "trigger": trigger, "state": snapshot]
    )
  }

  private func handleUserCallEventLocked(event: String, payload: [String: Any]) -> Bool {
    guard ["call-start", "call-accepted", "call-end", "webrtc-signal"].contains(event) else {
      return false
    }

    var callPayload = makeJSONSafeMap(payload)
    callPayload["event"] = event
    callPayload["direction"] = "inbound"
    appendJournalLocked(
      event: "native-call-signal-inbound",
      payload: [
        "event": event,
        "callId": normalizedString(callPayload["callId"] ?? callPayload["call_id"]) ?? "",
      ]
    )

    DispatchQueue.main.async {
      switch event {
      case "call-start":
        _ = VibeNativeCallEngine.shared.handleSignal(callPayload)
        if UIApplication.shared.applicationState != .active {
          let notificationPayload = callPayload.reduce(into: [AnyHashable: Any]()) { out, item in
            out[item.key] = item.value
          }
          _ = VibeNativeCallManager.shared.handleRemoteNotification(
            userInfo: notificationPayload,
            preferSystemUI: true
          )
        }
      case "call-end":
        var endPayload = callPayload
        endPayload["remote"] = true
        _ = VibeNativeCallEngine.shared.endCall(endPayload)
        VibeNativeCallManager.shared.clearIncomingCallUi(
          callId: self.normalizedString(callPayload["callId"] ?? callPayload["call_id"]))
      default:
        _ = VibeNativeCallEngine.shared.handleSignal(callPayload)
      }
    }
    return true
  }

  @available(iOS 13.0, *)
  private func handleNativeSocketFrame(_ frame: ChatTransportFrame) {
    // Captured off-queue, the instant the frame arrives from the socket, so we
    // can separate true wire round-trip from time spent waiting behind other
    // work on the serial engine queue when diagnosing send→ack latency.
    let frameArrivalMs = nowMs()
    queue.async {
      if frame.event == "phx_error",
        frame.topic.hasPrefix("chat:")
      {
        let chatId = String(frame.topic.dropFirst("chat:".count))
        self.recoverStaleNativeChatTopicLocked(
          chatId: chatId,
          reason: "channel_phx_error"
        )
        return
      }

      if frame.event == "phx_reply",
        frame.topic == self.nativeUserTopic,
        let ref = frame.ref,
        ref == self.nativeUserJoinRef,
        (frame.payload["status"] as? String) == "ok"
      {
        self.nativePresenceActive = true
        self.state["presenceSource"] = "native"
        self.state["userChannelState"] = "joined"
        self.state["updatedAt"] = self.nowMs()
        self.appendJournalLocked(event: "native-user-joined", payload: ["topic": frame.topic])
        self.flushPendingCallSignalsLocked(trigger: "user_joined")
        let snapshot = self.statusSnapshotLocked()
        self.postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
        return
      }

      if frame.event == "phx_reply", let ref = frame.ref {
        if let chatId = self.nativeChatJoinRefsByRef.removeValue(forKey: ref) {
          let status = (frame.payload["status"] as? String)?.lowercased() ?? ""
          if status == "ok" {
            self.nativeJoinedChatIds.insert(chatId)
            self.appendJournalLocked(event: "native-chat-joined", payload: ["chatId": chatId])
            self.flushPendingAgentBridgeHistoryRequestsLocked(chatId: chatId)
            self.sweepOrphanedPendingLocked(trigger: "chat_joined")
            self.ensureMlsProvisionedLocked(trigger: "chat_joined")
            self.refreshMlsPeerConfirmationLocked(chatId: chatId)
            self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "chat_joined")
            // Resume the live tail for a bridge session this chat had loaded: the topic is
            // freshly (re)joined after a view re-attach or background reconnect, so re-arm
            // the transcript watch instead of leaving the agent feed frozen.
            self.rearmLiveBridgeSessionLocked(chatId: chatId, trigger: "chat_joined")
            // Rejoin backfill: pull the newest history page. Join replay only covers
            // OUR queued sends — messages that settled while the socket was down
            // (backgrounded phone, network blip) otherwise never reach this device
            // until a cold history reload.
            self.backfillNewestChatHistoryLocked(chatId: chatId, trigger: "chat_joined")
            // Announce the topic JOIN so open surfaces can re-fire loads that lost the race
            // at cold launch. During a launch-time socket flap the current-session poll and
            // the History list both refuse with `chat_not_joined` and exhaust their bounded
            // retries BEFORE this join lands; without this post nothing re-triggers them, so
            // the chat + History stay empty until the user manually reopens. (Channel
            // open/close already posts this reason — join is the missing edge.)
            self.postChangeLocked(
              reason: "chatChannelStateChanged", userInfo: ["chatId": chatId])
          } else {
            self.appendJournalLocked(
              event: "native-chat-join-error",
              payload: [
                "chatId": chatId, "status": status, "payload": self.makeJSONSafeMap(frame.payload),
              ]
            )
          }
          self.state["updatedAt"] = self.nowMs()
          return
        }

        if let pending = self.nativePendingMessagePushRefs.removeValue(forKey: ref) {
          let status = (frame.payload["status"] as? String)?.lowercased() ?? ""
          let failureReason =
            status == "ok" ? "ok" : self.messagePushFailureReasonLocked(frame.payload)
          let bridgeProvider = self.bridgeProviderForChatLocked(chatId: pending.chatId)
          let replayDraft = self.pendingOutboundDraftsByMessageId[pending.messageId]
          let permanentFailure =
            status != "ok" && self.isPermanentMessagePushFailureLocked(frame.payload)
          let retryable =
            status != "ok"
            && bridgeProvider == nil
            && !permanentFailure
            && replayDraft != nil
          let staleTopic =
            status != "ok"
            && failureReason.contains("unmatched topic")
          let nextStatus = status == "ok" ? "sent" : (retryable ? "pending" : "error")
          if status != "ok" {
            let payloadKeys = frame.payload.keys.sorted().joined(separator: ",")
            NSLog(
              "[OutboundRetry] push reply chatId=%@ messageId=%@ status=%@ reason=%@ keys=%@ draft=%@ permanent=%@ retryable=%@",
              pending.chatId, pending.messageId, status, failureReason, payloadKeys,
              replayDraft == nil ? "N" : "Y",
              permanentFailure ? "Y" : "N",
              retryable ? "Y" : "N")
          }
          if let sentAtMs = self.nativeMessagePushSentAtMs.removeValue(forKey: ref) {
            let wireRTT = frameArrivalMs - sentAtMs
            let queueWait = self.nowMs() - frameArrivalMs
            NSLog(
              "[ChatEngine] ⏱️ send→%@ ack %dms (wire %dms + engineQueueWait %dms) chatId=%@ messageId=%@",
              nextStatus, Int(wireRTT + queueWait), Int(wireRTT), Int(queueWait),
              pending.chatId, pending.messageId)
          }
          if status == "ok" {
            self.cancelScheduledOutboundReplayLocked(
              messageId: pending.messageId, resetAttempt: true)
            self.removeQueuedOutboundDraftLocked(
              chatId: pending.chatId, messageId: pending.messageId, dropDraft: true)
          } else if let provider = bridgeProvider {
            // Server rejected the push — keep the user's text visible with an error
            // badge (tap-to-retry) instead of deleting the bubble.
            self.markVolatileBridgeSendErrorLocked(
              chatId: pending.chatId,
              messageId: pending.messageId,
              reason: "push_\(status.isEmpty ? "error" : status)",
              provider: provider
            )
            return
          } else if retryable,
            let draft = replayDraft
          {
            if staleTopic {
              // Phoenix returns this when the chat Channel process died while
              // the websocket itself stayed healthy. Do not tear down the
              // socket: invalidate only this topic and join it again now. The
              // join reply replays the queued draft, normally within one RTT.
              self.recoverStaleNativeChatTopicLocked(
                chatId: pending.chatId,
                reason: "push_unmatched_topic"
              )
            }
            self.appendJournalLocked(
              event: "native-message-push-reply",
              payload: [
                "chatId": pending.chatId,
                "messageId": pending.messageId,
                "ref": ref,
                "status": status,
                "reason": failureReason,
                "retryable": true,
              ])
            self.scheduleRetryableOutboundReplayLocked(
              chatId: pending.chatId,
              messageId: pending.messageId,
              draft: draft,
              reason: failureReason,
              recycleTransport: !staleTopic
            )
            return
          }
          self.cancelScheduledOutboundReplayLocked(
            messageId: pending.messageId, resetAttempt: true)
          self.removeQueuedOutboundDraftLocked(
            chatId: pending.chatId, messageId: pending.messageId, dropDraft: false)
          self.upsertLocalStatusLocked(
            chatId: pending.chatId, messageId: pending.messageId, status: nextStatus)
          self.appendJournalLocked(
            event: "native-message-push-reply",
            payload: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "ref": ref,
              "status": status,
              "reason": failureReason,
              "retryable": false,
            ])
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "messageStatusChanged",
            userInfo: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "status": nextStatus,
              "state": snapshot,
            ]
          )
          return
        }

        if let pending = self.nativePendingEditPushRefs.removeValue(forKey: ref) {
          let status = (frame.payload["status"] as? String)?.lowercased() ?? ""
          self.appendJournalLocked(
            event: "native-edit-message-push-reply",
            payload: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "ref": ref,
              "status": status,
            ])
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "chatMessageEdited",
            userInfo: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "action": "edited",
              "state": snapshot,
            ]
          )
          return
        }

        if let pending = self.nativePendingDeletePushRefs.removeValue(forKey: ref) {
          let status = (frame.payload["status"] as? String)?.lowercased() ?? ""
          let replyError =
            frame.payload["response"] ?? frame.payload["reason"] ?? frame.payload["error"]
          NSLog(
            "[DeleteTrace] reply chatId=%@ messageId=%@ forEveryone=%@ status=%@ error=%@",
            pending.chatId,
            pending.messageId,
            pending.forEveryone ? "true" : "false",
            status.isEmpty ? "missing" : status,
            replyError.map { String(describing: $0) } ?? "-")
          // Optimistic deletion is intentionally stable even when the server rejects the
          // push. Reassert the tombstone idempotently; never restore the row and flicker.
          self.removeMessageIndicesLocked(chatId: pending.chatId, messageId: pending.messageId)
          self.markLiveMessageDeletedLocked(chatId: pending.chatId, messageId: pending.messageId)
          self.appendJournalLocked(
            event: "native-delete-message-push-reply",
            payload: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "ref": ref,
              "status": status,
              "forEveryone": pending.forEveryone,
            ])
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "chatMessageDeleted",
            userInfo: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "action": "deleted",
              "state": snapshot,
            ]
          )
          return
        }

        if let callSignalId = self.nativePendingCallPushRefs.removeValue(forKey: ref) {
          let status = (frame.payload["status"] as? String)?.lowercased() ?? ""
          self.appendJournalLocked(
            event: "native-call-signal-reply",
            payload: ["id": callSignalId, "ref": ref, "status": status]
          )
          self.state["updatedAt"] = self.nowMs()
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(reason: "callSignalAck", userInfo: ["state": snapshot])
          return
        }
      }

      if frame.topic.hasPrefix("chat:") {
        let chatId = String(frame.topic.dropFirst(5))
        if frame.event == "agent-progress" {
          let payloadUserId = self.normalizedString(
            frame.payload["userId"] ?? frame.payload["user_id"] ?? frame.payload["id"])
          let isAgentEvent =
            (frame.payload["isAgent"] as? Bool == true)
            || payloadUserId?.lowercased() == Self.agentUserId
          if isAgentEvent {
            let label = self.normalizedString(frame.payload["label"])
            let tool = self.normalizedString(frame.payload["tool"])
            let status = self.normalizedString(frame.payload["status"]) ?? "running"
            self.setAgentProgressLocked(chatId: chatId, label: label, tool: tool, status: status)
          }
          return
        }
        if frame.event == "agent-stream" {
          self.applyAgentStreamLocked(chatId: chatId, payload: frame.payload)
          return
        }
        // Supervisor under-hood worker progress folded into the lead cell strip.
        if frame.event == "agent-team-worker" {
          if let teamRunId = self.normalizedString(
            frame.payload["teamRunId"] ?? frame.payload["team_run_id"])
          {
            self.mergeSuppressedTeamWorkerStreamLocked(
              chatId: chatId,
              teamRunId: teamRunId,
              payload: frame.payload
            )
          }
          return
        }
        // Subscription/rate-limit hit: no transcript row — refresh the usage banner.
        if frame.event == "agent-usage-limit" {
          let provider = self.normalizedString(frame.payload["provider"]) ?? ""
          let message = self.normalizedString(frame.payload["message"]) ?? ""
          self.postChangeLocked(
            reason: "agentUsageLimit",
            userInfo: [
              "chatId": chatId,
              "provider": provider,
              "message": message,
            ]
          )
          return
        }
        if frame.event == "agent-bridge-history" {
          self.applyAgentBridgeHistoryResultLocked(
            chatId: chatId, payload: frame.payload, transport: "cloud")
          return
        }
        if frame.event == "agent-bridge-file" {
          let requestId = self.normalizedString(frame.payload["requestId"]) ?? ""
          if !requestId.isEmpty {
            self.agentBridgeFileByRequestId[requestId] = frame.payload
          }
          self.postChangeLocked(
            reason: "agentBridgeFile",
            userInfo: [
              "chatId": chatId,
              "requestId": requestId,
              "ok": (frame.payload["ok"] as? Bool) ?? true,
            ]
          )
          return
        }
        if frame.event == "agent-bridge-usage" {
          let requestId = self.normalizedString(frame.payload["requestId"]) ?? ""
          if !requestId.isEmpty {
            self.agentBridgeUsageByRequestId[requestId] = frame.payload
          }
          // Cache by chat+provider for sheet prefill (even if requestId is empty).
          let provider =
            (self.normalizedString(frame.payload["provider"])
              ?? self.normalizedString(frame.payload["agentBridgeProvider"])
              ?? "")
            .lowercased()
          if !provider.isEmpty, (frame.payload["ok"] as? Bool) ?? true {
            let key = "\(chatId)|\(provider)"
            self.agentBridgeUsageByChatProvider[key] = frame.payload
          }
          self.postChangeLocked(
            reason: "agentBridgeUsage",
            userInfo: [
              "chatId": chatId,
              "requestId": requestId,
              "provider": provider,
              "ok": (frame.payload["ok"] as? Bool) ?? true,
            ]
          )
          return
        }
        if frame.event == "agent-bridge-ask" {
          let requestId = self.normalizedString(frame.payload["requestId"]) ?? ""
          let kind = self.normalizedString(frame.payload["kind"]) ?? "ask"
          let provider = self.normalizedString(frame.payload["provider"]) ?? ""
          let sealed = frame.payload["askEnc"] != nil
          if !requestId.isEmpty {
            self.agentBridgeAskByRequestId[requestId] = frame.payload
          }
          // An ask IS proof the run is alive (paused on the user) — refresh the running
          // mark so the ingest settle-clear / typing-stop paths hold the working header
          // instead of flipping to "Start session" while the approval sheet is up.
          self.agentTurnRunningAtMsByChatId[chatId] = Int64(self.nowMs())
          // Surface the paused-on-user state in the chat header ("Waiting for approval"
          // instead of a stale tool label) — the run makes no progress until answered,
          // so the last streamed action would otherwise sit there misleadingly.
          self.setAgentProgressLocked(
            chatId: chatId, label: "Waiting for approval", tool: nil, status: "running")
          // New bridge requests intentionally have no expiry: mobile remains the
          // control surface until the user answers. Preserve compatibility with an
          // explicitly configured legacy bridge timeout when it sends expiresAtMs.
          if let expiresAtMs = self.parseLongValue(
            frame.payload["expiresAtMs"] ?? frame.payload["expires_at_ms"])
          {
            let expiryDelaySeconds = max(1.0, Double(expiresAtMs - Int64(self.nowMs())) / 1000.0)
            self.queue.asyncAfter(deadline: .now() + expiryDelaySeconds) { [weak self] in
              guard let self else { return }
              guard self.agentBridgeAskByRequestId[requestId] != nil else { return }
              self.agentBridgeAskByRequestId.removeValue(forKey: requestId)
              self.presentedAskRequestIds.remove(requestId)
              self.postChangeLocked(
                reason: "agentBridgeAskCancel",
                userInfo: ["chatId": chatId, "requestId": requestId]
              )
            }
          }
          NSLog(
            "[ChatEngine][ask] RECEIVED chat=%@ requestId=%@ kind=%@ provider=%@ sealed=%@ stored=%@ → post agentBridgeAsk",
            chatId, requestId, kind, provider, sealed ? "Y" : "N", requestId.isEmpty ? "N(empty-requestId)" : "Y"
          )
          self.postChangeLocked(
            reason: "agentBridgeAsk",
            userInfo: [
              "chatId": chatId,
              "requestId": requestId,
              "kind": kind,
              "provider": provider,
              // Conversation scoping: the CLI session that raised this ask (empty when
              // the bridge couldn't resolve one). Surfaces drop asks whose session
              // doesn't match the conversation they're showing. `resumedFromSessionId`
              // is the id the run resumed FROM — a resumed run mints a NEW session id,
              // but the page still identifies the conversation by the old one.
              "sessionId": self.normalizedString(
                frame.payload["sessionId"] ?? frame.payload["session_id"]) ?? "",
              "resumedFromSessionId": self.normalizedString(
                frame.payload["resumedFromSessionId"] ?? frame.payload["resumed_from_session_id"])
                ?? "",
            ]
          )
          return
        }
        if frame.event == "agent-bridge-ask-cancel" {
          // The bridge resolved this ask/command elsewhere (answered at the desk, or the
          // caller timed out/disconnected). Drop the cached request + presentation claim
          // and tell any presented sheet to dismiss — so a stale "waiting for approval"
          // sheet doesn't linger after the command already left the device.
          let requestId = self.normalizedString(frame.payload["requestId"]) ?? ""
          if !requestId.isEmpty {
            self.agentBridgeAskByRequestId.removeValue(forKey: requestId)
            self.presentedAskRequestIds.remove(requestId)
          }
          NSLog("[ChatEngine][ask] CANCEL chat=%@ requestId=%@ → post agentBridgeAskCancel", chatId, requestId)
          self.postChangeLocked(
            reason: "agentBridgeAskCancel",
            userInfo: [
              "chatId": chatId,
              "requestId": requestId,
            ]
          )
          return
        }
        if frame.event == "typing" || frame.event == "stop-typing" {
          let typing = frame.event == "typing"
          let payloadUserId = self.normalizedUpper(
            frame.payload["userId"] ?? frame.payload["user_id"] ?? frame.payload["id"])
          let myUserId = self.normalizedUpper(self.getConfigValueLocked("userId"))
          var typingUsers = self.peerTypingUserIdsByChatId[chatId] ?? Set<String>()
          if let payloadUserId, payloadUserId != myUserId {
            if typing {
              typingUsers.insert(payloadUserId)
            } else {
              typingUsers.remove(payloadUserId)
            }
            if typingUsers.isEmpty {
              self.peerTypingUserIdsByChatId.removeValue(forKey: chatId)
            } else {
              self.peerTypingUserIdsByChatId[chatId] = typingUsers
            }
          } else if !typing {
            self.peerTypingUserIdsByChatId.removeValue(forKey: chatId)
            typingUsers.removeAll()
          }
          if !typing, payloadUserId?.lowercased() == Self.agentUserId {
            // A bridge run that pauses (command approval, thinking gap) can emit the agent
            // user's typing:false while the turn is very much alive — the run's OWN signals
            // (stream frames / running transcript / outstanding ask) refresh the grace mark,
            // so only let a typing stop clear the header once those have gone quiet too.
            let sinceRunningMs =
              Int64(self.nowMs()) - (self.agentTurnRunningAtMsByChatId[chatId] ?? 0)
            let askOutstanding = self.agentBridgeAskByRequestId.values.contains { payload in
              (self.normalizedString(payload["chatId"]) ?? "") == chatId
            }
            if askOutstanding || sinceRunningMs < Self.agentTurnRunningGraceMs {
              VibeDebugLog.log(
                "[EmptyTrace] agentTypingStopped HOLD chatId=%@ ask=%@ sinceRunningMs=%lld",
                String(chatId.suffix(12)), askOutstanding ? "Y" : "N", sinceRunningMs)
            } else {
              self.clearAgentProgressLocked(chatId: chatId, status: "done", reason: "agentTypingStopped(A)")
            }
          }
          let typingUserIds = Array(typingUsers).sorted()
          let isAnyTyping = !typingUserIds.isEmpty || (typing && payloadUserId == nil)
          self.postChangeLocked(
            reason: "peerTyping",
            userInfo: [
              "chatId": chatId,
              "messageId": isAnyTyping ? "true" : "false",  // Kept for ChatListView compatibility.
              "typingUserIds": typingUserIds,
            ]
          )
          return
        }
        if frame.event == "pinned-updated" {
          guard
            let messageId = self.normalizedString(
              frame.payload["messageId"] ?? frame.payload["message_id"])
          else { return }
          let pinned = self.parseBooleanLike(frame.payload["pinned"]) ?? true
          NSLog(
            "[ChatEngine][Pin] socket pinned-updated chatId=%@ messageId=%@ pinned=%@ payloadKeys=%@",
            chatId,
            messageId,
            pinned ? "true" : "false",
            Array(frame.payload.keys).sorted().joined(separator: ",")
          )
          self.applyPinnedUpdateLocked(
            chatId: chatId,
            messageId: messageId,
            pinned: pinned,
            payload: frame.payload,
            trigger: "socket_pinned_updated",
            refreshRemote: true
          )
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "chatPinnedUpdated",
            userInfo: [
              "chatId": chatId,
              "messageId": messageId,
              "pinned": pinned,
              "state": snapshot,
            ]
          )
          return
        }
        let incomingMessageId = self.normalizedString(frame.payload["id"] ?? frame.payload["message_id"])
        let incomingMessageWasPresent = incomingMessageId.map { messageId in
          self.liveMessageRowsByChat[chatId]?[messageId] != nil
            || (self.historyRowsByChat[chatId] ?? []).contains {
              self.messageId(fromRow: $0) == messageId
            }
        } ?? false
        if frame.event == "message",
          let insertedMessageId = self.applyNativeIncomingMessageEventLocked(
            chatId: chatId, payload: frame.payload, postDelta: false)
        {
          let fromId = self.normalizedString(frame.payload["fromId"] ?? frame.payload["from_id"])
          let isAgentMessage =
            (frame.payload["isAgentMessage"] as? Bool == true)
            || fromId?.lowercased() == Self.agentUserId
            || (fromId.map { Self.reservedBridgeAgentUserIds.contains($0.lowercased()) } ?? false)
          var removedStreamIds: [String] = []
          if isAgentMessage {
            // Only clear the shared header progress when no other agent is still typing
            // in this group — otherwise Claude's finish blanks "Grok typing…".
            let othersStillTyping: Bool = {
              guard let typers = self.peerTypingUserIdsByChatId[chatId], !typers.isEmpty else {
                return false
              }
              let sender = self.normalizedUpper(fromId)
              return typers.contains { self.normalizedUpper($0) != sender }
            }()
            if !othersStillTyping {
              self.clearAgentProgressLocked(
                chatId: chatId, status: "done", reason: "agentPersistedMessage")
            }
            // The persisted message supersedes any live streaming bubble for this agent
            // (cloud `stream-…` and LAN `lan-…` dual-path rows). The reply adopts the
            // live bubble's slot so the list keeps "who responded first" order instead
            // of reshuffling every reply to the bottom as it settles (multi-agent groups
            // settled 3 swaps in <1s — the jumping/overlap churn).
            let removal = self.removeAgentStreamRowsLocked(chatId: chatId, agentUserId: fromId)
            removedStreamIds = removal.removedIds
            if let slotTs = removal.slotTs {
              self.adoptAgentSettleSlotTsLocked(
                chatId: chatId, messageId: insertedMessageId, slotTs: slotTs)
            }
          }

          let myUserId = self.normalizedUpper(self.getConfigValueLocked("userId"))
          let isMe = self.normalizedUpper(fromId) == myUserId

          if !isMe {
            _ = self.sendDeliveryReceipt([
              "chatId": chatId,
              "messageId": insertedMessageId,
            ])
          }

          if var typingUsers = self.peerTypingUserIdsByChatId[chatId], !typingUsers.isEmpty {
            // Only the SENDER stops typing when their message lands. A group can have a
            // second agent (or person) still typing; wiping the whole set here blanked the
            // "Codex typing…" header the moment Claude's reply arrived.
            if let senderUpper = self.normalizedUpper(fromId) {
              typingUsers = typingUsers.filter { self.normalizedUpper($0) != senderUpper }
            } else {
              typingUsers = []
            }
            if typingUsers != self.peerTypingUserIdsByChatId[chatId] {
              if typingUsers.isEmpty {
                self.peerTypingUserIdsByChatId.removeValue(forKey: chatId)
              } else {
                self.peerTypingUserIdsByChatId[chatId] = typingUsers
              }
              self.postChangeLocked(
                reason: "peerTyping",
                userInfo: [
                  "chatId": chatId,
                  "messageId": typingUsers.isEmpty ? "false" : "true",
                  "typingUserIds": Array(typingUsers).sorted(),
                ]
              )
            }
          }
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "chatMessageInserted",
            userInfo: [
              "chatId": chatId,
              "messageId": insertedMessageId,
              "state": snapshot,
            ]
          )
          self.postChatDeltaLocked(
            chatId: chatId,
            inserted: incomingMessageWasPresent ? [] : [insertedMessageId],
            updated: incomingMessageWasPresent ? [insertedMessageId] : [],
            deleted: removedStreamIds,
            source: removedStreamIds.isEmpty ? "live" : "streamSettle")
          return
        }
        if let mutationUpdate = self.applyNativeChatMutationEventLocked(
          chatId: chatId, event: frame.event, payload: frame.payload)
        {
          let reason: String = {
            switch mutationUpdate.action {
            case "edited": return "chatMessageEdited"
            case "deleted": return "chatMessageDeleted"
            default: return "chatMessageChanged"
            }
          }()
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: reason,
            userInfo: [
              "chatId": chatId,
              "messageId": mutationUpdate.messageId,
              "action": mutationUpdate.action,
              "state": snapshot,
            ]
          )
          switch mutationUpdate.action {
          case "edited":
            self.postChatDeltaLocked(
              chatId: chatId, inserted: [], updated: [mutationUpdate.messageId], deleted: [],
              source: "edit")
          case "deleted":
            self.postChatDeltaLocked(
              chatId: chatId, inserted: [], updated: [], deleted: [mutationUpdate.messageId],
              source: "delete")
          default:
            break
          }
          return
        }
        if let receiptUpdate = self.applyNativeChatEventLocked(
          chatId: chatId, event: frame.event, payload: frame.payload)
        {
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "messageStatusChanged",
            userInfo: [
              "chatId": chatId,
              "messageId": receiptUpdate.messageId,
              "status": receiptUpdate.status,
              "state": snapshot,
            ]
          )
          return
        }
      }

      guard frame.topic == self.nativeUserTopic else { return }
      if frame.event == "bridge-status" {
        // Live bridge status off the socket. Replaces the client's repeated polling of
        // /api/agent-bridge/status — the server pushes this on every Presence change.
        let payload = frame.payload
        DispatchQueue.main.async {
          AgentPairingService.ingestSocketStatusSnapshot(payload)
        }
        return
      }
      if frame.event == "chat-deleted" {
        guard
          let chatId = self.normalizedString(
            frame.payload["chatId"] ?? frame.payload["chat_id"]),
          !chatId.isEmpty
        else { return }
        self.clearChatStateLocked(chatId: chatId, journalEvent: "native-chat-clear-remote")
        return
      }
      if frame.event == "message-edited" || frame.event == "message-deleted" {
        guard
          let chatId = self.normalizedString(
            frame.payload["chatId"] ?? frame.payload["chat_id"]),
          !chatId.isEmpty
        else { return }
        // A mounted chat receives the authoritative event on `chat:<id>`. Ignoring its
        // user-topic mirror avoids a second delete/edit delta while still giving Home,
        // another chat, and this user's other devices the same realtime mutation.
        guard !self.nativeJoinedChatIds.contains(chatId) else { return }
        guard
          let mutationUpdate = self.applyNativeChatMutationEventLocked(
            chatId: chatId, event: frame.event, payload: frame.payload)
        else {
          // Compatibility/oversize fallback: older servers and deliberately omitted
          // mirrors cannot hydrate a never-opened row. Tell Home to reconcile without
          // blocking the navigation transition or clearing its populated cached tail.
          self.postChangeLocked(
            reason: "remoteChatMutationMiss",
            userInfo: [
              "chatId": chatId,
              "messageId": self.normalizedString(
                frame.payload["messageId"] ?? frame.payload["message_id"]) as Any,
              "chatIsOnScreen": false,
              "state": self.statusSnapshotLocked(),
            ]
          )
          return
        }
        let reason =
          mutationUpdate.action == "edited" ? "chatMessageEdited" : "chatMessageDeleted"
        self.postChangeLocked(
          reason: reason,
          userInfo: [
            "chatId": chatId,
            "messageId": mutationUpdate.messageId,
            "action": mutationUpdate.action,
            "chatIsOnScreen": false,
            "state": self.statusSnapshotLocked(),
          ]
        )
        if mutationUpdate.action == "edited" {
          self.postChatDeltaLocked(
            chatId: chatId, inserted: [], updated: [mutationUpdate.messageId], deleted: [],
            source: "userTopicEdit")
        } else {
          self.postChatDeltaLocked(
            chatId: chatId, inserted: [], updated: [], deleted: [mutationUpdate.messageId],
            source: "userTopicDelete")
        }
        return
      }
      if frame.event == "message-delivered" || frame.event == "message-read" {
        guard
          let chatId = self.normalizedString(
            frame.payload["chatId"] ?? frame.payload["chat_id"]),
          !chatId.isEmpty
        else { return }
        // As above, an open affected chat already receives the chat-topic receipt.
        guard !self.nativeJoinedChatIds.contains(chatId) else { return }
        guard
          let receiptUpdate = self.applyNativeChatEventLocked(
            chatId: chatId, event: frame.event, payload: frame.payload)
        else { return }
        self.postChangeLocked(
          reason: "messageStatusChanged",
          userInfo: [
            "chatId": chatId,
            "messageId": receiptUpdate.messageId,
            "status": receiptUpdate.status,
            "chatIsOnScreen": false,
            "state": self.statusSnapshotLocked(),
          ]
        )
        return
      }
      if frame.event == "new_message" {
        // A new message landed in one of this user's chats (from a peer, an agent, or
        // mirrored from the user's OWN other device). Devices only join a chat's
        // realtime topic while that chat screen is open, so this user-topic ping is how
        // the chat LIST and any other-device surface learn about it.
        //
        // The server now mirrors the message itself under `message` (see
        // `Vibe.Chat.mirrored_message_payload/1`). Ingesting it here is what makes the
        // chat list real-time: without it the ping carried only ids, so Home could
        // project nothing, had to wait for a debounced `/api/chats` round trip, and a
        // row tapped inside that window opened on a transcript that did not contain the
        // message its own notification had just announced.
        let signalChatId = self.normalizedString(
          frame.payload["chatId"] ?? frame.payload["chat_id"])
        var ingested: (messageId: String, inserted: Bool)?
        if let chatId = signalChatId, !chatId.isEmpty,
          let mirrored = frame.payload["message"] as? [String: Any],
          !mirrored.isEmpty
        {
          ingested = self.ingestMirroredUserTopicMessageLocked(
            chatId: chatId, payload: mirrored)
        }
        var userInfo: [String: Any] = [
          "chatId": signalChatId ?? "",
          "state": self.statusSnapshotLocked(),
          // Free here (we already hold the queue) and it saves the chat list a
          // synchronous hop back into this queue just to ask whether the conversation
          // it is about to badge is the one on screen.
          "chatIsOnScreen": signalChatId.map { self.nativeJoinedChatIds.contains($0) } ?? false,
        ]
        // Additive: lets Home account for exactly this message (unread, projection)
        // instead of inferring it from whatever happens to be newest. `inserted` is what
        // makes a redelivery idempotent — an upsert that only updated an existing row
        // must not raise the badge a second time.
        if let ingested {
          userInfo["messageId"] = ingested.messageId
          userInfo["inserted"] = ingested.inserted
        }
        self.postChangeLocked(reason: "remoteNewMessage", userInfo: userInfo)
        return
      }
      if self.handleUserCallEventLocked(event: frame.event, payload: frame.payload) {
        let snapshot = self.statusSnapshotLocked()
        self.postChangeLocked(
          reason: "callSignalReceived",
          userInfo: ["event": frame.event, "state": snapshot]
        )
        return
      }
      if self.applyPresenceEventLocked(event: frame.event, payload: frame.payload) {
        self.state["presenceSource"] = "native"
        self.state["updatedAt"] = self.nowMs()
        let snapshot = self.statusSnapshotLocked()
        self.postChangeLocked(
          reason: "presenceChanged",
          userInfo: ["onlineCount": self.onlineUsers.count, "state": snapshot]
        )
      }
    }
  }

  private func applyPresenceEventLocked(event: String, payload: [String: Any]) -> Bool {
    switch event {
    case "initial-presence":
      let ids = (payload["onlineFriendIds"] as? [Any])?.compactMap { normalizedUpper($0) } ?? []
      onlineUsers = Set(ids)
      for userId in ids {
        lastSeenByUserId.removeValue(forKey: userId)
      }
      appendJournalLocked(event: "native-presence-initial", payload: ["count": ids.count])
      return true
    case "friend-online":
      if let userId = normalizedUpper(payload["userId"] ?? payload["user_id"] ?? payload["id"]) {
        onlineUsers.insert(userId)
        lastSeenByUserId.removeValue(forKey: userId)
        appendJournalLocked(event: "native-presence-online", payload: ["userId": userId])
        return true
      }
      return false
    case "friend-offline":
      if let userId = normalizedUpper(payload["userId"] ?? payload["user_id"] ?? payload["id"]) {
        onlineUsers.remove(userId)
        let lastSeen =
          parseLongValue(
            payload["lastSeenMs"] ?? payload["last_seen_ms"] ?? payload["lastSeen"]
              ?? payload["last_seen"])
          ?? Int64(nowMs())
        lastSeenByUserId[userId] = lastSeen
        appendJournalLocked(
          event: "native-presence-offline",
          payload: ["userId": userId, "lastSeenMs": lastSeen])
        return true
      }
      return false
    case "presence_state":
      let ids = payload.keys.compactMap { normalizedUpper($0) }
      onlineUsers = Set(ids)
      for userId in ids {
        lastSeenByUserId.removeValue(forKey: userId)
      }
      appendJournalLocked(event: "native-presence-state", payload: ["count": ids.count])
      return true
    case "presence_diff", "presence-diff":
      let joins = payload["joins"] as? [String: Any] ?? [:]
      let leaves = payload["leaves"] as? [String: Any] ?? [:]
      for id in joins.keys {
        if let normalized = normalizedUpper(id) {
          onlineUsers.insert(normalized)
          lastSeenByUserId.removeValue(forKey: normalized)
        }
      }
      for id in leaves.keys {
        if let normalized = normalizedUpper(id) {
          onlineUsers.remove(normalized)
          lastSeenByUserId[normalized] = Int64(nowMs())
        }
      }
      appendJournalLocked(
        event: "native-presence-diff",
        payload: [
          "joins": joins.keys.count,
          "leaves": leaves.keys.count,
        ])
      return true
    default:
      return false
    }
  }

  private func getConfigValueLocked(_ key: String) -> Any? {
    store.getConfig()[key]
  }

  private func transportModeLocked(config: [String: Any]? = nil) -> String {
    let resolvedConfig = config ?? store.getConfig()
    let mode =
      normalizedString(resolvedConfig["transportMode"])?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).lowercased()
    switch mode {
    case "direct", "packet_mesh", "bridge_text", "offline":
      return mode ?? "packet_mesh"
    default:
      return "direct"
    }
  }

  private func isBridgeTextModeLocked(config: [String: Any]? = nil) -> Bool {
    transportModeLocked(config: config) == "bridge_text"
  }

  private func packetProxyPortLocked(config: [String: Any]? = nil) -> Int? {
    let resolvedConfig = config ?? store.getConfig()
    if let value = resolvedConfig["packetProxyPort"] as? NSNumber {
      return value.intValue
    }
    if let value = normalizedString(resolvedConfig["packetProxyPort"]), let port = Int(value) {
      return port
    }
    return nil
  }

  private func packetProxyHostLocked(config: [String: Any]? = nil) -> String {
    let resolvedConfig = config ?? store.getConfig()
    return normalizedString(resolvedConfig["packetProxyHost"]) ?? "127.0.0.1"
  }

  private func disableMediaLocked(config: [String: Any]? = nil) -> Bool {
    let resolvedConfig = config ?? store.getConfig()
    return parseBooleanLike(resolvedConfig["disableMedia"])
      ?? isBridgeTextModeLocked(config: resolvedConfig)
  }

  private func disableCallsLocked(config: [String: Any]? = nil) -> Bool {
    let resolvedConfig = config ?? store.getConfig()
    return parseBooleanLike(resolvedConfig["disableCalls"])
      ?? ["bridge_text", "packet_mesh"].contains(transportModeLocked(config: resolvedConfig))
  }

  private func disableRemoteAvatarsLocked(config: [String: Any]? = nil) -> Bool {
    let resolvedConfig = config ?? store.getConfig()
    return parseBooleanLike(resolvedConfig["disableRemoteAvatars"])
      ?? isBridgeTextModeLocked(config: resolvedConfig)
  }

  private func bridgeBaseURLLocked(config: [String: Any]? = nil) -> URL? {
    let resolvedConfig = config ?? store.getConfig()
    if let explicit = normalizedString(resolvedConfig["bridgeBaseUrl"]), let url = URL(string: explicit) {
      return url
    }
    let activeBridgeId = normalizedString(resolvedConfig["activeBridgeId"])
    let bundle = resolvedConfig["bridgeBundle"] as? [String: Any]
    let descriptors = bundle?["descriptors"] as? [[String: Any]] ?? []
    let preferred =
      descriptors.first(where: { normalizedString($0["id"]) == activeBridgeId })
      ?? descriptors.sorted { left, right in
        let leftPriority = parseLongValue(left["priority"]) ?? 999
        let rightPriority = parseLongValue(right["priority"]) ?? 999
        return leftPriority < rightPriority
      }.first
    guard let preferred else { return nil }
    if let baseUrl = normalizedString(preferred["baseUrl"]), let url = URL(string: baseUrl) {
      return url
    }
    guard let host = normalizedString(preferred["host"]) else { return nil }
    let transport = normalizedString(preferred["transport"]) == "http" ? "http" : "https"
    let port = parseLongValue(preferred["port"]).map { ":\($0)" } ?? ""
    let pathPrefix =
      normalizedString(preferred["pathPrefix"])?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let suffix = (pathPrefix?.isEmpty == false) ? "/\(pathPrefix!)" : ""
    return URL(string: "\(transport)://\(host)\(port)\(suffix)")
  }

  private func bridgeURLLocked(_ path: String, config: [String: Any]? = nil) -> URL? {
    guard let base = bridgeBaseURLLocked(config: config) else { return nil }
    let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return base.appendingPathComponent(trimmed)
  }

  private func extractPublicKeyValue(from data: [String: Any]) -> String? {
    normalizedString(data["publicKey"])
      ?? normalizedString(data["friendKey"])
      ?? normalizedString(data["friendPublicKey"])
      ?? normalizedString(data["public_key"])
      ?? normalizedString(data["public_key_pem"])
      ?? ((data["data"] as? [String: Any]).flatMap(extractPublicKeyValue(from:)))
      ?? ((data["user"] as? [String: Any]).flatMap(extractPublicKeyValue(from:)))
      ?? ((data["friend"] as? [String: Any]).flatMap(extractPublicKeyValue(from:)))
  }

  private func resolveFriendPublicKeyLocked(chatId: String, peerUserIdHint: String?) -> String? {
    let resolvedPeerId = peerUserIdHint ?? chatPeerUserIdsByChatId[chatId]
    if let resolvedPeerId {
      chatPeerUserIdsByChatId[chatId] = resolvedPeerId
    }
    if let resolvedPeerId, let cached = friendPublicKeysByUserId[resolvedPeerId] {
      return cached
    }
    return nil
  }

  /// Reserved shadow-user ids for the computer-bridge agents (Claude/Codex),
  /// seeded server-side. They are real users with no `Agent` record, so the
  /// server never sends a `peerAgentId` for them — we recognize the ids here so a
  /// DM with them routes as an agent (cleartext) instead of being E2E-encrypted to
  /// a non-existent friend key, which silently drops the prompt into the chat.
  private static let claudeBridgeAgentUserId = "11111111-1111-1111-1111-111111111111"
  private static let codexBridgeAgentUserId = "22222222-2222-2222-2222-222222222222"
  private static let grokBridgeAgentUserId = "33333333-3333-3333-3333-333333333333"
  private static let agyBridgeAgentUserId = "44444444-4444-4444-4444-444444444444"
  private static let reservedBridgeAgentUserIds: Set<String> = [
    claudeBridgeAgentUserId,
    codexBridgeAgentUserId,
    grokBridgeAgentUserId,
    agyBridgeAgentUserId,
  ]

  private static let bridgeAgentProvidersByUserId: [String: String] = [
    claudeBridgeAgentUserId: "claude",
    codexBridgeAgentUserId: "codex",
    grokBridgeAgentUserId: "grok",
    agyBridgeAgentUserId: "agy",
  ]

  private static func bridgeAgentUserId(forProvider provider: String) -> String? {
    switch provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "claude": return claudeBridgeAgentUserId
    case "codex": return codexBridgeAgentUserId
    case "grok": return grokBridgeAgentUserId
    case "agy", "antigravity": return agyBridgeAgentUserId
    default: return nil
    }
  }

  private func bridgeProviderForAgentIdentifier(_ raw: String?) -> String? {
    guard let value = normalizedString(raw)?.lowercased() else { return nil }
    switch value {
    case "claude", Self.claudeBridgeAgentUserId:
      return "claude"
    case "codex", Self.codexBridgeAgentUserId:
      return "codex"
    case "grok", Self.grokBridgeAgentUserId:
      return "grok"
    case "agy", "antigravity", Self.agyBridgeAgentUserId:
      return "agy"
    default:
      return nil
    }
  }

  private func bridgeProviderForMetadata(_ metadata: [String: Any]) -> String? {
    bridgeProviderForAgentIdentifier(
      normalizedString(metadata["agentBridgeProvider"] ?? metadata["agent_bridge_provider"] ?? metadata["provider"]))
  }

  private func bridgeProviderForChatLocked(
    chatId: String?,
    peerUserId: String? = nil,
    peerAgentId: String? = nil,
    metadata: [String: Any] = [:]
  ) -> String? {
    if let provider = bridgeProviderForMetadata(metadata) {
      return provider
    }
    if let provider = bridgeProviderForAgentIdentifier(peerAgentId) {
      return provider
    }
    if let peer = normalizedString(peerUserId)?.lowercased(),
      let provider = Self.bridgeAgentProvidersByUserId[peer]
    {
      return provider
    }
    guard let chatId, !chatId.isEmpty else { return nil }
    if let cachedAgentId = chatPeerAgentIdsByChatId[chatId],
      let provider = bridgeProviderForAgentIdentifier(cachedAgentId)
    {
      return provider
    }
    if let cachedPeer = chatPeerUserIdsByChatId[chatId]?.lowercased(),
      let provider = Self.bridgeAgentProvidersByUserId[cachedPeer]
    {
      return provider
    }
    return nil
  }

  private func isVolatileBridgeAgentChatLocked(
    chatId: String?,
    peerUserId: String? = nil,
    peerAgentId: String? = nil,
    metadata: [String: Any] = [:]
  ) -> Bool {
    let isAgent =
      bridgeProviderForChatLocked(
        chatId: chatId,
        peerUserId: peerUserId,
        peerAgentId: peerAgentId,
        metadata: metadata
      ) != nil
    // Provider just resolved for a real chatId — remember it so a future cold launch
    // (peer maps empty) still knows this DM is agent and keeps its transcript off disk.
    if isAgent, let chatId, !chatId.isEmpty {
      markAgentDMChatForPersistenceLocked(chatId: chatId)
    }
    return isAgent
  }

  private func resolvePeerAgentIdLocked(chatId: String, peerUserIdHint: String?) -> String? {
    if let cached = chatPeerAgentIdsByChatId[chatId], !cached.isEmpty {
      return cached
    }
    let resolvedPeerId = peerUserIdHint ?? chatPeerUserIdsByChatId[chatId]
    guard let resolvedPeerId else { return nil }
    if let mapped = agentIdsByPeerUserId[resolvedPeerId] { return mapped }
    if Self.reservedBridgeAgentUserIds.contains(resolvedPeerId.lowercased()) {
      return resolvedPeerId
    }
    return nil
  }

  private func scheduleFriendPublicKeyRetryLocked(peerId: String, reason: String) {
    guard pendingFriendKeyChatIdsByUserId[peerId]?.isEmpty == false else {
      friendKeyRetryWorkItemsByUserId[peerId]?.cancel()
      friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
      return
    }
    guard friendKeyRetryWorkItemsByUserId[peerId] == nil else { return }

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.queue.async {
        self.friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
        guard let chatId = self.pendingFriendKeyChatIdsByUserId[peerId]?.first else { return }
        self.scheduleFriendPublicKeyFetchLocked(
          chatId: chatId,
          peerUserIdHint: peerId,
          trigger: "retry_\(reason)"
        )
      }
    }
    friendKeyRetryWorkItemsByUserId[peerId] = workItem
    queue.asyncAfter(deadline: .now() + 1.0, execute: workItem)
  }

  private func scheduleFriendPublicKeyFetchLocked(
    chatId: String,
    peerUserIdHint: String?,
    trigger: String
  ) {
    let resolvedPeerId = (peerUserIdHint ?? chatPeerUserIdsByChatId[chatId])?.uppercased()
    guard let peerId = resolvedPeerId, !peerId.isEmpty else { return }
    chatPeerUserIdsByChatId[chatId] = peerId
    if friendPublicKeysByUserId[peerId] != nil {
      scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "friend_key_cached")
      return
    }

    var pendingChats = pendingFriendKeyChatIdsByUserId[peerId] ?? Set<String>()
    pendingChats.insert(chatId)
    pendingFriendKeyChatIdsByUserId[peerId] = pendingChats

    guard !friendKeyFetchInFlightUserIds.contains(peerId) else { return }
    let isBridgeText = isBridgeTextModeLocked()
    guard let token = authHeaderTokenLocked() else { return }
    let requestURL: URL? =
      isBridgeText
      ? bridgeURLLocked("/bridge/v1/keys/peer")
      : apiBaseURLLocked()?.appendingPathComponent("api").appendingPathComponent("user")
        .appendingPathComponent(peerId)
    guard let requestURL else { return }

    friendKeyRetryWorkItemsByUserId[peerId]?.cancel()
    friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
    friendKeyFetchInFlightUserIds.insert(peerId)

    var request = URLRequest(url: requestURL)
    request.httpMethod = isBridgeText ? "POST" : "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if isBridgeText {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 8.0
    if isBridgeText {
      request.httpBody = try? JSONSerialization.data(
        withJSONObject: ["peerUserId": peerId, "chatId": chatId], options: [])
    }
    appendJournalLocked(
      event: "friend-key-fetch-start",
      payload: ["peerUserId": peerId, "chatId": chatId, "trigger": trigger]
    )
    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        self.friendKeyFetchInFlightUserIds.remove(peerId)

        let statusCode = (response as? HTTPURLResponse)?.statusCode
        let parsedObject: [String: Any]? = {
          guard error == nil,
            let statusCode,
            (200...299).contains(statusCode),
            let data
          else { return nil }
          return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }()
        let resolvedKey: String? = {
          guard let obj = parsedObject else { return nil }
          return
            self.normalizedString(obj["publicKey"])
            ?? self.normalizedString(obj["friendKey"])
            ?? self.normalizedString(obj["friendPublicKey"])
            ?? self.normalizedString(obj["public_key"])
            ?? self.normalizedString(obj["public_key_pem"])
            ?? ((obj["data"] as? [String: Any]).flatMap(self.extractPublicKeyValue(from:)))
            ?? ((obj["user"] as? [String: Any]).flatMap(self.extractPublicKeyValue(from:)))
            ?? ((obj["friend"] as? [String: Any]).flatMap(self.extractPublicKeyValue(from:)))
        }()
        let resolvedAgentId: String? = {
          guard let obj = parsedObject else { return nil }
          let nested = obj["data"] as? [String: Any]
          let isAgent =
            (obj["isAgent"] as? Bool == true)
            || (nested?["isAgent"] as? Bool == true)
          guard isAgent else { return nil }
          return
            self.normalizedString(obj["agentId"] ?? obj["agent_id"])
            ?? self.normalizedString(nested?["agentId"] ?? nested?["agent_id"])
        }()

        let waitingChatIds = Array(self.pendingFriendKeyChatIdsByUserId[peerId] ?? [])
        if let resolvedAgentId, !resolvedAgentId.isEmpty {
          self.agentIdsByPeerUserId[peerId] = resolvedAgentId
          for waitingChatId in waitingChatIds {
            self.chatPeerAgentIdsByChatId[waitingChatId] = resolvedAgentId
          }
        }
        if let resolvedKey {
          self.friendPublicKeysByUserId[peerId] = resolvedKey
          for waitingChatId in waitingChatIds {
            self.chatPeerUserIdsByChatId[waitingChatId] = peerId
          }
          self.pendingFriendKeyChatIdsByUserId.removeValue(forKey: peerId)
          self.friendKeyRetryWorkItemsByUserId[peerId]?.cancel()
          self.friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
          self.appendJournalLocked(
            event: "friend-key-fetch-ok",
            payload: ["peerUserId": peerId, "chatCount": waitingChatIds.count]
          )
          for waitingChatId in waitingChatIds {
            self.scheduleReplayQueuedOutboundLocked(
              chatId: waitingChatId, trigger: "friend_key_loaded")
          }
          return
        }

        if let resolvedAgentId, !resolvedAgentId.isEmpty {
          self.pendingFriendKeyChatIdsByUserId.removeValue(forKey: peerId)
          self.friendKeyRetryWorkItemsByUserId[peerId]?.cancel()
          self.friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
          self.appendJournalLocked(
            event: "friend-key-fetch-agent-ok",
            payload: [
              "peerUserId": peerId,
              "chatCount": waitingChatIds.count,
              "agentId": resolvedAgentId,
            ]
          )
          for waitingChatId in waitingChatIds {
            self.scheduleReplayQueuedOutboundLocked(
              chatId: waitingChatId, trigger: "peer_agent_loaded")
          }
          return
        }

        self.appendJournalLocked(
          event: "friend-key-fetch-error",
          payload: [
            "peerUserId": peerId,
            "chatCount": waitingChatIds.count,
            "status": statusCode as Any,
            "error": error?.localizedDescription as Any,
          ])
        let shouldRetry = waitingChatIds.contains {
          !(self.pendingOutboundQueueByChat[$0]?.isEmpty ?? true)
        }
        if shouldRetry {
          self.scheduleFriendPublicKeyRetryLocked(peerId: peerId, reason: "fetch_failed")
        } else {
          self.pendingFriendKeyChatIdsByUserId.removeValue(forKey: peerId)
        }
      }
    }.resume()
  }

  private func currentUserIdLocked() -> String? {
    normalizedUpper(getConfigValueLocked("userId"))
  }

  private func decryptPrivateKeyLocked() -> SecKey? {
    guard
      let pem = normalizedString(
        getConfigValueLocked("privateKeyPem") ?? getConfigValueLocked("privateKey"))
    else {
      print("[ChatEngine] decryptPrivateKeyLocked — no privateKeyPem in config")
      return nil
    }
    // Check TTL: clear cached key if it has expired to limit in-memory exposure.
    if let ts = cachedDecryptKeyTimestamp, Date().timeIntervalSince(ts) >= keyTTL {
      cachedDecryptPrivateKey = nil
      cachedDecryptPrivateKeyPem = nil
      cachedDecryptKeyTimestamp = nil
    }
    if cachedDecryptPrivateKeyPem == pem {
      if let cached = cachedDecryptPrivateKey {
        cachedDecryptKeyTimestamp = Date()
        return cached
      }
      if let ts = cachedDecryptKeyTimestamp, Date().timeIntervalSince(ts) < keyTTL {
        return nil
      }
    }
    let key = chatEnginePrivateKey(from: pem)
    if key == nil {
      print(
        "[ChatEngine] decryptPrivateKeyLocked — parsing FAILED, pem.count=\(pem.count) prefix=\(pem.prefix(50))"
      )
    }
    cachedDecryptPrivateKeyPem = pem
    cachedDecryptPrivateKey = key
    cachedDecryptKeyTimestamp = Date()
    // Hand the resolved key to the Rust core's unwrap seam. Pushed from this
    // queue rather than pulled from the core's worker thread — a worker that
    // blocked on this queue to read a key would be the `syncOnQueue`-from-another
    // -thread stall the core exists to retire. See `VibeCorePrivateKeyBox`.
    VibeCorePrivateKeyBox.shared.publish(key)
    return key
  }

  private func parseLongValue(_ value: Any?) -> Int64? {
    if let n = value as? Int64 { return n }
    if let n = value as? Int { return Int64(n) }
    if let n = value as? Double, n.isFinite { return Int64(n) }
    if let n = value as? Float, n.isFinite { return Int64(n) }
    if let n = value as? NSNumber { return n.int64Value }
    if let s = value as? String { return Int64(s) }
    return nil
  }

  private func parseDoubleValue(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
  }

  private func parseWaveformArray(_ value: Any?) -> [Double]? {
    let rawList: [Any]
    if let array = value as? [Any] {
      rawList = array
    } else if let nsArray = value as? NSArray {
      rawList = nsArray.compactMap { $0 }
    } else {
      return nil
    }
    let mapped = rawList.compactMap { parseDoubleValue($0) }.map { max(0.0, min(1.0, $0)) }
    return mapped.isEmpty ? nil : mapped
  }

  private func deriveFileNameFromURL(_ rawURL: String?) -> String? {
    guard let rawURL = normalizedString(rawURL), !rawURL.isEmpty else { return nil }
    let normalizedPath = rawURL.split(separator: "?", maxSplits: 1).first.map(String.init)
    let name = (normalizedPath ?? rawURL).split(separator: "/").last.map(String.init)
    guard let name else { return nil }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func isLikelyHybridCiphertext(_ raw: String?) -> Bool {
    guard let raw = normalizedString(raw) else { return false }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else {
      return false
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let json = object as? [String: Any]
    else {
      return false
    }
    return json["iv"] != nil && json["c"] != nil && json["k"] != nil
  }

  private func parseDecryptedMessagePayload(_ raw: String) -> [String: Any] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else {
      return ["text": raw]
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let json = object as? [String: Any]
    else {
      return ["text": raw]
    }
    var out: [String: Any] = [:]
    if let text = json["text"] { out["text"] = text }
    if let mediaUrl = json["mediaUrl"] { out["mediaUrl"] = mediaUrl }
    if let mediaKey = json["mediaKey"] { out["mediaKey"] = mediaKey }
    if let fileName = json["fileName"] { out["fileName"] = fileName }
    if let fileSize = json["fileSize"] { out["fileSize"] = fileSize }
    if let latitude = json["latitude"] { out["latitude"] = latitude }
    if let longitude = json["longitude"] { out["longitude"] = longitude }
    if let duration = json["duration"] { out["duration"] = duration }
    if let replyToId = json["replyToId"] { out["replyToId"] = replyToId }
    if let replyPreview = json["replyPreview"] ?? json["reply_preview"] {
      out["replyPreview"] = replyPreview
    }
    if let replyPreviewTitle =
      json["replyPreviewTitle"] ?? json["reply_preview_title"] ?? json["replyAuthorName"]
      ?? json["reply_author_name"]
    {
      out["replyPreviewTitle"] = replyPreviewTitle
    }
    if let replyPreviewText =
      json["replyPreviewText"] ?? json["reply_preview_text"] ?? json["replyText"]
      ?? json["reply_text"]
    {
      out["replyPreviewText"] = replyPreviewText
    }
    if let contact = json["contact"] { out["contact"] = contact }
    if let caption = json["caption"] { out["caption"] = caption }
    if let viewOnce = json["viewOnce"] { out["viewOnce"] = viewOnce }
    if let isEdited = json["isEdited"] { out["isEdited"] = isEdited }
    if let editedAt = json["editedAt"] { out["editedAt"] = editedAt }
    if let waveform = json["waveform"] { out["waveform"] = waveform }
    if let isVideoNote = json["isVideoNote"] { out["isVideoNote"] = isVideoNote }
    if let width = json["width"] { out["width"] = width }
    if let height = json["height"] { out["height"] = height }
    if let thumbnailBase64 = json["thumbnailBase64"] { out["thumbnailBase64"] = thumbnailBase64 }
    if let stickerId = json["stickerId"] { out["stickerId"] = stickerId }
    if let stickerPackId = json["stickerPackId"] ?? json["packId"] {
      out["stickerPackId"] = stickerPackId
    }
    if let stickerBundleFileName = json["stickerBundleFileName"] ?? json["bundleFileName"] {
      out["stickerBundleFileName"] = stickerBundleFileName
    }
    if let emoji = json["emoji"] { out["emoji"] = emoji }
    if out["text"] == nil {
      out["text"] = raw
    }
    return out
  }

  private func formatMessageTimeLabel(timestampMs: Int64) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0))
  }

  private func messageId(fromRow row: [String: Any]) -> String? {
    guard normalizedString(row["kind"]) == "message",
      let message = row["message"] as? [String: Any]
    else {
      return nil
    }
    return normalizedString(message["id"])
  }

  private func messageIsMe(fromRow row: [String: Any]) -> Bool {
    guard let message = row["message"] as? [String: Any] else { return false }
    return (message["isMe"] as? Bool) == true
  }

  private func messageTimestampMs(fromRow row: [String: Any]) -> Int64 {
    guard let message = row["message"] as? [String: Any] else { return 0 }
    return transcriptTimestampMs(message) ?? 0
  }

  /// The ordering timestamp of one message payload, or nil if it genuinely has none.
  ///
  /// # Why this is a function and not three `??` chains
  ///
  /// There were three, and they disagreed in two separate ways.
  ///
  /// **They read the keys in different orders.** The merge comparator took
  /// `timestampMs` first; the two history sorts took `timestamp` first. A row carrying
  /// both — and rows do, because `rowAdoptingSettleSlotTs` writes both and the builder
  /// re-stamps `timestampMs` over a server `timestamp` — sorts to one place under the
  /// merge and another under history. Same row, same device, two positions depending on
  /// which producer last touched it.
  ///
  /// **They fell through on the wrong condition.** `raw["timestamp"] ?? raw["timestampMs"]`
  /// picks the first key that is *present*, and only then tries to parse it. A present
  /// but unparseable `timestamp` — an ISO-8601 string, which `parseLongValue` rejects
  /// because `Int64("2026-08-06T17:27:03Z")` is nil — therefore ends the chain at nil
  /// while a perfectly good numeric `timestampMs` sits unread in the same dictionary.
  /// The caller then substituted `0` (sorts to the very top) or `nowMs()` (sorts to the
  /// very bottom, and gets persisted). This tries each key until one *parses*.
  func transcriptTimestampMs(_ message: [String: Any]) -> Int64? {
    for key in ["timestampMs", "timestamp_ms", "timestamp"] {
      if let value = message[key], !(value is NSNull), let parsed = parseLongValue(value) {
        return parsed
      }
    }
    return nil
  }

  /// How many rows this launch had to be given a locally-invented timestamp.
  private static var transcriptTimestampSynthesizedCount = 0

  /// Records a message that had no readable ordering timestamp, with the shape of what it
  /// did carry — never the values, which are content.
  private func noteSynthesizedTimestamp(chatId: String, messageId: String, raw: [String: Any]) {
    Self.transcriptTimestampSynthesizedCount &+= 1
    let present =
      ["timestampMs", "timestamp_ms", "timestamp"]
      .compactMap { key -> String? in
        guard let value = raw[key], !(value is NSNull) else { return nil }
        return "\(key):\(type(of: value))"
      }
      .joined(separator: ",")
    VibeLog.warning(
      "message has no readable timestamp — ordered by this device's clock",
      category: "order",
      metadata: [
        "chat": String(chatId.prefix(12)),
        "message": String(messageId.prefix(12)),
        "carried": present.isEmpty ? "none" : present,
        "totalThisLaunch": String(Self.transcriptTimestampSynthesizedCount),
      ])
  }

  /// A comparable summary of the order this device settled on for a chat.
  ///
  /// Two devices showing the same conversation in different orders is not visible to
  /// either of them, and it is not visible in any per-row log either — the divergence is
  /// only a divergence when you hold the two side by side. So this writes one line per
  /// chat that can be exported from both phones and diffed directly: the digest tells you
  /// *whether* they agree, and the tail tells you *where* they stopped agreeing.
  ///
  /// Ids and timestamps only. No message content leaves the device.
  func logTranscriptOrderFingerprint(chatId: String, rows: [[String: Any]], reason: String) {
    guard !rows.isEmpty else { return }
    var hasher = Hasher()
    var inversions = 0
    var previousTs: Int64 = .min
    for row in rows {
      let id = messageId(fromRow: row) ?? ""
      let ts = messageTimestampMs(fromRow: row)
      hasher.combine(id)
      hasher.combine(ts)
      // An inversion here means the rows were handed over out of order — a producer that
      // skipped the comparator, not a disagreement about the timestamps themselves.
      if ts < previousTs { inversions += 1 }
      previousTs = ts
    }
    // The last rows are where a burst of near-simultaneous sends lands, which is where
    // the ties are and therefore where two devices actually part company.
    let tail = rows.suffix(12).map { row in
      "\(messageTimestampMs(fromRow: row)):\(String((messageId(fromRow: row) ?? "?").prefix(8)))"
    }
    VibeLog.notice(
      "transcript order chat=\(String(chatId.prefix(12))) rows=\(rows.count) "
        + "digest=\(String(format: "%016llx", UInt64(bitPattern: Int64(hasher.finalize()))))"
        + (inversions > 0 ? " INVERSIONS=\(inversions)" : ""),
      category: "order",
      metadata: [
        "chat": String(chatId.prefix(12)),
        "rows": String(rows.count),
        "reason": reason,
        "inversions": String(inversions),
        "tail": tail.joined(separator: " "),
      ])
  }

  /// The id a raw server message will be keyed under once built, for tie-breaking before
  /// it is built. Mirrors `buildHistoryRowsLocked`'s `preferredId` exactly — including the
  /// Saved Messages preference for `original_message_id` — because a tie-break that uses a
  /// different id than the row ends up carrying is a tie-break on a value nothing else
  /// agrees with.
  func rawMessageIdForOrdering(_ raw: [String: Any], chatId: String) -> String? {
    let preferred =
      chatId == "saved_messages"
      ? raw["original_message_id"] ?? raw["originalMessageId"] ?? raw["id"] ?? raw["message_id"]
      : raw["id"] ?? raw["message_id"]
    return normalizedString(preferred)
  }

  /// The total order of the transcript: ascending timestamp, ties broken by message id.
  ///
  /// The tie-break is not decoration. `Array.sorted(by:)` is explicitly documented as
  /// **not guaranteed to be stable**, so a comparator that returns false in both
  /// directions for two rows leaves their relative order up to the algorithm and the
  /// input permutation — and the input permutation is exactly the thing that differs
  /// between two devices looking at the same conversation. Voice notes fired off in a
  /// burst are the case that collides, and the case the reader noticed.
  ///
  /// This is the same comparator the Rust core sorts with (`core/vibe_core/src/order.rs`,
  /// `(ts_ms ASC, message_id ASC)`), deliberately: two producers that disagree about
  /// order produce a transcript that reorders itself depending on which one painted it.
  func transcriptOrderPrecedes(
    lhsTs: Int64?, lhsId: String?, rhsTs: Int64?, rhsId: String?
  ) -> Bool {
    let lt = lhsTs ?? 0
    let rt = rhsTs ?? 0
    if lt != rt { return lt < rt }
    return (lhsId ?? "") < (rhsId ?? "")
  }

  private func bubbleShapePayload(
    isMe: Bool,
    isSequenceStart: Bool,
    isSequenceEnd: Bool
  ) -> [String: Any] {
    // Telegram-style radii: full 18 on open corners; consecutive "merged" corners
    // use ~12 (was 5–8, which read as a sharp ~6pt notch next to the big round).
    let full: CGFloat = 18
    let merged: CGFloat = 12
    var shape: [String: Any] = [
      "isMe": isMe,
      "showTail": isSequenceEnd,
      "borderTopLeftRadius": full,
      "borderTopRightRadius": full,
      "borderBottomLeftRadius": full,
      "borderBottomRightRadius": full,
    ]

    if isMe {
      // Keep the outgoing top-right corner full in every sequence position. The
      // optimistic/send-morph row uses the same contract, so settling cannot shrink
      // this corner. Only a bubble with another outgoing bubble below it tightens its
      // bottom-right corner; therefore bottom-right is never larger than top-right.
      shape["borderTopRightRadius"] = full
      shape["borderBottomRightRadius"] = isSequenceEnd ? full : merged
    } else {
      shape["borderTopLeftRadius"] = isSequenceStart ? full : merged
      shape["borderBottomLeftRadius"] = isSequenceEnd ? full : merged
    }

    return shape
  }

  private func rowsByApplyingBubbleSequenceShapes(_ rows: [[String: Any]]) -> [[String: Any]] {
    var patchedRows = rows
    let messageIndices = rows.indices.filter { messageId(fromRow: rows[$0]) != nil }
    guard !messageIndices.isEmpty else { return rows }

    for (offset, rowIndex) in messageIndices.enumerated() {
      guard var message = patchedRows[rowIndex]["message"] as? [String: Any] else { continue }
      let isMe = messageIsMe(fromRow: rows[rowIndex])
      let previousIsSameSender: Bool = {
        guard offset > 0 else { return false }
        return messageIsMe(fromRow: rows[messageIndices[offset - 1]]) == isMe
      }()
      let nextIsSameSender: Bool = {
        guard offset + 1 < messageIndices.count else { return false }
        return messageIsMe(fromRow: rows[messageIndices[offset + 1]]) == isMe
      }()
      message["bubbleShape"] = bubbleShapePayload(
        isMe: isMe,
        isSequenceStart: !previousIsSameSender,
        isSequenceEnd: !nextIsSameSender
      )
      patchedRows[rowIndex]["message"] = message
    }

    return patchedRows
  }

  /// `mergedChatRowsLocked` PICKS the live row over the history row for any id present in
  /// both — it does not merge them. That is fine only while every producer of a live row is
  /// as rich as the history builder, and they have not been: the socket path resolved agent
  /// identity from the top-level payload only, while `buildHistoryRowsLocked` also reads
  /// `metadata`. The poor copy then shadowed the rich one and 48 agent rows in a plain DM
  /// silently rendered as text, changing `type` and every cached height with it.
  ///
  /// The builders agree now, so this should never fire. It stays as the failsafe for the
  /// other live-row producers (stream frames, bridge ingest, synthetic rows), because the
  /// failure is invisible — no error, just a transcript that quietly downgrades and a list
  /// that walks. If `[AgentDowngrade]` ever appears, a producer has drifted again.
  private func liveRowPreservingAgentIdentityLocked(
    live: [String: Any], history: [String: Any], messageId: String
  ) -> [String: Any] {
    guard var liveMessage = live["message"] as? [String: Any],
      let historyMessage = history["message"] as? [String: Any],
      (historyMessage["isAgentMessage"] as? Bool) == true,
      (liveMessage["isAgentMessage"] as? Bool) != true
    else { return live }
    for key in [
      "isAgentMessage", "agentName", "agentId", "agentUserId", "agentUsername",
      "plainContent", "text", "type",
    ] where liveMessage[key] == nil || liveMessage[key] is NSNull {
      if let value = historyMessage[key] { liveMessage[key] = value }
    }
    // `isAgentMessage` is the flag whose absence defines this downgrade, so set it even
    // when the live row carries an explicit `false`.
    liveMessage["isAgentMessage"] = true
    NSLog(
      "[AgentDowngrade] live row lost agent identity id=%@ — restored from history",
      String(messageId.suffix(12)))
    var restored = live
    restored["message"] = liveMessage
    return restored
  }

  private func mergedChatRowsLocked(chatId: String) -> [[String: Any]] {
    let historyRows = historyRowsByChat[chatId] ?? []
    let liveRows = liveMessageRowsByChat[chatId] ?? [:]
    let deletedIds = deletedMessageIdsByChat[chatId] ?? []
    guard !historyRows.isEmpty || !liveRows.isEmpty else { return [] }

    var mergedById: [String: [String: Any]] = [:]
    var rowsWithoutIds: [[String: Any]] = []
    for row in historyRows {
      guard let messageId = messageId(fromRow: row) else {
        rowsWithoutIds.append(row)
        continue
      }
      guard !deletedIds.contains(messageId) else { continue }
      let chosen: [String: Any]
      if let live = liveRows[messageId] {
        chosen = liveRowPreservingAgentIdentityLocked(
          live: live, history: row, messageId: messageId)
      } else {
        chosen = row
      }
      mergedById[messageId] = rowAdoptingSettleSlotTs(chosen, messageId: messageId)
    }

    for (messageId, row) in liveRows {
      guard !deletedIds.contains(messageId), mergedById[messageId] == nil else { continue }
      mergedById[messageId] = rowAdoptingSettleSlotTs(row, messageId: messageId)
    }

    // Mirrored-prompt dedup: a session transcript records the user's OWN prompt as a
    // user turn, and the bridge ingest re-emits it as a `bridge-…` user row — while
    // the phone already renders the real sent message (server row, its own UUID).
    // Same text, two ids → duplicate "Continue" bubbles. Drop the mirrored copy
    // whenever a non-bridge own-user row with identical text exists nearby in time.
    // (When a History session is viewed in isolation the server rows are absent from
    // this merge, so the mirrored user rows survive there — as they must.)
    let ownUserTexts: [(text: String, ts: Int64)] = mergedById.compactMap { id, row in
      guard !id.hasPrefix("bridge-"), !id.hasPrefix("stream-"),
        messageIsMe(fromRow: row),
        let message = row["message"] as? [String: Any],
        let text = normalizedString(message["text"])?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
      else { return nil }
      return (text, messageTimestampMs(fromRow: row))
    }
    if !ownUserTexts.isEmpty {
      let mirrorDedupWindowMs = Self.bridgeMirrorDedupWindowMs
      for (id, row) in mergedById {
        guard id.hasPrefix("bridge-"), messageIsMe(fromRow: row),
          let message = row["message"] as? [String: Any],
          let rawText = normalizedString(message["text"])
        else { continue }
        // Comparable form strips the daemon's attachment preamble too, so an
        // image-carrying prompt still matches its own sent row.
        let text = Self.bridgeMirrorComparableText(rawText)
        guard !text.isEmpty else { continue }
        let ts = messageTimestampMs(fromRow: row)
        if ownUserTexts.contains(where: { $0.text == text && abs($0.ts - ts) <= mirrorDedupWindowMs }) {
          mergedById.removeValue(forKey: id)
        }
      }
    }

    // The final bridge result is persisted as the canonical server message while the
    // local session watcher mirrors that same assistant turn as a `bridge-…` row.
    // Their ids differ, so id-based merging alone renders two identical responses.
    // Keep the persisted row (it carries delivery state/runtime metadata) and suppress
    // only an exact-text, same-agent transcript mirror nearby in time. A History-only
    // view has no persisted twin, so its bridge rows remain untouched.
    let persistedAgentResponses: [(text: String, from: String, ts: Int64)] =
      mergedById.compactMap { id, row in
        guard !id.hasPrefix("bridge-"), !id.hasPrefix("stream-"),
          let message = row["message"] as? [String: Any],
          (message["isAgentMessage"] as? Bool) == true,
          let text = normalizedString(message["plainContent"] ?? message["text"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty
        else { return nil }
        return (
          text,
          normalizedUpper(message["agentUserId"] ?? message["fromId"]) ?? "",
          messageTimestampMs(fromRow: row)
        )
      }
    if !persistedAgentResponses.isEmpty {
      let mirrorWindowMs: Int64 = 5 * 60 * 1000
      for (id, row) in mergedById where id.hasPrefix("bridge-") {
        guard let message = row["message"] as? [String: Any],
          (message["isAgentMessage"] as? Bool) == true,
          let text = normalizedString(message["plainContent"] ?? message["text"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty
        else { continue }
        let from = normalizedUpper(message["agentUserId"] ?? message["fromId"]) ?? ""
        let ts = messageTimestampMs(fromRow: row)
        if persistedAgentResponses.contains(where: {
          $0.text == text && ($0.from.isEmpty || from.isEmpty || $0.from == from)
            && abs($0.ts - ts) <= mirrorWindowMs
        }) {
          mergedById.removeValue(forKey: id)
        }
      }
    }

    // Agent DM hygiene (Grok desktop + bridge restart):
    // 1) Drop fully empty agent shells (settled OR streaming with no body/nodes) —
    //    blank bubbles corrupt height layout and overlap neighbors.
    // 2) Drop settled stream- rows when a finished bridge- agent card exists for the
    //    same agent — the classic empty "Worked" duplicate after reconnect.
    // 3) Drop synthetic running-mirror hosts that are empty (or settled under a card).
    let hasFinishedAgentCard = mergedById.contains { id, row in
      guard id.hasPrefix("bridge-") else { return false }
      guard let message = row["message"] as? [String: Any] else { return false }
      guard (message["isAgentMessage"] as? Bool) == true else { return false }
      let meta = message["metadata"] as? [String: Any]
      let streaming =
        (message["isStreaming"] as? Bool) == true || (meta?["isStreaming"] as? Bool) == true
      return !streaming
    }
    for (id, row) in mergedById {
      guard let message = row["message"] as? [String: Any] else { continue }
      let isAgent = (message["isAgentMessage"] as? Bool) == true
      guard isAgent else { continue }
      let meta = message["metadata"] as? [String: Any]
      let streaming =
        (message["isStreaming"] as? Bool) == true || (meta?["isStreaming"] as? Bool) == true
      let text = (
        normalizedString(message["plainContent"])
          ?? normalizedString(message["text"])
          ?? ""
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      let nodes =
        (meta?["progressNodes"] as? [[String: Any]])
        ?? (message["progressNodes"] as? [[String: Any]])
        ?? []
      let hasNodes = !nodes.isEmpty
      let onlyPlaceholderThinking = hasNodes && nodes.allSatisfy { node in
        let kind = (normalizedString(node["kind"] ?? node["itemType"]) ?? "").lowercased()
        let label = (normalizedString(node["label"] ?? node["title"]) ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let detail = (
          normalizedString(node["detail"] ?? node["messageContent"] ?? node["messagePreview"]) ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == "thinking" || label == "thinking" || label == "thinking..." else {
          return false
        }
        // Tokens-only / bare Thinking with no detail is still a placeholder shell.
        return detail.isEmpty
      }
      // Empty agent shell — no body, no real steps (settled or streaming placeholder).
      // Streaming with only a bare Thinking node is held out of the list (header shows
      // Thinking…); leaving it as a row paints a zero/44pt empty bubble that overlaps.
      if text.isEmpty, (!hasNodes || onlyPlaceholderThinking) {
        mergedById.removeValue(forKey: id)
        VibeDebugLog.log(
          "[EmptyTrace] dropEmptyAgentShell id=%@ chat=%@ streaming=%@ nodes=%d placeholder=%@",
          String(id.suffix(20)), String(chatId.suffix(12)),
          streaming ? "Y" : "N", nodes.count, onlyPlaceholderThinking ? "Y" : "N")
        continue
      }
      // Stale stream row after finished session card arrived (bridge restart recovery).
      // Also drop when still marked streaming if a finished bridge- card already owns
      // the turn — otherwise logs show dual apply of the same prose (stream + bridge).
      if id.hasPrefix("stream-"), hasFinishedAgentCard {
        mergedById.removeValue(forKey: id)
        VibeDebugLog.log(
          "[EmptyTrace] dropStaleStreamRow id=%@ chat=%@ textLen=%d nodes=%d streaming=%@",
          String(id.suffix(20)), String(chatId.suffix(12)), text.count, nodes.count,
          streaming ? "Y" : "N")
        continue
      }
      // Synthetic running-mirror hosts that settled empty under a real finished card.
      if id.contains("running-mirror"), text.isEmpty, hasFinishedAgentCard || !streaming {
        mergedById.removeValue(forKey: id)
        continue
      }
    }

    // Dead-run settle: a persisted agent/team row that still claims to be streaming but
    // has no live row feeding it and hasn't been touched in minutes is an orphan — its
    // run ended without a terminal frame (CLI crash, or the finalizing monitor was reset
    // by a server redeploy). Left alone it re-renders as a live shimmering team cell on
    // every history load. Coerce a terminal display copy so it settles ("stopped"
    // workers, no shimmer). A genuinely live run keeps a live row (preferred at :8660),
    // so it never enters here; the staleness gate protects the cold-start-mid-run window
    // (the row re-arms its live row on the next frame and that live row wins).
    // A history-only row settles quickly (3 min). A row ALSO present in the live store
    // (e.g. a streaming snapshot resurrected from the volatile bridge-rows disk cache, or
    // a run the monitor never finalized) gets a long grace — a genuinely live turn keeps a
    // fast-refreshing live row, but no real turn streams for an hour, so an hour-stale live
    // row is an orphan. Flip the plaintext isStreaming so the cell settles; the client
    // terminalizes the (decrypted, E2E) worker rows once the message is no longer streaming.
    let staleStreamingIds: [String] = mergedById.compactMap { id, row in
      let minStaleMs: Int64 = liveRows[id] == nil ? (3 * 60 * 1000) : (60 * 60 * 1000)
      return isStaleStreamingAgentRowLocked(row, minStaleMs: minStaleMs) ? id : nil
    }
    for id in staleStreamingIds {
      guard let row = mergedById[id] else { continue }
      mergedById[id] = terminalizedStaleAgentRowLocked(row)
      NSLog(
        "[TeamSettle] merge-coerce chat=%@ id=%@ inLiveStore=%@",
        String(chatId.suffix(12)), String(id.suffix(12)),
        liveRows[id] != nil ? "Y" : "N")
    }

    var mergedRows = Array(mergedById.values)
    mergedRows.sort { lhs, rhs in
      transcriptOrderPrecedes(
        lhsTs: messageTimestampMs(fromRow: lhs), lhsId: messageId(fromRow: lhs),
        rhsTs: messageTimestampMs(fromRow: rhs), rhsId: messageId(fromRow: rhs))
    }
    mergedRows.insert(contentsOf: rowsWithoutIds, at: 0)
    return rowsByApplyingBubbleSequenceShapes(mergedRows)
  }

  private func ingestHistoryRowsLocked(
    chatId: String,
    remoteRows: [[String: Any]]
  ) -> (rows: [[String: Any]], delta: ChatIngestDelta) {
    let existingRows = historyRowsByChat[chatId] ?? []
    let deletedIds = deletedMessageIdsByChat[chatId] ?? []
    guard !existingRows.isEmpty || !remoteRows.isEmpty else {
      return (
        [],
        ChatIngestDelta(insertedIds: [], updatedIds: [], deletedIds: []))
    }

    var mergedById: [String: [String: Any]] = [:]
    var rowsWithoutIds: [[String: Any]] = []
    for row in existingRows {
      guard let messageId = messageId(fromRow: row) else {
        rowsWithoutIds.append(row)
        continue
      }
      guard !deletedIds.contains(messageId) else { continue }
      mergedById[messageId] = rowAdoptingSettleSlotTs(row, messageId: messageId)
    }

    for row in remoteRows {
      guard let messageId = messageId(fromRow: row) else {
        rowsWithoutIds.append(row)
        continue
      }
      guard !deletedIds.contains(messageId) else { continue }
      var mergedRow = row
      if let existing = mergedById[messageId] {
        if mergedRow["message"] is [String: Any] || existing["message"] is [String: Any] {
          var mergedMessage = mergedRow["message"] as? [String: Any] ?? [:]
          let existingMessage = existing["message"] as? [String: Any] ?? [:]
          for (key, value) in existingMessage
          where mergedMessage[key] == nil || mergedMessage[key] is NSNull {
            // Transient liveness keys are OFF-by-absence: a settled remote copy omits
            // them, and carrying a stale true/value forward would resurrect a dead
            // live state (stuck shimmer — the team-run orphan bug class).
            if Self.ingestTransientMessageKeys.contains(key) { continue }
            if key == "metadata", var carriedMeta = value as? [String: Any] {
              carriedMeta.removeValue(forKey: "isStreaming")
              carriedMeta.removeValue(forKey: "is_streaming")
              mergedMessage[key] = carriedMeta
              continue
            }
            mergedMessage[key] = value
          }
          // Prefer local agentTurnStructureVersion >= 2 full progressNodes over a
          // thinner server copy so cold-open keeps intro→note→summary (never clobber).
          if let existingMeta = existingMessage["metadata"] as? [String: Any] {
            let localVersion =
              (existingMeta["agentTurnStructureVersion"] as? Int)
              ?? (existingMeta["agentTurnStructureVersion"] as? NSNumber)?.intValue
              ?? 0
            if localVersion >= 2,
              let localNodes = existingMeta["progressNodes"] as? [[String: Any]],
              !localNodes.isEmpty
            {
              var meta = mergedMessage["metadata"] as? [String: Any] ?? [:]
              let remoteNodes = (meta["progressNodes"] as? [[String: Any]]) ?? []
              if remoteNodes.count < localNodes.count || meta["agentTurnStructureVersion"] == nil {
                meta["progressNodes"] = localNodes
                meta["agentTurnStructureVersion"] = localVersion
                mergedMessage["metadata"] = meta
              }
            }
          }
          mergedRow["message"] = mergedMessage
        }
        for (key, value) in existing
        where key != "message" && (mergedRow[key] == nil || mergedRow[key] is NSNull) {
          mergedRow[key] = value
        }
      }
      mergedById[messageId] = rowAdoptingSettleSlotTs(mergedRow, messageId: messageId)
    }

    var mergedRows = Array(mergedById.values)
    mergedRows.sort { lhs, rhs in
      transcriptOrderPrecedes(
        lhsTs: messageTimestampMs(fromRow: lhs), lhsId: messageId(fromRow: lhs),
        rhsTs: messageTimestampMs(fromRow: rhs), rhsId: messageId(fromRow: rhs))
    }
    mergedRows.insert(contentsOf: rowsWithoutIds, at: 0)
    let rows = rowsByApplyingBubbleSequenceShapes(mergedRows)
    logTranscriptOrderFingerprint(chatId: chatId, rows: rows, reason: "ingest")

    var previousRowsById: [String: [String: Any]] = [:]
    for row in existingRows {
      guard let messageId = messageId(fromRow: row) else { continue }
      previousRowsById[messageId] = row
    }
    var rowsById: [String: [String: Any]] = [:]
    for row in rows {
      guard let messageId = messageId(fromRow: row) else { continue }
      rowsById[messageId] = row
    }

    let previousIds = Set(previousRowsById.keys)
    let ids = Set(rowsById.keys)
    let insertedIds = ids.subtracting(previousIds).sorted()
    let deltaDeletedIds = previousIds.subtracting(ids).sorted()
    let updatedIds = ids.intersection(previousIds).filter { messageId in
      guard let row = rowsById[messageId], let previousRow = previousRowsById[messageId] else {
        return false
      }
      return !(row as NSDictionary).isEqual(to: previousRow)
    }.sorted()
    return (
      rows,
      ChatIngestDelta(
        insertedIds: insertedIds,
        updatedIds: updatedIds,
        deletedIds: deltaDeletedIds))
  }

  // v2: subsumed by ingestHistoryRowsLocked
  private func mergedStoredHistoryRowsLocked(
    chatId: String,
    remoteRows: [[String: Any]]
  ) -> [[String: Any]] {
    ingestHistoryRowsLocked(chatId: chatId, remoteRows: remoteRows).rows
  }

  /// Durability must NOT depend on network-load state.
  ///
  /// This used to be gated on `historyFullyLoadedChats`, which created a bootstrap
  /// dependency: writing required the flag, and for a chat with nothing stored yet
  /// that flag could only be set by a SUCCESSFUL network history load. So a dormant
  /// or very old chat whose history request never completes with rows (server returns
  /// an empty page, the request errors, offline) was NEVER written to SQLite — every
  /// cold launch then found nothing and painted an empty transcript, permanently,
  /// because the same condition repeats on every run. Healthy chats had crossed that
  /// bootstrap once and self-sustained via restore -> flag -> write.
  ///
  /// No permission check is needed, because the store is MONOTONE:
  /// `persistHistoryRowsToStoreLocked` only upserts validated rows (it filters
  /// transient `stream-`/`lan-` ids, applies local tombstones, and requires a userId).
  /// Rows leave the store only through explicit deleteMessages / pruneChat / deleteChat.
  /// A partial tail upserted over a fuller stored transcript can therefore only grow
  /// it — it can never truncate one.
  private func storeMergedChatHistoryIfLoadedLocked(chatId: String) {
    // Drop a merge that carries nothing persistable (a streaming-only tick), so token
    // streaming never churns the store.
    let rows = mergedChatRowsLocked(chatId: chatId).filter { !isTransientStreamRow($0) }
    guard !rows.isEmpty else { return }
    storeCachedHistoryRowsLocked(chatId: chatId, rows: rows)
  }

  @discardableResult
  private func upsertLiveMessageRowLocked(
    chatId: String, messageId: String, row: [String: Any]
  ) -> Bool {
    let wasPresent =
      liveMessageRowsByChat[chatId]?[messageId] != nil
      || (historyRowsByChat[chatId] ?? []).contains {
        self.messageId(fromRow: $0) == messageId
      }
    var perChat = liveMessageRowsByChat[chatId] ?? [:]
    perChat[messageId] = row
    liveMessageRowsByChat[chatId] = perChat
    if var deleted = deletedMessageIdsByChat[chatId] {
      deleted.remove(messageId)
      if deleted.isEmpty {
        deletedMessageIdsByChat.removeValue(forKey: chatId)
      } else {
        deletedMessageIdsByChat[chatId] = deleted
      }
    }
    storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
    return !wasPresent
  }

  @discardableResult
  private func mutateLiveMessagePayloadLocked(
    chatId: String,
    messageId: String,
    mutate: (inout [String: Any]) -> Void
  ) -> Bool {
    guard var perChat = liveMessageRowsByChat[chatId],
      var row = perChat[messageId],
      var message = row["message"] as? [String: Any]
    else {
      return false
    }
    let previousMessage = message
    mutate(&message)
    guard !(message as NSDictionary).isEqual(to: previousMessage) else { return false }
    row["message"] = message
    perChat[messageId] = row
    liveMessageRowsByChat[chatId] = perChat
    return true
  }

  /// Make every liveness field agree on a terminal state. Previously the top-level
  /// `isStreaming` flag was cleared while `agentRuntime.status` and team worker rows
  /// remained `running`, so the same card kept its spinners after the CLI had exited.
  @discardableResult
  private func settleLiveBridgeMessageLocked(
    chatId: String,
    messageId: String,
    terminalStatus: String
  ) -> Bool {
    guard var perChat = liveMessageRowsByChat[chatId],
      var row = perChat[messageId],
      var message = row["message"] as? [String: Any]
    else { return false }

    var metadata = (message["metadata"] as? [String: Any]) ?? [:]
    var runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
    let activeStates = Set(["running", "starting", "pending", "active", "streaming"])
    let previousRuntimeStatus = (normalizedString(runtime["status"]) ?? "").lowercased()
    let wasLive =
      (message["isStreaming"] as? Bool) == true
      || (metadata["isStreaming"] as? Bool) == true
      || activeStates.contains(previousRuntimeStatus)
      || ((runtime["teamWorkersStatus"] as? [[String: Any]]) ?? []).contains { worker in
        activeStates.contains((normalizedString(worker["status"]) ?? "").lowercased())
      }
    guard wasLive else { return false }

    func terminalized(_ entries: [[String: Any]]) -> [[String: Any]] {
      entries.map { entry in
        var next = entry
        let state = (normalizedString(next["status"]) ?? "").lowercased()
        if activeStates.contains(state) {
          next["status"] = terminalStatus
        }
        return next
      }
    }

    message["isStreaming"] = false
    metadata["isStreaming"] = false
    runtime["status"] = terminalStatus
    runtime["controls"] = ["canCancel": false, "canRevert": false]

    let workerRows =
      (runtime["teamWorkersStatus"] as? [[String: Any]])
      ?? (metadata["teamWorkersStatus"] as? [[String: Any]])
      ?? []
    if !workerRows.isEmpty {
      let settledWorkers = terminalized(workerRows)
      runtime["teamWorkersStatus"] = settledWorkers
      metadata["teamWorkersStatus"] = settledWorkers
    }
    if let nodes = metadata["progressNodes"] as? [[String: Any]], !nodes.isEmpty {
      metadata["progressNodes"] = terminalized(nodes)
    }
    metadata["agentRuntime"] = runtime
    message["metadata"] = metadata
    row["message"] = message
    perChat[messageId] = row
    liveMessageRowsByChat[chatId] = perChat
    return true
  }

  /// True when `row` is an agent/team turn that still claims to be streaming yet is older
  /// than `minStaleMs` — i.e. a dead run that never got a terminal frame. Detection must
  /// survive the E2E case: on persisted/cached rows the runtime (teamWorkersStatus/status)
  /// is encrypted into `agentRuntimeEnc`, so the only streaming signal ChatEngine can read
  /// is the plaintext `isStreaming` flag, and `isAgentMessage` may be absent — detect via
  /// any agent marker, the encrypted blob included.
  private func isStaleStreamingAgentRowLocked(_ row: [String: Any], minStaleMs: Int64) -> Bool {
    guard let message = row["message"] as? [String: Any] else { return false }
    let meta = message["metadata"] as? [String: Any]
    let isAgentRow =
      (message["isAgentMessage"] as? Bool) == true
      || meta?["agentRuntime"] != nil || meta?["agent_runtime"] != nil
      || message["agentRuntime"] != nil || message["agent_runtime"] != nil
      || meta?["agentRuntimeEnc"] != nil || meta?["agent_runtime_enc"] != nil
      || message["agentRuntimeEnc"] != nil || message["agent_runtime_enc"] != nil
      || meta?["teamWorkersStatus"] != nil || meta?["team_workers_status"] != nil
      || (meta?["progressNodes"] as? [[String: Any]])?.isEmpty == false
      || (message["progressNodes"] as? [[String: Any]])?.isEmpty == false
      || normalizedString(message["agentUserId"] ?? message["agent_user_id"]) != nil
      || normalizedString(message["agentUsername"] ?? message["agent_username"]) != nil
    guard isAgentRow else { return false }
    let active = Set(["running", "starting", "pending", "queued", "active", "streaming", "waiting"])
    let runtime = meta?["agentRuntime"] as? [String: Any]
    let streaming =
      (message["isStreaming"] as? Bool) == true
      || (meta?["isStreaming"] as? Bool) == true
      || active.contains((normalizedString(runtime?["status"]) ?? "").lowercased())
      || ((runtime?["teamWorkersStatus"] as? [[String: Any]]) ?? []).contains { worker in
        active.contains((normalizedString(worker["status"]) ?? "").lowercased())
      }
    guard streaming else { return false }
    let ts = messageTimestampMs(fromRow: row)
    return ts == 0 || Int64(nowMs()) - ts > minStaleMs
  }

  /// A dead run that never received a terminal frame — the CLI crashed, or the server
  /// monitor that would have finalized it was reset by a redeploy — stays `isStreaming`
  /// forever in its PERSISTED row. `settleLiveBridgeMessageLocked` only fixes the live
  /// store, so on every history load such an orphan re-renders as a live, shimmering
  /// team cell (worker rows stuck "working…"). This returns a TERMINAL display copy of
  /// the row: every liveness field agrees on "stopped" so the cell settles. The stored
  /// source row is never mutated — if the run ever re-arms a live row, that live row is
  /// preferred in the merge and wins.
  private func terminalizedStaleAgentRowLocked(_ row: [String: Any]) -> [String: Any] {
    guard var message = row["message"] as? [String: Any] else { return row }
    let activeStates = Set(["running", "starting", "pending", "queued", "active", "streaming", "waiting"])
    func terminalized(_ entries: [[String: Any]]) -> [[String: Any]] {
      entries.map { entry in
        var next = entry
        let state = (normalizedString(next["status"]) ?? "").lowercased()
        if activeStates.contains(state) { next["status"] = "stopped" }
        return next
      }
    }
    var metadata = (message["metadata"] as? [String: Any]) ?? [:]
    var runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
    message["isStreaming"] = false
    metadata["isStreaming"] = false
    runtime["status"] = "stopped"
    runtime["controls"] = ["canCancel": false, "canRevert": false]
    if let workers = runtime["teamWorkersStatus"] as? [[String: Any]], !workers.isEmpty {
      runtime["teamWorkersStatus"] = terminalized(workers)
    }
    if let workers = metadata["teamWorkersStatus"] as? [[String: Any]], !workers.isEmpty {
      metadata["teamWorkersStatus"] = terminalized(workers)
    }
    if let nodes = metadata["progressNodes"] as? [[String: Any]], !nodes.isEmpty {
      metadata["progressNodes"] = terminalized(nodes)
    }
    metadata["agentRuntime"] = runtime
    message["metadata"] = metadata
    var out = row
    out["message"] = message
    return out
  }

  /// Tombstone a task so a late frame can never mint a second live row for it.
  private func markAgentTaskRetiredLocked(chatId: String, taskId: String) {
    let id = taskId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty, !id.isEmpty else { return }
    let now = Int64(nowMs())
    var perChat = retiredAgentTaskIdsByChatId[chatId] ?? [:]
    perChat[id] = now
    // Bounded: drop entries past the TTL, then cap the newest 64 (a busy group run tops
    // out at a handful of concurrent tasks).
    perChat = perChat.filter { now - $0.value < Self.retiredAgentTaskTtlMs }
    if perChat.count > 64 {
      let newest = perChat.sorted { $0.value > $1.value }.prefix(64)
      perChat = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }
    retiredAgentTaskIdsByChatId[chatId] = perChat
  }

  private func isAgentTaskRetiredLocked(chatId: String, taskId: String) -> Bool {
    guard let retiredAt = retiredAgentTaskIdsByChatId[chatId]?[taskId] else { return false }
    return Int64(nowMs()) - retiredAt < Self.retiredAgentTaskTtlMs
  }

  private func removeBridgeTaskTrackingLocked(chatId: String, taskId: String) {
    let taskKey = "\(chatId):\(taskId)"
    markAgentTaskRetiredLocked(chatId: chatId, taskId: taskId)
    cloudProgressAtMsByTask.removeValue(forKey: taskKey)
    if var taskRows = liveStreamTaskRowIdByChatId[chatId] {
      taskRows.removeValue(forKey: taskId)
      if taskRows.isEmpty {
        liveStreamTaskRowIdByChatId.removeValue(forKey: chatId)
      } else {
        liveStreamTaskRowIdByChatId[chatId] = taskRows
      }
    }
    let lanKeys = lanProgressLinesByTask.keys.filter { $0.contains(":\(chatId):\(taskId)") }
    for key in lanKeys {
      lanProgressLinesByTask.removeValue(forKey: key)
      lanProgressSeqByTask.removeValue(forKey: key)
    }
  }

  private func settleAgentBridgeTaskLocked(
    chatId: String,
    taskId: String,
    terminalStatus: String,
    reason: String
  ) {
    let matchingIds = (liveMessageRowsByChat[chatId] ?? [:]).compactMap {
      messageId, row -> String? in
      guard let message = row["message"] as? [String: Any],
        let metadata = message["metadata"] as? [String: Any]
      else { return nil }
      let runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
      let rowTaskId = normalizedString(
        runtime["taskId"] ?? runtime["task_id"]
          ?? metadata["agentTaskId"] ?? metadata["agent_task_id"])
      return rowTaskId == taskId ? messageId : nil
    }
    var changedIds: [String] = []
    for messageId in matchingIds {
      if settleLiveBridgeMessageLocked(
        chatId: chatId,
        messageId: messageId,
        terminalStatus: terminalStatus
      ) {
        changedIds.append(messageId)
      }
    }
    removeBridgeTaskTrackingLocked(chatId: chatId, taskId: taskId)
    guard !changedIds.isEmpty else { return }
    agentTurnRunningAtMsByChatId.removeValue(forKey: chatId)
    clearAgentProgressLocked(chatId: chatId, status: terminalStatus, reason: reason)
    storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
    postChangeLocked(
      reason: "chatRowsReloaded",
      userInfo: ["chatId": chatId, "state": statusSnapshotLocked()]
    )
    postChatDeltaLocked(
      chatId: chatId, inserted: [], updated: changedIds, deleted: [], source: "bridgeSettle")
  }

  private func setLiveMessageStatusLocked(chatId: String, messageId: String, status: String) -> Bool {
    mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
      message["status"] = status
    }
  }

  // MARK: - Bridge tail-cell liveness (mid-run collapse fix)

  /// Latch a bridge session as terminally settled so its tail cell stops being widened to
  /// "still streaming" by the chat-wide run grace. `contentSig` is the tail item's content
  /// signature at settle time (uid:text:nodes) — used to distinguish a genuine resume (new
  /// content) from a stale `running=true` re-push of the same content.
  private func bridgeMarkSessionSettledLocked(chatId: String, sessionId: String, contentSig: String) {
    guard !sessionId.isEmpty else { return }
    var perChat = bridgeSettledSessionSigByChatId[chatId] ?? [:]
    perChat[sessionId] = contentSig
    // Bound growth across a long-lived chat (new-task-per-message mints many session ids):
    // once it gets large, drop everything but the session we just settled.
    if perChat.count > 24 { perChat = [sessionId: contentSig] }
    bridgeSettledSessionSigByChatId[chatId] = perChat
  }

  /// Drop a session's terminal latch on genuine proof-of-life (running item/frame, resume).
  private func bridgeClearSessionSettledLocked(chatId: String, sessionId: String) {
    guard var perChat = bridgeSettledSessionSigByChatId[chatId], perChat[sessionId] != nil else {
      return
    }
    perChat.removeValue(forKey: sessionId)
    if perChat.isEmpty {
      bridgeSettledSessionSigByChatId.removeValue(forKey: chatId)
    } else {
      bridgeSettledSessionSigByChatId[chatId] = perChat
    }
  }

  private func bridgeSessionIsSettledLocked(chatId: String, sessionId: String) -> Bool {
    bridgeSettledSessionSigByChatId[chatId]?[sessionId] != nil
  }

  /// Is this bridge session's tail turn still live right now? Used to keep the tail agent
  /// cell in its streaming state through a text→tool/MCP gap where the per-item `running`
  /// flag momentarily reads false. Session-agnostic grace (matches the header + settle-clear)
  /// gated by the per-session terminal latch for prompt, correct settle.
  private func bridgeRunIsLiveLocked(chatId: String, sessionId: String) -> Bool {
    if bridgeSessionIsSettledLocked(chatId: chatId, sessionId: sessionId) { return false }
    let askOutstanding = agentBridgeAskByRequestId.values.contains { payload in
      (normalizedString(payload["chatId"]) ?? "") == chatId
    }
    if askOutstanding { return true }
    guard let last = agentTurnRunningAtMsByChatId[chatId] else { return false }
    return Int64(nowMs()) - last < Self.agentTurnRunningGraceMs
  }

  /// Flip an already-ingested tail `bridge-<sessionId>-<uid>` row out of its streaming state.
  /// Called from the idempotent-settled early-return (which returns before the per-row loop,
  /// so nothing else settles the cell). No-ops — and posts no change — when the row is already
  /// settled, so the per-tick idempotent re-push doesn't re-render the cell.
  private func settleBridgeTailRowStreamingLocked(chatId: String, sessionId: String, uid: String) {
    guard !uid.isEmpty else { return }
    let messageId = "bridge-\(sessionId)-\(uid)"
    var changed = false
    mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
      let wasStreaming =
        (message["isStreaming"] as? Bool) == true
        || ((message["metadata"] as? [String: Any])?["isStreaming"] as? Bool) == true
      guard wasStreaming else { return }
      message["isStreaming"] = false
      var metadata = (message["metadata"] as? [String: Any]) ?? [:]
      metadata["isStreaming"] = false
      message["metadata"] = metadata
      changed = true
    }
    guard changed else { return }
    storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
    postChangeLocked(
      reason: "chatMessageChanged",
      userInfo: ["chatId": chatId, "messageId": messageId, "state": statusSnapshotLocked()]
    )
    postChatDeltaLocked(
      chatId: chatId, inserted: [], updated: [messageId], deleted: [], source: "bridgeSettle")
  }

  /// Pin a settled agent reply to the slot its live stream bubble occupied. Rewrites the
  /// live-store copy immediately and records the override so both merge paths keep
  /// re-applying it to server/history copies of the same message for this session.
  private func adoptAgentSettleSlotTsLocked(chatId: String, messageId: String, slotTs: Int64) {
    guard slotTs > 0 else { return }
    if agentSettleSlotTsByMessageId[messageId] == nil {
      agentSettleSlotTsOrder.append(messageId)
      if agentSettleSlotTsOrder.count > 256 {
        let evicted = agentSettleSlotTsOrder.removeFirst()
        agentSettleSlotTsByMessageId.removeValue(forKey: evicted)
      }
    }
    agentSettleSlotTsByMessageId[messageId] = slotTs
    mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
      message["timestampMs"] = slotTs
      message["timestamp"] = slotTs
    }
    NSLog(
      "[AgentOrder] settle adopts live slot chatId=%@ messageId=%@ slotTs=%lld",
      String(chatId.suffix(12)), String(messageId.suffix(12)), slotTs)
  }

  /// Re-apply a recorded settle-slot override to a row copy that may have come from the
  /// server/history (which carries the settle-time timestamp and would re-sort the reply
  /// to the bottom, undoing the stable order the user already saw).
  private func rowAdoptingSettleSlotTs(_ row: [String: Any], messageId: String) -> [String: Any] {
    guard let slotTs = agentSettleSlotTsByMessageId[messageId],
      var message = row["message"] as? [String: Any]
    else { return row }
    let current =
      parseLongValue(message["timestampMs"] ?? message["timestamp_ms"] ?? message["timestamp"])
      ?? 0
    guard current != slotTs else { return row }
    message["timestampMs"] = slotTs
    message["timestamp"] = slotTs
    message.removeValue(forKey: "timestamp_ms")
    var next = row
    next["message"] = message
    return next
  }

  @discardableResult
  private func setLiveMessageUploadProgressLocked(
    chatId: String,
    messageId: String,
    progress: Double?,
    postDelta: Bool = true
  ) -> Bool {
    let normalizedProgress: Double?
    if let progress, progress.isFinite {
      normalizedProgress = max(0.0, min(1.0, progress))
    } else {
      normalizedProgress = nil
    }

    let existingProgress: Double? = {
      guard let perChat = liveMessageRowsByChat[chatId],
        let row = perChat[messageId],
        let message = row["message"] as? [String: Any]
      else {
        return nil
      }
      return parseDoubleValue(message["uploadProgress"])
        ?? parseDoubleValue((message["metadata"] as? [String: Any])?["uploadProgress"])
    }()

    let isUnchanged: Bool = {
      switch (existingProgress, normalizedProgress) {
      case (nil, nil):
        return true
      case let (lhs?, rhs?):
        return abs(lhs - rhs) < 0.004
      default:
        return false
      }
    }()
    if isUnchanged {
      return false
    }

    let changed = mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
      if let clamped = normalizedProgress {
        message["uploadProgress"] = clamped
        var metadata = (message["metadata"] as? [String: Any]) ?? [:]
        metadata["uploadProgress"] = clamped
        message["metadata"] = metadata
      } else {
        message.removeValue(forKey: "uploadProgress")
        if var metadata = message["metadata"] as? [String: Any] {
          metadata.removeValue(forKey: "uploadProgress")
          if metadata.isEmpty {
            message.removeValue(forKey: "metadata")
          } else {
            message["metadata"] = metadata
          }
        }
      }
    }
    if changed && postDelta {
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [messageId], deleted: [], source: "upload")
    }
    return changed
  }

  private func markLiveMessageDeletedLocked(chatId: String, messageId: String) {
    if var perChat = liveMessageRowsByChat[chatId] {
      perChat.removeValue(forKey: messageId)
      if perChat.isEmpty {
        liveMessageRowsByChat.removeValue(forKey: chatId)
      } else {
        liveMessageRowsByChat[chatId] = perChat
      }
    }
    var deleted = deletedMessageIdsByChat[chatId] ?? Set<String>()
    deleted.insert(messageId)
    deletedMessageIdsByChat[chatId] = deleted
    deleteCachedHistoryMessageLocked(chatId: chatId, messageId: messageId)
    storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
    feedCoreDeleteLocked(chatId: chatId, messageId: messageId)
  }

  /// Delete persistence must not depend on there being another row to write.
  /// `storeMergedChatHistoryIfLoadedLocked` intentionally skips an empty transcript,
  /// so without this direct removal the final message remains in SQLite (or the
  /// pre-SQLite UserDefaults blob) and resurrects after the next process launch.
  private func deleteCachedHistoryMessageLocked(chatId: String, messageId: String) {
    if var historyRows = historyRowsByChat[chatId] {
      historyRows.removeAll { self.messageId(fromRow: $0) == messageId }
      historyRowsByChat[chatId] = historyRows
    }

    var sqliteBefore = -1
    var sqliteAfter = -1
    if let userId = chatHistoryCacheUserIdLocked(), messageStore.isAvailable {
      sqliteBefore = messageStore.messageCount(userId: userId, chatId: chatId)
      messageStore.deleteMessages(
        userId: userId,
        chatId: chatId,
        messageIds: [messageId]
      )
      sqliteAfter = messageStore.messageCount(userId: userId, chatId: chatId)
    }

    var legacyRemoved = false
    if let cacheKey = chatHistoryCacheKeyLocked(chatId: chatId),
      let data = UserDefaults.standard.data(forKey: cacheKey),
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
      let legacyRows = object as? [[String: Any]]
    {
      let retained = legacyRows.filter { self.messageId(fromRow: $0) != messageId }
      if retained.count != legacyRows.count {
        legacyRemoved = true
        if retained.isEmpty {
          UserDefaults.standard.removeObject(forKey: cacheKey)
        } else if JSONSerialization.isValidJSONObject(retained),
          let nextData = try? JSONSerialization.data(withJSONObject: retained)
        {
          UserDefaults.standard.set(nextData, forKey: cacheKey)
        }
      }
    }

    NSLog(
      "[HistoryStore] DELETE chat=%@ id=%@ sqlite=%d→%d legacy=%@",
      String(chatId.prefix(12)),
      String(messageId.suffix(12)),
      sqliteBefore,
      sqliteAfter,
      legacyRemoved ? "Y" : "N"
    )
  }

  private func findMessagePayloadLocked(chatId: String, messageId: String) -> [String: Any]? {
    if let liveMessage = liveMessageRowsByChat[chatId]?[messageId]?["message"] as? [String: Any] {
      return liveMessage
    }
    guard let rows = historyRowsByChat[chatId] else { return nil }
    for row in rows {
      guard normalizedString(row["kind"]) == "message" else { continue }
      guard let message = row["message"] as? [String: Any] else { continue }
      if normalizedString(message["id"]) == messageId {
        return message
      }
    }
    return nil
  }

  private func buildLiveRowPayloadLocked(
    chatId: String,
    messageId: String,
    fromId: String?,
    type: String?,
    timestampMs: Int64,
    encryptedContent: String?,
    decryptedFields: [String: Any],
    forceEdited: Bool = false,
    forceEditedAt: Any? = nil
  ) -> [String: Any] {
    let normalizedType = normalizedString(type)?.lowercased() ?? "text"
    let normalizedFrom = normalizedString(fromId)
    let isMe =
      normalizedUpper(normalizedFrom) != nil
      && normalizedUpper(normalizedFrom) == currentUserIdLocked()
    let text = normalizedString(decryptedFields["text"]) ?? ""
    let mediaUrl = normalizedString(decryptedFields["mediaUrl"])
    let localMediaUrl = normalizedString(
      decryptedFields["localMediaUrl"] ?? decryptedFields["local_media_url"])
    let fileName = normalizedString(decryptedFields["fileName"])
    let fileSize = parseLongValue(decryptedFields["fileSize"])
    let latitude = parseDoubleValue(decryptedFields["latitude"])
    let longitude = parseDoubleValue(decryptedFields["longitude"])
    let duration = parseDoubleValue(decryptedFields["duration"])
    let replyToId = normalizedString(decryptedFields["replyToId"])
    let replyPreviewTitle = normalizedString(
      decryptedFields["replyPreviewTitle"] ?? decryptedFields["reply_preview_title"]
        ?? decryptedFields["replyAuthorName"] ?? decryptedFields["reply_author_name"])
    let replyPreviewText = normalizedString(
      decryptedFields["replyPreviewText"] ?? decryptedFields["reply_preview_text"]
        ?? decryptedFields["replyText"] ?? decryptedFields["reply_text"])
    let replyPreview = decryptedFields["replyPreview"] ?? decryptedFields["reply_preview"]
    let caption = normalizedString(decryptedFields["caption"])
    let waveform = parseWaveformArray(decryptedFields["waveform"])
    let isEdited = forceEdited || ((decryptedFields["isEdited"] as? Bool) == true)
    let editedAt = forceEditedAt ?? decryptedFields["editedAt"]

    var metadata = (decryptedFields["metadata"] as? [String: Any]) ?? [:]
    if let waveform { metadata["waveform"] = waveform }
    if let width = decryptedFields["width"] { metadata["width"] = width }
    if let height = decryptedFields["height"] { metadata["height"] = height }
    if let thumbnailBase64 = decryptedFields["thumbnailBase64"] {
      metadata["thumbnailBase64"] = thumbnailBase64
    }
    if let isVideoNote = decryptedFields["isVideoNote"] { metadata["isVideoNote"] = isVideoNote }
    if let fileSize { metadata["fileSize"] = fileSize }
    if let latitude { metadata["latitude"] = latitude }
    if let longitude { metadata["longitude"] = longitude }
    if let viewOnce = decryptedFields["viewOnce"] { metadata["viewOnce"] = viewOnce }
    if let contact = decryptedFields["contact"] { metadata["contact"] = contact }
    if let caption { metadata["caption"] = caption }
    if let mediaKey = decryptedFields["mediaKey"] { metadata["mediaKey"] = mediaKey }
    if let localMediaUrl { metadata["localMediaUrl"] = localMediaUrl }
    if let replyPreviewTitle { metadata["replyPreviewTitle"] = replyPreviewTitle }
    if let replyPreviewText { metadata["replyPreviewText"] = replyPreviewText }
    if let replyPreview { metadata["replyPreview"] = replyPreview }
    if let stickerId = normalizedString(decryptedFields["stickerId"]) {
      metadata["stickerId"] = stickerId
    }
    if let stickerPackId = normalizedString(
      decryptedFields["stickerPackId"] ?? decryptedFields["packId"])
    {
      metadata["stickerPackId"] = stickerPackId
      metadata["packId"] = stickerPackId
    }
    if let stickerBundleFileName = normalizedString(
      decryptedFields["stickerBundleFileName"] ?? decryptedFields["bundleFileName"])
    {
      metadata["stickerBundleFileName"] = stickerBundleFileName
      metadata["bundleFileName"] = stickerBundleFileName
    }
    if let emoji = normalizedString(decryptedFields["emoji"]) {
      metadata["emoji"] = emoji
    }
    // Music card identity. The send path seals `cover`/`artist`/`source` at the TOP level
    // of the encrypted payload, and the row model reads them back from `metadata` — this
    // fold is the only bridge between the two. Without it every history rebuild (network
    // reload, logout/login) produced a music row with no artwork, and the store upsert
    // then overwrote the rich row on disk, so the loss looked permanent.
    if metadata["cover"] == nil,
      let cover = normalizedString(
        decryptedFields["cover"] ?? decryptedFields["coverUrl"] ?? decryptedFields["artworkUrl"])
    {
      metadata["cover"] = cover
    }
    if metadata["artist"] == nil, let artist = normalizedString(decryptedFields["artist"]) {
      metadata["artist"] = artist
    }
    if metadata["source"] == nil, let source = normalizedString(decryptedFields["source"]) {
      metadata["source"] = source
    }

    var message: [String: Any] = [
      "id": messageId,
      "chatId": chatId,
      "timestampMs": Double(timestampMs),
      "timestamp": formatMessageTimeLabel(timestampMs: timestampMs),
      "text": text,
      "type": normalizedType,
      "isMe": isMe,
      "isEdited": isEdited,
      "bubbleShape": [
        "showTail": true,
        "borderTopLeftRadius": 18,
        "borderTopRightRadius": 18,
        "borderBottomRightRadius": 18,
        "borderBottomLeftRadius": 18,
      ],
    ]
    if let normalizedFrom { message["fromId"] = normalizedFrom }
    if isMe { message["status"] = "sent" }
    if let editedAt { message["editedAt"] = editedAt }
    if let encryptedContent { message["encryptedContent"] = encryptedContent }
    if let mediaUrl { message["mediaUrl"] = mediaUrl }
    if let localMediaUrl { message["localMediaUrl"] = localMediaUrl }
    if let fileName { message["fileName"] = fileName }
    if let duration { message["duration"] = duration }
    if let replyToId { message["replyToId"] = replyToId }
    if let replyPreviewTitle { message["replyPreviewTitle"] = replyPreviewTitle }
    if let replyPreviewText { message["replyPreviewText"] = replyPreviewText }
    if let replyPreview { message["replyPreview"] = replyPreview }
    if let caption { message["caption"] = caption }
    if let contact = decryptedFields["contact"] { message["contact"] = contact }
    if !metadata.isEmpty { message["metadata"] = metadata }

    return [
      "kind": "message",
      "key": "m-\(messageId)",
      "message": message,
    ]
  }

  private static let agentUserId = "00000000-0000-0000-0000-000000000001"

  /// Ingest the message mirrored onto this user's own topic for a chat whose realtime
  /// topic this device is NOT joined to (i.e. the chat is not on screen).
  ///
  /// Deliberately narrow:
  /// - a joined chat is left entirely to the chat-topic path, which additionally emits
  ///   the delivery receipt, clears typing, and retires the agent's streaming row;
  /// - a message the user already deleted locally is never re-inserted, because
  ///   `upsertLiveMessageRowLocked` lifts the tombstone and a late mirror (or a
  ///   reconnect-era duplicate) would otherwise resurrect deleted content.
  ///
  /// Everything else is the same upsert the chat topic performs, so redelivery of the
  /// same id updates in place rather than duplicating.
  private func ingestMirroredUserTopicMessageLocked(
    chatId: String, payload: [String: Any]
  ) -> (messageId: String, inserted: Bool)? {
    guard !nativeJoinedChatIds.contains(chatId) else { return nil }
    guard let messageId = normalizedString(payload["id"] ?? payload["message_id"]) else {
      return nil
    }
    guard deletedMessageIdsByChat[chatId]?.contains(messageId) != true else {
      NSLog(
        "[ChatEngine] user-topic mirror ignored for locally deleted message chatId=%@ messageId=%@",
        String(chatId.prefix(12)),
        String(messageId.prefix(12))
      )
      return nil
    }
    let wasPresent =
      liveMessageRowsByChat[chatId]?[messageId] != nil
      || (historyRowsByChat[chatId] ?? []).contains { self.messageId(fromRow: $0) == messageId }
    guard
      let insertedMessageId = applyNativeIncomingMessageEventLocked(
        chatId: chatId, payload: payload, postDelta: true)
    else { return nil }
    return (insertedMessageId, !wasPresent)
  }

  private func applyNativeIncomingMessageEventLocked(
    chatId: String, payload: [String: Any], postDelta: Bool = true
  )
    -> String?
  {
    guard let messageId = normalizedString(payload["id"] ?? payload["message_id"]) else {
      return nil
    }
    // Same rule as the history page: the core reads the frame the server sent,
    // not Swift's interpretation of it. `.chatTopic` rather than `.historyPage`
    // because the source drives the core's flush barrier and its dedup rules.
    feedCoreRawFramesLocked(chatId: chatId, rawMessages: [payload], source: .chatTopic)

    let fromId = normalizedString(payload["fromId"] ?? payload["from_id"])
    let encryptedContent = normalizedString(
      payload["encryptedContent"] ?? payload["encrypted_content"])
    let type = normalizedString(payload["type"]) ?? "text"
    let timestampMs = parseLongValue(payload["timestamp"]) ?? Int64(nowMs())
    let isMe = normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserIdLocked()
    let rawMediaUrl = normalizedString(payload["mediaUrl"] ?? payload["media_url"])
    let rawFileName = normalizedString(payload["fileName"] ?? payload["file_name"])
    let rawMediaKey = normalizedString(payload["mediaKey"] ?? payload["media_key"])
    let derivedFileName = deriveFileNameFromURL(rawMediaUrl)
    let encryptedLooksHybrid = isLikelyHybridCiphertext(encryptedContent)
    let encryptedIsMls = VibeSecureSessions.isMlsEnvelope(encryptedContent)

    // Detect agent messages by fromId or explicit flag.
    //
    // These MUST resolve from `metadata` as well as the top level, exactly like
    // `buildHistoryRowsLocked` does (see `rawAgentId`/`rawAgentName` there). The server
    // puts agent identity in `metadata` for some deliveries, and this builder used to look
    // only at the top level — so the same message produced a RICH row through the history
    // path and a POOR one through this path: no `isAgentMessage`, no agentName/agentId, no
    // plainContent, and a different `type`.
    //
    // That asymmetry is not cosmetic, because `mergedChatRowsLocked` prefers the LIVE row
    // over the history row for any id present in both. So the poor copy shadows the rich
    // one and the transcript silently downgrades 48 agent rows to plain text. Measured on
    // chat 47157fce5863 (Mahiro — a normal DM that contains agent messages, so it never
    // takes the `agentChatMode` protected path):
    //
    //   parse reuse-MISS count=55 of=59 fields=[message.agentId=48, message.agentName=48,
    //     message.isAgentMessage=48, message.plainContent=48, message.type=39]
    //   height-audit stale=41 of 48 shifted=14 dh=-421
    //     flipped=[plainContent=41, agentName=41, agentId=41, ...]
    //   [ListShift] MOVED row=c-40b4fcbe9614 … ×17, ~420pt total
    //
    // The warm snapshot seeds the rich rows, this path replaces them with poor ones, every
    // cached height is invalidated at once, and the list walks under the reader.
    let rawMetadataForAgentFields = payload["metadata"] as? [String: Any]
    let agentName = firstNormalizedString(
      payload["agentName"], payload["agent_name"],
      rawMetadataForAgentFields?["agentName"], rawMetadataForAgentFields?["agent_name"])
    let agentId = firstNormalizedString(
      payload["agentId"], payload["agent_id"],
      rawMetadataForAgentFields?["agentId"], rawMetadataForAgentFields?["agent_id"])
    let isAgentMessage =
      (payload["isAgentMessage"] as? Bool == true)
      || (payload["is_agent_message"] as? Bool == true)
      || (rawMetadataForAgentFields?["isAgentMessage"] as? Bool == true)
      || (rawMetadataForAgentFields?["is_agent_message"] as? Bool == true)
      || (normalizedString(fromId)?.lowercased() == Self.agentUserId)
      || agentId != nil
      || agentName != nil
      || (rawMediaUrl?.lowercased().contains("/uploads/agent-docs/") == true)
      || (rawMediaUrl?.lowercased().contains("/api/agent/document/") == true)
    let plainContent = firstNormalizedString(
      payload["plainContent"], payload["plain_content"], payload["plaintext"],
      rawMetadataForAgentFields?["plainContent"], rawMetadataForAgentFields?["plain_content"])
    let agentUserId =
      firstNormalizedString(
        payload["agentUserId"], payload["agent_user_id"],
        rawMetadataForAgentFields?["agentUserId"], rawMetadataForAgentFields?["agent_user_id"])
      ?? (isAgentMessage ? fromId : nil)
    let agentUsername = firstNormalizedString(
      payload["agentUsername"], payload["agent_username"],
      payload["agentHandle"], payload["agent_handle"],
      rawMetadataForAgentFields?["agentUsername"], rawMetadataForAgentFields?["agent_username"],
      rawMetadataForAgentFields?["agentHandle"], rawMetadataForAgentFields?["agent_handle"])

    let hadEncryptedContent = encryptedContent != nil && !encryptedContent!.isEmpty
    let decryptedText: String = {
      // Agent messages use plainContent instead of encryption
      if isAgentMessage, let plainContent, !plainContent.isEmpty {
        return plainContent
      }
      guard let encryptedContent, !encryptedContent.isEmpty else {
        return ""
      }
      // An MLS envelope is opened by the ratchet in `vibe_secure`, not by the
      // RSA path — no key travels with it, so there is nothing here to unwrap.
      // Tested BEFORE the hybrid check: `vmls1.` is not JSON, so it would
      // otherwise fall through the `!encryptedLooksHybrid` arm below and render
      // as literal text.
      if encryptedIsMls {
        // Our own message can never be opened — MLS encrypts to the *other*
        // members and refuses to process what we authored. Asking anyway is
        // how these rendered as empty bubbles; the retained plaintext is the
        // only source for them.
        if isMe, let mine = VibeSecureSessions.shared.ownPlaintext(messageId: messageId) {
          return mine
        }
        return VibeSecureSessions.shared.open(
          chatId: chatId, envelope: encryptedContent, isMine: isMe, messageId: messageId) ?? ""
      }
      if !encryptedLooksHybrid {
        return encryptedContent
      }
      guard let privateKey = decryptPrivateKeyLocked() else { return "" }
      return chatEngineDecryptHybridMessage(
        privateKey: privateKey, ciphertext: encryptedContent, isMyMessage: isMe)
    }()
    // `encryptedIsMls` belongs here too. Without it a failed MLS open renders as
    // an empty bubble rather than the decryption-failed state, because the
    // envelope is not hybrid and the old condition only ever considered hybrid.
    let decryptionFailed =
      !isAgentMessage && hadEncryptedContent && (encryptedLooksHybrid || encryptedIsMls)
      && decryptedText.isEmpty

    var decryptedFields = parseDecryptedMessagePayload(decryptedText)
    // Always merge server/wire metadata in (forward chrome, covers, etc.). Decrypted
    // E2E JSON often has only text and used to leave `metadata` nil/empty so reopen
    // lost isForwarded / forwardedFrom* / cover after history reload.
    if let metadata = payload["metadata"] as? [String: Any], !metadata.isEmpty {
      var merged = (decryptedFields["metadata"] as? [String: Any]) ?? [:]
      for (key, value) in metadata {
        if merged[key] == nil { merged[key] = value }
      }
      // Prefer durable remote mediaUrl from server metadata over any local path.
      if let remote = metadata["mediaUrl"] as? String ?? metadata["media_url"] as? String,
        remote.hasPrefix("http")
      {
        merged["mediaUrl"] = remote
      }
      decryptedFields["metadata"] = merged
    }
    if let rawReplyToId = normalizedString(payload["replyToId"] ?? payload["reply_to_id"]),
      normalizedString(decryptedFields["replyToId"]) == nil
    {
      decryptedFields["replyToId"] = rawReplyToId
    }
    if let rawMediaUrl, !rawMediaUrl.isEmpty, normalizedString(decryptedFields["mediaUrl"]) == nil {
      decryptedFields["mediaUrl"] = rawMediaUrl
    }
    if let rawMediaKey, !rawMediaKey.isEmpty, normalizedString(decryptedFields["mediaKey"]) == nil {
      decryptedFields["mediaKey"] = rawMediaKey
    }
    let fileNameForRow =
      rawFileName
      ?? ((normalizedString(type)?.lowercased() == "file") ? derivedFileName : nil)
    if let fileNameForRow, !fileNameForRow.isEmpty,
      normalizedString(decryptedFields["fileName"]) == nil
    {
      decryptedFields["fileName"] = fileNameForRow
    }
    var row = buildLiveRowPayloadLocked(
      chatId: chatId,
      messageId: messageId,
      fromId: fromId,
      type: type,
      timestampMs: timestampMs,
      encryptedContent: encryptedContent,
      decryptedFields: decryptedFields
    )
    // Inject agent-specific fields into the message payload for the UI layer
    if isAgentMessage, var message = row["message"] as? [String: Any] {
      message["isAgentMessage"] = true
      message["isMe"] = false
      if let agentName { message["agentName"] = agentName }
      if let agentId { message["agentId"] = agentId }
      if let agentUserId { message["agentUserId"] = agentUserId }
      if let agentUsername {
        message["agentUsername"] = agentUsername.trimmingCharacters(
          in: CharacterSet(charactersIn: "@"))
      }
      if let plainContent { message["plainContent"] = plainContent }
      // Use plainContent as the display text for agent messages
      if let plainContent, !plainContent.isEmpty { message["text"] = plainContent }
      row["message"] = message
    }
    // Signal decryption failure to the UI layer so it can show an appropriate indicator
    // instead of a blank bubble.
    if decryptionFailed, var message = row["message"] as? [String: Any] {
      message["decryptionFailed"] = true
      row["message"] = message
    }
    if ["image", "gif", "file", "voice", "video", "music", "sticker"].contains(type.lowercased()), isMe,
      let existingMessage = findMessagePayloadLocked(chatId: chatId, messageId: messageId),
      let localPlaybackUrl = extractLocalPlaybackMediaURLFromMessage(existingMessage)
    {
      NSLog(
        "[ChatEngine] preserve local media url on incoming echo chatId=%@ messageId=%@ local=%@",
        chatId,
        messageId,
        localPlaybackUrl
      )
      row = mergeLocalPlaybackMediaURLIntoRow(row: row, localUrl: localPlaybackUrl)
    }
    // The server strips sealed image blobs (`agentBridgeAttachmentsEnc`) from the
    // broadcast/persisted copy, so an own-send echo would wipe the attachment
    // thumbnails off the optimistic row. Carry them (and durable thumbs/caption)
    // forward from the existing row.
    if isMe, let existingMessage = findMessagePayloadLocked(chatId: chatId, messageId: messageId) {
      let existingMeta = existingMessage["metadata"] as? [String: Any]
      let existingBlobs =
        (existingMeta?["agentBridgeAttachmentsEnc"] as? [String])?.filter { !$0.isEmpty } ?? []
      let existingThumbs =
        (existingMeta?["attachmentThumbnailsB64"] as? [String])?.filter { !$0.isEmpty } ?? []
      let existingThumb =
        (existingMeta?["thumbnailBase64"] as? String)
        ?? (existingMessage["thumbnailBase64"] as? String)
      if var message = row["message"] as? [String: Any] {
        var meta = (message["metadata"] as? [String: Any]) ?? [:]
        var changed = false
        if !existingBlobs.isEmpty,
          ((meta["agentBridgeAttachmentsEnc"] as? [String])?.isEmpty ?? true)
        {
          meta["agentBridgeAttachmentsEnc"] = existingBlobs
          changed = true
        }
        if !existingThumbs.isEmpty,
          ((meta["attachmentThumbnailsB64"] as? [String])?.isEmpty ?? true)
        {
          meta["attachmentThumbnailsB64"] = existingThumbs
          changed = true
        }
        if let existingThumb, !existingThumb.isEmpty,
          ((meta["thumbnailBase64"] as? String)?.isEmpty ?? true)
        {
          meta["thumbnailBase64"] = existingThumb
          message["thumbnailBase64"] = existingThumb
          changed = true
        }
        // Keep image type if the optimistic row was media and the echo collapsed to text.
        let existingType = ((existingMessage["type"] as? String) ?? "").lowercased()
        let nextType = ((message["type"] as? String) ?? "").lowercased()
        if ["image", "gif", "video"].contains(existingType), nextType == "text" || nextType.isEmpty
        {
          message["type"] = existingType
          changed = true
        }
        if changed {
          message["metadata"] = meta
          row["message"] = message
        }
      }
    }
    let inserted = upsertLiveMessageRowLocked(chatId: chatId, messageId: messageId, row: row)
    appendJournalLocked(
      event: "native-message-row-upsert",
      payload: [
        "chatId": chatId,
        "messageId": messageId,
        "type": type,
      ])
    state["updatedAt"] = nowMs()
    if postDelta {
      let source =
        messageId.hasPrefix("stream-") || messageId.hasPrefix("lan-") ? "stream" :
        messageId.hasPrefix("bridge-") ? "bridge" : "live"
      postChatDeltaLocked(
        chatId: chatId,
        inserted: inserted ? [messageId] : [],
        updated: inserted ? [] : [messageId],
        deleted: [],
        source: source)
    }
    return messageId
  }

  private func extractLocalPlaybackMediaURLFromMessage(_ message: [String: Any]) -> String? {
    let metadata = message["metadata"] as? [String: Any]
    let candidates: [Any?] = [
      message["localMediaUrl"],
      message["local_media_url"],
      metadata?["localMediaUrl"],
      metadata?["local_media_url"],
      message["mediaUrl"],
      message["media_url"],
      metadata?["mediaUrl"],
      metadata?["media_url"],
      message["uri"],
      metadata?["uri"],
      message["audioUrl"],
      message["audio_url"],
      metadata?["audioUrl"],
      metadata?["audio_url"],
    ]
    for candidate in candidates {
      guard let value = normalizedString(candidate), isLocalMediaURI(value) else { continue }
      return value
    }
    return nil
  }

  private func mergeLocalPlaybackMediaURLIntoRow(row: [String: Any], localUrl: String) -> [String:
    Any]
  {
    var mutableRow = row
    guard var message = mutableRow["message"] as? [String: Any] else {
      return mutableRow
    }
    message["localMediaUrl"] = localUrl
    var metadata = (message["metadata"] as? [String: Any]) ?? [:]
    metadata["localMediaUrl"] = localUrl
    message["metadata"] = metadata
    mutableRow["message"] = message
    return mutableRow
  }

  private func applyNativeChatMutationEventLocked(
    chatId: String,
    event: String,
    payload: [String: Any]
  ) -> (messageId: String, action: String)? {
    guard !chatId.isEmpty else { return nil }
    guard let messageId = normalizedString(payload["messageId"] ?? payload["message_id"]) else {
      return nil
    }
    switch event {
    case "message-edited":
      // Deletion wins every race. `upsertLiveMessageRowLocked` intentionally lifts a
      // tombstone for legitimate re-inserts, so an older edit must be rejected before
      // hydrating its canonical message or it could resurrect deleted content.
      guard deletedMessageIdsByChat[chatId]?.contains(messageId) != true else { return nil }
      let editedAtValue = payload["editedAt"] ?? payload["edited_at"]
      let encryptedContent = normalizedString(
        payload["encryptedContent"] ?? payload["encrypted_content"])

      // A user-topic mutation can arrive for a chat this process has never opened. The
      // compact canonical row included by the server supplies the identity/type/metadata
      // needed to build a real bubble without waiting for a history fetch (and therefore
      // keeps the first pushed frame populated). Older servers omit it; in that case we
      // preserve the current snapshot and let Home's reconcile fetch fill the gap.
      if findMessagePayloadLocked(chatId: chatId, messageId: messageId) == nil,
        let mirroredMessage = payload["message"] as? [String: Any],
        normalizedString(mirroredMessage["id"] ?? mirroredMessage["message_id"]) == messageId
      {
        _ = applyNativeIncomingMessageEventLocked(
          chatId: chatId, payload: mirroredMessage, postDelta: false)
      }
      guard let existingMessage = findMessagePayloadLocked(chatId: chatId, messageId: messageId)
      else { return nil }

      // Receipts and mutations are allowed to be duplicated and reordered by reconnects.
      // Never let an older edit overwrite a newer local/server edit.
      if let incomingEditedAt = parseLongValue(editedAtValue),
        let currentEditedAt = parseLongValue(
          existingMessage["editedAt"] ?? existingMessage["edited_at"]),
        incomingEditedAt < currentEditedAt
      {
        return nil
      }
      let existingMetadata = existingMessage["metadata"] as? [String: Any]
      let fromId = normalizedString(existingMessage["fromId"] ?? existingMessage["from_id"])
      let type = normalizedString(existingMessage["type"]) ?? "text"
      let timestampMs =
        parseLongValue(existingMessage["timestampMs"] ?? existingMessage["timestamp"])
        ?? Int64(nowMs())
      let isMe = normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserIdLocked()
      let decryptedFields: [String: Any] = {
        guard let encryptedContent, !encryptedContent.isEmpty else {
          return [:]
        }
        if !isLikelyHybridCiphertext(encryptedContent) {
          return parseDecryptedMessagePayload(encryptedContent)
        }
        guard let privateKey = decryptPrivateKeyLocked() else { return [:] }
        let decrypted = chatEngineDecryptHybridMessage(
          privateKey: privateKey,
          ciphertext: encryptedContent,
          isMyMessage: isMe
        )
        return parseDecryptedMessagePayload(decrypted)
      }()
      var hydratedFields = decryptedFields
      if normalizedString(hydratedFields["mediaUrl"]) == nil {
        hydratedFields["mediaUrl"] =
          existingMessage["mediaUrl"] ?? existingMessage["media_url"]
          ?? existingMetadata?["mediaUrl"] ?? existingMetadata?["media_url"]
      }
      if normalizedString(hydratedFields["fileName"]) == nil {
        hydratedFields["fileName"] =
          existingMessage["fileName"] ?? existingMessage["file_name"]
          ?? existingMetadata?["fileName"] ?? existingMetadata?["file_name"]
      }
      if normalizedString(hydratedFields["mediaKey"]) == nil {
        hydratedFields["mediaKey"] =
          existingMessage["mediaKey"] ?? existingMessage["media_key"]
          ?? existingMetadata?["mediaKey"] ?? existingMetadata?["media_key"]
      }
      if hydratedFields["thumbnailBase64"] == nil {
        hydratedFields["thumbnailBase64"] =
          existingMessage["thumbnailBase64"] ?? existingMessage["thumbnail_base64"]
          ?? existingMetadata?["thumbnailBase64"] ?? existingMetadata?["thumbnail_base64"]
      }
      // Carry the existing metadata under the edited payload's fields so an edit
      // (e.g. adding a caption to a sent image) can't wipe row-only state like the
      // sealed attachment blobs (server never echoes those back) or media size.
      // Also accept top-level `metadata` on the wire event (decision settlement
      // rewrites `service` there without re-wrapping ciphertext as hybrid JSON).
      let wireMetadata = payload["metadata"] as? [String: Any]
      if let existingMetadata, !existingMetadata.isEmpty {
        var mergedMetadata = existingMetadata
        if let editedMetadata = hydratedFields["metadata"] as? [String: Any] {
          mergedMetadata.merge(editedMetadata) { _, new in new }
        }
        if let wireMetadata {
          mergedMetadata.merge(wireMetadata) { _, new in new }
        }
        hydratedFields["metadata"] = mergedMetadata
      } else if let wireMetadata, !wireMetadata.isEmpty {
        var mergedMetadata = (hydratedFields["metadata"] as? [String: Any]) ?? [:]
        mergedMetadata.merge(wireMetadata) { _, new in new }
        hydratedFields["metadata"] = mergedMetadata
      }
      if let plain = normalizedString(payload["plainContent"] ?? payload["plaintext"]),
        !plain.isEmpty
      {
        hydratedFields["text"] = plain
        hydratedFields["plainContent"] = plain
      }
      let row = buildLiveRowPayloadLocked(
        chatId: chatId,
        messageId: messageId,
        fromId: fromId,
        type: type,
        timestampMs: timestampMs,
        encryptedContent: encryptedContent
          ?? normalizedString(
            existingMessage["encryptedContent"] ?? existingMessage["encrypted_content"]),
        decryptedFields: hydratedFields,
        forceEdited: true,
        forceEditedAt: editedAtValue
      )
      upsertLiveMessageRowLocked(chatId: chatId, messageId: messageId, row: row)
      appendJournalLocked(
        event: "native-message-edited",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "editedAt": editedAtValue as Any,
        ])
      state["updatedAt"] = nowMs()
      return (messageId, "edited")
    case "message-deleted":
      removeMessageIndicesLocked(chatId: chatId, messageId: messageId)
      markLiveMessageDeletedLocked(chatId: chatId, messageId: messageId)
      applyPinnedUpdateLocked(
        chatId: chatId,
        messageId: messageId,
        pinned: false,
        payload: [:],
        trigger: "message_deleted",
        refreshRemote: false
      )
      appendJournalLocked(
        event: "native-message-deleted",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
        ])
      state["updatedAt"] = nowMs()
      return (messageId, "deleted")
    default:
      return nil
    }
  }

  private func applyNativeChatEventLocked(
    chatId: String,
    event: String,
    payload: [String: Any]
  ) -> (messageId: String, status: String)? {
    guard !chatId.isEmpty else { return nil }
    switch event {
    case "message-delivered":
      guard let messageId = normalizedString(payload["messageId"] ?? payload["message_id"]) else {
        return nil
      }
      // A receipt can legally arrive after the message was deleted (peer's client had it
      // in flight, or a reconnect replayed it). Recording it would re-seed the receipt
      // indices for a row that no longer exists and leave stale state behind a later
      // re-use of the same id.
      guard deletedMessageIdsByChat[chatId]?.contains(messageId) != true else { return nil }
      upsertReceiptLocked(chatId: chatId, messageId: messageId, status: "delivered")
      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "delivered")
      appendJournalLocked(
        event: "native-message-delivered",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
        ])
      return (messageId, "delivered")
    case "message-read":
      guard let messageId = normalizedString(payload["messageId"] ?? payload["message_id"]) else {
        return nil
      }
      guard deletedMessageIdsByChat[chatId]?.contains(messageId) != true else { return nil }
      upsertReceiptLocked(chatId: chatId, messageId: messageId, status: "read")
      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "read")
      appendJournalLocked(
        event: "native-message-read",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
        ])
      return (messageId, "read")
    default:
      return nil
    }
  }

  private func fetchPinnedMessagesLocked(chatId: String, trigger: String) {
    guard !chatId.isEmpty else { return }
    guard chatId != "saved_messages" else {
      pinnedMessagesByChatId[chatId] = []
      VibeDebugLog.log("[ChatEngine][Pin] fetchPinnedMessages skip saved_messages trigger=%@", trigger)
      return
    }
    guard !pinnedFetchInFlightChatIds.contains(chatId) else {
      VibeDebugLog.log(
        "[ChatEngine][Pin] fetchPinnedMessages skipped (in-flight) chatId=%@ trigger=%@",
        chatId,
        trigger
      )
      return
    }
    guard let apiBase = apiBaseURLLocked() else {
      VibeDebugLog.log(
        "[ChatEngine][Pin] fetchPinnedMessages skipped (missing apiBase) chatId=%@ trigger=%@",
        chatId,
        trigger
      )
      return
    }
    let token = authHeaderTokenLocked() ?? ""

    pinnedFetchInFlightChatIds.insert(chatId)
    VibeDebugLog.log(
      "[ChatEngine][Pin] fetchPinnedMessages start chatId=%@ trigger=%@ tokenPresent=%@",
      chatId,
      trigger,
      token.isEmpty ? "false" : "true"
    )
    appendJournalLocked(
      event: "native-pinned-load-start",
      payload: ["chatId": chatId, "trigger": trigger]
    )

    var request = URLRequest(
      url: apiBase.appendingPathComponent("api").appendingPathComponent("chat")
        .appendingPathComponent(chatId).appendingPathComponent("pinned_messages"))
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        self.pinnedFetchInFlightChatIds.remove(chatId)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        if let error {
          NSLog(
            "[ChatEngine][Pin] fetchPinnedMessages network error chatId=%@ trigger=%@ error=%@",
            chatId,
            trigger,
            error.localizedDescription
          )
          self.appendJournalLocked(
            event: "native-pinned-load-error",
            payload: [
              "chatId": chatId,
              "trigger": trigger,
              "error": error.localizedDescription,
            ])
          self.postChangeLocked(
            reason: "chatPinnedUpdated",
            userInfo: ["chatId": chatId, "loading": false]
          )
          return
        }

        guard (200...299).contains(statusCode), let data else {
          NSLog(
            "[ChatEngine][Pin] fetchPinnedMessages http error chatId=%@ trigger=%@ status=%@",
            chatId,
            trigger,
            String(statusCode)
          )
          if statusCode == 401 {
            Task { await AppSessionGuard.shared.recover(reason: "pinned-http-401") }
          }
          self.appendJournalLocked(
            event: "native-pinned-load-error",
            payload: [
              "chatId": chatId,
              "trigger": trigger,
              "status": statusCode,
            ])
          self.postChangeLocked(
            reason: "chatPinnedUpdated",
            userInfo: ["chatId": chatId, "loading": false]
          )
          return
        }

        let nextPins = self.parsePinnedMessagesResponse(data: data, chatId: chatId)
        let nextPinIds = nextPins.compactMap {
          self.normalizedString($0["messageId"] ?? $0["message_id"])
        }
        VibeDebugLog.log(
          "[ChatEngine][Pin] fetchPinnedMessages ok chatId=%@ trigger=%@ status=%@ count=%@ ids=%@",
          chatId,
          trigger,
          String(statusCode),
          String(nextPins.count),
          nextPinIds.joined(separator: ",")
        )
        let previousPins = self.pinnedMessagesByChatId[chatId] ?? []
        let previousIds = Set(
          previousPins.compactMap { self.normalizedString($0["messageId"] ?? $0["message_id"]) })
        let nextIds = Set(
          nextPins.compactMap { self.normalizedString($0["messageId"] ?? $0["message_id"]) })
        let allIds = previousIds.union(nextIds)
        for messageId in allIds {
          self.setMessagePinnedStateLocked(
            chatId: chatId,
            messageId: messageId,
            pinned: nextIds.contains(messageId)
          )
        }

        self.pinnedMessagesByChatId[chatId] = nextPins
        self.state["updatedAt"] = self.nowMs()
        self.appendJournalLocked(
          event: "native-pinned-load-ok",
          payload: [
            "chatId": chatId,
            "trigger": trigger,
            "count": nextPins.count,
            "status": statusCode,
          ])
        let snapshot = self.statusSnapshotLocked()
        self.postChangeLocked(
          reason: "chatPinnedUpdated",
          userInfo: [
            "chatId": chatId,
            "loading": false,
            "count": nextPins.count,
            "state": snapshot,
          ]
        )
      }
    }.resume()
  }

  private func parsePinnedMessagesResponse(data: Data, chatId: String) -> [[String: Any]] {
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let response = object as? [String: Any]
    else {
      return []
    }

    let rawItems = (response["data"] as? [Any]) ?? []
    return rawItems.compactMap { rawItem in
      guard let raw = rawItem as? [String: Any] else { return nil }
      return normalizePinnedEntry(raw, chatId: chatId)
    }
  }

  private func normalizePinnedEntry(
    _ raw: [String: Any],
    chatId: String,
    fallbackMessageId: String? = nil
  ) -> [String: Any]? {
    let messageId =
      normalizedString(raw["messageId"] ?? raw["message_id"] ?? raw["id"] ?? fallbackMessageId)
    guard let messageId, !messageId.isEmpty else { return nil }

    var entry: [String: Any] = [
      "messageId": messageId,
      "chatId": chatId,
    ]
    if let pinnedAt = raw["pinnedAt"] ?? raw["pinned_at"] {
      entry["pinnedAt"] = pinnedAt
    } else {
      entry["pinnedAt"] = nowMs()
    }
    if let timestamp = raw["timestamp"] ?? raw["messageTimestamp"] ?? raw["message_timestamp"] {
      entry["timestamp"] = timestamp
    }
    if let type = normalizedString(raw["type"] ?? raw["messageType"] ?? raw["message_type"]) {
      entry["type"] = type
    }
    if let mediaURL = normalizedString(raw["mediaUrl"] ?? raw["media_url"]) {
      entry["mediaUrl"] = mediaURL
    }
    if let fileName = normalizedString(raw["fileName"] ?? raw["file_name"]) {
      entry["fileName"] = fileName
    }
    if let text = normalizedString(raw["text"] ?? raw["plainContent"] ?? raw["plain_content"]) {
      entry["text"] = text
    }
    return entry
  }

  private func applyPinnedUpdateLocked(
    chatId: String,
    messageId: String,
    pinned: Bool,
    payload: [String: Any],
    trigger: String,
    refreshRemote: Bool
  ) {
    setMessagePinnedStateLocked(chatId: chatId, messageId: messageId, pinned: pinned)

    var pins = pinnedMessagesByChatId[chatId] ?? []
    pins.removeAll {
      normalizedString($0["messageId"] ?? $0["message_id"]) == messageId
    }
    if pinned {
      let entry =
        normalizePinnedEntry(payload, chatId: chatId, fallbackMessageId: messageId)
        ?? [
          "messageId": messageId,
          "chatId": chatId,
          "pinnedAt": nowMs(),
        ]
      pins.insert(entry, at: 0)
    }
    pinnedMessagesByChatId[chatId] = pins
    NSLog(
      "[ChatEngine][Pin] applyPinnedUpdate chatId=%@ messageId=%@ pinned=%@ trigger=%@ pinCount=%@",
      chatId,
      messageId,
      pinned ? "true" : "false",
      trigger,
      String(pins.count)
    )
    state["updatedAt"] = nowMs()
    appendJournalLocked(
      event: "native-pinned-updated",
      payload: [
        "chatId": chatId,
        "messageId": messageId,
        "pinned": pinned,
        "trigger": trigger,
      ])
    if refreshRemote {
      fetchPinnedMessagesLocked(chatId: chatId, trigger: trigger)
    }
  }

  private func setMessagePinnedStateLocked(chatId: String, messageId: String, pinned: Bool) {
    let liveChanged = mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
      message["isPinned"] = pinned
      message["pinned"] = pinned
    }

    guard var rows = historyRowsByChat[chatId] else {
      if liveChanged {
        postChatDeltaLocked(
          chatId: chatId, inserted: [], updated: [messageId], deleted: [], source: "pin")
      }
      return
    }
    var changed = false
    for index in rows.indices {
      guard normalizedString(rows[index]["kind"]) == "message" else { continue }
      guard var message = rows[index]["message"] as? [String: Any] else { continue }
      guard normalizedString(message["id"]) == messageId else { continue }
      let previousMessage = message
      message["isPinned"] = pinned
      message["pinned"] = pinned
      guard !(message as NSDictionary).isEqual(to: previousMessage) else { continue }
      var row = rows[index]
      row["message"] = message
      rows[index] = row
      changed = true
    }
    if changed {
      historyRowsByChat[chatId] = rows
    }
    if liveChanged || changed {
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [messageId], deleted: [], source: "pin")
    }
  }

  private func joinNativeChatTopicIfNeededLocked(chatId: String) {
    guard !chatId.isEmpty else { return }
    guard !isBuiltInAgentChatId(chatId) else {
      VibeDebugLog.log("[ChatEngine][Route] skip realtime join for built-in agent chatId=%@", chatId)
      return
    }
    guard chatId != "saved_messages" else {
      VibeDebugLog.log("[ChatEngine][Route] skip realtime join for saved_messages")
      return
    }
    guard let client = phoenixClient else {
      VibeDebugLog.log("[ChatEngine][Route] joinNativeChatTopic deferred chatId=%@ reason=no_socket", chatId)
      scheduleReconnectLocked(reason: "join_chat_no_socket")
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "join_chat_no_socket")
      }
      return
    }
    guard state["connected"] as? Bool == true else {
      VibeDebugLog.log("[ChatEngine][Route] joinNativeChatTopic deferred chatId=%@ reason=not_connected", chatId)
      scheduleReconnectLocked(reason: "join_chat_not_connected")
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "join_chat_not_connected")
      }
      return
    }
    if nativeJoinedChatIds.contains(chatId) { return }
    if nativeChatJoinRefsByRef.values.contains(chatId) { return }
    VibeDebugLog.log("[ChatEngine][Route] joinNativeChatTopic start chatId=%@", chatId)
    let ref = client.join(topic: chatTopic(for: chatId), payload: [:])
    nativeChatJoinRefsByRef[ref] = chatId
    appendJournalLocked(event: "native-chat-join-start", payload: ["chatId": chatId, "ref": ref])
  }

  /// A Phoenix channel is a process independent from the websocket. If that
  /// process exits, the socket may remain open and `connected` stays true, but
  /// pushes to the old topic receive `unmatched topic`. Recover the individual
  /// topic immediately and keep every unacknowledged bubble queued.
  private func recoverStaleNativeChatTopicLocked(chatId: String, reason: String) {
    guard !chatId.isEmpty else { return }

    let inFlight = nativePendingMessagePushRefs.filter { _, pending in
      pending.chatId == chatId
    }
    for (ref, pending) in inFlight {
      nativePendingMessagePushRefs.removeValue(forKey: ref)
      nativeMessagePushSentAtMs.removeValue(forKey: ref)
      upsertLocalStatusLocked(
        chatId: pending.chatId,
        messageId: pending.messageId,
        status: "pending",
        allowDowngrade: true
      )
      if let draft = pendingOutboundDraftsByMessageId[pending.messageId] {
        queueOutboundDraftLocked(
          chatId: pending.chatId,
          messageId: pending.messageId,
          payload: draft,
          reason: reason
        )
      }
    }

    nativeJoinedChatIds.remove(chatId)
    nativeChatJoinRefsByRef = nativeChatJoinRefsByRef.filter { _, joinedChatId in
      joinedChatId != chatId
    }
    appendJournalLocked(
      event: "native-chat-topic-recover",
      payload: [
        "chatId": chatId,
        "reason": reason,
        "requeued": inFlight.count,
      ])
    NSLog(
      "[OutboundRetry] rejoin stale topic chatId=%@ reason=%@ requeued=%d",
      chatId, reason, inFlight.count)

    let hasDemand =
      openChatChannels[chatId] != nil
      || !(pendingOutboundQueueByChat[chatId]?.isEmpty ?? true)
      || !inFlight.isEmpty
    if hasDemand {
      joinNativeChatTopicIfNeededLocked(chatId: chatId)
    }
    state["updatedAt"] = nowMs()
    postChangeLocked(
      reason: "chatChannelStateChanged",
      userInfo: ["chatId": chatId, "recovery": reason]
    )
  }

  /// Answers "why is this row still showing a clock?" for a whole chat at once.
  ///
  /// A row renders pending purely from its stored `status`. Nothing about that string
  /// says whether the send is still *going* to happen — that depends on an outbound
  /// draft existing and being in this chat's replay queue. A message whose status says
  /// pending but which has no draft is not in flight and never will be: it is a
  /// permanent clock, and the only way to tell the two apart from the outside is to ask
  /// here.
  ///
  /// `queue.async`, never `syncOnQueue` — a diagnostic that blocks the main thread to
  /// explain a rendering problem has become one. It logs and returns nothing.
  func logPendingSendDiagnostics(chatId: String, pendingMessageIds: [String]) {
    guard !pendingMessageIds.isEmpty else { return }
    queue.async { [weak self] in
      guard let self else { return }
      let queued = Set(self.pendingOutboundQueueByChat[chatId] ?? [])
      var withDraft = 0
      var inReplayQueue = 0
      var orphaned: [String] = []
      for id in pendingMessageIds {
        if self.pendingOutboundDraftsByMessageId[id] != nil {
          withDraft += 1
        } else {
          orphaned.append(id)
        }
        if queued.contains(id) { inReplayQueue += 1 }
      }
      NSLog(
        "[PendingAudit] chat=%@ pending=%d withDraft=%d inReplayQueue=%d orphaned=%d orphanSample=[%@]",
        String(chatId.prefix(12)), pendingMessageIds.count, withDraft, inReplayQueue,
        orphaned.count,
        orphaned.prefix(6).map { String($0.prefix(12)) }.joined(separator: ","))
      guard !orphaned.isEmpty else { return }
      self.resolveStrandedPendingLocked(chatId: chatId, messageIds: orphaned)
    }
  }

  /// Turns a row that can never send back into a row the user can act on.
  ///
  /// A message renders a pending clock from its stored `status` alone. Whether it will
  /// *actually* send depends on a completely separate thing — an outbound draft. Those
  /// two can disagree, and when they do the row is stranded: a clock forever, no retry,
  /// no error, no way for the user to even know it failed. Device session 2026-08-04
  /// found 512 of them in one chat, every one from a fan-out heal that removed drafts
  /// without correcting statuses.
  ///
  /// Fixing that one site is not enough, which is why this exists separately. Any path
  /// that drops a draft — a heal, a stale-age expiry, a crash between writing the status
  /// and persisting the draft — produces the same stranded row, and new ones can be
  /// written at any time. This is the backstop that makes the *class* of bug
  /// self-correcting rather than the one instance of it: no draft means not queued,
  /// not queued means it is not going to send, and a message that is not going to send
  /// is failed. Failed is honest, shows a Retry, and is recoverable by the user.
  ///
  /// Never sends anything. Re-dispatching messages the user typed weeks ago into a
  /// conversation that has moved on is a worse outcome than showing them as failed.
  private func resolveStrandedPendingLocked(chatId: String, messageIds: [String]) {
    guard !messageIds.isEmpty else { return }
    // Write every status first, notify ONCE at the end.
    //
    // The first version of this posted a `messageStatusChanged` per message, the way
    // every single-message send path does. At 512 messages that is 512 notifications,
    // each one waking `ChatConversationController.engineChanged` into a full
    // `getChatRows` on the main thread. Measured on device 2026-08-04: a **10.11 second**
    // main-thread freeze immediately after the resolve, with the stall sampler naming it
    // outright — `context=ChatConversationController engineChanged
    // reason=messageStatusChanged`, `hint=likely-blocking-wait`. A fix for a stuck clock
    // that freezes the app for ten seconds is not a fix.
    //
    // Per-message notifications are correct for a per-message event. This is a bulk
    // repair, and the list only needs to be told once that it changed.
    for messageId in messageIds {
      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
    }
    // …and again on disk, because the line above only writes memory.
    //
    // `localStatusIndex` is declared `= [:]` and is never restored, so a status written
    // through it survives exactly as long as the process. The row itself renders from
    // the persisted payload's `status` field, which still said `pending`. Device
    // sessions 2026-08-04: the resolve reported "RESOLVED 512" on one launch and then
    // found the identical 512 on the next, because nothing had actually changed —
    // a fix that only repaired the copy nobody reads on cold start.
    let persisted = persistStrandedResolutionLocked(chatId: chatId, messageIds: messageIds)
    appendJournalLocked(
      event: "native-pending-stranded-resolved",
      payload: ["chatId": chatId, "count": messageIds.count])
    postChangeLocked(
      reason: "chatMessageChanged",
      userInfo: ["chatId": chatId, "action": "updated"])
    NSLog(
      "[PendingAudit] chat=%@ RESOLVED %d stranded rows → failed, %d rewritten on disk (no draft existed, so nothing was ever going to send them)",
      String(chatId.prefix(12)), messageIds.count, persisted)
  }

  /// Rewrites the stored `status` of stranded rows so the repair survives a relaunch.
  ///
  /// One batched transaction for the whole set. `upsertMessages` already wraps its
  /// entries in `BEGIN IMMEDIATE`, so 512 rows cost one commit, not 512 — which matters
  /// because this runs on the engine queue and the main thread blocks on that queue
  /// through `syncOnQueue`.
  ///
  /// Returns how many rows were actually rewritten, so the log can distinguish "repaired
  /// on disk" from "said it repaired something".
  private func persistStrandedResolutionLocked(chatId: String, messageIds: [String]) -> Int {
    guard let userId = chatHistoryCacheUserIdLocked(), messageStore.isAvailable else { return 0 }
    let targets = Set(messageIds)
    // A generous read: the stranded set can be anywhere in the transcript, and this runs
    // once per chat open only when there is something wrong to fix.
    let payloads = messageStore.recentMessagePayloads(
      userId: userId, chatId: chatId, limit: max(targets.count * 4, 2_000))
    var entries: [(messageId: String, ts: Int64, payload: Data)] = []
    entries.reserveCapacity(targets.count)
    for data in payloads {
      guard
        var row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let messageId = messageId(fromRow: row),
        targets.contains(messageId)
      else { continue }
      // The row shape is nested exactly as the list reads it — the status the bubble
      // renders lives at `message.status`, not at the top level. Writing the top-level
      // key instead would leave the clock on screen while the log claimed a repair.
      if var message = row["message"] as? [String: Any] {
        message["status"] = "error"
        row["message"] = message
      } else {
        row["status"] = "error"
      }
      guard
        JSONSerialization.isValidJSONObject(row),
        let rewritten = try? JSONSerialization.data(withJSONObject: row, options: [])
      else { continue }
      entries.append((messageId, messageTimestampMs(fromRow: row), rewritten))
    }
    guard !entries.isEmpty else { return 0 }
    messageStore.upsertMessages(userId: userId, chatId: chatId, entries: entries)
    return entries.count
  }

  private func queueOutboundDraftLocked(
    chatId: String, messageId: String, payload: [String: Any], reason: String
  ) {
    if isBuiltInAgentChatId(chatId) {
      pendingOutboundDraftsByMessageId.removeValue(forKey: messageId)
      if var ids = pendingOutboundQueueByChat[chatId] {
        ids.removeAll { $0 == messageId }
        if ids.isEmpty {
          pendingOutboundQueueByChat.removeValue(forKey: chatId)
        } else {
          pendingOutboundQueueByChat[chatId] = ids
        }
      }
      removeMessageIndicesLocked(chatId: chatId, messageId: messageId)
      markLiveMessageDeletedLocked(chatId: chatId, messageId: messageId)
      persistOutboundStateLocked()
      appendJournalLocked(
        event: "native-outgoing-drop",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "reason": "built_in_agent_surface:\(reason)",
        ])
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [], deleted: [messageId], source: "delete")
      return
    }
    var payload = payload
    let isBridgeDraft = bridgeProviderForOutboundDraftLocked(payload, fallbackChatId: chatId) != nil
    if isBridgeDraft {
      // Stamp the (re)queue time — replay refuses bridge drafts older than
      // bridgeQueuedReplayMaxAgeMs. Lives in the draft so it dies with it;
      // bridge drafts are never persisted (see persistOutboundStateLocked).
      payload["__bridgeQueuedAtMs"] = nowMs()
    }
    // Every draft is stamped, bridge or not. An ordinary send that has sat in the
    // queue for hours must not auto-dispatch the moment the blocker clears: the
    // user typed it in a conversation that has since moved on, and delivering it
    // silently later is a worse outcome than showing it as failed. Absent stamp
    // reads as stale — that is deliberate, so drafts persisted before this existed
    // are expired rather than delivered.
    if payload["__queuedAtMs"] == nil {
      payload["__queuedAtMs"] = nowMs()
    }
    pendingOutboundDraftsByMessageId[messageId] = payload
    var ids = pendingOutboundQueueByChat[chatId] ?? []
    if ids.contains(messageId) { return }
    ids.append(messageId)
    pendingOutboundQueueByChat[chatId] = ids
    appendJournalLocked(
      event: "native-outgoing-queued",
      payload: [
        "chatId": chatId,
        "messageId": messageId,
        "reason": reason,
      ])
    persistOutboundStateLocked()
    postChangeLocked(
      reason: "outgoingMessageQueued",
      userInfo: [
        "chatId": chatId,
        "messageId": messageId,
        "reason": reason,
      ])
    // Ordinary messages remain queued and self-heal through reconnect/replay.
    // A slow or absent network is not a terminal send failure. Bridge prompts
    // retain their separate expiry because replaying an old agent run has
    // different side-effect semantics.
    guard isBridgeDraft else { return }
    queue.asyncAfter(deadline: .now() + .milliseconds(queuedOutboundVisibleErrorDelayMs)) { [weak self] in
      guard let self else { return }
      let stillQueued = self.pendingOutboundQueueByChat[chatId]?.contains(messageId) == true
      let stillDrafted = self.pendingOutboundDraftsByMessageId[messageId] != nil
      guard stillQueued && stillDrafted else { return }
      let currentStatus = self.localStatusIndex[chatId]?[messageId]
      if currentStatus == "sent" || currentStatus == "delivered" || currentStatus == "read" {
        return
      }
      let expiredDraft = self.pendingOutboundDraftsByMessageId[messageId] ?? [:]
      let isBridgeDraft =
        self.bridgeProviderForOutboundDraftLocked(expiredDraft, fallbackChatId: chatId) != nil
      self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
      if isBridgeDraft {
        // The user now sees this bridge send as failed — drop it from the queue so
        // a later reconnect can't ghost-dispatch an agent run behind their back.
        // The draft stays (out of the queue it never auto-sends) so tap-to-retry
        // via retryOutgoingMessage still works.
        self.removeQueuedOutboundDraftLocked(chatId: chatId, messageId: messageId, dropDraft: false)
      }
      self.appendJournalLocked(
        event: "native-outgoing-visible-error",
        payload: ["chatId": chatId, "messageId": messageId, "reason": reason]
      )
      self.postChangeLocked(
        reason: "messageStatusChanged",
        userInfo: ["chatId": chatId, "messageId": messageId, "status": "error"]
      )
    }
  }

  private func messagePushFailureReasonLocked(_ payload: [String: Any]) -> String {
    var maps: [[String: Any]] = [payload]
    for key in ["response", "error", "details"] {
      if let nested = payload[key] as? [String: Any] {
        maps.append(nested)
      }
    }
    for map in maps {
      for key in ["reason", "error", "message", "code"] {
        if let value = normalizedString(map[key])?.lowercased(), !value.isEmpty {
          return value
        }
      }
    }
    return "push_error"
  }

  /// Only explicit policy/validation failures stop replay. A bare Phoenix
  /// `status=error` commonly means a stale socket/topic and is recoverable.
  private func isPermanentMessagePushFailureLocked(_ payload: [String: Any]) -> Bool {
    let reason = messagePushFailureReasonLocked(payload)
    let permanentMarkers = [
      "unauthorized", "forbidden", "not_member", "not a member", "blocked",
      "invalid_payload", "invalid message", "invalid_message", "message_too_large",
      "unsupported_type", "chat_disabled", "account_disabled", "permission_denied",
    ]
    return permanentMarkers.contains { reason.contains($0) }
  }

  private func cancelScheduledOutboundReplayLocked(
    messageId: String,
    resetAttempt: Bool
  ) {
    outboundReplayWorkItemsByMessageId.removeValue(forKey: messageId)?.cancel()
    if resetAttempt {
      outboundReplayAttemptsByMessageId.removeValue(forKey: messageId)
    }
  }

  private func scheduleRetryableOutboundReplayLocked(
    chatId: String,
    messageId: String,
    draft: [String: Any],
    reason: String,
    recycleTransport: Bool
  ) {
    upsertLocalStatusLocked(
      chatId: chatId,
      messageId: messageId,
      status: "pending",
      allowDowngrade: true
    )
    queueOutboundDraftLocked(
      chatId: chatId,
      messageId: messageId,
      payload: draft,
      reason: "retryable_\(reason)"
    )

    let attempt = (outboundReplayAttemptsByMessageId[messageId] ?? 0) + 1
    outboundReplayAttemptsByMessageId[messageId] = attempt
    let delay = outboundReplayDelays[
      min(max(0, attempt - 1), outboundReplayDelays.count - 1)]
    cancelScheduledOutboundReplayLocked(messageId: messageId, resetAttempt: false)

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.outboundReplayWorkItemsByMessageId.removeValue(forKey: messageId)
      guard
        self.pendingOutboundQueueByChat[chatId]?.contains(messageId) == true,
        self.pendingOutboundDraftsByMessageId[messageId] != nil
      else { return }
      self.appendJournalLocked(
        event: "native-outgoing-auto-retry",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "attempt": attempt,
          "reason": reason,
        ])
      self.scheduleReplayQueuedOutboundLocked(
        chatId: chatId, trigger: "push_error_backoff")
      self.ensureNativeTransportIfDemandedLocked(trigger: "push_error_backoff")
    }
    outboundReplayWorkItemsByMessageId[messageId] = workItem
    queue.asyncAfter(deadline: .now() + delay, execute: workItem)

    appendJournalLocked(
      event: "native-outgoing-retry-scheduled",
      payload: [
        "chatId": chatId,
        "messageId": messageId,
        "attempt": attempt,
        "delayMs": Int(delay * 1000),
        "reason": reason,
        "recycleTransport": recycleTransport,
      ])
    NSLog(
      "[ChatEngine] send queued for auto-retry chatId=%@ messageId=%@ reason=%@ attempt=%d delayMs=%d recycle=%@",
      chatId, messageId, reason, attempt, Int(delay * 1000),
      recycleTransport ? "Y" : "N")
    postChangeLocked(
      reason: "messageStatusChanged",
      userInfo: [
        "chatId": chatId,
        "messageId": messageId,
        "status": "pending",
      ])

    if recycleTransport, let client = phoenixClient {
      appendJournalLocked(
        event: "native-outgoing-recycle-socket",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "reason": reason,
        ])
      // ChatPhoenixClient.disconnect() is deliberately silent for user-driven
      // shutdowns: it sets `isClosing`, so its delegate never calls onClose.
      // A retry recycle is different. Publish the close into the engine before
      // disconnecting so `connected`, joined topics, and other in-flight pushes
      // are reset/requeued instead of leaving a zombie "open" client whose
      // sendFrame silently returns because its URLSession task is nil.
      handleNativeSocketClosed(
        code: 4001,
        reason: "outbound_recycle:\(reason)"
      )
      DispatchQueue.global(qos: .utility).async {
        client.disconnect()
      }
    }
  }

  private func removeQueuedOutboundDraftLocked(chatId: String, messageId: String, dropDraft: Bool) {
    if var ids = pendingOutboundQueueByChat[chatId] {
      ids.removeAll { $0 == messageId }
      if ids.isEmpty {
        pendingOutboundQueueByChat.removeValue(forKey: chatId)
      } else {
        pendingOutboundQueueByChat[chatId] = ids
      }
    }
    if dropDraft {
      cancelScheduledOutboundReplayLocked(messageId: messageId, resetAttempt: true)
      pendingOutboundDraftsByMessageId.removeValue(forKey: messageId)
    }
    persistOutboundStateLocked()
  }

  /// Ceiling on a single chat's unsent queue before replay refuses to run.
  ///
  /// Generous on purpose — a genuine offline stretch can legitimately bank a lot of
  /// messages, and refusing to send those would be a worse bug than the one this
  /// guards. Nobody types 500 messages into one chat while offline; a queue past this
  /// is a fan-out, not a backlog.
  private static let maxQueuedOutboundReplay = 500

  /// How long a queued send stays eligible for automatic dispatch.
  ///
  /// Past this it fails visibly instead. A send is a promise to deliver soon; a
  /// draft that surfaces hours later arrives in a conversation that has moved on,
  /// and the user has no idea it went. Fifteen minutes covers a tunnel, a lift and
  /// a flaky handover — the cases a queue is actually for.
  private static let queuedOutboundReplayMaxAgeMs = 15 * 60 * 1000

  /// How many drafts a restored queue may keep.
  ///
  /// Strictly **below** ``maxQueuedOutboundReplay`` on purpose. The heal used to
  /// trim to exactly that ceiling, and the replay guard refuses only when the
  /// queue is *past* it — so a healed queue landed on precisely the one size the
  /// runaway guard could never refuse, and replayed all 500 on every trigger. Two
  /// constants that must not be equal, so they are no longer the same constant.
  private static let maxHealedOutboundQueue = 100

  /// Gap between outbox dispatches, per chat.
  ///
  /// The queue drains one draft per tick. 400ms is slow enough that a hundred-draft
  /// backlog is background work the main thread never sees, and fast enough that a
  /// normal offline burst (a handful of messages) is gone before the user notices.
  private static let outboundDrainIntervalMs = 400

  /// Automatic attempts per draft before it is failed rather than retried.
  private static let outboundDrainMaxAttempts = 3

  /// The one draft each chat currently has in flight. The whole no-fan-out property.
  private var outboundDrainInFlightByChat: [String: String] = [:]
  private var outboundDrainAttemptsByMessageId: [String: Int] = [:]

  /// Fails every queued send that has outlived ``queuedOutboundReplayMaxAgeMs``,
  /// across all chats, whether or not a replay runs.
  ///
  /// A pending bubble must always reach a terminal state. Expiry used to live only
  /// inside ``scheduleReplayQueuedOutboundLocked``, which meant three ways to sit
  /// pending forever: no trigger ever fired for that chat; the queue was past
  /// ``maxQueuedOutboundReplay`` so the runaway guard returned before the expiry
  /// ran; or the draft was still listed in `nativePendingMessagePushRefs` and the
  /// loop skipped it. Observed on device 2026-08-03 — a send from 18:36 still
  /// showing the pending clock at 19:32, an hour later, with a newer message in
  /// the same chat already delivered.
  ///
  /// The draft itself is kept, so tap-to-retry still works. Only the promise of
  /// automatic delivery is withdrawn.
  private func expireStaleQueuedOutboundLocked(trigger: String) {
    let now = Int64(nowMs())
    var expiredByChat: [String: [String]] = [:]
    for (chatId, ids) in pendingOutboundQueueByChat {
      for messageId in ids {
        guard let draft = pendingOutboundDraftsByMessageId[messageId] else { continue }
        let queuedAtMs = parseLongValue(draft["__queuedAtMs"]) ?? 0
        // A missing stamp counts as stale: those drafts predate the stamp and are
        // exactly the ones that must never dispatch now.
        guard queuedAtMs <= 0 || now - queuedAtMs > Int64(Self.queuedOutboundReplayMaxAgeMs)
        else { continue }
        expiredByChat[chatId, default: []].append(messageId)
      }
    }
    guard !expiredByChat.isEmpty else { return }
    for (chatId, messageIds) in expiredByChat {
      for messageId in messageIds {
        upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
        removeQueuedOutboundDraftLocked(chatId: chatId, messageId: messageId, dropDraft: false)
      }
      NSLog(
        "[ChatEngine] expireStaleQueuedOutbound chatId=%@ trigger=%@ count=%d — older than %dms, failed instead of left pending",
        String(chatId.prefix(12)), trigger, messageIds.count, Self.queuedOutboundReplayMaxAgeMs)
      appendJournalLocked(
        event: "native-outgoing-queue-expired",
        payload: ["chatId": chatId, "count": messageIds.count, "trigger": trigger])
    }
  }

  private func scheduleReplayQueuedOutboundLocked(chatId: String, trigger: String) {
    if isBuiltInAgentChatId(chatId) {
      dropQueuedOutboundForChatLocked(chatId: chatId, reason: "built_in_agent_replay_\(trigger)")
      return
    }
    let ids = pendingOutboundQueueByChat[chatId] ?? []
    guard !ids.isEmpty else { return }

    // Stale drafts leave before anything is dispatched, on every trigger. A queued send
    // that has outlived the promise is failed visibly, never delivered late.
    expireStaleQueuedOutboundLocked(trigger: trigger)
    // Runaway guard. A replay that re-queues instead of re-sending turns this into an
    // exponential fan-out — measured at 3,310 drafts for one message on 2026-08-03,
    // with the main thread blocked 31s until the watchdog killed the app.
    //
    // The cause of that incident is fixed above (drafts now carry their own id, so a
    // replay is a retry rather than a new send) and the loop edge that drove it is
    // gone. This stays because the failure mode is unrecoverable-by-the-user: the app
    // dies before anyone can open a chat to clear it. A queue this size is a bug, and
    // refusing to replay it keeps the app usable while the log names the chat.
    guard ids.count <= Self.maxQueuedOutboundReplay else {
      NSLog(
        "[ChatEngine] scheduleReplayQueuedOutboundLocked REFUSED chatId=%@ trigger=%@ count=%d — queue past %d, replaying it would fan out",
        chatId, trigger, ids.count, Self.maxQueuedOutboundReplay)
      appendJournalLocked(
        event: "native-outgoing-replay-refused",
        payload: ["chatId": chatId, "count": ids.count, "trigger": trigger])
      return
    }

    NSLog(
      "[ChatEngine] scheduleReplayQueuedOutboundLocked chatId=%@ trigger=%@ count=%d", chatId,
      trigger, ids.count)
    var drafts: [[String: Any]] = []
    var expiredIds: [String] = []
    for messageId in ids {
      if nativePendingMessagePushRefs.values.contains(where: {
        $0.chatId == chatId && $0.messageId == messageId
      }) {
        continue
      }
      guard let draft = pendingOutboundDraftsByMessageId[messageId] else { continue }
      // Expire stale drafts instead of dispatching them.
      //
      // A queued send is a promise to deliver *soon*. Once it has sat for longer
      // than a user would wait, silently delivering it is worse than failing it:
      // the conversation has moved on, and on 2026-08-03 a queue of drafts that
      // had been stuck for a day drained the moment a peer key resolved, sending
      // ~100 duplicates of one message to a real person.
      //
      // A missing stamp counts as stale on purpose — drafts persisted before the
      // stamp existed are exactly the ones that must not be dispatched now. The
      // draft is kept (out of the queue it never auto-sends) so tap-to-retry
      // still works; only the automatic dispatch is refused.
      let queuedAtMs = parseLongValue(draft["__queuedAtMs"]) ?? 0
      if queuedAtMs <= 0 || Int64(nowMs()) - queuedAtMs > Int64(Self.queuedOutboundReplayMaxAgeMs) {
        expiredIds.append(messageId)
        continue
      }
      if let provider = bridgeProviderForOutboundDraftLocked(draft, fallbackChatId: chatId) {
        // Bridge-agent drafts only auto-send while they're fresh (connection
        // warm-up). Anything older — e.g. the app sat backgrounded — fails
        // visibly instead of silently dispatching a stale agent prompt.
        let queuedAtMs = parseLongValue(draft["__bridgeQueuedAtMs"]) ?? 0
        if Int64(nowMs()) - queuedAtMs > Int64(bridgeQueuedReplayMaxAgeMs) {
          markVolatileBridgeSendErrorLocked(
            chatId: chatId,
            messageId: messageId,
            reason: "queued_expired_\(trigger)",
            provider: provider
          )
          continue
        }
      }
      drafts.append(draft)
    }
    if !expiredIds.isEmpty {
      // Out of the queue and visibly failed. Leaving them queued would re-run this
      // check on every trigger forever; marking them `error` is what tells the user
      // these never went, instead of them discovering it when the peer replies to a
      // message from yesterday.
      for messageId in expiredIds {
        upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
        removeQueuedOutboundDraftLocked(chatId: chatId, messageId: messageId, dropDraft: false)
      }
      NSLog(
        "[ChatEngine] scheduleReplayQueuedOutboundLocked EXPIRED chatId=%@ trigger=%@ count=%d — older than %dms, failed instead of sent",
        String(chatId.prefix(12)), trigger, expiredIds.count, Self.queuedOutboundReplayMaxAgeMs)
      appendJournalLocked(
        event: "native-outgoing-replay-expired",
        payload: ["chatId": chatId, "count": expiredIds.count, "trigger": trigger])
    }

    guard !drafts.isEmpty else { return }

    // Resolve the peer key ONCE for the batch, and skip the whole replay if it is
    // not there.
    //
    // Every draft here is a 1:1 send in the same chat, so they share one peer and
    // one key. Without that key not one of them can be sent: each reaches the
    // `missing_friend_key` branch of `sendMessage`, re-queues itself, emits a
    // status change and a delta, and schedules another key fetch. Replaying 500
    // drafts therefore did 500 rounds of that and drained nothing — and since the
    // queue survived, the next trigger did it again. That is the flood that killed
    // the app on 2026-08-03 (`sendMessage queued reason=missing_friend_key` ×500,
    // per trigger, forever).
    //
    // This queue is not drained by replaying it. It is drained when the key lands,
    // and `scheduleFriendPublicKeyFetchLocked` already replays on success — so
    // deferring here loses no send and costs one key resolution instead of 500.
    let hasNonPeerDraft = drafts.contains { draft in
      (draft["isGroup"] as? Bool) == true
        || (draft["isGroupOrChannel"] as? Bool) == true
        || normalizedString(draft["peerAgentId"] ?? draft["peer_agent_id"]) != nil
    }
    if !hasNonPeerDraft, chatId != "saved_messages",
      !isVolatileBridgeAgentChatLocked(chatId: chatId),
      resolveFriendPublicKeyLocked(chatId: chatId, peerUserIdHint: nil) == nil
    {
      NSLog(
        "[ChatEngine] scheduleReplayQueuedOutboundLocked DEFERRED chatId=%@ trigger=%@ count=%d — no peer key; fetching once instead of replaying",
        String(chatId.prefix(12)), trigger, drafts.count)
      appendJournalLocked(
        event: "native-outgoing-replay-deferred",
        payload: ["chatId": chatId, "count": drafts.count, "trigger": trigger])
      scheduleFriendPublicKeyFetchLocked(
        chatId: chatId, peerUserIdHint: nil, trigger: "replay_\(trigger)")
      return
    }

    // ONE draft, oldest first, and nothing else until it settles.
    //
    // This used to dispatch the whole batch in a loop. That is the shape that put 692
    // messages on the server for one send (2026-08-03, chat 176cdf92eec5, a doubling
    // pattern 3, 4, 8, 16, 32, 60, 84): every draft that failed on a missing key
    // re-queued itself, each re-queue fired another trigger, and each trigger replayed
    // the whole grown batch again. A loop over a queue that a failure can grow is a
    // multiplier no per-draft bound can make safe.
    //
    // Serial drain cannot multiply. The head of the queue is dispatched, the rest wait,
    // and the next tick is scheduled on a timer rather than on the result — so a draft
    // that fails and re-queues occupies the same one slot it already had instead of
    // adding one. A hundred-draft backlog drains in a hundred ticks of background work
    // and is invisible to the main thread, which is the other half of what a queue this
    // size has to guarantee.
    guard outboundDrainInFlightByChat[chatId] == nil else { return }
    guard let draft = drafts.first,
      let draftId = normalizedString(draft["messageId"] ?? draft["message_id"])
    else { return }

    // A draft that will not go is failed rather than retried forever. Without this a
    // permanently unsendable message (revoked key, deleted peer) reoccupies the drain
    // slot on every trigger and no other queued message ever gets a turn.
    let attempts = (outboundDrainAttemptsByMessageId[draftId] ?? 0) + 1
    outboundDrainAttemptsByMessageId[draftId] = attempts
    guard attempts <= Self.outboundDrainMaxAttempts else {
      NSLog(
        "[ChatEngine] outbox EXHAUSTED chatId=%@ id=%@ attempts=%d — failed instead of retried",
        String(chatId.prefix(12)), String(draftId.suffix(12)), attempts)
      upsertLocalStatusLocked(chatId: chatId, messageId: draftId, status: "error")
      removeQueuedOutboundDraftLocked(chatId: chatId, messageId: draftId, dropDraft: false)
      outboundDrainAttemptsByMessageId.removeValue(forKey: draftId)
      return
    }

    outboundDrainInFlightByChat[chatId] = draftId
    NSLog(
      "[ChatEngine] outbox DRAIN chatId=%@ id=%@ attempt=%d queued=%d trigger=%@",
      String(chatId.prefix(12)), String(draftId.suffix(12)), attempts, drafts.count, trigger)
    appendJournalLocked(
      event: "native-outgoing-replay-scheduled",
      payload: [
        "chatId": chatId,
        "count": drafts.count,
        "trigger": trigger,
        "messageId": draftId,
        "attempt": attempts,
      ])
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      _ = self.sendMessage(draft)
      // Paced, not immediate: the interval is what turns a backlog into background
      // work instead of a burst, and what keeps a draft that instantly re-queues from
      // spinning this loop at full speed.
      self.queue.asyncAfter(deadline: .now() + .milliseconds(Self.outboundDrainIntervalMs)) {
        [weak self] in
        guard let self else { return }
        // Cleared here rather than on the send's result: a send has several ways to
        // end (ack, error, silent re-queue) and a slot released on only some of them
        // is a queue that wedges on the others.
        self.outboundDrainInFlightByChat.removeValue(forKey: chatId)
        // Delivered — forget the attempt count so a future send of a *different*
        // message is not judged by this one's history.
        if !(self.pendingOutboundQueueByChat[chatId]?.contains(draftId) ?? false) {
          self.outboundDrainAttemptsByMessageId.removeValue(forKey: draftId)
        }
        self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "drain_tick")
      }
    }
  }

  /// Gives an orphaned pending bubble a terminal state.
  ///
  /// A message can show the pending clock with **no draft behind it**: the queue entry
  /// was consumed, dropped or never restored, while `localStatusIndex` still says
  /// `sending`. Nothing then ever moves it — expiry walks the queue, and the queue no
  /// longer knows about this message. That is how a screen full of "Test" from
  /// yesterday still showed the clock today, hours after every retry path had given up
  /// on it.
  ///
  /// Cheap by construction: one pass over `localStatusIndex`, which holds only messages
  /// with a non-terminal local status, and only entries past the age limit are touched.
  /// Reconstruct a send payload for a message that is still in the transcript but whose
  /// outbound draft no longer exists.
  ///
  /// Only ever produces a plain text send. Media messages carry local file references and
  /// sealed blobs that may no longer be on disk, and a re-send that quietly drops the
  /// attachment would be a worse outcome than refusing — so those return nil and the
  /// caller reports the refusal.
  private func rebuildOutboundDraftFromStoredRowLocked(
    chatId: String?, messageId targetMessageId: String
  ) -> [String: Any]? {
    // Named `targetMessageId` so the `messageId(fromRow:)` helper below is still callable
    // — a parameter called `messageId` shadows it into a String.
    let messageId = targetMessageId
    let resolvedChatId: String? = {
      if let chatId, !chatId.isEmpty { return chatId }
      return liveMessageRowsByChat.first(where: { $0.value[messageId] != nil })?.key
    }()
    guard let resolvedChatId, !resolvedChatId.isEmpty else { return nil }
    // Live rows first, then history — and history is where these actually are.
    //
    // `liveMessageRowsByChat` holds this session's traffic. A stranded send is by
    // definition from an earlier session, so it has long since moved into the history
    // rows, and looking only at the live table refused every message a person would ever
    // want to retry (`retry REFUSED … no re-sendable row`, on messages plainly visible in
    // the transcript).
    let row: [String: Any]? =
      liveMessageRowsByChat[resolvedChatId]?[messageId]
      ?? (historyRowsByChat[resolvedChatId] ?? []).first {
        self.messageId(fromRow: $0) == targetMessageId
      }
    guard let row else { return nil }
    // Rows are envelopes: `["kind": "message", "key": …, "message": [ … ]]`. Reading
    // `isMe` / `text` / `type` off the outer dictionary finds nothing at all, which is a
    // silent refusal rather than an error — every field comes back nil and the guards
    // below decline a message that was perfectly re-sendable.
    guard let message = row["message"] as? [String: Any] else { return nil }
    guard (message["isMe"] as? Bool) ?? false else { return nil }
    let type = normalizedString(message["type"] ?? message["messageType"]) ?? "text"
    guard type == "text" else { return nil }
    let text = normalizedString(message["text"] ?? message["content"]) ?? ""
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    var draft: [String: Any] = [
      "chatId": resolvedChatId,
      "messageId": messageId,
      "text": text,
      "type": "text",
    ]
    if let replyToId = normalizedString(row["replyToId"] ?? row["reply_to_id"]) {
      draft["replyToId"] = replyToId
    }
    if let peerUserId = chatPeerUserIdsByChatId[resolvedChatId] {
      draft["peerUserId"] = peerUserId
    }
    return draft
  }

  private func sweepOrphanedPendingLocked(trigger: String) {
    let now = Int64(nowMs())
    var strandedByChat: [String: [String]] = [:]
    for (chatId, statuses) in localStatusIndex {
      for (messageId, status) in statuses where status == "sending" || status == "pending" {
        // Still queued, or a push is genuinely in flight — the normal paths own it.
        if pendingOutboundQueueByChat[chatId]?.contains(messageId) == true { continue }
        if nativePendingMessagePushRefs.values.contains(where: {
          $0.chatId == chatId && $0.messageId == messageId
        }) { continue }
        // Age from the row itself: an orphan has no draft, so there is no
        // `__queuedAtMs` to read.
        let tsMs = liveMessageRowsByChat[chatId]?[messageId].flatMap {
          parseLongValue($0["timestampMs"] ?? $0["timestamp_ms"])
        } ?? 0
        guard tsMs <= 0 || now - tsMs > Int64(Self.queuedOutboundReplayMaxAgeMs) else { continue }
        strandedByChat[chatId, default: []].append(messageId)
      }
    }
    guard !strandedByChat.isEmpty else { return }
    for (chatId, messageIds) in strandedByChat {
      for messageId in messageIds {
        upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
      }
      NSLog(
        "[ChatEngine] outbox STRANDED chatId=%@ trigger=%@ count=%d — pending with no draft, failed so it can be retried",
        String(chatId.prefix(12)), trigger, messageIds.count)
      appendJournalLocked(
        event: "native-outgoing-stranded-swept",
        payload: ["chatId": chatId, "count": messageIds.count, "trigger": trigger])
    }
  }

  private func chatTopic(for chatId: String) -> String {
    "chat:\(chatId)"
  }

  private struct LocalMediaUploadResult {
    let remoteUrl: String
    let fileName: String?
    let fileSize: Int64?
    let mediaKey: String?
  }

  private struct LocalMediaUploadOutcome {
    let result: LocalMediaUploadResult?
    let reason: String?
  }

  private struct LocalMediaPreparationFailure: Error {
    let reason: String
  }

  private struct PreparedLocalMediaUpload {
    let fileData: Data
    let fileName: String
    let mimeType: String

    var fileSize: Int64 {
      Int64(fileData.count)
    }
  }

  private let packetMeshMaxVoiceUploadBytes = 2 * 1024 * 1024
  private let packetMeshMaxImageUploadBytes = 384 * 1024
  private let packetMeshImageMaxDimensions: [CGFloat] = [1440, 1280, 960, 768]
  private let packetMeshImageQualities: [CGFloat] = [0.82, 0.72, 0.62, 0.52, 0.45]

  private func isLocalMediaURI(_ raw: String) -> Bool {
    raw.hasPrefix("file://") || raw.hasPrefix("/") || raw.hasPrefix("content://")
  }

  private func prepareLocalMediaUploadLocked(
    fileData: Data,
    normalizedURL: URL,
    messageType: String,
    fileNameHint: String?
  ) -> Result<PreparedLocalMediaUpload, LocalMediaPreparationFailure> {
    let resolvedFileName = fileNameHint ?? normalizedURL.lastPathComponent
    let transportMode = syncOnQueue { transportModeLocked() }

    if transportMode != "packet_mesh" {
      return .success(
        PreparedLocalMediaUpload(
          fileData: fileData,
          fileName: resolvedFileName,
          mimeType: mediaMimeType(fileName: resolvedFileName, fallbackType: messageType)
        )
      )
    }

    switch messageType {
    case "voice":
      guard fileData.count <= packetMeshMaxVoiceUploadBytes else {
        return .failure(LocalMediaPreparationFailure(reason: "packet_mesh_voice_too_large"))
      }
      return .success(
        PreparedLocalMediaUpload(
          fileData: fileData,
          fileName: resolvedFileName,
          mimeType: mediaMimeType(fileName: resolvedFileName, fallbackType: messageType)
        )
      )
    case "image":
      return preparePacketMeshImageUploadLocked(
        fileData: fileData,
        normalizedURL: normalizedURL,
        fileNameHint: fileNameHint
      )
    default:
      return .failure(LocalMediaPreparationFailure(reason: "packet_mesh_type_blocked"))
    }
  }

  private func preparePacketMeshImageUploadLocked(
    fileData: Data,
    normalizedURL: URL,
    fileNameHint: String?
  ) -> Result<PreparedLocalMediaUpload, LocalMediaPreparationFailure> {
    guard let image = UIImage(data: fileData) else {
      return .failure(LocalMediaPreparationFailure(reason: "packet_mesh_image_decode_failed"))
    }

    let rawBaseName = (
      fileNameHint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? fileNameHint!
      : normalizedURL.deletingPathExtension().lastPathComponent
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let strippedBaseName = (rawBaseName as NSString).deletingPathExtension
    let baseName = strippedBaseName.isEmpty ? "packet-image" : strippedBaseName

    for maxDimension in packetMeshImageMaxDimensions {
      guard let renderedImage = packetMeshRenderedImage(image, maxDimension: maxDimension) else {
        continue
      }
      for quality in packetMeshImageQualities {
        guard let jpegData = renderedImage.jpegData(compressionQuality: quality) else {
          continue
        }
        if jpegData.count <= packetMeshMaxImageUploadBytes {
          return .success(
            PreparedLocalMediaUpload(
              fileData: jpegData,
              fileName: "\(baseName).jpg",
              mimeType: "image/jpeg"
            )
          )
        }
      }
    }

    return .failure(LocalMediaPreparationFailure(reason: "packet_mesh_image_too_large"))
  }

  private func packetMeshRenderedImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
    let sourceSize = image.size
    guard sourceSize.width > 0, sourceSize.height > 0 else {
      return nil
    }

    let longestSide = max(sourceSize.width, sourceSize.height)
    let scale = min(1.0, maxDimension / longestSide)
    let targetSize = CGSize(
      width: max(1.0, floor(sourceSize.width * scale)),
      height: max(1.0, floor(sourceSize.height * scale))
    )

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true

    return UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: targetSize))
      image.draw(in: CGRect(origin: .zero, size: targetSize))
    }
  }

  private func uploadCategory(for messageType: String) -> String {
    switch messageType {
    case "image", "gif":
      return "image"
    case "voice", "music":
      return "audio"
    case "video":
      return "video"
    default:
      return "file"
    }
  }

  private func shouldEncryptUploadedMediaType(_ messageType: String) -> Bool {
    switch messageType {
    case "image", "gif", "voice", "music", "video", "file", "sticker":
      return true
    default:
      return false
    }
  }

  private func mediaMimeType(fileName: String, fallbackType: String) -> String {
    let ext = (fileName as NSString).pathExtension.lowercased()
    if !ext.isEmpty {
      switch ext {
      case "jpg", "jpeg":
        return "image/jpeg"
      case "png":
        return "image/png"
      case "gif":
        return "image/gif"
      case "webp":
        return "image/webp"
      case "heic":
        return "image/heic"
      case "m4a":
        return "audio/mp4"
      case "mp3":
        return "audio/mpeg"
      case "wav":
        return "audio/wav"
      case "aac":
        return "audio/aac"
      case "mp4":
        return "video/mp4"
      case "mov":
        return "video/quicktime"
      default:
        break
      }
    }
    switch fallbackType {
    case "image", "gif":
      return "image/jpeg"
    case "voice", "music":
      return "audio/mp4"
    case "video":
      return "video/mp4"
    default:
      return "application/octet-stream"
    }
  }

  private func resolveUploadURL(apiBase: URL) -> URL? {
    var base = apiBase.absoluteString
    while base.hasSuffix("/") {
      base.removeLast()
    }
    if base.hasSuffix("/api") {
      base = String(base.dropLast(4))
    }
    return URL(string: base + "/api/media/upload")
  }

  private func localFileURL(from rawURI: String) -> URL? {
    if rawURI.hasPrefix("file://"), let url = URL(string: rawURI), url.isFileURL {
      return url
    }
    if rawURI.hasPrefix("/") {
      return URL(fileURLWithPath: rawURI)
    }
    return nil
  }

  private func appendMultipartField(body: inout Data, boundary: String, name: String, value: String)
  {
    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append(
      "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8) ?? Data())
    body.append("\(value)\r\n".data(using: .utf8) ?? Data())
  }

  fileprivate class UploadSessionDelegate: PinnedSessionDelegate, URLSessionTaskDelegate,
    URLSessionDataDelegate
  {
    var onProgress: ((Float) -> Void)?
    var onCompletion: ((Data?, HTTPURLResponse?, Error?) -> Void)?
    var responseData = Data()
    private var lastEmitTime: TimeInterval = 0
    private var lastEmittedProgress: Float = 0
    private let activityLock = NSLock()
    private var lastActivityTime: TimeInterval = CACurrentMediaTime()

    /// When bytes last moved, read from the waiting thread to tell a slow upload
    /// (still sending — keep waiting) apart from a dead one (nothing for seconds).
    var lastActivityAt: TimeInterval {
      activityLock.lock()
      defer { activityLock.unlock() }
      return lastActivityTime
    }

    private func markActivity() {
      activityLock.lock()
      lastActivityTime = CACurrentMediaTime()
      activityLock.unlock()
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
      totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
      markActivity()
      guard totalBytesExpectedToSend > 0 else { return }
      let progress = Float(totalBytesSent) / Float(totalBytesExpectedToSend)
      let now = CACurrentMediaTime()
      // Ticks are not free: each one wakes the engine queue, writes the row and
      // repaints the cell. The old rule emitted on a 30 Hz timer REGARDLESS of
      // whether the fraction had moved, so a fast upload could fire dozens of
      // identical repaints. Emit on real movement (2%), on a 200ms floor when the
      // bar is still creeping, and always on completion.
      let advanced = progress > lastEmittedProgress
      let shouldEmit =
        progress >= 0.999
        || progress <= 0.0
        || (progress - lastEmittedProgress) >= 0.02
        || (advanced && (now - lastEmitTime) >= 0.2)
      if shouldEmit {
        lastEmitTime = now
        lastEmittedProgress = progress
        onProgress?(progress)
      }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      markActivity()
      responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
      onCompletion?(responseData, task.response as? HTTPURLResponse, error)
    }
  }

  private func uploadLocalMediaLocked(
    localUri: String,
    messageType: String,
    fileNameHint: String?,
    userId: String,
    token: String,
    apiBase: URL,
    messageId: String? = nil,
    onProgress: ((Float) -> Void)? = nil
  ) -> LocalMediaUploadOutcome {
    guard let fileURL = localFileURL(from: localUri) else {
      return LocalMediaUploadOutcome(result: nil, reason: "invalid_local_media_uri")
    }
    let normalizedURL = fileURL.standardizedFileURL
    guard FileManager.default.fileExists(atPath: normalizedURL.path) else {
      return LocalMediaUploadOutcome(result: nil, reason: "media_file_missing")
    }
    let fileData: Data
    do {
      fileData = try Data(contentsOf: normalizedURL, options: [.mappedIfSafe])
    } catch {
      return LocalMediaUploadOutcome(result: nil, reason: "media_file_read_failed")
    }
    let preparedUpload: PreparedLocalMediaUpload
    switch prepareLocalMediaUploadLocked(
      fileData: fileData,
      normalizedURL: normalizedURL,
      messageType: messageType,
      fileNameHint: fileNameHint
    ) {
    case .success(let value):
      preparedUpload = value
    case .failure(let error):
      return LocalMediaUploadOutcome(result: nil, reason: error.reason)
    }
    let preparedFileSize = preparedUpload.fileSize
    let resolvedFileName = preparedUpload.fileName
    let resolvedMimeType = preparedUpload.mimeType
    let uploadType = uploadCategory(for: messageType)
    guard let uploadURL = resolveUploadURL(apiBase: apiBase) else {
      return LocalMediaUploadOutcome(result: nil, reason: "invalid_upload_url")
    }
    let uploadFileData: Data
    let mediaKey: String?
    if shouldEncryptUploadedMediaType(messageType) {
      do {
        let encrypted = try chatEngineEncryptMediaData(preparedUpload.fileData)
        uploadFileData = encrypted.encryptedData
        mediaKey = encrypted.keyBase64
      } catch {
        return LocalMediaUploadOutcome(result: nil, reason: "media_encrypt_failed")
      }
    } else {
      uploadFileData = preparedUpload.fileData
      mediaKey = nil
    }

    let boundary = "----VibeChatBoundary\(UUID().uuidString)"
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "POST"
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 35

    var body = Data()
    appendMultipartField(body: &body, boundary: boundary, name: "user_id", value: userId)
    appendMultipartField(body: &body, boundary: boundary, name: "type", value: uploadType)
    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append(
      "Content-Disposition: form-data; name=\"file\"; filename=\"\(resolvedFileName)\"\r\n".data(
        using: .utf8) ?? Data())
    body.append("Content-Type: \(resolvedMimeType)\r\n\r\n".data(using: .utf8) ?? Data())
    body.append(uploadFileData)
    body.append("\r\n".data(using: .utf8) ?? Data())
    body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())
    let delegate = UploadSessionDelegate()
    delegate.onProgress = onProgress

    let semaphore = DispatchSemaphore(value: 0)
    var responseData: Data?
    var responseCode: Int?
    var responseError: Error?

    delegate.onCompletion = { data, res, error in
      if let error {
        responseError = error
      }
      responseCode = res?.statusCode
      responseData = data
      semaphore.signal()
    }

    let session = ChatPhoenixClient.makePinnedURLSession(delegate: delegate)
    let task = session.uploadTask(with: request, from: body)
    if let messageId, !messageId.isEmpty {
      syncOnQueue {
        activeMediaUploadTasksByMessageId[messageId] = task
      }
    }
    let wireStartedAt = ProcessInfo.processInfo.systemUptime
    task.resume()
    // Wait for as long as bytes keep moving. The old fixed 40s wall-clock cap was a
    // hard ceiling on FILE SIZE, not on failure: this 5.9 MB audio took 25s on a
    // contended link, so anything appreciably larger (any video) was cancelled as
    // "upload_timeout" while it was still uploading fine. Bail only when the
    // transfer has genuinely stalled — no body bytes and no response bytes for
    // `uploadStallTimeout` — which is the condition that actually means dead.
    let uploadStallTimeout: TimeInterval = 30
    var waitResult: DispatchTimeoutResult = .timedOut
    while true {
      if semaphore.wait(timeout: .now() + 2.0) == .success {
        waitResult = .success
        break
      }
      if CACurrentMediaTime() - delegate.lastActivityAt >= uploadStallTimeout {
        NSLog(
          "[MediaUpload] STALLED %@ bytes=%d elapsed=%.1fs idle>=%.0fs — cancelling",
          messageType, body.count,
          ProcessInfo.processInfo.systemUptime - wireStartedAt, uploadStallTimeout)
        break
      }
    }
    // The one number that says whether a slow upload is the link or the app.
    // Compare it against what the same device gets on a speed test: if they match,
    // the wire is the limit; if the app is far below, something on device is
    // stealing the pipe (that is exactly how the Home-refetch storm was found).
    let wireSeconds = max(0.001, ProcessInfo.processInfo.systemUptime - wireStartedAt)
    NSLog(
      "[MediaUpload] %@ bytes=%d wire=%.2fs throughput=%.0fKB/s result=%@",
      messageType, body.count, wireSeconds,
      Double(body.count) / 1024.0 / wireSeconds,
      waitResult == .timedOut ? "timeout" : "done")
    if waitResult == .timedOut {
      task.cancel()
      if let messageId, !messageId.isEmpty {
        syncOnQueue {
          if activeMediaUploadTasksByMessageId[messageId] === task {
            activeMediaUploadTasksByMessageId.removeValue(forKey: messageId)
          }
        }
      }
      return LocalMediaUploadOutcome(result: nil, reason: "upload_timeout")
    }
    if let messageId, !messageId.isEmpty {
      syncOnQueue {
        if activeMediaUploadTasksByMessageId[messageId] === task {
          activeMediaUploadTasksByMessageId.removeValue(forKey: messageId)
        }
      }
    }
    if
      let nsError = responseError as NSError?,
      nsError.domain == NSURLErrorDomain,
      nsError.code == NSURLErrorCancelled
    {
      return LocalMediaUploadOutcome(result: nil, reason: "upload_canceled")
    }
    if responseError != nil {
      return LocalMediaUploadOutcome(result: nil, reason: "upload_failed")
    }
    guard let responseCode, (200...299).contains(responseCode), let responseData else {
      return LocalMediaUploadOutcome(result: nil, reason: "upload_failed")
    }
    guard
      let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
      let remoteUrl = normalizedString(json["url"] ?? json["mediaUrl"] ?? json["media_url"])
    else {
      return LocalMediaUploadOutcome(result: nil, reason: "invalid_upload_response")
    }
    return LocalMediaUploadOutcome(
      result: LocalMediaUploadResult(
        remoteUrl: remoteUrl,
        fileName: resolvedFileName,
        fileSize: preparedFileSize,
        mediaKey: mediaKey),
      reason: nil
    )
  }

  /// Publishes this device's KeyPackages and applies any Welcome waiting for it,
  /// so a peer can start an encrypted conversation with us and we can join one
  /// they started.
  ///
  /// Deliberately **not** gated on `isSendEnabled`. Publishing and joining are
  /// the receive side: a device that cannot be added to a group cannot be sent
  /// to at all, so this has to work even on an install that is not sealing its
  /// own outbound messages yet.
  ///
  /// Both halves are cheap no-ops when there is nothing to do (a count check
  /// and an empty list), which is why this can hang off chat join rather than
  /// needing a lifecycle event of its own. Throttled because chat join fires
  /// once per open chat on every reconnect.
  /// Asks whether this chat's peer applied our Welcome, so the send path knows
  /// whether sealing is safe yet.
  ///
  /// Per-chat, unlike `ensureMlsProvisionedLocked`, because the answer is about
  /// one conversation's peer rather than about this device. Cheap and one-way:
  /// it returns immediately once confirmed and never un-confirms, so a bad
  /// network cannot silently downgrade an established chat.
  private func refreshMlsPeerConfirmationLocked(chatId: String) {
    guard VibeSecureSessions.isSendEnabled else { return }
    guard !VibeSecureSessions.shared.isPeerConfirmed(chatId: chatId) else { return }
    guard let apiBase = apiBaseURLLocked() else { return }
    VibeSecureEstablishment.refreshPeerConfirmation(
      chatId: chatId, apiBase: apiBase, token: authHeaderTokenLocked())
  }

  private func ensureMlsProvisionedLocked(trigger: String) {
    let now = Int64(nowMs())
    if mlsProvisionedAtMs != 0, now - mlsProvisionedAtMs < 60_000 { return }
    guard let apiBase = apiBaseURLLocked() else { return }
    let token = authHeaderTokenLocked()
    mlsProvisionedAtMs = now
    VibeSecureEstablishment.ensureKeyPackagesPublished(apiBase: apiBase, token: token)
    VibeSecureEstablishment.drainPendingWelcomes(apiBase: apiBase, token: token) {
      [weak self] joinedChatIds in
      guard let self = self, !joinedChatIds.isEmpty else { return }
      self.queue.async {
        for chatId in joinedChatIds {
          self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "mls_welcome_drained")
          // Anything the peer sent between adding us and this drain was parsed
          // without a session and stored as decryption-failed. The ciphertext is
          // still good and we can read it *now*, but nothing re-parses a row that
          // already resolved — so those messages would stay stuck on the failure
          // placeholder for the life of the install. Re-fetch and re-parse them.
          //
          // The heights cached for those rows describe the placeholder, not the
          // real text, so they have to go too or the transcript sizes itself
          // against content it is about to replace.
          VibeTimelinePreparedStore.shared.invalidate(chatId: chatId)
          self.loadChatHistoryIfNeededLocked(chatId: chatId, force: true)
        }
      }
    }
  }

  private func apiBaseURLLocked() -> URL? {
    if let configured = normalizedString(
      getConfigValueLocked("apiBaseUrl") ?? getConfigValueLocked("baseUrl")),
      let url = URL(string: configured)
    {
      return url
    }
    guard
      let socketUrl = normalizedString(
        getConfigValueLocked("socketUrl") ?? getConfigValueLocked("url")),
      var components = URLComponents(string: socketUrl)
    else { return nil }
    if components.scheme == "wss" { components.scheme = "https" }
    if components.scheme == "ws" { components.scheme = "http" }
    if components.path.hasSuffix("/socket") {
      components.path = String(components.path.dropLast("/socket".count))
    }
    return components.url
  }

  private func originString(from base: URL) -> String? {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { return nil }
    return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func sanitizeOpenURLString(_ raw: String) -> String {
    let trimmed =
      raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

    return
      trimmed
      .replacingOccurrences(
        of: #"^https?:\/\/\[(https?:\/\/[^\]]+)\](\/.*)?$"#,
        with: "$1$2",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: #"^\[(https?:\/\/[^\]]+)\](\/.*)?$"#,
        with: "$1$2",
        options: .regularExpression
      )
      .replacingOccurrences(of: "https://https://", with: "https://")
      .replacingOccurrences(of: "http://http://", with: "http://")
  }

  private func resolveURLForOpenLocked(_ raw: String?) -> String? {
    guard let raw = normalizedString(raw), !raw.isEmpty else { return nil }
    let sanitized = sanitizeOpenURLString(raw)
    guard !sanitized.isEmpty else { return nil }

    if let url = URL(string: sanitized), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https" || scheme == "file"
    {
      return url.absoluteString
    }

    if sanitized.hasPrefix("/uploads/") || sanitized.hasPrefix("uploads/"),
      let base = apiBaseURLLocked(),
      let origin = originString(from: base)
    {
      let path = sanitized.hasPrefix("/") ? sanitized : "/" + sanitized
      return origin + path
    }

    if sanitized.hasPrefix("/"), let base = apiBaseURLLocked(),
      let origin = originString(from: base)
    {
      return origin + sanitized
    }

    return sanitized
  }

  private func authHeaderTokenLocked() -> String? {
    normalizedString(getConfigValueLocked("authToken") ?? getConfigValueLocked("token"))
  }

  private func chatHistoryCacheUserIdLocked() -> String? {
    normalizedString(configuredUserId)
      ?? normalizedString(getConfigValueLocked("userId") ?? getConfigValueLocked("myUserId"))
  }

  private func chatHistoryCacheKeyLocked(chatId: String) -> String? {
    guard let userId = chatHistoryCacheUserIdLocked(), !chatId.isEmpty else { return nil }
    return "\(chatHistoryCacheKeyPrefix).\(cacheKeyComponent(userId)).\(cacheKeyComponent(chatId))"
  }

  /// Live stream placeholder rows (`stream-…` / `lan-…` ids) are transient render
  /// state: their run either settles into a real message or dies with the socket.
  /// Persisting them poisons the cache — on the next open they resurrect as
  /// orphan plain-text bubbles that duplicate the settled card (with no sender
  /// meta, so they even group under the wrong agent name).
  /// `bridge-…` ids are session-transcript MIRRORS: the bridge ingest re-emits a
  /// prompt/turn the server already persists as a canonical row (the merge dedups the
  /// pair at paint). Persisting the mirror would seed the durable store with synthetic
  /// twins — and, when a History session is mounted, leak that old session's rows into
  /// the DM's durable transcript. The store holds server truth only.
  private func isTransientStreamRow(_ row: [String: Any]) -> Bool {
    guard let id = messageId(fromRow: row) else { return false }
    return id.hasPrefix("stream-") || id.hasPrefix("lan-") || id.hasPrefix("bridge-")
  }

  // MARK: - Agent/bridge DM volatility (empty on cold launch, live only within a run)

  private func loadAgentDMChatIdsIfNeededLocked() {
    guard !agentDMChatIdsLoaded else { return }
    agentDMChatIdsLoaded = true
    if let stored = UserDefaults.standard.array(forKey: Self.agentDMChatIdsDefaultsKey)
      as? [String]
    {
      agentDMChatIdsPersisted = Set(stored.filter { !$0.isEmpty })
    }
  }

  /// True when `chatId` is a bridge/agent DM whose transcript must NOT survive a process
  /// kill. Combines the durable stamped set (reliable at cold launch, when the peer maps
  /// are empty) with the live provider resolution (reliable once maps are populated).
  private func isAgentDMForPersistenceLocked(chatId: String) -> Bool {
    guard !chatId.isEmpty else { return false }
    loadAgentDMChatIdsIfNeededLocked()
    if agentDMChatIdsPersisted.contains(chatId) { return true }
    return isVolatileBridgeAgentChatLocked(chatId: chatId)
  }

  /// Remember that `chatId` is an agent DM so future cold launches skip its durable
  /// transcript without needing the peer→provider maps. Stamped at every point a provider
  /// resolves during a run; the write is tiny and rare (once per new chat).
  private func markAgentDMChatForPersistenceLocked(chatId: String) {
    guard !chatId.isEmpty else { return }
    loadAgentDMChatIdsIfNeededLocked()
    guard !agentDMChatIdsPersisted.contains(chatId) else { return }
    agentDMChatIdsPersisted.insert(chatId)
    UserDefaults.standard.set(
      Array(agentDMChatIdsPersisted), forKey: Self.agentDMChatIdsDefaultsKey)
  }

  /// Delete an agent DM's durable-era transcript exactly once per run — from SQLite AND
  /// from memory. Reuses clearCachedHistoryRowsLocked (which logs the WIPE + clears the
  /// legacy blob) for disk, then drops the in-memory pile so the transition run (the first
  /// launch after this build ships, when an early restore loaded the pile before the
  /// provider resolved) stops re-seeding those rows every time the chat opens.
  private func purgeAgentDMDurableStoreIfNeededLocked(chatId: String) {
    guard !chatId.isEmpty, !agentDMStorePurgedChats.contains(chatId) else { return }
    agentDMStorePurgedChats.insert(chatId)
    clearCachedHistoryRowsLocked(chatId: chatId)
    // Bridge DMs never populate historyRowsByChat except via restore (server-load +
    // backfill are gated for them), so the pile here is exactly the stale durable
    // transcript — the live session lives in liveMessageRowsByChat and is untouched.
    guard let existing = historyRowsByChat[chatId], !existing.isEmpty else { return }
    let removedIds = existing.compactMap { messageId(fromRow: $0) }
    historyRowsByChat.removeValue(forKey: chatId)
    historyFullyLoadedChats.remove(chatId)
    historyRowsRestoredFromCacheChats.remove(chatId)
    NSLog(
      "[HistoryStore] agent-DM drop in-memory chat=%@ rows=%d (volatile-per-session)",
      String(chatId.prefix(12)), existing.count)
    postChatDeltaLocked(
      chatId: chatId, inserted: [], updated: [], deleted: removedIds, source: "agentDMPurge")
  }

  private func restoreCachedHistoryRowsLocked(chatId: String) -> Bool {
    guard !chatId.isEmpty else { return false }
    // Agent/bridge DMs are volatile-per-session: never paint a persisted transcript on a
    // cold launch. Fast path when we already know (stamped set, or provider resolves).
    // Their in-session rows live in historyRowsByChat/liveMessageRowsByChat (in-memory)
    // + the launch-purged VibeBridgeRows cache — untouched here — so a warm reopen inside
    // a run still shows the ongoing session; only the DISK transcript stays empty.
    if isAgentDMForPersistenceLocked(chatId: chatId) {
      purgeAgentDMDurableStoreIfNeededLocked(chatId: chatId)
      return false
    }
    // NORMAL chats restore their settled, server-canonical transcript here so a cold open
    // paints offline. (Agent DMs are handled by the volatile fast-path above — they were
    // briefly made durable like normal chats, but that caused a cold-launch flicker where
    // the persisted transcript painted and then the volatile session layer wiped it, so
    // they are volatile-per-session again.)
    // The in-memory entry only counts as "already restored" when it actually HOLDS rows.
    // An EMPTY array here is a poison pill: a background history load whose server page
    // came back with zero rows installs `[]` plus the fullyLoaded flag, and from then on
    // every restore for this chat short-circuits `true` WITHOUT ever reading SQLite. A
    // chat with a full transcript on disk then paints EMPTY for the rest of the run —
    // and again after every relaunch, because the same background load repeats. Falling
    // through on empty costs one bounded (120-row) SQLite read.
    if let existing = historyRowsByChat[chatId], !existing.isEmpty,
      historyFullyLoadedChats.contains(chatId)
    {
      return true
    }
    // Known-empty store: an empty chat's open path calls restore from several places
    // (engine bind, refreshRows, chat_joined) and each MISS was a fresh SQLite query —
    // ~30 "restore MISS" lines for one open. One probe per run is enough.
    if historyRestoreMissChats.contains(chatId) { return false }
    guard let userId = chatHistoryCacheUserIdLocked() else { return false }
    var decodedRows: [[String: Any]] = messageStore.recentMessagePayloads(
      userId: userId, chatId: chatId, limit: chatHistoryCacheRowLimit
    ).compactMap { payload in
      (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }
    if decodedRows.isEmpty {
      // One-time migration from the legacy UserDefaults blob cache.
      guard let cacheKey = chatHistoryCacheKeyLocked(chatId: chatId),
        let data = UserDefaults.standard.data(forKey: cacheKey),
        let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
        let legacyRows = object as? [[String: Any]]
      else {
        // Names the exact failure behind an "empty chat on every launch": the durable
        // store holds nothing for this chat, so there is nothing to paint offline.
        NSLog(
          "[HistoryStore] restore MISS chat=%@ — SQLite holds 0 rows and no legacy blob",
          String(chatId.prefix(12)))
        historyRestoreMissChats.insert(chatId)
        return false
      }
      decodedRows = legacyRows
      persistHistoryRowsToStoreLocked(chatId: chatId, rows: legacyRows)
      UserDefaults.standard.removeObject(forKey: cacheKey)
    }
    // Self-heal caches written before transient rows were excluded from storage.
    let rows = decodedRows.filter { !isTransientStreamRow($0) }
    guard !rows.isEmpty else {
      // The store HAS rows for this chat but every one of them is a transient
      // placeholder — a distinct failure from "nothing was ever written", and
      // previously silent.
      NSLog(
        "[HistoryStore] restore DROPPED chat=%@ — all %d stored rows are transient (stream-/lan-)",
        String(chatId.prefix(12)), decodedRows.count)
      historyRestoreMissChats.insert(chatId)
      return false
    }

    // Self-heal twin generations already on disk: the same logical message persisted
    // under two different ids (the saved-messages `id` vs `original_message_id`
    // re-keying) restores as an adjacent DUPLICATE pair. Content-identical at the same
    // millisecond is not something two real messages can be — collapse to the richer
    // row and delete the twin from SQLite so this heals once, not per launch.
    let dedup = dedupContentIdenticalRestoredRows(rows)
    let restoredRows = dedup.rows
    if !dedup.droppedIds.isEmpty {
      if let userId = chatHistoryCacheUserIdLocked() {
        messageStore.deleteMessages(
          userId: userId, chatId: chatId, messageIds: dedup.droppedIds)
      }
      flagTranscriptHealedForRasterInvalidation(chatId: chatId)
      NSLog(
        "[HistoryStore] restore DEDUP chat=%@ dropped=%d twin rows (same content+ms, different id)",
        String(chatId.prefix(12)), dedup.droppedIds.count)
    }
    historyRowsByChat[chatId] = restoredRows
    historyFullyLoadedChats.insert(chatId)
    historyRowsRestoredFromCacheChats.insert(chatId)
    // Feed the core from the store too, not just from the network.
    //
    // Without this the core starves on exactly the launch that matters. A warm
    // relaunch restores from SQLite and logs `loadChatHistory SKIP … reason=
    // restored_fresh_ttl` — the network fetch never runs, so the network-side
    // ingest hooks never fire and the core holds zero rows for a chat the user is
    // looking at. Observed on device 2026-08-03: `driver ARMED` with no window
    // behind it.
    //
    // The inner `message` dict is what goes over, not the row wrapper: rows are
    // `{kind, key, message:{…}}` and `canonical.rs` reads server-frame keys. That
    // dict keeps `encryptedContent` alongside the opened text, so the core opens
    // the envelope itself rather than trusting Swift's copy.
    feedCoreRawFramesLocked(
      chatId: chatId,
      rawMessages: restoredRows.compactMap { $0["message"] as? [String: Any] },
      source: .storeRestore)
    NSLog(
      "[HistoryStore] restore HIT chat=%@ rows=%d (painted from local store, no network)",
      String(chatId.prefix(12)), restoredRows.count)
    appendJournalLocked(
      event: "native-chat-history-cache-restore",
      payload: ["chatId": chatId, "rows": restoredRows.count])
    VibeDebugLog.log(
      "[ChatEngine] restored cached chat history chatId=%@ rows=%d",
      String(chatId.prefix(12)),
      restoredRows.count
    )
    return true
  }

  /// Collapses rows that are the SAME logical message under two ids: identical sender,
  /// type, text, media, and millisecond timestamp. Keeps the richer payload (more message
  /// fields — the normalized generation carries decrypted extras the bare seed lacks) and
  /// reports the loser ids so the caller can delete them from the durable store. Rows
  /// without an id, without a timestamp, or from agents are never touched.
  private func dedupContentIdenticalRestoredRows(
    _ rows: [[String: Any]]
  ) -> (rows: [[String: Any]], droppedIds: [String]) {
    guard rows.count > 1 else { return (rows, []) }
    var bestIndexBySignature: [String: Int] = [:]
    var droppedIndices: Set<Int> = []
    var droppedIds: [String] = []
    for (index, row) in rows.enumerated() {
      guard let id = messageId(fromRow: row),
        let message = row["message"] as? [String: Any],
        (message["isAgentMessage"] as? Bool) != true
      else { continue }
      let ts = messageTimestampMs(fromRow: row)
      guard ts > 0 else { continue }
      let signature = [
        String(ts),
        normalizedString(message["type"]) ?? "text",
        normalizedUpper(message["fromId"]) ?? "",
        (message["isMe"] as? Bool) == true ? "me" : "peer",
        normalizedString(message["text"]) ?? "",
        normalizedString(message["mediaUrl"]) ?? "",
        normalizedString(message["fileName"]) ?? "",
      ].joined(separator: "|")
      guard let keptIndex = bestIndexBySignature[signature] else {
        bestIndexBySignature[signature] = index
        continue
      }
      let keptMessage = rows[keptIndex]["message"] as? [String: Any] ?? [:]
      let keptId = messageId(fromRow: rows[keptIndex]) ?? ""
      // Richer row wins; identical richness falls back to the larger id so the choice
      // is deterministic across launches.
      let currentWins =
        message.count != keptMessage.count ? message.count > keptMessage.count : id > keptId
      if currentWins {
        droppedIndices.insert(keptIndex)
        droppedIds.append(keptId)
        bestIndexBySignature[signature] = index
      } else {
        droppedIndices.insert(index)
        droppedIds.append(id)
      }
    }
    guard !droppedIndices.isEmpty else { return (rows, []) }
    let kept = rows.enumerated().compactMap { droppedIndices.contains($0.offset) ? nil : $0.element }
    return (kept, droppedIds)
  }

  private func storeCachedHistoryRowsLocked(chatId: String, rows: [[String: Any]]) {
    // Normal chats persist their settled server rows here. Agent/bridge DMs are gated out
    // inside persistHistoryRowsToStoreLocked (the single write choke) so their transcript
    // never reaches disk — it lives only in memory for the current run.
    guard !chatId.isEmpty, !rows.isEmpty else { return }
    let stored = persistHistoryRowsToStoreLocked(chatId: chatId, rows: rows)
    guard stored > 0 else { return }
    appendJournalLocked(
      event: "native-chat-history-cache-store",
      payload: ["chatId": chatId, "rows": stored])
    VibeDebugLog.log(
      "[ChatEngine] stored cached chat history chatId=%@ rows=%d",
      String(chatId.prefix(12)),
      stored
    )
  }

  /// Upserts persistable rows into the SQLite store; locally-deleted ids are
  /// removed so they cannot resurrect on the next restore. Returns the number
  /// of rows written.
  @discardableResult
  private func persistHistoryRowsToStoreLocked(
    chatId: String,
    rows: [[String: Any]],
    skipPrune: Bool = false
  ) -> Int {
    guard let userId = chatHistoryCacheUserIdLocked(), messageStore.isAvailable else { return 0 }
    // Agent/bridge DMs are volatile-per-session — their transcript must never reach disk,
    // so it can't paint on the next cold launch. Classify at WRITE time, where the
    // provider is reliably resolved (unlike cold-launch restore). This is the single
    // choke for every persist path (store, background load, legacy migration).
    if isAgentDMForPersistenceLocked(chatId: chatId) {
      markAgentDMChatForPersistenceLocked(chatId: chatId)
      return 0
    }
    var entries: [(messageId: String, ts: Int64, payload: Data)] = []
    entries.reserveCapacity(rows.count)
    var durableRows: [[String: Any]] = []
    durableRows.reserveCapacity(rows.count)
    for row in rows {
      guard !isTransientStreamRow(row),
        let messageId = messageId(fromRow: row),
        JSONSerialization.isValidJSONObject(row),
        let payload = try? JSONSerialization.data(withJSONObject: row, options: [])
      else { continue }
      entries.append((messageId, messageTimestampMs(fromRow: row), payload))
      durableRows.append(row)
    }
    guard !entries.isEmpty else { return 0 }
    messageStore.upsertMessages(userId: userId, chatId: chatId, entries: entries)
    // P4-C — the engine **pushes** its transcript at the same choke it persists it,
    // so the next open reads prepared heights instead of measuring during the push.
    // This is a copy and a dispatch; the measuring happens on the store's own utility
    // queue, never here. Putting it at the persist choke rather than at a load site
    // is deliberate: every path that changes the durable transcript passes through
    // here exactly once, so there is no second feed to keep in agreement.
    // `.page`, because this is the rows *this write* touched — a history page, a backfill,
    // one incoming message — not the chat. Declaring it full is what made every drained
    // page evict the transcript's measurements and the next pass re-measure them.
    VibeTimelinePreparedStore.shared.prepareAsync(
      chatId: chatId, rawRows: durableRows, reason: "persist", scope: .page)
    historyRestoreMissChats.remove(chatId)
    if let deletedIds = deletedMessageIdsByChat[chatId], !deletedIds.isEmpty {
      messageStore.deleteMessages(userId: userId, chatId: chatId, messageIds: Array(deletedIds))
    }
    if !skipPrune {
      messageStore.pruneChat(userId: userId, chatId: chatId)
    }
    // The Rust store mirrors this same choke, for the same reason. It writes only
    // to its own additive `core_*` tables and nothing reads them yet, so a failure
    // here cannot affect what the list renders — it can only fail to migrate.
    // All three calls hop to the store's own queue immediately; none run here.
    //
    // Backfill is the one-time historical catch-up; `mirrorRows` is what keeps
    // the two tables in step afterwards, because backfill's cursor completes and
    // can never see a row that arrives after it. Same serial queue, so the
    // historical walk always lands before the increments that follow it.
    VibeCoreStoreBridge.backfillChat(userId: userId, chatId: chatId)
    VibeCoreStoreBridge.mirrorRows(
      userId: userId, chatId: chatId, entries: entries,
      keepNewest: skipPrune ? 0 : UInt32(ChatMessageStore.prunedChatRowLimit))
    VibeCoreStoreBridge.verifyAgainstLegacy(userId: userId, chatId: chatId)
    return entries.count
  }

  /// Deletes store rows the server-canonical transcript no longer lists. Upserts alone can
  /// never remove a ghost: a row persisted under a retired id (a re-keying, a delete on
  /// another device) sits in SQLite forever and resurrects as a DUPLICATE or a zombie on
  /// every cold-open restore — network reconcile fixed the screen, relaunch brought it
  /// back. Only call this with a COMPLETE canonical set for the chat (saved_messages
  /// returns its full list); a paginated window would mass-delete rows beyond the page.
  private func reconcileStoreAgainstCanonicalLocked(chatId: String, canonicalIds: Set<String>) {
    guard !canonicalIds.isEmpty, let userId = chatHistoryCacheUserIdLocked(),
      messageStore.isAvailable
    else { return }
    let stored = messageStore.messageIdsWithTimestamps(userId: userId, chatId: chatId)
    guard !stored.isEmpty else { return }
    let liveIds = Set(liveMessageRowsByChat[chatId]?.keys.map { $0 } ?? [])
    let pendingIds = Set(pendingOutboundDraftsByMessageId.keys)
    // A send still in flight may predate the GET this canonical set came from — never
    // treat anything live, pending, or seconds old as a ghost.
    let recencyFloorTs = Int64(nowMs()) - Int64(5 * 60 * 1000)
    let ghostIds = stored.filter { entry in
      !canonicalIds.contains(entry.messageId)
        && !liveIds.contains(entry.messageId)
        && !pendingIds.contains(entry.messageId)
        && entry.ts < recencyFloorTs
    }.map(\.messageId)
    guard !ghostIds.isEmpty else { return }
    messageStore.deleteMessages(userId: userId, chatId: chatId, messageIds: ghostIds)
    flagTranscriptHealedForRasterInvalidation(chatId: chatId)
    NSLog(
      "[HistoryStore] reconcile chat=%@ purged=%d of %d stored (ids absent from the canonical transcript)",
      String(chatId.prefix(12)), ghostIds.count, stored.count)
  }

  /// A structural heal (twin dedup, ghost reconcile) changed this chat's durable
  /// transcript — any reopen raster captured before it photographs a world that no
  /// longer exists, and covering the next open with it means a visible content jump when
  /// the healed rows mount underneath. The view layer owns the raster lifecycle, so the
  /// fact travels via UserDefaults: thread-safe, immune to the launch ordering race with
  /// the raster prewarm, and it survives a relaunch if the process dies in between.
  private func flagTranscriptHealedForRasterInvalidation(chatId: String) {
    let key = "VibeReopenRasterHealedChats"
    let defaults = UserDefaults.standard
    var ids = defaults.stringArray(forKey: key) ?? []
    guard !ids.contains(chatId) else { return }
    ids.append(chatId)
    defaults.set(ids, forKey: key)
  }

  private func clearCachedHistoryRowsLocked(chatId: String) {
    if let userId = chatHistoryCacheUserIdLocked() {
      // Destructive: this is the only path that DELETES a chat's durable transcript.
      // Name it in the log — "the cache is gone after relaunch" is indistinguishable from
      // "it was never written" without this line.
      let before = messageStore.messageCount(userId: userId, chatId: chatId)
      if before > 0 {
        NSLog(
          "[HistoryStore] WIPE chat=%@ — deleting %d stored rows",
          String(chatId.prefix(12)), before)
      }
      messageStore.deleteChat(userId: userId, chatId: chatId)
      // Same wipe for the sealed core tables. Without this, a later core-store read
      // would resurrect history the engine just deleted.
      VibeCoreStoreBridge.clearChat(userId: userId, chatId: chatId)
    }
    // Heights measured for rows that no longer exist would open the next visit
    // with wrong content-size / jump targets.
    VibeTimelinePreparedStore.shared.invalidate(chatId: chatId)
    ChatListView.clearWarmTranscriptSnapshot(chatId: chatId)
    guard let cacheKey = chatHistoryCacheKeyLocked(chatId: chatId) else { return }
    UserDefaults.standard.removeObject(forKey: cacheKey)
    UserDefaults.standard.synchronize()
  }

  // MARK: - Agent-bridge DM row persistence
  //
  // Agent DMs are excluded from the normal server-history cache (the "agent_surface"
  // skip in loadChatHistoryIfNeededLocked), which left their transcript existing ONLY
  // in memory + on the wire: every cold open — and every long reconnect on a bad
  // link — rendered an empty surface until a server/bridge round-trip landed. Persist
  // the SETTLED rows (finished turns + real messages; `stream-` fragments and rows
  // still flagged streaming are skipped — the mid-run current-session request owns
  // re-delivering those) so the last-known transcript paints instantly on open and
  // survives connection loss without depending on the socket.

  /// Base directory of the per-chat bridge-rows cache files.
  private func volatileBridgeRowsCacheDir() -> URL? {
    guard
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { return nil }
    return base.appendingPathComponent("VibeBridgeRows", isDirectory: true)
  }

  /// Wipe the whole on-disk bridge-rows cache at process launch, so a cold start opens
  /// agent DMs clean (see the rationale at the init call site). Runs exactly once per
  /// launch; in-memory rows are never touched, only the disk files.
  private func purgeVolatileBridgeRowsCacheOnLaunchLocked() {
    guard let dir = volatileBridgeRowsCacheDir() else { return }
    // Mark every chat as "already restored" so a later getChatRows can't re-seed from a
    // file that races the delete — the cold-launch surface stays clean until live rows
    // arrive. (Files this run subsequently writes are for the CURRENT session only.)
    if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
      for name in files {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
      }
      appendJournalLocked(
        event: "bridge-rows-cache-purge-launch", payload: ["files": files.count])
    }
  }

  private func volatileBridgeRowsCacheURL(chatId: String) -> URL? {
    guard let dir = volatileBridgeRowsCacheDir() else { return nil }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("rows-\(cacheKeyComponent(chatId)).json")
  }

  private func scheduleVolatileBridgeRowsStoreLocked(chatId: String) {
    guard !chatId.isEmpty, volatileBridgeRowsStoreTimers[chatId] == nil,
      isVolatileBridgeAgentChatLocked(chatId: chatId)
    else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.volatileBridgeRowsStoreTimers.removeValue(forKey: chatId)
      self.storeVolatileBridgeRowsLocked(chatId: chatId)
    }
    volatileBridgeRowsStoreTimers[chatId] = work
    queue.asyncAfter(deadline: .now() + 1.5, execute: work)
  }

  private func storeVolatileBridgeRowsLocked(chatId: String) {
    guard let url = volatileBridgeRowsCacheURL(chatId: chatId) else { return }
    let perChat = liveMessageRowsByChat[chatId] ?? [:]
    var settled: [String: [String: Any]] = [:]
    for (rowMessageId, row) in perChat {
      // Stream fragments and running turns are transient — the live pipeline owns them.
      if rowMessageId.hasPrefix("stream-") { continue }
      let message = row["message"] as? [String: Any]
      let metaStreaming = (message?["metadata"] as? [String: Any])?["isStreaming"] as? Bool
      let topStreaming = message?["isStreaming"] as? Bool
      if metaStreaming == true || topStreaming == true { continue }
      settled[rowMessageId] = row
    }
    guard !settled.isEmpty else { return }
    if settled.count > 80 {
      let newest = settled.sorted {
        messageTimestampMs(fromRow: $0.value) < messageTimestampMs(fromRow: $1.value)
      }.suffix(80)
      settled = Dictionary(uniqueKeysWithValues: Array(newest))
    }
    guard JSONSerialization.isValidJSONObject(settled),
      let data = try? JSONSerialization.data(withJSONObject: settled, options: [])
    else {
      appendJournalLocked(
        event: "bridge-rows-cache-skip",
        payload: ["chatId": chatId, "reason": "invalid_json"])
      return
    }
    try? data.write(to: url, options: [.atomic])
    appendJournalLocked(
      event: "bridge-rows-cache-store",
      payload: ["chatId": chatId, "rows": settled.count])
  }

  private func restoreVolatileBridgeRowsIfNeededLocked(chatId: String) {
    // Keyed on the cache file's existence, not on isVolatileBridgeAgentChatLocked: at
    // cold open the peer→provider maps may not be populated yet, and a present file
    // proves the chat WAS an agent DM when it was stored.
    guard !chatId.isEmpty, !volatileBridgeRowsRestoredChats.contains(chatId) else { return }
    volatileBridgeRowsRestoredChats.insert(chatId)
    guard let url = volatileBridgeRowsCacheURL(chatId: chatId),
      let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data, options: []),
      let cached = object as? [String: [String: Any]],
      !cached.isEmpty
    else { return }
    var perChat = liveMessageRowsByChat[chatId] ?? [:]
    let deletedIds = deletedMessageIdsByChat[chatId] ?? []
    var seeded = 0
    var seededIds: [String] = []
    var settledOnRestore = 0
    for (rowMessageId, row) in cached {
      guard perChat[rowMessageId] == nil, !deletedIds.contains(rowMessageId) else { continue }
      // A disk snapshot is never itself a live stream — liveness is re-established by
      // incoming frames. A cached row still flagged streaming is a dead run that was killed
      // mid-flight (CLI crash, app killed, monitor reset); restoring it as-is resurrects it
      // into the live store as a permanent shimmer that no terminal frame will ever clear.
      // Settle it on the way in; if the run is genuinely still live, the next frame re-marks
      // it streaming. The 3-min gate leaves a just-backgrounded live turn untouched.
      if isStaleStreamingAgentRowLocked(row, minStaleMs: 3 * 60 * 1000) {
        perChat[rowMessageId] = terminalizedStaleAgentRowLocked(row)
        settledOnRestore += 1
      } else {
        perChat[rowMessageId] = row
      }
      seeded += 1
      seededIds.append(rowMessageId)
    }
    if settledOnRestore > 0 {
      NSLog(
        "[TeamSettle] restore-settle chat=%@ settled=%d of %d",
        String(chatId.prefix(12)), settledOnRestore, seeded)
    }
    guard seeded > 0 else { return }
    liveMessageRowsByChat[chatId] = perChat
    NSLog(
      "[ChatEngine] bridge-rows cache seeded chatId=%@ rows=%d",
      String(chatId.prefix(12)), seeded)
    appendJournalLocked(
      event: "bridge-rows-cache-restore",
      payload: ["chatId": chatId, "rows": seeded])
    postChatDeltaLocked(
      chatId: chatId, inserted: seededIds.sorted(), updated: [], deleted: [],
      source: "bridgeRestore")
  }

  /// Resets the SESSION layer for a bridge DM: the mounted History-session payload,
  /// per-provider session lists, and any in-flight session requests. It deliberately
  /// does NOT touch the transcript (`historyRowsByChat` + flags + cursors) — the
  /// settled transcript is durable, chat-keyed state that a new run appends to, exactly
  /// like a normal chat. (The old version wiped the transcript too, which is why an
  /// agent DM emptied at every send/classification tick and held content only for the
  /// life of the process.) And it never touches the durable store: a runtime
  /// classification may route, never destroy.
  private func clearVolatileBridgeHistoryLocked(chatId: String, reason: String) {
    guard !chatId.isEmpty else { return }
    agentBridgeHistoryByChat.removeValue(forKey: chatId)
    let listPrefix = "\(chatId)|"
    agentBridgeHistoryListByChatProvider = agentBridgeHistoryListByChatProvider.filter {
      !$0.key.hasPrefix(listPrefix)
    }
    pendingAgentBridgeHistoryRequestsByChat.removeValue(forKey: chatId)
    appendJournalLocked(
      event: "native-bridge-history-cleared",
      payload: ["chatId": chatId, "reason": reason]
    )
  }

  /// When `row` is a live supervisor team LEAD row — the single group cell that folds
  /// every under-hood worker's status — return its teamRunId; otherwise nil. The lead
  /// row is `stream-…` keyed like any other live turn, but it represents a long-lived,
  /// server-durable run (teamWorkersStatus lives in ETS + the TeamRun DB row). It must
  /// therefore be exempt from the socket-reset wipe: backgrounding the app mid-run and
  /// returning was blanking the group cell and — because the row-id pin kept pointing at
  /// the dropped row — resetting its streaming text to the next partial frame.
  private func supervisorTeamRunIdForRowLocked(_ row: [String: Any]) -> String? {
    guard let message = row["message"] as? [String: Any],
      let metadata = message["metadata"] as? [String: Any]
    else { return nil }
    let runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
    guard let teamRunId = normalizedString(runtime["teamRunId"] ?? runtime["team_run_id"]),
      !teamRunId.isEmpty
    else { return nil }
    let teamMode = (normalizedString(runtime["teamMode"] ?? runtime["team_mode"]) ?? "").lowercased()
    let isSupervisor = teamMode == "supervisor" || teamMode == "group_supervisor"
    let hasWorkerStatus =
      ((metadata["teamWorkersStatus"] as? [[String: Any]])?.isEmpty == false)
      || ((runtime["teamWorkersStatus"] as? [[String: Any]])?.isEmpty == false)
    return (isSupervisor || hasWorkerStatus) ? teamRunId : nil
  }

  /// True when a NON-streaming (settled) card for `teamRunId` already exists in this
  /// chat's live or history rows — i.e. the run finished, possibly while the app was
  /// backgrounded. In that case the live lead row is stale and must NOT be preserved
  /// across a socket reset, or it lingers as a ghost "working" cell beside the final
  /// summary card.
  private func hasFinishedTeamCardLocked(chatId: String, teamRunId: String) -> Bool {
    guard !teamRunId.isEmpty else { return false }
    func finishedForRun(_ message: [String: Any]) -> Bool {
      guard let metadata = message["metadata"] as? [String: Any] else { return false }
      let runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
      guard normalizedString(runtime["teamRunId"] ?? runtime["team_run_id"]) == teamRunId
      else { return false }
      if let id = normalizedString(message["id"]),
        id.hasPrefix("stream-") || id.hasPrefix("lan-")
      {
        return false
      }
      let streaming =
        (message["isStreaming"] as? Bool) == true
        || (metadata["isStreaming"] as? Bool) == true
      return !streaming
    }
    if let perChat = liveMessageRowsByChat[chatId] {
      for (_, row) in perChat {
        if let message = row["message"] as? [String: Any], finishedForRun(message) {
          return true
        }
      }
    }
    for row in historyRowsByChat[chatId] ?? [] {
      if let message = row["message"] as? [String: Any], finishedForRun(message) {
        return true
      }
    }
    return false
  }

  private func clearSocketResetLiveRowsLocked() {
    // [EmptyTrace] This ONLY runs on a socket reset. The user's hypothesis is the list jumps
    // to empty WITHOUT a drop — so if this line is ABSENT from the log at the empty moment,
    // the connection did not reset and the wipe came from elsewhere (ingest/typing/message).
    VibeDebugLog.log(
      "[EmptyTrace] socketReset clearLiveRows — chats=%d (connection DID reset)",
      liveMessageRowsByChat.count)
    // On a socket reset we only drop live rows that a history refetch can re-deliver.
    // A live row NOT present in fetched history (an unsent/queued outbound, or any
    // message in a chat whose history was never loaded — e.g. the very first message
    // of a brand-new chat) is the ONLY copy the app has: wiping it makes the message
    // vanish from the chat list and the home preview until a full history round-trip.
    let previousLive = liveMessageRowsByChat
    var nextLive: [String: [String: [String: Any]]] = [:]
    for (chatId, perChat) in previousLive {
      if isVolatileBridgeAgentChatLocked(chatId: chatId) {
        nextLive[chatId] = perChat
        continue
      }
      let historyIds = Set((historyRowsByChat[chatId] ?? []).compactMap { messageId(fromRow: $0) })
      var kept: [String: [String: Any]] = [:]
      for (rowMessageId, row) in perChat {
        // Agent stream fragments are transient by design — always drop on reset.
        if rowMessageId.hasPrefix("stream-") {
          // Exception: a supervisor team LEAD row is a long-lived, server-durable run,
          // not a throwaway fragment. Backgrounding + returning must not blank the group
          // cell (and, via the stale row-id pin, reset its streaming text). Keep it —
          // unless the run has already settled (a finished card for the same teamRunId
          // exists), in which case dropping it avoids a ghost "working" cell.
          if let teamRunId = supervisorTeamRunIdForRowLocked(row),
            !hasFinishedTeamCardLocked(chatId: chatId, teamRunId: teamRunId)
          {
            kept[rowMessageId] = row
            VibeDebugLog.log(
              "[FirstMsg] socketReset preserving team lead row chatId=%@ run=%@",
              String(chatId.prefix(12)), String(teamRunId.prefix(8)))
          }
          continue
        }
        if historyIds.contains(rowMessageId) { continue }
        kept[rowMessageId] = row
      }
      if !kept.isEmpty {
        nextLive[chatId] = kept
        VibeDebugLog.log(
          "[FirstMsg] socketReset keeping %d live row(s) chatId=%@ (not in fetched history)",
          kept.count, String(chatId.prefix(12)))
      }
    }
    liveMessageRowsByChat = nextLive
    // A deleted chat's final live row makes `liveMessageRowsByChat[chatId]` nil.
    // Dropping its tombstone on the next socket reset exposed the unchanged
    // in-memory history row again, which is the delete → flicker → resurrection
    // sequence seen in the UI. Keep tombstones for every loaded transcript; a
    // legitimate later upsert already removes its own id from this set.
    deletedMessageIdsByChat = deletedMessageIdsByChat.filter { chatId, _ in
      isVolatileBridgeAgentChatLocked(chatId: chatId)
        || liveMessageRowsByChat[chatId] != nil
        || historyRowsByChat[chatId] != nil
    }
    for (chatId, perChat) in previousLive {
      let remainingIds = Set(nextLive[chatId]?.keys ?? Dictionary<String, [String: Any]>().keys)
      let removedIds = Set(perChat.keys).subtracting(remainingIds).sorted()
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [], deleted: removedIds, source: "socketReset")
    }
  }

  private func cacheKeyComponent(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let mapped = trimmed.unicodeScalars.map { scalar -> Character in
      CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
    }
    let resolved = String(mapped)
    return resolved.isEmpty ? "default" : resolved
  }

  private func oldestHistoryBoundaryLocked(
    rows: [[String: Any]]
  ) -> (messageId: String, timestampMs: Int64)? {
    var oldest: (messageId: String, timestampMs: Int64)?
    for row in rows {
      guard let messageId = messageId(fromRow: row) else { continue }
      let timestampMs = messageTimestampMs(fromRow: row)
      if let current = oldest,
        current.timestampMs < timestampMs
          || (current.timestampMs == timestampMs && current.messageId <= messageId)
      {
        continue
      }
      oldest = (messageId, timestampMs)
    }
    return oldest
  }

  private func oldestHistoryBoundaryLocked(
    chatId: String
  ) -> (messageId: String, timestampMs: Int64)? {
    guard let rows = historyRowsByChat[chatId], !rows.isEmpty else { return nil }
    return oldestHistoryBoundaryLocked(rows: rows)
  }

  private func encodedHistoryCursorLocked(
    timestampMs: Int64,
    messageId: String
  ) -> String? {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: ["timestamp": timestampMs, "id": messageId], options: [.sortedKeys])
    else { return nil }
    return data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func applyHistoryPaginationMetadataLocked(
    chatId: String,
    response: [String: Any],
    remoteRows: [[String: Any]]
  ) {
    if response.keys.contains("hasMore"), let hasMore = parseBooleanLike(response["hasMore"]) {
      historyHasMoreByChat[chatId] = hasMore
      if hasMore {
        historyOlderExhaustedChats.remove(chatId)
      } else {
        historyOlderExhaustedChats.insert(chatId)
      }
    }

    if response.keys.contains("nextCursor") {
      if let nextCursor = normalizedString(response["nextCursor"]) {
        historyNextCursorByChat[chatId] = nextCursor
        if let boundary = oldestHistoryBoundaryLocked(rows: remoteRows) {
          historyNextCursorBoundaryByChat[chatId] = boundary
        } else {
          historyNextCursorBoundaryByChat.removeValue(forKey: chatId)
        }
      } else {
        historyNextCursorByChat.removeValue(forKey: chatId)
        historyNextCursorBoundaryByChat.removeValue(forKey: chatId)
      }
    }
  }

  /// Rejoin/backfill: fetch the NEWEST history page and merge it in. Covers messages
  /// that landed while the socket was down (backgrounded phone, network blip) — the
  /// join handler replays queues but nothing re-fetched the tail, so a reopened chat
  /// rendered the stale cached window until the user scrolled. Merge is id-keyed
  /// (idempotent); durable agent rows retire their superseded live stream bubbles
  /// (taskId match) so a missed settle can't leave a duplicate response cell.
  private func backfillNewestChatHistoryLocked(chatId: String, trigger: String) {
    guard historyRowsByChat[chatId] != nil else { return }
    guard chatId != "saved_messages",
      !isBuiltInAgentChatId(chatId),
      !isAgentDMForPersistenceLocked(chatId: chatId),
      !historyBackfillingChats.contains(chatId)
    else { return }
    let now = Int64(nowMs())
    if let last = historyBackfillAtMsByChat[chatId], now - last < 10_000 { return }
    guard let apiBase = apiBaseURLLocked(),
      normalizedString(getConfigValueLocked("userId")) != nil
    else { return }

    let baseMessageUrl = apiBase.appendingPathComponent("api").appendingPathComponent("chat")
      .appendingPathComponent(chatId).appendingPathComponent("messages")
    var urlComponents = URLComponents(url: baseMessageUrl, resolvingAgainstBaseURL: false)
    urlComponents?.queryItems = [
      URLQueryItem(name: "limit", value: "\(chatOlderHistoryFetchLimit)")
    ]
    guard let finalUrl = urlComponents?.url else { return }
    var request = URLRequest(url: finalUrl)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let token = authHeaderTokenLocked(), !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    historyBackfillingChats.insert(chatId)
    historyBackfillAtMsByChat[chatId] = now
    NSLog(
      "[ChatEngine] backfillNewest START chatId=%@ trigger=%@",
      String(chatId.prefix(12)), trigger)

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        self.historyBackfillingChats.remove(chatId)
        guard error == nil,
          let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
          let data,
          let object = try? JSONSerialization.jsonObject(with: data)
        else {
          NSLog(
            "[ChatEngine] backfillNewest FAIL chatId=%@ trigger=%@ error=%@",
            String(chatId.prefix(12)), trigger,
            error?.localizedDescription
              ?? "http_\((response as? HTTPURLResponse)?.statusCode ?? -1)")
          return
        }
        let responseDict = object as? [String: Any]
        let messagesArray: [[String: Any]]
        if let array = object as? [[String: Any]] {
          messagesArray = array
        } else if let array = responseDict?["data"] as? [[String: Any]] {
          messagesArray = array
        } else if let array = responseDict?["messages"] as? [[String: Any]] {
          messagesArray = array
        } else {
          return
        }
        let remoteRows = self.buildHistoryRowsLocked(chatId: chatId, rawMessages: messagesArray)
          .filter { !self.isTransientStreamRow($0) }
        guard !remoteRows.isEmpty else { return }
        let (rows, delta) = self.ingestHistoryRowsLocked(chatId: chatId, remoteRows: remoteRows)
        self.historyRowsByChat[chatId] = rows
        _ = self.persistHistoryRowsToStoreLocked(chatId: chatId, rows: rows)
        let retiredLiveIds = self.retireLiveRowsSupersededByDurableLocked(
          chatId: chatId, durableRows: remoteRows)
        let changed =
          !delta.insertedIds.isEmpty || !delta.updatedIds.isEmpty || !delta.deletedIds.isEmpty
          || !retiredLiveIds.isEmpty
        NSLog(
          "[ChatEngine] backfillNewest OK chatId=%@ trigger=%@ fetched=%d ins=%d upd=%d retiredLive=%d",
          String(chatId.prefix(12)), trigger, remoteRows.count,
          delta.insertedIds.count, delta.updatedIds.count, retiredLiveIds.count)
        // [BackfillReinsert] "The previous cell jumps a beat after the new one."
        // Prime suspect: the server echoes a just-sent message back through this
        // backfill and ingest counts it as a NEW durable row (it was previously only
        // an OPTIMISTIC row in liveMessageRowsByChat, a separate store this delta
        // doesn't see) — so postChatDelta fires inserted:[thatId] ~0.6s post-send and
        // the list re-inserts/re-slots it. For every inserted id, name whether it is
        // also a live optimistic row (liveDup=Y ⇒ this is the sent message, not a new
        // one) and whether its slot timestamp CHANGED between the optimistic copy and
        // the durable copy (liveTs→durableTs) — a ts change is what makes it re-sort
        // into a different slot and drag its neighbor. retiredLive only covers agent
        // stream rows, so a plain text send always shows liveDup=Y here.
        if !delta.insertedIds.isEmpty {
          let liveForChat = self.liveMessageRowsByChat[chatId] ?? [:]
          let durableById = Dictionary(
            remoteRows.compactMap { row -> (String, [String: Any])? in
              guard let mid = self.messageId(fromRow: row) else { return nil }
              return (mid, row)
            }, uniquingKeysWith: { _, last in last })
          let insDetail = delta.insertedIds.map { id -> String in
            let liveRow = liveForChat[id]
            let liveDup = liveRow != nil
            let liveTs = liveRow.map { self.messageTimestampMs(fromRow: $0) } ?? -1
            let durableTs = durableById[id].map { self.messageTimestampMs(fromRow: $0) } ?? -1
            let tsMoved = liveDup && liveTs != durableTs
            return
              "\(id.suffix(6)){live=\(liveDup ? "Y" : "N") ts=\(liveTs)->\(durableTs)\(tsMoved ? " MOVED" : "")}"
          }.joined(separator: ",")
          NSLog(
            "[BackfillReinsert] chatId=%@ ins=[%@] liveRows=%d",
            String(chatId.prefix(12)), insDetail, liveForChat.count)
        }
        self.appendJournalLocked(
          event: "native-chat-backfill-ok",
          payload: [
            "chatId": chatId, "trigger": trigger, "fetched": remoteRows.count,
            "inserted": delta.insertedIds.count, "retiredLive": retiredLiveIds.count,
          ])
        guard changed else { return }
        self.state["updatedAt"] = self.nowMs()
        self.postChangeLocked(
          reason: "chatRowsReloaded",
          userInfo: ["chatId": chatId, "state": self.statusSnapshotLocked()])
        self.postChatDeltaLocked(
          chatId: chatId,
          inserted: delta.insertedIds,
          updated: delta.updatedIds,
          deleted: delta.deletedIds + retiredLiveIds,
          source: "backfill")
      }
    }.resume()
  }

  /// A durable agent message that carries taskId T supersedes any still-live
  /// `stream-…`/`lan-…` bubble for the same task. The connected path retires those on
  /// live message arrival (removeAgentStreamRowsLocked); this covers the DISCONNECTED
  /// path, where the settle broadcast was missed and the durable copy arrives later via
  /// backfill — without it the chat shows the response twice (live orphan + durable).
  private func retireLiveRowsSupersededByDurableLocked(
    chatId: String, durableRows: [[String: Any]]
  ) -> [String] {
    guard let perChat = liveMessageRowsByChat[chatId], !perChat.isEmpty else { return [] }
    var durableMessageIdByTaskId: [String: String] = [:]
    for row in durableRows {
      guard let mid = messageId(fromRow: row),
        let taskId = agentTaskIdFromRow(row), !taskId.isEmpty
      else { continue }
      durableMessageIdByTaskId[taskId] = mid
    }
    guard !durableMessageIdByTaskId.isEmpty else { return [] }
    var removedIds: [String] = []
    for (liveId, liveRow) in perChat {
      guard liveId.hasPrefix("stream-") || liveId.hasPrefix("lan-") else { continue }
      guard let liveTaskId = agentTaskIdFromRow(liveRow),
        let durableMessageId = durableMessageIdByTaskId[liveTaskId]
      else { continue }
      if let slotTs = agentStreamTimestampsByChat[chatId]?[liveId] {
        adoptAgentSettleSlotTsLocked(chatId: chatId, messageId: durableMessageId, slotTs: slotTs)
      }
      liveMessageRowsByChat[chatId]?.removeValue(forKey: liveId)
      removedIds.append(liveId)
      removeBridgeTaskTrackingLocked(chatId: chatId, taskId: liveTaskId)
      NSLog(
        "[ChatEngine] retireSupersededLive chatId=%@ live=%@ task=%@ durable=%@",
        String(chatId.suffix(12)), String(liveId.suffix(20)),
        String(liveTaskId.suffix(20)), String(durableMessageId.suffix(12)))
    }
    if liveMessageRowsByChat[chatId]?.isEmpty == true {
      liveMessageRowsByChat.removeValue(forKey: chatId)
    }
    if !removedIds.isEmpty, var perChatTimestamps = agentStreamTimestampsByChat[chatId] {
      for id in removedIds { perChatTimestamps.removeValue(forKey: id) }
      if perChatTimestamps.isEmpty {
        agentStreamTimestampsByChat.removeValue(forKey: chatId)
      } else {
        agentStreamTimestampsByChat[chatId] = perChatTimestamps
      }
    }
    return removedIds
  }

  /// taskId as carried on both live stream rows and durable settled agent messages:
  /// message.metadata.agentRuntime.taskId (bridge runtime) with agentTaskId fallback.
  private func agentTaskIdFromRow(_ row: [String: Any]) -> String? {
    guard let message = row["message"] as? [String: Any],
      let metadata = message["metadata"] as? [String: Any]
    else { return nil }
    let runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
    return normalizedString(
      runtime["taskId"] ?? runtime["task_id"]
        ?? metadata["agentTaskId"] ?? metadata["agent_task_id"])
  }

  private func loadOlderChatHistoryLocked(chatId: String) -> Bool {
    guard !historyLoadingOlderChats.contains(chatId), !historyLoadingChats.contains(chatId),
      chatId != "saved_messages",
      !isBuiltInAgentChatId(chatId),
      !isAgentDMForPersistenceLocked(chatId: chatId),
      !historyOlderExhaustedChats.contains(chatId),
      let boundary = oldestHistoryBoundaryLocked(chatId: chatId)
    else { return false }

    historyLoadingOlderChats.insert(chatId)
    if let userId = chatHistoryCacheUserIdLocked(), messageStore.isAvailable {
      let payloads = messageStore.olderMessagePayloads(
        userId: userId,
        chatId: chatId,
        beforeTs: boundary.timestampMs,
        beforeMessageId: boundary.messageId,
        limit: chatOlderHistoryFetchLimit
      )
      if !payloads.isEmpty {
        let olderRows = payloads.compactMap { payload in
          (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        }.filter { !isTransientStreamRow($0) }
        let existingCount = historyRowsByChat[chatId]?.count ?? 0
        // Page the core back in step with the list. The core serves a bounded
        // window over its own store, and this store page is the only place the
        // older rows exist — without this the core stays at its opening window
        // while the list grows, the coverage gate refuses on every scroll-back,
        // and the transcript flips between core rows and engine rows mid-scroll.
        feedCoreRawFramesLocked(
          chatId: chatId,
          rawMessages: olderRows.compactMap { $0["message"] as? [String: Any] },
          source: .storeRestore)
        let (rows, delta) = ingestHistoryRowsLocked(chatId: chatId, remoteRows: olderRows)
        historyRowsByChat[chatId] = rows
        historyLoadingOlderChats.remove(chatId)
        state["updatedAt"] = nowMs()
        let prependedCount = max(0, rows.count - existingCount)
        appendJournalLocked(
          event: "native-chat-older-history-load-ok",
          payload: [
            "chatId": chatId,
            "source": "store",
            "rows": prependedCount,
          ])
        NSLog(
          "[ChatEngine] loadOlderHistory chatId=%@ source=store rows=%d exhausted=N",
          String(chatId.prefix(12)), prependedCount)
        postChangeLocked(
          reason: "chatRowsReloaded",
          userInfo: [
            "chatId": chatId,
            "state": statusSnapshotLocked(),
            "prependedOlder": prependedCount,
          ])
        postChatDeltaLocked(
          chatId: chatId, inserted: delta.insertedIds, updated: delta.updatedIds,
          deleted: delta.deletedIds, source: "history")
        return true
      }
    }

    guard let apiBase = apiBaseURLLocked(),
      normalizedString(getConfigValueLocked("userId")) != nil
    else {
      historyLoadingOlderChats.remove(chatId)
      appendJournalLocked(
        event: "native-chat-older-history-skip",
        payload: ["chatId": chatId, "reason": "missing_config"])
      return false
    }

    let cursor: String?
    if let serverCursor = historyNextCursorByChat[chatId],
      let cursorBoundary = historyNextCursorBoundaryByChat[chatId],
      cursorBoundary.messageId == boundary.messageId,
      cursorBoundary.timestampMs == boundary.timestampMs
    {
      cursor = serverCursor
    } else {
      cursor = encodedHistoryCursorLocked(
        timestampMs: boundary.timestampMs, messageId: boundary.messageId)
    }
    guard let cursor else {
      historyLoadingOlderChats.remove(chatId)
      return false
    }

    let baseMessageUrl = apiBase.appendingPathComponent("api").appendingPathComponent("chat")
      .appendingPathComponent(chatId).appendingPathComponent("messages")
    var urlComponents = URLComponents(url: baseMessageUrl, resolvingAgainstBaseURL: false)
    urlComponents?.queryItems = [
      URLQueryItem(name: "limit", value: "\(chatOlderHistoryFetchLimit)"),
      URLQueryItem(name: "before", value: cursor),
    ]
    guard let finalUrl = urlComponents?.url else {
      historyLoadingOlderChats.remove(chatId)
      return false
    }
    var request = URLRequest(url: finalUrl)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let token = authHeaderTokenLocked(), !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let fetchStartMs = nowMs()
    NSLog(
      "[ChatEngine] loadOlderHistory START chatId=%@ limit=%d",
      String(chatId.prefix(12)), chatOlderHistoryFetchLimit)
    appendJournalLocked(
      event: "native-chat-older-history-load-start",
      payload: ["chatId": chatId, "source": "network"])

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        let durationMs = self.nowMs() - fetchStartMs
        self.historyLoadingOlderChats.remove(chatId)
        if let error {
          NSLog(
            "[ChatEngine] loadOlderHistory FAIL chatId=%@ duration=%lldms error=%@",
            String(chatId.prefix(12)), durationMs, error.localizedDescription)
          self.appendJournalLocked(
            event: "native-chat-older-history-load-error",
            payload: ["chatId": chatId, "error": error.localizedDescription])
          self.postChangeLocked(
            reason: "engineError",
            userInfo: ["state": self.statusSnapshotLocked(), "error": error.localizedDescription])
          return
        }
        guard let http = response as? HTTPURLResponse else {
          NSLog(
            "[ChatEngine] loadOlderHistory FAIL chatId=%@ duration=%lldms error=invalid_response",
            String(chatId.prefix(12)), durationMs)
          self.appendJournalLocked(
            event: "native-chat-older-history-load-error",
            payload: ["chatId": chatId, "error": "invalid_response"])
          return
        }
        guard (200...299).contains(http.statusCode), let data else {
          NSLog(
            "[ChatEngine] loadOlderHistory FAIL chatId=%@ duration=%lldms status=%d",
            String(chatId.prefix(12)), durationMs, http.statusCode)
          self.appendJournalLocked(
            event: "native-chat-older-history-load-error",
            payload: ["chatId": chatId, "status": http.statusCode])
          return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
          self.appendJournalLocked(
            event: "native-chat-older-history-load-error",
            payload: ["chatId": chatId, "error": "invalid_json_expected_messages_array"])
          return
        }

        let responseDict = object as? [String: Any]
        let messagesArray: [[String: Any]]
        if let array = object as? [[String: Any]] {
          messagesArray = array
        } else if let array = responseDict?["data"] as? [[String: Any]] {
          messagesArray = array
        } else if let array = responseDict?["messages"] as? [[String: Any]] {
          messagesArray = array
        } else {
          self.appendJournalLocked(
            event: "native-chat-older-history-load-error",
            payload: ["chatId": chatId, "error": "invalid_json_expected_messages_array"])
          return
        }

        let olderRows = self.buildHistoryRowsLocked(chatId: chatId, rawMessages: messagesArray)
          .filter { !self.isTransientStreamRow($0) }
        if let responseDict {
          self.applyHistoryPaginationMetadataLocked(
            chatId: chatId, response: responseDict, remoteRows: olderRows)
        }
        guard !olderRows.isEmpty else {
          self.historyHasMoreByChat[chatId] = false
          self.historyNextCursorByChat.removeValue(forKey: chatId)
          self.historyNextCursorBoundaryByChat.removeValue(forKey: chatId)
          self.historyOlderExhaustedChats.insert(chatId)
          NSLog(
            "[ChatEngine] loadOlderHistory chatId=%@ source=network rows=0 exhausted=Y",
            String(chatId.prefix(12)))
          self.appendJournalLocked(
            event: "native-chat-older-history-load-ok",
            payload: ["chatId": chatId, "source": "network", "rows": 0, "exhausted": true])
          return
        }

        let existingCount = self.historyRowsByChat[chatId]?.count ?? 0
        // Same reason as the store branch above: the core pages back with the list.
        self.feedCoreRawFramesLocked(
          chatId: chatId, rawMessages: messagesArray, source: .historyPage)
        let (rows, delta) = self.ingestHistoryRowsLocked(chatId: chatId, remoteRows: olderRows)
        self.historyRowsByChat[chatId] = rows
        _ = self.persistHistoryRowsToStoreLocked(
          chatId: chatId, rows: olderRows, skipPrune: true)
        self.state["updatedAt"] = self.nowMs()
        let prependedCount = max(0, rows.count - existingCount)
        let exhausted = self.historyOlderExhaustedChats.contains(chatId)
        NSLog(
          "[ChatEngine] loadOlderHistory chatId=%@ source=network rows=%d exhausted=%@",
          String(chatId.prefix(12)), prependedCount, exhausted ? "Y" : "N")
        self.appendJournalLocked(
          event: "native-chat-older-history-load-ok",
          payload: [
            "chatId": chatId,
            "source": "network",
            "rows": prependedCount,
            "exhausted": exhausted,
          ])
        self.postChangeLocked(
          reason: "chatRowsReloaded",
          userInfo: [
            "chatId": chatId,
            "state": self.statusSnapshotLocked(),
            "prependedOlder": prependedCount,
          ])
        self.postChatDeltaLocked(
          chatId: chatId, inserted: delta.insertedIds, updated: delta.updatedIds,
          deleted: delta.deletedIds, source: "history")
      }
    }.resume()
    return true
  }

  private func historyNetworkSyncDefaultsKey(userId: String, chatId: String) -> String {
    "chat.history.lastNetworkSyncMs.\(userId).\(chatId)"
  }

  private func lastHistoryNetworkSyncAtLocked(chatId: String) -> Int? {
    if let cached = historyLastNetworkSyncAtByChat[chatId] {
      return cached
    }
    guard let userId = chatHistoryCacheUserIdLocked() else { return nil }
    let value = UserDefaults.standard.object(
      forKey: historyNetworkSyncDefaultsKey(userId: userId, chatId: chatId)) as? NSNumber
    let ms = value?.intValue
    if let ms, ms > 0 {
      historyLastNetworkSyncAtByChat[chatId] = ms
    }
    return ms
  }

  private func markHistoryNetworkSyncedLocked(chatId: String) {
    let ms = Int(nowMs())
    historyLastNetworkSyncAtByChat[chatId] = ms
    guard let userId = chatHistoryCacheUserIdLocked() else { return }
    UserDefaults.standard.set(
      ms, forKey: historyNetworkSyncDefaultsKey(userId: userId, chatId: chatId))
  }

  private func isHistoryNetworkSyncFreshLocked(chatId: String) -> Bool {
    guard let last = lastHistoryNetworkSyncAtLocked(chatId: chatId), last > 0 else {
      return false
    }
    return (Int(nowMs()) - last) < historyRevalidationTTLMs
  }

  private func loadChatHistoryIfNeededLocked(chatId: String, force: Bool = false) {
    guard !chatId.isEmpty else { return }
    // Only the built-in agent surface has no server chat to fetch. Bridge DMs are
    // ordinary chats at the transcript layer: their settled turns are canonical server
    // messages, and fetching them is what backfills SQLite so a cold open paints — the
    // old skip here (plus the in-memory wipe it did) is why an agent DM could show
    // content only for as long as the process lived.
    guard !isBuiltInAgentChatId(chatId), !isAgentDMForPersistenceLocked(chatId: chatId) else {
      historyLoadingChats.remove(chatId)
      // Agent/bridge DMs are volatile-per-session: a server backfill would repaint the
      // very transcript we keep off disk, so a cold launch would flicker (paint→wipe)
      // again. Skip the fetch; the live bridge pipeline delivers the current run's rows.
      if isAgentDMForPersistenceLocked(chatId: chatId) {
        markAgentDMChatForPersistenceLocked(chatId: chatId)
      }
      appendJournalLocked(
        event: "native-chat-history-skip",
        payload: ["chatId": chatId, "reason": "agent_surface"]
      )
      VibeDebugLog.log("[ChatEngine] loadChatHistory SKIP chatId=%@ reason=agent_surface", chatId)
      return
    }
    if historyLoadingChats.contains(chatId) || historyLoadingOlderChats.contains(chatId) { return }
    if !force, historyFullyLoadedChats.contains(chatId) {
      // Already network-confirmed this process — no need to hit the server again.
      if !historyRowsRestoredFromCacheChats.contains(chatId) {
        return
      }
      // Restored from SQLite on cold open. Previously we ALWAYS revalidated every
      // restored chat on launch (logs: 8 MERGEs with unchanged=Y, seconds of work).
      // If the last successful network sync is still within TTL, trust the local
      // store and skip — realtime socket still delivers live deltas.
      if isHistoryNetworkSyncFreshLocked(chatId: chatId) {
        historyRowsRestoredFromCacheChats.remove(chatId)
        NSLog(
          "[ChatEngine] loadChatHistory SKIP chatId=%@ reason=restored_fresh_ttl",
          String(chatId.prefix(12)))
        return
      }
    }
    let isBridgeText = isBridgeTextModeLocked()
    let apiBase = apiBaseURLLocked()
    let bridgeURL = bridgeURLLocked("/bridge/v1/chat/history")
    guard let userId = normalizedString(getConfigValueLocked("userId")),
      (isBridgeText ? bridgeURL != nil : apiBase != nil)
    else {
      NSLog(
        "[ChatEngine] loadChatHistory SKIP chatId=%@ reason=missing_config",
        String(chatId.prefix(12)))
      appendJournalLocked(
        event: "native-chat-history-skip",
        payload: [
          "chatId": chatId,
          "reason": "missing_config",
        ])
      return
    }

    // saved_messages uses a different API endpoint: /api/saved_messages/{userId}
    let isSavedMessages = chatId == "saved_messages"

    historyLoadingChats.insert(chatId)
    let token = authHeaderTokenLocked()
    let finalUrl: URL
    var request: URLRequest
    if isBridgeText, let bridgeURL {
      finalUrl = bridgeURL
      request = URLRequest(url: finalUrl)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try? JSONSerialization.data(
        withJSONObject: [
          "chatId": chatId,
          "userId": userId,
          "limit": chatHistoryFetchLimit,
          "savedMessages": isSavedMessages,
        ],
        options: []
      )
    } else if isSavedMessages, let apiBase {
      finalUrl = apiBase.appendingPathComponent("api").appendingPathComponent("saved_messages")
        .appendingPathComponent(userId)
      request = URLRequest(url: finalUrl)
      request.httpMethod = "GET"
    } else if let apiBase {
      let baseMessageUrl = apiBase.appendingPathComponent("api").appendingPathComponent("chat")
        .appendingPathComponent(chatId).appendingPathComponent("messages")
      var urlComponents = URLComponents(url: baseMessageUrl, resolvingAgainstBaseURL: false)
      urlComponents?.queryItems = [URLQueryItem(name: "limit", value: "\(chatHistoryFetchLimit)")]
      finalUrl = urlComponents?.url ?? baseMessageUrl
      request = URLRequest(url: finalUrl)
      request.httpMethod = "GET"
    } else {
      historyLoadingChats.remove(chatId)
      return
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let token, !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    let fetchStartMs = self.nowMs()
    VibeDebugLog.log(
      "[ChatEngine] loadChatHistory START chatId=%@ limit=%d url=%@",
      String(chatId.prefix(12)),
      chatHistoryFetchLimit,
      request.url?.absoluteString ?? "nil")
    appendJournalLocked(event: "native-chat-history-load-start", payload: ["chatId": chatId])

    // Use a pinned URLSession with the same cert pinning + TLS enforcement
    // as the WebSocket connection, instead of URLSession.shared.
    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        let durationMs = self.nowMs() - fetchStartMs
        self.historyLoadingChats.remove(chatId)
        if let error {
          NSLog(
            "[ChatEngine] loadChatHistory FAIL chatId=%@ duration=%lldms error=%@",
            String(chatId.prefix(12)), durationMs, error.localizedDescription)
          self.appendJournalLocked(
            event: "native-chat-history-load-error",
            payload: [
              "chatId": chatId,
              "error": error.localizedDescription,
            ])
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "engineError",
            userInfo: ["state": snapshot, "error": error.localizedDescription])
          return
        }
        guard let http = response as? HTTPURLResponse else {
          NSLog(
            "[ChatEngine] loadChatHistory FAIL chatId=%@ duration=%lldms error=invalid_response",
            String(chatId.prefix(12)), durationMs)
          self.appendJournalLocked(
            event: "native-chat-history-load-error",
            payload: [
              "chatId": chatId,
              "error": "invalid_response",
            ])
          return
        }
        guard (200...299).contains(http.statusCode), let data else {
          NSLog(
            "[ChatEngine] loadChatHistory FAIL chatId=%@ duration=%lldms status=%d",
            String(chatId.prefix(12)), durationMs, http.statusCode)
          self.appendJournalLocked(
            event: "native-chat-history-load-error",
            payload: [
              "chatId": chatId,
              "status": http.statusCode,
            ])
          return
        }
        VibeDebugLog.log(
          "[ChatEngine] loadChatHistory OK chatId=%@ duration=%lldms bytes=%d",
          String(chatId.prefix(12)),
          durationMs, data.count)
        if isSavedMessages {
          self.applySavedMessagesHistoryResponseLocked(data: data)
        } else {
          self.applyChatHistoryResponseLocked(chatId: chatId, data: data)
        }
      }
    }.resume()
  }

  /// Hands raw server frames to the Rust core.
  ///
  /// Called from the ingest paths, on the engine queue, with the frames exactly as
  /// received.
  ///
  /// **Starts the core if the gate is open**, rather than waiting for a chat
  /// surface to bring one up. Ingest happens at launch — the store restore runs
  /// long before any chat is opened — so a core that only exists once a surface
  /// arms it misses the entire transcript and then reports an empty window for a
  /// chat the user is reading. Gated on the render-path flag so a build with the
  /// core off pays neither a worker thread nor the ingest.
  ///
  /// Best-effort by design. A rejected frame is counted inside the core and the
  /// Swift path is unaffected — during the migration the core is a second reader
  /// of the same bytes, and a core that cannot keep up must never delay a message
  /// the user is waiting for.
  private func feedCoreRawFramesLocked(
    chatId: String, rawMessages: [[String: Any]], source: VibeFfiSource
  ) {
    guard !rawMessages.isEmpty else { return }
    guard VibeTimelineUserDefaultsFeatureFlags.isDirectMessageRenderPathEnabled() else { return }
    guard let core = VibeCoreBridge.sharedCore(ownUserId: currentUserIdLocked() ?? "") else {
      return
    }
    guard JSONSerialization.isValidJSONObject(rawMessages),
      let json = try? JSONSerialization.data(withJSONObject: rawMessages)
    else {
      VibeLog.warning(
        "core ingest skipped — page is not JSON-serializable", category: "core",
        metadata: ["chat": String(chatId.prefix(12)), "rows": String(rawMessages.count)])
      return
    }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    do {
      try core.ingestFrames(
        chatId: chatId, jsonArray: json, source: source, receivedAtMs: now)
      // What went in, so "the core has 7 rows for a 55-message chat" can be read as
      // either "it was never fed" or "it dropped them". Without this the two are
      // indistinguishable and the next step is a guess.
      NSLog(
        "[VibeCore] fed chat=%@ frames=%d source=%@",
        String(chatId.prefix(12)), rawMessages.count, String(describing: source))
    } catch {
      VibeLog.warning(
        "core ingest rejected", category: "core",
        metadata: [
          "chat": String(chatId.prefix(12)), "error": String(describing: error),
        ])
    }
  }

  /// Tells the core a message is gone.
  ///
  /// The core is fed *frames*, and a deletion has no frame — the server sends an id
  /// and a scope, never a message — so there was no path by which the core could
  /// learn about one. That was invisible while the core only reported geometry, and
  /// became a user-visible bug the moment its window became the list's content: the
  /// engine dropped the row, the core's next publish put it straight back, and the
  /// deleted cell reappeared on screen (device run 2026-08-04, `sqlite=999→998` while
  /// `authority LIVE rows=200` still carried the row).
  ///
  /// Hooked at ``markLiveMessageDeletedLocked(chatId:messageId:)`` because that is the
  /// one funnel every delete path already passes through — optimistic send, server
  /// `message-deleted`, pending-push failure and history reconciliation alike.
  private func feedCoreDeleteLocked(chatId: String, messageId: String) {
    guard VibeTimelineUserDefaultsFeatureFlags.isDirectMessageRenderPathEnabled() else { return }
    guard let core = VibeCoreBridge.sharedCore(ownUserId: currentUserIdLocked() ?? "") else {
      return
    }
    // Scope is not carried here and does not need to be: a tombstone is a tombstone
    // as far as this device's transcript is concerned, and "delete for me" and
    // "delete for everyone" both mean the row leaves *this* window.
    try? core.deleteMessage(
      chatId: chatId, messageId: messageId, forEveryone: true,
      tombstoneMs: Int64(Date().timeIntervalSince1970 * 1000))
  }

  // MARK: - Repairing a missed clear
  //
  // `chat-deleted` is a fire-and-forget socket push, and it is the ONLY thing that used to
  // tell a peer its chat had been deleted for both sides. The device exports from
  // 2026-08-06 are wall-to-wall `ws dead socket reason=heartbeat_timeout` /
  // `Software caused connection abort`, so missing that push is the ordinary case, not an
  // exotic one — and missing it was permanent. The server filters cleared messages out of
  // every subsequent response, so it can never re-send what the peer is holding, and
  // nothing on the client compared the two. The result is exactly the reported symptom:
  // one phone deletes a conversation for both sides, the other keeps rendering all of it,
  // forever, with no error anywhere.
  //
  // The server now publishes the clear POINT (`messagesClearedAt`) on every chat row, so
  // any refresh is enough to notice and repair. This is where that repair lands.

  /// Clear points already applied on this device, per chat. A home refresh runs several
  /// times a minute and almost always has nothing to do; this is what makes the common
  /// case a dictionary lookup instead of a store scan.
  private var appliedMessagesClearedAtByChat: [String: Int64] = [:]

  /// Drop every locally-held message at or before a clear point the server reports.
  ///
  /// Matches the server's own predicate exactly — it keeps `timestamp > cleared_at`, so
  /// this keeps `ts > clearedAtMs` — because a client that disagreed by one millisecond
  /// would resurrect a row on every refresh and look like a flickering bug.
  ///
  /// Deliberately NOT `clearChatStateLocked`: that wipes the conversation whole, which is
  /// right for "delete this chat" but wrong here. A clear point can be older than the
  /// newest message (the peer messaged again after the delete, and the server restored the
  /// row via `restore_if_deleted`), and those newer messages are real.
  func applyRemoteMessagesClearedAt(chatId: String, clearedAtMs: Int64) {
    guard !chatId.isEmpty, clearedAtMs > 0 else { return }
    queue.async { [weak self] in
      self?.applyRemoteMessagesClearedAtLocked(chatId: chatId, clearedAtMs: clearedAtMs)
    }
  }

  private func applyRemoteMessagesClearedAtLocked(chatId: String, clearedAtMs: Int64) {
    guard (appliedMessagesClearedAtByChat[chatId] ?? Int64.min) < clearedAtMs else { return }
    appliedMessagesClearedAtByChat[chatId] = clearedAtMs

    var droppedFromStore = 0
    if let userId = chatHistoryCacheUserIdLocked() {
      let stale = messageStore.messageIdsWithTimestamps(userId: userId, chatId: chatId)
        .filter { $0.ts <= clearedAtMs }
        .map(\.messageId)
      if !stale.isEmpty {
        messageStore.deleteMessages(userId: userId, chatId: chatId, messageIds: stale)
        droppedFromStore = stale.count
      }
    }

    let historyBefore = historyRowsByChat[chatId]?.count ?? 0
    if let rows = historyRowsByChat[chatId] {
      historyRowsByChat[chatId] = rows.filter { messageTimestampMs(fromRow: $0) > clearedAtMs }
    }
    let liveBefore = liveMessageRowsByChat[chatId]?.count ?? 0
    if let live = liveMessageRowsByChat[chatId] {
      liveMessageRowsByChat[chatId] = live.filter {
        messageTimestampMs(fromRow: $0.value) > clearedAtMs
      }
    }
    let droppedFromMemory =
      (historyBefore - (historyRowsByChat[chatId]?.count ?? 0))
      + (liveBefore - (liveMessageRowsByChat[chatId]?.count ?? 0))

    // The core is a second reader of the same transcript; leaving it holding the cleared
    // rows means a core-authoritative list paints straight back over the wipe. `+1`
    // because the reducer's cutoff is exclusive (`retain(ts_ms >= cutoff)`).
    if let core = VibeCoreBridge.sharedCore(ownUserId: currentUserIdLocked() ?? "") {
      try? core.clearChat(
        chatId: chatId, beforeTsMs: clearedAtMs &+ 1, clearedAtMs: clearedAtMs)
    }

    guard droppedFromStore > 0 || droppedFromMemory > 0 else { return }

    // Heights and the warm snapshot describe rows that no longer exist. Left behind, the
    // next open sizes a transcript against a content size for messages it will not show.
    VibeTimelinePreparedStore.shared.invalidate(chatId: chatId)
    ChatListView.clearWarmTranscriptSnapshot(chatId: chatId)

    VibeLog.notice(
      "repaired a missed remote clear",
      category: "engine",
      metadata: [
        "chat": String(chatId.prefix(12)),
        "clearedAtMs": String(clearedAtMs),
        "droppedStore": String(droppedFromStore),
        "droppedMemory": String(droppedFromMemory),
      ])
    appendJournalLocked(
      event: "native-chat-clear-repair",
      payload: ["chatId": chatId, "clearedAtMs": clearedAtMs, "dropped": droppedFromStore])
    state["updatedAt"] = nowMs()
    postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId])
    postChangeLocked(reason: "chatCleared", userInfo: ["chatId": chatId])
  }

  /// Tells the core the whole chat was cleared (Clear Chat for me / for both).
  ///
  /// Same class of bug as ``feedCoreDeleteLocked``: clear is not a frame, so without
  /// an explicit command the reducer's window keeps every row and the list paints
  /// them back after the engine and SQLite are empty.
  private func feedCoreClearChatLocked(chatId: String) {
    // Always try: Clear Chat must empty the core even when the DM render-path flag
    // is off, because a later open that arms the flag would otherwise restore a
    // non-empty window from the still-live reducer.
    guard let core = VibeCoreBridge.sharedCore(ownUserId: currentUserIdLocked() ?? "") else {
      return
    }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    do {
      try core.clearChat(chatId: chatId, beforeTsMs: nil, clearedAtMs: now)
      NSLog("[VibeCore] clear chat=%@", String(chatId.prefix(12)))
    } catch {
      VibeLog.warning(
        "core clear rejected", category: "core",
        metadata: [
          "chat": String(chatId.prefix(12)), "error": String(describing: error),
        ])
    }
  }

  private func applyChatHistoryResponseLocked(chatId: String, data: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
      appendJournalLocked(
        event: "native-chat-history-load-error",
        payload: [
          "chatId": chatId,
          "error": "invalid_json_expected_messages_array",
        ])
      return
    }

    let messagesArray: [[String: Any]]
    if let array = object as? [[String: Any]] {
      messagesArray = array
    } else if let dict = object as? [String: Any], let array = dict["data"] as? [[String: Any]] {
      messagesArray = array
    } else if let dict = object as? [String: Any], let array = dict["messages"] as? [[String: Any]]
    {
      messagesArray = array
    } else {
      appendJournalLocked(
        event: "native-chat-history-load-error",
        payload: [
          "chatId": chatId,
          "error": "invalid_json_expected_messages_array",
        ])
      return
    }

    // Hand the page to the Rust core **before** Swift canonicalizes it. These are
    // the bytes as the server sent them, which is what `VibeCoreEventV1::RawFrames`
    // is specified to carry — the core does its own alias resolution, envelope
    // open, media fold and dedup from the original frame. Feeding it Swift's
    // already-normalized output instead would make the core a re-parser of a parse
    // and leave the divergence it exists to remove.
    feedCoreRawFramesLocked(chatId: chatId, rawMessages: messagesArray, source: .historyPage)

    let remoteRows = buildHistoryRowsLocked(chatId: chatId, rawMessages: messagesArray)
    if let response = object as? [String: Any] {
      applyHistoryPaginationMetadataLocked(
        chatId: chatId, response: response, remoteRows: remoteRows)
    }
    let existingRows = historyRowsByChat[chatId] ?? []
    let existingRowsCount = existingRows.count
    let liveRowsCount = liveMessageRowsByChat[chatId]?.count ?? 0
    let (rows, delta) = ingestHistoryRowsLocked(chatId: chatId, remoteRows: remoteRows)
    // Refetch reconciliation that changed nothing must not repaint: the view already
    // rendered these exact rows from cache, and the reload notification would send the
    // whole transcript back through the full parse/diff/layout pipeline on main.
    let isUnchangedRefetch = !existingRows.isEmpty && (rows as NSArray).isEqual(to: existingRows)
    // An empty/failed refresh must never wipe rows we already restored from the local
    // store. A dormant chat whose server page comes back empty would otherwise blank a
    // transcript the cache had just painted (the failure mode that only becomes
    // reachable once persistence above is unconditional). Adopt an empty result only
    // when there is nothing better on screen.
    var adoptedFromStore = false
    if rows.isEmpty, existingRows.isEmpty {
      // The fetch returned NOTHING for this chat. Before adopting an empty transcript —
      // what the user sees as "this chat opens empty on every launch" — give the durable
      // store its turn: it may hold a full transcript this particular page simply did not
      // return (dormant chat, archived window, partial outage). Dropping the flags first
      // is what lets the restore actually read SQLite instead of short-circuiting.
      historyRowsByChat.removeValue(forKey: chatId)
      historyFullyLoadedChats.remove(chatId)
      adoptedFromStore = restoreCachedHistoryRowsLocked(chatId: chatId)
      if adoptedFromStore {
        NSLog(
          "[HistoryStore] empty-fetch chat=%@ — repainted %d rows from the local store",
          String(chatId.prefix(12)), historyRowsByChat[chatId]?.count ?? 0)
      }
    }
    if !adoptedFromStore {
      if !rows.isEmpty || existingRows.isEmpty {
        historyRowsByChat[chatId] = rows
      }
      historyFullyLoadedChats.insert(chatId)
      historyRowsRestoredFromCacheChats.remove(chatId)
    }
    // Stamp network success even when the merge is unchanged — next cold open can
    // skip revalidation while this TTL holds.
    markHistoryNetworkSyncedLocked(chatId: chatId)
    storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
    state["updatedAt"] = nowMs()
    appendJournalLocked(
      event: "native-chat-history-load-ok",
      payload: [
        "chatId": chatId,
        "rows": rows.count,
        "remoteRows": remoteRows.count,
        "existingRows": existingRowsCount,
        "liveRows": liveRowsCount,
        "messages": messagesArray.count,
      ])
    // `messages` (what the server actually sent) vs `remoteRows` (what survived row
    // building) separates "the server has nothing" from "we dropped everything it sent";
    // `store` says whether the durable transcript exists regardless of either.
    let storedRowCount =
      chatHistoryCacheUserIdLocked().map {
        messageStore.messageCount(userId: $0, chatId: chatId)
      } ?? -1
    NSLog(
      "[ChatEngine] loadChatHistory MERGE chatId=%@ messages=%d remoteRows=%d existingRows=%d liveRows=%d mergedRows=%d store=%d unchanged=%@",
      String(chatId.prefix(12)),
      messagesArray.count,
      remoteRows.count,
      existingRowsCount,
      liveRowsCount,
      historyRowsByChat[chatId]?.count ?? rows.count,
      storedRowCount,
      isUnchangedRefetch ? "Y" : "N"
    )
    scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "history_loaded")
    guard !isUnchangedRefetch else { return }
    let snapshot = statusSnapshotLocked()
    postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId, "state": snapshot])
    postChatDeltaLocked(
      chatId: chatId,
      inserted: delta.insertedIds,
      updated: delta.updatedIds,
      deleted: delta.deletedIds,
      source: "history")
  }

  private func applySavedMessagesHistoryResponseLocked(data: Data) {
    let chatId = "saved_messages"
    let rawItems = parseSavedMessagesServerItems(data)
    guard !rawItems.isEmpty else {
      appendJournalLocked(
        event: "native-chat-history-load-error",
        payload: [
          "chatId": chatId,
          "error": "empty_saved_messages_response",
        ])
      // An empty saved-messages response is NOT evidence that saved messages were
      // deleted — it is equally a hiccup, an auth blip or an outage. It used to be
      // treated as truth twice over: it wiped the durable transcript AND installed an
      // empty in-memory array, which then satisfied every later restore. Absence is
      // never delete evidence; fall back to whatever the local store holds.
      cachedSavedMessagesResponse = []
      if (historyRowsByChat[chatId] ?? []).isEmpty {
        historyRowsByChat.removeValue(forKey: chatId)
        historyFullyLoadedChats.remove(chatId)
        if !restoreCachedHistoryRowsLocked(chatId: chatId) {
          historyRowsByChat[chatId] = []
          historyFullyLoadedChats.insert(chatId)
          historyRowsRestoredFromCacheChats.remove(chatId)
        }
      }
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId, "state": snapshot])
      return
    }
    let normalized = normalizeSavedMessagesLocked(rawItems)
    cachedSavedMessagesResponse = normalized
    let previousRows = historyRowsByChat[chatId] ?? []
    let rows = buildHistoryRowsLocked(chatId: chatId, rawMessages: normalized)
    historyRowsByChat[chatId] = rows
    historyFullyLoadedChats.insert(chatId)
    historyRowsRestoredFromCacheChats.remove(chatId)
    markHistoryNetworkSyncedLocked(chatId: chatId)
    storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
    // list_saved_messages returns the COMPLETE set, so this response is authoritative:
    // anything on disk it doesn't list is a ghost (a re-keyed twin, an unsave from
    // another device) and must go now, or the next cold-open restore repaints it.
    reconcileStoreAgainstCanonicalLocked(
      chatId: chatId,
      canonicalIds: Set(rows.compactMap { messageId(fromRow: $0) }))
    state["updatedAt"] = nowMs()
    appendJournalLocked(
      event: "native-chat-history-load-ok",
      payload: [
        "chatId": chatId,
        "rows": rows.count,
        "messages": rawItems.count,
      ])
    scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "history_loaded")
    let snapshot = statusSnapshotLocked()
    postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId, "state": snapshot])
    let previousById = Dictionary(
      uniqueKeysWithValues: previousRows.compactMap { row in
        messageId(fromRow: row).map { ($0, row) }
      })
    let rowsById = Dictionary(
      uniqueKeysWithValues: rows.compactMap { row in
        messageId(fromRow: row).map { ($0, row) }
      })
    let previousIds = Set(previousById.keys)
    let ids = Set(rowsById.keys)
    let updatedIds = ids.intersection(previousIds).filter { id in
      guard let previous = previousById[id], let row = rowsById[id] else { return false }
      return !(row as NSDictionary).isEqual(to: previous)
    }.sorted()
    postChatDeltaLocked(
      chatId: chatId,
      inserted: ids.subtracting(previousIds).sorted(),
      updated: updatedIds,
      deleted: previousIds.subtracting(ids).sorted(),
      source: "savedMessages")
  }

  private func buildHistoryRowsLocked(chatId: String, rawMessages: [[String: Any]]) -> [[String:
    Any]]
  {
    let sortedMessages = rawMessages.sorted { lhs, rhs in
      transcriptOrderPrecedes(
        lhsTs: transcriptTimestampMs(lhs), lhsId: rawMessageIdForOrdering(lhs, chatId: chatId),
        rhsTs: transcriptTimestampMs(rhs), rhsId: rawMessageIdForOrdering(rhs, chatId: chatId))
    }
    let rows: [[String: Any]] = sortedMessages.compactMap { (raw: [String: Any]) -> [String: Any]? in
      // Saved messages carry TWO ids: the server row's UUID (`id`) and the client's
      // `original_message_id`. Every other saved-messages path (normalize, the send echo)
      // keys rows by the ORIGINAL id — preferring `id` here re-keyed the same transcript
      // under a second generation whenever Home's seed passed raw server dicts through
      // this builder. The append-only SQLite store then held BOTH generations and every
      // cold-open restore painted each message twice (the duplicated-cells screenshot).
      let preferredId =
        chatId == "saved_messages"
        ? raw["original_message_id"] ?? raw["originalMessageId"] ?? raw["id"] ?? raw["message_id"]
        : raw["id"] ?? raw["message_id"]
      guard let messageId = normalizedString(preferredId) else { return nil }
      let fromId = normalizedString(raw["fromId"] ?? raw["from_id"])
      let type = normalizedString(raw["type"]) ?? "text"
      // A message with no readable timestamp gets this device's clock, and that value is
      // then PERSISTED as if the server had sent it — so two devices that first parsed
      // the same message at different moments disagree about where it belongs, forever,
      // and no refresh talks either of them out of it. It is the one ordering divergence
      // in this file that cannot heal itself.
      //
      // The fallback stays (a row with no slot is worse than a row in a wrong slot), but
      // it is no longer silent. Reading through the shared helper already removes the
      // likely way to get here: a present-but-unparseable `timestamp` shadowing a good
      // numeric `timestampMs` in the same dictionary.
      let parsedTimestampMs = transcriptTimestampMs(raw)
      if parsedTimestampMs == nil {
        noteSynthesizedTimestamp(chatId: chatId, messageId: messageId, raw: raw)
      }
      let timestampMs = parsedTimestampMs ?? Int64(nowMs())
      let encryptedContent = normalizedString(raw["encryptedContent"] ?? raw["encrypted_content"])
      let plaintextFallback = normalizedString(raw["plaintext"] ?? raw["text"]) ?? ""
      let serverStatus = normalizedString(raw["status"])?.lowercased()
      let isEdited = ((raw["isEdited"] as? Bool) == true)
      let editedAt = raw["editedAt"] ?? raw["edited_at"]
      let rawMediaUrl = normalizedString(raw["mediaUrl"] ?? raw["media_url"])
      let rawFileName = normalizedString(raw["fileName"] ?? raw["file_name"])
      let rawMediaKey = normalizedString(raw["mediaKey"] ?? raw["media_key"])
      let rawMetadata = raw["metadata"] as? [String: Any]
      let derivedFileName = deriveFileNameFromURL(rawMediaUrl)
      let rawAgentId = firstNormalizedString(
        raw["agentId"], raw["agent_id"], rawMetadata?["agentId"], rawMetadata?["agent_id"])
      let rawAgentName = firstNormalizedString(
        raw["agentName"], raw["agent_name"], rawMetadata?["agentName"], rawMetadata?["agent_name"])
      let rawAgentUserId = firstNormalizedString(
        raw["agentUserId"], raw["agent_user_id"], rawMetadata?["agentUserId"],
        rawMetadata?["agent_user_id"])
      let rawAgentUsername = firstNormalizedString(
        raw["agentUsername"], raw["agent_username"], raw["agentHandle"], raw["agent_handle"],
        rawMetadata?["agentUsername"], rawMetadata?["agent_username"], rawMetadata?["agentHandle"],
        rawMetadata?["agent_handle"])

      let isMe = normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserIdLocked()
      let encryptedLooksHybrid = isLikelyHybridCiphertext(encryptedContent)
      let historyIsAgent =
        (raw["isAgentMessage"] as? Bool == true)
        || (raw["is_agent_message"] as? Bool == true)
        || (normalizedString(fromId)?.lowercased() == Self.agentUserId)
        || rawAgentId != nil
        || rawAgentName != nil
        || (rawMediaUrl?.lowercased().contains("/uploads/agent-docs/") == true)
        || (rawMediaUrl?.lowercased().contains("/api/agent/document/") == true)
      let agentPlainContent =
        normalizedString(raw["plainContent"] ?? raw["plain_content"])
        ?? normalizedString(raw["plaintext"])
        ?? encryptedContent
      let hadEncryptedContent = encryptedContent != nil && !encryptedContent!.isEmpty
      var historyDecryptionFailed = false
      let decryptedFields: [String: Any] = {
        if historyIsAgent {
          if let agentPlainContent, !agentPlainContent.isEmpty {
            return ["text": agentPlainContent]
          }
          return [:]
        }

        if let encryptedContent, !encryptedContent.isEmpty {
          // Same reasoning as the live path: an MLS envelope is opened by the
          // ratchet, and it must be tested before the hybrid check or it falls
          // into the `!encryptedLooksHybrid` arm and gets parsed as if the
          // envelope string were itself the payload JSON.
          if VibeSecureSessions.isMlsEnvelope(encryptedContent) {
            // Our own messages have no decryptable form — MLS encrypts to the
            // other members. Scrolling back through our own history would go
            // blank without the retained plaintext.
            if isMe, let mine = VibeSecureSessions.shared.ownPlaintext(messageId: messageId) {
              return parseDecryptedMessagePayload(mine)
            }
            guard
              let opened = VibeSecureSessions.shared.open(
                chatId: chatId, envelope: encryptedContent, isMine: isMe, messageId: messageId)
            else {
              historyDecryptionFailed = true
              return plaintextFallback.isEmpty ? [:] : ["text": plaintextFallback]
            }
            let parsed = parseDecryptedMessagePayload(opened)
            if !parsed.isEmpty { return parsed }
            historyDecryptionFailed = true
            return plaintextFallback.isEmpty ? [:] : ["text": plaintextFallback]
          }
          if !encryptedLooksHybrid {
            return parseDecryptedMessagePayload(encryptedContent)
          }
          guard let privateKey = decryptPrivateKeyLocked() else {
            historyDecryptionFailed = true
            return plaintextFallback.isEmpty ? [:] : ["text": plaintextFallback]
          }
          let decrypted = chatEngineDecryptHybridMessage(
            privateKey: privateKey,
            ciphertext: encryptedContent,
            isMyMessage: isMe
          )
          if decrypted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            historyDecryptionFailed = true
            return plaintextFallback.isEmpty ? [:] : ["text": plaintextFallback]
          }
          let parsed = parseDecryptedMessagePayload(decrypted)
          if !parsed.isEmpty { return parsed }
          historyDecryptionFailed = true
        }
        return plaintextFallback.isEmpty ? [:] : ["text": plaintextFallback]
      }()
      var enrichedFields = decryptedFields
      if let rawMetadata, enrichedFields["metadata"] == nil {
        enrichedFields["metadata"] = rawMetadata
      }
      if let rawReplyToId = normalizedString(raw["replyToId"] ?? raw["reply_to_id"]),
        normalizedString(enrichedFields["replyToId"] ?? enrichedFields["reply_to_id"]) == nil
      {
        enrichedFields["replyToId"] = rawReplyToId
      }
      if let rawReplyPreview = raw["replyPreview"] ?? raw["reply_preview"],
        enrichedFields["replyPreview"] == nil,
        enrichedFields["reply_preview"] == nil
      {
        enrichedFields["replyPreview"] = rawReplyPreview
      }
      if let rawReplyPreviewTitle = normalizedString(
        raw["replyPreviewTitle"] ?? raw["reply_preview_title"] ?? raw["replyAuthorName"]
          ?? raw["reply_author_name"]),
        normalizedString(enrichedFields["replyPreviewTitle"] ?? enrichedFields["reply_preview_title"])
          == nil
      {
        enrichedFields["replyPreviewTitle"] = rawReplyPreviewTitle
      }
      if let rawReplyPreviewText = normalizedString(
        raw["replyPreviewText"] ?? raw["reply_preview_text"] ?? raw["replyText"]
          ?? raw["reply_text"]),
        normalizedString(enrichedFields["replyPreviewText"] ?? enrichedFields["reply_preview_text"])
          == nil
      {
        enrichedFields["replyPreviewText"] = rawReplyPreviewText
      }
      if let rawMediaUrl, !rawMediaUrl.isEmpty, normalizedString(enrichedFields["mediaUrl"]) == nil
      {
        enrichedFields["mediaUrl"] = rawMediaUrl
      }
      // Prefer remote URL over a dead local file path left in metadata after reopen.
      if let existing = normalizedString(enrichedFields["mediaUrl"]), isLocalMediaURI(existing) {
        if let rawMediaUrl, !rawMediaUrl.isEmpty, !isLocalMediaURI(rawMediaUrl) {
          enrichedFields["mediaUrl"] = rawMediaUrl
        } else if let meta = enrichedFields["metadata"] as? [String: Any],
          let remote = normalizedString(meta["mediaUrl"] ?? meta["media_url"]),
          !remote.isEmpty, !isLocalMediaURI(remote)
        {
          enrichedFields["mediaUrl"] = remote
        } else {
          // Drop unusable local path so UI falls through to thumbs.
          enrichedFields.removeValue(forKey: "mediaUrl")
        }
      }
      // Promote durable thumbs from server metadata into decrypted fields.
      if let rawMetadata {
        if normalizedString(enrichedFields["thumbnailBase64"]) == nil,
          let thumb = normalizedString(
            rawMetadata["thumbnailBase64"] ?? rawMetadata["thumbnail_base64"])
        {
          enrichedFields["thumbnailBase64"] = thumb
        }
        if (enrichedFields["attachmentThumbnailsB64"] as? [String])?.isEmpty != false,
          let thumbs = rawMetadata["attachmentThumbnailsB64"] as? [String], !thumbs.isEmpty
        {
          enrichedFields["attachmentThumbnailsB64"] = thumbs
          var meta = (enrichedFields["metadata"] as? [String: Any]) ?? [:]
          meta["attachmentThumbnailsB64"] = thumbs
          enrichedFields["metadata"] = meta
        }
      }
      let resolvedMedia = normalizedString(enrichedFields["mediaUrl"])
      let hasThumb =
        normalizedString(enrichedFields["thumbnailBase64"]) != nil
        || ((enrichedFields["attachmentThumbnailsB64"] as? [String])?.isEmpty == false)
        || ((rawMetadata?["thumbnailBase64"] as? String)?.isEmpty == false)
      if normalizedString(enrichedFields["mediaKey"]) == nil {
        let keyFromRaw = rawMediaKey
        let keyFromMeta = normalizedString(
          rawMetadata?["mediaKey"] ?? rawMetadata?["media_key"])
        if let key = keyFromRaw ?? keyFromMeta, !key.isEmpty {
          enrichedFields["mediaKey"] = key
        }
      }
      let fileNameForRow =
        rawFileName
        ?? ((normalizedString(type)?.lowercased() == "file") ? derivedFileName : nil)
      if let fileNameForRow, !fileNameForRow.isEmpty,
        normalizedString(enrichedFields["fileName"]) == nil
      {
        enrichedFields["fileName"] = fileNameForRow
      }
      // If type collapsed to text but we have media evidence, restore image type for list/profile.
      var resolvedType = type
      if (resolvedType == "text" || resolvedType.isEmpty),
        (resolvedMedia != nil && !(resolvedMedia?.isEmpty ?? true)) || hasThumb
      {
        resolvedType = "image"
      }
      var row = buildLiveRowPayloadLocked(
        chatId: chatId,
        messageId: messageId,
        fromId: fromId,
        type: resolvedType,
        timestampMs: timestampMs,
        encryptedContent: encryptedContent,
        decryptedFields: enrichedFields,
        forceEdited: isEdited,
        forceEditedAt: editedAt
      )
      if historyIsAgent, var message = row["message"] as? [String: Any] {
        message["isAgentMessage"] = true
        message["isMe"] = false
        if let rawAgentId { message["agentId"] = rawAgentId }
        if let agentUserId = rawAgentUserId ?? fromId {
          message["agentUserId"] = agentUserId
        }
        if let username = rawAgentUsername {
          message["agentUsername"] = username.trimmingCharacters(
            in: CharacterSet(charactersIn: "@"))
        }
        if let rawAgentName { message["agentName"] = rawAgentName }
        if let agentPlainContent, !agentPlainContent.isEmpty {
          message["plainContent"] = agentPlainContent
          message["text"] = agentPlainContent
        }
        row["message"] = message
      }
      if var message = row["message"] as? [String: Any] {
        if let serverStatus { message["status"] = serverStatus }
        if let reactionEmoji = normalizedString(raw["reactionEmoji"] ?? raw["reaction_emoji"]) {
          message["reactionEmoji"] = reactionEmoji
        }
        if !historyIsAgent && hadEncryptedContent && encryptedLooksHybrid && historyDecryptionFailed
        {
          message["decryptionFailed"] = true
        }
        row["message"] = message
      }
      return row
    }
    return rowsByApplyingBubbleSequenceShapes(rows)
  }

  private func appendJournalLocked(event: String, payload: [String: Any]) {
    journalEntryCount = min(journalEntryCount + 1, 300)
    state["journalCount"] = journalEntryCount
    store.appendJournal([
      "event": event,
      "timestamp": nowMs(),
      "payload": sanitizeJournalPayload(makeJSONSafeMap(payload)),
    ])
  }

  /// Truncate sensitive identifiers in journal payloads to prevent
  /// leaking full chat/message/user IDs in plaintext storage.
  private func sanitizeJournalPayload(_ payload: [String: Any]) -> [String: Any] {
    let sensitiveKeys: Set<String> = ["chatId", "messageId", "userId", "peerUserId", "fromId"]
    var out = payload
    for key in sensitiveKeys {
      if let value = out[key] as? String, value.count > 8 {
        out[key] = String(value.prefix(8)) + "..."
      }
    }
    return out
  }

  private func postChatDeltaLocked(
    chatId: String,
    inserted: [String],
    updated: [String],
    deleted: [String],
    source: String
  ) {
    guard !inserted.isEmpty || !updated.isEmpty || !deleted.isEmpty else { return }
    let generation = (chatIngestGenerationByChat[chatId] ?? 0) + 1
    chatIngestGenerationByChat[chatId] = generation
    postChangeLocked(
      reason: "chatDelta",
      userInfo: [
        "chatId": chatId,
        "generation": generation,
        "insertedIds": inserted,
        "updatedIds": updated,
        "deletedIds": deleted,
        "source": source,
        "state": statusSnapshotLocked(),
      ])
    NSLog(
      "[ChatDelta] %@ chat=%@ gen=%d ins=%d upd=%d del=%d",
      source, chatId, generation, inserted.count, updated.count, deleted.count)
  }

  /// Copies the UI-polled state out to the mirror. Engine queue only.
  ///
  /// Called from ``postChangeLocked`` rather than from each mutation site: this
  /// is the funnel every UI-visible change already passes through, so hanging
  /// the publish here means a new mutation path cannot forget to update the
  /// mirror unless it also forgot to notify the UI — in which case the mirror is
  /// not what is broken.
  private func publishUIMirrorLocked() {
    // The first three assignments are copy-on-write retains, not deep copies.
    // Only the agent-progress transform allocates, over a map that holds one
    // entry per chat with a running agent.
    var progress: [String: ChatEngineAgentProgressSnapshot] = [:]
    progress.reserveCapacity(agentProgressByChatId.count)
    for (chatId, state) in agentProgressByChatId {
      progress[chatId] = ChatEngineAgentProgressSnapshot(
        label: state.label,
        tool: state.tool,
        status: state.status,
        updatedAtMs: state.updatedAtMs
      )
    }
    // Unanswered approval prompts, grouped the way they are read. The engine keys them
    // by request id and the getter scans; a chat with no agent running contributes
    // nothing, so this map is empty in the ordinary case.
    var pendingAsk: [String: [ChatEngineBridgeAskSnapshot]] = [:]
    for (requestId, payload) in agentBridgeAskByRequestId {
      guard !presentedAskRequestIds.contains(requestId) else { continue }
      guard let chatId = normalizedString(payload["chatId"]), !chatId.isEmpty else { continue }
      pendingAsk[chatId, default: []].append(
        ChatEngineBridgeAskSnapshot(
          requestId: requestId,
          chatId: chatId,
          kind: normalizedString(payload["kind"]) ?? "ask",
          provider: (normalizedString(payload["provider"]) ?? "").lowercased(),
          sessionId: normalizedString(payload["sessionId"] ?? payload["session_id"]) ?? "",
          resumedFromSessionId: normalizedString(
            payload["resumedFromSessionId"] ?? payload["resumed_from_session_id"]) ?? ""
        ))
    }
    // Dictionary iteration has no order, and the getter returns the *first* match. Sort
    // by request id so two reads of the same state cannot answer with different prompts
    // — an approval sheet that swaps which request it is answering mid-flight is worse
    // than one that is late.
    for (chatId, prompts) in pendingAsk where prompts.count > 1 {
      pendingAsk[chatId] = prompts.sorted { $0.requestId < $1.requestId }
    }
    uiMirror.publish(
      typingByChatId: peerTypingUserIdsByChatId,
      agentProgressByChatId: progress,
      onlineUserIds: onlineUsers,
      lastSeenByUserId: lastSeenByUserId,
      pendingAskByChatId: pendingAsk
    )
    // Sampled, so the export can answer "is the UI still queueing?" without a
    // profiler. `fallback` climbing after launch means the mirror stopped being
    // published and the stalls are back.
    uiMirrorPublishes += 1
    if uiMirrorPublishes % Self.uiMirrorLogInterval == 1 {
      let counts = uiMirror.counts
      VibeLog.info(
        "ui mirror", category: "engine",
        metadata: [
          "reads": String(counts.mirrorReads),
          "fallback": String(counts.fallbackReads),
          "publishes": String(counts.publishes),
        ])
    }
  }

  private var uiMirrorPublishes = 0
  private static let uiMirrorLogInterval = 200

  private func postChangeLocked(reason: String, userInfo: [String: Any]) {
    publishUIMirrorLocked()
    var info = userInfo
    info["reason"] = reason
    info["timestamp"] = nowMs()
    // Agent-bridge DM rows are excluded from the server-history cache, so persist
    // their settled rows whenever the chat's row set changes (debounced).
    if ["chatMessageInserted", "chatMessageChanged", "chatRowsReloaded"].contains(reason),
      let changedChatId = (userInfo["chatId"] as? String)?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      !changedChatId.isEmpty
    {
      scheduleVolatileBridgeRowsStoreLocked(chatId: changedChatId)
    }
    if ["chatMessageInserted", "chatMessageChanged", "chatRowsReloaded", "presenceChanged"]
      .contains(reason)
    {
      let rawChatId =
        (info["chatId"] as? String) ??
        (info["chat_id"] as? String) ??
        ""
      let chatId =
        rawChatId.count > 12 ? String(rawChatId.prefix(12)) + "..." : rawChatId
      VibeDebugLog.print(
        "[ChatEngine] didChange reason=\(reason) chatId=\(chatId.isEmpty ? "<empty>" : chatId)"
      )
      chatEngineUITrace(
        "ChatEngine didChange reason=\(reason) chatId=\(chatId.isEmpty ? "<empty>" : chatId)"
      )
    }
    // Always dispatch the notification asynchronously so the engine queue is
    // released before any observer runs. Posting synchronously while holding
    // the queue lock can deadlock: if the main thread is blocked in queue.sync
    // (e.g. from ChatEngine.isTyping called inside refreshHeaderState) while
    // the engine queue is running postChangeLocked, any observer that tries to
    // dispatch work back to the main thread creates a cross-thread lock
    // inversion that stalls the app for up to 40 seconds (the upload semaphore
    // timeout).
    let notification = Notification(name: Self.didChangeNotification, object: self, userInfo: info)
    DispatchQueue.main.async {
      NotificationCenter.default.post(notification)
    }
  }

  private func nowMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
  }

  private func syncOnQueue<T>(
    _ work: () -> T,
    function: StaticString = #function,
    file: StaticString = #fileID,
    line: UInt = #line
  ) -> T {
    if DispatchQueue.getSpecific(key: queueSpecificKey) == queueSpecificValue {
      return work()
    }
    guard Thread.isMainThread else {
      return queue.sync(execute: work)
    }

    // Main-thread read of the engine queue. If the queue is busy/blocked this
    // call freezes the UI for the full duration — and queue.sync only returns
    // once it unblocks, so a "log after the fact" never fires during a true
    // hang. Arm a background watchdog that reports WHILE we are still blocked,
    // identifying the exact main-thread call site so the offender is findable
    // from device logs even when the app never recovers.
    let start = CFAbsoluteTimeGetCurrent()
    let callSite = "\(function) (\(file):\(line))"
    let watchdog = DispatchSource.makeTimerSource(queue: ChatEngine.syncWatchdogQueue)
    watchdog.schedule(deadline: .now() + 0.75, repeating: 1.0)
    watchdog.setEventHandler {
      let blockedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
      NSLog(
        "[ChatEngine][MAIN-THREAD-HANG] main thread blocked %dms in syncOnQueue at %@",
        blockedMs, callSite)
    }
    watchdog.resume()
    let result = queue.sync(execute: work)
    watchdog.cancel()

    let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    if elapsedMs > 50 {
      // `callSite` is the ENGINE method that blocked — always `getChatRows` — which
      // cannot say who asked for it. Every ChatListView caller is already off-main, so
      // the blocker is somewhere else entirely, and 53 of these in one session (up to
      // 623ms) makes finding it the single biggest remaining main-thread item. The frames
      // only cost anything on a stall that has already happened.
      let callers = Thread.callStackSymbols.dropFirst(2).prefix(8)
        .map { symbol -> String in
          // Keep the demangled symbol, drop the address/module columns.
          let parts = symbol.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
          return parts.count >= 4 ? String(parts[3].prefix(70)) : symbol
        }
        .joined(separator: " ← ")
      NSLog(
        "[ChatEngine][MAIN-THREAD-SYNC-STALL] syncOnQueue blocked main thread for %dms at %@\n    via %@",
        elapsedMs, callSite, callers)
      // Also into the exportable log. Retiring these stalls is the scroll goal,
      // and a stall that only reaches the Xcode console cannot be measured from
      // a device the debugger is not attached to — which is every real run. The
      // >50 ms threshold keeps this rare enough not to crowd the ring.
      VibeLog.error(
        "main-thread stall in syncOnQueue", category: "engine",
        metadata: ["ms": String(elapsedMs), "callSite": callSite])
    }
    return result
  }

  private func normalizedString(_ value: Any?) -> String? {
    if let str = value as? String {
      let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : t
    }
    if let n = value as? NSNumber {
      return n.stringValue
    }
    return nil
  }

  private func firstNormalizedString(_ values: Any?...) -> String? {
    for value in values {
      if let normalized = normalizedString(value) {
        return normalized
      }
    }
    return nil
  }

  private func parseBooleanLike(_ value: Any?) -> Bool? {
    switch value {
    case let bool as Bool:
      return bool
    case let str as String:
      let normalized = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if ["1", "true", "yes", "on"].contains(normalized) {
        return true
      }
      if ["0", "false", "no", "off"].contains(normalized) {
        return false
      }
      return nil
    case let num as NSNumber:
      return num.boolValue
    default:
      return nil
    }
  }

  private func containsLinkCandidate(_ value: String?) -> Bool {
    guard let value, !value.isEmpty else { return false }
    let lower = value.lowercased()
    return lower.contains("http://") || lower.contains("https://") || lower.contains("www.")
  }

  private func normalizedUpper(_ value: Any?) -> String? {
    normalizedString(value)?.uppercased()
  }

  private func makeJSONSafeMap(_ payload: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, value) in payload {
      if JSONSerialization.isValidJSONObject(["v": value]) {
        out[key] = value
      } else {
        out[key] = String(describing: value)
      }
    }
    return out
  }

  private var requestContext: (URL, String)? {
    syncOnQueue {
      guard let apiBase = apiBaseURLLocked() else { return nil }
      let token = authHeaderTokenLocked() ?? ""
      return (apiBase, token)
    }
  }

  private func parseSavedMessagesServerItems(_ data: Data) -> [[String: Any]] {
    let json = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? []
    if let items = json as? [[String: Any]] {
      return items
    }
    if let dict = json as? [String: Any], let items = dict["data"] as? [[String: Any]] {
      return items
    }
    if let dict = json as? [String: Any], let items = dict["messages"] as? [[String: Any]] {
      return items
    }
    return []
  }

  private func parseJSONObjectString(_ raw: Any?) -> [String: Any] {
    guard let text = normalizedString(raw), let data = text.data(using: .utf8) else { return [:] }
    guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else {
      return [:]
    }
    return json as? [String: Any] ?? [:]
  }

  private func normalizeSavedMessagesLocked(_ rawItems: [[String: Any]]) -> [[String: Any]] {
    let privateKey = decryptPrivateKeyLocked()
    let currentUserId = currentUserIdLocked()

    return rawItems.compactMap { raw in
      guard
        let messageId = normalizedString(
          raw["original_message_id"] ?? raw["messageId"] ?? raw["message_id"] ?? raw["id"])
      else { return nil }

      let fromId =
        normalizedString(raw["from_id"] ?? raw["fromId"])
        ?? normalizedString(getConfigValueLocked("userId"))
      let type = normalizedString(raw["type"])?.lowercased() ?? "text"
      let parsedTimestampMs = transcriptTimestampMs(raw)
      if parsedTimestampMs == nil {
        noteSynthesizedTimestamp(chatId: "saved_messages", messageId: messageId, raw: raw)
      }
      let timestampMs = parsedTimestampMs ?? Int64(nowMs())
      let encryptedContent =
        normalizedString(raw["encrypted_content"] ?? raw["encryptedContent"])
      let parsedExtra = parseJSONObjectString(raw["extra"])
      var decryptedFields = parsedExtra

      let plaintextFallback =
        normalizedString(raw["content"] ?? raw["plaintext"] ?? raw["text"]) ?? ""
      if !plaintextFallback.isEmpty {
        decryptedFields["text"] = plaintextFallback
      }

      if let encryptedContent, !encryptedContent.isEmpty {
        let isMe = normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserId
        let parsedEncryptedFields: [String: Any]
        if !isLikelyHybridCiphertext(encryptedContent) {
          parsedEncryptedFields = parseDecryptedMessagePayload(encryptedContent)
        } else if let privateKey {
          let decrypted = chatEngineDecryptHybridMessage(
            privateKey: privateKey,
            ciphertext: encryptedContent,
            isMyMessage: isMe
          )
          parsedEncryptedFields = parseDecryptedMessagePayload(decrypted)
        } else {
          parsedEncryptedFields = [:]
        }
        for (key, value) in parsedEncryptedFields where decryptedFields[key] == nil {
          decryptedFields[key] = value
        }
      }

      let resolvedText = normalizedString(decryptedFields["text"]) ?? plaintextFallback
      let resolvedMediaUrl =
        normalizedString(
          decryptedFields["mediaUrl"] ?? raw["media_url"] ?? raw["mediaUrl"])
      let resolvedFileName =
        normalizedString(
          decryptedFields["fileName"] ?? raw["file_name"] ?? raw["fileName"])
      let resolvedMediaKey = normalizedString(
        decryptedFields["mediaKey"] ?? raw["media_key"] ?? raw["mediaKey"])
      let resolvedLatitude = parseDoubleValue(decryptedFields["latitude"])
      let resolvedLongitude = parseDoubleValue(decryptedFields["longitude"])
      let resolvedDuration = parseDoubleValue(decryptedFields["duration"])
      let resolvedEditedAt = parseLongValue(
        decryptedFields["editedAt"] ?? raw["edited_at"] ?? raw["editedAt"])

      var normalized: [String: Any] = [
        "id": messageId,
        "chatId": "saved_messages",
        "timestamp": timestampMs,
        "timestampMs": timestampMs,
        "type": type,
        "extra": parsedExtra,
      ]
      if let fromId { normalized["fromId"] = fromId }
      if let encryptedContent { normalized["encryptedContent"] = encryptedContent }
      if !resolvedText.isEmpty {
        normalized["plaintext"] = resolvedText
        normalized["text"] = resolvedText
      }
      if let resolvedMediaUrl { normalized["mediaUrl"] = resolvedMediaUrl }
      if let resolvedFileName { normalized["fileName"] = resolvedFileName }
      if let resolvedMediaKey { normalized["mediaKey"] = resolvedMediaKey }
      if let resolvedLatitude { normalized["latitude"] = resolvedLatitude }
      if let resolvedLongitude { normalized["longitude"] = resolvedLongitude }
      if let resolvedDuration { normalized["duration"] = resolvedDuration }
      if let resolvedEditedAt { normalized["editedAt"] = resolvedEditedAt }
      if let status = normalizedString(raw["status"])?.lowercased() {
        normalized["status"] = status
      } else if normalizedUpper(fromId) == currentUserId {
        normalized["status"] = "sent"
      }
      if let isEdited = raw["isEdited"] as? Bool {
        normalized["isEdited"] = isEdited
      }
      if let replyToId = normalizedString(decryptedFields["replyToId"]) {
        normalized["replyToId"] = replyToId
      }
      if let replyPreview = decryptedFields["replyPreview"] ?? decryptedFields["reply_preview"] {
        normalized["replyPreview"] = replyPreview
      }
      if let replyPreviewTitle = normalizedString(
        decryptedFields["replyPreviewTitle"] ?? decryptedFields["reply_preview_title"]
          ?? decryptedFields["replyAuthorName"] ?? decryptedFields["reply_author_name"])
      {
        normalized["replyPreviewTitle"] = replyPreviewTitle
      }
      if let replyPreviewText = normalizedString(
        decryptedFields["replyPreviewText"] ?? decryptedFields["reply_preview_text"]
          ?? decryptedFields["replyText"] ?? decryptedFields["reply_text"])
      {
        normalized["replyPreviewText"] = replyPreviewText
      }
      if let width = decryptedFields["width"] { normalized["width"] = width }
      if let height = decryptedFields["height"] { normalized["height"] = height }
      if let waveform = decryptedFields["waveform"] { normalized["waveform"] = waveform }
      if let isVideoNote = decryptedFields["isVideoNote"] {
        normalized["isVideoNote"] = isVideoNote
      }
      if let contact = decryptedFields["contact"] {
        normalized["contact"] = contact
      }
      if let stickerId = normalizedString(decryptedFields["stickerId"]) {
        normalized["stickerId"] = stickerId
      }
      if let stickerPackId = normalizedString(
        decryptedFields["stickerPackId"] ?? decryptedFields["packId"])
      {
        normalized["stickerPackId"] = stickerPackId
        normalized["packId"] = stickerPackId
      }
      if let stickerBundleFileName = normalizedString(
        decryptedFields["stickerBundleFileName"] ?? decryptedFields["bundleFileName"])
      {
        normalized["stickerBundleFileName"] = stickerBundleFileName
        normalized["bundleFileName"] = stickerBundleFileName
      }
      if let emoji = normalizedString(decryptedFields["emoji"]) {
        normalized["emoji"] = emoji
      }
      // Metadata is where the forward chrome (`forwardedFrom*`, `isForwarded`) and a music
      // card's cover/artist/title live. This normalizer rebuilds the row from an allow-list of
      // top-level fields, and `metadata` was never on the list — so a forwarded or music
      // message painted correctly when it arrived (the live socket path DOES merge it) and then
      // came back bare on the next launch, because the row written to disk had no metadata to
      // read. The regular-chat history path already does exactly this merge.
      var mergedMetadata = (decryptedFields["metadata"] as? [String: Any]) ?? [:]
      if let serverMetadata = raw["metadata"] as? [String: Any] {
        for (key, value) in serverMetadata where mergedMetadata[key] == nil {
          mergedMetadata[key] = value
        }
      }
      // The send path seals these at the TOP level of the encrypted payload, not under
      // `metadata` — fold them in here so the row builder (which reads them back out of
      // metadata) still finds them even when its own decrypt pass is skipped or fails.
      // Missing `cover`/`artist`/`source` was the music card losing its artwork on every
      // saved-messages reload; `thumbnailBase64`/`caption` are the same class for images.
      for key in ["cover", "artist", "source", "thumbnailBase64", "caption"] {
        if mergedMetadata[key] == nil, let value = decryptedFields[key] {
          mergedMetadata[key] = value
        }
      }
      if !mergedMetadata.isEmpty {
        normalized["metadata"] = mergedMetadata
      }
      return normalized
    }
  }

  func sendSavedMessage(_ payload: [String: Any], completion: @escaping ([String: Any]) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(["success": false, "reason": "missing_config"]) }
        return
      }
      guard let userId = syncOnQueue({ self.normalizedString(self.getConfigValueLocked("userId")) }) else {
        DispatchQueue.main.async { completion(["success": false, "reason": "missing_user_id"]) }
        return
      }

      let type = self.normalizedString(payload["type"])?.lowercased() ?? "text"
      let text = self.normalizedString(payload["text"]) ?? ""
      let transportMode = syncOnQueue { self.transportModeLocked() }
      let messageId =
        self.normalizedString(payload["messageId"] ?? payload["message_id"] ?? payload["id"])
        ?? UUID().uuidString.lowercased()
      NSLog(
        "[ChatEngine] sendSavedMessage START messageId=%@ type=%@ hasText=%@",
        messageId,
        type,
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true")
      let metadata = (payload["metadata"] as? [String: Any]) ?? [:]
      var mediaUrl =
        self.normalizedString(
          metadata["mediaUrl"] ?? metadata["media_url"] ?? payload["mediaUrl"]
            ?? payload["media_url"])
      var fileName =
        self.normalizedString(metadata["fileName"] ?? metadata["file_name"] ?? payload["fileName"])
      var fileSize = self.parseLongValue(
        metadata["fileSize"] ?? metadata["file_size"] ?? payload["fileSize"])
      let latitude = self.parseDoubleValue(metadata["latitude"] ?? payload["latitude"])
      let longitude = self.parseDoubleValue(metadata["longitude"] ?? payload["longitude"])
      let duration = self.parseDoubleValue(metadata["duration"] ?? payload["duration"])
      // Saved Messages used to seal a SHORTER payload than a DM: no cover art, no caption,
      // no waveform, no music identity. The optimistic row carried them, so a just-sent track
      // looked right and lost its artwork the moment the row was rebuilt from the server —
      // i.e. on the next open. What is not in this envelope does not exist anywhere else.
      let thumbnailBase64 = self.normalizedString(
        metadata["thumbnailBase64"] ?? metadata["thumbnail_base64"] ?? payload["thumbnailBase64"])
      let caption = self.normalizedString(metadata["caption"] ?? payload["caption"])
      let waveform = metadata["waveform"] ?? payload["waveform"]
      let musicCover = self.normalizedString(
        metadata["cover"] ?? metadata["coverUrl"] ?? metadata["cover_url"] ?? payload["cover"])
      let musicArtist = self.normalizedString(metadata["artist"] ?? payload["artist"])
      let musicSource = self.normalizedString(
        metadata["source"] ?? metadata["platform"] ?? payload["source"])
      // `var`: if the caller could not read the picked file it passes neither, and the
      // upload block below fills them from the bytes it just uploaded. See there.
      var width = self.parseLongValue(metadata["width"] ?? payload["width"])
      var height = self.parseLongValue(metadata["height"] ?? payload["height"])
      var mediaKey = self.normalizedString(metadata["mediaKey"] ?? metadata["media_key"] ?? payload["mediaKey"])
      let replyToId =
        self.normalizedString(metadata["replyToId"] ?? metadata["reply_to_id"] ?? payload["replyToId"])
      let contact = metadata["contact"] ?? payload["contact"]
      let isVideoNote = metadata["isVideoNote"] ?? payload["isVideoNote"]
      let stickerId = self.normalizedString(metadata["stickerId"] ?? payload["stickerId"])
      let stickerPackId = self.normalizedString(
        metadata["stickerPackId"] ?? metadata["packId"] ?? payload["stickerPackId"]
          ?? payload["packId"])
      let stickerBundleFileName = self.normalizedString(
        metadata["stickerBundleFileName"] ?? metadata["bundleFileName"]
          ?? payload["stickerBundleFileName"] ?? payload["bundleFileName"])
      let stickerEmoji = self.normalizedString(metadata["emoji"] ?? payload["emoji"])
      let myPublicKeyPem = syncOnQueue { self.normalizedString(
        self.getConfigValueLocked("publicKeyPem") ?? self.getConfigValueLocked("publicKey")) }

      if type == "text" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        DispatchQueue.main.async { completion(["success": false, "reason": "empty_text"]) }
        return
      }
      if transportMode == "bridge_text" && type != "text" {
        DispatchQueue.main.async {
          completion(["success": false, "reason": "media_disabled_in_blackout", "type": type])
        }
        return
      }
      if transportMode == "packet_mesh" && !["text", "voice", "image"].contains(type) {
        DispatchQueue.main.async {
          completion(["success": false, "reason": "type_disabled_in_packet_mesh", "type": type])
        }
        return
      }

      let uploadableTypes: Set<String> = ["image", "voice", "video", "file", "sticker", "music"]
      if let currentMediaUrl = mediaUrl, uploadableTypes.contains(type),
        self.isLocalMediaURI(currentMediaUrl)
      {
        let uploadOutcome = self.uploadLocalMediaLocked(
          localUri: currentMediaUrl,
          messageType: type,
          fileNameHint: fileName,
          userId: userId,
          token: token,
          apiBase: apiBase
        )
        guard let uploadResult = uploadOutcome.result else {
          DispatchQueue.main.async {
            completion([
              "success": false,
              "reason": uploadOutcome.reason ?? "upload_failed",
              "messageId": messageId,
            ])
          }
          return
        }
        if ["image", "gif", "video"].contains(type) {
          chatMediaSeedRemoteCacheFromLocalFile(
            localURI: currentMediaUrl,
            remoteURL: uploadResult.remoteUrl,
            mediaKey: mediaKey ?? uploadResult.mediaKey
          )
        }
        // Dimensions are the receiver's ONLY way to shape the bubble before the bytes
        // arrive. Without them the cell falls back to a square (see the square fallback in
        // ChatListViewCells) and then resizes when the real image decodes — a photo-sized
        // shift, on the recipient, on every media message.
        //
        // The caller derives them from the picked file, so when that read fails they are
        // simply absent and every `if let width` downstream silently omits them. Nothing
        // errors; the recipient just gets a black square. The bytes are right here — they
        // were just uploaded — so read the header (no decode) and fill the gap. Covers
        // every send path at once, including the ones that never passed dimensions.
        if width == nil || height == nil, ["image", "gif"].contains(type) {
          let localPath: String? = {
            if let url = URL(string: currentMediaUrl), url.isFileURL { return url.path }
            return currentMediaUrl.hasPrefix("/") ? currentMediaUrl : nil
          }()
          if let localPath, let headerSize = chatMediaImageHeaderSize(atPath: localPath),
            headerSize.width > 1.0, headerSize.height > 1.0
          {
            width = Int64(headerSize.width)
            height = Int64(headerSize.height)
            NSLog(
              "[MediaDims] recovered from upload source type=%@ %.0fx%.0f",
              type, headerSize.width, headerSize.height)
          } else {
            NSLog(
              "[MediaDims] MISSING type=%@ local=%@ — recipient will size this as a square",
              type, localPath ?? "<not-a-file>")
          }
        }
        mediaUrl = uploadResult.remoteUrl
        if fileName == nil { fileName = uploadResult.fileName }
        if fileSize == nil { fileSize = uploadResult.fileSize }
        if mediaKey == nil { mediaKey = uploadResult.mediaKey }
      }

      var encryptedContent = ""
      if let myPublicKeyPem, !myPublicKeyPem.isEmpty {
        var encryptedPayload: [String: Any] = ["text": text]
        if let mediaUrl { encryptedPayload["mediaUrl"] = mediaUrl }
        if let mediaKey { encryptedPayload["mediaKey"] = mediaKey }
        if let fileName { encryptedPayload["fileName"] = fileName }
        if let fileSize { encryptedPayload["fileSize"] = fileSize }
        if let latitude { encryptedPayload["latitude"] = latitude }
        if let longitude { encryptedPayload["longitude"] = longitude }
        if let width { encryptedPayload["width"] = width }
        if let height { encryptedPayload["height"] = height }
        if let duration { encryptedPayload["duration"] = duration }
        if let replyToId { encryptedPayload["replyToId"] = replyToId }
        if let contact { encryptedPayload["contact"] = contact }
        if let isVideoNote { encryptedPayload["isVideoNote"] = isVideoNote }
        if let stickerId { encryptedPayload["stickerId"] = stickerId }
        if let stickerPackId { encryptedPayload["stickerPackId"] = stickerPackId }
        if let stickerBundleFileName {
          encryptedPayload["stickerBundleFileName"] = stickerBundleFileName
        }
        if let stickerEmoji { encryptedPayload["emoji"] = stickerEmoji }
        if let thumbnailBase64 { encryptedPayload["thumbnailBase64"] = thumbnailBase64 }
        if let caption { encryptedPayload["caption"] = caption }
        if let waveform { encryptedPayload["waveform"] = waveform }
        if let musicCover { encryptedPayload["cover"] = musicCover }
        if let musicArtist { encryptedPayload["artist"] = musicArtist }
        if let musicSource { encryptedPayload["source"] = musicSource }
        if let payloadString = try? JSONSerialization.data(
          withJSONObject: self.makeJSONSafeMap(encryptedPayload), options: []),
          let messageString = String(data: payloadString, encoding: .utf8),
          let sealed = try? chatEngineEncryptHybridMessage(
            recipientPublicKeyPem: myPublicKeyPem,
            message: messageString,
            myPublicKeyPem: myPublicKeyPem
          )
        {
          encryptedContent = sealed
        }
      }

      var extraPayload: [String: Any] = [:]
      if let fileName { extraPayload["fileName"] = fileName }
      if let fileSize { extraPayload["fileSize"] = fileSize }
      if let latitude { extraPayload["latitude"] = latitude }
      if let longitude { extraPayload["longitude"] = longitude }
      if let width { extraPayload["width"] = width }
      if let height { extraPayload["height"] = height }
      if let duration { extraPayload["duration"] = duration }
      if let replyToId { extraPayload["replyToId"] = replyToId }
      if let isVideoNote { extraPayload["isVideoNote"] = isVideoNote }
      if let stickerId { extraPayload["stickerId"] = stickerId }
      if let stickerPackId {
        extraPayload["stickerPackId"] = stickerPackId
        extraPayload["packId"] = stickerPackId
      }
      if let stickerBundleFileName {
        extraPayload["stickerBundleFileName"] = stickerBundleFileName
        extraPayload["bundleFileName"] = stickerBundleFileName
      }
      if let stickerEmoji { extraPayload["emoji"] = stickerEmoji }

      let requestBody = self.makeJSONSafeMap([
        "user_id": userId,
        "original_message_id": messageId,
        "chat_id": "saved_messages",
        "from_id": userId,
        "encrypted_content": encryptedContent,
        "content": "",
        "type": type,
        "media_url": NSNull(),
        "timestamp": Int64(self.nowMs()),
        "extra": String(
          data: (try? JSONSerialization.data(withJSONObject: extraPayload, options: []))
            ?? Data("{}".utf8),
          encoding: .utf8
        ) ?? "{}",
      ])

      var request = URLRequest(
        url: apiBase.appendingPathComponent("api").appendingPathComponent("saved_messages"))
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
      request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody, options: [])

      let session = ChatPhoenixClient.makePinnedURLSession()
      session.dataTask(with: request) { data, response, error in
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let success = error == nil && (200...299).contains(statusCode)
        let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let errorText = error?.localizedDescription ?? ""
        NSLog(
          "[ChatEngine] sendSavedMessage %@ messageId=%@ status=%d error=%@ body=%@",
          success ? "OK" : "FAIL",
          messageId,
          statusCode,
          errorText.isEmpty ? "-" : errorText,
          responseBody.isEmpty ? "-" : responseBody
        )
        DispatchQueue.main.async {
          completion([
            "success": success,
            "status": statusCode,
            "messageId": messageId,
            "reason": success ? "ok" : "request_failed",
            "error": errorText,
            "body": responseBody,
          ])
        }
      }.resume()
    }
  }

  // MARK: - Agent Config (Native HTTP)

  func fetchAgentConfig(chatId: String, completion: @escaping ([String: Any]?) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      guard chatId != "saved_messages" else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      var request = URLRequest(
        url: apiBase.appendingPathComponent("api").appendingPathComponent("group")
          .appendingPathComponent(chatId).appendingPathComponent("agent"))
      request.httpMethod = "GET"
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

      let session = ChatPhoenixClient.makePinnedURLSession()
      session.dataTask(with: request) { data, response, error in
        guard let data = data, (response as? HTTPURLResponse)?.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          DispatchQueue.main.async { completion(nil) }
          return
        }
        DispatchQueue.main.async { completion(json) }
      }.resume()
    }
  }

  func saveAgentConfig(chatId: String, config: [String: Any], completion: @escaping (Bool) -> Void)
  {
    queue.async { [weak self] in
      guard let self else { return }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      let endpoint = apiBase.appendingPathComponent("api").appendingPathComponent("group")
        .appendingPathComponent(chatId).appendingPathComponent("agent")
      let safeConfig = self.makeJSONSafeMap(config)
      let payload = (try? JSONSerialization.data(withJSONObject: safeConfig)) ?? Data()

      let hasPersistedId: Bool = {
        if let id = config["id"] as? String {
          return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return config["id"] != nil
      }()
      let initialMethod = hasPersistedId ? "PUT" : "POST"

      func makeRequest(method: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        if !token.isEmpty {
          request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = payload
        return request
      }

      func send(method: String, completion: @escaping (Int) -> Void) {
        let request = makeRequest(method: method)
        let session = ChatPhoenixClient.makePinnedURLSession()
        session.dataTask(with: request) { _, response, _ in
          completion((response as? HTTPURLResponse)?.statusCode ?? -1)
        }.resume()
      }

      send(method: initialMethod) { statusCode in
        if initialMethod == "POST" && statusCode == 409 {
          send(method: "PUT") { retryStatus in
            let success = (200...299).contains(retryStatus)
            DispatchQueue.main.async { completion(success) }
          }
          return
        }
        let success = (200...299).contains(statusCode)
        DispatchQueue.main.async { completion(success) }
      }
    }
  }

  func generateAgentPrompt(
    chatId: String,
    input: String,
    enabledTools: [String],
    completion: @escaping ([String: Any]?) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(nil) }
        return
      }

      let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedInput.isEmpty else {
        DispatchQueue.main.async { completion(nil) }
        return
      }

      var request = URLRequest(
        url: apiBase.appendingPathComponent("api").appendingPathComponent("group")
          .appendingPathComponent(chatId).appendingPathComponent("agent")
          .appendingPathComponent("generate_prompt"))
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

      let safeTools =
        enabledTools
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      let body: [String: Any] = [
        "input": trimmedInput,
        "enabled_tools": safeTools,
      ]
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)

      let session = ChatPhoenixClient.makePinnedURLSession()
      session.dataTask(with: request) { data, response, _ in
        guard
          let data = data,
          (response as? HTTPURLResponse)?.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          DispatchQueue.main.async { completion(nil) }
          return
        }
        DispatchQueue.main.async { completion(json) }
      }.resume()
    }
  }

  func deleteAgentConfig(chatId: String, completion: @escaping (Bool) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      var request = URLRequest(
        url: apiBase.appendingPathComponent("api").appendingPathComponent("group")
          .appendingPathComponent(chatId).appendingPathComponent("agent"))
      request.httpMethod = "DELETE"
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

      let session = ChatPhoenixClient.makePinnedURLSession()
      session.dataTask(with: request) { data, response, error in
        let success = (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        DispatchQueue.main.async { completion(success) }
      }.resume()
    }
  }
}
