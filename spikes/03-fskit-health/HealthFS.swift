// Spike 03: minimal path-backed FSKit module ("healthfs").
// Purpose: determine whether fskitd on this macOS build accepts a
// third-party, path-resource FSKit module from an unprivileged user.
// Read-only volume containing exactly one file, HEALTH.txt.

import ExtensionFoundation
import FSKit
import Foundation

let healthContent = Data("healthfs alive\n".utf8)

@main
struct HealthFSExtension: UnaryFileSystemExtension {
    var fileSystem: HealthFS { HealthFS() }
}

final class HealthFS: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    func probeResource(
        resource: FSResource,
        replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        reply(.usable(name: "healthfs", containerID: FSContainerIdentifier()), nil)
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        reply(HealthVolume(), nil)
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        reply(nil)
    }
}

final class HealthItem: FSItem {
    let name: FSFileName
    let attrs = FSItem.Attributes()
    init(name: String, id: UInt64, type: FSItem.ItemType, size: UInt64) {
        self.name = FSFileName(string: name)
        super.init()
        attrs.fileID = FSItem.Identifier(rawValue: id) ?? .invalid
        attrs.parentID = .rootDirectory
        attrs.type = type
        attrs.mode = type == .directory ? 0o40555 : 0o100444
        attrs.linkCount = 1
        attrs.uid = getuid()
        attrs.gid = getgid()
        attrs.size = size
        attrs.allocSize = size
        var now = timespec(); clock_gettime(CLOCK_REALTIME, &now)
        attrs.modifyTime = now; attrs.changeTime = now
        attrs.accessTime = now; attrs.birthTime = now
    }
}

let eROFS = fs_errorForPOSIXError(POSIXError.EROFS.rawValue)
let eNOENT = fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)

final class HealthVolume: FSVolume {
    let root = HealthItem(name: "/", id: FSItem.Identifier.rootDirectory.rawValue,
                          type: .directory, size: 0)
    let file = HealthItem(name: "HEALTH.txt", id: 64,
                          type: .file, size: UInt64(healthContent.count))

    init() {
        super.init(volumeID: FSVolume.Identifier(uuid: UUID()),
                   volumeName: FSFileName(string: "HealthFS"))
    }
}

extension HealthVolume: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
}

extension HealthVolume: FSVolume.Operations {
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities()
        c.supportsHardLinks = false
        c.supportsSymbolicLinks = false
        c.supportsPersistentObjectIDs = true
        c.doesNotSupportVolumeSizes = true
        return c
    }

    var volumeStatistics: FSStatFSResult {
        let s = FSStatFSResult(fileSystemTypeName: "healthfs")
        s.blockSize = 4096
        s.ioSize = 4096
        s.totalBlocks = 1
        s.availableBlocks = 0
        s.freeBlocks = 0
        s.totalFiles = 2
        s.freeFiles = 0
        return s
    }

    func activate(options: FSTaskOptions,
                  replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        reply(root, nil)
    }

    func deactivate(options: FSDeactivateOptions,
                    replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func mount(options: FSTaskOptions,
               replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        reply()
    }

    func synchronize(flags: FSSyncFlags,
                     replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func getAttributes(_ desired: FSItem.GetAttributesRequest, of item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let it = item as? HealthItem else { return reply(nil, eNOENT) }
        reply(it.attrs, nil)
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        reply(nil, eROFS)
    }

    func lookupItem(named name: FSFileName, inDirectory dir: FSItem,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        if name.string == "HEALTH.txt" { reply(file, file.name, nil) }
        else { reply(nil, nil, eNOENT) }
    }

    func reclaimItem(_ item: FSItem,
                     replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func readSymbolicLink(_ item: FSItem,
                          replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, eNOENT)
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory dir: FSItem,
                    attributes: FSItem.SetAttributesRequest,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, eROFS)
    }

    func createSymbolicLink(named name: FSFileName, inDirectory dir: FSItem,
                            attributes: FSItem.SetAttributesRequest, linkContents: FSFileName,
                            replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, eROFS)
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory dir: FSItem,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, eROFS)
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory dir: FSItem,
                    replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(eROFS)
    }

    func renameItem(_ item: FSItem, inDirectory src: FSItem, named srcName: FSFileName,
                    to destName: FSFileName, inDirectory dest: FSItem, overItem: FSItem?,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, eROFS)
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker,
                            replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        // Entries in cookie order: 0=".", 1="..", 2=HEALTH.txt, 3=end.
        let entries: [(String, FSItem.ItemType, HealthItem)] = [
            (".", .directory, root), ("..", .directory, root),
            ("HEALTH.txt", .file, file),
        ]
        var i = Int(cookie.rawValue)
        while i < entries.count {
            let (n, t, it) = entries[i]
            let ok = packer.packEntry(name: FSFileName(string: n), itemType: t,
                                      itemID: it.attrs.fileID,
                                      nextCookie: FSDirectoryCookie(UInt64(i + 1)),
                                      attributes: attributes != nil ? it.attrs : nil)
            if !ok { break }
            i += 1
        }
        reply(FSDirectoryVerifier(1), nil)
    }
}

extension HealthVolume: FSVolume.OpenCloseOperations {
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes,
                  replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes,
                   replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }
}

extension HealthVolume: FSVolume.ReadWriteOperations {
    func read(from item: FSItem, at offset: off_t, length: Int,
              into buffer: FSMutableFileDataBuffer,
              replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        guard item === file else { return reply(0, eNOENT) }
        let start = min(Int(offset), healthContent.count)
        let end = min(start + length, healthContent.count)
        let chunk = healthContent[start..<end]
        var n = 0
        chunk.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                n = min(src.count, dst.count)
                if n > 0 { dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<n])) }
            }
        }
        reply(n, nil)
    }

    func write(contents data: Data, to item: FSItem, at offset: off_t,
               replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        reply(0, eROFS)
    }
}
