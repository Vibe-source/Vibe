# Chat open with no main-thread work, and a list that never shifts

**Status:** P4-A landed 2026-08-03. B, C, D specified, not built.

Two requirements, stated by the product owner, that everything below serves:

1. **The push must not be settled by the main thread at all.**
2. **The list must never shift. Ever.**

Neither is an optimisation target. They are the acceptance criteria, and the
reason for them is on record: `ChatListView` is 22,586 lines *because* the
problem was attacked by optimisation for months, including by the strongest
model available. Optimisation produced the file. It did not produce a list that
holds still. So the remaining work is structural — the hybrid split Telegram and
Discord use, where the platform's UI toolkit draws and nothing else.

---

## Why the list still shifts today — measured, 2026-08-03

From a device run on the current build:

```
viewport-cover seed     off=4266  contentH=5222  boundsH=956   cover=86%
viewport-cover settled  off=4238  contentH=5222  boundsH=956   cover=89%
```

Content height never changed; the **offset moved 28 pt after mount**. That is the
visible jump on chat open.

```
MAIN-THREAD-SYNC-STALL  104ms at getStatus()
MAIN-THREAD-SYNC-STALL  109ms at getChatRows(_:)
```

```
setRows ins:60  (135 → 195)  177ms  applyMs=169
setRows del:60  (195 → 135)   73ms  applyMs=69
setRows ins:80  (135 → 215)   97ms  applyMs=88
```

Sixty older rows were inserted, **discarded**, then eighty inserted — three
main-thread stalls for a net result one pass could have produced.

The shape of the problem is not that any one of these is slow. It is that chat
open **pulls**: it reads the engine synchronously, parses, decrypts, measures,
mounts, then corrects. Correction after mount is what shifting *is*.

---

## The target: chat open is a hand-off, not a computation

```
        BEFORE push                          AT push                AFTER push
┌────────────────────────────┐        ┌──────────────────┐     ┌──────────────┐
│ core: order, dedup, window │        │ mount frozen     │     │ draw only    │
│ swift: parse, decrypt      │  ───►  │ snapshot         │ ──► │ (cellFor…)   │
│ metrics: measure + freeze  │        │ no measurement   │     │ no measure   │
└────────────────────────────┘        └──────────────────┘     └──────────────┘
     off the push                        main, but O(1)          main, bounded
```

A row that is measured before the push and never re-measured cannot shift. That
is the entire mechanism — there is no second code path to keep in agreement,
which is what the old list's twelve post-hoc height movers each are.

---

## P4-A — the core host draws real cells · **landed**

`VibeCollectionMessageListHost` registered exactly one cell,
`VibeTimelineBubbleCell`, a plain bubble it defines itself. That is why every
flag in front of the core stopped at the Diagnostics preview: the core could
order, window and seal a conversation but **could not draw one**. A real chat
needs agent turns, media, voice waveforms, link previews, replies, reactions —
all of which already exist in `ChatListCell`.

The host now takes a `rowProvider: ((String) -> ChatListRow?)` and dequeues
`ChatListCell` when one is supplied. The division it draws is the migration:

| Owner | Decides |
|---|---|
| **core** | which messages exist, in what order, how tall each is |
| **Swift** | what a message contains (parse, decrypt) and how it is drawn |

`cellForItemAt` does not measure, does not consult a height cache, and never asks
a cell what size it wants. Returning `nil` falls back to the placeholder bubble,
so a missing payload leaves a correctly-sized gap rather than a hole.

---

## P4-B — measurement that can leave the main thread · **not built**

**This corrects a claim made earlier in this project.** Measurement was called
main-thread-bound "and never will be", on the grounds that text measurement is
CoreText and `VibeRowMeasurementCache` is `@MainActor`. That is half right, and
the wrong half is load-bearing:

- **UIView-based sizing cannot leave the main thread.** `UILabel.sizeThatFits`,
  `VibeAgentTurnContentView.measuredHeight`, anything that instantiates or lays
  out a view — main thread, no exceptions.
- **`NSAttributedString.boundingRect(with:options:context:)` can.** It is
  CoreText over an immutable string. No view, no main thread.

### What the audit found — `docs/row-height-formulas.md`, 2026-08-03

A full inventory of every height path settles what is and is not movable, and it
is not a clean sweep:

