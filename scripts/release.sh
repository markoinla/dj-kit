#!/usr/bin/env bash
# Build, sign, notarize and package DJ Kit as a DMG, sign it for Sparkle, update
# appcast.xml and (with --publish) put both on a GitHub release. See RELEASING.md.
#
#   scripts/release.sh [--dry-run] [--publish] [--notes FILE] <version>
#
#   <version>    Marketing version, e.g. 0.2.0. If it differs from project.yml,
#                MARKETING_VERSION is set to it and CURRENT_PROJECT_VERSION
#                (Sparkle's build number) goes up by one. Re-running the same
#                version keeps the build number, so a failed run can be retried.
#   --dry-run    No credentials needed: unsigned archive, DMG and appcast with a
#                fake signature. Checks the pipeline, not the release.
#   --publish    Commit project.yml, tag v<version>, push, and create the GitHub
#                release with the DMGs and appcast.xml (marked latest, which is
#                what the feed URL follows).
#   --notes F    Release notes (Markdown) for the GitHub release and the appcast.
#                Without it, GitHub generates notes from the commits.
#
# Credentials (checked up front; all missing ones are listed together):
#   Signing   "Developer ID Application" identity for team M44R9APYMG in the keychain.
#   Notary    NOTARY_KEYCHAIN_PROFILE (default djkit-notary, from
#             `xcrun notarytool store-credentials`), or NOTARY_KEY_PATH +
#             NOTARY_KEY_ID + NOTARY_ISSUER_ID (App Store Connect API key).
#   Sparkle   SPARKLE_PRIVATE_KEY_FILE, or the key `generate_keys --account djkit`
#             stored in the login keychain.
#   Publish   gh logged in with push access to the repo.
#
# Outputs land in app/build/release/: DJ-Kit-<version>.dmg, DJ-Kit.dmg (the same
# image under a stable name for .../releases/latest/download/DJ-Kit.dmg), appcast.xml.

set -euo pipefail

TEAM_ID="M44R9APYMG"
REPO="markoinla/dj-kit"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
SPARKLE_ACCOUNT="djkit"
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
DMGBUILD_VERSION="1.6.7"  # run through uvx (brew install uv)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_DIR/app"
PROJECT_YML="$APP_DIR/project.yml"
BUILD_DIR="$APP_DIR/build"
PACKAGES_DIR="$BUILD_DIR/SourcePackages"
OUT_DIR="$BUILD_DIR/release"
SPARKLE_BIN="$PACKAGES_DIR/artifacts/sparkle/Sparkle/bin"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

DRY_RUN=0
PUBLISH=0
NOTES_FILE=""
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --publish) PUBLISH=1 ;;
    --notes) shift; NOTES_FILE="${1:-}"; [[ -f "$NOTES_FILE" ]] || die "--notes: no such file '$NOTES_FILE'" ;;
    -h|--help) usage 0 ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z "$VERSION" ]] || die "more than one version given"; VERSION="$1" ;;
  esac
  shift
done
[[ -n "$VERSION" ]] || usage 1
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "version must look like 1.2 or 1.2.3, got '$VERSION'"
[[ $DRY_RUN -eq 1 && $PUBLISH -eq 1 ]] && die "--dry-run and --publish can't be combined"
TAG="v$VERSION"

# --- Version -----------------------------------------------------------------

yml_value() { sed -nE "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$PROJECT_YML" | head -n1; }
set_yml_value() { sed -i '' -E "s/^([[:space:]]*$1:[[:space:]]*).*/\1\"$2\"/" "$PROJECT_YML"; }

CURRENT_VERSION="$(yml_value MARKETING_VERSION)"
CURRENT_BUILD="$(yml_value CURRENT_PROJECT_VERSION)"
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || die "CURRENT_PROJECT_VERSION in project.yml isn't an integer: '$CURRENT_BUILD'"

if [[ "$VERSION" == "$CURRENT_VERSION" ]]; then
  BUILD="$CURRENT_BUILD"
else
  BUILD=$((CURRENT_BUILD + 1))
