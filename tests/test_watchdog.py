from __future__ import annotations

import datetime as dt
import json
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from watchdog import watchdog


LOCAL_TZ = dt.timezone(dt.timedelta(hours=9))


def policy_for(root: Path) -> dict:
    value = watchdog.validate_policy(
        {
            "schema_version": watchdog.SCHEMA,
            "product_version": "0.1.0",
            "mode": "active",
            "poll_seconds": 60,
            "network": {
                "wifi_interface": "en0",
                "managed_interfaces": ["en0", "en3"],
                "https_endpoints": [
                    "https://www.google.com/generate_204",
                    "https://www.cloudflare.com/cdn-cgi/trace",
                ],
                "minimum_https_successes": 1,
                "unhealthy_threshold": 3,
                "healthy_threshold": 2,
                "probe_timeout_seconds": 5,
            },
            "recovery": {
                "airportd_restart_enabled": True,
                "airportd_max_attempts_per_incident": 2,
                "airportd_minimum_attempt_interval_seconds": 60,
                "airportd_max_attempts_per_hour": 2,
                "full_reboot_enabled": False,
            },
            "chrome_remote_desktop": {
                "enabled": True,
                "user_uid": 501,
                "launchd_label": "org.chromium.chromoting",
                "missing_threshold": 2,
                "max_attempts_per_incident": 1,
            },
            "paths": {
                "state": "/Library/Application Support/RemoteAccessWatch/state/state.json",
                "public_status": "/Library/Application Support/RemoteAccessWatch/status.json",
                "outbox": "/Library/Application Support/RemoteAccessWatch/incidents",
            },
        }
    )
    value["paths"]["state"] = str(root / "state.json")
    value["paths"]["public_status"] = str(root / "status.json")
    value["paths"]["outbox"] = str(root / "incidents")
    return value


def installed_paths() -> dict:
    return {
        "state": "/Library/Application Support/RemoteAccessWatch/state/state.json",
        "public_status": "/Library/Application Support/RemoteAccessWatch/status.json",
        "outbox": "/Library/Application Support/RemoteAccessWatch/incidents",
    }


