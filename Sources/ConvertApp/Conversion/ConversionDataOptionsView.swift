import ConversionCore
import SwiftUI

extension ConversionOptionsView {
    @ViewBuilder var dataOptionsSections: some View {
        subtitleOptionsSection
        configurationOptionsSection
        archiveOptionsSection
        spreadsheetOptionsSection
        emailOptionsSection
        modelOptionsSection
    }

    @ViewBuilder var subtitleOptionsSection: some View {
        if category == nil || category == "subtitle" {
            Section("Subtitles") {
                if category == nil || sourceCategory == "video" {
                    if category != nil, !embeddedSubtitleTracks.isEmpty {
                        Picker("Embedded subtitle track", selection: $settings.subtitleOptions.embeddedTrack) {
                            Text("First subtitle track").tag(nil as Int?)
                            if let selected = settings.subtitleOptions.embeddedTrack,
                               !embeddedSubtitleTracks.contains(where: { $0.id == selected }) {
                                Text("Track \(selected) (unavailable)").tag(Optional(selected))
                            }
                            ForEach(embeddedSubtitleTracks) { track in
                                Text((["Track \(track.id)", track.language, track.title, track.codec].compactMap { $0 }).joined(separator: " · "))
                                    .tag(Optional(track.id))
                            }
                        }.accessibilityLabel("Embedded subtitle track")
                    } else {
                        Toggle("Use the first embedded subtitle track", isOn: Binding(
                            get: { settings.subtitleOptions.embeddedTrack == nil },
                            set: { settings.subtitleOptions.embeddedTrack = $0 ? nil : 1 })).accessibilityLabel("Use the first embedded subtitle track")
                        if settings.subtitleOptions.embeddedTrack != nil {
                            Stepper("Subtitle track: \(settings.subtitleOptions.embeddedTrack ?? 1)", value: Binding(
                                get: { settings.subtitleOptions.embeddedTrack ?? 1 },
                                set: { settings.subtitleOptions.embeddedTrack = $0 }), in: 1...256).accessibilityLabel("Subtitle track")
                        }
                    }
                    Text("Track numbers follow the file's subtitle order. Audio and video are omitted from the extracted file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("MicroDVD output frame rate", value: $settings.subtitleOptions.frameRate, format: .number).accessibilityLabel("MicroDVD output frame rate")
                Toggle("Set source frame rate when its header is missing", isOn: Binding(
                    get: { settings.subtitleOptions.sourceFrameRate != nil },
                    set: { settings.subtitleOptions.sourceFrameRate = $0 ? 25 : nil })).accessibilityLabel("Set source frame rate when its header is missing")
                if settings.subtitleOptions.sourceFrameRate != nil {
                    TextField("MicroDVD source frame rate", value: Binding(
                        get: { settings.subtitleOptions.sourceFrameRate ?? 25 },
                        set: { settings.subtitleOptions.sourceFrameRate = $0 }), format: .number).accessibilityLabel("MicroDVD source frame rate")
                }
                Toggle("Remove subtitle formatting", isOn: $settings.subtitleOptions.removeFormatting).accessibilityLabel("Remove subtitle formatting")
            }
        }
    }

    @ViewBuilder var configurationOptionsSection: some View {
        if category == nil || category == "config" || sourceCategory == "config" {
            Section("Configuration files") {
                Toggle("Pretty print output", isOn: $settings.configOptions.prettyPrint).accessibilityLabel("Pretty print output")
                Toggle("Infer numbers and booleans from strings", isOn: $settings.configOptions.inferStringTypes).accessibilityLabel("Infer numbers and booleans from strings")
                Toggle("Write binary plist files", isOn: $settings.configOptions.binaryPlist).accessibilityLabel("Write binary plist files")
                Text("Type inference can change text values. Leave it off to keep their types.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder var archiveOptionsSection: some View {
        if category == nil || category == "archive" {
            Section("Archives") {
                Picker("Compression", selection: $settings.archiveOptions.compression) {
                    Text("Fast").tag(ArchiveOptions.Compression.fast)
                    Text("Balanced").tag(ArchiveOptions.Compression.balanced)
                    Text("Small file").tag(ArchiveOptions.Compression.small)
                }.accessibilityLabel("Compression")
                Toggle("Include a top-level folder", isOn: $settings.archiveOptions.includeTopLevelFolder).accessibilityLabel("Include a top-level folder")
                Text("GZIP stores one file. Use compressed TAR for folders or multiple files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder var spreadsheetOptionsSection: some View {
        if category == nil || category == "spreadsheet" || category == "config"
            || sourceCategory == "spreadsheet" || sourceCategory == "config" {
            Section("Spreadsheets") {
                Picker("CSV delimiter", selection: $settings.spreadsheetOptions.csvDelimiter) {
                    Text("Comma").tag(SpreadsheetOptions.Delimiter.comma)
                    Text("Semicolon").tag(SpreadsheetOptions.Delimiter.semicolon)
                    Text("Tab").tag(SpreadsheetOptions.Delimiter.tab)
                    Text("Pipe").tag(SpreadsheetOptions.Delimiter.pipe)
                }.accessibilityLabel("CSV delimiter")
                TextField("Workbook sheet number", value: Binding(
                    get: { min(9_999, max(0, settings.spreadsheetOptions.sheetIndex)) + 1 },
                    set: { settings.spreadsheetOptions.sheetIndex = min(10_000, max(1, $0)) - 1 }), format: .number).accessibilityLabel("Workbook sheet number")
                Text("The first sheet is 1. CSV and TSV keep every data row. TSV always uses tabs.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Use the first row as JSON column names", isOn: $settings.spreadsheetOptions.csvHeaderRow).accessibilityLabel("Use the first row as JSON column names")
                Text("Off names columns by position and keeps every row as a record. CSV and TSV output always keep every row.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Include column headers when reading XML tables", isOn: $settings.spreadsheetOptions.xmlHeaderRow).accessibilityLabel("Include column headers when reading XML tables")
                Toggle("Infer table numbers and booleans", isOn: $settings.spreadsheetOptions.inferTypes).accessibilityLabel("Infer table numbers and booleans")
                Text("Inference applies to XML table values and JSON record output. Leading-zero codes stay text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder var emailOptionsSection: some View {
        if category == nil || sourceCategory == "email" {
            Section("Email") {
                Toggle("Include headers in rendered documents", isOn: $settings.emailOptions.includeHeaders).accessibilityLabel("Include headers in rendered documents")
            }
        }
    }

    @ViewBuilder var modelOptionsSection: some View {
        if category == nil || category == "model" || sourceCategory == "model" {
            Section("3D models") {
                Toggle("Write binary PLY", isOn: $settings.modelOptions.binaryPLY).accessibilityLabel("Write binary PLY")
                Toggle("Write binary STL", isOn: $settings.modelOptions.binarySTL).accessibilityLabel("Write binary STL")
                Toggle("Embed textures in GLB and FBX", isOn: $settings.modelOptions.embedTextures).accessibilityLabel("Embed textures in GLB and FBX")
                Text("Separate textures stay in a folder beside the model. Keep that folder with the file. USDZ includes its textures. STL stores the surface only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
