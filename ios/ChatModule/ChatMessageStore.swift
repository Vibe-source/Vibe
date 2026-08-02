import Foundation
import SQLite3

/// Durable per-user message store backing ChatEngine's chat history.
///
/// Replaces the old UserDefaults JSON blob (120-row cap, full rewrite on every
/// store). Rows are upserted individually keyed by (user, chat, message id) so
/// the store can retain history far beyond the newest fetch window — the raw
/// material for real scroll-back pagination — while restores stay bounded.
///
/// Threading: every call MUST come from ChatEngine's serial queue. The store
/// owns a single connection and does no locking of its own.
final class ChatMessageStore {

  private var db: OpaquePointer?

  /// Retained per chat after pruning; restores read far fewer (the engine's
  /// UI window). The surplus is deliberate headroom for future pagination.
  static let prunedChatRowLimit = 1000

  init() {
    guard
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { return }
    let dir = base.appendingPathComponent("VibeChatStore", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("messages.db")
    var handle: OpaquePointer?
    guard sqlite3_open_v2(
      url.path, &handle,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
      let handle = handle
    else {
      NSLog("[ChatStore] open FAILED path=%@", url.path)
      if let orphan = handle { sqlite3_close_v2(orphan) }
      return
    }
    db = handle
    exec("PRAGMA journal_mode=WAL")
    exec("PRAGMA synchronous=NORMAL")
    exec("PRAGMA busy_timeout=2000")
    exec(
      """
      CREATE TABLE IF NOT EXISTS messages(
        user_id TEXT NOT NULL,
        chat_id TEXT NOT NULL,
        message_id TEXT NOT NULL,
        ts INTEGER NOT NULL,
        payload BLOB NOT NULL,
        PRIMARY KEY(user_id, chat_id, message_id)
      )
      """)
    exec(
      "CREATE INDEX IF NOT EXISTS idx_messages_chat_ts ON messages(user_id, chat_id, ts)")
  }

  deinit {
    if let db = db { sqlite3_close_v2(db) }
  }

  var isAvailable: Bool { db != nil }

  @discardableResult
  private func exec(_ sql: String) -> Bool {
    guard let db = db else { return false }
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
    if result != SQLITE_OK {
      NSLog(
        "[ChatStore] exec FAILED rc=%d error=%@ sql=%@",
        result, errorMessage.map { String(cString: $0) } ?? "?", String(sql.prefix(80)))
      sqlite3_free(errorMessage)
      return false
    }
    return true
  }

  private func prepare(_ sql: String) -> OpaquePointer? {
    guard let db = db else { return nil }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      NSLog("[ChatStore] prepare FAILED sql=%@", String(sql.prefix(80)))
      return nil
    }
    return statement
  }

  private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
    // SQLITE_TRANSIENT — sqlite copies the buffer before the Swift string is released.
    sqlite3_bind_text(
      statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
  }

  func upsertMessages(
    userId: String,
    chatId: String,
    entries: [(messageId: String, ts: Int64, payload: Data)]
  ) {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty, !entries.isEmpty else { return }
    guard
      let statement = prepare(
        """
        INSERT INTO messages(user_id, chat_id, message_id, ts, payload)
        VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(user_id, chat_id, message_id)
        DO UPDATE SET ts=excluded.ts, payload=excluded.payload
        """)
    else { return }
    defer { sqlite3_finalize(statement) }
    exec("BEGIN IMMEDIATE")
    for entry in entries {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      bindText(statement, 1, userId)
      bindText(statement, 2, chatId)
      bindText(statement, 3, entry.messageId)
      sqlite3_bind_int64(statement, 4, entry.ts)
      _ = entry.payload.withUnsafeBytes { buffer in
        sqlite3_bind_blob(
          statement, 5, buffer.baseAddress, Int32(buffer.count),
          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      }
      if sqlite3_step(statement) != SQLITE_DONE {
        NSLog("[ChatStore] upsert step FAILED chat=%@", String(chatId.prefix(12)))
      }
    }
    exec("COMMIT")
  }

  func deleteMessages(userId: String, chatId: String, messageIds: [String]) {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty, !messageIds.isEmpty else { return }
    guard
      let statement = prepare(
        "DELETE FROM messages WHERE user_id=? AND chat_id=? AND message_id=?")
    else { return }
    defer { sqlite3_finalize(statement) }
    exec("BEGIN IMMEDIATE")
    for messageId in messageIds {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      bindText(statement, 1, userId)
      bindText(statement, 2, chatId)
      bindText(statement, 3, messageId)
      _ = sqlite3_step(statement)
    }
    exec("COMMIT")
  }

  /// Newest `limit` payloads in ascending timestamp order (transcript order).
  func recentMessagePayloads(userId: String, chatId: String, limit: Int) -> [Data] {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty, limit > 0 else { return [] }
    guard
      let statement = prepare(
        """
        SELECT payload FROM (
          SELECT payload, ts, message_id FROM messages
          WHERE user_id=? AND chat_id=?
          ORDER BY ts DESC, message_id DESC LIMIT ?
        ) ORDER BY ts ASC, message_id ASC
        """)
    else { return [] }
    defer { sqlite3_finalize(statement) }
    bindText(statement, 1, userId)
    bindText(statement, 2, chatId)
    sqlite3_bind_int(statement, 3, Int32(limit))
    var payloads: [Data] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let bytes = sqlite3_column_blob(statement, 0) {
        let count = Int(sqlite3_column_bytes(statement, 0))
        payloads.append(Data(bytes: bytes, count: count))
      }
    }
    return payloads
  }

  /// Up to `limit` payloads below a transcript row, returned in ascending order.
  func olderMessagePayloads(
    userId: String,
    chatId: String,
    beforeTs: Int64,
    beforeMessageId: String,
    limit: Int
  ) -> [Data] {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty, !beforeMessageId.isEmpty, limit > 0
    else { return [] }
    guard
      let statement = prepare(
        """
        SELECT payload FROM (
          SELECT payload, ts, message_id FROM messages
          WHERE user_id=? AND chat_id=?
            AND (ts < ? OR (ts = ? AND message_id < ?))
          ORDER BY ts DESC, message_id DESC LIMIT ?
        ) ORDER BY ts ASC, message_id ASC
        """)
    else { return [] }
    defer { sqlite3_finalize(statement) }
    bindText(statement, 1, userId)
    bindText(statement, 2, chatId)
    sqlite3_bind_int64(statement, 3, beforeTs)
    sqlite3_bind_int64(statement, 4, beforeTs)
    bindText(statement, 5, beforeMessageId)
    sqlite3_bind_int(statement, 6, Int32(limit))
    var payloads: [Data] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let bytes = sqlite3_column_blob(statement, 0) {
        let count = Int(sqlite3_column_bytes(statement, 0))
        payloads.append(Data(bytes: bytes, count: count))
      }
    }
    return payloads
  }

