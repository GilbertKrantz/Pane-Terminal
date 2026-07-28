import Combine
import Foundation

@MainActor
final class FocusCoordinator: ObservableObject {
    @Published private(set) var target: PaneFocusTarget = .none
    @Published private(set) var generation: UInt64 = 0

    func request(_ target: PaneFocusTarget) {
        generation &+= 1
        self.target = target
    }

    func isCurrent(_ target: PaneFocusTarget, generation: UInt64) -> Bool {
        self.target == target && self.generation == generation
    }
}
