import AppKit
import SwiftUI
@testable import Pane

// Matched optimization measurements; baseline source remains in audit-probe.swift.
final class PerformanceAuditProbeTests {
    @MainActor
    func testTextLayoutCost() {
        for byteTarget in [4096, 65536, 262144] {
            let line = "output https://example.com/path line\n"
            let output = String(repeating: line, count: byteTarget / line.utf8.count)
            for trial in 0..<3 {
                let view = CommandClickableTextView.makeTextView()
                let started = CFAbsoluteTimeGetCurrent()
                CommandClickableTextView(text: output,
                    font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                    textColor: .labelColor).updateTextView(view)
                let updateMS = (CFAbsoluteTimeGetCurrent() - started) * 1000
                let layoutStart = CFAbsoluteTimeGetCurrent()
                _ = view.height(fitting: 760)
                let layoutMS = (CFAbsoluteTimeGetCurrent() - layoutStart) * 1000
                print("AUDIT text bytes=\(output.utf8.count) trial=\(trial) update_ms=\(updateMS) layout_ms=\(layoutMS)")
            }
        }
    }

    func testIndexReplacementCost() async {
        for count in [100, 500, 1000] {
            let blocks = (0..<count).map { i in
                CommandBlock(command: "echo \(i)", workingDirectory: "/tmp",
                             state: .completed(exitCode: 0),
                             output: String(repeating: "bounded output line \(i)\n", count: max(1, 4096 / 24)))
            }
            let index = BlockSearchIndex()
            _ = await index.replace(blocks: blocks)
            var samples: [Double] = []
            for _ in 0..<5 {
                let started = CFAbsoluteTimeGetCurrent()
                _ = await index.replace(blocks: blocks)
                samples.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
            }
            print("AUDIT index_replace blocks=\(count) bytes=\(blocks.reduce(0) { $0 + $1.output.utf8.count }) ms=\(samples)")
        }
    }

    @MainActor
    func testTimelineScaling() async {
        for count in [10, 100, 500, 1000] {
            for trial in 0..<3 {
                let session = TerminalSession()
                let blocks = (0..<count).map { i in
                    CommandBlock(command: "echo \(i)", workingDirectory: "/tmp",
                                 state: .completed(exitCode: 0), output: "audit output \(i)")
                }
                session.blockLifecycleController.restore(blocks)
                // Let the independent index task settle before timing layout.
                try? await Task.sleep(for: .milliseconds(160))
                let started = CFAbsoluteTimeGetCurrent()
                let host = NSHostingView(rootView: BlocksView(session: session))
                host.frame = NSRect(x: 0, y: 0, width: 1120, height: 620)
                host.layoutSubtreeIfNeeded()
                let mountMS = (CFAbsoluteTimeGetCurrent() - started) * 1000
                let resizeStart = CFAbsoluteTimeGetCurrent()
                host.frame.size.width = 760
                host.layoutSubtreeIfNeeded()
                let resizeMS = (CFAbsoluteTimeGetCurrent() - resizeStart) * 1000
                let draftStart = CFAbsoluteTimeGetCurrent()
                session.commandDraft = "g"
                for _ in 0..<3 { await Task.yield() }
                host.layoutSubtreeIfNeeded()
                let draftMS = (CFAbsoluteTimeGetCurrent() - draftStart) * 1000
                let outputs = outputCount(host)
                print("AUDIT timeline blocks=\(count) trial=\(trial) mounted_outputs=\(outputs) mount_ms=\(mountMS) resize_ms=\(resizeMS) draft_update_ms=\(draftMS)")
                precondition(outputs > 0 && outputs <= min(count, 50))
                host.rootView = BlocksView(session: TerminalSession())
                _ = await session.shutdownAndWait()
            }
        }
    }

    @MainActor
    private func outputCount(_ view: NSView) -> Int {
        (view is CommandClickableNSTextView ? 1 : 0)
            + view.subviews.reduce(0) { $0 + outputCount($1) }
    }
}

@main struct AuditRunner {
 @MainActor static func main() async {
  _ = NSApplication.shared
  let probe = PerformanceAuditProbeTests()
  await probe.testIndexReplacementCost()
  probe.testTextLayoutCost()
  await probe.testTimelineScaling()
 }
}
