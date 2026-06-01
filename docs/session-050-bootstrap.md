## Session 050 bootstrap prompt — paste into a fresh Claude conversation at session start

Use this as the first message to a new conversation. It mirrors the standing project-instructions session-bootstrap rule but pre-loads what just shipped so the new architect doesn't re-derive context.

---

Session 050 opening. Standard bootstrap, plus a head start.

**Standing bootstrap (do all of it, in order):**

1. `date "+%Y-%m-%d %H:%M %Z"` for the time ledger.
2. `cd /home/claude && rm -rf TalkCoach && git clone https://github.com/anton-glance/TalkCoach.git && cd TalkCoach && git log --oneline -8`
3. Read in order from the clone: `CLAUDE.md`, `docs/00_COLLABORATION_INSTRUCTIONS.md`, `docs/01_PROJECT_JOURNAL.md` (newest first — Session 049 is the most recent and covers the Phase 5 close), `docs/04_BACKLOG.md`, `docs/08_TIME_LEDGER.md`, `docs/03_ARCHITECTURE.md`, `docs/02_PRODUCT_SPEC.md`, `docs/07_RELEASE_PLAN.md`.
4. Recap state in 3–5 lines and ask what to work on.

**Pre-loaded context (so you don't waste tokens re-deriving):**

Locto / TalkCoach is in **Phase 6 — Polish & ship-readiness**. Phase 5 (Widget UI) closed Session 049 with `m5.7-complete` at commit `3ec9a5b`. Eight Phase 5 modules shipped: M5.1, M5.2, M5.3, M5.4, M5.4a, M5.5, M5.6, M5.7 (M5.8 brand identity was folded into M5.4).

**Phase 5 in one paragraph:** The widget now has a fully locked opacity state machine with two orthogonal layers (window alpha at AppKit, content opacity in SwiftUI), Liquid Glass material with two-zone tinted gradient and a real `ShadowStyle.inner` fallback for Reduce Transparency, cold-start pulsing Locto mark that covers every pre-first-WPM state including session-end-during-warming, hover that bumps alpha + lifts + reveals X at the FPC NSTrackingArea level (not via SwiftUI routing), L3 monologue continuous breathing on the bottom cluster, and a 7-state widget model where `.counting` only enters when `WPMCalculator` publishes the first non-nil WPM (gate-driven via `compactMap{$0}.prefix(1)` subscription).

**Phase 6 open items (read the backlog for full text):**
- **M6.1** — manual language override in menu bar (2h)
- **M6.2** — Settings sheet polish: WPM band slider (2h)
- **M6.3** — accessibility audit (3h) — note: this is the v1 accessibility item; the original M5.7 VoiceOver+IncreaseContrast scope was deferred to v2-accessibility per S049 product decision. M6.3 may be partially overlapping; check the backlog row before scoping.
- **M6.4** — dark/light mode visual check (2h)
- **M6.5** — first-launch defaults end-to-end (2h)
- **M6.6** — performance pass: re-run S7 measurements on real build (3h)
- **M6.7** — notarization & DMG creation (4h)
- **M6.8** — AirPods/HFP-codec device-switch fix (4–6h) — known live-reproducible bug from Session 041; full strawman fix direction is in the backlog row. **Likely the most user-impactful Phase 6 item.**
- **M6.9** — Reduce Motion wrap-fade snap (1h, deferred from S049)
- **M6.10** — mid-monologue dash flash (0.5h investigation if it recurs, deferred from S049)

**Phase 6 total estimate**: ~22–24h.

**Process rules carried forward from Phase 5:**
- Architect writes plans; agent executes; Anton smokes. Anton never reads agent plans or self-reviews.
- Commit-local → SHA-audit → Anton-smokes-local-build → push. The "done = pushed" rule failed four times in M5; the corrective is to audit via `git cat-file -e <sha>` (failure means local-only, which is what we want pre-smoke) and `git show <sha>` against the self-review.
- swiftlint --strict before declaring done; binary not on agent PATH so Anton runs it manually.
- Three-channel deliverable discipline: repo files via `present_files` (tarballs for multi-file), agent prompts inline (single fenced block, plain prose with inline backticks, never triple-fenced — Xcode chat panel can't select across fence boundaries), chat discussion in plain prose.
- NO-SKIPPING rule (S030): if something doesn't work and no clear solution is found, architect + agent continue resolving in the same session. Do not pass forward.
- Strawman pattern: for non-trivial design decisions, commit to specific choices, mark confidence, surface open questions, invite Anton to knock it down. Never "here are several options" with no recommendation.

**Recommendation for what to open Session 050 with:** ask Anton which Phase 6 module to start. **M6.8 (AirPods device-switch) is the most user-impactful** — the only known live-reproducible production bug. **M6.4 (dark/light visual check)** is a fast warmup that will surface design-token gaps. **M6.6 (performance pass)** is the riskiest item because perf regressions could force re-architecture; better to surface them early.

Don't recommend M6.7 (notarization) until M6.6 confirms performance and M6.8 closes the known crash path.

After the bootstrap, ask Anton what to work on.
