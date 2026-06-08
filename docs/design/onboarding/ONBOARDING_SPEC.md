# Onboarding Flow Specification — Locto v1

> **Purpose:** Design handoff document for the Locto first-launch onboarding experience. Covers all five steps, screen-by-screen content, interaction states, and technical constraints. Placeholder copy is marked `[COPY: ...]` — product owner reviews and replaces before implementation.
>
> **Owner:** Product owner (copy) + Design (visuals) + Architect (implementation spec).
> **Status:** Draft — Session 050. Copy placeholders pending product owner review.

---

## Overview

Onboarding runs exactly once: on the first launch after install. It is a linear five-step modal flow. The app does not show the menu bar or widget until onboarding completes. After completion, `hasCompletedOnboarding` is written to UserDefaults and the flow never runs again.

All model assets are bundled in the installer — no downloads during onboarding. No internet connection required.

**Permissions required (v1):**
- Microphone (`AVCaptureDevice` / `AVFoundation`)

No Speech Recognition permission — v1 transcription runs entirely through Parakeet (Rust/ONNX) and Silero VAD; `SFSpeechRecognizer` is not used. The `NSSpeechRecognitionUsageDescription` plist key and `PermissionManager`'s speech branch are removed as part of M6.5 cleanup. No Screen Recording, no Accessibility.

---

## Step 1 — Welcome

**Window type:** Centered modal, fixed size. No close button. No window chrome (title bar hidden).

**Layout:**
- Locto logo / wordmark centered top
- Headline: `[COPY: short punchy welcome headline, ~5 words]`
- Body: `[COPY: 2–3 sentences. What Locto does. Local-only, no cloud. Works silently during calls.]`
- Single CTA button: `[COPY: "Get Started" or similar]`

**Interaction:** Clicking the CTA advances to Step 2. No back navigation from Step 1.

---

## Step 2 — Permissions + Language Setup

**Window type:** Same centered modal. No close button.

**Layout:**
- Section heading: `[COPY: "Let's get you set up" or similar]`
- One permission row (icon + label + toggle):
  - **Microphone** — `[COPY: one-line explainer, e.g. "To hear your speech during calls. Nothing leaves your Mac."]`
- Language section below the permission rows:
  - **Primary language** (mandatory) — dropdown, pre-populated with the Mac system locale. Label: `[COPY: "Your main speaking language"]`
  - **Secondary language** (optional) — dropdown, empty by default. Label: `[COPY: "Optional second language"]`. A clear/empty option must be available.
- Footer note: `[COPY: brief privacy reassurance, ~1 sentence. "All processing happens on your Mac."]`
- CTA button: `[COPY: "Continue"]` — **disabled** until both permission toggles are ON and the primary language dropdown has a value.

**Interaction — permission toggles:**
- Toggle OFF → ON: triggers the macOS system permission dialog for that permission (same as `PermissionManager.requestAll()` today). If the user denies in the system dialog, the toggle snaps back to OFF and a small inline message appears: `[COPY: "Locto needs this to work. You can enable it in System Settings."]` with a `[COPY: "Open Settings"]` link.
- Toggle ON → OFF: not allowed during onboarding (toggle is one-way). If already granted and the user tries to toggle OFF, show inline message directing to System Settings to revoke.
- If a permission was previously granted (e.g. user quit and relaunched before finishing onboarding), the toggle appears pre-set to ON.

**Interaction — language dropdowns:**
- ~50 locales available (same set as existing `SettingsStore.declaredLocales`).
- Max 2 total (primary + secondary). If secondary is set to the same value as primary, show inline validation: `[COPY: "Choose a different language for the second slot."]`
- Secondary dropdown has an explicit "None / not set" option at the top.

**CTA activation:** Microphone toggle ON + primary language selected → button activates. Tapping advances to Step 3.

---

## Step 3 — Menu Bar Explainer

**Window type:** Same centered modal OR full-screen dark overlay (see note below).

**Goal:** Show the user where the Locto icon lives in the menu bar.

**Preferred approach (if feasible on macOS without Accessibility permission):** Darken the screen with a semi-transparent overlay and draw an animated highlight around the Locto menu bar icon, with a floating tooltip-style card below it.

**Fallback (if overlay requires Accessibility permission or is technically blocked):** Standard centered modal window with an animated illustration of the menu bar showing the Locto icon highlighted.

**Content (tooltip card or modal body):**
- Animated arrow or pulse pointing to the menu bar icon position
- Text: `[COPY: ~1–2 sentences. "Locto lives quietly here. Click to pause coaching or open Settings."]`

**Interaction:** Single `[COPY: "Next"]` button on the tooltip card or modal. Advances to Step 4.

