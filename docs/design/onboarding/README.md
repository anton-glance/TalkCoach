# Handoff: Locto — First-Launch Onboarding Flow

## Overview

This package documents the **Locto v1 first-launch onboarding** — a linear, five-step modal flow shown exactly once on the first launch after install. Locto is an ambient macOS speech coach that lives in the menu bar and shows a small floating widget while the mic is active.

The flow: **Welcome → Set up (mic + languages) → Menu-bar explainer → Widget explainer → You're set.** On completion the app writes `hasCompletedOnboarding = true` to UserDefaults and never runs onboarding again. The menu-bar icon and widget do not appear until onboarding completes.

The authoritative product spec is included as **`ONBOARDING_SPEC.md`** — read it alongside this README. Where this README and the spec differ, the differences are **intentional design decisions made after the spec** and are called out explicitly below (see "Deviations from the spec").

---

## About the Design Files

The files in this bundle are **design references created in HTML/React (via in-browser Babel)** — a clickable prototype showing the intended look, copy, and behavior. **They are not production code to copy directly.**

The target app is a **native macOS menu-bar app (Swift / SwiftUI or AppKit)**. Your task is to **recreate these designs in that environment** using its established patterns — native `NSWindow`/SwiftUI sheets, `AVCaptureDevice` permission APIs, `UserDefaults`, the existing `SettingsStore`, and the already-shipping widget component. Treat the HTML as the spec for pixels, motion, and states; implement it idiomatically in Swift.

The production design tokens live upstream in `DesignTokens.swift` (see the Locto design system). The values in `tokens.css` (included here) mirror those — use the Swift source as the source of truth for shipping values.

### How to run the reference prototype
Open `Locto Onboarding.html` in a browser. A dark **review toolbar** at the bottom lets you jump between the five steps, toggle **"Spec notes"** (pinned implementation annotations), and restart. Arrow keys also navigate. Step state persists in `localStorage` under `locto.onboarding.v1`.

---

## Fidelity

