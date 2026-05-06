# Phase 1 Autonomy Prompts — Speech Coach v1

> **Purpose:** Pre-structured prompts for Phase 1 (Foundation) modules. Each prompt is self-contained — paste it into a fresh Claude Code session. The agent reads `CLAUDE.md` automatically; the prompt references docs by `@path`.
>
> **Ordering:** M1.1 → M1.2 → M1.4 → M1.3 → M1.5 → M1.6. Each depends on the prior being committed.
>
> **Usage:** Copy one prompt per session. Wait for the agent's Phase 1 plan. Review. Say "Plan approved. Proceed." Agent runs TDD + self-review. Report back.

---

## M1.1 — Xcode project setup (2h)

```markdown
# M1.1: Xcode Project Setup

## Context (read first)
- Project docs: @docs/02_PRODUCT_SPEC.md, @docs/03_ARCHITECTURE.md, @CLAUDE.md
- This module: Create the Xcode project structure with correct entitlements, Info.plist, and code signing configuration.
- Depends on: nothing (first module)
- Failure mode this serves: FM3 (minimal setup) + FM4 (no performance impact — correct entitlements from day 1)
- Stakes: Every future module builds on this. Wrong entitlements or build settings mean rework across the entire project.

## Phase 1 — Plan (DO NOT IMPLEMENT YET)
Read all referenced files. Then produce a plan covering:
1. Xcode project creation: single macOS app target `TalkCoach`, bundle ID `com.talkcoach.app`
2. Build settings: macOS 26.0 deployment target, Swift 6, strict concurrency `complete`, arm64 only, hardened runtime
3. Entitlements file: `com.apple.security.app-sandbox`, `com.apple.security.device.audio-input`, `com.apple.security.network.client`
4. Info.plist: `LSUIElement = true`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `LSApplicationCategoryType = public.app-category.productivity`
5. Source folder structure matching `CLAUDE.md` project layout: `Sources/App/`, `Sources/Core/`, `Sources/Audio/`, `Sources/Speech/`, `Sources/Analyzer/`, `Sources/Storage/`, `Sources/Widget/`, `Sources/Settings/`, `Tests/UnitTests/`, `Tests/IntegrationTests/`, `Resources/FillerDictionaries/`, `Resources/Localizations/`
6. Minimal `TalkCoachApp.swift` that compiles and runs (empty `@main` struct with `MenuBarExtra` placeholder)
7. `os.Logger` extension with subsystem `com.talkcoach.app`

Stop after the plan. Do not write any implementation code in this phase.

## Phase 2 — Implement (only after user approves plan)
1. Create the Xcode project and folder structure.
2. Add entitlements and Info.plist entries.
3. Write the minimal `TalkCoachApp.swift`.
4. Build: `xcodebuild -scheme TalkCoach -destination 'platform=macOS' build`
5. Iterate until build succeeds.

## Phase 3 — Self-review (mandatory before reporting done)
- [ ] Build succeeds on the latest commit
- [ ] Entitlements match `03_ARCHITECTURE.md` §Permissions exactly
- [ ] `LSUIElement = true` in Info.plist
- [ ] Deployment target = macOS 26.0
- [ ] Swift 6 strict concurrency = complete
- [ ] All source folders exist (even if empty with placeholder files)
- [ ] No `print()` in any source file
- [ ] `os.Logger` subsystem = `com.talkcoach.app`

## Acceptance Criteria
- Project builds for macOS 26.0 on Apple Silicon
- App launches as a menu-bar-only app (no Dock icon)
- Folder structure matches CLAUDE.md layout
- Entitlements correct per architecture doc

## Out of Scope
- Any actual functionality (MenuBarExtra content, Settings window, etc.)
- Tests (no logic to test yet)
- SwiftData setup (that's M1.5)
```

---

## M1.2 — App lifecycle + MenuBarExtra skeleton (2h)

