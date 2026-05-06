# Info.plist & entitlements

Add the following to `Info.plist`:

```xml
<key>LSUIElement</key>
<true/>

<key>LSApplicationCategoryType</key>
<string>public.app-category.productivity</string>

<key>LSMinimumSystemVersion</key>
<string>26.0</string>

<key>NSMicrophoneUsageDescription</key>
<string>Talking Coach listens to your microphone to measure your speaking pace and detect filler words. Audio never leaves this device.</string>

<key>NSSpeechRecognitionUsageDescription</key>
<string>Talking Coach uses on-device speech recognition to count words and identify fillers. Speech is never sent to Apple or anyone else.</string>
```

## App Sandbox entitlements

In `TalkingCoach.entitlements`:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>

<key>com.apple.security.device.audio-input</key>
<true/>

<key>com.apple.security.device.microphone</key>
<true/>
```

## What you do NOT need

- No `com.apple.security.network.client` — the app is fully offline.
- No `com.apple.security.files.user-selected.read-write` — no file access.
- No background app entitlement — running as `LSUIElement` does not require the background mode.

## Build settings

| Setting | Value |
|---|---|
| `MACOSX_DEPLOYMENT_TARGET` | `26.0` |
| `SWIFT_VERSION` | `6.0` |
| `SWIFT_STRICT_CONCURRENCY` | `complete` |
| `CODE_SIGN_ENTITLEMENTS` | `TalkingCoach.entitlements` |
| `ENABLE_HARDENED_RUNTIME` | `YES` |

Architectures: arm64 only. On-device `SpeechTranscriber` performance is calibrated for Apple Silicon.

## Privacy strings — guidance

The strings above are deliberately specific and reassuring:

- They tell the user *what* the data is used for (pace + fillers).
- They tell the user *where* the data goes (this device only).
- They are written in the first person from the app's perspective.

If localization is added in v2, keep the same shape: a one-sentence purpose followed by a one-sentence privacy assurance. Apple's HIG note on privacy strings:
<https://developer.apple.com/design/human-interface-guidelines/privacy>