**Off-main safe today — `boundingRect` and arithmetic only:**
plain text, rich text, media (known aspect), voice, video note, sticker,
document, link/music preview, reply preview, forwarded header, day separator,
`AgentRuntimeSummaryView.measuredHeight` (already a pure formula),
`AgentIntegrationPackView.measuredHeight` (a constant, 72),
`ChatNativeAgentTextRenderer.measuredSize`.

**Not movable — `VibeAgentTurnContentView.measuredHeight`
(`VibeAgentTurnContentView.swift:362–420`):**
it pins a width constraint on a shared template view, calls `configure`,
`layoutIfNeeded`, then `systemLayoutSizeFitting(…, .fittingSizeLevel)`. The body
is a `UIStackView` whose arranged subviews are built in a **loop over progress
items**, each of which is itself Auto Layout sized. There is no arithmetic that
reproduces that without rebuilding the stack — and rebuilding it in order to
predict it is worse than laying it out.

### So the split is by *when*, not only by *where*

Requirement 1 says the push must not be settled by the main thread. It does not
say every measurement must leave the main thread — it says none of them may
happen **during the push**. Two mechanisms, applied where each actually works:

| Rows | Mechanism |
|---|---|
| everything except agent turns | `VibeRowMetrics` — pure, off-main, measured while the transcript is prepared |
| agent turns | measured on main but **off the push** — at prewarm, or when the turn settles — then frozen |

A frozen agent-turn height is as good as an off-main one for this requirement,
because the push reads a number either way. What matters is that the number
exists before `pushViewController` and is never re-derived after.

This is also why P4-C is not optional. Without a prepared timeline there is
nowhere for either measurement to happen except during the push.

```
VibeRowMetrics.height(kind:text:font:width:mediaAspect:…) -> CGFloat
```

no `UIView` in the call graph, callable from any thread. Each case needs a test
asserting it agrees with the view-based measurement it replaces to within
0.5 pt — a disagreement is a shift, which is the thing this exists to prevent.

**Trap the audit surfaced:** `estimateMessageHeight` is the *exact* path despite
the name, and `presentationSeedMessageHeight` is the progressive one. The two
disagree on settled agent turns, where the seed uses a `boundingRect` + character
formula capped at 430 while the exact path lays out the real view. That
disagreement is a shift by construction and is a strong candidate for the 28 pt.

---

## P4-C — the prepared timeline · **not built**

`getChatRows` blocks the main thread for 109 ms because the chat **pulls** from
the engine at open. The core exists partly to make that structurally impossible:
it has no synchronous read API.

So the route must be handed a snapshot rather than fetch one:

- the engine **pushes** its rows into the core at the persistence choke
  (`persistHistoryRowsToStoreLocked`, `ChatEngine.swift:12255` — the comment
  there already calls it "the single choke for every persist path")
- the core orders, dedups and windows them
- metrics (P4-B) measure and freeze, off the push
- `prepareForNavigationPush` mounts the frozen result

Chat open then costs one array hand-off and a `reloadData` over pre-sized rows.

Also removes the 60-in / 60-out / 80-in churn: pagination becomes a core window
move, not three separate `setRows` passes each re-deciding the whole list.

---

## P4-D — point the chat surface at the host · **not built**

`ChatConversationController` → `ChatMainView` → **`VibeCollectionMessageListHost`**
instead of `ChatListView`, for 1:1 DM first, behind `vibeAsyncTimelineV1Enabled`
+ `eligibleChatClasses`, both of which already exist and are already default-off.

What stops being on the path, rather than being optimised:

- the twelve post-hoc height movers in `docs/chat-list-seams-map.md`
- `syncOnQueue`-from-main reads during open
- the dual seed/exact sizing paths
- progressive warmup and its corrections

That list is the answer to "will the old functions be removed?" — they are
removed by **replacement**, once the thing replacing them can draw a chat.

---

## Gates

Inherited from §9.1, plus the two requirements above stated as measurements:

| Gate | Threshold |
|---|---|
| Settled-row geometry changes after mount | **0** |
| Content-offset movement between seed and settled | **0 pt** |
| `MAIN-THREAD-SYNC-STALL` during chat open | **0** |
| Main-thread transaction | p95 ≤ 4 ms, p99 ≤ 8 ms |
| Instantiated cells | visible + ≤ 2 screens |
| Metrics agreement (P4-B vs view-based) | 0 rows differ by > 0.5 pt |

The offset-movement gate is new and is the direct expression of "never shifts".
It is measurable today from `viewport-cover seed` vs `viewport-cover settled`.
