#!/bin/bash
# Archives FrameCast, signs it with Developer ID, notarizes it, packages a DMG and
# publishes it as a GitHub Release on this repo.
#
#   scripts/release.sh 1.2.0            full release: sign, notarize, publish
#   scripts/release.sh 1.2.0 --draft    publish as a draft release for review
#   scripts/release.sh 1.2.0 --local    sign and notarize, but don't publish
#   scripts/release.sh --dry-run        unsigned test of the build and packaging steps
#
# Version defaults to MARKETING_VERSION in project.yml. The build number is the commit count.
#
# One-time setup for notarization (stores an app-specific password in your keychain):
#   xcrun notarytool store-credentials "FrameCast-notary" \
#       --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
# Use a different profile name with NOTARY_PROFILE=<name>.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="FrameCast"
SCHEME="FrameCast"
SPEC="project.yml"
NOTARY_PROFILE="${NOTARY_PROFILE:-FrameCast-notary}"

VERSION=""
DRAFT=0; LOCAL=0; DRY=0
for arg in "$@"; do
  case "$arg" in
    --draft)   DRAFT=1 ;;
    --local)   LOCAL=1 ;;
    --dry-run) DRY=1; LOCAL=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        echo "Unknown option: $arg" >&2; exit 2 ;;
    *)         VERSION="$arg" ;;
  esac
done

spec_value() { sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" "$SPEC" | head -1; }
[[ -n "$VERSION" ]] || VERSION="$(spec_value MARKETING_VERSION)"
TEAM_ID="$(spec_value DEVELOPMENT_TEAM)"
BUILD="$(git rev-list --count HEAD)"
TAG="v$VERSION"

OUT="build/release"
ARCHIVE="$OUT/$APP_NAME.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/$APP_NAME.app"
DMG="$OUT/$APP_NAME-$VERSION.dmg"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { echo "error: $1" >&2; exit 1; }

# ---- Checks: fail early, before a long build ---------------------------------------------
step "Checking"
command -v xcodegen >/dev/null || fail "xcodegen is not installed (brew install xcodegen)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "version '$VERSION' should look like 1.2.0"
if [[ $DRY -eq 0 ]]; then
  [[ -z "$(git status --porcelain)" ]] || fail "commit or stash your changes first, so the release matches a commit"
  security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || fail "no 'Developer ID Application' certificate in your keychain"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "notary profile '$NOTARY_PROFILE' not found; see the setup note at the top of this script"
fi
if [[ $LOCAL -eq 0 ]]; then
  command -v gh >/dev/null || fail "the GitHub CLI (gh) is not installed"
  gh auth status >/dev/null 2>&1 || fail "gh is not signed in (gh auth login)"
  ! gh release view "$TAG" >/dev/null 2>&1 || fail "release $TAG already exists"
  git fetch -q origin
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse @{u})" ]] || fail "push your commits first; the release tag must point at a commit on GitHub"
fi
echo "$APP_NAME $VERSION (build $BUILD)$([[ $DRY -eq 1 ]] && echo ' [dry run, unsigned]')"

# ---- Archive ----------------------------------------------------------------------------
step "Generating the Xcode project"
xcodegen generate --spec "$SPEC" --quiet

step "Archiving"
rm -rf "$OUT"; mkdir -p "$OUT"
SIGN_ARGS=(-allowProvisioningUpdates)
[[ $DRY -eq 1 ]] && SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO)
xcodebuild archive -project "$APP_NAME.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" -destination "generic/platform=macOS" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" "${SIGN_ARGS[@]}" \
  > "$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; fail "archive failed (full log: $OUT/archive.log)"; }

# ---- Export, signed with Developer ID -----------------------------------------------------
if [[ $DRY -eq 1 ]]; then
  mkdir -p "$EXPORT"
  ditto "$ARCHIVE/Products/Applications/$APP_NAME.app" "$APP"
else
  step "Exporting with Developer ID"
  cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates \
    > "$OUT/export.log" 2>&1 || { tail -30 "$OUT/export.log"; fail "export failed (full log: $OUT/export.log)"; }
  codesign --verify --deep --strict "$APP" || fail "the exported app's signature didn't verify"

  step "Notarizing the app"
  ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME.zip"
  xcrun notarytool submit "$OUT/$APP_NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$OUT/$APP_NAME.zip"
fi
[[ -d "$APP" ]] || fail "no app at $APP"

# ---- Package ----------------------------------------------------------------------------
step "Building the disk image"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
cp LICENSE "$STAGE/LICENSE.txt"
# (hdiutil prints a deprecation notice on newer macOS; it still works, so only that line is hidden.)
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" 2> >(grep -v "is deprecated" >&2) >/dev/null
rm -rf "$STAGE"

if [[ $DRY -eq 0 ]]; then
  step "Signing and notarizing the disk image"
  codesign --sign "Developer ID Application" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature "$DMG" || fail "Gatekeeper rejected the disk image"
fi
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "$DMG"
cat "$DMG.sha256"

# ---- Publish ----------------------------------------------------------------------------
if [[ $LOCAL -eq 1 ]]; then
  step "Done (not published)"
  exit 0
fi
step "Publishing $TAG to GitHub Releases"
GH_ARGS=(--title "$APP_NAME $VERSION" --generate-notes --target "$(git rev-parse HEAD)")
[[ $DRAFT -eq 1 ]] && GH_ARGS+=(--draft)
gh release create "$TAG" "$DMG" "$DMG.sha256" "${GH_ARGS[@]}"
step "Done"
gh release view "$TAG" --json url -q .url
