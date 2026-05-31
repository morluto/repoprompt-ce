#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-preflight}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

set -a
source "$ROOT_DIR/version.env"
set +a

DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$ROOT_DIR/.build/release/$APP_NAME.app"
ARCHIVE_BASENAME="${APP_NAME}-${MARKETING_VERSION}-${BUILD_NUMBER}"
UPDATE_ZIP="$DIST_DIR/$ARCHIVE_BASENAME.zip"
DMG="$DIST_DIR/$ARCHIVE_BASENAME.dmg"
APPCAST="$DIST_DIR/appcast.xml"
CHECKSUMS="$DIST_DIR/SHA256SUMS"
RELEASE_TAG="${RELEASE_TAG:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-repoprompt/repoprompt-ce}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/$GITHUB_REPOSITORY/releases/download/$RELEASE_TAG}"
EXPECTED_FEED_URL="https://github.com/repoprompt/repoprompt-ce-updates/releases/latest/download/appcast.xml"
SPARKLE_FRAMEWORK_INFO="$ROOT_DIR/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Resources/Info.plist"
TMP_DIR=""

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_file() {
    [[ -f "$1" ]] || fail "Missing required file: $1"
}

require_env() {
    [[ -n "${!1:-}" ]] || fail "Missing required environment variable: $1"
}

cleanup() {
    [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

prepare_dist() {
    [[ "$DIST_DIR" != "/" ]] || fail "DIST_DIR must not be /"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
}

run_preflight() {
    require_command plutil
    require_file "$ROOT_DIR/AppBundle/Info.plist.template"
    require_file "$ROOT_DIR/AppBundle/RepoPrompt.entitlements.template"
    require_file "$ROOT_DIR/Vendor/Sparkle/LICENSE"
    require_file "$ROOT_DIR/Vendor/Sparkle/PROVENANCE.md"
    require_file "$ROOT_DIR/Vendor/Sparkle/SHA256SUMS"
    require_file "$ROOT_DIR/Vendor/Sparkle/bin/generate_appcast"
    require_file "$SPARKLE_FRAMEWORK_INFO"

    local sparkle_version feed_url
    sparkle_version="$(plutil -extract CFBundleShortVersionString raw "$SPARKLE_FRAMEWORK_INFO")"
    feed_url="$(plutil -extract SUFeedURL raw "$ROOT_DIR/AppBundle/Info.plist.template")"
    [[ "$sparkle_version" == "2.9.2" ]] || fail "Expected vendored Sparkle 2.9.2, got $sparkle_version"
    [[ "$feed_url" == "$EXPECTED_FEED_URL" ]] || fail "Expected CE Sparkle feed $EXPECTED_FEED_URL, got $feed_url"

    printf 'OK: release preflight passed for %s %s (%s) with Sparkle %s.\n' \
        "$DISPLAY_NAME" "$MARKETING_VERSION" "$BUILD_NUMBER" "$sparkle_version"
}

package_release_candidate() {
    run_preflight
    require_command ditto
    prepare_dist

    env -u SIGN_IDENTITY RELEASE_ALLOW_ADHOC_SIGNING=1 "$ROOT_DIR/Scripts/package_app.sh" release
    ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$UPDATE_ZIP"
    (
        cd "$DIST_DIR"
        shasum -a 256 "$(basename "$UPDATE_ZIP")" > "$(basename "$CHECKSUMS")"
    )

    printf 'Created ad-hoc release-candidate artifact: %s\n' "$UPDATE_ZIP"
    printf 'This artifact is for packaging validation only. It is not notarized or distributable.\n'
}

verify_publish_inputs() {
    require_env RELEASE_TAG
    require_env SIGN_IDENTITY
    require_env REPOPROMPT_PROVISIONING_PROFILE
    require_env SPARKLE_PRIVATE_KEY
    require_env NOTARYTOOL_PRIVATE_KEY
    require_env NOTARYTOOL_KEY_ID
    require_env NOTARYTOOL_ISSUER_ID
    require_env GH_TOKEN
    require_file "$REPOPROMPT_PROVISIONING_PROFILE"
    require_file "$NOTARYTOOL_PRIVATE_KEY"

    local tag_commit head_commit
    tag_commit="$(git rev-parse "$RELEASE_TAG^{commit}" 2>/dev/null || true)"
    [[ -n "$tag_commit" ]] || fail "Release tag does not exist locally: $RELEASE_TAG"
    head_commit="$(git rev-parse HEAD)"
    [[ "$tag_commit" == "$head_commit" ]] || fail "Release tag $RELEASE_TAG must point at HEAD ($head_commit), got $tag_commit"
}

submit_notarization() {
    xcrun notarytool submit "$1" \
        --key "$NOTARYTOOL_PRIVATE_KEY" \
        --key-id "$NOTARYTOOL_KEY_ID" \
        --issuer "$NOTARYTOOL_ISSUER_ID" \
        --wait \
        --timeout "${NOTARYTOOL_TIMEOUT:-30m}"
}

publish_release() {
    run_preflight
    require_command ditto
    require_command gh
    require_command hdiutil
    require_command xcrun
    verify_publish_inputs
    prepare_dist
    TMP_DIR="$(mktemp -d)"

    "$ROOT_DIR/Scripts/package_app.sh" release

    local notary_zip="$TMP_DIR/$ARCHIVE_BASENAME-notarization.zip"
    ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$notary_zip"
    submit_notarization "$notary_zip"
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"

    ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$UPDATE_ZIP"

    local dmg_staging="$TMP_DIR/dmg"
    mkdir -p "$dmg_staging"
    ditto "$APP_BUNDLE" "$dmg_staging/$APP_NAME.app"
    hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$dmg_staging" -ov -format UDZO "$DMG"
    submit_notarization "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"

    local appcast_dir="$TMP_DIR/appcast"
    mkdir -p "$appcast_dir"
    cp "$UPDATE_ZIP" "$appcast_dir/"
    printf '%s' "$SPARKLE_PRIVATE_KEY" |
        "$ROOT_DIR/Vendor/Sparkle/bin/generate_appcast" \
            --ed-key-file - \
            --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
            -o "$APPCAST" \
            "$appcast_dir"

    (
        cd "$DIST_DIR"
        shasum -a 256 \
            "$(basename "$UPDATE_ZIP")" \
            "$(basename "$DMG")" \
            "$(basename "$APPCAST")" \
            > "$(basename "$CHECKSUMS")"
    )

    local release_args=(
        "$RELEASE_TAG"
        "$UPDATE_ZIP"
        "$DMG"
        "$APPCAST"
        "$CHECKSUMS"
        --verify-tag
        --title "$DISPLAY_NAME $MARKETING_VERSION"
        --generate-notes
        --repo "$GITHUB_REPOSITORY"
    )
    if [[ "${RELEASE_DRAFT:-true}" == "true" ]]; then
        release_args+=(--draft)
    fi
    gh release create "${release_args[@]}"
    printf 'Published GitHub release assets for %s.\n' "$RELEASE_TAG"
}

case "$MODE" in
    preflight) run_preflight ;;
    artifact) package_release_candidate ;;
    publish) publish_release ;;
    *) fail "Usage: $0 preflight|artifact|publish" ;;
esac
