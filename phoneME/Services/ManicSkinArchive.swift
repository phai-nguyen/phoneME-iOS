import Foundation

enum ManicSkinArchiveError: LocalizedError {
    case unreadable
    case tooLarge
    case invalidZip
    case encrypted
    case unsupportedCompression
    case unsafePath
    case invalidEntry
    case missingInfo
    case inflateFailed
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return L10n.string("The selected ManicEMU skin could not be read.")
        case .tooLarge:
            return L10n.string("The ManicEMU skin archive is too large.")
        case .invalidZip:
            return L10n.string("The selected file is not a valid ManicEMU skin archive.")
        case .encrypted:
            return L10n.string("Encrypted ManicEMU skin archives are not supported.")
        case .unsupportedCompression:
            return L10n.string("This ManicEMU skin uses an unsupported ZIP compression method.")
        case .unsafePath:
            return L10n.string("The ManicEMU skin contains an unsafe file path.")
        case .invalidEntry:
            return L10n.string("The ManicEMU skin contains an invalid archive entry.")
        case .missingInfo:
            return L10n.string("The ManicEMU skin does not contain info.json.")
        case .inflateFailed:
            return L10n.string("A ManicEMU skin asset could not be decompressed.")
        case .checksumMismatch:
            return L10n.string("A ManicEMU skin asset failed its integrity check.")
        }
    }
}

enum ManicSkinArchive {
    private static let maximumArchiveBytes = 32 * 1024 * 1024
    private static let maximumExpandedBytes = 64 * 1024 * 1024
    private static let maximumEntries = 512
    private static let endSignature: UInt32 = 0x06054b50
    private static let centralSignature: UInt32 = 0x02014b50
    private static let localSignature: UInt32 = 0x04034b50

    static func extract(from sourceURL: URL, to destinationURL: URL) throws {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maximumArchiveBytes {
            throw ManicSkinArchiveError.tooLarge
        }

        let archive: Data
        do {
            archive = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        } catch {
            throw ManicSkinArchiveError.unreadable
        }
        guard archive.count <= maximumArchiveBytes else {
            throw ManicSkinArchiveError.tooLarge
        }

        let endRecord = try findEndRecord(in: archive)
        let disk = try archive.readUInt16LE(at: endRecord + 4)
        let centralDisk = try archive.readUInt16LE(at: endRecord + 6)
        let diskEntries = try archive.readUInt16LE(at: endRecord + 8)
        let entryCount = try archive.readUInt16LE(at: endRecord + 10)
        let centralSize = Int(try archive.readUInt32LE(at: endRecord + 12))
        let centralOffset = Int(try archive.readUInt32LE(at: endRecord + 16))

        guard disk == 0, centralDisk == 0, diskEntries == entryCount,
              Int(entryCount) <= maximumEntries,
              centralOffset >= 0, centralSize >= 0,
              centralOffset <= archive.count - centralSize else {
            throw ManicSkinArchiveError.invalidZip
        }
        guard entryCount != UInt16.max,
              centralOffset != Int(UInt32.max),
              centralSize != Int(UInt32.max) else {
            throw ManicSkinArchiveError.invalidZip
        }

        try FileManager.default.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )

        var cursor = centralOffset
        var expandedTotal = 0
        var foundInfo = false

