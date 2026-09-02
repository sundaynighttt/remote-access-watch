#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
version="$(/bin/cat "$repo_root/VERSION")"
product_name="RemoteAccessWatch-$version"
dist_root="$repo_root/dist"
package_root="$dist_root/$product_name"
archive_path="$dist_root/$product_name.zip"
checksum_path="$archive_path.sha256"
app_path="$package_root/Remote Access Watch.app"
signing_identity=${REMOTE_ACCESS_WATCH_SIGN_IDENTITY:-}
notary_profile=${REMOTE_ACCESS_WATCH_NOTARY_PROFILE:-}

if [[ -z "$signing_identity" || "$signing_identity" == '-' ]]; then
  echo 'REMOTE_ACCESS_WATCH_SIGN_IDENTITY must name a Developer ID Application identity.' >&2
  exit 2
fi

if [[ -z "$notary_profile" ]]; then
  echo 'REMOTE_ACCESS_WATCH_NOTARY_PROFILE must name a notarytool Keychain profile.' >&2
  exit 2
fi

temp_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/remote-access-watch-notary.XXXXXX")"
trap '/bin/rm -rf -- "$temp_root"' EXIT

require_accepted_submission() {
  local label=$1
  local result_path="$temp_root/$label.json"
  local submission_status
  local submission_id

  xcrun notarytool submit "$archive_path" \
    --keychain-profile "$notary_profile" \
    --wait \
    --output-format json > "$result_path"

  submission_status="$(/usr/bin/plutil -extract status raw -o - "$result_path")"
  submission_id="$(/usr/bin/plutil -extract id raw -o - "$result_path")"
  if [[ "$submission_status" != 'Accepted' ]]; then
    echo "notarization $label failed: status=$submission_status id=$submission_id" >&2
    exit 1
  fi

  echo "notarization $label accepted: id=$submission_id"
}

REMOTE_ACCESS_WATCH_SIGN_IDENTITY="$signing_identity" \
  "$repo_root/scripts/package-release.sh" >/dev/null

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
require_accepted_submission initial

xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

(
  cd "$package_root"
  /usr/bin/find . -type f ! -name SHA256SUMS -print0 \
    | /usr/bin/sort -z \
    | /usr/bin/xargs -0 /usr/bin/shasum -a 256 > SHA256SUMS
)

/bin/rm "$archive_path"
/usr/bin/ditto -c -k --keepParent "$package_root" "$archive_path"
/usr/bin/unzip -tqq "$archive_path"

extract_root="$temp_root/extracted"
/bin/mkdir -p "$extract_root"
/usr/bin/ditto -x -k "$archive_path" "$extract_root"
extracted_package="$extract_root/$product_name"
extracted_app="$extracted_package/Remote Access Watch.app"

(
  cd "$extracted_package"
  /usr/bin/shasum -a 256 -c SHA256SUMS
)
/usr/bin/codesign --verify --deep --strict --verbose=2 "$extracted_app"
xcrun stapler validate "$extracted_app"
/usr/sbin/spctl --assess --type execute --verbose=3 "$extracted_app"

require_accepted_submission final

(
  cd "$dist_root"
  /usr/bin/shasum -a 256 "$product_name.zip" > "$product_name.zip.sha256"
  /usr/bin/shasum -a 256 -c "$product_name.zip.sha256"
)

echo "$archive_path"
echo "$checksum_path"
