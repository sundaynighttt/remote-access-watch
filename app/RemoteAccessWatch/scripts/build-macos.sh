#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
macos_dir=${script_dir:h}
app_name='Remote Access Watch'
bundle_dir="$macos_dir/dist/$app_name.app"
contents_dir="$bundle_dir/Contents"
version=${REMOTE_ACCESS_WATCH_VERSION:-0.1.0}
build_number=${REMOTE_ACCESS_WATCH_BUILD_NUMBER:-1}

cd "$macos_dir"
/usr/bin/swift build -c release --arch arm64 --arch x86_64
bin_path="$(/usr/bin/swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

if [[ -e "$bundle_dir" ]]; then
  backup_dir="$macos_dir/dist/$app_name.backup-$(date +%Y%m%d-%H%M%S).app"
  /bin/mv "$bundle_dir" "$backup_dir"
fi

/bin/mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
/bin/cp "$bin_path/RemoteAccessWatch" "$contents_dir/MacOS/RemoteAccessWatch"

/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string 원격접속 지킴이' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string RemoteAccessWatch' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string io.github.sundaynighttt.RemoteAccessWatch' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleInfoDictionaryVersion string 6.0' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string RemoteAccessWatch' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build_number" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 13.0' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$contents_dir/Info.plist"
signing_identity=${REMOTE_ACCESS_WATCH_SIGN_IDENTITY:--}
if [[ "$signing_identity" == '-' ]]; then
  /usr/bin/codesign --force --sign - --timestamp=none "$bundle_dir"
else
  /usr/bin/codesign --force --options runtime --timestamp --sign "$signing_identity" "$bundle_dir"
fi

/usr/bin/codesign --verify --deep --strict "$bundle_dir"
archs="$(/usr/bin/lipo -archs "$contents_dir/MacOS/RemoteAccessWatch")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || {
  echo "universal build verification failed: $archs" >&2
  exit 1
}

echo "$bundle_dir"
