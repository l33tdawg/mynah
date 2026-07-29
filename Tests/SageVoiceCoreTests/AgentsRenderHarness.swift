import SwiftUI
import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// A throwaway harness that draws the Agents pane to PNGs so somebody can look
/// at it. Opt-in via `MYNAH_RENDER_PNGS=1`; deleted once the layout is settled.
///
/// `ImageRenderer` will not draw `List`, `ScrollView` *contents*, `Picker` or
/// anything AppKit-backed — they come out blank or as a yellow placeholder — so
/// this reconstructs the body out of the real row and detail views in plain
/// stacks. It therefore checks composition, typography and colour in both
/// schemes; it does not check scrolling.
@MainActor
final class AgentsRenderHarness: XCTestCase {

    private func agent(
        _ name: String, mask: UInt32 = 0, memories: Int = 0, appliance: Bool = false,
        role: String = "member", clearance: Int = 1, active: Bool = true
    ) -> NodeAgent {
        NodeAgent(
            id: name, name: name, role: role, clearance: clearance, memoryCount: memories,
            isActive: active, lastSeen: nil, capabilities: mask, isThisAppliance: appliance
        )
    }

    func testRenderAgentsPane() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MYNAH_RENDER_PNGS"] == "1", "opt-in")

        let mynah = agent("Mynah - Sage Voice Bridge", mask: 30, appliance: true)
        let roster = [
            mynah,
            agent("claude-code/l33tdawg", memories: 4068),
            agent("codex-sage", memories: 1558, clearance: 2),
            agent("macmini", memories: 105, role: "admin", clearance: 3, active: false)
        ]

        for scheme in [ColorScheme.light, .dark] {
            let pane = HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("ON THIS MAC").mynahFont(.eyebrow).foregroundStyle(Palette.ink.secondary)
                        .padding(.horizontal, s6).padding(.top, s6).padding(.bottom, s4)
                    // The real `AgentListRow` renders as a yellow placeholder:
                    // it carries `.pointingHandCursor()`, which is an
                    // `NSViewRepresentable`, and `ImageRenderer` refuses
                    // anything AppKit-backed. This is its body with that one
                    // modifier omitted — everything about the density,
                    // typography, selection wash and the two marks that matter
                    // is the same.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(roster) { row in
                            VStack(alignment: .leading, spacing: s1) {
                                HStack(spacing: s3) {
                                    Text(row.name).mynahFont(.body)
                                        .foregroundStyle(Palette.ink.primary)
                                        .lineLimit(1).truncationMode(.tail)
                                    if row.permissions.isRestricted {
                                        Circle().fill(Palette.state.caution).frame(width: 6, height: 6)
                                    }
                                    Spacer(minLength: 0)
                                }
                                HStack(spacing: s2) {
                                    Text(row.standingLine).mynahFont(.label)
                                        .foregroundStyle(Palette.ink.secondary)
                                    Text("·").mynahFont(.label).foregroundStyle(Palette.ink.quaternary)
                                    Text(row.memoryLine).mynahFont(.label)
                                        .foregroundStyle(row.memoryCount == 0
                                            ? Palette.state.caution : Palette.ink.secondary)
                                    Spacer(minLength: 0)
                                }
                            }
                            .padding(.horizontal, s4).padding(.vertical, s4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                row.id == mynah.id ? Palette.accent.wash : .clear,
                                in: RoundedRectangle.mynah(r.control)
                            )
                        }
                    }
                    .padding(.horizontal, s5)
                    Spacer(minLength: 0)
                    MynahDivider()
                    VStack(alignment: .leading, spacing: s4) {
                        // Same reason as the rows: `MynahButton` carries the
                        // cursor modifier. Its chrome, without it.
                        Text("Look for agents on your network")
                            .mynahFont(.title3).foregroundStyle(Palette.ink.primary)
                            .padding(.horizontal, s6).padding(.vertical, 10)
                            .background(Palette.surface.raised, in: RoundedRectangle.mynah(r.control))
                            .mynahBorder(r.control)
                        Text("Asks your node which other SAGEs it can reach. It changes nothing.")
                            .mynahFont(.label).foregroundStyle(Palette.ink.secondary)
                    }
                    .padding(.horizontal, s6).padding(.vertical, s5)
                }
                .frame(width: 300)
                Rectangle().fill(Palette.line.divider).frame(width: 1)
                VStack(alignment: .leading, spacing: s6) {
                    VStack(alignment: .leading, spacing: s2) {
                        Text(mynah.name).mynahFont(.title2).foregroundStyle(Palette.ink.primary)
                        Text("\(mynah.standingLine) · \(mynah.memoryLine)")
                            .mynahFont(.label).foregroundStyle(Palette.state.caution)
                    }
                    StandingFacts(agent: mynah)
                    ApplianceStanding(agent: mynah)
                    Text("Adding another agent").mynahFont(.title3).foregroundStyle(Palette.ink.primary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, s8).padding(.vertical, s7)
            }
            .frame(width: 1100, height: 700)
            .background(Palette.surface.canvas)
            .environment(\.colorScheme, scheme)

            let renderer = ImageRenderer(content: pane)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return XCTFail("render produced nothing") }
            let url = URL(fileURLWithPath: "/tmp/agents-\(scheme == .light ? "light" : "dark").png")
            try png.write(to: url)
            print("wrote \(url.path)")
        }
    }
}
