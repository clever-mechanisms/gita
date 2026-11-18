import Foundation

/// Remote management: list, add, change the URL of, rename, remove and fetch a remote. Writes go to this
/// repository's own config only, and every write first re-reviews the remote.
extension GitService {
    struct RemoteReview {
        var details: GitRemoteDetails
        var canFetch: Bool
    }

    public func remoteDetails() async throws -> [GitRemoteDetails] {
        let catalog = try await remoteCatalog()
        var details: [GitRemoteDetails] = []
        for name in catalog.names {
            try Task.checkCancellation()
            details.append(try await remoteReview(name, catalog: catalog).details)
        }
        return details
    }

    public func addRemote(name: String, url: String) async throws {
        let source = try RemoteURLPolicy.validate(url)
        try await mutate { service in
            try await service.validateRemoteName(name)
            let catalog = try await service.remoteCatalog()
            guard catalog.canWriteLocal else {
                throw RemoteError.configurationNotLocalFile
            }
            try await service.requireAvailableRemoteName(name, catalog: catalog)
            _ = try await service.managementCommand(
                GitArguments.noHooks + ["remote", "add", "--", name, source], mutation: true,
                failure: RemoteCommandError.addFailed)
        }
    }

    public func setRemoteURL(_ expected: GitRemoteDetails, url: String) async throws {
        let source = try RemoteURLPolicy.validate(url)
        try await mutate { service in
            let current = try await service.requireRemoteReview(expected, editing: true)
            guard current.details.editableURL != nil else {
                throw RemoteError.noEditableURL
            }
            _ = try await service.managementCommand(
                ["config", "--local", "--no-includes", "--replace-all", "remote." + expected.name + ".url", source],
                mutation: true,
                failure: RemoteCommandError.setURLFailed)
        }
    }

    public func renameRemote(_ expected: GitRemoteDetails, to name: String) async throws {
        try await mutate { service in
            try await service.validateRemoteName(name)
            let catalog = try await service.remoteCatalog()
            try await service.requireAvailableRemoteName(name, catalog: catalog)
            _ = try await service.requireRemoteReview(expected, editing: true)
            _ = try await service.managementCommand(
                GitArguments.noHooks + ["remote", "rename", "--no-progress", "--", expected.name, name], mutation: true,
                failure: RemoteCommandError.renameFailed)
        }
    }

    public func removeRemote(_ expected: GitRemoteDetails) async throws {
        try await mutate { service in
            _ = try await service.requireRemoteReview(expected, editing: true)
            _ = try await service.managementCommand(
                GitArguments.noHooks + ["remote", "remove", "--", expected.name], mutation: true,
                failure: RemoteCommandError.removeFailed)
        }
    }

    public func fetchRemote(_ expected: GitRemoteDetails) async throws {
        try await mutate { service in
            let current = try await service.requireRemoteReview(expected, editing: false)
            guard current.canFetch else {
                throw RemoteError.cannotFetchSafely
            }
            _ = try await service.managementCommand(
                GitArguments.transportAllowList + GitArguments.noHooks + [
                    "fetch", "--atomic", "--no-prune", "--no-prune-tags", "--no-recurse-submodules",
                    "--no-auto-maintenance", "--no-write-commit-graph", "--", expected.name,
                ], timeout: .untilIdle, mutation: true,
                failure: RemoteCommandError.fetchFailed)
        }
    }

    private func requireRemoteReview(_ expected: GitRemoteDetails, editing: Bool) async throws -> RemoteReview {
        try await validateRemoteName(expected.name)
        let current = try await remoteReview(expected.name, catalog: remoteCatalog())
        guard current.details.identity == expected.identity else {
            throw RemoteError.changed
        }
        if editing, let restriction = current.details.mutationRestriction { throw RemoteError.restricted(restriction) }
        return current
    }

    func validateRemoteName(_ name: String) async throws {
        guard !name.isEmpty, name != ".", !name.hasPrefix("-"), name.utf8.count <= 256,
            !GitInput.containsControlCharacters(name)
        else { throw RemoteNameError.invalid }
        _ = try await managementCommand(
            ["check-ref-format", "refs/remotes/" + name + "/probe"], outputLimit: 4_096,
            failure: RemoteNameError.invalid)
    }

    private func requireAvailableRemoteName(_ name: String, catalog: RemoteCatalog) async throws {
        guard !catalog.names.contains(where: { $0 == name || $0.hasPrefix(name + "/") || name.hasPrefix($0 + "/") })
        else {
            throw RemoteNameError.taken
        }
        let refs = try await managementCommand(
            [
                "for-each-ref", "--count=1", "--format=%(refname)", "--", "refs/remotes/" + name,
                "refs/remotes/" + name + "/",
            ],
            outputLimit: 64 * 1_024)
        guard refs.stdout.isEmpty else {
            throw RemoteNameError.trackingReferencesTaken
        }
    }
}