```markdown
# M1.2: App Lifecycle + MenuBarExtra Skeleton

## Context (read first)
- Project docs: @docs/02_PRODUCT_SPEC.md §Menu bar, @docs/03_ARCHITECTURE.md §MenuBarUI, @CLAUDE.md
- This module: Wire the `TalkCoachApp` entry point with a `MenuBarExtra` showing 4 items: About, Pause/Resume Coaching, Settings…, Quit.
- Depends on: M1.1 (project builds)
- Failure mode this serves: FM3 (minimal setup — app lifecycle must be clean from first launch)
- Stakes: The menu bar is the user's only persistent UI. If it's wrong, the app feels broken.

## Phase 1 — Plan (DO NOT IMPLEMENT YET)
Read all referenced files. Then produce a plan covering:
1. `TalkCoachApp.swift` — `@main` struct with `MenuBarExtra` using a label (SF Symbol `waveform.badge.mic`) and a menu content view
2. Menu items: "About TalkCoach" (triggers `NSApplication.shared.orderFrontStandardAboutPanel`), "Pause Coaching" / "Resume Coaching" (toggles a `@AppStorage("coachingEnabled")` bool), "Settings…" (placeholder — opens nothing yet, will wire in M1.3), "Quit TalkCoach" (`NSApplication.shared.terminate`)
3. `@AppStorage` for `coachingEnabled` (default `true`)
4. Test plan: at least one test verifying the menu item states (paused vs resumed label)

Stop after the plan.

## Phase 2 — Implement (only after user approves plan)
1. Write failing tests first. Commit: `test(app): add failing tests for MenuBarExtra lifecycle`
2. Implement. Do NOT modify committed tests.
3. Build + test: `xcodebuild -scheme TalkCoach -destination 'platform=macOS' test`
4. Iterate until green.

## Phase 3 — Self-review
- [ ] All tests pass
- [ ] Tests not modified after initial commit
- [ ] Menu bar icon visible when app launches
- [ ] "About TalkCoach" opens standard about panel
- [ ] Pause/Resume toggles correctly
- [ ] "Quit TalkCoach" terminates the app
- [ ] No `print()` — `os.Logger` only
- [ ] No Dock icon (LSUIElement)

## Acceptance Criteria
- App launches with menu bar icon
- Four menu items present with correct labels
- Pause/Resume toggles `coachingEnabled` and updates the menu item label
- About panel opens
- Quit works

## Out of Scope
- Settings window (M1.3)
- FloatingPanel (M2.5)
- Any audio or speech functionality
```

---

## M1.4 — Settings UserDefaults wrapper (1h)

```markdown
# M1.4: Settings UserDefaults Wrapper

## Context (read first)
- Project docs: @docs/03_ARCHITECTURE.md §Settings, @CLAUDE.md
- This module: Create `Sources/Settings/SettingsStore.swift` — a thin wrapper around UserDefaults for all app preferences.
- Depends on: M1.2
- Failure mode this serves: FM3 (sensible defaults for everything)

## Phase 1 — Plan (DO NOT IMPLEMENT YET)
Read the Settings keys in `03_ARCHITECTURE.md` §10. Plan:
1. `SettingsStore` class (or struct with `@AppStorage` bindings) with:
   - `declaredLocales: [String]` (empty until first launch setup)
   - `wpmTargetMin: Int` (default 130), `wpmTargetMax: Int` (default 170)
   - `fillerDict: [String: [String]]` (locale identifier → word list)
   - `widgetPositionByDisplay: [String: CGPoint]`
   - `coachingEnabled: Bool` (default true)
   - `hasCompletedSetup: Bool` (default false)
2. Tests: default values correct, read/write round-trips, edge cases (empty locales array)
3. File path: `Sources/Settings/SettingsStore.swift`, tests in `Tests/UnitTests/Settings/`

Stop after the plan.

## Phase 2 — Implement
1. Write failing tests. Commit: `test(settings): add failing tests for SettingsStore`
2. Implement. Do NOT modify committed tests.
3. `xcodebuild -scheme TalkCoach -destination 'platform=macOS' test`
4. Iterate until green.

## Acceptance Criteria
- All settings keys have documented defaults
- Round-trip read/write works for all types
- `hasCompletedSetup` defaults to `false`
- `declaredLocales` defaults to empty array

## Out of Scope
- Settings UI (M1.3)
- Filler dictionary content (M4.2)
```

