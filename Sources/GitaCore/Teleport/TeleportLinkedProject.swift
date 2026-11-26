import Darwin
import Foundation

/// VercelLinkResolver verifies the link IDs. Newer CLI versions also record the dashboard project name.
enum TeleportLinkedProject {
    static func name(_ link: VercelLink) -> String? {
        let dir = open(link.root.appendingPathComponent(".vercel").path, O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return nil }
        defer { close(dir) }
        let fd = openat(dir, "project.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            let data = try? handle.read(upToCount: 16_385), data.count <= 16_384,
            let json = try? JSONDecoder().decode(Project.self, from: data),
            json.orgId == link.parts?.org, json.projectId == link.parts?.project,
            ProviderValidation.isSlug(json.projectName)
        else { return nil }
        return json.projectName.lowercased()
    }

    private struct Project: Decodable {
        let projectId: String
        let orgId: String
        let projectName: String
    }
}