**High-fidelity.** Final colors, typography, spacing, motion, copy, and interaction states. Recreate the UI faithfully using the codebase's native components. All copy is **draft, written in Locto's voice** — flagged for product-owner review before shipping (the spec's `[COPY: …]` placeholders). Drop-in text is acceptable for build; final wording is the product owner's call.

---

## Global structure & conventions

- **Stage:** the prototype renders on a simulated 1440 × 900 macOS desktop (wallpaper + menu bar + dock) purely to give the modals context. In the real app there is no simulated desktop — the modals are real windows over the user's actual screen.
- **Modal window:** every step is the **same fixed size — 560 × 600 pt** — chromeless (no title bar). Steps 1–4 have **no close button**; **Step 5 has a close button (X)** top-right. Content sits in a flex column; the **footer is pinned to the bottom**.
  - Surface `#FFFFFF`, corner radius **22 pt**, border `0.5px solid rgba(0,0,0,0.06)`, shadow `0 32px 80px rgba(20,30,28,0.30), 0 8px 24px rgba(20,30,28,0.14)`, padding `44px 48px 30px`.
  - Vertical alignment: Steps 1 & 5 center their content; Steps 2, 3, 4 top-align (footer still pinned bottom).
- **Footer:** left = progress dots, right = primary button. **Exception: Step 5 has no progress dots** (button only, right-aligned).
- **Progress dots:** 5 dots, 6 pt tall. Active dot is a 20 pt-wide pill in `--brand`; completed dots `--teal-200`; upcoming dots `--border-strong`. 7 pt gap.
- **CTA gating:** advance buttons disable until their step's requirements are met (see Step 2).

---

## Screens / Views

### Step 1 — Welcome  (`StepWelcome`)
- **Purpose:** First impression; state what Locto is and that it's fully on-device.
- **Layout:** centered column.
  - **Lockup** (ring mark + "locto" wordmark), mark 30 pt.
  - **Headline**, margin-top 36: `speak in your` / `sweet spot.` (two lines). Inter Display, 40 pt, weight 300, letter-spacing −1.6px, line-height 1.08, color `--text-primary`.
  - **Body**, margin-top 18, max-width 380, centered: 15 pt, line-height 1.65, color `--text-secondary`. Draft copy: *"Locto is an ambient speech coach that lives at the edge of your screen. It watches your pace and nudges you back to your sweet spot — quietly, while you talk. Everything runs on your Mac. Nothing is recorded, and nothing ever leaves your device."*
  - **Footer:** progress dots (step 1) + primary button **"Get started"**.
- **Interaction:** button → Step 2. No back navigation.

### Step 2 — Set up: permissions + language  (`StepSetup`)
- **Purpose:** Grant the microphone and pick speaking language(s).
- **Layout (top-aligned):**
  - **Eyebrow** "— SET UP" (see Eyebrow component).
  - **Heading** "Let's get you set up." — 26 pt, weight 500, letter-spacing −0.6px, `--text-primary`. Sub-line below, 14 pt, `--text-secondary`: *"One permission and your languages. Takes about ten seconds."*
  - **Microphone permission row** (margin-top 22): recessed card `--surface-2`, border `0.5px solid --border`, radius 14, padding `14px 16px`, flex row.
    - Left: title "Microphone" (15 pt, weight 500) + explainer (13 pt, `--text-secondary`, line-height 1.45): *"To hear your speech during calls. It's analyzed on your Mac and discarded — never recorded."*
    - Right: **Toggle** (macOS-style switch, see component).
    - Below the card while mic is **off**: tertiary note (12.5 pt, `--text-tertiary`): *"macOS will ask you to confirm."*
    - After granted, if the user taps the toggle again: neutral inline message *"Microphone access is on. To turn it off, manage it in System Settings → Privacy."* (toggle is one-way during onboarding).
  - **Language section** (margin-top 22): two columns, gap 16.
    - **"Your main speaking language"** — Dropdown, mandatory, defaults to system locale (prototype defaults to "English (US)").
    - **"Optional second language"** — Dropdown with a **"None"** row at the top, optional.
    - If secondary == primary: inline coral validation *"Choose a different language for the second slot."*
  - **Privacy footer** (margin-top 20): 12.5 pt, `--text-tertiary`: *"All processing happens on your Mac. Locto works fully offline and never sends your audio anywhere."*
  - **Footer:** progress dots + **"Continue"** (disabled until: mic granted **AND** a primary language is set **AND** secondary ≠ primary).
- **Interaction:**
  - Toggling mic OFF→ON triggers the **macOS system microphone prompt** (`AVCaptureDevice.requestAccess(for: .audio)`). **This is a system window — do not design or build a custom dialog.** In the prototype, granting is represented by flipping state directly.
  - Language picks **persist to `SettingsStore` immediately on change** (not on CTA), so they survive a mid-onboarding restart.
  - Locale set: ~50 in production (`SettingsStore.declaredLocales`); the prototype includes a representative 30.

### Step 3 — Menu-bar explainer  (`StepMenuBar`)
- **Purpose:** Show where the Locto icon lives in the menu bar.
- **Window type:** **standard modal** (same 560 × 600 sheet). *No screen overlay* — see Deviations.
- **Layout (centered):**
  - Eyebrow "— MENU BAR".
  - Heading "Locto lives up here." + body: *"Look for the ring in your menu bar, top-right. Click it any time to pause coaching or open settings."*
  - **A drawn "screenshot" crop** (`ScreenCrop`, 190 pt tall) of the menu bar: faux app menus (Zoom / Edit / Meeting) on the left; on the right the **highlighted Locto ring** — a 26 pt filled `--brand` chip with white mark and a green glow (`0 0 0 3px rgba(15,110,86,0.20), 0 0 16px 3px rgba(15,110,86,0.42)`) — sitting **to the LEFT of the system icons** (battery, wifi, clock), as real macOS third-party items do. A caret + open dropdown drop from the ring: **"● Active"**, "Pause coaching", "Settings…", "Quit Locto".
  - Footer: progress dots + **"Next"**.

### Step 4 — Widget explainer  (`StepWidget`)
- **Purpose:** Show the widget, that it auto-appears, reads green when you're in your sweet spot, and can be placed **anywhere** on screen.
- **Window type:** standard modal.
- **Layout (centered):**
  - Eyebrow "— THE WIDGET".
  - Heading "Put it wherever you like." + body: *"The tile appears on its own when a call starts — green means you're in your sweet spot. Drag it anywhere on your screen, and it stays exactly where you leave it."*
  - **ScreenCrop** (246 pt tall) with a menu-bar sliver and the **live widget component** (rendered at 0.72 scale) that **animates to a new position every 2 s**, gliding (transition `left/top 0.95s cubic-bezier(0.4,0,0.2,1)`) among five non-corner spots to convey "anywhere." A small drag-cursor glyph rides with the tile. The widget shows a **ticking monologue clock** (mm:ss counts up) and a **drifting WPM** that stays in the green/ideal band.
  - Caption under the crop: "Drag the widget anywhere on your screen".
  - Footer: progress dots + **"Next"**.

### Step 5 — You're set  (`StepReady`)
- **Purpose:** Confirm setup; show supported calling apps; start.
- **Window type:** modal **with a close button (X)** top-right (the only dismissible step).
- **Layout (centered):**
  - **Lockup** (ring + "locto", mark 30 pt) — same as Step 1.
  - Heading "You're all set." (30 pt, weight 500, −0.8px) + body: *"Open your favorite calling app and start talking. Locto appears on its own — no buttons to press."*
  - **App parade:** a horizontally auto-scrolling marquee (26 s linear loop) of **10 calling apps** — Zoom, Teams, Meet, FaceTime, Slack, Discord, Webex, Skype, WhatsApp, Telegram. Each tile: 60 pt rounded square (`--surface-2`, border `0.5px --border`, radius 16) + label (11.5 pt, `--text-tertiary`). Edge fade masks on both sides.
  - **No progress dots.** Footer: **"Start coaching"** button, right-aligned.
- **Interaction:** "Start coaching" (or the X) sets `hasCompletedOnboarding = true`, dismisses the window, and transitions the app to normal operation (menu-bar icon becomes active). No coaching session starts until the user opens a call app.
  - **App icons are placeholder line-glyphs** (generic comm icons) — **the real trademarked app icons must be swapped in at build.**

---

## Interactions & Behavior (summary)

- **Navigation:** linear forward via each step's CTA. No back button in the product (the prototype's bottom toolbar is a review-only affordance, not part of the design).
- **Step 2 gating:** Continue enabled only when `micGranted && primary && secondary !== primary`.
- **Mic permission:** OS-provided dialog. Grant → toggle ON; one-way during onboarding (revoke directs to System Settings).
- **Language validation:** duplicate primary/secondary → inline coral message + Continue stays disabled.
- **Step 4 animation:** widget repositions every 2 s with an eased glide; WPM drifts within 138–166; monologue timer ticks up ~1/s, looping.
- **Step 5 marquee:** continuous 26 s loop; respects `prefers-reduced-motion`.
- **Motion tokens:** durations `--dur-fast 200ms / --dur-base 350ms / --dur-slow 600ms`; easing `--ease-out cubic-bezier(0,0,0.2,1)`, `--ease-in-out cubic-bezier(0.42,0,0.58,1)`. Entrance fades should keep content visible under reduced-motion / no-JS.

