# 03 · Data model

How Locto represents and persists what it captures. The privacy boundary lives here.

## Core entities

### Session

A single mic-active period with detected speech.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | Stable identifier |
| `startedAt` | Date | First speech detected after mic activation |
| `endedAt` | Date? | Set on session finalization (mic deactivated, sleep, quit) |
| `durationMs` | Int | Cached `endedAt - startedAt` for query performance |
| `wordCount` | Int | Total words transcribed |
| `averageWpm` | Double | Mean pace across session |
| `medianWpm` | Double | Median pace (less skewed by pauses) |
| `peakWpm` | Double | Max 5-second-window pace observed |
| `valleyWpm` | Double | Min 5-second-window pace observed (only if at least 30 s of continuous speech) |
| `slowMs` | Int | Total ms in `tooSlow` state |
| `idealMs` | Int | Total ms in `ideal` state |
| `fastMs` | Int | Total ms in `tooFast` state |
| `fillerCount` | Int | Total filler words detected |
| `fillerRate` | Double | Fillers per 100 words |
| `longestSoloRunMs` | Int | Longest continuous-speech segment without ≥1.5 s pause |
| `appName` | String? | Frontmost app at session start (Zoom, Meet, etc.) — see privacy note |
| `coachNotes` | [CoachNote] | Generated at session end, persisted as JSON |

### Utterance

One transcribed segment within a session. Granularity is roughly per-sentence or per-pause (depends on the speech engine's segmentation).

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `sessionId` | UUID | Foreign key |
| `text` | String | Transcribed content |
| `startedAt` | Date | Relative to session start |
| `durationMs` | Int | |
| `wordCount` | Int | |
| `wpm` | Double | Computed from word count and duration |
| `state` | State | `tooSlow` / `ideal` / `tooFast` at the time of utterance |

### FillerOccurrence

A single occurrence of a configured filler word.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `sessionId` | UUID | Foreign key |
| `utteranceId` | UUID? | If detection was inside a transcribed utterance |
| `word` | String | Lowercased, normalized form (e.g., "uh", "um", "like") |
| `at` | Date | Relative to session start |

### CoachNote

| Field | Type | Notes |
|---|---|---|
| `kind` | NoteKind | `positive` / `tell` / `pattern` |
| `title` | String | Short headline (≤ 5 words) |
| `body` | String | 1-2 sentence explanation |
| `priority` | Int | For ranking when more candidates exist than slots |

### Settings (singleton, stored in UserDefaults)

| Field | Type | Default |
|---|---|---|
| `paceTargetMin` | Double | 110 wpm |
| `paceTargetMax` | Double | 180 wpm |
| `fillerWords` | [String] | `["um", "uh", "like", "you know", "right", "so", "basically", "actually"]` |
| `widgetPosition` | CGPoint | nil (auto-positioned) |
| `widgetEnabled` | Bool | true |
| `appearance` | Appearance | `.light` (MVP) — `.system` lands with v1.1 dark mode |
| `lastDashboardTab` | TimeRange | `.lastSession` |
| `excludedApps` | [String] | Empty default; users can blacklist apps where they don't want widget to appear (e.g., recording software they're already monitoring) |

## Aggregation views

Queries the dashboard needs efficiently:

- **By time range:** `WHERE startedAt BETWEEN ?startDate AND ?endDate`
- **Today / This week / etc.** are date-window helpers, not a separate column.
- **Filler word frequency** (per session, per range): `GROUP BY word, sessionId` then aggregate.
- **Pace over time** (line chart): pull all utterances for a session, sort by `startedAt`, plot `(startedAt, wpm)`.
- **Time-in-zone** (bar chart on right of pace chart): use cached `slowMs` / `idealMs` / `fastMs` on the session record.

For "all time" queries on a power user with thousands of sessions, build incremental aggregates on session-end so the dashboard doesn't re-scan everything. A nightly compaction job to a `DailyAggregate` table is the right shape if needed in v1.1+.

## Persistence layer

Two reasonable choices. Pick one and document the reason.

**Option A — SQLite via [GRDB](https://github.com/groue/GRDB.swift)**

- Pros: explicit schema migrations, performant queries, well-supported, type-safe Swift API
- Cons: external dependency
- Migration strategy: GRDB's built-in migrator with versioned schema steps in `Persistence/Migrations/`

**Option B — Core Data**

- Pros: built-in to the platform, no external dependency, integrates with iCloud sync if that ever matters (post-MVP)
- Cons: schema migrations are notoriously brittle, queries are verbose
- Migration strategy: lightweight automatic migrations where possible; mapping models for non-trivial changes

**Recommendation:** GRDB. Schema migrations are clearer, queries are faster, and the iCloud sync angle isn't relevant until accounts are added (which is post-PMF). Plus GRDB has better tooling for the analytical queries the dashboard needs.

## File-system layout

App support directory structure:

```
~/Library/Application Support/Locto/
├── locto.sqlite                        (encrypted with file-protection)
├── locto.sqlite-wal
├── locto.sqlite-shm
├── transcripts/                        (never used — see privacy boundary)
└── logs/
    └── locto.log                       (rotating, max 10 MB, no transcript content)
```

Audio recordings are never written to disk. Transcripts are stored in the SQLite database, not as separate files.

## Privacy boundary

This is the part that gets violated by mistake unless documented loudly.

### What persists

- Transcribed text (in the SQLite `Utterance` table)
- Aggregated session metrics (`Session` table)
- Filler-word occurrences (text, position)
- App name detected at session start (e.g., "zoom.us")
- User settings

### What does NOT persist

- Audio buffers — kept in memory only, released after transcription completes for the chunk
- Audio file paths — none, ever
- The user's identity beyond device-local settings (no email, name, account)
- IP addresses, device IDs, advertising IDs — none captured

### What does NOT leave the device

- Anything in the "persists" list above
- Crash report symbolication — strip transcripts before sending; only stack traces leave

### What MAY leave the device

- Anonymous app start counts (Daily Active Users) — only if explicit telemetry is added in a later phase, only with user opt-in
- Crash stack traces — to a privacy-respecting service (Sentry self-hosted, or PostHog with masking) — no transcript data
- Update checks (the app pinging for new versions)

### User controls

- **Per-session delete:** right-click in dashboard → "Delete session…" with confirmation. Immediate hard-delete from SQLite, no soft-delete state.
- **Bulk delete:** Settings → Privacy → "Delete all sessions…" — hard-deletes the whole dataset.
- **Export:** Settings → Privacy → "Export my data…" — produces a JSON dump in `~/Downloads/` with all sessions and utterances.
- **Quit & data:** quitting the app does not delete sessions. Uninstalling via Trash leaves data in `~/Library/Application Support/Locto/`. Clean uninstall instructions belong in support docs (not yet written).

### Encryption

- SQLite database stored with `NSFileProtectionComplete` on macOS — readable only when the user is logged in and the device is unlocked.
- No additional application-level encryption in MVP. If a stronger guarantee is needed later (e.g., for journalists or other high-threat users), add SQLCipher in v1.1+.

## Schema versioning

Use a `schema_version` table with a single integer column. Bump on every schema change. Migration steps live in `Persistence/Migrations/<version>.swift`. Never modify a shipped migration — only append new ones.

## Test data

For development and design QA, ship a "load demo data" debug menu item (visible only in Debug builds) that populates the database with 30 days of synthetic sessions. Strip from Release builds.
