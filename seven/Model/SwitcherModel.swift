import Foundation
import SwiftUI

enum SwitcherMode: String, CaseIterable {
    case text
    case notes

    init(savedValue: String?) {
        // Preserve the second slot for users who selected the old placeholder.
        self = savedValue == "image" ? .notes : Self(rawValue: savedValue ?? "") ?? .text
    }

    var title: String { self == .text ? "Launcher" : "Notes" }
    var other: Self { self == .text ? .notes : .text }
    var color: Color { Self.tint(at: self == .text ? 0 : 1) }
    var highlight: Color { Self.glow(at: self == .text ? 0 : 1) }

    static func tint(at progress: CGFloat) -> Color {
        interpolate(from: (0.065, 0.46, 0.65), to: (0.70, 0.19, 0.035), progress: progress)
    }

    static func glow(at progress: CGFloat) -> Color {
        interpolate(from: (0.56, 0.92, 1), to: (1, 0.73, 0.48), progress: progress)
    }

    private static func interpolate(from: (Double, Double, Double), to: (Double, Double, Double), progress: CGFloat) -> Color {
        let t = Double(min(max(progress, 0), 1))
        return Color(red: from.0 + (to.0 - from.0) * t,
                     green: from.1 + (to.1 - from.1) * t,
                     blue: from.2 + (to.2 - from.2) * t)
    }
}

/// A deliberate movement selects a mode; trackpad momentum never changes it.
/// Direction reversals start a fresh accumulation instead of fighting old deltas.
struct ScrollSelector {
    private(set) var accumulatedDelta: Double = 0
    private var previousTime: TimeInterval = 0

    mutating func reset() {
        accumulatedDelta = 0
        previousTime = 0
    }

    mutating func selection(
        delta: Double,
        precise: Bool,
        momentum: Bool,
        timestamp: TimeInterval
    ) -> SwitcherMode? {
        guard !momentum, delta.isFinite, delta != 0 else { return nil }
        if timestamp - previousTime > 0.25 || delta * accumulatedDelta < 0 {
            accumulatedDelta = 0
        }
        previousTime = timestamp
        accumulatedDelta += delta
        guard abs(accumulatedDelta) >= (precise ? 7 : 0.1) else { return nil }
        let mode: SwitcherMode = accumulatedDelta > 0 ? .text : .notes
        accumulatedDelta = 0
        return mode
    }
}

struct SwitcherSession {
    enum Activation { case holdOption, toggle }

    private(set) var isVisible = false
    private(set) var mode: SwitcherMode
    private(set) var activation: Activation = .holdOption
    private var originalMode: SwitcherMode

    init(mode: SwitcherMode) {
        self.mode = mode
        originalMode = mode
    }

    mutating func open(activation: Activation) {
        guard !isVisible else { return }
        originalMode = mode
        self.activation = activation
        isVisible = true
    }

    mutating func select(_ mode: SwitcherMode) { self.mode = mode }

    mutating func close(cancelled: Bool = false) {
        if cancelled { mode = originalMode }
        isVisible = false
    }

    func shouldDismiss(isOptionDown: Bool) -> Bool {
        isVisible && activation == .holdOption && !isOptionDown
    }
}

@MainActor
final class SwitcherAppearance: ObservableObject {
    @Published var mode: SwitcherMode
    @Published var pillOnLeft = true
    @Published var pillVerticalOffset: CGFloat = 0

    init(mode: SwitcherMode) { self.mode = mode }
}