## State Management

| State | Where | Notes |
|---|---|---|
| `hasCompletedOnboarding` | UserDefaults | false until Step 5 completes; gates whether onboarding runs |
| `hasCompletedSetup` | UserDefaults (existing M1.3 flag) | set when Step 5 completes |
| `micGranted` | OS permission state | toggle reflects it; pre-set ON if already granted on re-entry |
| `primary` / `secondary` language | `SettingsStore` | persisted **on change**, not on CTA |
| current step | in-memory (prototype mirrors to `localStorage`) | restart resumes at Step 1 if onboarding incomplete |

**Restart mid-onboarding:** `hasCompletedOnboarding` stays false → flow reopens at Step 1; granted permissions and saved languages persist via OS / `SettingsStore`.

---

## Design Tokens (exact values — from `tokens.css`, mirroring `DesignTokens.swift`)

**Brand / teal**
- `--brand` `#0F6E56` (teal-600, primary) · `--brand-dark` `#085041` (teal-800, hover) · `--brand-light` `#E1F5EE` (teal-50) · `--brand-ink` `#04342C`
- teal-100 `#9FE1CB` · teal-200 `#5DCAA5` · teal-400 `#1D9E75`

**Ideal (widget green)**
- `--ideal-bg-1` `#ACD9C0` · `--ideal-bg-2` `#86C3A5` · `--ideal-ink` `#1F4A3A` · `--ideal-base` `rgb(108,207,160)` · `--ideal-deep` `rgb(31,90,64)`

**Neutrals**
- `--bg` `#FAF8F2` (warm bone) · `--surface` `#FFFFFF` · `--surface-2` `#F5F3EC`
- `--text-primary` `#1F2937` · `--text-secondary` `#5F5E5A` · `--text-tertiary` `#9C9A93`
- `--border` `rgba(15,110,86,0.12)` · `--border-strong` `rgba(15,110,86,0.22)` · hairline `0.5px`

**Radii:** sm 4 · md 8 · lg 12 · xl 16 · 2xl 24 · **3xl 32 (shipping 144 pt widget)** · pill 999. Onboarding modal uses **22 pt**.

