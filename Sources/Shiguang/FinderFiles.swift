import Darwin
import Foundation

enum FinderFileError: LocalizedError, Equatable {
    case invalidName, alreadyExists, unsupportedFolder, unavailableFolder, permissionDenied, diskFull
    case changedSelection, invalidDestination, differentVolumes
    case destinationConflict(String)
    case io(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidName: return L("请输入有效的文件名，文件名不能以点开头或包含路径符号。")
        case .alreadyExists: return L("同名文件已存在，请换一个名称。")
        case .unsupportedFolder: return L("请选择一个本地文件夹。")
        case .unavailableFolder: return L("目标文件夹已移动或访问范围已更改，请重新选择。")
        case .permissionDenied: return L("无法访问此位置，请检查文件权限和完整磁盘访问设置。")
        case .diskFull: return L("存储空间不足，无法完成文件操作。")
        case .changedSelection: return L("所选项目已移动或被替换，请在访达中重新选择。")
        case .invalidDestination: return L("不能将文件夹放入它自身或它的子文件夹。")
        case .differentVolumes: return L("移动仅支持同一磁盘。请使用「复制到…」。")
        case .destinationConflict(let name): return String(format: L("目标文件夹已存在「%@」。"), name)
        case .io(let code): return NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
        }
    }

    init(errno: Int32) {
        switch errno {
        case EEXIST: self = .alreadyExists
        case ENAMETOOLONG: self = .invalidName
        case ENOENT, ENOTDIR, ELOOP: self = .unavailableFolder
        case EACCES, EPERM, EROFS: self = .permissionDenied
        case ENOSPC, EDQUOT: self = .diskFull
        default: self = .io(errno)
        }
    }
}

struct FinderItemIdentity: Codable, Equatable, Sendable {
    let inode: UInt64
    let birthSecond: Int64
    let birthNanosecond: Int64

    init(descriptor: Int32) throws {
        var details = stat()
        guard fstat(descriptor, &details) == 0 else { throw FinderFileError(errno: errno) }
        self.init(details)
    }

    init(_ details: stat) {
        inode = details.st_ino
        birthSecond = Int64(details.st_birthtimespec.tv_sec)
        birthNanosecond = Int64(details.st_birthtimespec.tv_nsec)
    }
}

struct FinderFolderGrant: Codable, Sendable {
    let scope: FinderScope
    let identity: FinderItemIdentity
    let volumeID: String?
}

struct FinderDestination {
    let scopeID: UUID
    let path: FinderRelativePath
    let url: URL
    let identity: FinderItemIdentity
}

struct FinderSelectedItem: Sendable {
    let path: FinderRelativePath
    let url: URL
    let identity: FinderItemIdentity
    let isDirectory: Bool
    let deviceID: dev_t
}

struct FinderTransferFailure: LocalizedError {
    let completed: [URL]
    let item: String
    let reason: Error

    var errorDescription: String? {
        String(format: L("处理「%@」时停止，已完成 %ld 项。"), item, completed.count) +
            "\n" + reason.localizedDescription
    }
}

enum FinderArchiveError: LocalizedError, Equatable {
    case differentFolders, unsupported, compressFailed, extractFailed, unsafeContents

    var errorDescription: String? {
        switch self {
        case .differentFolders: return L("请选择同一个文件夹中的项目进行压缩。")
        case .unsupported: return L("请选择支持解压的压缩文件。")
        case .compressFailed: return L("无法创建 ZIP，请检查文件权限和可用空间。")
        case .extractFailed: return L("无法解压。请检查压缩包是否完整、是否需要密码，以及可用空间。")
        case .unsafeContents: return L("压缩包包含指向目标目录之外的链接或不支持的项目。")
        }
    }
}

enum FinderFiles {
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    static func grant(for selectedFolder: URL, localVolumeOnly: Bool = true) throws -> FinderFolderGrant {
        guard selectedFolder.isFileURL else { throw FinderFileError.unsupportedFolder }
        let folder = selectedFolder.resolvingSymlinksInPath().standardizedFileURL
        let volumeID = localVolumeOnly ? try localVolumeID(for: folder) : nil
        return try makeGrant(scope: FinderScope(id: UUID(), directory: folder), volumeID: volumeID, requiresWrite: true)
    }

    static func allFoldersGrant(id: UUID) throws -> FinderFolderGrant {
        try makeGrant(scope: .allFolders(id: id), volumeID: nil, requiresWrite: false)
    }

