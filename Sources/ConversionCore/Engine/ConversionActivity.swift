import Foundation

public struct ConversionActivity: Codable, Identifiable, Sendable {
    public enum State: String, Codable, CaseIterable, Sendable {
        case queued, waiting, running, completed, failed, cancelled

        public var title: String {
            switch self {
            case .queued: "Queued"
            case .waiting: "Waiting for a decision"
            case .running: "Converting"
            case .completed: "Completed"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
        }
        public var isFinished: Bool { self == .completed || self == .failed || self == .cancelled }
    }

    public struct Configuration: Codable, Sendable {
        public let outputURL: URL
        public let settings: ConversionSettings
        public let keepOriginal: Bool
        public var steps: [Step]?

        public init(outputURL: URL, settings: ConversionSettings, keepOriginal: Bool) {
            self.outputURL = outputURL
            self.settings = settings
            self.keepOriginal = keepOriginal
        }

        public mutating func record(_ step: Step) {
            if let index = steps?.firstIndex(where: { $0.id == step.id }) { steps?[index] = step }
            else { steps = (steps ?? []) + [step] }
        }
    }

    public struct Step: Codable, Identifiable, Sendable {
        public let id: Int
        public let count: Int
        public let sourceID: String?
        public let targetID: String
        public let settings: ConversionSettings?
        public var state: State = .running
        public var message: String?

        public init(index: Int, count: Int, sourceID: String?, targetID: String, settings: ConversionSettings?) {
            id = index
            self.count = count
            self.sourceID = sourceID
            self.targetID = targetID
            self.settings = settings
        }
    }

    public mutating func record(_ step: Step, for output: URL) {
        guard let index = configurations.firstIndex(where: { $0.outputURL == output }) else { return }
        configurations[index].record(step)
    }

    public let id: UUID
    public let date: Date
    public let originalURL: URL
    public let requestedURL: URL
    public var outputURLs: [URL]
    public var state: State
    public var sourceID: String?
    public var configurations: [Configuration] = []
    public var recordID: UUID?
    public var message: String?

    public init(id: UUID = UUID(), date: Date = Date(), originalURL: URL, requestedURL: URL,
                outputURLs: [URL], state: State, sourceID: String? = nil, recordID: UUID? = nil) {
        self.id = id
        self.date = date
        self.originalURL = originalURL
        self.requestedURL = requestedURL
        self.outputURLs = outputURLs
        self.state = state
        self.sourceID = sourceID
        self.recordID = recordID
    }
}
