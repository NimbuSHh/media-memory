import CryptoKit
import Foundation

struct MediaFileSnapshot: Equatable, Sendable {
    let fileSize: Int64
    let modificationDate: Date
    let fileIdentifier: String?
}

enum FileFingerprint {
    private static let sampleSize = 64 * 1_024

    static func snapshot(for url: URL) throws -> MediaFileSnapshot {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .isRegularFileKey
        ])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate else {
            throw MediaScanError.invalidRegularFile(url.path)
        }
        return MediaFileSnapshot(
            fileSize: Int64(fileSize),
            modificationDate: modificationDate,
            fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) }
        )
    }

    static func lightFingerprint(for url: URL, snapshot: MediaFileSnapshot) throws -> String {
        var input = metadata(snapshot: snapshot)
        input.append(try sampledBytes(for: url, snapshot: snapshot))
        return digest(input)
    }

    /// Identifies the copied bytes without depending on filesystem timestamp
    /// precision, which can differ between NAS and local volumes.
    static func sampledContentFingerprint(
        for url: URL,
        snapshot: MediaFileSnapshot
    ) throws -> String {
        var input = Data("\(snapshot.fileSize)|".utf8)
        input.append(try sampledBytes(for: url, snapshot: snapshot))
        return digest(input)
    }

    private static func sampledBytes(
        for url: URL,
        snapshot: MediaFileSnapshot
    ) throws -> Data {
        var input = Data()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        if let prefix = try handle.read(upToCount: sampleSize) {
            input.append(prefix)
        }
        if snapshot.fileSize > Int64(sampleSize) {
            let offset = UInt64(max(0, snapshot.fileSize - Int64(sampleSize)))
            try handle.seek(toOffset: offset)
            if let suffix = try handle.read(upToCount: sampleSize) {
                input.append(suffix)
            }
        }
        return input
    }

    static func metadataFingerprint(snapshot: MediaFileSnapshot) -> String {
        "metadata-\(digest(metadata(snapshot: snapshot)))"
    }

    private static func metadata(snapshot: MediaFileSnapshot) -> Data {
        Data(
            "\(snapshot.fileSize)|\(snapshot.modificationDate.timeIntervalSince1970)"
                .utf8
        )
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