    private static func makeGrant(scope: FinderScope, volumeID: String?, requiresWrite: Bool) throws -> FinderFolderGrant {
        let descriptor = open(scope.directory.path, directoryFlags)
        guard descriptor >= 0 else { throw FinderFileError(errno: errno) }
        defer { close(descriptor) }
        if requiresWrite, faccessat(descriptor, ".", W_OK, AT_EACCESS) != 0 {
            throw FinderFileError(errno: errno)
        }
        return FinderFolderGrant(
            scope: scope,
            identity: try FinderItemIdentity(descriptor: descriptor),
            volumeID: volumeID
        )
    }

    static func destination(at path: FinderRelativePath, in grant: FinderFolderGrant) throws -> FinderDestination {
        try withDirectory(at: path, in: grant) { descriptor, folder in
            FinderDestination(scopeID: grant.scope.id, path: path, url: folder,
                              identity: try FinderItemIdentity(descriptor: descriptor))
        }
    }

    static func create(named input: String, format: FinderFileFormat, at destination: FinderDestination,
                       in grant: FinderFolderGrant) throws -> URL {
        guard destination.scopeID == grant.scope.id else { throw FinderFileError.unavailableFolder }
        let name = try filename(for: input, format: format)
        return try withDirectory(at: destination.path, in: grant) { descriptor, folder in
            guard try FinderItemIdentity(descriptor: descriptor) == destination.identity else {
                throw FinderFileError.unavailableFolder
            }
            let contents = format.initialContents
            if contents.isEmpty {
                close(try createExclusiveFile(in: descriptor, name: name))
            } else {
                let temporaryName = ".pawshot-\(UUID().uuidString).tmp"
                let file = try createExclusiveFile(in: descriptor, name: temporaryName)
                defer {
                    close(file)
                    unlinkat(descriptor, temporaryName, 0)
                }
                try write(contents, to: file)
                try renameExclusive(temporaryName, in: descriptor, to: name, in: descriptor)
            }
            return folder.appendingPathComponent(name, isDirectory: false)
        }
    }

