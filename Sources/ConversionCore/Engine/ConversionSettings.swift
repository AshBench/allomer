public struct ConversionSettings: Codable, Equatable, Sendable {
    public var imageOptions: ImageOptions
    public var documentOptions: DocumentOptions
    public var mediaOptions: MediaOptions
    public var subtitleOptions: SubtitleOptions
    public var configOptions: ConfigOptions
    public var archiveOptions: ArchiveOptions
    public var spreadsheetOptions: SpreadsheetOptions
    public var emailOptions: EmailOptions
    public var modelOptions: ModelOptions
    public var postScriptOptions: PostScriptOptions
    public var pdfOptions: PDFOptions

    public init(imageOptions: ImageOptions = ImageOptions(),
                documentOptions: DocumentOptions = DocumentOptions(),
                mediaOptions: MediaOptions = MediaOptions(),
                subtitleOptions: SubtitleOptions = SubtitleOptions(),
                configOptions: ConfigOptions = ConfigOptions(),
                archiveOptions: ArchiveOptions = ArchiveOptions(),
                spreadsheetOptions: SpreadsheetOptions = SpreadsheetOptions(),
                emailOptions: EmailOptions = EmailOptions(),
                modelOptions: ModelOptions = ModelOptions(),
                postScriptOptions: PostScriptOptions = PostScriptOptions(),
                pdfOptions: PDFOptions = PDFOptions()) {
        self.imageOptions = imageOptions
        self.documentOptions = documentOptions
        self.mediaOptions = mediaOptions
        self.subtitleOptions = subtitleOptions
        self.configOptions = configOptions
        self.archiveOptions = archiveOptions
        self.spreadsheetOptions = spreadsheetOptions
        self.emailOptions = emailOptions
        self.modelOptions = modelOptions
        self.postScriptOptions = postScriptOptions
        self.pdfOptions = pdfOptions
    }
}

public struct ConversionRule: Codable, Equatable, Identifiable, Sendable {
    public var sourceID: String
    public var targetID: String
    public var action: AutomaticConversionAction
    public var settings: ConversionSettings?
    public var keepOriginal: Bool?
    public var stageOverrides: [ConversionStageOverride]?
    public var id: String { sourceID + ":" + targetID }

    public init(sourceID: String, targetID: String, action: AutomaticConversionAction,
                settings: ConversionSettings? = nil, keepOriginal: Bool? = nil,
                stageOverrides: [ConversionStageOverride]? = nil) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.action = action
        self.settings = settings
        self.keepOriginal = keepOriginal
        self.stageOverrides = stageOverrides
    }
}

public struct ConversionStageOverride: Codable, Equatable, Identifiable, Sendable {
    public let sourceID: String?
    public let targetID: String
    public var settings: ConversionSettings
    public var id: String { (sourceID ?? "file") + ":" + targetID }

    public init(sourceID: String?, targetID: String, settings: ConversionSettings) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.settings = settings
    }
}
