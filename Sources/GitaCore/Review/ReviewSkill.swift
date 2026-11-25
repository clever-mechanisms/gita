import Foundation

/// The review method handed to the agent (Settings › AI Agents › AI Review). Each is bundled in
/// `Resources/ReviewSkills/<folder>/` with its license: the three published skills unmodified, and Gitā's own in
/// `gita-review` (README › Review skills).
public enum ReviewSkill: String, Sendable, CaseIterable, Hashable {
    case mattPocock = "mattpocock-code-review"
    case thermoNuclear = "thermo-nuclear-code-quality-review"
    case caveman = "caveman-review"
    /// Gitā's own skill; the saved value predates its SKILL.md, so it differs from its folder.
    case builtIn = "built-in"

    public static let `default` = Self.mattPocock

    /// Brand names (never translated).
    public var displayName: String {
        switch self {
        case .mattPocock: "Matt Pocock Review"
        case .thermoNuclear: "Thermo-Nuclear Review"
        case .caveman: "Caveman Review"
        case .builtIn: "Gitā Review"
        }
    }

    /// The skill's page in its repository, for people to read before using it.
    public var sourceURL: URL? {
        switch self {
        case .mattPocock:
            URL(string: "https://github.com/mattpocock/skills/blob/main/skills/engineering/code-review/SKILL.md")
        case .thermoNuclear:
            URL(
                string:
                    "https://github.com/cursor/plugins/blob/main/thermos/skills/thermo-nuclear-code-quality-review/SKILL.md"
            )
        case .caveman: URL(string: "https://github.com/JuliusBrussee/caveman/tree/main/skills/caveman-review")
        case .builtIn:
            URL(
                string:
                    "https://github.com/clever-mechanisms/gita/blob/main/Resources/ReviewSkills/gita-review/SKILL.md"
            )
        }
    }

    /// The skill's folder inside `ReviewSkills`.
    public var folder: String { self == .builtIn ? "gita-review" : rawValue }

    /// `SKILL.md` inside a `ReviewSkills` folder (the app bundle's, or the repository's in tests).
    public func file(in folder: URL) -> URL {
        folder.appendingPathComponent(self.folder, isDirectory: true).appendingPathComponent("SKILL.md")
    }
}