    static func filename(for input: String, format: FinderFileFormat) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw FinderFileError.invalidName
        }
        let suffix = "." + format.rawValue
        return name.lowercased().hasSuffix(suffix) ? name : name + suffix
    }

    static func item(at path: FinderRelativePath, in grant: FinderFolderGrant) throws -> FinderSelectedItem {
        guard let parent = path.parent, let name = path.name else {
            return try withDirectory(at: .root, in: grant) { descriptor, folder in
                let info = try descriptorStat(descriptor)
                return FinderSelectedItem(path: .root, url: folder, identity: FinderItemIdentity(info),
                                          isDirectory: true, deviceID: info.st_dev)
            }
        }
        return try withDirectory(at: parent, in: grant) { descriptor, folder in
            let details = try itemDetails(name, in: descriptor)
            let directory = details.st_mode & S_IFMT == S_IFDIR
            return FinderSelectedItem(path: path, url: folder.appendingPathComponent(name, isDirectory: directory),
                                      identity: FinderItemIdentity(details), isDirectory: directory,
                                      deviceID: details.st_dev)
        }
    }

    static func terminalFolder(for item: FinderSelectedItem, in grant: FinderFolderGrant) throws -> URL {
        let path = item.isDirectory ? item.path : (item.path.parent ?? .root)
        return try destination(at: path, in: grant).url
    }

    static func transfer(_ operation: FinderTransfer, items: [FinderSelectedItem],
                         from sourceGrant: FinderFolderGrant, to targetGrant: FinderFolderGrant) throws -> [URL] {
        return try withDirectory(at: .root, in: targetGrant) { target, targetURL in
            let targetDevice = try descriptorStat(target).st_dev
            let caseSensitive = try targetURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames ?? false
            var names: Set<String> = []
            let paths = Set(items.map(\.path))
            for item in items {
                guard let name = item.path.name else { throw FinderFileError.changedSelection }
                var ancestor = item.path.parent
                while let parent = ancestor {
                    guard !paths.contains(parent) else { throw FinderFileError.changedSelection }
                    ancestor = parent.parent
                }
                if item.isDirectory, targetURL.pathComponents.starts(with: item.url.pathComponents) {
                    throw FinderFileError.invalidDestination
                }
                let key = caseSensitive ? name : name.lowercased()
                guard names.insert(key).inserted else { throw FinderFileError.destinationConflict(name) }
                var details = stat()
                guard fstatat(target, name, &details, AT_SYMLINK_NOFOLLOW) != 0 else {
                    throw FinderFileError.destinationConflict(name)
                }
                guard errno == ENOENT else { throw FinderFileError(errno: errno) }
                let current = try self.item(at: item.path, in: sourceGrant)
                guard current.identity == item.identity, current.deviceID == item.deviceID else {
                    throw FinderFileError.changedSelection
                }
                if operation == .move, current.deviceID != targetDevice { throw FinderFileError.differentVolumes }
            }

            var completed: [URL] = []
            for item in items {
                guard let parent = item.path.parent, let name = item.path.name else {
                    throw FinderFileError.changedSelection
                }
                do {
                    try withDirectory(at: parent, in: sourceGrant) { source, sourceURL in
                        try validateItem(name, in: source, expected: item.identity)
                        guard try directoryURL(for: target).path == targetURL.path else {
                            throw FinderFileError.unavailableFolder
                        }
                        if operation == .move {
                            try renameExclusive(name, in: source, to: name, in: target)
                        } else {
                            try copyItem(name, from: source, sourceURL: sourceURL, expected: item.identity,
                                         to: target, targetURL: targetURL)
                        }
                    }
                    completed.append(targetURL.appendingPathComponent(name, isDirectory: item.isDirectory))
                } catch {
                    throw FinderTransferFailure(completed: completed, item: name, reason: error)
                }
            }
            return completed
        }
    }

    private static func copyItem(_ name: String, from source: Int32, sourceURL: URL,
                                 expected: FinderItemIdentity, to target: Int32, targetURL: URL) throws {
        try withStagingDirectory(in: target) { staging, stagingURL in
            let stagedItem = stagingURL.appendingPathComponent(name)
            guard try directoryURL(for: source).path == sourceURL.path else { throw FinderFileError.unavailableFolder }
            try FileManager.default.copyItem(at: sourceURL.appendingPathComponent(name), to: stagedItem)
            try validateItem(name, in: source, expected: expected)
            guard try directoryURL(for: target).path == targetURL.path else { throw FinderFileError.unavailableFolder }
            try renameExclusive(name, in: staging, to: name, in: target)
        }
    }

    private static func withStagingDirectory<Result>(in target: Int32,
                                                     _ operation: (Int32, URL) throws -> Result) throws -> Result {
        let stagingName = ".pawshot-work-\(UUID().uuidString)"
        guard mkdirat(target, stagingName, 0o700) == 0 else { throw FinderFileError(errno: errno) }
        let staging = openat(target, stagingName, directoryFlags)
        guard staging >= 0 else {
            let error = FinderFileError(errno: errno)
            unlinkat(target, stagingName, AT_REMOVEDIR)
            throw error
        }
        defer {
            if let folder = try? directoryURL(for: staging), folder.lastPathComponent == stagingName {
                try? FileManager.default.removeItem(at: folder)
            }
            close(staging)
        }
        return try operation(staging, directoryURL(for: staging))
    }

    private static func itemDetails(_ name: String, in directory: Int32) throws -> stat {
        var details = stat()
        guard fstatat(directory, name, &details, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw FinderFileError(errno: errno)
        }
        return details
    }

    private static func descriptorStat(_ descriptor: Int32) throws -> stat {
        var details = stat()
        guard fstat(descriptor, &details) == 0 else { throw FinderFileError(errno: errno) }
        return details
    }

    private static func validateItem(_ name: String, in directory: Int32,
                                     expected: FinderItemIdentity) throws {
        guard try FinderItemIdentity(itemDetails(name, in: directory)) == expected else {
            throw FinderFileError.changedSelection
        }
    }

    private static func createExclusiveFile(in directory: Int32, name: String) throws -> Int32 {
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { throw FinderFileError(errno: errno) }
        return descriptor
    }

    private static func write(_ data: Data, to file: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file, start.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw FinderFileError(errno: count == 0 ? EIO : errno) }
                offset += count
            }
        }
    }

    private static func renameExclusive(_ from: String, in source: Int32,
                                        to name: String, in target: Int32) throws {
        guard renameatx_np(source, from, target, name, UInt32(RENAME_EXCL)) == 0 else {
            throw FinderFileError(errno: errno)
        }
    }

    private static func localVolumeID(for directory: URL) throws -> String {
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeURLKey, .volumeUUIDStringKey, .isUbiquitousItemKey]
        let values = try directory.resourceValues(forKeys: keys)
        let homeLibrary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let cloudFolders = ["CloudStorage", "Mobile Documents"].map {
            homeLibrary.appendingPathComponent($0).pathComponents
        }
        guard values.volumeIsLocal == true, let volumeID = values.volumeUUIDString,
              directory.path != values.volume?.standardizedFileURL.path,
              values.isUbiquitousItem != true,
              !cloudFolders.contains(where: { directory.pathComponents.starts(with: $0) }) else {
            throw FinderFileError.unsupportedFolder
        }
        return volumeID
    }

    private static func directoryURL(for descriptor: Int32) throws -> URL {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else { throw FinderFileError(errno: errno) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true).standardizedFileURL
    }

    private static func withDirectory<T>(
        at path: FinderRelativePath, in grant: FinderFolderGrant,
        _ action: (Int32, URL) throws -> T
    ) throws -> T {
        let root = grant.scope.directory
        let components: [String]
        if grant.scope.coversAllFolders {
            let requested = root.appendingPathComponent(path.relativeString, isDirectory: true)
            // Foundation may shorten /private/var to /var. Walk the physical path so openat can reject new links.
            guard let resolved = realpath(requested.path, nil) else { throw FinderFileError(errno: errno) }
            defer { free(resolved) }
            components = String(cString: resolved).split(separator: "/").map(String.init)
        } else {
            components = path.components
        }
        var descriptor = open(root.path, directoryFlags)
        guard descriptor >= 0 else { throw FinderFileError(errno: errno) }
        defer { close(descriptor) }
        guard try FinderItemIdentity(descriptor: descriptor) == grant.identity else {
            throw FinderFileError.unavailableFolder
        }
        var folder = root
        // Walk the authorized path without following links introduced after resolving it.
        for component in components {
            let next = openat(descriptor, component, directoryFlags)
            guard next >= 0 else { throw FinderFileError(errno: errno) }
            close(descriptor)
            descriptor = next
            folder.appendPathComponent(component, isDirectory: true)
        }
        folder = folder.standardizedFileURL
        if let volumeID = grant.volumeID, try localVolumeID(for: folder) != volumeID {
            throw FinderFileError.unsupportedFolder
        }
        guard try directoryURL(for: descriptor).path == folder.path else {
            throw FinderFileError.unavailableFolder
        }
        return try action(descriptor, folder)
    }
}