fi

step "DJ Kit $VERSION (build $BUILD)"
if [[ $DRY_RUN -eq 1 ]]; then
  note "dry run: project.yml is left alone"
elif [[ "$VERSION" != "$CURRENT_VERSION" ]]; then
  set_yml_value MARKETING_VERSION "$VERSION"
  set_yml_value CURRENT_PROJECT_VERSION "$BUILD"
  note "project.yml: $CURRENT_VERSION ($CURRENT_BUILD) → $VERSION ($BUILD)"
fi

# --- Preflight ---------------------------------------------------------------

step "Preflight"
missing=()
for tool in xcodegen xcodebuild hdiutil ditto codesign python3 curl uvx xmllint; do
  command -v "$tool" >/dev/null || missing+=("'$tool' not found on PATH")
done

[[ -n "$(yml_value SUPublicEDKey)" ]] || missing+=("SUPublicEDKey missing from project.yml")

if ! security find-identity -v -p codesigning 2>/dev/null | grep -F "$SIGN_IDENTITY" | grep -qF "($TEAM_ID)"; then
  missing+=("no '$SIGN_IDENTITY' signing identity for team $TEAM_ID in the keychain")
fi

NOTARY_ARGS=()
if [[ -n "${NOTARY_KEY_PATH:-}${NOTARY_KEY_ID:-}${NOTARY_ISSUER_ID:-}" ]]; then
  if [[ -z "${NOTARY_KEY_PATH:-}" || -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" ]]; then
    missing+=("NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID must all be set")
  else
    NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  fi
else
  NOTARY_ARGS=(--keychain-profile "${NOTARY_KEYCHAIN_PROFILE:-djkit-notary}")
  if [[ $DRY_RUN -eq 0 ]] && ! xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null 2>&1; then
    missing+=("notary keychain profile '${NOTARY_KEYCHAIN_PROFILE:-djkit-notary}' doesn't work (RELEASING.md → One-time setup)")
  fi
fi

if [[ $PUBLISH -eq 1 ]]; then
  command -v gh >/dev/null || missing+=("'gh' not found on PATH")
  gh auth status >/dev/null 2>&1 || missing+=("gh isn't logged in")
  gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && missing+=("release $TAG already exists on GitHub")
  [[ "$(git -C "$REPO_DIR" branch --show-current)" == "main" ]] || missing+=("not on main")
  if [[ -n "$(git -C "$REPO_DIR" status --porcelain -- . ':!app/project.yml')" ]]; then
    missing+=("uncommitted changes besides app/project.yml; commit them first")
  fi
fi

if [[ ${#missing[@]} -gt 0 ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    for m in "${missing[@]}"; do note "skipped in dry run: $m"; done
  else
    printf '\033[31merror:\033[0m missing before a release can be built:\n' >&2
    for m in "${missing[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
  fi
else
  note "ok"
fi

# --- Build -------------------------------------------------------------------

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
ARCHIVE="$OUT_DIR/DJKit.xcarchive"
EXPORT_DIR="$OUT_DIR/export"

step "Generate project"
(cd "$APP_DIR" && xcodegen generate --quiet)

step "Archive (Release)"
archive_args=(
  archive
  -project "$APP_DIR/DJKit.xcodeproj"
  -scheme DJKit
  -configuration Release
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE"
  -derivedDataPath "$BUILD_DIR/release-derived"
  -clonedSourcePackagesDirPath "$PACKAGES_DIR"
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD"
  # Apple Silicon only (MLX). On the command line so the packages get it too;
  # a generic destination otherwise builds them universal.
  ARCHS=arm64
  EXCLUDED_ARCHS=x86_64
)
if [[ $DRY_RUN -eq 1 ]]; then
  archive_args+=(CODE_SIGNING_ALLOWED=NO)
else
  archive_args+=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID")
fi
xcodebuild "${archive_args[@]}" -quiet

step "Export (Developer ID)"
if [[ $DRY_RUN -eq 1 ]]; then
  mkdir -p "$EXPORT_DIR"
  ditto "$ARCHIVE/Products/Applications/DJKit.app" "$EXPORT_DIR/DJKit.app"
  note "dry run: copied the unsigned app out of the archive"
else
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$APP_DIR/ExportOptions.plist" -quiet
fi
[[ -d "$EXPORT_DIR/DJKit.app" ]] || die "export didn't produce DJKit.app"
# The target is DJKit; installs get "DJ Kit.app". The signature doesn't cover
# the bundle's folder name, and Sparkle updates an install in place.
APP="$OUT_DIR/DJ Kit.app"
mv "$EXPORT_DIR/DJKit.app" "$APP"

built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
built_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ "$built_version" == "$VERSION" && "$built_build" == "$BUILD" ]] \
  || die "built app is $built_version ($built_build), expected $VERSION ($BUILD)"

# notarize <file>: submit, wait, fail with the log unless Accepted.
notarize() {
  local file="$1" result status id
  result="$OUT_DIR/notary-$(basename "$file").json"
  xcrun notarytool submit "$file" "${NOTARY_ARGS[@]}" --wait --output-format json >"$result" \
    || die "notarytool submit failed for $(basename "$file"): $(cat "$result")"
  status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
  id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" >&2 || true
    die "notarization of $(basename "$file") ended as '${status:-unknown}' (submission ${id:-?})"
  fi
  note "$(basename "$file"): Accepted ($id)"
}

if [[ $DRY_RUN -eq 0 ]]; then
  step "Verify signature"
  codesign --verify --deep --strict --verbose=2 "$APP"
  # Captured first: `codesign | grep -q` trips pipefail when grep exits early (SIGPIPE).
  signature="$(codesign -d --verbose=2 "$APP" 2>&1)"
  [[ "$signature" == *"TeamIdentifier=$TEAM_ID"* ]] || die "app isn't signed by team $TEAM_ID"
  [[ "$signature" == *"flags=0x10000(runtime)"* ]] || die "app isn't signed with the hardened runtime"

  step "Notarize app"
  ditto -c -k --keepParent "$APP" "$OUT_DIR/DJKit.zip"
  notarize "$OUT_DIR/DJKit.zip"
  xcrun stapler staple "$APP"
  rm -f "$OUT_DIR/DJKit.zip"
fi

# --- DMG ---------------------------------------------------------------------

step "DMG"
DMG_NAME="DJ-Kit-$VERSION.dmg"
DMG="$OUT_DIR/$DMG_NAME"
uvx --from "dmgbuild==$DMGBUILD_VERSION" dmgbuild -s "$REPO_DIR/scripts/dmg/settings.py" \
  -D app="$APP" "DJ Kit" "$DMG"

if [[ $DRY_RUN -eq 0 ]]; then
  codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  step "Notarize DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
cp "$DMG" "$OUT_DIR/DJ-Kit.dmg"

# --- Sparkle -----------------------------------------------------------------

step "Sparkle signature"
if [[ $DRY_RUN -eq 1 ]]; then
  SIGNATURE="sparkle:edSignature=\"DRY-RUN\" length=\"$(stat -f%z "$DMG")\""
  note "dry run: fake signature"
else
  [[ -x "$SPARKLE_BIN/sign_update" ]] || die "sign_update not found at $SPARKLE_BIN (Sparkle package didn't resolve?)"
  if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    sign_args=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
  else
    sign_args=(--account "$SPARKLE_ACCOUNT")
  fi
  SIGNATURE="$("$SPARKLE_BIN/sign_update" "${sign_args[@]}" "$DMG")" \
    || die "sign_update failed — is the Sparkle key in the keychain (account $SPARKLE_ACCOUNT) or SPARKLE_PRIVATE_KEY_FILE set?"
  [[ "$SIGNATURE" == *edSignature=* ]] || die "unexpected sign_update output: $SIGNATURE"
fi
note "$SIGNATURE"

step "Appcast"
APPCAST="$OUT_DIR/appcast.xml"
# Start from the live feed so earlier releases stay listed.
if curl -fsSL "$FEED_URL" -o "$APPCAST" 2>/dev/null; then
  note "updating the live feed from $FEED_URL"
else
  rm -f "$APPCAST"
  note "no live feed yet — starting a new one"
fi
MIN_OS="$(yml_value MACOSX_DEPLOYMENT_TARGET)"
DMG_URL="https://github.com/$REPO/releases/download/$TAG/$DMG_NAME"
python3 - "$APPCAST" "$VERSION" "$BUILD" "$MIN_OS" "$DMG_URL" "$SIGNATURE" "$NOTES_FILE" "$REPO" <<'PY'
import email.utils, html, os, re, sys

path, version, build, min_os, url, signature, notes_file, repo = sys.argv[1:9]

head = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>DJ Kit</title>
    <link>https://github.com/{repo}/releases</link>
    <description>DJ Kit updates</description>
    <language>en</language>
  </channel>
</rss>
"""
doc = open(path).read() if os.path.exists(path) else head
if "<channel>" not in doc:
    sys.exit("existing appcast has no <channel>")

# Sparkle shows the notes in its update window; the full text is on GitHub.
notes = f"\n      <sparkle:fullReleaseNotesLink>https://github.com/{repo}/releases/tag/v{html.escape(version)}</sparkle:fullReleaseNotesLink>"
if notes_file:
    notes += "\n      <description sparkle:format=\"markdown\"><![CDATA[" + open(notes_file).read().strip() + "]]></description>"

item = f"""    <item>
      <title>DJ Kit {html.escape(version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(min_os)}</sparkle:minimumSystemVersion>{notes}
      <enclosure url="{html.escape(url)}" type="application/octet-stream" {signature} />
    </item>
"""

# Re-running a release replaces its item instead of duplicating it.
doc = re.sub(
    r"[ \t]*<item>(?:(?!</item>).)*<sparkle:version>" + re.escape(build) + r"</sparkle:version>.*?</item>\n?",
    "",
    doc,
    flags=re.S,
)
# Newest first: before the first existing item, else before </channel>.
m = re.search(r"[ \t]*<item>", doc)
pos = m.start() if m else doc.index("  </channel>") if "  </channel>" in doc else doc.index("</channel>")
doc = doc[:pos] + item + doc[pos:]
open(path, "w").write(doc)
PY
xmllint --noout "$APPCAST" || die "appcast.xml isn't well-formed"
note "$APPCAST"

# --- Publish -----------------------------------------------------------------

if [[ $PUBLISH -eq 1 ]]; then
  step "Publish $TAG"
  cd "$REPO_DIR"
  if [[ -n "$(git status --porcelain -- app/project.yml)" ]]; then
    git commit -q -m "Release $VERSION" -- app/project.yml
  fi
  git tag -a "$TAG" -m "DJ Kit $VERSION"
  git push -q origin main "$TAG"
  notes_args=(--generate-notes)
  [[ -n "$NOTES_FILE" ]] && notes_args=(--notes-file "$NOTES_FILE")
  # DMGs first, feed last, so a client never sees a feed whose DMG is missing.
  gh release create "$TAG" --repo "$REPO" --title "DJ Kit $VERSION" --latest --draft \
    "${notes_args[@]}" "$DMG" "$OUT_DIR/DJ-Kit.dmg"
  gh release upload "$TAG" --repo "$REPO" "$APPCAST"
  gh release edit "$TAG" --repo "$REPO" --draft=false --latest
  note "https://github.com/$REPO/releases/tag/$TAG"
fi

step "Done"
cat <<EOF
    $OUT_DIR/$DMG_NAME
    $OUT_DIR/DJ-Kit.dmg   (stable name: releases/latest/download/DJ-Kit.dmg)
    $OUT_DIR/appcast.xml
EOF
if [[ $DRY_RUN -eq 1 ]]; then
  echo "    Dry run — nothing here is signed or notarized. Don't publish it."
elif [[ $PUBLISH -eq 0 ]]; then
  echo "    Not published. Re-run with --publish, or commit app/project.yml and upload by hand."
fi