  func hasOlderMessages(
    userId: String,
    chatId: String,
    beforeTs: Int64,
    beforeMessageId: String
  ) -> Bool {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty, !beforeMessageId.isEmpty else {
      return false
    }
    guard
      let statement = prepare(
        """
        SELECT 1 FROM messages
        WHERE user_id=? AND chat_id=?
          AND (ts < ? OR (ts = ? AND message_id < ?))
        LIMIT 1
        """)
    else { return false }
    defer { sqlite3_finalize(statement) }
    bindText(statement, 1, userId)
    bindText(statement, 2, chatId)
    sqlite3_bind_int64(statement, 3, beforeTs)
    sqlite3_bind_int64(statement, 4, beforeTs)
    bindText(statement, 5, beforeMessageId)
    return sqlite3_step(statement) == SQLITE_ROW
  }

  /// Every stored (message_id, ts) pair for one chat — the raw material for reconciling
  /// the store against a server-canonical transcript (ghost rows under retired ids are
  /// invisible to upserts and can only be found by enumerating what disk actually holds).
  func messageIdsWithTimestamps(userId: String, chatId: String) -> [(messageId: String, ts: Int64)] {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty else { return [] }
    guard
      let statement = prepare(
        "SELECT message_id, ts FROM messages WHERE user_id=? AND chat_id=?")
    else { return [] }
    defer { sqlite3_finalize(statement) }
    bindText(statement, 1, userId)
    bindText(statement, 2, chatId)
    var results: [(messageId: String, ts: Int64)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idBytes = sqlite3_column_text(statement, 0) else { continue }
      results.append((String(cString: idBytes), sqlite3_column_int64(statement, 1)))
    }
    return results
  }

  func deleteChat(userId: String, chatId: String) {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty else { return }
    guard let statement = prepare("DELETE FROM messages WHERE user_id=? AND chat_id=?") else {
      return
    }
    defer { sqlite3_finalize(statement) }
    bindText(statement, 1, userId)
    bindText(statement, 2, chatId)
    _ = sqlite3_step(statement)
  }

  /// Drop everything older than the newest `keepNewest` rows for one chat.
  func pruneChat(userId: String, chatId: String, keepNewest: Int = ChatMessageStore.prunedChatRowLimit) {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty, keepNewest > 0 else { return }
    guard
      let statement = prepare(
        """
        DELETE FROM messages WHERE user_id=? AND chat_id=? AND message_id NOT IN (
          SELECT message_id FROM messages WHERE user_id=? AND chat_id=?
          ORDER BY ts DESC, message_id DESC LIMIT ?
        )
        """)
    else { return }
    defer { sqlite3_finalize(statement) }
    bindText(statement, 1, userId)
    bindText(statement, 2, chatId)
    bindText(statement, 3, userId)
    bindText(statement, 4, chatId)
    sqlite3_bind_int(statement, 5, Int32(keepNewest))
    _ = sqlite3_step(statement)
  }

  func messageCount(userId: String, chatId: String) -> Int {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty else { return 0 }
    guard
      let statement = prepare(
        "SELECT COUNT(*) FROM messages WHERE user_id=? AND chat_id=?")
    else { return 0 }
    defer { sqlite3_finalize(statement) }
    bindText(statement, 1, userId)
    bindText(statement, 2, chatId)
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int(statement, 0))
  }
}
