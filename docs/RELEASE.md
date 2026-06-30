# Releasing TalkCoach (M6.7 — Developer ID notarized DMG)

This is the **direct-download** distribution path: a signed, notarized `.dmg` a
user double-clicks and drags into `/Applications`. (Mac App Store is a deferred
post-v1 decision; the app is already App-Store-compatible — sandbox + hardened
runtime + no private APIs — so switching later is a packaging change, not an
architecture change.)

Everything here runs on **your Mac** (the build needs `xcodebuild`, `codesign`,
`notarytool`, `hdiutil` — none of which exist in the cloud/Linux dev sessions).

---

## One-time setup

1. **Apple Developer account** (paid, $99/yr) on team `ABHZSV6FGT`.

2. **Developer ID Application certificate** in your login keychain. Xcode →
   Settings → Accounts → Manage Certificates → `+` → *Developer ID Application*.
   Verify:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

   You should see exactly one. (If you have several, pass the exact name to the
   script with `--identity "Developer ID Application: Your Name (ABHZSV6FGT)"`.)

3. **notarytool keychain profile** — store credentials once so the script never
   sees your password. Create an **app-specific password** at
   <https://account.apple.com> → Sign-In and Security → App-Specific Passwords,
   then:

   ```sh
   xcrun notarytool store-credentials talkcoach-notary \
     --apple-id "you@example.com" \
     --team-id  ABHZSV6FGT \
     --password "abcd-efgh-ijkl-mnop"   # the app-specific password
   ```

   (Alternatively use an App Store Connect API key: `--key`, `--key-id`,
   `--issuer`.) The profile name `talkcoach-notary` is the script default.

4. **Rust toolchain** (the Parakeet bridge is built from source):
   <https://rustup.rs>. The script invokes `Vendor/build-parakeet-bridge.sh`.

---

## Cut a release

```sh
./scripts/release.sh --version 1.0 --notary-profile talkcoach-notary
```

What it does, in order:

1. **preflight** — verifies tools, signing identity, and (implicitly, at submit
   time) the notary profile.
2. **build_bridge** — `Vendor/build-parakeet-bridge.sh` → `libparakeet_bridge.a`.
3. **archive** — `xcodebuild archive` (Release, hardened runtime, team `ABHZSV6FGT`).
4. **export** — `xcodebuild -exportArchive` with `scripts/ExportOptions.plist`
   (`method=developer-id`) → `build/export/TalkCoach.app`.
5. **fixup_dylibs** — embeds + signs any non-system dynamic library the executable
   links against (see "ONNX Runtime" below). No-op if ONNX is statically linked.
6. **resign_app** — re-signs the bundle with hardened runtime + entitlements, then
   `codesign --verify --deep --strict`.
7. **notarize app**, **make_dmg**, **notarize dmg**, **staple** both.
8. **verify** — `spctl` Gatekeeper assessment + `stapler validate`.

Final artifact: `build/TalkCoach-1.0.dmg`.

For a quick **local** build with no Apple round-trip (produces an *unnotarized*
DMG — for your machine only, will be Gatekeeper-blocked elsewhere):

```sh
./scripts/release.sh --skip-notarize
```

---

## Success looks like

```
spctl --assess --type install ... build/TalkCoach-1.0.dmg
  → source=Notarized Developer ID, accepted
xcrun stapler validate build/TalkCoach-1.0.dmg
  → The validate action worked!
codesign -dv --verbose=4 TalkCoach.app
  → Authority=Developer ID Application: ...   flags=...(runtime)   Timestamp=...
```

---

## The ONNX Runtime caveat (read this if notarization or launch fails)

`Vendor/parakeet-bridge` links `ort 2.0.0-rc.12` (ONNX Runtime). It is built as a
Rust **staticlib**, but whether ONNX Runtime itself ends up **statically linked**
or as a separate **`libonnxruntime*.dylib`** depends on what `ort-sys` emits — and
the app currently only runs on the build machine (no dylib is bundled).

- If `otool -L build/export/TalkCoach.app/Contents/MacOS/TalkCoach` lists a
  non-system `libonnxruntime*.dylib` (an absolute path under `~/.cargo`, the build
  dir, or `/opt/homebrew`), it is **dynamic**. The `fixup_dylibs` step embeds it
  into `Contents/Frameworks/`, repoints the binary at `@rpath`, and signs it. This
  is required — without it the app fails to launch on any other Mac and
  notarization rejects the unsigned/missing dylib.
- If `otool -L` shows only `/usr/lib` + `/System` entries, ONNX is static and
  there is nothing to embed.

**Always run the cross-machine check** (Verification step 3 below). The build Mac
hides a broken dynamic-link because the absolute path happens to exist there.

If the app passes notarization but **crashes on launch under hardened runtime**
(e.g. ONNX needs executable memory it can't get), add to
`Sources/App/TalkCoach.entitlements` and re-run:

```xml
<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
<true/>
```

Add it only if you actually hit the crash — it weakens the hardened runtime.

---

## Verification before tagging

1. `./scripts/release.sh` completes; notarytool returns `status: Accepted`.
2. `spctl --assess --type install build/TalkCoach-1.0.dmg` → accepted, Notarized.
3. **Cross-machine smoke:** mount the DMG on a *second* Mac (or a clean user
   account), drag to Applications, place the Parakeet/Silero models manually (until
   M3.7.5 in-app download lands), launch, start a session → menu bar appears and
   the widget shows a live WPM number. This is the step that catches a broken
   dynamic ONNX link.
4. `codesign -dv --verbose=4 TalkCoach.app` shows the `runtime` flag, the
   `Developer ID Application` authority, and a secure `Timestamp`.

Then, per project convention, after your manual smoke gate:

```sh
xcodebuild -scheme TalkCoach -destination 'platform=macOS' test   # expect green
git tag -a m6.7-complete -m "M6.7: notarized Developer ID DMG"
```

---

## Known follow-ups (not blocking the DMG)

- **M3.7.5** (in-app model download) is still unbuilt — the DMG is installable but
  the models must be placed manually until then, so it is not yet end-user-ready.
- **B3** (optional): auto-build the Rust bridge from an Xcode Run-Script phase so
  plain `⌘B` in Xcode can't link a stale `.a`. The release script already builds it
  before archiving, so this is convenience only.
