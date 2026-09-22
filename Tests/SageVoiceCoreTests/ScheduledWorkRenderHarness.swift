import SwiftUI
import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// Draws the Scheduled screen so somebody can look at it. Opt-in via
/// `MYNAH_RENDER_PNGS=1`.
///
/// **What this cannot draw, stated plainly rather than discovered later.**
/// `ImageRenderer` refuses anything AppKit-backed, and the "Set one up" card is
/// all controls: the text field comes out blank, and the pickers and the date
/// field render as their chrome without their measurements. So this is a check
/// of the *list* — the numbering, the two lines per row, the switch and the
/// cross, the air between rows, and the light/dark inks — plus the heading and
/// the empty state. It says nothing about typing, about what a menu picker opens
/// as, or about anything the owner does with the mouse.
@MainActor
final class ScheduledWorkRenderHarness: XCTestCase {

    func testRenderScheduledScreen() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MYNAH_RENDER_PNGS"] == "1", "opt-in")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scheduled-work.json")

        let nine = Calendar.current.date(bySettingHour: 9, minute: 5, second: 0, of: Date())!
        var fixture = ScheduledWork()
        _ = fixture.add(
            instruction: "check my inbox and tell me what's waiting",
            cadence: .daily(hour: 8, minute: 0),
            now: Date().addingTimeInterval(-86_400 * 3)
        )
        _ = fixture.add(
            instruction: "send me the week ahead",
            cadence: .weekly(weekday: 2, hour: 9, minute: 30),
            now: Date().addingTimeInterval(-86_400 * 2)
        )
        _ = fixture.add(
            instruction: "look for anything new from Flint and tell me the moment there is",
            cadence: .every(minutes: 30),
            now: Date().addingTimeInterval(-86_400)
        )
        _ = fixture.pause(number: 2)
        if let index = fixture.tasks.firstIndex(where: { $0.instruction.hasPrefix("check my inbox") }) {
            fixture.tasks[index].lastRunAt = nine
        }
        try fixture.save(to: file)

        // And the empty list, which is the state a fresh install shows and the
        // one nobody looks at twice.
        let emptyFile = directory.appendingPathComponent("empty.json")
        try ScheduledWork().save(to: emptyFile)

        for (name, source) in [("", file), ("-empty", emptyFile)] {
            for scheme in [ColorScheme.light, .dark] {
                let screen = ScheduledWorkView(model: ScheduledWorkModel(fileURL: source))
                    .pane
                    .frame(width: 900)
                    .environment(\.colorScheme, scheme)

                let renderer = ImageRenderer(content: screen)
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { return XCTFail("render produced nothing") }
                let url = URL(
                    fileURLWithPath:
                        "/tmp/scheduled\(name)-\(scheme == .light ? "light" : "dark").png"
                )
                try png.write(to: url)
                print("wrote \(url.path)")
            }
        }
    }
}
