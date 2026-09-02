#!/bin/bash
set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

LABEL="io.github.sundaynighttt.remote-access-watch.watchdog"
APP_PATH="/Applications/Remote Access Watch.app"
STATUS_PATH="/Library/Application Support/RemoteAccessWatch/status.json"
INCIDENT_ROOT="/Library/Application Support/RemoteAccessWatch/incidents"
LOG_ROOT="/Library/Logs/RemoteAccessWatch"

echo "Remote Access Watch 진단"
echo "수집 범위: 제품 버전, launchd 상태, 공개 상태, 파일 개수와 크기 (로그 내용은 수집하지 않음)"

if [[ -e "$APP_PATH/Contents/Info.plist" ]]; then
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo unknown)"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo unknown)"
  archs="$(/usr/bin/file "$APP_PATH/Contents/MacOS/RemoteAccessWatch" 2>/dev/null | /usr/bin/sed 's|^[^:]*: ||')"
  signature="$(/usr/bin/codesign -dv --verbose=1 "$APP_PATH" 2>&1 | /usr/bin/awk -F= '/^Authority=|^Signature=/{print $0}' | /usr/bin/paste -sd ';' -)"
  echo "app: installed version=$version build=$build"
  echo "app_architecture: $archs"
  echo "app_signature: ${signature:-unknown}"
else
  echo "app: not_installed"
fi

job_output="$(/bin/launchctl print "system/$LABEL" 2>/dev/null || true)"
if [[ -n "$job_output" ]]; then
  echo "watchdog: loaded"
  printf '%s\n' "$job_output" | /usr/bin/awk '
    index($0, "\t") == 1 && index(substr($0, 2), "\t") != 1 && $0 ~ /(state|runs|last exit code|pid) =/ {
      sub(/^\t/, "")
      print "watchdog_" $0
    }
  '
else
  echo "watchdog: not_loaded"
fi

if [[ -r "$STATUS_PATH" ]]; then
  /usr/bin/python3 - "$STATUS_PATH" <<'PY'
import json
import sys

try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    print(f"public_status: unreadable ({type(error).__name__})")
else:
    network = value.get("network", {})
    chrome = value.get("chrome_remote_desktop", {})
    recovery = value.get("recovery", {})
    print("public_status: " + json.dumps({
        "schema_version": value.get("schema_version"),
        "engine_version": value.get("engine_version"),
        "updated_at": value.get("updated_at"),
        "overall_status": value.get("overall_status"),
        "mode": value.get("mode"),
        "network_healthy": network.get("healthy"),
        "network_interface": network.get("interface"),
        "wifi_interface": network.get("wifi_interface"),
        "chrome_remote_desktop_running": chrome.get("running"),
        "recovery_incident_kind": recovery.get("incident_kind"),
        "recovery_unresolved": recovery.get("unresolved"),
    }, ensure_ascii=False, sort_keys=True))
PY
else
  echo "public_status: missing"
fi

incident_count="$(/usr/bin/find "$INCIDENT_ROOT" -type f -name '*.json' 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
echo "incident_files: ${incident_count:-0}"
for log in "$LOG_ROOT/watchdog.log" "$LOG_ROOT/watchdog.err.log"; do
  if [[ -e "$log" ]]; then
    size="$(/usr/bin/stat -f %z "$log" 2>/dev/null || echo unknown)"
    echo "log_size: $log $size bytes"
  else
    echo "log_size: $log missing"
  fi
done