extension FinderFiles {
    private static let quarantineAttribute = "com.apple.quarantine"

    static func archive(_ operation: FinderArchiveOperation, items: [FinderSelectedItem], in grant: FinderFolderGrant) throws -> [URL] {
        if operation == .compress { return [try compress(items, in: grant)] }

        var completed: [URL] = []
        for item in items {
            do {
                completed.append(try extract(item, in: grant))
            } catch {
                guard !completed.isEmpty else { throw error }
                throw FinderTransferFailure(completed: completed, item: item.url.lastPathComponent, reason: error)
            }
        }
        return completed
    }

    private static func compress(_ items: [FinderSelectedItem], in grant: FinderFolderGrant) throws -> URL {
        guard let parent = items.first?.path.parent, items.allSatisfy({ $0.path.parent == parent }) else {
            throw FinderArchiveError.differentFolders
        }
        let names = items.compactMap(\.path.name)
        let archiveName = items.count == 1 ? names[0] : L("归档")
        return try withDirectory(at: parent, in: grant) { directory, folder in
            let verifySources = {
                for (name, item) in zip(names, items) {
                    try validateItem(name, in: directory, expected: item.identity)
                }
            }
            try verifySources()
            return try withStagingDirectory(in: directory) { staging, stagingURL in
                let filename = "compressed.zip"
                let output = stagingURL.appendingPathComponent(filename)
                // Prefix operands to avoid interpreting Finder names as bsdtar options or @archive inputs.
                let sources = names.map { "./" + $0 }
                try runArchiveTool(["-c", "--format", "zip", "--one-file-system", "-f", output.path, "--"] + sources,
                                   in: folder, failure: .compressFailed)
                try verifySources()
                try verifyDirectory(directory, at: folder)
                return try publishArchiveItem(filename, from: staging, to: directory, at: folder,
                                              base: archiveName, suffix: ".zip")
            }
        }
    }

