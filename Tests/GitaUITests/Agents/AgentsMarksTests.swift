import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// Agent, service and app marks: every shape is drawn (with the bundled logos from the source tree and with the drawn
/// fallbacks), images and labels carry the names, and the animated mark moves only while its agent works.
@MainActor
struct AgentsMarksTests {
    /// The source tree's `Resources/AgentMarks`, read without changing `BundledResources`.
    private static var logos: [AgentMarkPainter.Kind: NSImage] {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/AgentMarks", isDirectory: true)
        return AgentMarkPainter.loadLogos(from: resources)
    }

    /// True when anything was drawn into the context.
    private static func inked(_ context: CGContext) -> Bool {
        guard let data = context.data else { return false }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
        return (0..<(context.bytesPerRow * context.height)).contains { bytes[$0] != 0 }
    }

    @Test func everyKindIsDrawnFromItsLogoOrItsFallback() throws {
        let logos = Self.logos
        #expect(logos.count == 6)
        #expect(logos[.aider] == nil)
        for kind in AgentMarkPainter.Kind.allCases {
            for set in [logos, [:]] {
                let context = try #require(AgentsImages.context())
                AgentMarkPainter.draw(
                    kind, in: CGRect(x: 0, y: 0, width: 32, height: 32), context: context, ink: .black, logos: set)
                #expect(Self.inked(context), "\(kind)")
            }
        }
        #expect(AgentMarkPainter.loadLogos(from: nil).isEmpty)
        #expect(AgentMarkPainter.rgb(0xFF0000).components?.first == 1)
    }

    @Test func eachToolHasAKindAnImageAndALabel() throws {
        UITestSupport.bootstrap()
        let font = NSFont.systemFont(ofSize: 12)
        for tool in AgentTool.allCases {
            let image = AgentMarks.image(tool, size: 16)
            #expect(image === AgentMarks.image(tool, size: 16))
            #expect(image.accessibilityDescription == tool.displayName)
            #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
            let label = AgentMarks.label(tool, "Working", font: font, color: .labelColor)
            #expect(label.string.hasSuffix(" Working"))
        }
        #expect(AgentMarks.kind(.codex) == .openAI)
        #expect(AgentMarks.kind(.antigravity) == .antigravity)
        let view = FlippedDrawingView(frame: NSRect(x: 0, y: 0, width: 20, height: 20)) {
            AgentMarks.draw(.gemini, in: NSRect(x: 2, y: 2, width: 16, height: 16), flipped: true)
            AgentMarks.draw(.aider, in: NSRect(x: 2, y: 2, width: 16, height: 16), flipped: false)
            AgentMarks.draw(.antigravity, in: NSRect(x: 2, y: 2, width: 16, height: 16), flipped: true)
        }
        UITestSupport.render(view)
        #expect(view.drew)
        AgentMarks.draw(.codex, in: .zero, flipped: false)
    }

    @Test func serviceAndAppMarks() throws {
        UITestSupport.bootstrap()
        for brand in [BrandMarks.Brand.github, .vercel] {
            let image = BrandMarks.image(brand, size: 14)
            #expect(image === BrandMarks.image(brand, size: 14))
            _ = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        #expect(BrandMarks.image(.vercel, size: 14).accessibilityDescription == "Vercel")
        #expect(BrandMarks.web(try #require(URL(string: "https://github.com/o/r")), size: 12) != nil)
        #expect(BrandMarks.web(try #require(URL(string: "https://app.vercel.app")), size: 12) != nil)
        #expect(BrandMarks.web(try #require(URL(string: "https://example.com")), size: 12) == nil)
        let label = BrandMarks.label(
            BrandMarks.image(.vercel, size: 12), "Vercel", font: .systemFont(ofSize: 12), color: .labelColor)
        #expect(label.string.hasSuffix(" Vercel"))
        #expect(
            BrandMarks.app(at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), size: 20).size.width
                == 20)
        #expect(BrandMarks.app("invalid.bundle.identifier.\(UUID().uuidString)") == nil)
    }

    @Test func aMarkMovesOnlyWhileItsAgentWorksInAVisibleWindow() throws {
        let mark = AgentMarkView(side: 14)
        mark.agent = AgentMarkState(tool: .claudeCode, state: .working)
        #expect(mark.agent == AgentMarkState(tool: .claudeCode, state: .working))
        #expect(mark.intrinsicContentSize == NSSize(width: 14, height: 14))
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        controller.view.addSubview(mark)
        let window = UITestSupport.host(controller, size: NSSize(width: 40, height: 40))
        defer { window.close() }
        mark.frame = NSRect(x: 0, y: 0, width: 14, height: 14)
        mark.layout()
        mark.updateLayer()
        mark.state = .idle
        mark.updateLayer()
        mark.tool = .codex
        mark.side = 18
        mark.side = 18
        mark.isHidden = true
        mark.isHidden = false
        mark.viewDidChangeEffectiveAppearance()
        mark.viewDidChangeBackingProperties()
        mark.agent = nil
        mark.updateLayer()
        #expect(mark.tool == nil)
        mark.removeFromSuperview()
    }

    @Test func radialMarksTurnAndTheOthersBreathe() {
        for kind in AgentMarkPainter.Kind.allCases {
            let animation = AgentMarkView.motion(kind)
            let turns = [.claude, .openAI, .gemini].contains(kind)
            #expect(animation.keyPath == (turns ? "transform.rotation.z" : "transform.scale"))
            #expect(animation.repeatCount == .infinity)
        }
        let state = AgentMarkState(
            AgentSession(
                id: "s", tool: .gemini, pid: nil, workingDirectory: URL(fileURLWithPath: "/w"), state: .done,
                stateSince: Date(), evidence: .hook))
        #expect(state == AgentMarkState(tool: .gemini, state: .done))
    }
}

/// A flipped view that runs `body` in `draw(_:)`.
private final class FlippedDrawingView: NSView {
    private let body: () -> Void
    private(set) var drew = false
    init(frame: NSRect, body: @escaping () -> Void) {
        self.body = body
        super.init(frame: frame)
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }
    override var isFlipped: Bool { true }
    override func draw(_: NSRect) {
        drew = true
        body()
    }
}
