#!/bin/bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

LABEL="io.github.sundaynighttt.remote-access-watch.watchdog"
APP_PATH="/Applications/Remote Access Watch.app"
INSTALL_ROOT="/Library/PrivilegedHelperTools/io.github.sundaynighttt.remote-access-watch"
RUNTIME_ROOT="/Library/Application Support/RemoteAccessWatch"
LOG_ROOT="/Library/Logs/RemoteAccessWatch"
DAEMON_PLIST="/Library/LaunchDaemons/$LABEL.plist"
PURGE_STATE=0

if [[ "${1:-}" == "--purge-state" ]]; then
  PURGE_STATE=1
  shift
fi
if [[ $# -ne 0 ]]; then
  echo "usage: sudo ./uninstall.sh [--purge-state]" >&2
  exit 2
fi
if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
  echo "관리자 권한이 필요합니다: sudo ./uninstall.sh" >&2
  exit 2
fi

/bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
TARGET_USER="$(/usr/bin/stat -f %Su /dev/console)"
if [[ -x "$APP_PATH/Contents/MacOS/RemoteAccessWatch" && "$TARGET_USER" != "root" && "$TARGET_USER" != "loginwindow" ]]; then
  TARGET_UID="$(/usr/bin/id -u "$TARGET_USER")"
  /bin/launchctl asuser "$TARGET_UID" /usr/bin/sudo -u "$TARGET_USER" \
    "$APP_PATH/Contents/MacOS/RemoteAccessWatch" --unregister-login-item-and-quit || true
fi
/usr/bin/pkill -x RemoteAccessWatch >/dev/null 2>&1 || true

/bin/rm -rf "$APP_PATH"
/bin/rm -rf "$INSTALL_ROOT"
/bin/rm -f "$DAEMON_PLIST"

if [[ "$PURGE_STATE" -eq 1 ]]; then
  /bin/rm -rf "$RUNTIME_ROOT" "$LOG_ROOT"
  echo "앱, 감시 엔진, 로컬 상태와 로그를 제거했습니다."
else
  echo "앱과 감시 엔진을 제거했습니다."
  echo "사건 기록과 로그는 보존했습니다: $RUNTIME_ROOT, $LOG_ROOT"
fi
