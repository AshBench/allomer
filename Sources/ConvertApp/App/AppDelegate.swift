import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: ConversionModel?
    private var showWindow: (() -> Void)?
    private var pendingTab: String?

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func connect(model: ConversionModel, showWindow: @escaping () -> Void) {
        self.model = model
        self.showWindow = showWindow
        if let pendingTab {
            self.pendingTab = nil
            openNotification(tab: pendingTab)
        }
    }

    func openNotification(tab: String) {
        guard let model, let showWindow else { pendingTab = tab; return }
        switch tab {
        case "manual": model.tab = .manual
        case "automatic": model.tab = .automatic
        default: model.tab = .history
        }
        showWindow()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let tab = response.notification.request.content.userInfo["tab"] as? String ?? "history"
        await openNotification(tab: tab)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await foregroundPresentation
    }

    private var foregroundPresentation: UNNotificationPresentationOptions {
        model?.appSettings.showNotifications == true ? [.banner, .list, .sound] : []
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.prepareToQuit(sender) ?? .terminateNow
    }
}
