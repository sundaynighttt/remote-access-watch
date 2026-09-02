#!/bin/bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

LABEL="io.github.sundaynighttt.remote-access-watch.watchdog"
APP_NAME="Remote Access Watch.app"
INSTALL_ROOT="/Library/PrivilegedHelperTools/io.github.sundaynighttt.remote-access-watch"
RUNTIME_ROOT="/Library/Application Support/RemoteAccessWatch"
LOG_ROOT="/Library/Logs/RemoteAccessWatch"
POLICY_PATH="$RUNTIME_ROOT/policy.json"
DAEMON_PLIST="/Library/LaunchDaemons/$LABEL.plist"
APP_PATH="/Applications/$APP_NAME"
MODE=""
LOAD_JOB=1
TARGET_USER=""

usage() {
  echo "usage: sudo ./install.sh [--mode observe|active] [--user USER] [--no-load]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --user)
      TARGET_USER="${2:-}"
      shift 2
      ;;
    --no-load)
      LOAD_JOB=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -n "$MODE" && "$MODE" != "observe" && "$MODE" != "active" ]]; then
  usage
  exit 2
fi
if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
  echo "관리자 권한이 필요합니다: sudo ./install.sh" >&2
  exit 2
fi

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
RESOURCES="$PACKAGE_ROOT/Resources"
SOURCE_APP="$PACKAGE_ROOT/$APP_NAME"
SOURCE_WATCHDOG="$RESOURCES/watchdog.py"
SOURCE_POLICY="$RESOURCES/policy.example.json"
SOURCE_PLIST="$RESOURCES/watchdog.plist.in"

for required in "$SOURCE_APP" "$SOURCE_WATCHDOG" "$SOURCE_POLICY" "$SOURCE_PLIST"; do
  if [[ ! -e "$required" ]]; then
    echo "배포 패키지가 불완전합니다: $required" >&2
    exit 1
  fi
done

if [[ -z "$TARGET_USER" ]]; then
  TARGET_USER="$(/usr/bin/stat -f %Su /dev/console)"
fi
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" || "$TARGET_USER" == "loginwindow" ]]; then
  echo "로그인 사용자를 찾지 못했습니다. --user USER를 지정하세요." >&2
  exit 2
fi
TARGET_UID="$(/usr/bin/id -u "$TARGET_USER")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"

/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"

TEMP_ROOT="$(/usr/bin/mktemp -d /private/tmp/remote-access-watch-install.XXXXXX)"
POLICY_TEMP="$TEMP_ROOT/policy.json"
PLIST_TEMP="$TEMP_ROOT/$LABEL.plist"
APP_TEMP="/Applications/.$APP_NAME.new.$$"
cleanup() {
  /bin/rm -rf "$TEMP_ROOT" "$APP_TEMP"
}
trap cleanup EXIT

/usr/bin/python3 - "$SOURCE_POLICY" "$POLICY_PATH" "$POLICY_TEMP" "$MODE" "$TARGET_UID" "$VERSION" <<'PY'
import json
import sys
from pathlib import Path

source_path, installed_path, output_path, requested_mode, uid, version = sys.argv[1:]
policy = json.loads(Path(source_path).read_text(encoding="utf-8"))
installed = Path(installed_path)
if installed.exists():
    try:
        prior = json.loads(installed.read_text(encoding="utf-8"))
        if prior.get("schema_version") == policy.get("schema_version"):
            policy = prior
    except (OSError, json.JSONDecodeError):
        pass