class WatchdogPolicyTests(unittest.TestCase):
    def test_policy_forbids_full_reboot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            value = policy_for(Path(temporary))
            value["paths"] = installed_paths()
            value["recovery"]["full_reboot_enabled"] = True
            with self.assertRaisesRegex(ValueError, "full reboot"):
                watchdog.validate_policy(value)

    def test_policy_forbids_unapproved_probe_host(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            value = policy_for(Path(temporary))
            value["paths"] = installed_paths()
            value["network"]["https_endpoints"][0] = "https://example.com/"
            with self.assertRaisesRegex(ValueError, "allowlist"):
                watchdog.validate_policy(value)

    def test_policy_requires_strict_product_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            value = policy_for(Path(temporary))
            value["paths"] = installed_paths()
            value["product_version"] = "latest"
            with self.assertRaisesRegex(ValueError, "SemVer"):
                watchdog.validate_policy(value)

    def test_auto_wifi_detection_uses_hardware_port_mapping(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            value = policy_for(Path(temporary))
            value["network"]["wifi_interface"] = "auto"
            runner = mock.Mock(spec=watchdog.Runner)
            runner.run.return_value = subprocess.CompletedProcess(
                [],
                0,
                "Hardware Port: Ethernet\nDevice: en0\n\nHardware Port: Wi-Fi\nDevice: en1\n",
                "",
            )
            self.assertEqual("en1", watchdog.detected_wifi_interface(value, runner))

    def test_airportd_restart_requires_exact_executable(self) -> None:
        runner = mock.Mock(spec=watchdog.Runner)
        runner.run.side_effect = [
            subprocess.CompletedProcess([], 0, "456\n", ""),
            subprocess.CompletedProcess([], 0, "/tmp/not-airportd\n", ""),
        ]
        with mock.patch.object(watchdog.os, "kill") as kill:
            ok, detail = watchdog.restart_airportd(runner)
        self.assertFalse(ok)
        self.assertIn("validation failed", detail)
        kill.assert_not_called()

    def test_airportd_restart_sends_only_sigterm_to_validated_pid(self) -> None:
        runner = mock.Mock(spec=watchdog.Runner)
        runner.run.side_effect = [
            subprocess.CompletedProcess([], 0, "456\n", ""),
            subprocess.CompletedProcess([], 0, f"{watchdog.AIRPORTD_PATH}\n", ""),
        ]
        with mock.patch.object(watchdog.os, "kill") as kill:
            ok, _ = watchdog.restart_airportd(runner)
        self.assertTrue(ok)
        kill.assert_called_once_with(456, watchdog.signal.SIGTERM)


class WatchdogStateMachineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.policy = policy_for(self.root)
        self.runner = mock.Mock(spec=watchdog.Runner)
        self.unhealthy = {
            "healthy": False,
            "interface": "en0",
            "gateway_present": True,
            "gateway_reachable": False,
            "https_successes": 0,
            "https_required": 1,
            "endpoints": [],
            "wifi_interface": "en0",
            "wifi_recovery_applicable": True,
        }
        self.healthy = dict(self.unhealthy, healthy=True, gateway_reachable=True, https_successes=2)
        self.start = dt.datetime(2026, 8, 29, 2, 40, tzinfo=LOCAL_TZ)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _run(self, health: dict, current: dt.datetime, chrome: bool = True) -> dict:
        with mock.patch.object(watchdog, "network_health", return_value=health), mock.patch.object(
            watchdog, "chrome_host_running", return_value=chrome
        ):
            return watchdog.run_once(self.policy, self.runner, clock=lambda: current)

    def test_network_recovery_waits_three_failures_then_restarts_only_airportd(self) -> None:
        with mock.patch.object(watchdog, "restart_airportd", return_value=(True, "requested")) as restart:
            self._run(self.unhealthy, self.start)
            self._run(self.unhealthy, self.start + dt.timedelta(minutes=1))
            self.assertEqual(0, restart.call_count)
            result = self._run(self.unhealthy, self.start + dt.timedelta(minutes=2))
            self.assertEqual(1, restart.call_count)
            self.assertEqual([], result["receipts"])
        state = json.loads(Path(self.policy["paths"]["state"]).read_text(encoding="utf-8"))
        self.assertEqual("restart_airportd", state["network"]["incident"]["actions"][0]["type"])
        self.assertFalse(self.policy["recovery"]["full_reboot_enabled"])

    def test_non_wifi_route_is_reported_but_never_restarts_airportd(self) -> None:
        ethernet_failure = dict(
            self.unhealthy,
            interface="en3",
            wifi_interface="en0",
            wifi_recovery_applicable=False,
        )
        with mock.patch.object(watchdog, "restart_airportd") as restart:
            for minute in range(3):
                result = self._run(ethernet_failure, self.start + dt.timedelta(minutes=minute))
            repeated = self._run(ethernet_failure, self.start + dt.timedelta(minutes=3))
        restart.assert_not_called()
        self.assertEqual(1, len(result["receipts"]))
        self.assertEqual([], repeated["receipts"])
        self.assertEqual("failed", result["public_status"]["overall_status"])

    def test_public_status_is_world_readable_versioned_and_sanitized(self) -> None:
        result = self._run(self.healthy, self.start)
        public_path = Path(self.policy["paths"]["public_status"])
        payload = json.loads(public_path.read_text(encoding="utf-8"))
        self.assertEqual(watchdog.PUBLIC_STATUS_SCHEMA, payload["schema_version"])
        self.assertEqual("0.1.0", payload["engine_version"])
        self.assertEqual("healthy", payload["overall_status"])
        self.assertTrue(payload["network"]["healthy"])
        self.assertEqual("en0", payload["network"]["wifi_interface"])
        self.assertTrue(payload["chrome_remote_desktop"]["running"])
        self.assertEqual(0o644, stat.S_IMODE(public_path.stat().st_mode))
        encoded = json.dumps(payload)
        self.assertNotIn("192.", encoded)
        self.assertNotIn("endpoints", encoded)
        self.assertEqual(payload, result["public_status"])

    def test_public_status_surfaces_recovery_and_failure(self) -> None:
        self.policy["recovery"]["airportd_max_attempts_per_incident"] = 1
        with mock.patch.object(watchdog, "restart_airportd", return_value=(True, "requested")):
            for minute in range(3):
                result = self._run(self.unhealthy, self.start + dt.timedelta(minutes=minute))
            self.assertEqual("recovering", result["public_status"]["overall_status"])
            failed = self._run(self.unhealthy, self.start + dt.timedelta(minutes=3, seconds=1))
        self.assertEqual("failed", failed["public_status"]["overall_status"])
        self.assertTrue(failed["public_status"]["recovery"]["unresolved"])
        self.assertEqual("restart_airportd", failed["public_status"]["recovery"]["last_action_type"])

    def test_recovery_requires_two_healthy_checks_and_writes_sanitized_receipt(self) -> None:
        with mock.patch.object(watchdog, "restart_airportd", return_value=(True, "requested")):
            for minute in range(3):
                self._run(self.unhealthy, self.start + dt.timedelta(minutes=minute))
            first = self._run(self.healthy, self.start + dt.timedelta(minutes=3))
            second = self._run(self.healthy, self.start + dt.timedelta(minutes=4))
        self.assertEqual([], first["receipts"])
        self.assertEqual(1, len(second["receipts"]))
        receipt = json.loads(Path(second["receipts"][0]).read_text(encoding="utf-8"))
        self.assertEqual(watchdog.RECEIPT_SCHEMA, receipt["schema_version"])
        self.assertEqual("recovered", receipt["status"])
        self.assertEqual("network", receipt["kind"])
        self.assertNotIn("gateway", json.dumps(receipt))

    def test_exhausted_network_attempts_emit_one_unresolved_receipt(self) -> None:
        self.policy["recovery"]["airportd_max_attempts_per_incident"] = 1
        with mock.patch.object(watchdog, "restart_airportd", return_value=(True, "requested")):
            for minute in range(3):
                self._run(self.unhealthy, self.start + dt.timedelta(minutes=minute))
            result = self._run(self.unhealthy, self.start + dt.timedelta(minutes=3, seconds=1))
            repeated = self._run(self.unhealthy, self.start + dt.timedelta(minutes=4, seconds=2))
        self.assertEqual(1, len(result["receipts"]))
        self.assertEqual([], repeated["receipts"])
        receipt = json.loads(Path(result["receipts"][0]).read_text(encoding="utf-8"))
        self.assertEqual("unresolved", receipt["status"])

    def test_chrome_host_restart_is_verified_on_next_check(self) -> None:
        with mock.patch.object(watchdog, "restart_chrome_host", return_value=(True, "requested")) as restart:
            self._run(self.healthy, self.start, chrome=False)
            attempted = self._run(self.healthy, self.start + dt.timedelta(minutes=1), chrome=False)
            recovered = self._run(self.healthy, self.start + dt.timedelta(minutes=2), chrome=True)
        self.assertEqual(1, restart.call_count)
        self.assertEqual([], attempted["receipts"])
        self.assertEqual(1, len(recovered["receipts"]))
        receipt = json.loads(Path(recovered["receipts"][0]).read_text(encoding="utf-8"))
        self.assertEqual("chrome_remote_desktop", receipt["kind"])
        self.assertEqual("recovered", receipt["status"])


if __name__ == "__main__":
    unittest.main()
