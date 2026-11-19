import Darwin
import Foundation

private struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure(message: message) }
}

private func expect(_ expected: FinderFileError, _ operation: () throws -> Void) throws {
    do {
        try operation()
        throw CheckFailure(message: "Expected \(expected)")
    } catch let error as FinderFileError {
        try check(error == expected, "Expected \(expected), got \(error)")
    }
}

private func withFixture(_ run: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PawShot-Finder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try await run(root)
}

@main
struct FinderActionsChecks {
    static func route() async throws {
        try await withFixture { root in
            let grant = try FinderFiles.grant(for: root)
            let folder = root.appendingPathComponent("工作 + 备忘 & 👩🏻‍💻", isDirectory: true)
            let file = folder.appendingPathComponent("带空格的路径?.txt")
            let actions: [FinderAction] = [
                .create(.text), .create(.markdown), .create(.json), .create(.csv),
                .copyPaths, .copyNames, .openTerminal, .transfer(.copy), .transfer(.move),
                .archive(.compress), .archive(.extract), .openFavorite(UUID()),
            ]
            for action in actions {
                let request = try grant.scope.request(action, for: [folder]).unwrap()
                try check(try FinderActionRequest(url: request.url.unwrap()) == request, "Each action must round-trip Unicode paths")
            }
            let request = try grant.scope.request(.copyPaths, for: [folder, file]).unwrap()
            let url = try request.url.unwrap()
            try check(FinderActionRequest(url: url) == request, "Multiple selected items must retain their order")
            try check(grant.scope.relativePath(to: root) == .root, "The chosen folder itself is valid")
            let neighbour = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-other")
            try check(grant.scope.request(.copyPaths, for: [file, neighbour]) == nil, "Reject selections outside the chosen folder")
            try check(grant.scope.request(.transfer(.move), for: [root]) == nil, "Do not move the granted folder")
            try check(grant.scope.request(.archive(.compress), for: [root]) == nil, "Do not archive the granted root")
            try check(grant.scope.request(.copyNames, for: [file, file]) == nil, "Reject repeated paths")
            let legacy = URL(string: "pawshot-finder://new-markdown?scope=\(grant.scope.id)&folder=")!
            try check(FinderActionRequest(url: legacy) == grant.scope.request(.create(.markdown), for: [root]),
                      "An older Finder extension can still create Markdown")
            let malicious = URL(string: "pawshot-finder://new-markdown?scope=\(grant.scope.id)&folder=..%2FOutside")!
            try check(FinderActionRequest(url: malicious) == nil, "The action must reject parent traversal")
            let extraParameter = URL(string: url.absoluteString + "&folder=Elsewhere")!
            try check(FinderActionRequest(url: extraParameter) == nil, "Reject unexpected query parameters")
            let encoded = try PropertyListEncoder().encode(grant)
            let restored = try PropertyListDecoder().decode(FinderFolderGrant.self, from: encoded)
            try check(restored.scope == grant.scope, "Reopening must restore the same folder grant")
            _ = try FinderFiles.destination(at: .root, in: restored)
        }
    }

    static func menuPreferences() async throws {
        struct LegacySettings: Encodable {
            let scope: FinderScope
            let language: AppLanguage
        }
        try await withFixture { root in
            let scope = try FinderFiles.grant(for: root).scope
            let old = try PropertyListEncoder().encode(LegacySettings(scope: scope, language: .japanese))
            let migrated = try PropertyListDecoder().decode(FinderMenuSettings.self, from: old)
            try check(migrated.scope == scope && migrated.depth == .two && migrated.language == .japanese,
                      "Restoring an existing folder grant defaults to two menu levels")
            let favorite = FinderMenuFavorite(id: UUID(), title: "项目", symbol: "folder")
            let custom = FinderMenuSettings(scope: scope, language: .english, depth: .one, favorites: [favorite])
            let data = try PropertyListEncoder().encode(custom)
            let restored = try PropertyListDecoder().decode(FinderMenuSettings.self, from: data)
            try check(restored.depth == .one && restored.favorites == [favorite], "Publish custom depth and favorite folder")
        }
    }

