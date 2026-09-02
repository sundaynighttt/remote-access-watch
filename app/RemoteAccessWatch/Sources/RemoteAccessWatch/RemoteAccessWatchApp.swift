import AppKit
import Combine
import OSLog

@main
@MainActor
final class RemoteAccessWatchApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static var retainedDelegate: RemoteAccessWatchApp?

    private let store = RecoveryStatusStore()
    private let statusMenu = NSMenu()
    private let logger = Logger(
        subsystem: "com.sundaynighttt.remote-access-watch",
        category: "MenuBar"
    )
    private var statusItem: NSStatusItem?
    private var storeCancellable: AnyCancellable?
    private var loginItemError: String?
    private lazy var managementWindowController = ManagementWindowController(store: store)

    private var maintenanceAction: String? {
        CommandLine.arguments.first {
            $0 == "--refresh-login-item-and-quit" || $0 == "--unregister-login-item-and-quit"
        }
    }

    static func main() {
        let delegate = RemoteAccessWatchApp()
        retainedDelegate = delegate
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(delegate.maintenanceAction == nil ? .accessory : .prohibited)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if performMaintenanceActionIfNeeded() {
            NSApplication.shared.terminate(nil)
            return
        }
        statusMenu.delegate = self
        installStatusItem()
        observeStatusChanges()
        observeSystemEvents()
        configureLaunchAtLoginOnce()
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        storeCancellable = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        ensureStatusItemVisible(reason: "application reopen")
        DispatchQueue.main.async { [weak self] in
            self?.showManagementWindow()
        }
        return false
    }

    func menuWillOpen(_ menu: NSMenu) {
        store.refresh()
        rebuildMenu()
    }

    private func installStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = statusMenu
        item.isVisible = true
        statusItem = item
        updateStatusItem()
        rebuildMenu()
    }

    private func observeStatusChanges() {
        storeCancellable = store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusItem()
            }
        }
    }

    private func observeSystemEvents() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(restoreStatusItem),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(restoreStatusItem),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(restoreStatusItem),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    private func configureLaunchAtLoginOnce() {
        let bundlePath = Bundle.main.bundlePath
        let installedForAllUsers = bundlePath == "/Applications/Remote Access Watch.app"
        let installedForCurrentUser = bundlePath == FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Remote Access Watch.app").path
        guard installedForAllUsers || installedForCurrentUser else {
            loginItemError = "배포 패키지 미리보기에서는 로그인 자동 실행을 등록하지 않음"
            return
        }
        let defaults = UserDefaults.standard
        let key = "didConfigureLaunchAtLogin"
        guard !defaults.bool(forKey: key) else { return }
        do {
            try LoginItemManager.setEnabled(true)
            defaults.set(true, forKey: key)
        } catch {
            loginItemError = "자동 실행 설정 실패: \(error.localizedDescription)"
        }
    }

    private func performMaintenanceActionIfNeeded() -> Bool {
        guard let maintenanceAction else { return false }
        do {
            switch maintenanceAction {
            case "--refresh-login-item-and-quit":
                try LoginItemManager.refreshRegistration()
                UserDefaults.standard.set(true, forKey: "didConfigureLaunchAtLogin")
            case "--unregister-login-item-and-quit":
                try LoginItemManager.setEnabled(false)
                UserDefaults.standard.set(false, forKey: "didConfigureLaunchAtLogin")
            default:
                break
            }
        } catch {
            logger.error("Login item maintenance failed: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
        return true
    }

    @objc private func restoreStatusItem(_ notification: Notification) {
        ensureStatusItemVisible(reason: notification.name.rawValue)
    }

    private func ensureStatusItemVisible(reason: String) {
        guard let statusItem, statusItem.button != nil else {
            installStatusItem()
            return
        }
        statusItem.length = NSStatusItem.variableLength
        statusItem.isVisible = true
        statusItem.menu = statusMenu
        updateStatusItem()
        logger.info("Status item restored after \(reason, privacy: .public)")
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let state = store.displayState
        let image = NSImage(
            systemSymbolName: state.symbolName,
            accessibilityDescription: state.title
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.title = " \(state.title)"
        button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.toolTip = "Mac 원격접속 자동복구 상태"
        button.setAccessibilityLabel("Mac 원격접속 \(state.title)")
        button.setAccessibilityIdentifier("RemoteAccessWatchStatusItem")
    }

    private func rebuildMenu() {
        statusMenu.removeAllItems()
        let state = store.displayState
        let header = NSMenuItem(title: state.title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.image = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: nil)
        header.attributedTitle = NSAttributedString(
            string: state.title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        statusMenu.addItem(header)
        addInfoItem(store.statusDetail)

        statusMenu.addItem(.separator())
        addSectionHeader("복구 엔진")
        addInfoItem(store.engineDetail)
        addInfoItem("인터넷  \(store.networkDetail)")
        addInfoItem("Google 원격  \(store.chromeDetail)")

        if let latest = store.latestReceiptDetail {
            statusMenu.addItem(.separator())
            addSectionHeader("최근 사건")
            addInfoItem(latest)
            if let receipt = store.latestReceipt {
                addInfoItem(receipt.verification)
            }
        }
        if let error = store.errorMessage {
            statusMenu.addItem(.separator())
            addInfoItem(error)
        }
        if let loginItemError {
            addInfoItem(loginItemError)
        }

        statusMenu.addItem(.separator())
        let manage = actionItem(title: "관리 및 제품 정보…", action: #selector(showManagementWindow))
        manage.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        statusMenu.addItem(manage)
        let refresh = actionItem(title: "지금 새로고침", action: #selector(refreshStatus))
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        statusMenu.addItem(refresh)
        statusMenu.addItem(actionItem(title: "상태 파일 보기", action: #selector(revealStatusFile)))
        statusMenu.addItem(actionItem(title: "복구 로그 폴더 열기", action: #selector(openLogs)))

        let loginItem = actionItem(title: "로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin))
        loginItem.state = LoginItemManager.isEnabled ? .on : .off
        statusMenu.addItem(loginItem)

        statusMenu.addItem(.separator())
        statusMenu.addItem(actionItem(title: "상태 앱 종료 (감시는 계속됨)", action: #selector(quitApplication)))
    }

    private func addSectionHeader(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        statusMenu.addItem(item)
    }

    private func addInfoItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        statusMenu.addItem(item)
    }

    private func actionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func refreshStatus() {
        store.refresh()
        updateStatusItem()
    }

    @objc private func showManagementWindow() {
        store.refresh()
        managementWindowController.show()
    }

    @objc private func revealStatusFile() {
        NSWorkspace.shared.activateFileViewerSelecting([RecoveryStatusStore.publicStatusURL])
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(RecoveryStatusStore.logsURL)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItemManager.setEnabled(!LoginItemManager.isEnabled)
            loginItemError = nil
        } catch {
            loginItemError = "자동 실행 설정 실패: \(error.localizedDescription)"
        }
        rebuildMenu()
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
}
