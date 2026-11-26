import Foundation
import GitaCore
import Testing

@testable import GitaUI

struct ExternalToolsPresenterTests {
    private let presenter = ExternalToolsPresenter()

    @Test func validatesDetectedAndCustomToolsForTheRequestedOperation() {
        let preset = ExternalToolSelection(preset: .fileMerge)
        #expect(presenter.validation(preset, kind: .diff, detection: nil) == "Checking…")
        #expect(presenter.validation(preset, kind: .diff, detection: .notInstalled) != nil)
        #expect(presenter.validation(preset, kind: .diff, detection: .installed(executablePath: "/bin/echo")) == nil)
        let custom = ExternalToolSelection(
            preset: .custom, customExecutable: "/bin/echo", customArguments: ["$BASE", "$LEFT", "$RIGHT", "$MERGED"])
        #expect(presenter.validation(custom, kind: .diff, detection: nil) != nil)
        #expect(presenter.validation(custom, kind: .merge, detection: nil) == nil)
    }

    @Test func reportsTheCurrentTestLaunchState() {
        #expect(presenter.banner(.idle).isEmpty)
        #expect(presenter.banner(.launching) == "Test in progress…")
        #expect(presenter.banner(.launched(toolName: "Example")) == "Example completed the test.")
        #expect(presenter.banner(.failed("Missing executable")) == "Missing executable")
    }
}