    static func allFoldersCoverage() async throws {
        try await withFixture { root in
            let fm = FileManager.default
            let first = root.appendingPathComponent("First", isDirectory: true)
            let second = root.appendingPathComponent("Second", isDirectory: true)
            try fm.createDirectory(at: first, withIntermediateDirectories: false)
            try fm.createDirectory(at: second, withIntermediateDirectories: false)
            let shortcut = root.appendingPathComponent("Shortcut", isDirectory: true)
            try fm.createSymbolicLink(at: shortcut, withDestinationURL: second)
            let narrow = try FinderFiles.grant(for: first)
            let global = try FinderFiles.allFoldersGrant(id: UUID())
            try check(global.scope.coversAllFolders && !narrow.scope.coversAllFolders, "Distinguish global and folder coverage")
            try check(narrow.scope.request(.create(.text), for: [second]) == nil, "A folder grant stops at its boundary")
            try check(global.scope.request(.create(.text), for: [first]) != nil, "Global menus include the first folder")
            try check(global.scope.request(.create(.text), for: [second]) != nil, "Global menus include sibling folders")
            try check(global.scope.request(.archive(.compress), for: [global.scope.directory]) == nil,
                      "The startup disk itself cannot be archived")

            let location = try FinderFiles.destination(at: global.scope.relativePath(to: shortcut).unwrap(), in: global)
            let file = try FinderFiles.create(named: "全局 新建", format: .json, at: location, in: global)
            let expected = second.appendingPathComponent("全局 新建.json").resolvingSymlinksInPath().standardizedFileURL
            try check(file.path == expected.path, "Creating in a folder alias uses its physical destination")
            let fileItem = try FinderFiles.item(at: global.scope.relativePath(to: file).unwrap(), in: global)
            let target = try FinderFiles.grant(for: first, localVolumeOnly: false)
            let moved = try FinderFiles.transfer(.move, items: [fileItem], from: global, to: target).first.unwrap()
            try check(moved.lastPathComponent == file.lastPathComponent && !fm.fileExists(atPath: file.path),
                      "The global grant can move between folders on the same filesystem")
            try expect(.unavailableFolder) {
                _ = try FinderFiles.create(named: "Revoked", format: .text, at: location,
                                           in: FinderFiles.allFoldersGrant(id: UUID()))
            }
        }
    }

    static func namesAndCancel() async throws {
        try await withFixture { root in
            let grant = try FinderFiles.grant(for: root)
            let target = try FinderFiles.destination(at: .root, in: grant)
            let fm = FileManager.default
            try check(try fm.contentsOfDirectory(atPath: root.path).isEmpty, "Opening and canceling the dialog must need no writes")
            for name in ["", "   ", ".", "..", ".md", "a/b", "a:b", "a\nb", "a\u{0000}b"] {
                try expect(.invalidName) {
                    _ = try FinderFiles.create(named: name, format: .markdown, at: target, in: grant)
                }
            }
            let formats: [(FinderFileFormat, String, String)] = [
                (.markdown, " 项目 记录 👩🏻‍💻 ", "项目 记录 👩🏻‍💻.md"),
                (.text, "Upper.TXT", "Upper.TXT"),
                (.csv, "Data", "Data.csv"),
                (.json, "Config", "Config.json"),
            ]
            for (format, input, filename) in formats {
                let output = try FinderFiles.create(named: input, format: format, at: target, in: grant)
                try check(output.lastPathComponent == filename, "File names and the existing extension must be preserved")
                let contents = try Data(contentsOf: output)
                if format == .json {
                    let dict = try JSONSerialization.jsonObject(with: contents) as? [String: String]
                    try check(dict?.isEmpty == true, "New JSON files contain an empty object")
                } else {
                    try check(contents.isEmpty, "New text documents are empty")
                }
                let mode = try fm.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int
                try check(mode.map { $0 & 0o111 == 0 } == true, "A new document must be non-executable")
            }
        }
    }