**Motion:** ease-in-out `cubic-bezier(0.42,0,0.58,1)` · ease-out `cubic-bezier(0,0,0.2,1)` · dur fast 200 / base 350 / slow 600 ms.

**Type families:**
- **Inter** — UI / body. **Inter Display** — headlines + hero numerals. **JetBrains Mono** — code/docs only (not used in onboarding UI).
- Headlines use Inter Display with tight negative tracking (−0.6 to −1.6px). Body uses Inter, line-height ~1.5–1.65.
- Numerals in the widget are tabular (`font-variant-numeric: tabular-nums`).

**Spacing:** 4 pt grid (`--space-1`=4 … `--space-24`=96).

---

## Key components in the prototype (where to look)

| File | Contains |
|---|---|
| `onboarding-shell.jsx` | Stage scaling, simulated desktop (menu bar, dock), step router, completion state, review toolbar, **spec-note annotations** (great per-step implementation hints) |
| `onboarding-steps.jsx` | The five steps + `ModalSheet`, `ScreenCrop` (drawn menu-bar/desktop crops), app parade |
| `onboarding-ui.jsx` | Reusable primitives: `Mark`, `Lockup`, `Eyebrow`, `ProgressDots`, `PrimaryButton`, `Toggle`, `Dropdown` (custom select w/ "None" + validation), `InlineMessage`, `LOCALES` |
| `widget/Widget.jsx` + `widget/tokens.js` | The **real shipping widget** (the same component the app uses). Props: `wpm`, `idle`, `monologueSeconds`, `onPointerDown`. Lift this, don't rebuild it. |
| `tokens.css` | All design tokens + `@font-face` |

**Eyebrow** renders a short uppercase label preceded by a small em-dash rule: a 18 × 1 px line in `currentColor` (70% opacity) + text (11 pt, weight 600, letter-spacing 0.14em, `--text-tertiary`). Used as "— SET UP", "— MENU BAR", "— THE WIDGET".

**Toggle** — 42 × 26 pon/off switch; track `--brand` when on / `#D8D5CC` when off; 22 pt white knob; eased slide.

---

## Deviations from `ONBOARDING_SPEC.md` (intentional, post-spec design decisions)

1. **Steps 3 & 4 are standard modals, not a full-screen dark overlay.** The spec listed the overlay as "preferred (if feasible without Accessibility)" with a modal fallback. We chose the **modal + drawn-screenshot** approach deliberately: a dimming overlay that draws over the system menu bar pushes toward screen-recording/Accessibility-style permissions, which is poor onboarding UX. The modals show **drawn crops** of the relevant screen regions instead — no extra permissions. This realizes the spec's documented fallback as the primary design.
2. **No custom mic permission dialog.** The spec described an in-flow dialog with Allow / Don't Allow and a deny path. Since macOS provides this as a **system window**, we removed the designed dialog to avoid implying it should be built. The toggle triggers the OS prompt; the prototype represents the granted result directly.
3. **Menu-bar status item is positioned to the LEFT of the system icons** (battery/wifi/clock) in Steps 3, 4, and the completed desktop — matching real macOS third-party menu-bar placement.
4. **Dropdown duplicate-language handling:** selecting the same language in both slots is **allowed** and surfaces the validation message (rather than being blocked), so the documented validation state is reachable.
5. **"Active"** (not "Listening") is the live-state label in the Step 3 menu dropdown.

---

## Files in this bundle

```
design_handoff_onboarding_flow/
├── README.md                 ← this file
├── ONBOARDING_SPEC.md        ← original product spec (authoritative for intent)
├── Locto Onboarding.html     ← run this to view the prototype
├── onboarding-shell.jsx      ← stage, router, desktop, review toolbar, spec notes
├── onboarding-steps.jsx      ← the five steps + ModalSheet + ScreenCrop + app parade
├── onboarding-ui.jsx         ← shared UI primitives
├── tokens.css                ← design tokens + @font-face
├── widget/
│   ├── Widget.jsx            ← the real widget component (props: wpm, idle, monologueSeconds, onPointerDown)
│   └── tokens.js             ← paceColors / monoColors helpers
├── brand/
│   ├── mark.svg              ← ring mark
│   ├── lockup.svg            ← mark + wordmark
│   └── menubar.svg           ← menu-bar template
└── fonts/                    ← Inter, Inter Display, JetBrains Mono (woff2)
```

**Assets:** the ring **mark** and **lockup** are in `brand/`. In the native app, use the existing brand assets / SF-style template image for the menu-bar item. The 10 calling-app icons in Step 5 are **placeholders** — replace with real app icons (respect each app's trademark/icon guidelines).
