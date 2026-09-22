import ConversionCore
import SwiftUI

extension ConversionOptionsView {
    @ViewBuilder var postScriptOptionsSection: some View {
        if showsPostScriptOptions {
            Section("PDF and PostScript") {
                Picker("PostScript language level", selection: $settings.postScriptOptions.languageLevel) {
                    Text("Level 2").tag(2)
                    Text("Level 3").tag(3)
                }.accessibilityLabel("PostScript language level")
                Stepper("EPS page: \(settings.postScriptOptions.epsPage)", value: $settings.postScriptOptions.epsPage, in: 1...10_000).accessibilityLabel("EPS page")
                Toggle("Crop EPS to its bounds when making PDF", isOn: $settings.postScriptOptions.cropEPS).accessibilityLabel("Crop EPS to its bounds when making PDF")
                Picker("PDF quality from PostScript or EPS", selection: $settings.postScriptOptions.pdfPreset) {
                    ForEach(PostScriptOptions.PDFPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue.capitalized).tag(preset)
                    }
                }.accessibilityLabel("PDF quality from PostScript or EPS")
                Text("Level 3 can compress images more efficiently and flattens transparent pages at 300 DPI. PostScript keeps all pages. EPS uses the selected page. Screen and Ebook reduce image resolution when making PDF.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder var documentOptionsSections: some View {
        if showsTextRecognition {
            Section("Text recognition") {
                Picker("Text language", selection: $settings.pdfOptions.ocrLanguage) {
                    Text("Automatic").tag("auto")
                    ForEach(PDFOptions.ocrLanguages, id: \.self) { language in
                        Text(Locale.current.localizedString(forIdentifier: language) ?? language).tag(language)
                    }
                    if settings.pdfOptions.ocrLanguage != "auto" && !PDFOptions.ocrLanguages.contains(settings.pdfOptions.ocrLanguage) {
                        Text("Unavailable: \(settings.pdfOptions.ocrLanguage)").tag(settings.pdfOptions.ocrLanguage)
                    }
                }.accessibilityLabel("Text language")
                .disabled(category != nil && ((targetID == "pdf" && !settings.pdfOptions.imageOCR)
                    || (sourceFormatID == "pdf" && !settings.pdfOptions.recognizeScans)))
                Text("Available languages come from macOS. Automatic detects the text language.")
                    .font(.caption).foregroundStyle(.secondary)
                if category == "subtitle" {
                    Text("Picture subtitles use text recognition. Check the result for reading errors.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if category == nil || (targetID == "pdf" && sourceCategory == "image") {
            Section("Image to PDF") {
                Toggle("Make image text searchable", isOn: $settings.pdfOptions.imageOCR).accessibilityLabel("Make image text searchable")
                Text("Recognizes text locally. Check the result for reading errors.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if showsPDFPages {
            Section("PDF pages") {
                if category == nil || category == "image" {
                    Stepper("Image or SVG page: \(settings.pdfOptions.page)", value: $settings.pdfOptions.page, in: 1...10_000).accessibilityLabel("Image or SVG page")
                }
                if category == nil || (category == "image" && targetID != "svg") {
                    TextField("Image resolution (DPI)", value: $settings.pdfOptions.resolution, format: .number).accessibilityLabel("Image resolution (DPI)")
                }
                if category == nil || targetID == "pptx" {
                    TextField("Slide resolution (DPI)", value: $settings.pdfOptions.slideResolution, format: .number).accessibilityLabel("Slide resolution (DPI)")
                }
                if category == nil || category != "image" {
                    TextField("Document pages", text: $settings.pdfOptions.pages).accessibilityLabel("Document pages")
                    if category == nil || targetID != "pptx" {
                        Toggle("Recognize scanned PDF text", isOn: $settings.pdfOptions.recognizeScans).accessibilityLabel("Recognize scanned PDF text")
                        Text("Skips pages that already have selectable text.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Use all or page ranges such as 1-3,5. Images use 72–1200 DPI.")
                    .font(.caption).foregroundStyle(.secondary)
                if category == nil || targetID == "pptx" {
                    Text("PowerPoint stores one page image per slide. Text and links are part of the image. Mixed page sizes fit within the first selected page's slide size.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if category != "image" {
                    Text("Document conversion reflows text; diagrams and complex layout can be lost.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if category == nil || (targetID != "pptx" && sourceFormatID != "pptx"
            && !["image", "audio", "video", "subtitle", "config", "archive", "spreadsheet", "email", "model"].contains(category ?? "")) {
            Section("Documents") {
                if category == nil || sourceFormatID == "markdown" || targetID == "markdown" {
                    Picker("Markdown flavor", selection: $settings.documentOptions.markdownFlavor) {
                        ForEach(DocumentOptions.MarkdownFlavor.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityLabel("Markdown flavor")
                    Text("Applies when reading or writing Markdown.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Complete document", isOn: $settings.documentOptions.standalone).accessibilityLabel("Complete document")
                    .disabled(category != nil && targetID == "pdf")
                Toggle("Highlight code syntax", isOn: $settings.documentOptions.syntaxHighlighting).accessibilityLabel("Highlight code syntax")
            }
        }
        if category == nil || (targetID == "pdf" && sourceCategory != "image"
            && !["pdf", "postscript", "eps", "pptx"].contains(sourceFormatID ?? "")) {
            Section("Document to PDF") {
                // Word documents carry their own page setup, so the paper size is not offered for them.
                if category == nil || sourceFormatID != "docx" {
                    Picker("Page size", selection: $settings.documentOptions.pdfPageSize) {
                        Text("A4").tag("a4")
                        Text("US Letter").tag("letter")
                    }.accessibilityLabel("Page size")
                }
                if category == nil || sourceFormatID == "markdown" {
                    Picker("Markdown template", selection: $settings.documentOptions.pdfTemplate) {
                        Text("GitHub").tag("github")
                        Text("Minimal / Print").tag("minimal")
                    }.accessibilityLabel("Markdown template")
                }
                if category == nil || sourceFormatID == "docx" {
                    Text("Word documents print at their own page size, orientation, and margins. A page size chosen here applies to other documents. A Word file this conversion cannot lay out faithfully is refused with a reason, and the original is left as it is.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if category == nil || sourceFormatID != "docx" {
                    Text("Local HTML printing uses the selected paper size. Document layout can change through HTML conversion.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
