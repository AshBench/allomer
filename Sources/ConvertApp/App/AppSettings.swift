import Foundation
import Observation
import ServiceManagement
@preconcurrency import UserNotifications

@MainActor
@Observable
final class AppSettings {
    private(set) var showNotifications: Bool
    private(set) var notificationAuthorization = UNAuthorizationStatus.notDetermined
    private(set) var loginStatus = SMAppService.Status.notRegistered
    private(set) var changingNotifications = false
    private(set) var changingLogin = false
    private(set) var notificationError: String?
    private(set) var loginError: String?
    @ObservationIgnored var readAuthorization: @MainActor () async -> UNAuthorizationStatus = {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    @ObservationIgnored var requestAuthorization: @MainActor () async throws -> Bool = {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    @ObservationIgnored var deliver: @MainActor (UNNotificationRequest) async throws -> Void = {
        try await UNUserNotificationCenter.current().add($0)
    }
    @ObservationIgnored var readLoginStatus: @MainActor () -> SMAppService.Status = { SMAppService.mainApp.status }
    @ObservationIgnored var registerLogin: @MainActor (Bool) async throws -> Void = { enabled in
        if enabled { try SMAppService.mainApp.register() }
        else { try await SMAppService.mainApp.unregister() }
    }
    private let defaults: UserDefaults
    private var notificationGeneration = UUID()
    private var completionTask: Task<Void, Never>?
    private var completedNames: [String] = []
    private var completedCount = 0
    private var stopped = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        showNotifications = defaults.bool(forKey: PreferenceKey.showNotifications)
    }

    var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    var loginDescription: String {
        switch loginStatus {
        case .enabled: "The app will open when you log in."
        case .notRegistered: "Launch at login is off."
        case .requiresApproval: "Allow the app in System Settings → General → Login Items."
        case .notFound: "The login item could not be found. Move the app to Applications and try again."
        @unknown default: "The login item status is unavailable."
        }
    }

    var notificationDescription: String {
        guard showNotifications else { return "Conversion notifications are off." }
        switch notificationAuthorization {
        case .authorized: return "Notifications are enabled. macOS controls their sound and appearance."
        case .provisional: return "Notifications are delivered quietly. Change this in System Settings."
        case .denied: return "Allow notifications for this app in System Settings → Notifications."
        case .notDetermined: return "Notification permission has not been granted. Turn the option off and on to request it."
        @unknown default: return "Notification permission is unavailable."
        }
    }

    func refresh() async {
        loginStatus = readLoginStatus()
        let generation = notificationGeneration
        let authorization = await readAuthorization()
        if generation == notificationGeneration { notificationAuthorization = authorization }
    }

    func setNotifications(_ enabled: Bool) async {
        guard !changingNotifications else { return }
        changingNotifications = true
        defer { changingNotifications = false }
        notificationError = nil
        showNotifications = enabled
        defaults.set(enabled, forKey: PreferenceKey.showNotifications)
        discardCompletions()
        guard enabled else { return }
        do {
            let authorization = await readAuthorization()
            notificationAuthorization = authorization
            if authorization == .notDetermined { _ = try await requestAuthorization() }
            notificationAuthorization = await readAuthorization()
        } catch { notificationError = "Notification permission could not be updated: \(error.localizedDescription)" }
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        guard !changingLogin else { return }
        changingLogin = true
        defer { changingLogin = false }
        loginError = nil
        loginStatus = readLoginStatus()
        guard enabled != launchAtLogin else { return }
        do { try await registerLogin(enabled) }
        catch { loginError = "Launch at login could not be changed: \(error.localizedDescription)" }
        loginStatus = readLoginStatus()
    }

    func converted(_ file: URL, manual: Bool = false) {
        guard showNotifications, !stopped else { return }
        if manual {
            post(title: "Conversion Complete", body: file.lastPathComponent, tab: "manual")
            return
        }
        completedCount += 1
        if completedNames.count < 3 { completedNames.append(file.lastPathComponent) }
        guard completionTask == nil else { return }
        completionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.flushCompletions()
        }
    }

    @discardableResult
    func failed(_ message: String, manual: Bool = false, undo: Bool = false) -> Task<Void, Never>? {
        post(title: undo ? "Undo Needs Attention" : "Conversion Needs Attention",
             body: message, tab: manual ? "manual" : (undo ? "history" : "automatic"))
    }

    func flushCompletions() {
        completionTask?.cancel()
        completionTask = nil
        guard completedCount > 0 else { return }
        let count = completedCount
        var body = completedNames.joined(separator: "\n")
        if count > completedNames.count { body += "\nAnd \(count - completedNames.count) more files." }
        completedCount = 0
        completedNames.removeAll(keepingCapacity: true)
        post(title: count == 1 ? "Conversion Complete" : "\(count) Conversions Complete", body: body, tab: "history")
    }

    func stop() {
        stopped = true
        discardCompletions()
    }

    private func discardCompletions() {
        notificationGeneration = UUID()
        completionTask?.cancel()
        completionTask = nil
        completedCount = 0
        completedNames.removeAll(keepingCapacity: true)
    }

    @discardableResult
    private func post(title: String, body: String, tab: String) -> Task<Void, Never>? {
        guard showNotifications, !stopped else { return nil }
        let generation = notificationGeneration
        return Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let authorization = await readAuthorization()
            guard generation == notificationGeneration, showNotifications, !stopped, !Task.isCancelled else { return }
            notificationAuthorization = authorization
            guard authorization == .authorized || authorization == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = "conversions"
            content.userInfo = ["tab": tab]
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do { try await deliver(request) }
            catch {
                if generation == notificationGeneration {
                    notificationError = "A conversion notification could not be delivered: \(error.localizedDescription)"
                }
            }
        }
    }
}
