import AppKit
import SwiftUI
@testable import Pane

// Synthetic, isolated rendering: does not load saved history or start shells.
@main struct VisualProbe {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        for (name, width, appearance) in [
            ("light-wide", 1120.0, NSAppearance.Name.aqua),
            ("dark-compact", 760.0, NSAppearance.Name.darkAqua)
        ] {
            let session = TerminalSession()
            session.blockLifecycleController.restore((0..<1000).map { index in
                CommandBlock(command: index == 999 ? "git status --short" : "echo \(index)",
                             workingDirectory: "/tmp/Pane performance verification",
                             state: .completed(exitCode: 0),
                             output: index == 998
                                ? String(repeating: "wrapped output with a link https://example.com/test and a longer line to check resizing\n", count: 80)
                                : index == 999 ? " M Pane/Views/BlocksView.swift\n?? Pane/Views/RecycledBlocksTimeline.swift" : "output \(index)")
            })
            let host = NSHostingView(rootView: BlocksView(session: session))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 620)
            host.layoutSubtreeIfNeeded()
            for _ in 0..<4 { await Task.yield() }
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = bitmap.representation(using: .png, properties: [:])!
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])
                .appendingPathComponent("\(name).png"))
            _ = await session.shutdownAndWait()
        }
    }
}
