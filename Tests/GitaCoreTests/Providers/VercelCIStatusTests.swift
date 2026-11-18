import Foundation
import Testing

@testable import GitaCore

/// Vercel CI runs keep the states and labels they showed when the status was a normalized string.
@Suite struct VercelCIStatusTests {
    private static let sha = String(repeating: "a", count: 40)

    /// Vercel's word → the run's state and the label its check shows.
    static let table: [(raw: String?, state: SignalState, label: String)] = [
        ("succeeded", .success, "Passed"), ("SUCCESS", .success, "Passed"), ("passed", .success, "Passed"),
        ("failed", .failure, "Failed"), ("failure", .failure, "Failed"), ("Error", .failure, "Failed"),
        ("running", .running, "Running"), ("IN_PROGRESS", .running, "Running"),
        ("queued", .pending, "Pending"), ("pending", .pending, "Pending"),
        ("skipped", .neutral, "Skipped"),
        ("canceled", .cancelled, "Cancelled"), ("cancelled", .cancelled, "Cancelled"),
        ("brand-new", .neutral, "Unknown"), (nil, .neutral, "Unknown"),
    ]

    @Test func eachVercelWordShowsTheSameStateAndLabel() throws {
        for (index, row) in Self.table.enumerated() {
            let status = row.raw.map { #","status":"\#($0)""# } ?? ""
            let json = #"{"runs":[{"id":"run\#(index)"\#(status),"commitSha":"\#(Self.sha)"}]}"#
            let runs = try VercelSignalParsers.ciRuns(Data(json.utf8))
            let item = try #require(VercelSignals(ci: runs).ciItems().first)
            #expect(item.state == row.state, "\(row.raw ?? "nil")")
            #expect(item.localizedDetail == row.label, "\(row.raw ?? "nil")")
        }
    }

    @Test func outcomeTokensFromEveryProviderKeepTheirLabels() {
        let labels = [
            "Passed": "Passed", "Failed": "Failed", "Failing": "Failing", "Running": "Running", "Pending": "Pending",
            "Skipped": "Skipped", "Cancelled": ProviderStatus.cancelled.localizedTitle, "Unknown": "Unknown",
        ]
        for (token, label) in labels { #expect(ProviderText.status(token) == label, "\(token)") }
    }
}
