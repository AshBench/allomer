import SwiftUI

struct ConversionMenu: View {
    let model: ConversionModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.monitoring ? "Automatic conversion is on" : "Automatic conversion is paused")
        if !model.approvals.isEmpty {
            Button(model.approvals.count == 1 ? "Review 1 Pending Conversion…"
                : "Review \(model.approvals.count) Pending Conversions…") {
                model.tab = .automatic
                openWindow(id: "conversion")
                NSApp.activate()
            }
        }
        Button(model.monitoring ? "Pause Automatic Conversion" : "Resume Automatic Conversion") {
            model.setMonitoring(!model.monitoring)
        }.disabled(!model.canMonitor || model.engine == nil || model.checkingDiskAccess)
        Button("Open Allomer…") {
            model.tab = .automatic
            openWindow(id: "conversion")
            NSApp.activate()
        }
        Button("Conversion History…") {
            model.tab = .history
            openWindow(id: "conversion")
            NSApp.activate()
        }
        Button("Convert a File Manually…") {
            model.tab = .manual
            openWindow(id: "conversion")
            NSApp.activate()
        }
        if model.canCancel { Button("Cancel Conversion") { model.cancel() } }
        Divider()
        Button("Quit Allomer") { NSApp.terminate(nil) }
    }
}
