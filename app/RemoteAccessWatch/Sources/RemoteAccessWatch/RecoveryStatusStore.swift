import Combine
import Foundation

@MainActor
final class RecoveryStatusStore: ObservableObject {
    nonisolated static let publicStatusURL = URL(
        fileURLWithPath: "/Library/Application Support/RemoteAccessWatch/status.json"
    )
    nonisolated static let outboxURL = URL(
        fileURLWithPath: "/Library/Application Support/RemoteAccessWatch/incidents",
        isDirectory: true
    )
    nonisolated static let logsURL = URL(
        fileURLWithPath: "/Library/Logs/RemoteAccessWatch",
        isDirectory: true
    )

    @Published private(set) var snapshot: PublicRecoveryStatus?
    @Published private(set) var latestReceipt: RecoveryReceipt?
    @Published private(set) var errorMessage: String?
    @Published private(set) var now = Date()

    private let statusURL: URL
    private let outboxURL: URL
    private var refreshTimer: Timer?

    init(
        statusURL: URL = RecoveryStatusStore.publicStatusURL,
        outboxURL: URL = RecoveryStatusStore.outboxURL
    ) {
        self.statusURL = statusURL
        self.outboxURL = outboxURL
    }

    var displayState: RecoveryDisplayState {
        RecoveryStatusClassifier.classify(snapshot, now: now)
    }

    var statusDetail: String {
        guard let snapshot else {
            return "복구 엔진의 공개 상태를 기다리는 중"
        }
        if displayState == .stale {
            return "복구 엔진 상태가 3분 넘게 갱신되지 않음"
        }
        switch displayState {
        case .healthy:
            return "인터넷과 Google 원격 호스트 정상"
        case .recovering:
            return RecoveryStatusClassifier.actionLabel(snapshot.recovery.lastActionType)
        case .degraded:
            if !snapshot.network.healthy {
                return "인터넷 연결 이상을 확인 중"
            }
            return "Google 원격 호스트 상태 확인 필요"
        case .failed:
            return "승인된 자동복구 범위 안에서 해결되지 않음"
        case .stale, .unavailable:
            return "복구 엔진 상태를 확인할 수 없음"
        }
    }

    var engineDetail: String {
        guard let snapshot else { return "상태 파일 없음" }
        let modeLabel = snapshot.mode == "active" ? "자동복구 켜짐" : "관찰 모드"
        return "\(modeLabel) · 엔진 \(snapshot.engineVersion) · \(snapshot.pollSeconds)초 주기 · \(relativeTime(snapshot.updatedAt))"
    }

    var networkDetail: String {
        guard let network = snapshot?.network else { return "인터넷 상태 없음" }
        let interface = network.interface ?? "경로 없음"
        if network.healthy {
            return "정상 · \(interface) · 외부 확인 \(network.httpsSuccesses)건"
        }
        return "이상 · \(interface) · 연속 실패 \(network.unhealthyStreak)회"
    }

    var chromeDetail: String {
        guard let chrome = snapshot?.chromeRemoteDesktop else {
            return "Google 원격 호스트 상태 없음"
        }
        if !chrome.enabled {
            return "감시 꺼짐"
        }
        return chrome.running ? "정상 실행 중" : "중지 또는 응답 없음"
    }

    var latestReceiptDetail: String? {
        guard let latestReceipt else { return nil }
        let statusLabel: String
        switch latestReceipt.status {
        case "recovered": statusLabel = "자동복구 완료"
        case "observed_recovery": statusLabel = "연결 회복"
        case "unresolved": statusLabel = "복구 실패"
        default: statusLabel = latestReceipt.status
        }
        return "\(statusLabel) · \(relativeTime(latestReceipt.completedAt))"
    }

    func start() {
        guard refreshTimer == nil else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        now = Date()
        guard FileManager.default.fileExists(atPath: statusURL.path) else {
            snapshot = nil
            latestReceipt = try? loadLatestReceipt()
            errorMessage = "아직 설치되지 않았거나 감시 엔진이 시작되지 않았습니다."
            return
        }
        do {
            let data = try Data(contentsOf: statusURL)
            snapshot = try JSONDecoder().decode(PublicRecoveryStatus.self, from: data)
            latestReceipt = try? loadLatestReceipt()
            errorMessage = nil
        } catch {
            snapshot = nil
            latestReceipt = try? loadLatestReceipt()
            errorMessage = "상태 파일 형식이나 읽기 권한을 확인해야 합니다."
        }
    }

    private func loadLatestReceipt() throws -> RecoveryReceipt? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: outboxURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        let candidates = urls
            .filter { $0.pathExtension == "json" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: keys))?.contentModificationDate
                let right = (try? $1.resourceValues(forKeys: keys))?.contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
            .prefix(20)
        return candidates.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(RecoveryReceipt.self, from: data)
        }.max {
            (RecoveryDateParser.parse($0.completedAt) ?? .distantPast)
                < (RecoveryDateParser.parse($1.completedAt) ?? .distantPast)
        }
    }

    private func relativeTime(_ value: String) -> String {
        guard let date = RecoveryDateParser.parse(value) else { return "시각 확인 불가" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
