# 04 · Build phases

How to sequence the work so the App Store launch ships at the right moment, and post-launch iterations have a clear scope.

## Phasing principle

Every phase has a **shippable end state**. We don't go to Phase N+1 until N is in users' hands, has been observed for a week, and the founder has decided whether the next phase is still the right next thing.

## Phase 0 — what already exists (MVP-in-progress)

Anton has stated the MVP exists. This phase is whatever's in the repo today. The Claude Code agent should start by reading the actual codebase before assuming the docs describe current state. If there's a gap between what's documented here and what's built, document the gap in `05-open-questions.md` rather than silently rebuilding.

## Phase 1 — App Store launch

Goal: ship a paid Mac App Store listing that solves the core promise (ambient pace + filler feedback during real conversations) cleanly enough that early adopters become advocates.

### Features in scope

- Auto-trigger widget on mic activation
- Real-time pace + filler detection (English, on-device)
- Three-state widget with all visuals from the brand guidelines
- Dashboard with last-session, today, this-week tabs
- Pace over time chart (line chart with reference lines)
- Filler-word breakdown (vertical strokes)
- Coach notes (rule-based, deterministic — no LLM call)
- Onboarding flow (4-5 steps)
- Settings (general, permissions, filler words, privacy)
- Session export (JSON dump)
- Light mode only

### Acceptance criteria

- App passes Mac App Store review on first or second submission. (Allow for one rejection cycle on minor fixable issues.)
- Onboarding completion rate > 80% in internal beta (5-10 testers).
- No crashes in a 1-hour live session (Zoom, Meet, browser audio).
- Memory usage < 250 MB sustained during active session.
- Widget appears within 400 ms of mic activation in 95% of cases.
- Privacy: a packet capture during a 30-minute session shows zero outbound transcript data.

### Out of scope for Phase 1

- Dark mode (Phase 1.1)
- Multilingual (Phase 2)
- Custom filler-word lists (Phase 2)
- LLM-powered coach notes (Phase 2)
- Streaks, goals, gamification (likely never)
- iOS companion (Phase 3+ if ever)

### Pricing

Locked in `05-open-questions.md`. Recommendation when ready: free trial (7 days unlimited) → paid subscription (`$4.99/mo` or `$39/yr` as starting points to test). Do not ship the App Store listing without a pricing decision.

## Phase 1.1 — first patch (target: 2-4 weeks post-launch)

Goal: address the top 3-5 issues from real users. Ship dark mode.

### Features in scope

- Dark mode (full app — widget, dashboard, settings, onboarding)
- Bug fixes from launch-week reports
- Whatever permission/onboarding friction surfaced in real-user data
- (If signal supports it) one or two settings users requested most loudly

### Acceptance criteria

- Dark mode parity — every screen reads cleanly in dark.
- Any bug from launch week with > 2 reports is fixed.
- App Store rating ≥ 4.2 (assumes some negative signal absorbed in 1.0).

## Phase 2 — first feature expansion (target: 2-3 months post-launch)

Goal: deepen for the segment showing strongest retention from Phase 1 data. Don't decide the segment until Phase 1 telemetry says.

### Candidate features (pick 2-3 based on signal)

- **Multilingual transcription** — Spanish, Portuguese (BR), German first based on the GTM brief. Whisper.cpp supports these natively if Apple Speech doesn't.
- **Custom filler-word lists** — user can add/remove words from the tracked list.
- **LLM-powered coach notes** — replace rule-based notes with on-device LLM (Llama 3, Phi-3) for richer, situational feedback. Stays on-device, no cloud.
- **Session search** — search transcripts ("when did I say 'circle back' in the last month?")
- **Tags / contexts** — let users label sessions ("interview prep", "podcast", "team meeting") and filter dashboard by tag.
- **Trend insights** — weekly/monthly automated reports ("filler rate down 30% vs last month").

### Out of scope for Phase 2

- Web app or browser extension
- Team / collaboration features
- API for third-party integration

## Phase 3 and beyond

Only worth scoping after Phase 2 ships and the product has clear PMF signal. Possibilities:

- iOS companion (read-only at first — view sessions on phone)
- Speaker diarization (separate user voice from meeting attendees) — hard, on-device
- Audio file import for non-realtime analysis (podcast post-production angle)
- Custom AI persona / coaching style (formal, casual, executive)
- Integration with calendar (auto-tag sessions to meetings)

## Anti-roadmap

Things we are deliberately not building, even if requested:

- **Cloud sync.** Adds complexity, requires accounts, breaks the privacy story. Local-first forever.
- **Social features.** Sharing sessions, leaderboards, community. Wrong audience — speakers don't want to be ranked publicly.
- **Coaching humans.** Locto coaches via software, not by connecting users to human coaches. Different business model entirely.
- **Audio recording.** We never want to be storing audio files. Ever.
- **Browser extension.** The whole point is system-wide, app-agnostic. Browser extension narrows the surface area.

## Decision checkpoints between phases

Before pulling the trigger on each phase:

1. **Phase 1 → 1.1:** has Locto been in App Store for 7+ days? Are there 3+ user reports? Are they directionally consistent? If yes, ship 1.1 with what they're asking for.
2. **Phase 1.1 → 2:** is retention stable (D7 > 40%)? Has one segment emerged as the heaviest user (from session metadata, e.g., session count, average duration)? If yes, build Phase 2 for that segment. If retention is bad, do not add features — fix the core experience first.
3. **Phase 2 → 3:** is there a paid customer base of 500+ on annual plans, or 1000+ on monthly? If yes, hire someone or commit to expansion. If not, stay in maintenance.