policy["product_version"] = version
policy["mode"] = requested_mode or policy.get("mode", "observe")
policy["chrome_remote_desktop"]["user_uid"] = int(uid)
policy["chrome_remote_desktop"]["launchd_label"] = "org.chromium.chromoting"
policy["recovery"]["full_reboot_enabled"] = False
policy["paths"] = {
    "state": "/Library/Application Support/RemoteAccessWatch/state/state.json",
    "public_status": "/Library/Application Support/RemoteAccessWatch/status.json",
    "outbox": "/Library/Application Support/RemoteAccessWatch/incidents",
}
Path(output_path).write_text(json.dumps(policy, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

/usr/bin/python3 "$SOURCE_WATCHDOG" --policy "$POLICY_TEMP" --validate-only >/dev/null
/usr/bin/sed \
  -e "s|__INSTALL_ROOT__|$INSTALL_ROOT|g" \
  -e "s|__POLICY_PATH__|$POLICY_PATH|g" \
  "$SOURCE_PLIST" > "$PLIST_TEMP"
/usr/bin/plutil -lint "$PLIST_TEMP" >/dev/null

BACKUP_ROOT="$RUNTIME_ROOT/backups/$(/bin/date +%Y%m%d-%H%M%S)-$$"
BACKUP_NEEDED=0
for existing in "$APP_PATH" "$INSTALL_ROOT/watchdog.py" "$POLICY_PATH" "$DAEMON_PLIST"; do
  if [[ -e "$existing" ]]; then
    BACKUP_NEEDED=1
    break
  fi
done
if [[ "$BACKUP_NEEDED" -eq 1 ]]; then
  /usr/bin/install -d -o root -g wheel -m 0700 "$BACKUP_ROOT"
  [[ ! -e "$APP_PATH" ]] || /usr/bin/ditto "$APP_PATH" "$BACKUP_ROOT/$APP_NAME"
  [[ ! -e "$INSTALL_ROOT/watchdog.py" ]] || /usr/bin/ditto "$INSTALL_ROOT/watchdog.py" "$BACKUP_ROOT/watchdog.py"
  [[ ! -e "$POLICY_PATH" ]] || /usr/bin/ditto "$POLICY_PATH" "$BACKUP_ROOT/policy.json"
  [[ ! -e "$DAEMON_PLIST" ]] || /usr/bin/ditto "$DAEMON_PLIST" "$BACKUP_ROOT/$LABEL.plist"
fi

/usr/bin/install -d -o root -g wheel -m 0755 "$INSTALL_ROOT" "$RUNTIME_ROOT" "$RUNTIME_ROOT/incidents" "$LOG_ROOT"
/usr/bin/install -d -o root -g wheel -m 0700 "$RUNTIME_ROOT/state" "$RUNTIME_ROOT/backups"
/usr/bin/install -o root -g wheel -m 0755 "$SOURCE_WATCHDOG" "$INSTALL_ROOT/watchdog.py"
/usr/bin/install -o root -g wheel -m 0600 "$POLICY_TEMP" "$POLICY_PATH"
/usr/bin/install -o root -g wheel -m 0644 "$PLIST_TEMP" "$DAEMON_PLIST"

/usr/bin/pkill -x RemoteAccessWatch >/dev/null 2>&1 || true
/usr/bin/ditto "$SOURCE_APP" "$APP_TEMP"
/usr/sbin/chown -R root:wheel "$APP_TEMP"
if [[ -e "$APP_PATH" ]]; then
  /bin/mv "$APP_PATH" "$BACKUP_ROOT/$APP_NAME.installed"
fi
/bin/mv "$APP_TEMP" "$APP_PATH"

if [[ "$LOAD_JOB" -eq 1 ]]; then
  /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap system "$DAEMON_PLIST"
  /bin/launchctl kickstart -k "system/$LABEL"
  /bin/launchctl asuser "$TARGET_UID" /usr/bin/sudo -u "$TARGET_USER" \
    "$APP_PATH/Contents/MacOS/RemoteAccessWatch" --refresh-login-item-and-quit
  /bin/launchctl asuser "$TARGET_UID" /usr/bin/open -a "$APP_PATH" >/dev/null 2>&1 || true
fi

echo "Remote Access Watch $VERSION 설치 완료"
echo "모드: $(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mode"])' "$POLICY_PATH")"
echo "상태 앱: $APP_PATH"
echo "감시 엔진: system/$LABEL"
if [[ "$BACKUP_NEEDED" -eq 1 ]]; then
  echo "이전 버전 백업: $BACKUP_ROOT"
fi
echo "설치 과정에서는 네트워크 복구 동작을 실행하지 않았습니다."
