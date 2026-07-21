import Foundation

enum PredictionKind: String, Codable, Sendable, Hashable {
    case commandCompletion
    case nextCommand
    case naturalLanguagePrompt
    case correctiveAction
}

enum PredictionSource: String, Codable, Sendable {
    case prefixHistory
    case directoryHistory
    case transitionModel
    case semanticRetrieval
    case localLanguageModel
}

enum PredictionAction: String, Codable, Sendable {
    case accepted
    case partiallyAccepted
    case dismissed
    case ignored
    case replaced
}

struct PredictionRequest: Sendable {
    let snapshot: RuntimeSnapshot
    let typedPrefix: String
    let maximumResults: Int
    let allowedKinds: Set<PredictionKind>
}

struct Prediction: Identifiable, Sendable {
    let id: UUID
    let text: String
    let kind: PredictionKind
    let confidence: Double
    let source: PredictionSource
}

protocol PromptPredicting: Sendable {
    func predict(request: PredictionRequest) async throws -> [Prediction]
    func cancelPendingPredictions() async
}
