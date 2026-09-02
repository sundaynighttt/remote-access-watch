import Foundation
import Testing
@testable import RemoteAccessWatch

struct RecoveryStatusTests {
    @Test
    func healthySnapshotIsVisibleAsHealthy() throws {
        let status = try decodeStatus(overall: "healthy", updatedAt: "2026-09-02T16:20:00+09:00")
        let now = try #require(RecoveryDateParser.parse("2026-09-02T16:21:00+09:00"))
        #expect(RecoveryStatusClassifier.classify(status, now: now) == .healthy)
        #expect(status.network.healthy)
        #expect(status.chromeRemoteDesktop.running)
    }

    @Test
    func activeRecoveryGetsDistinctMenuState() throws {
        let status = try decodeStatus(overall: "recovering", updatedAt: "2026-09-02T16:20:00+09:00")
        let now = try #require(RecoveryDateParser.parse("2026-09-02T16:20:10+09:00"))
        #expect(RecoveryStatusClassifier.classify(status, now: now) == .recovering)
        #expect(RecoveryStatusClassifier.actionLabel("restart_airportd") == "Wi-Fi 관리 프로세스 재시작")
    }

    @Test
    func staleSnapshotSurfacesStoppedWatchdog() throws {
        let status = try decodeStatus(overall: "healthy", updatedAt: "2026-09-02T16:10:00+09:00")
        let now = try #require(RecoveryDateParser.parse("2026-09-02T16:20:00+09:00"))
        #expect(RecoveryStatusClassifier.classify(status, now: now) == .stale)
    }

    @Test
    func missingOrWrongSchemaDoesNotClaimHealthy() throws {
        let now = Date()
        #expect(RecoveryStatusClassifier.classify(nil, now: now) == .unavailable)
        let status = try decodeStatus(
            overall: "healthy",
            updatedAt: "2026-09-02T16:20:00+09:00",
            schema: "unknown"
        )
        #expect(RecoveryStatusClassifier.classify(status, now: now) == .unavailable)
    }

    private func decodeStatus(
        overall: String,
        updatedAt: String,
        schema: String = "remote-access-watch-public-status-v1"
    ) throws -> PublicRecoveryStatus {
        let json = """
        {
          "schema_version": "\(schema)",
          "engine_version": "0.1.0",
          "updated_at": "\(updatedAt)",
          "overall_status": "\(overall)",
          "mode": "active",
          "poll_seconds": 60,
          "network": {
            "healthy": true,
            "interface": "en0",
            "gateway_reachable": true,
            "https_successes": 2,
            "https_required": 1,
            "unhealthy_streak": 0,
            "wifi_interface": "en0",
            "wifi_recovery_applicable": true
          },
          "chrome_remote_desktop": {
            "enabled": true,
            "running": true,
            "missing_streak": 0
          },
          "recovery": {
            "incident_kind": null,
            "detected_at": null,
            "action_count": 0,
            "last_action_type": null,
            "unresolved": false
          }
        }
        """
        return try JSONDecoder().decode(PublicRecoveryStatus.self, from: Data(json.utf8))
    }
}
