import SwiftUI

/// Coordinates are in points, matching the approximately 24 × 56 pt reference.
struct SwitcherHUD: View {
    @ObservedObject var appearance: SwitcherAppearance

    static let size = CGSize(width: 122, height: 90)
    static let cursorAnchor = CGPoint(x: 61, y: 45)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ModePill(mode: appearance.mode)
                .position(x: appearance.pillOnLeft ? 29 : 93, y: 45 + appearance.pillVerticalOffset)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mode switcher")
        .accessibilityValue(appearance.mode.title)
    }
}

/// The reference has a subtle inward waist on the cursor side, rather than a
/// regular capsule. Keep this vector so the HUD stays crisp on Retina displays.
struct CurvedPill: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 56
        return Path { p in
            p.move(to: CGPoint(x: 11, y: 0))
            p.addCurve(to: CGPoint(x: 21, y: 10), control1: CGPoint(x: 16, y: -0.2), control2: CGPoint(x: 19, y: 3))
            p.addCurve(to: CGPoint(x: 21, y: 45), control1: CGPoint(x: 25, y: 21), control2: CGPoint(x: 25, y: 35))
            p.addCurve(to: CGPoint(x: 11, y: 56), control1: CGPoint(x: 19, y: 52), control2: CGPoint(x: 17, y: 56))
            p.addCurve(to: CGPoint(x: 1, y: 43), control1: CGPoint(x: 3, y: 56), control2: CGPoint(x: -1, y: 51))
            p.addCurve(to: CGPoint(x: 1, y: 13), control1: CGPoint(x: 4, y: 33), control2: CGPoint(x: 4, y: 24))
            p.addCurve(to: CGPoint(x: 11, y: 0), control1: CGPoint(x: -1, y: 5), control2: CGPoint(x: 3, y: 0))
            p.closeSubpath()
        }.applying(CGAffineTransform(scaleX: sx, y: sy))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

struct ModePill: View {
    let mode: SwitcherMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PillArtwork(progress: mode == .text ? 0 : 1)
            .animation(reduceMotion ? .linear(duration: 0.12) : .spring(response: 0.40, dampingFraction: 0.72), value: mode)
    }
}

/// One animated value keeps geometry, reflections, and color in sync, including
/// when scrolling reverses before the previous transition has finished.
struct PillArtwork: View, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private var blend: CGFloat { min(max(progress, 0), 1) }

    var body: some View {
        let tint = SwitcherMode.tint(at: blend)
        let highlight = SwitcherMode.glow(at: blend)
        let lens = SwimmingLens(progress: progress)
        let top = UnitPoint(x: 0.5, y: (lens.centerY - lens.length / 2) / 56)
        let bottom = UnitPoint(x: 0.5, y: (lens.centerY + lens.length / 2) / 56)

        ZStack(alignment: .top) {
            CurvedPill()
                .fill(LinearGradient(colors: [tint, tint.opacity(0.96)], startPoint: .top, endPoint: .bottom))
                .overlay {
                    CurvedPill().strokeBorderLike(Color.white.opacity(0.11), width: 0.65)
                }
                .shadow(color: tint.opacity(0.25), radius: 2)
                .shadow(color: .black.opacity(0.24), radius: 3, y: 1)

            // Every part of the lens is warped, including its luminous rim.
            lens
                .fill(
                    LinearGradient(colors: [highlight.opacity(0.50), tint.opacity(0.12), highlight.opacity(0.26)], startPoint: top, endPoint: bottom)
                )
                .overlay {
                    lens.stroke(
                        LinearGradient(colors: [.white.opacity(0.95), highlight.opacity(0.65), .white.opacity(0.28)], startPoint: top, endPoint: bottom),
                        lineWidth: 1.15
                    )
                }
                .overlay {
                    lens.stroke(
                        LinearGradient(colors: [.white.opacity(0.9), .clear, .clear], startPoint: top, endPoint: bottom),
                        lineWidth: 0.8
                    )
                    .blur(radius: 0.55)
                    .offset(x: -0.25, y: -0.45)
                }
                .shadow(color: highlight.opacity(0.6), radius: 0.9)
                .clipShape(CurvedPill())

            CurvedSwitcherSymbol(systemName: "command", centerY: 15)
                .foregroundStyle(.white.opacity(1 - 0.6 * blend))
                .shadow(color: highlight.opacity(0.9 * (1 - blend)), radius: 1.6)

            CurvedSwitcherSymbol(systemName: "tornado", centerY: 41)
                .foregroundStyle(.white.opacity(0.4 + 0.6 * blend))
                .shadow(color: highlight.opacity(0.9 * blend), radius: 1.6)
        }
        .frame(width: 24, height: 56)
    }
}

