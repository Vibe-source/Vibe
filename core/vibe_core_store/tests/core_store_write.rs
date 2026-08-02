//! Write-side integration tests for `VibeCoreStore`.
//!
//! The legacy `messages` table is deliberately left alone: these tests never
//! create or touch it. Sealed body/nonce are opaque random-looking bytes.

use std::collections::HashSet;

use rusqlite::Connection;
use tempfile::NamedTempFile;
use vibe_core_store::{
    VibeChatLoadState, VibeCoreStore, VibeSealedRow, VibeStoreCursor, MAX_PAGE_LIMIT,
};

const USER: &str = "user-a";
const CHAT: &str = "chat-1";

fn open_fresh() -> (NamedTempFile, VibeCoreStore) {
    let tmp = NamedTempFile::new().expect("tempfile");
    let store = VibeCoreStore::open(tmp.path()).expect("open core store");
    (tmp, store)
}

fn sealed(id: &str, ts: i64, flags: i64, body: &[u8], nonce: &[u8]) -> VibeSealedRow {
    VibeSealedRow {
        message_id: id.to_string(),
        ts_ms: ts,
        flags,
        sealed_body: body.to_vec(),
        seal_nonce: nonce.to_vec(),
    }
}

fn ids(rows: &[VibeSealedRow]) -> Vec<&str> {
    rows.iter().map(|r| r.message_id.as_str()).collect()
}

fn assert_ascending(rows: &[VibeSealedRow]) {
    for w in rows.windows(2) {
        let a = &w[0];
        let b = &w[1];
        assert!(
            a.ts_ms < b.ts_ms || (a.ts_ms == b.ts_ms && a.message_id < b.message_id),
            "order broken: ({}, {}) then ({}, {})",
            a.ts_ms,
            a.message_id,
            b.ts_ms,
            b.message_id
        );
    }
}

// ---------------------------------------------------------------------------
// Open + pragmas + schema isolation
// ---------------------------------------------------------------------------

#[test]
fn open_creates_schema_and_never_touches_messages_table() {
    let (tmp, store) = open_fresh();
    store
        .upsert(USER, CHAT, &[sealed("m1", 1, 0, b"body", b"nonce")])
        .unwrap();
    assert_eq!(store.count(USER, CHAT).unwrap(), 1);
    drop(store);

    let conn = Connection::open(tmp.path()).unwrap();
    let tables: HashSet<String> = conn
        .prepare("SELECT name FROM sqlite_master WHERE type='table'")
        .unwrap()
        .query_map([], |r| r.get::<_, String>(0))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    assert!(tables.contains("core_messages_v1"));
    assert!(tables.contains("core_tombstones_v1"));
    assert!(tables.contains("core_meta_v1"));
    assert!(
        !tables.contains("messages"),
        "core store must not create legacy messages table"
    );

    let mode: String = conn
        .query_row("PRAGMA journal_mode", [], |r| r.get(0))
        .unwrap();
    assert_eq!(mode.to_lowercase(), "wal");
}

// ---------------------------------------------------------------------------
// Idempotent upsert + kill-9 re-run safety
// ---------------------------------------------------------------------------

#[test]
fn upsert_is_transactional_and_idempotent() {
    let (_tmp, store) = open_fresh();
    let batch = vec![
        sealed("a", 10, 0, b"ba", b"na"),
        sealed("b", 20, 1, b"bb", b"nb"),
        sealed("c", 30, 2, b"bc", b"nc"),
    ];

    store.upsert(USER, CHAT, &batch).unwrap();
    assert_eq!(store.count(USER, CHAT).unwrap(), 3);

    // Re-run identical batch — no duplicates, values unchanged.
    store.upsert(USER, CHAT, &batch).unwrap();
    assert_eq!(store.count(USER, CHAT).unwrap(), 3);

    let page = store.page_after(USER, CHAT, None, 100).unwrap();
    assert_eq!(ids(&page), ["a", "b", "c"]);
    assert_eq!(page[0].sealed_body, b"ba");
    assert_eq!(page[1].flags, 1);
    assert_eq!(page[2].seal_nonce, b"nc");
}

