#!/bin/bash
#
# M6.7 — Build, sign (Developer ID), notarize, and package TalkCoach as a DMG.
#
# Runs on macOS only (needs xcodebuild / codesign / notarytool / hdiutil).
# One-time setup and troubleshooting: see docs/RELEASE.md.
#
# Usage:
#   scripts/release.sh [--version 1.0] [--notary-profile talkcoach-notary] \
#                      [--identity "Developer ID Application: ..."] [--skip-notarize]
#
# Output: build/TalkCoach-<version>.dmg  (notarized + stapled)
#
set -euo pipefail

# --- locate repo root (script lives in scripts/) --------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- defaults / args ------------------------------------------------------------
VERSION="1.0"
NOTARY_PROFILE="talkcoach-notary"
IDENTITY=""           # auto-detected if empty
SKIP_NOTARIZE="no"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version)        VERSION="$2"; shift 2 ;;
		--notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
		--identity)       IDENTITY="$2"; shift 2 ;;
		--skip-notarize)  SKIP_NOTARIZE="yes"; shift ;;
		-h|--help)        grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "error: unknown argument '$1' (try --help)" >&2; exit 2 ;;
	esac
done

PROJECT="$REPO_ROOT/TalkCoach.xcodeproj"
SCHEME="TalkCoach"
TEAM_ID="ABHZSV6FGT"
ENTITLEMENTS="$REPO_ROOT/Sources/App/TalkCoach.entitlements"
EXPORT_OPTIONS="$REPO_ROOT/scripts/ExportOptions.plist"
BRIDGE_LIB="$REPO_ROOT/Vendor/parakeet-bridge/target/release/libparakeet_bridge.a"

BUILD_DIR="$REPO_ROOT/build"
ARCHIVE="$BUILD_DIR/TalkCoach.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/TalkCoach.app"
DMG="$BUILD_DIR/TalkCoach-$VERSION.dmg"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 0. preflight ---------------------------------------------------------------
preflight() {
	log "Preflight checks"
	[[ "$(uname)" == "Darwin" ]] || die "release.sh must run on macOS."
	for tool in xcodebuild codesign hdiutil ditto security; do
		command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found on PATH."
	done
	xcrun -f notarytool >/dev/null 2>&1 || die "notarytool not found (need Xcode 13+ command line tools)."
	xcrun -f stapler   >/dev/null 2>&1 || die "stapler not found."

	# cargo (the Rust bridge build script uses ~/.cargo/bin/cargo)
	[[ -x "${HOME}/.cargo/bin/cargo" ]] || command -v cargo >/dev/null 2>&1 \
		|| die "cargo not found — install Rust (https://rustup.rs) to build the Parakeet bridge."

	# Developer ID Application signing identity
	if [[ -z "$IDENTITY" ]]; then
		IDENTITY="$(security find-identity -v -p codesigning \
			| grep "Developer ID Application" | head -1 \
			| sed -E 's/.*"(.+)"$/\1/')"
		[[ -n "$IDENTITY" ]] || die "No 'Developer ID Application' identity in the keychain. See docs/RELEASE.md (one-time setup)."
	fi
	log "Signing identity: $IDENTITY"
	[[ "$SKIP_NOTARIZE" == "yes" ]] && log "Notarization: SKIPPED (--skip-notarize)" \
		|| log "Notarization keychain profile: $NOTARY_PROFILE"
}

# --- 1. build the Rust bridge staticlib ----------------------------------------
build_bridge() {
	log "Building Parakeet Rust bridge (libparakeet_bridge.a)"
	bash "$REPO_ROOT/Vendor/build-parakeet-bridge.sh"
	[[ -f "$BRIDGE_LIB" ]] || die "Expected $BRIDGE_LIB after bridge build."
}

# --- 2. archive -----------------------------------------------------------------
archive() {
	log "Archiving (Release, Developer ID, hardened runtime)"
	rm -rf "$ARCHIVE"
	xcodebuild clean archive \
		-project "$PROJECT" \
		-scheme "$SCHEME" \
		-configuration Release \
		-destination 'generic/platform=macOS' \
		-archivePath "$ARCHIVE" \
		DEVELOPMENT_TEAM="$TEAM_ID" \
		| xcbeautify_or_cat
	[[ -d "$ARCHIVE" ]] || die "Archive not produced at $ARCHIVE."
}

# --- 3. export the signed .app --------------------------------------------------
export_app() {
	log "Exporting signed .app (Developer ID)"
	rm -rf "$EXPORT_DIR"
	xcodebuild -exportArchive \
		-archivePath "$ARCHIVE" \
		-exportOptionsPlist "$EXPORT_OPTIONS" \
		-exportPath "$EXPORT_DIR" \
		| xcbeautify_or_cat
	[[ -d "$APP" ]] || die "Exported app not found at $APP."
}

