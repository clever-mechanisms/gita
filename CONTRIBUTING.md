# Contributing to Gita

Thanks for helping. Gita is a native macOS app: Swift 6, AppKit, Swift Package Manager, no third-party
package dependencies in the app. Bundled third-party resources (fonts, logos, xterm.js for the built-in terminal)
ship unmodified with their licenses.

## Setup

```sh
brew install swiftlint node             # lint and duplication tools used by the gate
scripts/install-periphery.sh            # its dead-code tool (pinned; Homebrew's formula is deprecated)
scripts/install-hooks.sh                # run the quality gate before every push
scripts/build.sh && scripts/install.sh  # build and install /Applications/Gita.app
```

Xcode 26 or later (Swift 6.2) is required. The scripts pick Xcode's toolchain for their own process and never change
`xcode-select`.

## Project layout

- `Sources/GitaCore`: everything that does not need AppKit: Git (through the `git` CLI), providers (GitHub
  through `gh`, Vercel through `vercel`, Orca), coding-agent detection and hooks, parsers and models.
- `Sources/GitaUI`: windows, views, controllers and their presentation logic.
- `Sources/GitaApp`: the entry point only. `Sources/GitaAgentHelper`: the `gita-agent` hook helper.
- `Tests/GitaCoreTests`, `Tests/GitaUITests`: Swift Testing suites. Integration tests build real, disposable
  Git repositories in a temporary directory.

Keep logic out of views: a view or controller binds a plain value type (state, presenter, builder) that tests can
check without a window. Put user-visible text in `String(localized:)` and keep each sentence one localized string.

Hold a lifecycle in one enum, not in flags. When something loads, runs, fails or waits (a read, a write, a page), give
it one `enum` whose cases carry what each state needs: the task, the failure. Views that read the old flags keep
computed accessors such as `isLoading`. Examples: `RepositoryRead`, `PullRequestReviewState.Load`,
`IndexRefreshTrial`, `TerminalSession.State`. A request made while busy, such as `AppModel.pendingRefresh` or
`WorkspaceMonitor`'s read-again mark, is honoured however the busy work ends, failures included. Test each
transition, the failure paths too.

## Quality gate

`scripts/quality.sh` runs everything below and fails on the first finding of any kind. The pre-push hook runs it,
and the same limits are the SonarQube quality gate.

| Check | Tool | Limit |
| --- | --- | --- |
| Formatting | `swift format lint --strict` (`.swift-format`) | no findings |
| Lint | SwiftLint `--strict` (`.swiftlint.yml`) | no findings |
| Compiler | `swift build -Xswiftc -warnings-as-errors` | no warnings |
| Cyclomatic complexity | `Tools/QualityMetrics` and SwiftLint | below 15 per function |
| Cognitive complexity | `Tools/QualityMetrics` | below 22 per function |
| Halstead difficulty | `Tools/QualityMetrics` | below 80 per function |
| Lines of code per file | `Tools/QualityMetrics` and SwiftLint | below 500 |
| Line coverage | `swift test --enable-code-coverage` | above 80% |
| CRAP | `Tools/QualityMetrics` | below 25 per function |
| Dead code | Periphery (test targets excluded) | none |
| Duplicated code | jscpd | none |
| Secrets and Keychain use | `scripts/secret-scan.py`, SwiftLint | none |
| String catalogs | `scripts/strings.sh check --source` | valid |

Other SwiftLint limits: functions up to 60 lines, types up to 350 lines, up to 6 parameters, no force unwraps or
`print` in app code.

`scripts/quality.sh --no-tests` skips the test, coverage and CRAP steps for a quick check.

## SonarQube

SonarQube has no Swift analyzer in its Community Build, so `scripts/sonar.sh` uploads the gate's own results:
the metrics, SwiftLint, Periphery and jscpd findings as external issues, and the line coverage. Swift files are
indexed through the HTML analyzer with an empty rule set. To use it, create an untracked `.sonar.txt`:

```sh
SONAR_URL=https://sonar.example.com
SONAR_PROJECT_ID=gita
SONAR_API_TOKEN=…
```

`scripts/sonar-setup.py` creates the matching "Gita macOS app" quality gate on the server once.

## Releasing

Local builds are ad-hoc signed. A distributable build signs with your Developer ID (hardened runtime, secure
timestamp, no entitlements) and is notarized and stapled:

```sh
xcrun notarytool store-credentials gita-notary   # once: stores your notary credentials in your keychain
GITA_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" GITA_NOTARY_PROFILE=gita-notary \
  CONFIG=release ARCH=universal scripts/build.sh
```

The script passes only these names to `codesign` and `notarytool`; the notarized archive is written to `build/`.

## Rules

- Git writes happen only from explicit user actions, or from opt-in background auto-fetch switched on by the user in Settings (off by default), updating `refs/remotes/*` and objects only (`--atomic --no-tags --no-recurse-submodules --no-prune --no-prune-tags --no-write-fetch-head --no-auto-maintenance --no-write-commit-graph`). Tests never touch a real repository.
- The app stores no credentials and never uses the Keychain; providers are reached through their CLIs.
- Bundle only material whose license is compatible with MIT, with its license file beside it.
- One focused change per pull request, with tests.
