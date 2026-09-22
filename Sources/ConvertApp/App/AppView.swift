import SwiftUI

struct AppView: View {
    @Bindable var model: ConversionModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $model.tab) {
            AutomaticView(model: model).tabItem { Label("Automatic", systemImage: "folder.badge.gearshape") }
                .tag(ConversionModel.Tab.automatic)
            ConversionView(model: model).tabItem { Label("Manual", systemImage: "doc") }
                .tag(ConversionModel.Tab.manual)
            HistoryView(model: model).tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(ConversionModel.Tab.history)
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(ConversionModel.Tab.settings)
        }
        .frame(minWidth: 640, minHeight: 570)
        .task {
            let openWindow = openWindow
            delegate.connect(model: model) { openWindow(id: "conversion"); NSApp.activate() }
            async let refresh: Void = model.appSettings.refresh()
            await model.load()
            await refresh
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    async let settings: Void = model.appSettings.refresh()
                    await model.refreshDiskAccess()
                    await settings
                }
            }
        }
        .alert("Conversion needs attention", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
