import SwiftUI

struct SettingsView: View {
    @Bindable var model: ConversionModel
    @State private var selection = Page.general

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section("Application") {
                    row(.general)
                    row(.backups)
                }
                Section("Conversion Defaults") {
                    row(.performance)
                    row(.images)
                    row(.media)
                    row(.documents)
                    row(.data)
                    row(.archivesAndModels)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 210)

            Divider()

            VStack(spacing: 0) {
                HStack {
                    Text(selection.title)
                        .font(.title2.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)

                Divider()

                Form {
                    pageContents
                }
                .formStyle(.grouped)
                .id(selection)
            }
        }
    }

    private func row(_ page: Page) -> some View {
        Label(page.title, systemImage: page.symbol)
            .tag(page)
    }

    @ViewBuilder private var pageContents: some View {
        switch selection {
        case .general:
            AppSettingsView(settings: model.appSettings)
        case .backups:
            BackupSettingsView(model: model)
                .disabled(model.engine == nil)
        case .performance:
            conversionOptions(.performance)
        case .images:
            conversionOptions(.images)
        case .media:
            conversionOptions(.media)
        case .documents:
            conversionOptions(.documents)
        case .data:
            conversionOptions(.data)
        case .archivesAndModels:
            conversionOptions(.archivesAndModels)
        }
    }

    private func conversionOptions(_ scope: ConversionOptionsView.Scope) -> some View {
        ConversionOptionsView(settings: $model.settings, scope: scope)
            .disabled(model.engine == nil)
    }
}

private extension SettingsView {
    enum Page: Hashable {
        case general
        case backups
        case performance
        case images
        case media
        case documents
        case data
        case archivesAndModels

        var title: String {
            switch self {
            case .general: "General"
            case .backups: "Backups"
            case .performance: "Performance"
            case .images: "Images & Graphics"
            case .media: "Audio & Video"
            case .documents: "Documents & OCR"
            case .data: "Data & Tables"
            case .archivesAndModels: "Archives & 3D"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .backups: "clock.arrow.circlepath"
            case .performance: "cpu"
            case .images: "photo.on.rectangle.angled"
            case .media: "film"
            case .documents: "doc.richtext"
            case .data: "tablecells"
            case .archivesAndModels: "archivebox"
            }
        }
    }
}