        for _ in 0..<Int(entryCount) {
            guard try archive.readUInt32LE(at: cursor) == centralSignature else {
                throw ManicSkinArchiveError.invalidZip
            }

            let flags = try archive.readUInt16LE(at: cursor + 8)
            let method = try archive.readUInt16LE(at: cursor + 10)
            let expectedCRC = try archive.readUInt32LE(at: cursor + 16)
            let compressedSize = Int(try archive.readUInt32LE(at: cursor + 20))
            let expandedSize = Int(try archive.readUInt32LE(at: cursor + 24))
            let nameLength = Int(try archive.readUInt16LE(at: cursor + 28))
            let extraLength = Int(try archive.readUInt16LE(at: cursor + 30))
            let commentLength = Int(try archive.readUInt16LE(at: cursor + 32))
            let localOffset = Int(try archive.readUInt32LE(at: cursor + 42))

            guard nameLength > 0, compressedSize >= 0, expandedSize >= 0,
                  localOffset >= 0,
                  compressedSize != Int(UInt32.max),
                  expandedSize != Int(UInt32.max),
                  localOffset != Int(UInt32.max) else {
                throw ManicSkinArchiveError.invalidEntry
            }

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            let nextCursor = nameEnd + extraLength + commentLength
            guard nameStart >= 0, nextCursor <= archive.count,
                  nextCursor <= centralOffset + centralSize else {
                throw ManicSkinArchiveError.invalidEntry
            }

            guard flags & 0x0001 == 0 else {
                throw ManicSkinArchiveError.encrypted
            }

            let nameData = archive.subdata(in: nameStart..<nameEnd)
            guard let name = String(data: nameData, encoding: .utf8),
                  isSafeFlatAssetName(name) else {
                throw ManicSkinArchiveError.unsafePath
            }

            cursor = nextCursor
            if name.hasSuffix("/") { continue }

            let lowerName = name.lowercased()
            let isInfo = lowerName == "info.json"
            let isSupportedAsset = [
                ".pdf", ".png", ".jpg", ".jpeg", ".webp", ".gif", ".caf"
            ].contains { lowerName.hasSuffix($0) }
            guard isInfo || isSupportedAsset else { continue }

            expandedTotal += expandedSize
            guard expandedTotal <= maximumExpandedBytes else {
                throw ManicSkinArchiveError.tooLarge
            }

            guard try archive.readUInt32LE(at: localOffset) == localSignature else {
                throw ManicSkinArchiveError.invalidEntry
            }
            let localNameLength = Int(try archive.readUInt16LE(at: localOffset + 26))
            let localExtraLength = Int(try archive.readUInt16LE(at: localOffset + 28))
            let payloadStart = localOffset + 30 + localNameLength + localExtraLength
            let payloadEnd = payloadStart + compressedSize
            guard payloadStart >= 0, payloadEnd >= payloadStart,
                  payloadEnd <= archive.count else {
                throw ManicSkinArchiveError.invalidEntry
            }

            let compressed = archive.subdata(in: payloadStart..<payloadEnd)
            let expanded: Data
            switch method {
            case 0:
                guard compressed.count == expandedSize else {
                    throw ManicSkinArchiveError.invalidEntry
                }
                expanded = compressed
            case 8:
                expanded = try inflateRaw(
                    compressed,
                    expectedSize: expandedSize
                )
            default:
                throw ManicSkinArchiveError.unsupportedCompression
            }

            guard Self.crc32(expanded) == expectedCRC else {
                throw ManicSkinArchiveError.checksumMismatch
            }

            let outputURL = destinationURL.appendingPathComponent(name)
            try expanded.write(to: outputURL, options: .atomic)
            if isInfo { foundInfo = true }
        }

        guard foundInfo else {
            throw ManicSkinArchiveError.missingInfo
        }
    }

    private static func findEndRecord(in data: Data) throws -> Int {
        guard data.count >= 22 else { throw ManicSkinArchiveError.invalidZip }
        let lowerBound = max(0, data.count - 65_557)
        for offset in stride(from: data.count - 22, through: lowerBound, by: -1) {
            if (try? data.readUInt32LE(at: offset)) == endSignature {
                let commentLength = Int((try? data.readUInt16LE(at: offset + 20)) ?? 0)
                if offset + 22 + commentLength == data.count {
                    return offset
                }
            }
        }
        throw ManicSkinArchiveError.invalidZip
    }

    private static func isSafeFlatAssetName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"),
              !name.contains("\\"),
              !name.contains(".."),
              !name.contains(":"),
              name.utf8.count <= 255 else {
            return false
        }
        return !name.contains("/") || name.hasSuffix("/")
    }

    private static func inflateRaw(
        _ compressed: Data,
        expectedSize: Int
    ) throws -> Data {
        guard expectedSize >= 0, expectedSize <= maximumExpandedBytes,
              compressed.count <= Int(UInt32.max),
              expectedSize <= Int(UInt32.max) else {
            throw ManicSkinArchiveError.tooLarge
        }
        if expectedSize == 0 {
            return Data()
        }

        var output = Data(count: expectedSize)
        var actualLength: UInt32 = 0
        let succeeded = compressed.withUnsafeBytes { sourceBuffer in
            output.withUnsafeMutableBytes { destinationBuffer in
                phoneME_inflate_raw_zip(
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress,
                    UInt32(compressed.count),
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress,
                    UInt32(expectedSize),
                    &actualLength
                )
            }
        }
        guard succeeded == 1, Int(actualLength) == expectedSize else {
            throw ManicSkinArchiveError.inflateFailed
        }
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1
                    ? (crc >> 1) ^ 0xedb8_8320
                    : crc >> 1
            }
        }
        return crc ^ 0xffff_ffff
    }
}

private extension Data {
    func readUInt16LE(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else {
            throw ManicSkinArchiveError.invalidZip
        }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= count - 4 else {
            throw ManicSkinArchiveError.invalidZip
        }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
