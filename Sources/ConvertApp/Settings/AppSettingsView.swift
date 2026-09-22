import ServiceManagement
import SwiftUI

struct AppSettingsView: View {
    let settings: AppSettings

    var body: some View {
        Section("General") {
            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { enabled in Task { await settings.setLaunchAtLogin(enabled) } }
            )).disabled(settings.changingLogin)
                .accessibilityLabel("Launch at login")
            Text(settings.loginDescription).font(.caption).foregroundStyle(.secondary)
            if let error = settings.loginError { Text(error).font(.caption).foregroundStyle(.red) }
            Button("Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }

            Toggle("Show notifications after conversion", isOn: Binding(
                get: { settings.showNotifications },
                set: { enabled in Task { await settings.setNotifications(enabled) } }
            )).disabled(settings.changingNotifications)
                .accessibilityLabel("Show notifications after conversion")
            Text(settings.notificationDescription).font(.caption).foregroundStyle(.secondary)
            if let error = settings.notificationError { Text(error).font(.caption).foregroundStyle(.red) }
            Button("Notification Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
        }
    }
}