#[test]
fn upsert_replace_updates_existing_row_same_pk() {
    let (_tmp, store) = open_fresh();
    store
        .upsert(USER, CHAT, &[sealed("m1", 100, 0, b"old-body", b"old-n")])
        .unwrap();
    store
        .upsert(USER, CHAT, &[sealed("m1", 200, 7, b"new-body", b"new-n")])
        .unwrap();

    assert_eq!(store.count(USER, CHAT).unwrap(), 1);
    let page = store.page_after(USER, CHAT, None, 10).unwrap();
    assert_eq!(page.len(), 1);
    assert_eq!(page[0].ts_ms, 200);
    assert_eq!(page[0].flags, 7);
    assert_eq!(page[0].sealed_body, b"new-body");
    assert_eq!(page[0].seal_nonce, b"new-n");
}

#[test]
fn upsert_partial_batch_abort_leaves_table_consistent() {
    // Simulate kill-9 mid-batch by rolling back an explicit transaction that
    // mirrors the store's BEGIN IMMEDIATE path. Then re-run via the public API.
    let (tmp, store) = open_fresh();
    store
        .upsert(
            USER,
            CHAT,
            &[
                sealed("keep-1", 1, 0, b"k1", b"n1"),
                sealed("keep-2", 2, 0, b"k2", b"n2"),
            ],
        )
        .unwrap();
    assert_eq!(store.count(USER, CHAT).unwrap(), 2);
    drop(store);

    // Open a raw connection, start IMMEDIATE, write one row, ROLLBACK (crash).
    {
        let conn = Connection::open(tmp.path()).unwrap();
        conn.execute_batch("BEGIN IMMEDIATE").unwrap();
        conn.execute(
            r"
            INSERT INTO core_messages_v1(
              user_id, chat_id, message_id, ts, order_key,
              flags, sealed_body, seal_nonce
            ) VALUES (?1,?2,?3,?4,X'00',0,X'aa',X'bb')
            ",
            rusqlite::params![USER, CHAT, "ghost", 99i64],
        )
        .unwrap();
        // kill -9 equivalent: abandon without commit.
        conn.execute_batch("ROLLBACK").unwrap();
    }

    let store = VibeCoreStore::open(tmp.path()).unwrap();
    // Ghost never landed.
    assert_eq!(store.count(USER, CHAT).unwrap(), 2);
    let page = store.page_after(USER, CHAT, None, 100).unwrap();
    assert_eq!(ids(&page), ["keep-1", "keep-2"]);

    // Re-run the original batch (+ one new) is idempotent for keep-* and adds d.
    store
        .upsert(
            USER,
            CHAT,
            &[
                sealed("keep-1", 1, 0, b"k1", b"n1"),
                sealed("keep-2", 2, 0, b"k2", b"n2"),
                sealed("d", 3, 0, b"kd", b"nd"),
            ],
        )
        .unwrap();
    assert_eq!(store.count(USER, CHAT).unwrap(), 3);
    assert_eq!(
        ids(&store.page_after(USER, CHAT, None, 100).unwrap()),
        ["keep-1", "keep-2", "d"]
    );
}

// ---------------------------------------------------------------------------
// order_key byte order vs SQL order
// ---------------------------------------------------------------------------

