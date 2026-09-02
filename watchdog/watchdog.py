#!/usr/bin/python3
"""Root-owned, deterministic macOS network and Chrome Remote Desktop watchdog."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import ipaddress
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple
from urllib.parse import urlparse


SCHEMA = "remote-access-watch-policy-v1"
STATE_SCHEMA = "remote-access-watch-state-v1"
RECEIPT_SCHEMA = "remote-access-watch-incident-v1"
PUBLIC_STATUS_SCHEMA = "remote-access-watch-public-status-v1"
ALLOWED_ENDPOINT_HOSTS = {"www.google.com", "www.cloudflare.com"}
AIRPORTD_PATH = "/usr/libexec/airportd"
FIXED_COMMANDS = {
    "curl": "/usr/bin/curl",
    "ifconfig": "/sbin/ifconfig",
    "launchctl": "/bin/launchctl",
    "networksetup": "/usr/sbin/networksetup",
    "pgrep": "/usr/bin/pgrep",
    "ping": "/sbin/ping",
    "ps": "/bin/ps",
    "route": "/sbin/route",
}


def now_local() -> dt.datetime:
    return dt.datetime.now().astimezone()


def iso(value: dt.datetime) -> str:
    return value.isoformat(timespec="seconds")


def parse_time(value: Optional[str]) -> Optional[dt.datetime]:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value)
    except ValueError:
        return None


def atomic_json_write(path: Path, payload: Dict[str, Any], mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(payload, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def default_state() -> Dict[str, Any]:
    return {
        "schema_version": STATE_SCHEMA,
        "network": {
            "unhealthy_streak": 0,
            "healthy_streak": 0,
            "incident": None,
            "recent_action_times": [],
        },
        "chrome_remote_desktop": {
            "missing_streak": 0,
            "incident": None,
        },
        "last_check_at": None,
    }


def load_state(path: Path) -> Dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default_state()
    if not isinstance(payload, dict) or payload.get("schema_version") != STATE_SCHEMA:
        return default_state()
    baseline = default_state()
    for section in ("network", "chrome_remote_desktop"):
        if isinstance(payload.get(section), dict):
            baseline[section].update(payload[section])
    baseline["last_check_at"] = payload.get("last_check_at")
    return baseline


def _require_int(value: Any, name: str, minimum: int, maximum: int) -> int:
    if not isinstance(value, int) or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be an integer in [{minimum}, {maximum}]")
    return value


def validate_policy(payload: Dict[str, Any]) -> Dict[str, Any]:
    if payload.get("schema_version") != SCHEMA:
        raise ValueError("unsupported policy schema")
    if payload.get("mode") not in {"observe", "active"}:
        raise ValueError("mode must be observe or active")
    if payload.get("poll_seconds") != 60:
        raise ValueError("poll_seconds must match the 60-second launchd interval")
    network = payload.get("network")
    recovery = payload.get("recovery")
    chrome = payload.get("chrome_remote_desktop")
    paths = payload.get("paths")
    if not all(isinstance(item, dict) for item in (network, recovery, chrome, paths)):
        raise ValueError("network, recovery, chrome_remote_desktop, and paths are required")
    iface_re = re.compile(r"^en\d+$")
    interfaces = network.get("managed_interfaces")
    if not isinstance(interfaces, list):
        raise ValueError("managed_interfaces must be a list")
    if any(not isinstance(item, str) or not iface_re.fullmatch(item) for item in interfaces):
        raise ValueError("managed_interfaces contains an invalid interface")
    wifi_interface = network.get("wifi_interface")
    if wifi_interface != "auto" and (not isinstance(wifi_interface, str) or not iface_re.fullmatch(wifi_interface)):
        raise ValueError("wifi_interface must be auto or an en device")
    if interfaces and wifi_interface != "auto" and wifi_interface not in interfaces:
        raise ValueError("wifi_interface must be managed")
    endpoints = network.get("https_endpoints")
    if not isinstance(endpoints, list) or len(endpoints) < 2:
        raise ValueError("at least two HTTPS endpoints are required")
    for endpoint in endpoints:
        parsed = urlparse(str(endpoint))
        if parsed.scheme != "https" or parsed.hostname not in ALLOWED_ENDPOINT_HOSTS:
            raise ValueError("HTTPS endpoint is outside the fixed allowlist")
    _require_int(network.get("minimum_https_successes"), "minimum_https_successes", 1, len(endpoints))
    _require_int(network.get("unhealthy_threshold"), "unhealthy_threshold", 2, 20)
    _require_int(network.get("healthy_threshold"), "healthy_threshold", 1, 10)
    _require_int(network.get("probe_timeout_seconds"), "probe_timeout_seconds", 2, 20)
    _require_int(recovery.get("airportd_max_attempts_per_incident"), "airportd_max_attempts_per_incident", 0, 3)
    _require_int(recovery.get("airportd_minimum_attempt_interval_seconds"), "airportd_minimum_attempt_interval_seconds", 60, 3600)
    _require_int(recovery.get("airportd_max_attempts_per_hour"), "airportd_max_attempts_per_hour", 0, 4)
    if recovery.get("full_reboot_enabled") is not False:
        raise ValueError("full reboot is forbidden in v1")
    _require_int(chrome.get("user_uid"), "user_uid", 1, 2_147_483_647)
    if chrome.get("launchd_label") != "org.chromium.chromoting":
        raise ValueError("Chrome Remote Desktop launchd label is not allowlisted")
    _require_int(chrome.get("missing_threshold"), "missing_threshold", 2, 20)
    _require_int(chrome.get("max_attempts_per_incident"), "max_attempts_per_incident", 0, 2)
    for key in ("state", "public_status", "outbox"):
        value = paths.get(key)
        if not isinstance(value, str) or not value.startswith("/Library/Application Support/RemoteAccessWatch/"):
            raise ValueError(f"paths.{key} is outside the root-owned runtime directory")
    product_version = payload.get("product_version")
    if not isinstance(product_version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", product_version):
        raise ValueError("product_version must be SemVer")
    return payload


def load_policy(path: Path) -> Dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("policy must be an object")
    return validate_policy(payload)


class Runner:
    def run(self, args: Sequence[str], timeout: int = 10) -> subprocess.CompletedProcess:
        return subprocess.run(
            list(args),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"},
        )


def default_route(runner: Runner) -> Tuple[Optional[str], Optional[str]]:
    result = runner.run([FIXED_COMMANDS["route"], "-n", "get", "default"], timeout=5)
    if result.returncode != 0:
        return None, None
    gateway = None
    interface = None
    for line in result.stdout.splitlines():
        key, separator, value = line.strip().partition(":")
        if separator and key == "gateway":
            gateway = value.strip()
        elif separator and key == "interface":
            interface = value.strip()
    return gateway, interface


def interface_active(runner: Runner, interface: str) -> bool:
    result = runner.run([FIXED_COMMANDS["ifconfig"], interface], timeout=5)
    if result.returncode != 0:
        return False
    return "status: active" in result.stdout or ("<UP," in result.stdout and " inet " in result.stdout)


def detected_wifi_interface(policy: Dict[str, Any], runner: Runner) -> Optional[str]:
    configured = policy["network"]["wifi_interface"]
    if configured != "auto":
        return configured
    result = runner.run([FIXED_COMMANDS["networksetup"], "-listallhardwareports"], timeout=5)
    if result.returncode != 0:
        return None
    hardware_port = None
    for raw_line in result.stdout.splitlines():
        key, separator, value = raw_line.strip().partition(":")
        if not separator:
            continue
        if key == "Hardware Port":
            hardware_port = value.strip()
        elif key == "Device" and hardware_port in {"Wi-Fi", "AirPort"}:
            device = value.strip()
            if re.fullmatch(r"en\d+", device):
                return device
    return None


def network_health(policy: Dict[str, Any], runner: Runner) -> Dict[str, Any]:
    network = policy["network"]
    gateway, interface = default_route(runner)
    managed_interfaces = set(network["managed_interfaces"])
    managed = bool(interface and (not managed_interfaces or interface in managed_interfaces))
    active = bool(interface and managed and interface_active(runner, interface))
    wifi_interface = detected_wifi_interface(policy, runner)
    endpoint_results = []
    successes = 0
    timeout = network["probe_timeout_seconds"]
    for endpoint in network["https_endpoints"]:
        args = [
            FIXED_COMMANDS["curl"],
            "-4",
            "-fsS",
            "--connect-timeout",
            str(timeout),
            "--max-time",
            str(timeout),
            "-o",
            "/dev/null",
        ]
        if active and interface:
            args.extend(["--interface", interface])
        args.append(endpoint)
        result = runner.run(args, timeout=timeout + 2)
        ok = result.returncode == 0
        successes += int(ok)
        endpoint_results.append({"host": urlparse(endpoint).hostname, "ok": ok})
    gateway_ok = False
    if gateway:
        try:
            ipaddress.ip_address(gateway)
            ping = runner.run([FIXED_COMMANDS["ping"], "-n", "-c", "1", "-W", "1000", gateway], timeout=3)
            gateway_ok = ping.returncode == 0
        except ValueError:
            gateway = None
    healthy = active and successes >= network["minimum_https_successes"]
    return {
        "healthy": healthy,
        "interface": interface,
        "gateway_present": gateway is not None,
        "gateway_reachable": gateway_ok,
        "https_successes": successes,
        "https_required": network["minimum_https_successes"],
        "endpoints": endpoint_results,
        "wifi_interface": wifi_interface,
        "wifi_recovery_applicable": bool(wifi_interface and (interface is None or interface == wifi_interface)),
    }


def chrome_host_running(policy: Dict[str, Any], runner: Runner) -> bool:
    chrome = policy["chrome_remote_desktop"]
    target = f"gui/{chrome['user_uid']}/{chrome['launchd_label']}"
    result = runner.run([FIXED_COMMANDS["launchctl"], "print", target], timeout=5)
    return result.returncode == 0 and "state = running" in result.stdout


def restart_airportd(runner: Runner) -> Tuple[bool, str]:
    lookup = runner.run([FIXED_COMMANDS["pgrep"], "-x", "airportd"], timeout=5)
    if lookup.returncode != 0:
        return False, "airportd process not found"
    pids = [item for item in lookup.stdout.split() if item.isdigit()]
    if not pids:
        return False, "airportd process not found"
    validated = []
    for pid in pids:
        result = runner.run([FIXED_COMMANDS["ps"], "-p", pid, "-o", "comm="], timeout=5)
        if result.returncode != 0 or result.stdout.strip() != AIRPORTD_PATH:
            return False, "airportd executable validation failed"
        validated.append(int(pid))
    for pid in validated:
        os.kill(pid, signal.SIGTERM)
    return True, "airportd SIGTERM requested"


def restart_chrome_host(policy: Dict[str, Any], runner: Runner) -> Tuple[bool, str]:
    chrome = policy["chrome_remote_desktop"]
    uid = chrome["user_uid"]
    target = f"gui/{uid}/{chrome['launchd_label']}"
    result = runner.run(
        [
            FIXED_COMMANDS["launchctl"],
            "asuser",
            str(uid),
            FIXED_COMMANDS["launchctl"],
            "kickstart",
            "-k",
            target,
        ],
        timeout=15,
    )
    return result.returncode == 0, "Chrome Remote Desktop kickstart requested" if result.returncode == 0 else "Chrome Remote Desktop kickstart failed"


def _new_incident(kind: str, current: dt.datetime, summary: str) -> Dict[str, Any]:
    return {
        "id": f"{current.strftime('%Y%m%dT%H%M%S%z')}-{kind}-{uuid.uuid4().hex[:8]}",
        "kind": kind,
        "detected_at": iso(current),
        "summary": summary,
        "actions": [],
        "last_action_at": None,
        "unresolved_receipt_written": False,
    }


def write_receipt(policy: Dict[str, Any], incident: Dict[str, Any], status: str, current: dt.datetime, verification: str) -> Path:
    detected = parse_time(incident.get("detected_at")) or current
    duration = max(0, int((current - detected).total_seconds()))
    payload = {
        "schema_version": RECEIPT_SCHEMA,
        "id": f"{incident['id']}-{status}",
        "incident_id": incident["id"],
        "kind": incident["kind"],
        "status": status,
        "detected_at": iso(detected),
        "completed_at": iso(current),
        "duration_seconds": duration,
        "summary": incident["summary"],
        "actions": incident.get("actions", []),
        "verification": verification,
        "mode": policy["mode"],
    }
    output = Path(policy["paths"]["outbox"]) / f"{payload['id']}.json"
    atomic_json_write(output, payload, mode=0o644)
    return output


def _action_due(incident: Dict[str, Any], current: dt.datetime, minimum_interval: int) -> bool:
    last = parse_time(incident.get("last_action_at"))
    return last is None or (current - last).total_seconds() >= minimum_interval


def handle_network(policy: Dict[str, Any], state: Dict[str, Any], health: Dict[str, Any], runner: Runner, current: dt.datetime) -> List[Path]:
    outputs = []
    section = state["network"]
    threshold = policy["network"]["unhealthy_threshold"]
    healthy_threshold = policy["network"]["healthy_threshold"]
    incident = section.get("incident")
    if health["healthy"]:
        section["unhealthy_streak"] = 0
        section["healthy_streak"] = int(section.get("healthy_streak", 0)) + 1
        if incident and section["healthy_streak"] >= healthy_threshold:
            status = "recovered" if incident.get("actions") else "observed_recovery"
            outputs.append(write_receipt(policy, incident, status, current, "외부 HTTPS와 기본 경로 연속 정상"))
            section["incident"] = None
        return outputs
    section["healthy_streak"] = 0
    section["unhealthy_streak"] = int(section.get("unhealthy_streak", 0)) + 1
    if section["unhealthy_streak"] < threshold:
        return outputs
    if not incident:
        incident = _new_incident("network", current, "기본 경로 또는 외부 통신이 연속 실패함")
        section["incident"] = incident
    recovery = policy["recovery"]
    recent = []
    for timestamp in section.get("recent_action_times", []):
        parsed = parse_time(timestamp)
        if parsed and (current - parsed).total_seconds() < 3600:
            recent.append(timestamp)
    section["recent_action_times"] = recent
    attempts = len(incident.get("actions", []))
    can_act = (
        policy["mode"] == "active"
        and recovery.get("airportd_restart_enabled") is True
        and health.get("wifi_recovery_applicable") is True
        and attempts < recovery["airportd_max_attempts_per_incident"]
        and len(recent) < recovery["airportd_max_attempts_per_hour"]
        and _action_due(incident, current, recovery["airportd_minimum_attempt_interval_seconds"])
    )
    if can_act:
        ok, detail = restart_airportd(runner)
        action = {"type": "restart_airportd", "at": iso(current), "ok": ok, "detail": detail}
        incident["actions"].append(action)
        incident["last_action_at"] = iso(current)
        section["recent_action_times"].append(iso(current))
        attempts += 1
    exhausted = (
        attempts >= recovery["airportd_max_attempts_per_incident"]
        or policy["mode"] == "observe"
        or health.get("wifi_recovery_applicable") is not True
    )
    if exhausted and not incident.get("unresolved_receipt_written") and _action_due(
        incident, current, recovery["airportd_minimum_attempt_interval_seconds"]
    ):
        outputs.append(write_receipt(policy, incident, "unresolved", current, "승인된 복구 범위 안에서 외부 통신을 확인하지 못함"))
        incident["unresolved_receipt_written"] = True
    return outputs


def handle_chrome(policy: Dict[str, Any], state: Dict[str, Any], network_ok: bool, running: bool, runner: Runner, current: dt.datetime) -> List[Path]:
    outputs = []
    chrome_policy = policy["chrome_remote_desktop"]
    section = state["chrome_remote_desktop"]
    incident = section.get("incident")
    if not chrome_policy.get("enabled") or not network_ok:
        section["missing_streak"] = 0
        return outputs
    if running:
        section["missing_streak"] = 0
        if incident:
            status = "recovered" if incident.get("actions") else "observed_recovery"
            outputs.append(write_receipt(policy, incident, status, current, "Chrome Remote Desktop launchd 서비스 정상"))
            section["incident"] = None
        return outputs
    section["missing_streak"] = int(section.get("missing_streak", 0)) + 1
    if section["missing_streak"] < chrome_policy["missing_threshold"]:
        return outputs
    if not incident:
        incident = _new_incident("chrome_remote_desktop", current, "인터넷은 정상이지만 Google 원격 호스트 서비스가 중지됨")
        section["incident"] = incident
    attempts = len(incident.get("actions", []))
    acted_now = False
    if policy["mode"] == "active" and attempts < chrome_policy["max_attempts_per_incident"]:
        ok, detail = restart_chrome_host(policy, runner)
        incident["actions"].append({"type": "restart_chrome_remote_desktop", "at": iso(current), "ok": ok, "detail": detail})
        incident["last_action_at"] = iso(current)
        attempts += 1
        acted_now = True
    if (policy["mode"] == "observe" or attempts >= chrome_policy["max_attempts_per_incident"]) and not incident.get("unresolved_receipt_written"):
        if acted_now and incident.get("actions") and incident["actions"][-1].get("ok"):
            return outputs
        outputs.append(write_receipt(policy, incident, "unresolved", current, "Google 원격 호스트 서비스를 시작하지 못함"))
        incident["unresolved_receipt_written"] = True
    return outputs


def build_public_status(
    policy: Dict[str, Any],
    state: Dict[str, Any],
    health: Dict[str, Any],
    chrome_running: bool,
    current: dt.datetime,
) -> Dict[str, Any]:
    network_incident = state["network"].get("incident")
    chrome_incident = state["chrome_remote_desktop"].get("incident")
    incident = network_incident or chrome_incident
    chrome_enabled = bool(policy["chrome_remote_desktop"].get("enabled"))
    if incident:
        if incident.get("unresolved_receipt_written"):
            overall_status = "failed"
        elif incident.get("actions"):
            overall_status = "recovering"
        else:
            overall_status = "degraded"
    elif health["healthy"] and (not chrome_enabled or chrome_running):
        overall_status = "healthy"
    else:
        overall_status = "degraded"
    actions = incident.get("actions", []) if incident else []
    last_action = actions[-1].get("type") if actions else None
    return {
        "schema_version": PUBLIC_STATUS_SCHEMA,
        "engine_version": policy["product_version"],
        "updated_at": iso(current),
        "overall_status": overall_status,
        "mode": policy["mode"],
        "poll_seconds": policy["poll_seconds"],
        "network": {
            "healthy": bool(health["healthy"]),
            "interface": health.get("interface"),
            "gateway_reachable": bool(health.get("gateway_reachable")),
            "https_successes": int(health.get("https_successes", 0)),
            "https_required": int(health.get("https_required", 0)),
            "unhealthy_streak": int(state["network"].get("unhealthy_streak", 0)),
            "wifi_interface": health.get("wifi_interface"),
            "wifi_recovery_applicable": bool(health.get("wifi_recovery_applicable")),
        },
        "chrome_remote_desktop": {
            "enabled": chrome_enabled,
            "running": bool(chrome_running),
            "missing_streak": int(state["chrome_remote_desktop"].get("missing_streak", 0)),
        },
        "recovery": {
            "incident_kind": incident.get("kind") if incident else None,
            "detected_at": incident.get("detected_at") if incident else None,
            "action_count": len(actions),
            "last_action_type": last_action,
            "unresolved": bool(incident and incident.get("unresolved_receipt_written")),
        },
    }


def run_once(policy: Dict[str, Any], runner: Optional[Runner] = None, clock: Callable[[], dt.datetime] = now_local) -> Dict[str, Any]:
    runner = runner or Runner()
    current = clock()
    state_path = Path(policy["paths"]["state"])
    state = load_state(state_path)
    health = network_health(policy, runner)
    receipts = handle_network(policy, state, health, runner, current)
    chrome_running = False
    if health["healthy"] and policy["chrome_remote_desktop"].get("enabled"):
        chrome_running = chrome_host_running(policy, runner)
        receipts.extend(handle_chrome(policy, state, True, chrome_running, runner, current))
    else:
        handle_chrome(policy, state, False, False, runner, current)
    state["last_check_at"] = iso(current)
    state["last_health"] = health
    state["last_chrome_remote_desktop_running"] = chrome_running
    atomic_json_write(state_path, state)
    public_status = build_public_status(policy, state, health, chrome_running, current)
    atomic_json_write(Path(policy["paths"]["public_status"]), public_status, mode=0o644)
    return {
        "ok": True,
        "health": health,
        "chrome_remote_desktop_running": chrome_running,
        "public_status": public_status,
        "receipts": [str(item) for item in receipts],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--check-once", action="store_true")
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    policy = load_policy(Path(args.policy))
    if args.validate_only:
        print(json.dumps({"ok": True, "mode": policy["mode"]}, sort_keys=True))
        return 0
    lock_path = Path(policy["paths"]["state"]).with_suffix(".lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        result = run_once(policy)
    if args.check_once or result["receipts"]:
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as exc:
        print(f"Remote Access Watch watchdog failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