    private static func extract(_ item: FinderSelectedItem, in grant: FinderFolderGrant) throws -> URL {
        guard let parent = item.path.parent, let name = item.path.name,
              let suffix = FinderArchiveOperation.suffix(for: name) else { throw FinderArchiveError.unsupported }
        let base = String(name.dropLast(suffix.count))
        return try withDirectory(at: parent, in: grant) { directory, folder in
            let input = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard input >= 0 else { throw FinderFileError(errno: errno) }
            let handle = FileHandle(fileDescriptor: input, closeOnDealloc: true)
            var details = stat()
            guard fstat(input, &details) == 0 else { throw FinderFileError(errno: errno) }
            guard details.st_mode & S_IFMT == S_IFREG else { throw FinderArchiveError.unsupported }
            guard FinderItemIdentity(details) == item.identity else { throw FinderFileError.changedSelection }
            let quarantine = try readQuarantine(input)
            return try withStagingDirectory(in: directory) { staging, stagingURL in
                let outputName = "expanded"
                guard mkdirat(staging, outputName, 0o755) == 0 else { throw FinderFileError(errno: errno) }
                let output = stagingURL.appendingPathComponent(outputName, isDirectory: true)
                // Keep bsdtar's path and symlink protections enabled. Publish only after a successful extraction.
                try runArchiveTool(["-x", "--no-same-permissions", "--no-same-owner", "--no-mac-metadata",
                                    "--safe-writes", "-f", "-"], in: output, input: handle, failure: .extractFailed)
                try checkExtractedContents(output, preserving: quarantine)
                try validateItem(name, in: directory, expected: item.identity)
                try verifyDirectory(directory, at: folder)
                return try publishArchiveItem(outputName, from: staging, to: directory, at: folder,
                                              base: base, suffix: "")
            }
        }
    }

    private static func runArchiveTool(_ arguments: [String], in folder: URL, input: FileHandle? = nil,
                                       failure: FinderArchiveError) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure }
    }

    private static func verifyDirectory(_ directory: Int32, at folder: URL) throws {
        guard try directoryURL(for: directory).path == folder.path else { throw FinderFileError.unavailableFolder }
    }

    private static func publishArchiveItem(_ item: String, from staging: Int32, to directory: Int32,
                                           at folder: URL, base: String, suffix: String) throws -> URL {
        var sequence = 1
        while true {
            let ending = (sequence == 1 ? "" : " \(sequence)") + suffix
            var stem = base == "." || base == ".." ? L("归档") : base
            while stem.utf8.count + ending.utf8.count > Int(NAME_MAX) { stem.removeLast() }
            let name = (stem.isEmpty ? L("归档") : stem) + ending
            do {
                try renameExclusive(item, in: staging, to: name, in: directory)
                return folder.appendingPathComponent(name, isDirectory: suffix.isEmpty)
            } catch FinderFileError.alreadyExists {
                sequence += 1
            }
        }
    }

    private static func checkExtractedContents(_ directory: URL, preserving quarantine: Data?) throws {
        var listingError: Error?
        guard let files = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [], errorHandler: { _, error in
                listingError = error
                return false
            }
        ) else { throw FinderArchiveError.extractFailed }
        let root = directory.standardizedFileURL.pathComponents
        try writeQuarantine(quarantine, to: directory)
        for case let file as URL in files {
            var details = stat()
            guard lstat(file.path, &details) == 0 else { throw FinderFileError(errno: errno) }
            switch details.st_mode & S_IFMT {
            case S_IFREG, S_IFDIR:
                try writeQuarantine(quarantine, to: file)
            case S_IFLNK:
                files.skipDescendants()
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
                let components = file.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.pathComponents
                guard !target.hasPrefix("/"), components.starts(with: root) else {
                    throw FinderArchiveError.unsafeContents
                }
            default:
                throw FinderArchiveError.unsafeContents
            }
        }
        if let listingError { throw listingError }
    }

    private static func readQuarantine(_ file: Int32) throws -> Data? {
        let size = fgetxattr(file, quarantineAttribute, nil, 0, 0, 0)
        if size < 0, errno == ENOATTR || errno == ENOTSUP { return nil }
        guard size >= 0 else { throw FinderFileError(errno: errno) }
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let copied = data.withUnsafeMutableBytes {
            fgetxattr(file, quarantineAttribute, $0.baseAddress, $0.count, 0, 0)
        }
        guard copied >= 0 else { throw FinderFileError(errno: errno) }
        data.count = copied
        return data
    }

    private static func writeQuarantine(_ quarantine: Data?, to file: URL) throws {
        guard let quarantine else { return }
        let result = quarantine.withUnsafeBytes {
            setxattr(file.path, quarantineAttribute, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw FinderFileError(errno: errno) }
    }
}
