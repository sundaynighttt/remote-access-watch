import Foundation

struct PublicRecoveryStatus: Decodable, Equatable {
    let schemaVersion: String
    let engineVersion: String
    let updatedAt: String
    let overallStatus: String
    let mode: String
    let pollSeconds: Int
    let network: NetworkStatus
    let chromeRemoteDesktop: ChromeRemoteDesktopStatus
    let recovery: RecoveryStatus

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case engineVersion = "engine_version"
        case updatedAt = "updated_at"
        case overallStatus = "overall_status"
        case mode
        case pollSeconds = "poll_seconds"
        case network
        case chromeRemoteDesktop = "chrome_remote_desktop"
        case recovery
    }

    struct NetworkStatus: Decodable, Equatable {
        let healthy: Bool
        let interface: String?
        let gatewayReachable: Bool
        let httpsSuccesses: Int
        let httpsRequired: Int
        let unhealthyStreak: Int
        let wifiInterface: String?
        let wifiRecoveryApplicable: Bool

        enum CodingKeys: String, CodingKey {
            case healthy
            case interface
            case gatewayReachable = "gateway_reachable"
            case httpsSuccesses = "https_successes"
            case httpsRequired = "https_required"
            case unhealthyStreak = "unhealthy_streak"
            case wifiInterface = "wifi_interface"
            case wifiRecoveryApplicable = "wifi_recovery_applicable"
        }
    }

    struct ChromeRemoteDesktopStatus: Decodable, Equatable {
        let enabled: Bool
        let running: Bool
        let missingStreak: Int

        enum CodingKeys: String, CodingKey {
            case enabled
            case running
            case missingStreak = "missing_streak"
        }
    }

    struct RecoveryStatus: Decodable, Equatable {
        let incidentKind: String?
        let detectedAt: String?
        let actionCount: Int
        let lastActionType: String?
        let unresolved: Bool

        enum CodingKeys: String, CodingKey {
            case incidentKind = "incident_kind"
            case detectedAt = "detected_at"
            case actionCount = "action_count"
            case lastActionType = "last_action_type"
            case unresolved
        }
    }
}

struct RecoveryReceipt: Decodable, Equatable {
    let id: String
    let kind: String
    let status: String
    let completedAt: String
    let durationSeconds: Int
    let summary: String
    let verification: String
    let actions: [RecoveryAction]

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case status
        case completedAt = "completed_at"
        case durationSeconds = "duration_seconds"
        case summary
        case verification
        case actions
    }
}

struct RecoveryAction: Decodable, Equatable {
    let type: String
    let ok: Bool
}

enum RecoveryDisplayState: Equatable {
    case healthy
    case recovering
    case degraded
    case failed
    case stale
    case unavailable

    var title: String {
        switch self {
        case .healthy: return "원격 정상"
        case .recovering: return "복구 중"
        case .degraded: return "확인 필요"
        case .failed: return "복구 실패"
        case .stale: return "감시 중단"
        case .unavailable: return "상태 없음"
        }
    }

    var symbolName: String {
        switch self {
        case .healthy: return "checkmark.shield.fill"
        case .recovering: return "arrow.triangle.2.circlepath.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.shield.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .unavailable: return "questionmark.circle"
        }
    }
}

enum RecoveryDateParser {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) {
            return parsed
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

enum RecoveryStatusClassifier {
    static let expectedSchema = "remote-access-watch-public-status-v1"

    static func classify(
        _ status: PublicRecoveryStatus?,
        now: Date,
        staleAfter: TimeInterval = 180
    ) -> RecoveryDisplayState {
        guard let status,
              status.schemaVersion == expectedSchema,
              let updated = RecoveryDateParser.parse(status.updatedAt)
        else {
            return .unavailable
        }
        if now.timeIntervalSince(updated) > staleAfter {
            return .stale
        }
        switch status.overallStatus {
        case "healthy": return .healthy
        case "recovering": return .recovering
        case "failed": return .failed
        default: return .degraded
        }
    }

    static func actionLabel(_ type: String?) -> String {
        switch type {
        case "restart_airportd": return "Wi-Fi 관리 프로세스 재시작"
        case "restart_chrome_remote_desktop": return "Google 원격 호스트 재시작"
        case .none: return "조치 대기"
        default: return "승인된 복구 조치"
        }
    }
}
