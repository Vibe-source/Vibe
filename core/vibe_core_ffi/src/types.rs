//! FFI-shaped mirrors of the core's render-facing types.
//!
//! # Why mirrors instead of exporting the core types directly
//!
//! `vibe_core` has no FFI dependency and is not going to grow one. Deriving
//! UniFFI traits on its types would pull `uniffi` into a crate whose stated
//! property is "no FFI, no SQLite, no network", and would let the shape of the
//! Swift binding start dictating the shape of the reduction. The conversion cost
//! is one pass per *commit*, not per cell, so it does not matter.
//!
//! # These are deliberately a flattened subset
//!
//! The renderer needs what it draws: identity, order, author, kind, text,
//! flags, delivery. It does not need the core's internal nesting. Flattening
//! here keeps the generated Swift value types small and keeps the per-window
//! allocation count down — a 300-message window is already ~3,000 allocations
//! and must never run on the main thread.
//!
//! Anything not yet mirrored (media geometry, agent nodes, service nodes,
//! reply detail) is exposed as a boolean presence flag rather than silently
//! dropped, so a consumer can tell the difference between "absent" and "not
//! carried across this boundary yet". Fields are appended, never repurposed,
//! per the evolution rule in §4.3 of the refactor doc.

use vibe_core::types::{
    VibeDisplayStatus, VibeEventSource, VibeMessageKind, VibeMessageSnapshotV1,
    VibeTimelineDeltaBodyV1, VibeTimelineDeltaV1, VibeTimelineOpV1, VibeTimelineWindowV1,
    VibeWindowBounds,
};

/// Which ingest source a frame arrived on. Mirrors [`VibeEventSource`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum VibeFfiSource {
    HistoryPage,
    ChatTopic,
    UserTopic,
    Optimistic,
    StoreRestore,
    BridgeMirror,
    SavedMessages,
    Local,
}