/// Warp each symbol's strokes onto the lens track, retaining the native glyph.
private struct CurvedSwitcherSymbol: View {
    let systemName: String
    let centerY: CGFloat

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .position(x: 12, y: centerY)
            .frame(width: 24, height: 56)
            .distortionEffect(CurvedTrack.symbolWarp, maxSampleOffset: CGSize(width: 4, height: 4))
    }
}

/// Map the lens outline onto the track's centerline and its local normal.
/// Unlike a rotated capsule, both sides bend continuously through the waist.
struct SwimmingLens: Shape {
    var progress: CGFloat

    private var travel: CGFloat { min(max(progress, -0.045), 1.045) }
    private var squeeze: CGFloat { sin(.pi * min(max(travel, 0), 1)) }
    var centerY: CGFloat { 15.5 + 25 * travel }
    var length: CGFloat { 23.5 + 5 * squeeze }
    // This includes room for the 1.15 pt rim and its glow at spring overshoot.
    private var radius: CGFloat { (15.5 - 2 * squeeze) / 2 }

    func path(in rect: CGRect) -> Path {
        let straightHalf = length / 2 - radius
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CurvedTrack.point(offsetX: x, at: centerY + y, in: rect)
        }

        var path = Path()
        for index in 0...32 {
            let angle = .pi + CGFloat(index) / 32 * .pi
            let p = point(radius * cos(angle), -straightHalf + radius * sin(angle))
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        // Sampling the long sides is essential; a straight segment between
        // the end caps would cut across the curve rather than bend with it.
        for index in 1...16 {
            path.addLine(to: point(radius, -straightHalf + 2 * straightHalf * CGFloat(index) / 16))
        }
        for index in 1...32 {
            let angle = CGFloat(index) / 32 * .pi
            path.addLine(to: point(radius * cos(angle), straightHalf + radius * sin(angle)))
        }
        for index in 1...16 {
            path.addLine(to: point(-radius, straightHalf - 2 * straightHalf * CGFloat(index) / 16))
        }
        path.closeSubpath()
        return path
    }
}

/// A shared coordinate space keeps the lens and symbols on the same contour.
/// The lower arc turns inward before the track's rounded end.
enum CurvedTrack {
    private static let centerX: CGFloat = 11.5
    private static let amplitude: CGFloat = 1.75
    private static let middleY: CGFloat = 28
    private static let frequency: CGFloat = 2 * .pi / 50

    static var symbolWarp: Shader {
        ShaderLibrary.curvedSwitcherSymbol(.float4(centerX, amplitude, middleY, frequency), .float(12))
    }

    static func point(offsetX x: CGFloat, at y: CGFloat, in rect: CGRect) -> CGPoint {
        let phase = frequency * (y - middleY)
        let trackX = centerX + amplitude * cos(phase)
        let slope = -amplitude * frequency * sin(phase)
        let normalLength = sqrt(1 + slope * slope)
        return CGPoint(
            x: rect.minX + (trackX + x / normalLength) * rect.width / 24,
            y: rect.minY + (y - x * slope / normalLength) * rect.height / 56
        )
    }
}

private extension Shape {
    func strokeBorderLike(_ color: Color, width: CGFloat) -> some View {
        stroke(color, lineWidth: width).clipShape(self)
    }
}

struct SwitcherHUD_Previews: PreviewProvider {
    static var previews: some View {
        ForEach(SwitcherMode.allCases, id: \.self) { mode in
            SwitcherHUD(appearance: SwitcherAppearance(mode: mode))
                .frame(width: 498, height: 278)
                .background(Color(white: 0.065))
                .previewDisplayName(mode.title)
        }
    }
}