#[test]
fn order_key_byte_order_matches_sql_order_including_negative_and_large_ts() {
    let (tmp, store) = open_fresh();
    let rows = [
        sealed("id-neg-a", i64::MIN, 0, b"x", b"n"),
        sealed("id-neg-b", -1, 0, b"x", b"n"),
        sealed("id-zero", 0, 0, b"x", b"n"),
        sealed("id-pos", 42, 0, b"x", b"n"),
        sealed("id-large", i64::MAX, 0, b"x", b"n"),
        sealed("id-same-b", 100, 0, b"x", b"n"),
        sealed("id-same-a", 100, 0, b"x", b"n"),
        sealed("id-huge", 9_000_000_000_000i64, 0, b"x", b"n"),
    ];
    store.upsert(USER, CHAT, &rows).unwrap();

    // SQL total order via the index columns.
    let sql_order: Vec<(i64, String)> = {
        let conn = Connection::open(tmp.path()).unwrap();
        let mut stmt = conn
            .prepare(
                r"
                SELECT ts, message_id FROM core_messages_v1
                WHERE user_id = ?1 AND chat_id = ?2
                ORDER BY ts ASC, message_id ASC
                ",
            )
            .unwrap();
        stmt.query_map(rusqlite::params![USER, CHAT], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
        })
        .unwrap()
        .map(|r| r.unwrap())
        .collect()
    };

    // order_key byte order from the stored column.
    let key_order: Vec<(i64, String)> = {
        let conn = Connection::open(tmp.path()).unwrap();
        let mut stmt = conn
            .prepare(
                r"
                SELECT ts, message_id FROM core_messages_v1
                WHERE user_id = ?1 AND chat_id = ?2
                ORDER BY order_key ASC
                ",
            )
            .unwrap();
        stmt.query_map(rusqlite::params![USER, CHAT], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
        })
        .unwrap()
        .map(|r| r.unwrap())
        .collect()
    };

    assert_eq!(
        sql_order, key_order,
        "order_key byte order must match (ts, message_id) SQL order"
    );

    // Public page API agrees.
    let page = store.page_after(USER, CHAT, None, 100).unwrap();
    let page_ids: Vec<&str> = ids(&page);
    let expected: Vec<&str> = sql_order.iter().map(|(_, id)| id.as_str()).collect();
    assert_eq!(page_ids, expected);
    assert_ascending(&page);
}

// ---------------------------------------------------------------------------
// Transient id rejection
// ---------------------------------------------------------------------------

#[test]
fn upsert_skips_transient_ids() {
    let (_tmp, store) = open_fresh();
    store
        .upsert(
            USER,
            CHAT,
            &[
                sealed("stream-1", 1, 0, b"s", b"n"),
                sealed("lan-xyz", 2, 0, b"l", b"n"),
                sealed("bridge-abc", 3, 0, b"b", b"n"),
                sealed("real-msg", 4, 0, b"r", b"n"),
                sealed("stream", 5, 0, b"ok", b"n"), // prefix only — allowed
            ],
        )
        .unwrap();

    assert_eq!(store.count(USER, CHAT).unwrap(), 2);
    let page = store.page_after(USER, CHAT, None, 100).unwrap();
    assert_eq!(ids(&page), ["real-msg", "stream"]);
}

// ---------------------------------------------------------------------------
// Tombstone
// ---------------------------------------------------------------------------

#[test]
fn tombstone_round_trip() {
    let (_tmp, store) = open_fresh();
    assert!(!store.is_tombstoned(USER, CHAT, "m1").unwrap());

    store
        .tombstone(USER, CHAT, &["m1", "m2"], 1_700_000_000_000, true)
        .unwrap();
    assert!(store.is_tombstoned(USER, CHAT, "m1").unwrap());
    assert!(store.is_tombstoned(USER, CHAT, "m2").unwrap());
    assert!(!store.is_tombstoned(USER, CHAT, "m3").unwrap());

    // Idempotent re-tombstone.
    store
        .tombstone(USER, CHAT, &["m1"], 1_700_000_000_001, false)
        .unwrap();
    assert!(store.is_tombstoned(USER, CHAT, "m1").unwrap());

    // Transient ids are not recorded.
    store
        .tombstone(USER, CHAT, &["stream-x", "lan-y"], 99, true)
        .unwrap();
    assert!(!store.is_tombstoned(USER, CHAT, "stream-x").unwrap());
    assert!(!store.is_tombstoned(USER, CHAT, "lan-y").unwrap());
}

