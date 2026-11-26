import Foundation

struct FlightSnapshotMetadata: Sendable {
    let trigger: FlightSnapshotTrigger
    let tool: AgentTool?
    let sessionID: String?
    let label: String
    let sequence: Int
    let count: Int

    func message(ref: String) throws -> String {
        // JSON strings keep arbitrary label/session text on one trailer line, including embedded NULs.
        let encoder = JSONEncoder()
        let labelText = String(decoding: try encoder.encode(label), as: UTF8.self)
        let sessionText = String(decoding: try encoder.encode(sessionID), as: UTF8.self)
        return """
            Gita flight snapshot

            Gita-Ref: \(ref)
            Gita-Trigger: \(trigger.rawValue)
            Gita-Tool: \(tool?.rawValue ?? "")
            Gita-Session: \(sessionText)
            Gita-Label: \(labelText)
            Gita-Sequence: \(sequence)
            Gita-Changed: \(count)
            """
    }

    static func list(git: AgentControlGit, tip: String, ref: String?, limit: Int) async throws -> [FlightSnapshot] {
        let args = [
            "log", "--first-parent", "--no-show-signature", "-z", "--format=%H%x00%P%x00%ct%x00%B",
            "--max-count=\(limit)", tip, "--",
        ]
        let fields = GitOutput.nulFields(try await git.run(args).stdout)
        var snapshots: [FlightSnapshot] = []
        for i in stride(from: 0, to: max(0, fields.count - 3), by: 4) {
            guard let snapshot = parse(fields[i...i + 3]), ref == nil || ref == snapshot.refName else { break }
            snapshots.append(snapshot)
            if snapshot.sequence == 1 { break }
        }
        return snapshots
    }

    private static func parse(_ fields: ArraySlice<String>) -> FlightSnapshot? {
        let i = fields.startIndex
        let lines = fields[i + 3].split(separator: "\n")
        guard lines.first == "Gita flight snapshot", let time = TimeInterval(fields[i + 2]) else { return nil }
        var values: [Substring: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            values[line[..<separator]] = String(line[line.index(after: separator)...].drop(while: { $0 == " " }))
        }
        guard let storedRef = values["Gita-Ref"], storedRef.hasPrefix("refs/gita/snapshots/"),
            let trigger = values["Gita-Trigger"].flatMap(FlightSnapshotTrigger.init),
            let sequence = values["Gita-Sequence"].flatMap(Int.init), sequence > 0,
            let count = values["Gita-Changed"].flatMap(Int.init),
            let label = string(values["Gita-Label"])
        else { return nil }
        return FlightSnapshot(
            id: fields[i], refName: storedRef, sequence: sequence, createdAt: Date(timeIntervalSince1970: time),
            trigger: trigger, tool: values["Gita-Tool"].flatMap(AgentTool.init),
            sessionID: string(values["Gita-Session"]),
            label: label, changedFileCount: count, parentOID: fields[i + 1].split(separator: " ").first.map(String.init)
        )
    }

    private static func string(_ encoded: String?) -> String? {
        guard let encoded else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(encoded.utf8))
    }
}
