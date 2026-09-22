import SwiftUI

@main
struct AllomerApp: App {
    @State private var model = ConversionModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Allomer", id: "conversion") {
            AppView(model: model, delegate: delegate)
        }
        .defaultSize(width: 700, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose File…") { model.tab = .manual; model.chooseFile() }
                    .keyboardShortcut("o")
                    .disabled(model.busy || model.cleaningBackups || model.engine == nil)
            }
        }
        MenuBarExtra {
            ConversionMenu(model: model)
        } label: {
            AllomerMenuBarIcon()
                .accessibilityLabel("Allomer")
        }
    }
}