---

## M1.3 — Settings window with language picker (4h)

```markdown
# M1.3: Settings Window + Language Picker

## Context (read first)
- Project docs: @docs/02_PRODUCT_SPEC.md §Features > Language handling, §FM3, @docs/03_ARCHITECTURE.md §Settings, @CLAUDE.md
- Design reference: @design/README.md (for general visual quality expectations, NOT for Settings layout — Settings is a standard macOS window, not the floating widget)
- This module: Build the Settings window that auto-opens on first launch. Must include: language picker (~50 locales, max 2 selectable, system locale pre-checked), model download size information, WPM target band placeholder, filler dictionary editor placeholder.
- Depends on: M1.2 (MenuBarExtra "Settings…" item), M1.4 (SettingsStore)
- Failure mode this serves: FM3 (minimal setup — this IS the setup flow)
- Stakes: First-launch experience. If this is confusing or broken, FM3 fails immediately.

## Phase 1 — Plan (DO NOT IMPLEMENT YET)
Read all referenced files. Then produce a plan covering:
1. `SettingsWindow` SwiftUI view hosted in a `Window` scene (or `WindowGroup` with `handlesExternalEvents`)
2. Language picker section:
   - Combined alphabetized list of locale display names
   - Checkmark selection, max 2
   - System locale pre-checked on first launch (when `hasCompletedSetup == false`)
   - Each locale shows backend indicator: "(Apple, ~150 MB)" or "(Parakeet, ~1.2 GB)" — informational, not blocking
   - "Confirm" or implicit save on selection change sets `declaredLocales` and `hasCompletedSetup = true`
3. WPM target band section: placeholder with min/max labels (full slider in M6.2)
4. Filler dictionary section: placeholder per declared language (full editor in M4.3)
5. Auto-open on first launch: check `hasCompletedSetup` in app startup; if false, open Settings window
6. "Settings…" menu item wires to open this window
7. Tests: first-launch auto-open behavior, locale selection logic (max 2 enforcement), system locale pre-check

Stop after the plan.

## Phase 2 — Implement
1. Write failing tests. Commit: `test(settings): add failing tests for Settings window`
2. Implement. Do NOT modify committed tests.
3. Build + test.
4. Iterate until green.
5. **Launch the app and visually verify** the first-launch flow: app opens → Settings window appears → language picker shows locales → select 1-2 → close Settings → relaunch → Settings does NOT auto-open.

## Phase 3 — Self-review
- [ ] All tests pass
- [ ] Settings auto-opens on first launch
- [ ] Settings does NOT auto-open after setup is completed
- [ ] Language picker shows ~50 locales alphabetically
- [ ] System locale is pre-checked on first launch
- [ ] Max 2 languages selectable
- [ ] Download size shown per locale
- [ ] "Settings…" menu item opens the window
- [ ] `hasCompletedSetup` set to `true` after confirming languages

## Acceptance Criteria
- First launch: Settings window opens automatically with language picker
- User can select 1-2 languages from ~50 options
- System locale pre-checked
- Subsequent launches: Settings does not auto-open
- "Settings…" in menu bar opens the window on demand

## Out of Scope
- Actual model downloads (M3.6)
- Full filler dictionary editor (M4.3)
- Full WPM slider (M6.2)
- Any audio/speech functionality

## Debugging hints
- Locale list: use `Locale.availableIdentifiers` filtered to the union of Apple + Parakeet supported sets. For now, hardcode the list — the runtime check against `SpeechTranscriber.supportedLocales` comes in M3.4.
- `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` or SwiftUI `openWindow` environment action to programmatically open Settings.
```

---

## M1.5 — SwiftData Session schema + SessionStore (3h)