# --- 4. embed + sign any non-system dynamic libs (handles dynamic ONNX case) ----
#   parakeet-bridge is a staticlib; if ONNX Runtime linked statically, otool shows
#   nothing to embed and this is a no-op. If ort pulled a dynamic libonnxruntime,
#   the dev machine resolves it via an absolute build path that does NOT exist on
#   other Macs and is unsigned — Gatekeeper/notarization would reject it. We catch
#   that here by embedding the dylib into Contents/Frameworks, repointing the
#   executable at @rpath, and signing the dylib (sign inside-out).
fixup_dylibs() {
	log "Scanning for non-system dynamic libraries to embed"
	local exe="$APP/Contents/MacOS/TalkCoach"
	local fw="$APP/Contents/Frameworks"
	[[ -f "$exe" ]] || die "Executable not found at $exe."
	mkdir -p "$fw"

	local embedded=0
	# otool -L: skip line 1 (the binary itself); column 1 of each line is the path.
	while IFS= read -r dep; do
		case "$dep" in
			/usr/lib/*|/System/*) continue ;;                 # OS libs — leave alone
			@rpath/*|@executable_path/*|@loader_path/*) continue ;;  # already bundle-relative
			"") continue ;;
		esac
		[[ -f "$dep" ]] || die "Executable depends on '$dep' which does not exist — cannot embed. Investigate manually."
		local base; base="$(basename "$dep")"
		log "  embedding $base  (from $dep)"
		cp -f "$dep" "$fw/$base"
		chmod u+w "$fw/$base"
		install_name_tool -id "@rpath/$base" "$fw/$base"
		install_name_tool -change "$dep" "@rpath/$base" "$exe"
		codesign --force --options runtime --timestamp -s "$IDENTITY" "$fw/$base"
		embedded=$((embedded+1))
	done < <(otool -L "$exe" | tail -n +2 | awk '{print $1}')

	if [[ "$embedded" -eq 0 ]]; then
		log "No external dylibs found — ONNX Runtime is statically linked. Nothing to embed."
	else
		log "Embedded + signed $embedded dylib(s)."
	fi
}

# --- 5. re-sign the app bundle (seals Frameworks we just modified) --------------
resign_app() {
	log "Re-signing app bundle with hardened runtime + entitlements"
	codesign --force --options runtime --timestamp \
		--entitlements "$ENTITLEMENTS" \
		-s "$IDENTITY" \
		"$APP"
	log "Verifying app signature"
	codesign --verify --deep --strict --verbose=2 "$APP"
}

# --- notarize + staple a path (.app is zipped first; .dmg submitted directly) ---
notarize_path() {
	local path="$1" submit rc out subid
	if [[ "$path" == *.app ]]; then
		submit="${path}.zip"
		rm -f "$submit"
		/usr/bin/ditto -c -k --keepParent "$path" "$submit"
	else
		submit="$path"
	fi

	log "Submitting $(basename "$path") to Apple notary service (this can take minutes)"
	set +e
	out="$(xcrun notarytool submit "$submit" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
	rc=$?
	set -e
	echo "$out"
	[[ "$submit" == *.zip ]] && rm -f "$submit"

	if [[ $rc -ne 0 ]] || ! grep -q "status: Accepted" <<<"$out"; then
		subid="$(grep -m1 '  id:' <<<"$out" | awk '{print $2}')"
		if [[ -n "$subid" ]]; then
			log "Notarization NOT accepted — fetching log for $subid"
			xcrun notarytool log "$subid" --keychain-profile "$NOTARY_PROFILE" || true
		fi
		die "Notarization failed for $(basename "$path")."
	fi

	log "Stapling ticket onto $(basename "$path")"
	xcrun stapler staple "$path"
}

# --- 6. build the DMG (drag-to-Applications) ------------------------------------
make_dmg() {
	log "Building DMG"
	local staging; staging="$(mktemp -d)"
	cp -R "$APP" "$staging/"
	ln -s /Applications "$staging/Applications"
	rm -f "$DMG"
	hdiutil create \
		-volname "TalkCoach" \
		-srcfolder "$staging" \
		-fs HFS+ \
		-format UDZO \
		-ov \
		"$DMG" >/dev/null
	rm -rf "$staging"
	log "Signing DMG"
	codesign --force --timestamp -s "$IDENTITY" "$DMG"
}

# --- 7. final verification ------------------------------------------------------
verify() {
	log "Gatekeeper assessment"
	spctl --assess --type install --verbose=4 "$DMG" || true
	spctl --assess --type exec   --verbose=4 "$APP" || true
	log "Staple validation"
	xcrun stapler validate "$APP"
	xcrun stapler validate "$DMG"
	log "Codesign summary"
	codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'Identifier|Authority|Timestamp|flags|Runtime' || true
}

# pretty-print xcodebuild output if xcbeautify is installed, else pass through
xcbeautify_or_cat() {
	if command -v xcbeautify >/dev/null 2>&1; then xcbeautify; else cat; fi
}

# --- main -----------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
preflight
build_bridge
archive
export_app
fixup_dylibs
resign_app
if [[ "$SKIP_NOTARIZE" == "yes" ]]; then
	log "Skipping notarization; producing UNNOTARIZED DMG for local testing only."
	make_dmg
else
	notarize_path "$APP"     # notarize + staple the app (offline-validatable)
	make_dmg
	notarize_path "$DMG"     # notarize + staple the dmg
	verify
fi

log "Done. Artifact: $DMG"
