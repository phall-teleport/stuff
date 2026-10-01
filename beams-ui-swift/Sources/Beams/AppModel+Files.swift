import AppKit

extension AppModel {
    /// Copies the beam's working directory (`config.workDir`) into a folder on
    /// this Mac. The first time (or with `choose`) it asks where; later saves
    /// go to the same folder. Files there with the same paths are overwritten;
    /// nothing else in the folder is removed.
    func saveWorkFolder(_ id: String? = nil, choose: Bool = false) async {
        guard let id = id ?? currentID, let s = sessions.first(where: { $0.id == id }) else { return }
        if beamGone(s) { toast("The beam for this session is gone, so there's nothing to save.", .err); return }
        guard sshAllowed(), !savingLocal.contains(id) else { return }

        var folder = s.localFolder
        if choose || folder.isEmpty || !FileManager.default.fileExists(atPath: folder) {
            guard let picked = pickFolder(for: s) else { return }
            folder = picked
        }

        savingLocal.insert(id)
        defer { savingLocal.remove(id) }
        do {
            let res = try await client.run(id: s.beamId, script: AgentScripts.workspaceDownload(workDir: config.workDir))
            guard !res.stdout.isEmpty else { toast("\(config.workDir) in \(s.beamName) is empty"); return }
            let count = try await Self.extract(res.stdout, into: folder)
            updateSession(id) { $0.localFolder = folder; $0.localSaved = RFC3339.string(Date()) }
            toast("Saved \(count) files to \(Self.displayPath(folder))", .ok, seconds: 6)
        } catch {
            noteSSHFailure(error.localizedDescription)
            fail(error)
        }
    }

    func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func pickFolder(for s: Session) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        panel.message = "Choose a folder for \(config.workDir) from \(s.beamName). Files with the same names are replaced; nothing else is deleted."
        let start = s.localFolder.isEmpty ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first : URL(fileURLWithPath: s.localFolder)
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Unpacks into `folder` (bsdtar refuses absolute and `..` paths by
    /// default) and returns the number of regular files in the archive.
    nonisolated static func extract(_ tarGz: Data, into folder: String) async throws -> Int {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let list = try await Shell.run(["/usr/bin/tar", "tvzf", "-"], stdin: tarGz)
        let files = String(decoding: list.stdout, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("-") }.count
        try await Shell.run(["/usr/bin/tar", "xzf", "-", "-C", folder], stdin: tarGz)
        return files
    }

    nonisolated static func displayPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