```markdown
# M1.5: SwiftData Session Schema + SessionStore

## Context (read first)
- Project docs: @docs/02_PRODUCT_SPEC.md §Session storage, @docs/03_ARCHITECTURE.md §SessionStore, @CLAUDE.md
- This module: Define the SwiftData `Session` model matching the product spec schema, and a `SessionStore` service for CRUD operations.
- Depends on: M1.1
- Failure mode this serves: FM2 (unreliable data — schema must be correct from day 1 to avoid migrations later)

## Phase 1 — Plan (DO NOT IMPLEMENT YET)
Read the Session schema in `02_PRODUCT_SPEC.md`. Plan:
1. `Sources/Storage/Session.swift` — `@Model` class with all fields from the spec schema
2. `Sources/Storage/SessionStore.swift` — actor or class with methods: `save(session:)`, `fetchAll()`, `fetchByDateRange(from:to:)`. Uses `ModelContainer` with single store in `~/Library/Application Support/TalkCoach/`.
3. Schema versioning from day 1 (even though v1 has one schema version)
4. Tests: save + fetch round-trip, date range query, empty store

Stop after the plan.

## Phase 2 — Implement
1. Write failing tests. Commit: `test(storage): add failing tests for Session schema`
2. Implement. Do NOT modify committed tests.
3. Build + test.

## Acceptance Criteria
- `Session` model matches spec schema exactly (all fields, correct types)
- Save + fetch round-trip works
- Schema is versioned
- Store location is `~/Library/Application Support/TalkCoach/`

## Out of Scope
- Populating sessions with real data (Phase 2+)
- StatsWindow queries (deferred to v2)
```

---

## M1.6 — Permission request flow (2h)

```markdown
# M1.6: Permission Request Flow

## Context (read first)
- Project docs: @docs/03_ARCHITECTURE.md §Permissions, @CLAUDE.md
- This module: Implement point-of-use permission requests for microphone and speech recognition. Permissions are requested when the user's first session would start, not pre-emptively at launch.
- Depends on: M1.2
- Failure mode this serves: FM3 (minimal setup — permissions are the second user action after language selection)

## Phase 1 — Plan (DO NOT IMPLEMENT YET)
1. `Sources/Core/PermissionManager.swift` — checks and requests mic + speech recognition authorization
2. Flow: check `AVCaptureDevice.authorizationStatus(for: .audio)` and `SFSpeechRecognizer.authorizationStatus()`. If both `.authorized`, return success. If `.notDetermined`, request in order (mic first, speech second). If `.denied` or `.restricted`, surface a one-time notification pointing to System Settings → Privacy.
3. Called by `SessionCoordinator` (M2.3) before starting a session — but for now, called by a placeholder in `TalkCoachApp` lifecycle.
4. Tests: mock authorization states, verify request ordering, verify denied handling

Stop after the plan.

## Phase 2 — Implement
1. Write failing tests. Commit: `test(core): add failing tests for PermissionManager`
2. Implement. Do NOT modify committed tests.
3. Build + test.

## Acceptance Criteria
- Mic permission requested before speech permission
- Both permissions checked before any audio work begins
- Denied state produces a user-visible notification (not a crash, not silent failure)
- No permissions requested until actually needed (point-of-use)

## Out of Scope
- Actually starting audio capture (M3.1)
- SessionCoordinator integration (M2.3)

## Debugging hints
- On macOS, `AVCaptureDevice.requestAccess(for: .audio)` triggers the system permission dialog. In tests, mock the authorization status rather than triggering real dialogs.
- `SFSpeechRecognizer.requestAuthorization` is the legacy API but still gates `SpeechAnalyzer` usage on macOS 26. Verify this against current Apple docs — the new `SpeechAnalyzer` may have its own authorization check.
```

---

## Prompt delivery notes

- Each prompt above is a complete, self-contained Claude Code session input.
- The agent reads `CLAUDE.md` automatically — no need to paste it.
- `@docs/...` and `@design/...` paths tell the agent to read those files.
- After the plan phase, review the agent's plan. If it looks right, say: **"Plan approved. Proceed with Phase 2 (implement) and Phase 3 (self-review)."**
- If the plan has issues, provide specific corrections and ask for a revised plan (still no implementation).
- Each module should complete in one agent session. If the two-strike rule fires, start a fresh session with the same prompt.