impl From<VibeFfiSource> for VibeEventSource {
    fn from(value: VibeFfiSource) -> Self {
        match value {
            VibeFfiSource::HistoryPage => Self::HistoryPage,
            VibeFfiSource::ChatTopic => Self::ChatTopic,
            VibeFfiSource::UserTopic => Self::UserTopic,
            VibeFfiSource::Optimistic => Self::Optimistic,
            VibeFfiSource::StoreRestore => Self::StoreRestore,
            VibeFfiSource::BridgeMirror => Self::BridgeMirror,
            VibeFfiSource::SavedMessages => Self::SavedMessages,
            VibeFfiSource::Local => Self::Local,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum VibeFfiMessageKind {
    Text,
    Image,
    Video,
    Voice,
    Music,
    File,
    Sticker,
    Location,
    Contact,
    Service,
    AgentTurn,
}

impl From<VibeMessageKind> for VibeFfiMessageKind {
    fn from(value: VibeMessageKind) -> Self {
        match value {
            VibeMessageKind::Text => Self::Text,
            VibeMessageKind::Image => Self::Image,
            VibeMessageKind::Video => Self::Video,
            VibeMessageKind::Voice => Self::Voice,
            VibeMessageKind::Music => Self::Music,
            VibeMessageKind::File => Self::File,
            VibeMessageKind::Sticker => Self::Sticker,
            VibeMessageKind::Location => Self::Location,
            VibeMessageKind::Contact => Self::Contact,
            VibeMessageKind::Service => Self::Service,
            VibeMessageKind::AgentTurn => Self::AgentTurn,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum VibeFfiDisplayStatus {
    Pending,
    Sending,
    Failed,
    Sent,
    Delivered,
    Read,
}

impl From<VibeDisplayStatus> for VibeFfiDisplayStatus {
    fn from(value: VibeDisplayStatus) -> Self {
        match value {
            VibeDisplayStatus::Pending => Self::Pending,
            VibeDisplayStatus::Sending => Self::Sending,
            VibeDisplayStatus::Failed => Self::Failed,
            VibeDisplayStatus::Sent => Self::Sent,
            VibeDisplayStatus::Delivered => Self::Delivered,
            VibeDisplayStatus::Read => Self::Read,
        }
    }
}

/// One row, flattened for rendering.
///
/// `struct_excessive_bools` is allowed deliberately. The lint's advice — collapse
/// them into a bitflags type — is right for internal Rust and wrong here: these
/// become named `Bool` properties in generated Swift, where `message.hasReply`
/// reads at a glance and `mask & .hasReply != 0` does not. The core already keeps
/// its own flags packed (`flags: u32` above); duplicating that packing for
/// presence bits would trade Swift-side clarity for nothing.
#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct VibeFfiMessage {
    pub message_id: String,
    /// Retained after id healing so anchors survive an optimistic-send ack.
    pub client_message_id: Option<String>,
    pub ts_ms: i64,
    /// Dense index within the window this snapshot was built for. Derived —
    /// never use it as a sort key.
    pub order_seq: u64,
    pub author_user_id: String,
    pub author_is_me: bool,
    /// Set for agent/bridge turns (`claude`, `codex`, …).
    pub author_agent_provider: Option<String>,
    pub kind: VibeFfiMessageKind,
    pub text: String,
    pub caption: Option<String>,
    /// Raw [`vibe_core::types::VibeMessageFlags`] bits. Kept as a bitmask rather
    /// than expanded to a dozen booleans so adding a flag is an additive change
    /// on both sides of the boundary.
    pub flags: u32,
    pub display_status: VibeFfiDisplayStatus,
    /// `Some(0.0..=1.0)` while an upload is in flight.
    pub upload_fraction: Option<f32>,
    pub delivery_failed: bool,
    /// FNV-1a over the rendered fields. A renderer can skip a reconfigure when
    /// this is unchanged.
    pub content_hash: u64,
    // Presence flags for detail this boundary does not carry yet. Explicit, so
    // "not mirrored" is never mistaken for "absent".
    pub has_media: bool,
    pub has_reply: bool,
    pub has_agent: bool,
    pub has_service: bool,
    pub is_edited: bool,
}

impl From<&VibeMessageSnapshotV1> for VibeFfiMessage {
    fn from(m: &VibeMessageSnapshotV1) -> Self {
        Self {
            message_id: m.message_id.clone(),
            client_message_id: m.client_message_id.clone(),
            ts_ms: m.ts_ms,
            order_seq: m.order_seq,
            author_user_id: m.author.user_id.clone(),
            author_is_me: m.author.is_me,
            author_agent_provider: m.author.agent_provider.clone(),
            kind: m.kind.into(),
            text: m.body.text.clone(),
            caption: m.body.caption.clone(),
            flags: m.flags.raw(),
            display_status: m.delivery.display.into(),
            upload_fraction: m.delivery.upload,
            delivery_failed: m.delivery.failed,
            content_hash: m.content_hash,
            has_media: m.media.is_some(),
            has_reply: m.reply.is_some(),
            has_agent: m.agent.is_some(),
            has_service: m.service.is_some(),
            is_edited: m.edit.is_some(),
        }
    }
}

/// One ordered mutation.
///
/// `EvictHead`/`EvictTail` stay distinct from `Remove` across the boundary on
/// purpose: collapsing them is how a scroll-back trim gets a delete animation.
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum VibeFfiOp {
    Insert {
        index: u32,
        message: VibeFfiMessage,
    },
    Remove {
        index: u32,
        message_id: String,
    },
    RemapIdentity {
        index: u32,
        previous_message_id: String,
        message: VibeFfiMessage,
    },
    /// Same geometry — reconfigure pixels only.
    UpdateContent {
        index: u32,
        message: VibeFfiMessage,
        changed: u32,
    },
    /// May change height — the renderer must preserve the anchor across it.
    UpdateGeometry {
        index: u32,
        message: VibeFfiMessage,
        changed: u32,
    },
    /// Index-only relocation; content unchanged. Never animate as remove+insert.
    Move {
        from: u32,
        to: u32,
        message_id: String,
    },
    /// Window trim, **not** a deletion. Must not animate.
    EvictHead {
        count: u32,
    },
    EvictTail {
        count: u32,
    },
}

impl From<&VibeTimelineOpV1> for VibeFfiOp {
    fn from(op: &VibeTimelineOpV1) -> Self {
        match op {
            VibeTimelineOpV1::Insert { index, message } => Self::Insert {
                index: *index,
                message: message.into(),
            },
            VibeTimelineOpV1::Remove { index, message_id } => Self::Remove {
                index: *index,
                message_id: message_id.clone(),
            },
            VibeTimelineOpV1::RemapIdentity {
                index,
                previous_message_id,
                message,
            } => Self::RemapIdentity {
                index: *index,
                previous_message_id: previous_message_id.clone(),
                message: message.into(),
            },
            VibeTimelineOpV1::UpdateContent {
                index,
                message,
                changed,
            } => Self::UpdateContent {
                index: *index,
                message: message.into(),
                changed: changed.raw(),
            },
            VibeTimelineOpV1::UpdateGeometry {
                index,
                message,
                changed,
            } => Self::UpdateGeometry {
                index: *index,
                message: message.into(),
                changed: changed.raw(),
            },
            VibeTimelineOpV1::Move {
                from,
                to,
                message_id,
            } => Self::Move {
                from: *from,
                to: *to,
                message_id: message_id.clone(),
            },
            VibeTimelineOpV1::EvictHead { count } => Self::EvictHead { count: *count },
            VibeTimelineOpV1::EvictTail { count } => Self::EvictTail { count: *count },
        }
    }
}

/// Window bounds after applying a delta. Faithful mirror of
/// [`vibe_core::types::VibeWindowBounds`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct VibeFfiBounds {
    pub head_ts_ms: i64,
    pub tail_ts_ms: i64,
    pub has_more_before: bool,
    pub has_more_after: bool,
    /// Live rows in the durable store for this chat — not the window length.
    pub total_known: u64,
    pub window_len: u32,
}

impl From<VibeWindowBounds> for VibeFfiBounds {
    fn from(b: VibeWindowBounds) -> Self {
        Self {
            head_ts_ms: b.head_ts_ms,
            tail_ts_ms: b.tail_ts_ms,
            has_more_before: b.has_more_before,
            has_more_after: b.has_more_after,
            total_known: b.total_known,
            window_len: b.window_len,
        }
    }
}

/// A delta is either an ordered op list or a full-snapshot reset.
///
/// Kept as two variants rather than flattened to "ops, possibly empty": a
/// `Reset` is adopted by the consumer **regardless of generation**, and
/// collapsing it into an empty op list would silently drop that distinction and
/// leave a consumer stuck after a generation gap.
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum VibeFfiDeltaBody {
    Ops { ops: Vec<VibeFfiOp> },
    Reset { window: VibeFfiWindow },
}

/// One ordered delta. At most one per flush barrier.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct VibeFfiDelta {
    pub chat_id: String,
    /// The generation this delta applies *to*. A consumer holding a different
    /// generation must resync rather than apply.
    pub base_generation: u64,
    pub generation: u64,
    pub body: VibeFfiDeltaBody,
    /// Bounds *after* applying the body.
    pub bounds: VibeFfiBounds,
    pub unread_count: u32,
    pub first_unread_id: Option<String>,
}

impl From<&VibeTimelineDeltaV1> for VibeFfiDelta {
    fn from(d: &VibeTimelineDeltaV1) -> Self {
        let body = match &d.body {
            VibeTimelineDeltaBodyV1::Ops(ops) => VibeFfiDeltaBody::Ops {
                ops: ops.iter().map(VibeFfiOp::from).collect(),
            },
            VibeTimelineDeltaBodyV1::Reset(window) => VibeFfiDeltaBody::Reset {
                window: VibeFfiWindow::from(window.as_ref()),
            },
        };
        Self {
            chat_id: d.chat_id.clone(),
            base_generation: d.base_generation,
            generation: d.generation,
            body,
            bounds: d.bounds.into(),
            unread_count: d.unread.count,
            first_unread_id: d.unread.first_unread_id.clone(),
        }
    }
}

/// A bounded window query result.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct VibeFfiWindow {
    pub chat_id: String,
    pub generation: u64,
    pub messages: Vec<VibeFfiMessage>,
    pub bounds: VibeFfiBounds,
    pub unread_count: u32,
    pub first_unread_id: Option<String>,
}

impl From<&VibeTimelineWindowV1> for VibeFfiWindow {
    fn from(w: &VibeTimelineWindowV1) -> Self {
        Self {
            chat_id: w.chat_id.clone(),
            generation: w.generation,
            messages: w.messages.iter().map(VibeFfiMessage::from).collect(),
            bounds: w.bounds.into(),
            unread_count: w.unread.count,
            first_unread_id: w.unread.first_unread_id.clone(),
        }
    }
}