// ---------------------------------------------------------------------------
// Three-state load state
// ---------------------------------------------------------------------------

#[test]
fn load_state_three_states_persist_distinctly() {
    let (_tmp, store) = open_fresh();

    // Default: not loaded — never confusable with known-empty.
    assert_eq!(
        store.load_state(USER, CHAT).unwrap(),
        VibeChatLoadState::NotLoaded
    );

    store
        .set_load_state(USER, CHAT, VibeChatLoadState::KnownEmpty)
        .unwrap();
    assert_eq!(
        store.load_state(USER, CHAT).unwrap(),
        VibeChatLoadState::KnownEmpty
    );
    // Known empty must not depend on row count.
    assert_eq!(store.count(USER, CHAT).unwrap(), 0);

    store
        .set_load_state(USER, CHAT, VibeChatLoadState::Loaded)
        .unwrap();
    assert_eq!(
        store.load_state(USER, CHAT).unwrap(),
        VibeChatLoadState::Loaded
    );

    // Still Loaded with zero rows — distinct from KnownEmpty.
    assert_eq!(store.count(USER, CHAT).unwrap(), 0);
    assert_eq!(
        store.load_state(USER, CHAT).unwrap(),
        VibeChatLoadState::Loaded
    );

    store
        .set_load_state(USER, CHAT, VibeChatLoadState::NotLoaded)
        .unwrap();
    assert_eq!(
        store.load_state(USER, CHAT).unwrap(),
        VibeChatLoadState::NotLoaded
    );

    // Per-chat isolation.
    store
        .set_load_state(USER, "other", VibeChatLoadState::KnownEmpty)
        .unwrap();
    assert_eq!(
        store.load_state(USER, CHAT).unwrap(),
        VibeChatLoadState::NotLoaded
    );
    assert_eq!(
        store.load_state(USER, "other").unwrap(),
        VibeChatLoadState::KnownEmpty
    );
}

// ---------------------------------------------------------------------------
// Prune keeps newest
// ---------------------------------------------------------------------------

#[test]
fn prune_keeps_newest_rows_not_oldest() {
    let (_tmp, store) = open_fresh();
    let batch: Vec<VibeSealedRow> = (0..10)
        .map(|i| sealed(&format!("m{i:02}"), i * 10, 0, b"x", b"n"))
        .collect();
    store.upsert(USER, CHAT, &batch).unwrap();
    assert_eq!(store.count(USER, CHAT).unwrap(), 10);

    store.prune(USER, CHAT, 3).unwrap();
    assert_eq!(store.count(USER, CHAT).unwrap(), 3);

    let page = store.page_after(USER, CHAT, None, 100).unwrap();
    // Newest three: m07 (70), m08 (80), m09 (90).
    assert_eq!(ids(&page), ["m07", "m08", "m09"]);
    assert_ascending(&page);

    // keep 0 → empty.
    store.prune(USER, CHAT, 0).unwrap();
    assert_eq!(store.count(USER, CHAT).unwrap(), 0);
}

#[test]
fn prune_same_ts_uses_message_id_tiebreak() {
    let (_tmp, store) = open_fresh();
    store
        .upsert(
            USER,
            CHAT,
            &[
                sealed("a", 100, 0, b"x", b"n"),
                sealed("b", 100, 0, b"x", b"n"),
                sealed("c", 100, 0, b"x", b"n"),
                sealed("d", 100, 0, b"x", b"n"),
            ],
        )
        .unwrap();
    store.prune(USER, CHAT, 2).unwrap();
    // Newest by (ts DESC, message_id DESC) → d, c.
    let page = store.page_after(USER, CHAT, None, 100).unwrap();
    assert_eq!(ids(&page), ["c", "d"]);
}