    static func exclusiveCreation() async throws {
        try await withFixture { root in
            let grant = try FinderFiles.grant(for: root)
            let target = try FinderFiles.destination(at: .root, in: grant)
            let existing = root.appendingPathComponent("existing.json")
            let contents = Data(#"{"existing":true}"#.utf8)
            try contents.write(to: existing)
            try expect(.alreadyExists) {
                _ = try FinderFiles.create(named: "existing", format: .json, at: target, in: grant)
            }
            try check(try Data(contentsOf: existing) == contents, "An existing file must keep its bytes")

            let counts = await withTaskGroup(of: Bool?.self, returning: [Bool?].self) { group in
                for _ in 0..<12 {
                    group.addTask {
                        do {
                            _ = try FinderFiles.create(named: "race", format: .json, at: target, in: grant)
                            return true
                        } catch FinderFileError.alreadyExists { return false }
                        catch { return nil }
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            try check(counts.filter { $0 == true }.count == 1 && counts.filter { $0 == false }.count == 11,
                      "Only one concurrent request may create the same file")
            try check(try Set(FileManager.default.contentsOfDirectory(atPath: root.path)) == ["existing.json", "race.json"],
                      "Creation leaves no staged files")
        }
    }

    static func destinationAndRevocation() async throws {
        try await withFixture { fixture in
            let fm = FileManager.default
            let root = fixture.appendingPathComponent("Allowed", isDirectory: true)
            let outside = fixture.appendingPathComponent("Outside", isDirectory: true)
            let folderA = root.appendingPathComponent("A", isDirectory: true)
            let folderB = root.appendingPathComponent("B", isDirectory: true)
            for folder in [folderA, folderB, outside] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let grant = try FinderFiles.grant(for: root)
            let pathA = try grant.scope.relativePath(to: folderA).unwrap()
            let pathB = try grant.scope.relativePath(to: folderB).unwrap()
            let originalDestination = try FinderFiles.destination(at: pathA, in: grant)
            _ = try FinderFiles.destination(at: pathB, in: grant)
            _ = try FinderFiles.create(named: "first", format: .markdown, at: originalDestination, in: grant)
            try check(fm.fileExists(atPath: folderA.appendingPathComponent("first.md").path), "Create in the directory captured at invocation")
            try check(try fm.contentsOfDirectory(atPath: folderB.path).isEmpty, "A second window must not change the destination")

            let newGrant = try FinderFiles.grant(for: root)
            try expect(.unavailableFolder) {
                _ = try FinderFiles.create(named: "revoked", format: .markdown, at: originalDestination, in: newGrant)
            }
            try fm.moveItem(at: folderA, to: outside.appendingPathComponent("Moved"))
            try fm.createDirectory(at: folderA, withIntermediateDirectories: false)
            try expect(.unavailableFolder) {
                _ = try FinderFiles.create(named: "moved", format: .markdown, at: originalDestination, in: grant)
            }
            try check(try fm.contentsOfDirectory(atPath: folderA.path).isEmpty, "A replacement directory must get no writes")

            let link = root.appendingPathComponent("Untrusted Link")
            try fm.createSymbolicLink(at: link, withDestinationURL: outside)
            let linkPath = try grant.scope.relativePath(to: link).unwrap()
            try expect(.unavailableFolder) { _ = try FinderFiles.destination(at: linkPath, in: grant) }
            let copy = fixture.appendingPathComponent("OldAllowed", isDirectory: true)
            try fm.moveItem(at: root, to: copy)
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            try expect(.unavailableFolder) {
                _ = try FinderFiles.destination(at: .root, in: grant)
            }
        }
    }

    static func permissionChanges() async throws {
        guard geteuid() != 0 else { return }
        try await withFixture { root in
            let grant = try FinderFiles.grant(for: root)
            let target = try FinderFiles.destination(at: .root, in: grant)
            let fm = FileManager.default
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
            try expect(.permissionDenied) {
                _ = try FinderFiles.create(named: "cannot-write", format: .markdown, at: target, in: grant)
            }
            try check(try fm.contentsOfDirectory(atPath: root.path).isEmpty, "Denied writes must be side-effect free")
        }
    }

    static func copyAndMove() async throws {
        try await withFixture { root in
            let fm = FileManager.default
            let from = root.appendingPathComponent("From", isDirectory: true)
            let to = root.appendingPathComponent("To", isDirectory: true)
            let folder = from.appendingPathComponent("项目 Folder", isDirectory: true)
            let file = from.appendingPathComponent("A.txt")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.createDirectory(at: to, withIntermediateDirectories: false)
            let original = Data("source".utf8)
            let existing = Data("existing".utf8)
            try original.write(to: folder.appendingPathComponent("nested.txt"))
            try original.write(to: file)
            let source = try FinderFiles.grant(for: from)
            let target = try FinderFiles.grant(for: to)
            let selection = try [folder, file].map {
                try FinderFiles.item(at: source.scope.relativePath(to: $0).unwrap(), in: source)
            }
            try check(try FinderFiles.terminalFolder(for: selection[0], in: source).path == folder.path,
                      "A selected folder opens itself in Terminal")
            try check(try FinderFiles.terminalFolder(for: selection[1], in: source).path == source.scope.directory.path,
                      "A selected file opens its parent in Terminal")
            let sameName = to.appendingPathComponent(file.lastPathComponent)
            try existing.write(to: sameName)
            for operation: FinderTransfer in [.copy, .move] {
                try expect(.destinationConflict(file.lastPathComponent)) {
                    _ = try FinderFiles.transfer(operation, items: selection, from: source, to: target)
                }
            }
            try check(try Data(contentsOf: sameName) == existing, "Existing files must remain untouched")
            try check(try fm.contentsOfDirectory(atPath: to.path) == [file.lastPathComponent],
                      "A known conflict stops the batch before the first item")
            try fm.removeItem(at: sameName)
            let copies = try FinderFiles.transfer(.copy, items: selection, from: source, to: target)
            try check(copies.map(\.lastPathComponent) == [folder.lastPathComponent, file.lastPathComponent],
                      "Copy returns both selected items in order")
            try check(try Data(contentsOf: copies[0].appendingPathComponent("nested.txt")) == original,
                      "Copy keeps a folder's contents")
            try check(try Data(contentsOf: file) == original, "Copy keeps the source")
            try check(try fm.contentsOfDirectory(atPath: to.path).count == 2, "Copy leaves no staging files")
            let moveTarget = root.appendingPathComponent("Move", isDirectory: true)
            try fm.createDirectory(at: moveTarget, withIntermediateDirectories: false)
            let moved = try FinderFiles.transfer(.move, items: selection, from: source,
                                                to: FinderFiles.grant(for: moveTarget))
            try check(try Data(contentsOf: moved[1]) == original, "Move preserves content")
            try check(try fm.contentsOfDirectory(atPath: from.path).isEmpty, "Move removes only the selected source items")
        }
    }

    static func transferWithChangedPaths() async throws {
        try await withFixture { root in
            let fm = FileManager.default
            let from = root.appendingPathComponent("From", isDirectory: true)
            let folder = from.appendingPathComponent("Child", isDirectory: true)
            let child = folder.appendingPathComponent("Grandchild", isDirectory: true)
            let to = root.appendingPathComponent("To", isDirectory: true)
            try fm.createDirectory(at: child, withIntermediateDirectories: true)
            try fm.createDirectory(at: to, withIntermediateDirectories: false)
            let source = try FinderFiles.grant(for: from)
            let selection = try FinderFiles.item(at: source.scope.relativePath(to: folder).unwrap(), in: source)
            for operation: FinderTransfer in [.copy, .move] {
                try expect(.invalidDestination) {
                    _ = try FinderFiles.transfer(operation, items: [selection], from: source,
                                                 to: FinderFiles.grant(for: child))
                }
            }
            try fm.moveItem(at: folder, to: from.appendingPathComponent("Original"))
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            try expect(.changedSelection) {
                _ = try FinderFiles.transfer(.move, items: [selection], from: source, to: FinderFiles.grant(for: to))
            }
            try check(fm.fileExists(atPath: folder.path), "A directory that replaced the selection is untouched")
            try check(try fm.contentsOfDirectory(atPath: to.path).isEmpty, "An expired selection creates no files")
        }
    }

    static func zipRoundTrip() async throws {
        try await withFixture { root in
            let fm = FileManager.default
            let file = root.appendingPathComponent("@项目记录.txt")
            let folder = root.appendingPathComponent("附件", isDirectory: true)
            let note = Data("PawShot archive fixture\n".utf8)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            try note.write(to: file)
            try note.write(to: folder.appendingPathComponent("notes.txt"))
            let grant = try FinderFiles.grant(for: root)
            let items = try [file, folder].map { try FinderFiles.item(at: grant.scope.relativePath(to: $0).unwrap(), in: grant) }
            let zip = try FinderFiles.archive(.compress, items: items, in: grant).first.unwrap()
            let firstZIP = try Data(contentsOf: zip)
            let nextZIP = try FinderFiles.archive(.compress, items: items, in: grant).first.unwrap()
            try check(nextZIP.lastPathComponent == "归档 2.zip" && zip != nextZIP, "Compression chooses an unused name")
            try check(try Data(contentsOf: zip) == firstZIP, "Compression preserves the existing archive")
            let quarantine = Data("0081;00000000;PawShot Fixture;".utf8)
            let attribute = "com.apple.quarantine"
            let result = quarantine.withUnsafeBytes { setxattr(zip.path, attribute, $0.baseAddress, $0.count, 0, 0) }
            try check(result == 0, "Can attach quarantine to the generated test ZIP")
            let archived = try FinderFiles.item(at: grant.scope.relativePath(to: zip).unwrap(), in: grant)
            let first = try FinderFiles.archive(.extract, items: [archived], in: grant).first.unwrap()
            let second = try FinderFiles.archive(.extract, items: [archived], in: grant).first.unwrap()
            try check(second.lastPathComponent == "归档 2", "Extraction chooses an unused folder")
            let extractedFile = first.appendingPathComponent(file.lastPathComponent)
            try check(try Data(contentsOf: extractedFile) == note, "Names with Unicode and @ survive the round trip")
            try check(try Data(contentsOf: second.appendingPathComponent("附件/notes.txt")) == note,
                      "Contents of a selected folder survive the round trip")
            try check(getxattr(extractedFile.path, attribute, nil, 0, 0, 0) > 0, "Extraction preserves archive quarantine")
            try check(try Data(contentsOf: file) == note, "Compression keeps original files")
        }
    }

    static func archiveFormatsAndFailedExtraction() async throws {
        try await withFixture { root in
            let fm = FileManager.default
            let fixture = root.appendingPathComponent("Source", isDirectory: true)
            try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
            let note = Data("Other format fixture".utf8)
            try note.write(to: fixture.appendingPathComponent("note.txt"))
            let grant = try FinderFiles.grant(for: root)
            for (name, options) in [("Gzip fixture.TAR.GZ", ["-cz"]), ("7z fixture.7z", ["-c", "--format", "7zip"])] {
                let archive = root.appendingPathComponent(name)
                let tar = Process()
                tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tar.currentDirectoryURL = fixture
                tar.arguments = options + ["-f", archive.path, "note.txt"]
                try tar.run()
                tar.waitUntilExit()
                try check(tar.terminationStatus == 0, "Can generate the archive fixture")
                let item = try FinderFiles.item(at: grant.scope.relativePath(to: archive).unwrap(), in: grant)
                let output = try FinderFiles.archive(.extract, items: [item], in: grant).first.unwrap()
                try check(try Data(contentsOf: output.appendingPathComponent("note.txt")) == note,
                          "The platform archiver extracts the original bytes")
            }
            let bad = root.appendingPathComponent("Broken.zip")
            try note.write(to: bad)
            let item = try FinderFiles.item(at: grant.scope.relativePath(to: bad).unwrap(), in: grant)
            do {
                _ = try FinderFiles.archive(.extract, items: [item], in: grant)
                throw CheckFailure(message: "Invalid ZIP was extracted")
            } catch FinderArchiveError.extractFailed {}
            try check(!fm.fileExists(atPath: root.appendingPathComponent("Broken").path), "Failed extraction leaves no output")

            try fm.createSymbolicLink(atPath: fixture.appendingPathComponent("Outside link").path,
                                      withDestinationPath: "../..")
            let folder = try FinderFiles.item(at: grant.scope.relativePath(to: fixture).unwrap(), in: grant)
            let zip = try FinderFiles.archive(.compress, items: [folder], in: grant).first.unwrap()
            let archived = try FinderFiles.item(at: grant.scope.relativePath(to: zip).unwrap(), in: grant)
            do {
                _ = try FinderFiles.archive(.extract, items: [archived], in: grant)
                throw CheckFailure(message: "A link pointing outside the result was published")
            } catch FinderArchiveError.unsafeContents {}
            try check(!fm.fileExists(atPath: root.appendingPathComponent("Source 2").path), "Unsafe archives leave no result")
            try check(try !fm.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".pawshot-work-") }),
                      "Extraction cleans up staging data")
        }
    }

    static func main() async {
        let cases: [(String, () async throws -> Void)] = [
            ("finder_request_roundtrip_and_scope", route),
            ("menu_depth_and_favorites_preferences", menuPreferences),
            ("all_folders_coverage_and_cross_folder_actions", allFoldersCoverage),
            ("new_file_formats_names_and_cancel", namesAndCancel),
            ("no_overwrite_under_concurrency", exclusiveCreation),
            ("pinned_destination_and_scope_revocation", destinationAndRevocation),
            ("permissions_rechecked_at_creation", permissionChanges),
            ("copy_and_move_keep_existing_files", copyAndMove),
            ("transfer_rejects_replaced_sources_and_descendants", transferWithChangedPaths),
            ("zip_roundtrip_quarantine_and_name_conflicts", zipRoundTrip),
            ("tar_7z_and_failed_extraction", archiveFormatsAndFailedExtraction),
        ]
        var passed = 0
        for (name, run) in cases {
            do {
                try await run()
                print("PASS \(name)")
                passed += 1
            } catch {
                print("FAIL \(name): \(error.localizedDescription)")
            }
        }
        print("\(passed)/\(cases.count) Finder action checks passed")
        exit(passed == cases.count ? 0 : 1)
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let value = self else { throw CheckFailure(message: "Missing Finder request data") }
        return value
    }
}