**Technical note for implementation:** The screen overlay approach requires the app to create a transparent full-screen `NSWindow` above all other windows. This does NOT require Accessibility permission — it's the app's own window. However, in `LSUIElement` mode (menu-bar-only app), the app may not be able to draw above Dock or menu bar system chrome. Architect must validate feasibility during M6.5 implementation before committing to the overlay approach; if blocked, use the animated illustration fallback.

---

## Step 4 — Widget Explainer

**Window type:** Same as Step 3 (overlay or modal fallback, matching the choice made in Step 3).

**Goal:** Show the user where the widget appears and that it can be dragged.

**Preferred approach:** Full-screen overlay with an animated widget mockup drawn at the default widget position (top-right corner). Widget renders in full green (all metrics in the "good" zone) to communicate the ideal experience. Animated arrow or dashed line shows drag affordance.

**Fallback:** Centered modal with animated illustration of the widget in the corner, drag arrow shown.

**Content:**
- Animated widget (green state) at default position
- Two sequential text hints (fade in one after the other, or two separate text areas):
  - `[COPY: "The widget appears automatically when you start a call."]`
  - `[COPY: "Drag it anywhere — it remembers where you left it."]`

**Interaction:** Single `[COPY: "Next"]` button. Advances to Step 5.

---

## Step 5 — You're Set

**Window type:** Centered modal. Has a close button (X) — user can dismiss from here.

**Layout:**
- Headline: `[COPY: "You're all set."]` or similar
- Body: `[COPY: 1–2 sentences. "Open your favorite calling app and start a conversation. Locto will appear automatically."]`
- App icon row: horizontal scrolling or wrapping grid of communication app icons. 10 apps (designer creates animated flow / parade of icons):
  1. Zoom
  2. Microsoft Teams
  3. Google Meet (browser icon)
  4. FaceTime
  5. Slack
  6. Discord
  7. Webex
  8. Skype
  9. WhatsApp
  10. Telegram
- CTA button: `[COPY: "Start Coaching"]` — closes the onboarding window and begins normal app operation. Menu bar icon becomes active. No session starts until the user actually opens a call app.

**Interaction:** Clicking `[COPY: "Start Coaching"]` sets `hasCompletedOnboarding = true` in UserDefaults and dismisses the window. App transitions to normal operation (menu bar icon visible, session lifecycle active).

---

## State persistence across restarts

If the user force-quits mid-onboarding:
- `hasCompletedOnboarding` remains `false`, so the flow re-opens on next launch.
- `hasCompletedSetup` (existing flag from M1.3) is set only when Step 5 completes.
- Permissions already granted persist via the OS — toggles in Step 2 appear pre-set to ON on re-entry.
- Language selections made in Step 2 are persisted to `SettingsStore` immediately on selection (not on CTA tap), so they survive a restart.

---

## Out of scope for v1

- Skip / "Do this later" option — not allowed. Onboarding must complete before the app is usable.
- Model download progress — models are bundled in the installer; no download step in onboarding.
- Tutorial for Settings — the Settings window is self-explanatory for the v1 feature set.
- Multi-language mid-session switching — v2. Only the initial primary/secondary selection is set here.

---

## Copy placeholders index

All `[COPY: ...]` items for product owner review:

| Step | Element | Placeholder |
|---|---|---|
| 1 | Headline | `[COPY: welcome headline ~5 words]` |
| 1 | Body | `[COPY: 2–3 sentence app description]` |
| 1 | CTA button | `[COPY: "Get Started" or equivalent]` |
| 2 | Section heading | `[COPY: "Let's get you set up"]` |
| 2 | Mic permission explainer | `[COPY: one-line, mention on-device / no data leaves Mac]` |
| 2 | Primary language label | `[COPY: label text]` |
| 2 | Secondary language label | `[COPY: label text]` |
| 2 | Permission denied inline message | `[COPY: ~1 sentence + link label]` |
| 2 | Privacy footer | `[COPY: ~1 sentence]` |
| 2 | CTA button | `[COPY: "Continue"]` |
| 3 | Tooltip / body text | `[COPY: 1–2 sentences about menu bar icon]` |
| 3 | Next button | `[COPY: "Next"]` |
| 4 | Hint line 1 | `[COPY: widget appears automatically]` |
| 4 | Hint line 2 | `[COPY: drag it anywhere]` |
| 4 | Next button | `[COPY: "Next"]` |
| 5 | Headline | `[COPY: "You're all set."]` |
| 5 | Body | `[COPY: 1–2 sentences with call to action]` |
| 5 | CTA button | `[COPY: "Start Coaching"]` |
