# 05 · Open questions

Decisions still pending. Resolve these before or during implementation. The Claude Code agent should not silently pick defaults — surface the question, get an answer, document it, then proceed.

When a question is resolved, move it to the bottom under "Resolved" with the answer and the date.

## Tech stack

### Q1: Which on-device transcription engine?

**Options:**
- **Apple Speech framework (`SFSpeechRecognizer`)** — built-in, free, works for English well. Multilingual coverage decent. Requires `Speech` permission. Less control over the model.
- **whisper.cpp** — best multilingual quality. Ships a model file with the app (~150 MB for `small`, ~500 MB for `medium`). More CPU/RAM during inference. Full control.
- **Apple's on-device dictation models** (newer macOS only) — better quality than `SFSpeechRecognizer`, but requires macOS 14+ minimum.

**Implications:**
- App Store binary size if whisper.cpp model bundled.
- Multilingual roadmap depends on this choice — Apple Speech does many languages but quality drops; whisper handles them all well.
- Battery / thermal load on the user's Mac.

**Recommendation when forced:** Apple Speech for MVP (smaller binary, simpler), swap to whisper.cpp in Phase 2 when multilingual matters.

### Q2: Persistence — GRDB or Core Data?

See `03-data-model.md` for the trade-off. **Recommendation:** GRDB for clarity of migrations and query performance.

### Q3: Minimum macOS version?

**Options:**
- macOS 13 (Ventura) — caps at ~80% of installed Macs as of 2026.
- macOS 14 (Sonoma) — closer to ~70%, but unlocks newer SwiftUI APIs and on-device dictation models.
- macOS 15+ — narrows the audience further but cleanest API surface.

**Trade-off:** lower minimum = bigger market; higher minimum = less compatibility code.

**Recommendation when forced:** macOS 14 (Sonoma). Indie Mac apps targeting professional users can assume current OS.

### Q4: Crash reporting / error monitoring service?

**Options:**
- **None.** Zero telemetry, zero error visibility. Hardest to debug user-reported issues.
- **Sentry (cloud)** — broadest support, but data-policy questions on transcript content.
- **Sentry (self-hosted)** — full control, real ops cost.
- **MetricKit (Apple)** — built-in crash reports via Apple, no third party. Limited compared to Sentry but privacy-clean.

**Recommendation when forced:** MetricKit for v1. Ensures no third-party data flow. Add Sentry self-hosted only if MetricKit's diagnostics are insufficient.

## Permissions and entitlements

### Q5: Mic activity detection mechanism?

**Options:**
- **CoreAudio HAL plug-in / process listing** — most reliable. Detect when other processes open audio input. Requires accessibility permission or specific entitlements.
- **`AVAudioEngine` polling** — Locto opens its own input stream, monitors for content. Simpler permissions. May not detect when *other* apps are using the mic.
- **System notifications** — listen for `NSWorkspace` events when known mic-using apps activate (Zoom, Meet via browser, etc.). Fragile, app-specific allowlist.

This decision drives the permissions UX significantly. Mic detection failing = product failing.

### Q6: Sandboxing — Mac App Store or direct?

**Options:**
- **App Store only** (sandboxed) — accessibility entitlements get stricter scrutiny, mic detection gets harder. Apple's payment system, 30%/15% cut.
- **Direct download only** — full system access, but no App Store distribution.
- **Both** — same binary signed differently. Most flexible, more setup.

**Recommendation when forced:** target App Store first (constrained environment forces clean architecture), add direct download in Phase 1.1 if App Store review blocks key features.

## Pricing and licensing

### Q7: Pricing tiers and trial length?

Out of scope for build, but blocks App Store launch. From the project brief: freemium subscription assumed. Concrete decision needed: free trial vs free tier with limits, monthly vs annual, single tier vs multi-tier.

**When making this decision, consider:**
- Mac App Store pricing tiers (Apple-set increments)
- Competitor benchmarks: Yoodli ($0–24/mo), Speeko ($9.99/mo), Orai ($179/yr post-free tier), Vocal Image ($16/mo)
- Whether to ship without payment integration in v1.0 (free) and add monetization in v1.1

**Recommendation when forced:** ship Phase 1 with one tier — `$5/mo or $40/yr` after 7-day free trial. Validate willingness-to-pay before adding tiers.

### Q8: Open source license vs proprietary?

For a closed-source commercial Mac app, no license is fine. If any portion of the codebase is opened (e.g., a Locto SDK for whisper integration), pick MIT or Apache 2.0.

**Recommendation when forced:** proprietary for now. Add license later if open-sourcing a component makes sense.

## Product decisions

### Q9: Dark mode timing?

Phase 1.1 per `04-build-phases.md`. Confirm with Anton — if he wants it in Phase 1, it pushes the launch date by 1-2 weeks.

### Q10: Multilingual roadmap priority?

GTM brief says multilingual from day one is the goal. Reality of Phase 1: English only. **Question:** Which language is second, and when does it ship?

**Probable order based on GTM brief:** Spanish → Portuguese (BR) → German → French → Mandarin → Hindi.

**Question:** Are filler-word lists per language ready? "Um/uh/like" doesn't translate directly — Spanish has "este," "o sea," "pues"; Portuguese has "tipo," "né"; German has "äh," "halt." Each language needs a curated list, validated by a native speaker.

### Q11: What's the default position for the widget?

Top-right of the active screen seems obvious, but:
- Some users have menu bar items there (Bartender, etc.) — widget may overlap.
- Multi-display: which screen?
- Notch on M1+ MacBooks: avoid the notch zone.

**Recommendation when forced:** top-right, 16 pt inset from screen edges, 56 pt from top to clear menu bar. Persist user-dragged position per-display.

### Q12: How many sessions to keep in default storage?

Forever, with manual delete? Or auto-prune after N days?

**Recommendation when forced:** keep all sessions forever by default. Add "Auto-delete sessions older than N days" setting in Phase 1.1 if disk-space complaints surface.

## Distribution and ops

### Q13: Code signing and notarization workflow?

Both App Store and direct-download require Apple Developer Program ($99/yr) and notarization. CI/CD pipeline needed.

**Question:** is this set up? If not, document the steps in a separate `docs/operations.md` once the build pipeline is ready.

### Q14: Update mechanism for direct-download builds?

**Options:**
- **Sparkle** (industry standard) — well-supported, requires hosting the appcast XML.
- **Manual updates** — user downloads a new DMG. Friction.
- **Mac App Store auto-update** — only if going App Store-exclusive.

**Recommendation when forced:** Sparkle for direct-download, App Store auto-update for App Store builds. Same source code, different update path.

### Q15: Where is locto.io hosted?

Static site? Framework? Just a landing page or full marketing site?

**Recommendation when forced:** start with a static landing page (Astro, Next.js static export, or just hand-written HTML) on Cloudflare Pages or Vercel. Keeps cost near zero. Build out as marketing matures.

---

## Resolved

(Move questions here as they're answered. Format: `**[Date] Q#:** answer.`)

(none yet)
