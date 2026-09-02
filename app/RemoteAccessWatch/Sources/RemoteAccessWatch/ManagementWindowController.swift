import AppKit
import SwiftUI

@MainActor
final class ManagementWindowController: NSWindowController {
    init(store: RecoveryStatusStore) {
        let rootView = ManagementView(store: store)
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.title = "원격접속 지킴이"
        window.setContentSize(NSSize(width: 680, height: 650))
        window.minSize = NSSize(width: 620, height: 580)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        showWindow(nil)
        window.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ManagementView: View {
    @ObservedObject var store: RecoveryStatusStore

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 빌드"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusCard
                protectionCard
                installationCard
                actionBar
            }
            .padding(26)
        }
        .frame(minWidth: 620, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: store.displayState.symbolName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("원격접속 지킴이")
                    .font(.title2.weight(.bold))
                Text("Remote Access Watch · 앱 \(appVersion)")
                    .foregroundStyle(.secondary)
                Text("인터넷과 Chrome Remote Desktop을 60초마다 확인하고, 허용된 범위에서만 자동 복구합니다.")
                    .font(.callout)
                    .padding(.top, 3)
            }
            Spacer()
        }
    }

    private var statusCard: some View {
        card(title: "현재 상태") {
            VStack(alignment: .leading, spacing: 10) {
                statusRow("전체", value: store.displayState.title, symbol: store.displayState.symbolName)
                Divider()
                statusRow("인터넷", value: store.networkDetail, symbol: "network")
                statusRow("Chrome Remote Desktop", value: store.chromeDetail, symbol: "desktopcomputer")
                statusRow("감시 엔진", value: store.engineDetail, symbol: "gearshape.2")
                if let latest = store.latestReceiptDetail {
                    statusRow("최근 사건", value: latest, symbol: "clock.arrow.circlepath")
                }
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var protectionCard: some View {
        card(title: "자동복구 범위") {
            VStack(alignment: .leading, spacing: 8) {
                Label("Wi-Fi 장애 때 Wi-Fi 관리 프로세스(airportd)만 제한적으로 재시작", systemImage: "wifi")
                Label("인터넷 정상인데 원격 호스트가 멈추면 Chrome Remote Desktop만 재시작", systemImage: "desktopcomputer")
                Label("Mac 재부팅·Wi-Fi 전원 토글·임의 명령 실행은 하지 않음", systemImage: "hand.raised.fill")
                Label("외부 서버나 메신저로 상태·알림을 보내지 않음", systemImage: "lock.shield.fill")
            }
            .font(.callout)
        }
    }

    private var installationCard: some View {
        card(title: "설치 및 관리") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    Text("앱")
                        .foregroundStyle(.secondary)
                    Text(Bundle.main.bundlePath)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("엔진")
                        .foregroundStyle(.secondary)
                    Text("/Library/PrivilegedHelperTools/io.github.sundaynighttt.remote-access-watch")
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("상태")
                        .foregroundStyle(.secondary)
                    Text(RecoveryStatusStore.publicStatusURL.path)
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
            Text("업데이트와 제거는 배포 패키지에 포함된 install.sh / uninstall.sh로 수행합니다. 제거 시 사건 기록은 기본적으로 보존됩니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 5)
        }
    }

    private var actionBar: some View {
        HStack {
            Button("새로고침") { store.refresh() }
                .keyboardShortcut("r", modifiers: .command)
            Button("상태 파일 보기") {
                NSWorkspace.shared.activateFileViewerSelecting([RecoveryStatusStore.publicStatusURL])
            }
            Button("로그 폴더 열기") {
                NSWorkspace.shared.open(RecoveryStatusStore.logsURL)
            }
            Spacer()
        }
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private func statusRow(_ label: String, value: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(label)
                .frame(width: 142, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private var statusColor: Color {
        switch store.displayState {
        case .healthy: return .green
        case .recovering: return .blue
        case .degraded, .stale: return .orange
        case .failed: return .red
        case .unavailable: return .secondary
        }
    }
}
