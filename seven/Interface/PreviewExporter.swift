import AppKit
import SwiftUI

@MainActor
enum PreviewExporter {
    static func export(to directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for mode in SwitcherMode.allCases {
                let view = SwitcherHUD(appearance: SwitcherAppearance(mode: mode))
                    .frame(width: 498, height: 278)
                    .background(Color(red: 0.065, green: 0.065, blue: 0.065))
                try writePNG(view, scale: 3, to: directory.appendingPathComponent("\(mode.rawValue)-mode.png"))
            }
        } catch {
            FileHandle.standardError.write(Data("Preview export failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    /// Sample the same animatable artwork, including intermediate deformations,
    /// for visual inspection without relying on screenshots of clear windows.
    static func exportMotion(to directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for frame in 0..<120 {
                let time = Double(frame) / 60
                let progress: Double
                if time < 0.3 { progress = 0 }
                else if time < 1.3 { progress = springValue(at: time - 0.3) }
                else { progress = 1 - springValue(at: time - 1.3) }
                let view = PillArtwork(progress: CGFloat(progress))
                    .scaleEffect(5)
                    .frame(width: 200, height: 320)
                    .background(Color(white: 0.065))
                try writePNG(view, scale: 1, to: directory.appendingPathComponent(String(format: "frame-%03d.png", frame)))
            }
            let strip = HStack(spacing: 0) {
                ForEach(0..<5) { index in
                    PillArtwork(progress: CGFloat(index) / 4)
                        .scaleEffect(4)
                        .frame(width: 140, height: 260)
                }
            }.background(Color(white: 0.065))
            try writePNG(strip, scale: 1, to: directory.appendingPathComponent("transition-strip.png"))
        } catch {
            FileHandle.standardError.write(Data("Motion export failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func springValue(at time: Double) -> Double {
        let frequency = 2 * Double.pi / 0.40
        let damping = 0.72
        let damped = frequency * sqrt(1 - damping * damping)
        return 1 - exp(-damping * frequency * time) * (cos(damped * time) + damping / sqrt(1 - damping * damping) * sin(damped * time))
    }

    private static func writePNG<V: View>(_ view: V, scale: CGFloat, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { throw ExportError.renderFailed }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ExportError.renderFailed }
        try data.write(to: url)
    }

    private enum ExportError: Error { case renderFailed }
}
