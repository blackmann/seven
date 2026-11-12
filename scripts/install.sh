#!/bin/bash
set -euo pipefail

# Build as the current user; request admin access only for installation if needed.
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination_dir="/Applications"
launch_after_install=true
signing_identity="${SEVEN_SIGNING_IDENTITY:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --destination)
            [[ $# -ge 2 && -n "$2" ]] || { echo "--destination requires a folder." >&2; exit 2; }
            destination_dir="$2"; shift 2 ;;
        --no-open) launch_after_install=false; shift ;;
        --signing-identity)
            [[ $# -ge 2 && -n "$2" ]] || { echo "--signing-identity requires a certificate name or SHA-1." >&2; exit 2; }
            signing_identity="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: ./scripts/install.sh [--destination /Applications] [--no-open] [--signing-identity certificate]"
            echo "Build seven in Release mode, install it, and launch it."
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ "$destination_dir" == /* ]] || { echo "The destination must be an absolute folder path." >&2; exit 2; }
command -v xcodebuild >/dev/null || { echo "Install Xcode and select its developer tools first." >&2; exit 1; }
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Apple Development:/ {print $2; exit}')"
fi
[[ -n "$signing_identity" && "$signing_identity" != "-" ]] || {
    echo "An Apple signing identity is required for the embedded SoulverCore framework." >&2
    echo "Create an Apple Development certificate in Xcode, or pass --signing-identity." >&2
    exit 1
}

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/seven-build.XXXXXX")"
staging_dir=""
installed=false
install_as_admin=false
install_file() {
    if [[ "$install_as_admin" == true ]]; then sudo "$@"; else "$@"; fi
}
app_path="$destination_dir/seven.app"
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -n "$staging_dir" ]]; then
        if [[ "$installed" == false && -d "$staging_dir/previous.app" && ! -e "$app_path" ]]; then
            install_file /bin/mv "$staging_dir/previous.app" "$app_path" || true
        fi
        install_file /bin/rm -rf "$staging_dir"
    fi
    /bin/rm -rf "$build_dir"
    exit "$result"
}
trap cleanup EXIT

echo "Building seven…"
xcodebuild -quiet -project "$project_dir/seven.xcodeproj" -scheme seven \
    -configuration Release -destination 'platform=macOS' -derivedDataPath "$build_dir" build
built_app="$build_dir/Build/Products/Release/seven.app"
[[ -d "$built_app" ]] || { echo "The build did not produce seven.app." >&2; exit 1; }
# Hardened Runtime requires a shared Team ID for the app and its embedded
# framework. Sign both with an existing identity; keep library validation on.
/usr/bin/codesign --force --deep --options runtime --timestamp=none --sign "$signing_identity" "$built_app"
/usr/bin/codesign --verify --deep --strict "$built_app"

# Refuse to replace an unrelated app or follow an existing application symlink.
if [[ -e "$app_path" || -L "$app_path" ]]; then
    [[ ! -L "$app_path" ]] || { echo "Refusing to replace a symlink: $app_path" >&2; exit 1; }
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$bundle_id" == "com.blackmann.seven" ]] || { echo "A different app already exists at $app_path." >&2; exit 1; }
fi

if [[ -d "$destination_dir" ]]; then
    [[ -w "$destination_dir" ]] || install_as_admin=true
else
    parent_dir="$(dirname "$destination_dir")"
    [[ -w "$parent_dir" ]] || install_as_admin=true
    install_file /bin/mkdir -p "$destination_dir"
fi
if [[ "$install_as_admin" == true ]]; then
    echo "Administrator access is needed to install into $destination_dir."
    sudo -v
fi
staging_dir="$(install_file /usr/bin/mktemp -d "$destination_dir/.seven-install.XXXXXX")"
install_file /usr/bin/ditto "$built_app" "$staging_dir/seven.app"

if /usr/bin/pgrep -x seven >/dev/null; then
    /usr/bin/osascript -e 'with timeout of 10 seconds' \
        -e 'tell application id "com.blackmann.seven" to quit' -e 'end timeout'
    for attempt in {1..50}; do
        /usr/bin/pgrep -x seven >/dev/null || break
        /bin/sleep 0.1
    done
    if /usr/bin/pgrep -x seven >/dev/null; then
        echo "Quit seven, then run this script again." >&2; exit 1
    fi
fi
if [[ -e "$app_path" ]]; then
    install_file /bin/mv "$app_path" "$staging_dir/previous.app"
fi
install_file /bin/mv "$staging_dir/seven.app" "$app_path"
installed=true
echo "Installed: $app_path"
if [[ "$launch_after_install" == true ]]; then
    /usr/bin/open "$app_path"
fi
