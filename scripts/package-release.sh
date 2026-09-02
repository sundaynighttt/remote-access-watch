#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
version="$(/bin/cat "$repo_root/VERSION")"
product_name="RemoteAccessWatch-$version"
dist_root="$repo_root/dist"
package_root="$dist_root/$product_name"
archive_path="$dist_root/$product_name.zip"
app_source="$repo_root/app/RemoteAccessWatch/dist/Remote Access Watch.app"

REMOTE_ACCESS_WATCH_VERSION="$version" \
  "$repo_root/app/RemoteAccessWatch/scripts/build-macos.sh" >/dev/null

/bin/rm -rf "$package_root" "$archive_path"
/bin/mkdir -p "$package_root/Resources"
/usr/bin/ditto "$app_source" "$package_root/Remote Access Watch.app"
/bin/cp "$repo_root/watchdog/watchdog.py" "$package_root/Resources/watchdog.py"
/bin/cp "$repo_root/config/policy.example.json" "$package_root/Resources/policy.example.json"
/bin/cp "$repo_root/watchdog/io.github.sundaynighttt.remote-access-watch.watchdog.plist.in" "$package_root/Resources/watchdog.plist.in"
/bin/cp "$repo_root/scripts/install.sh" "$package_root/install.sh"
/bin/cp "$repo_root/scripts/uninstall.sh" "$package_root/uninstall.sh"
/bin/cp "$repo_root/scripts/diagnose.sh" "$package_root/diagnose.sh"
/usr/bin/sed "s/__VERSION__/$version/g" "$repo_root/packaging/README.txt" > "$package_root/README.txt"
/bin/cp "$repo_root/LICENSE" "$package_root/LICENSE"
/bin/chmod 0755 "$package_root/install.sh" "$package_root/uninstall.sh" "$package_root/diagnose.sh" "$package_root/Resources/watchdog.py"

(
  cd "$package_root"
  /usr/bin/find . -type f ! -name SHA256SUMS -print0 \
    | /usr/bin/sort -z \
    | /usr/bin/xargs -0 /usr/bin/shasum -a 256 > SHA256SUMS
)
/usr/bin/ditto -c -k --keepParent "$package_root" "$archive_path"
/usr/bin/shasum -a 256 "$archive_path"
echo "$archive_path"
