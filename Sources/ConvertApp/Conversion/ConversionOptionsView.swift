import ConversionCore
import SwiftUI

struct ConversionOptionsView: View {
    enum Scope {
        case all
        case performance
        case images
        case media
        case documents
        case data
        case archivesAndModels
    }

    @Binding var settings: ConversionSettings
    var targetID = ""
    var source: URL?
    var sourceID: String?
    var embeddedSubtitleTracks: [EmbeddedSubtitleTrack] = []
    var showPerformance = true
    var category: String?
    var sourceCategory: String?
    var scope = Scope.all

    var sourceFormatID: String? { sourceID ?? source?.pathExtension.lowercased() }
    var showsPostScriptOptions: Bool {
        category == nil || ["eps", "postscript"].contains(targetID)
            || (targetID == "pdf" && ["postscript", "eps", "epsf", "epsi", "ps"].contains(sourceFormatID ?? ""))
    }
    var showsSVGTracing: Bool {
        category == nil || (sourceCategory == "image" && ["svg", "svgz"].contains(targetID)
            && !["svg", "svgz"].contains(sourceFormatID ?? ""))
    }
    var showsSVGSize: Bool {
        category == nil || (["svg", "svgz"].contains(sourceFormatID ?? "")
            && category != "archive" && !["svg", "svgz"].contains(targetID))
    }
    var showsTextRecognition: Bool {
        category == nil || (category == "subtitle" && sourceCategory == "video")
            || (category == "document" && targetID != "pptx" && (sourceCategory == "image" || sourceFormatID == "pdf"))
    }
    var showsPDFPages: Bool {
        category == nil || (sourceFormatID == "pdf"
            && category != "archive" && !["pdf", "eps", "postscript"].contains(targetID))
    }
    var showsVideoOptions: Bool {
        category == nil || (category == "video" && sourceCategory != "audio")
    }


    var body: some View {
        switch scope {
        case .all:
            performanceOptionsSection
            imageOptionsSections
            mediaOptionsSections
            videoAnimationOptionsSection
            dataOptionsSections
            postScriptOptionsSection
            vectorOptionsSections
            documentOptionsSections
        case .performance:
            performanceOptionsSection
        case .images:
            imageOptionsSections
            vectorOptionsSections
        case .media:
            mediaOptionsSections
            videoAnimationOptionsSection
            subtitleOptionsSection
        case .documents:
            postScriptOptionsSection
            documentOptionsSections
            emailOptionsSection
        case .data:
            configurationOptionsSection
            spreadsheetOptionsSection
        case .archivesAndModels:
            archiveOptionsSection
            modelOptionsSection
        }
    }
}
