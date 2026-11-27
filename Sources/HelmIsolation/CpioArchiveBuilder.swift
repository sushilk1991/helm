import Foundation
import zlib

public struct CpioEntry: Sendable, Equatable {
    public let path: String
    public let mode: UInt32
    public let data: Data

    public init(path: String, mode: UInt32, data: Data) {
        self.path = path
        self.mode = mode
        self.data = data
    }
}

public enum CpioArchiveBuilder {
    public static func buildNewcArchive(files: [CpioEntry]) -> Data {
        var archive = Data()
        var inode: UInt32 = 1

        for entry in files {
            var cleanPath = entry.path
            while cleanPath.hasPrefix("/") {
                cleanPath.removeFirst()
            }
            if cleanPath.isEmpty { continue }

            appendEntry(
                to: &archive,
                ino: inode,
                mode: entry.mode,
                nlink: 1,
                name: cleanPath,
                payload: entry.data
            )
            inode &+= 1
        }

        appendEntry(
            to: &archive,
            ino: 0,
            mode: 0,
            nlink: 1,
            name: "TRAILER!!!",
            payload: Data()
        )

        let remainder = archive.count % 512
        if remainder != 0 {
            archive.append(Data(repeating: 0, count: 512 - remainder))
        }
        return archive
    }

    private static func appendEntry(
        to archive: inout Data,
        ino: UInt32,
        mode: UInt32,
        nlink: UInt32,
        name: String,
        payload: Data
    ) {
        var nameData = Data(name.utf8)
        nameData.append(0)
        let nameSize = UInt32(nameData.count)
        let fileSize = UInt32(payload.count)

        let header = String(
            format: "070701%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x",
            ino,
            mode,
            0, // uid
            0, // gid
            nlink,
            0, // mtime
            fileSize,
            0, // devmajor
            0, // devminor
            0, // rdevmajor
            0, // rdevminor
            nameSize,
            0 // check
        )

        archive.append(Data(header.utf8))
        archive.append(nameData)

        let headerPlusName = 110 + nameData.count
        let namePad = (4 - (headerPlusName % 4)) % 4
        if namePad > 0 {
            archive.append(Data(repeating: 0, count: namePad))
        }

        if !payload.isEmpty {
            archive.append(payload)
            let dataPad = (4 - (payload.count % 4)) % 4
            if dataPad > 0 {
                archive.append(Data(repeating: 0, count: dataPad))
            }
        }
    }

    public static func gzipCompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw HelmIsolationError.invalidKernelImage("zlib deflateInit2_ failed (\(initStatus))")
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 65_536
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        try data.withUnsafeBytes { srcRaw in
            let srcBytes = srcRaw.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer(mutating: srcBytes.baseAddress)
            stream.avail_in = uInt(data.count)

            while true {
                let status: Int32 = buffer.withUnsafeMutableBytes { dstRaw in
                    let dstBytes = dstRaw.bindMemory(to: Bytef.self)
                    stream.next_out = dstBytes.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return deflate(&stream, Z_FINISH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: buffer[0..<produced])
                }
                if status == Z_STREAM_END {
                    break
                }
                if status != Z_OK && status != Z_BUF_ERROR {
                    throw HelmIsolationError.invalidKernelImage("zlib deflate failed (\(status))")
                }
                if produced == 0 && stream.avail_out != 0 {
                    throw HelmIsolationError.invalidKernelImage("zlib deflate stalled (\(status))")
                }
            }
        }

        return output
    }

    public static func gzipDecompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            throw HelmIsolationError.invalidKernelImage("Cannot decompress empty gzip payload.")
        }

        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            MAX_WBITS + 16,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw HelmIsolationError.invalidKernelImage("zlib inflateInit2_ failed (\(initStatus))")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 131_072
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        try data.withUnsafeBytes { srcRaw in
            let srcBytes = srcRaw.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer(mutating: srcBytes.baseAddress)
            stream.avail_in = uInt(data.count)

            while true {
                let status: Int32 = buffer.withUnsafeMutableBytes { dstRaw in
                    let dstBytes = dstRaw.bindMemory(to: Bytef.self)
                    stream.next_out = dstBytes.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: buffer[0..<produced])
                }
                if status == Z_STREAM_END {
                    break
                }
                if status == Z_DATA_ERROR || status == Z_MEM_ERROR || status == Z_NEED_DICT || status == Z_STREAM_ERROR {
                    throw HelmIsolationError.invalidKernelImage("zlib inflate failed (\(status))")
                }
                if produced == 0 && stream.avail_in == 0 {
                    throw HelmIsolationError.invalidKernelImage("Truncated gzip payload before Z_STREAM_END.")
                }
            }
        }

        return output
    }
}
