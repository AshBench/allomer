import Foundation

public enum CPUProfile: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    public func limits(activeCores: Int = ProcessInfo.processInfo.activeProcessorCount)
        -> (jobs: Int, encoderThreads: Int) {
        let spare = max(1, activeCores) - 1
        switch self {
        case .low: return (1, 1)
        case .medium: return (max(1, min(spare, 2)), max(1, min(activeCores, 2)))
        case .high: return (max(1, min(spare, 3)), max(1, min(spare, 4)))
        }
    }
}