// ---------------------------------------------------------------------------
// Paging + limit clamp on core table
// ---------------------------------------------------------------------------

#[test]
fn core_page_before_after_and_limit_clamp() {
    let (_tmp, store) = open_fresh();
    let batch: Vec<VibeSealedRow> = (0..20)
        .map(|i| sealed(&format!("id-{i:02}"), i64::from(i), 0, b"p", b"n"))
        .collect();
    store.upsert(USER, CHAT, &batch).unwrap();

    let head = store.page_after(USER, CHAT, None, 5).unwrap();
    assert_eq!(ids(&head), ["id-00", "id-01", "id-02", "id-03", "id-04"]);

    let mid = store
        .page_after(
            USER,
            CHAT,
            Some(VibeStoreCursor {
                ts_ms: 4,
                message_id: "id-04".into(),
            }),
            3,
        )
        .unwrap();
    assert_eq!(ids(&mid), ["id-05", "id-06", "id-07"]);

    let tail = store.page_before(USER, CHAT, None, 3).unwrap();
    assert_eq!(ids(&tail), ["id-17", "id-18", "id-19"]);

    let older = store
        .page_before(
            USER,
            CHAT,
            Some(VibeStoreCursor {
                ts_ms: 17,
                message_id: "id-17".into(),
            }),
            2,
        )
        .unwrap();
    assert_eq!(ids(&older), ["id-15", "id-16"]);

    let over = store
        .page_after(USER, CHAT, None, MAX_PAGE_LIMIT + 100)
        .unwrap();
    assert_eq!(over.len(), 20);

    assert!(store.page_after(USER, CHAT, None, 0).unwrap().is_empty());
}

// ---------------------------------------------------------------------------
// Meta + sealed opacity / debug
// ---------------------------------------------------------------------------

#[test]
fn meta_get_set_round_trip() {
    let (_tmp, store) = open_fresh();
    assert_eq!(store.meta_get("cursor").unwrap(), None);
    store.meta_set("cursor", b"\x00\x01\xff").unwrap();
    assert_eq!(store.meta_get("cursor").unwrap().unwrap(), b"\x00\x01\xff");
    store.meta_set("cursor", b"next").unwrap();
    assert_eq!(store.meta_get("cursor").unwrap().unwrap(), b"next");
}

#[test]
fn sealed_row_debug_has_no_blob_bytes() {
    let row = sealed("m1", 1, 0, b"SECRET_BODY", b"SECRET_NONCE");
    let rendered = format!("{row:?}");
    assert!(!rendered.contains("SECRET_BODY"));
    assert!(!rendered.contains("SECRET_NONCE"));
    assert!(rendered.contains("sealed_body_len"));
    assert!(rendered.contains("seal_nonce_len"));
}

#[test]
fn store_debug_is_shape_only() {
    let (_tmp, store) = open_fresh();
    assert_eq!(format!("{store:?}"), "VibeCoreStore");
}

#[test]
fn sealed_bytes_round_trip_opaque() {
    let crazy: Vec<u8> = {
        let mut v = vec![0u8, 1, 0xFF, 0xFE, b'\0'];
        v.extend_from_slice(b"not-utf8:");
        v.extend_from_slice(&[0x80, 0xC0, 0xFF]);
        v
    };
    let nonce = vec![0xDE, 0xAD, 0x00, 0xBE, 0xEF];
    let (_tmp, store) = open_fresh();
    store
        .upsert(
            USER,
            CHAT,
            &[VibeSealedRow {
                message_id: "blob".into(),
                ts_ms: 9,
                flags: 0,
                sealed_body: crazy.clone(),
                seal_nonce: nonce.clone(),
            }],
        )
        .unwrap();
    let page = store.page_after(USER, CHAT, None, 1).unwrap();
    assert_eq!(page[0].sealed_body, crazy);
    assert_eq!(page[0].seal_nonce, nonce);
}
