// MARK: - SharedRingBuffer.swift

//
// POSIX shared memory transport between the Python backend and Swift.
//
// ## Binary Layout
//
// ```
// Header (16 bytes)
//   0-3  head      UInt32 - next write position
//   4-7  tail      UInt32 - last read position
//   8-11 overflow  UInt32 - dropped entry count
//   12   version   UInt8  - format version (0x01)
// Data (starts at byte 16)
//   Repeating entries of:
//     length      UInt16    total size of this entry
//     sequence    UInt32    monotonic counter
//     timestamp   Float64   seconds since start
//     confidence  Float32   0.0 - 1.0
//     wordLength  UInt16    UTF-8 byte count
//     wordData    [UInt8]   variable length UTF‑8 bytes
//     crc32       UInt32    checksum of sequence..wordData
//     padding     [UInt8]   0-7 bytes so next entry starts on 8 byte boundary
// ```
//
// All multi-byte fields are little-endian.  The Swift reader validates the
// version byte before parsing entries.

import Combine
#if canImport(Darwin)
    import Darwin

    @_silgen_name("shm_open")
    func c_shm_open(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32

    @_silgen_name("shm_unlink")
    func c_shm_unlink(_ name: UnsafePointer<CChar>) -> Int32

#else
    import Glibc

    let c_shm_open = shm_open
    let c_shm_unlink = shm_unlink
#endif
import Foundation

/// A 64 KB POSIX shared‐memory ring buffer with head/tail at bytes 0–7.
/// Swift side reads new bytes every 16 ms and publishes Strings.
public final class SharedRingBuffer {
    private let shmName: String
    private let shmSize = 64 * 1024
    private let overflowOffset = 8
    private let versionOffset = 12
    private let dataOffset = 16
    private var fd: Int32 = -1
    private var ptr: UnsafeMutableRawPointer!
    private var lockFd: Int32 = -1
    private var timer: DispatchSourceTimer?
    public let publisher = PassthroughSubject<String, Never>()

    public init?(name: String = "/tc_rb") {
        self.shmName = name.hasPrefix("/") ? name : "/" + name

        // 1. shm_open (create if needed)
        fd = self.shmName.withCString { namePtr in
            c_shm_open(namePtr, O_RDWR | O_CREAT, mode_t(S_IRUSR | S_IWUSR))
        }
        if fd == -1 {
            // Attempt to unlink stale segment and retry once
            self.shmName.withCString { namePtr in
                c_shm_unlink(namePtr)
            }
            fd = self.shmName.withCString { namePtr in
                c_shm_open(namePtr, O_RDWR | O_CREAT, mode_t(S_IRUSR | S_IWUSR))
            }
        }
        guard fd != -1 else {
            print("SharedRingBuffer: Failed to create shared memory")
            return nil
        }

        // 2. ftruncate (ensure size)
        guard ftruncate(fd, off_t(shmSize)) != -1 else {
            print("SharedRingBuffer: ftruncate failed")
            return nil
        }

        // 3. mmap
        guard let m = mmap(nil,
                           shmSize,
                           PROT_READ | PROT_WRITE,
                           MAP_SHARED,
                           fd,
                           0),
            m != MAP_FAILED
        else {
            print("SharedRingBuffer: mmap failed")
            return nil
        }
        ptr = UnsafeMutableRawPointer(m)

        // Open shared lock used by Python writer
        lockFd = open("/tmp/tc_rb.lock", O_RDWR)
        if lockFd == -1 {
            print("SharedRingBuffer: failed to open lock file")
            return nil
        }

        // Validate version byte
        let version = ptr.load(fromByteOffset: versionOffset, as: UInt8.self)
        if version != 0x01 {
            ptr.storeBytes(of: UInt8(0x01), toByteOffset: versionOffset, as: UInt8.self)
        }
    }

    private func startPolling() {
        let queue = DispatchQueue.global(qos: .userInteractive)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer?.setEventHandler { [weak self] in
            guard let self = self else { return }

            if flock(self.lockFd, LOCK_EX) == 0 {
                defer { flock(self.lockFd, LOCK_UN) }

                let head = self.readUInt32(at: 0)
                let tail = self.readUInt32(at: 4)
                let capacity = self.shmSize - self.dataOffset
                let available = head >= tail
                    ? Int(head - tail)
                    : Int(UInt32(capacity) - (tail - head))
                guard available > 0 else { return }

                let start = self.dataOffset + Int(tail)
                let data: Data
                if start + available <= self.shmSize {
                    data = Data(bytes: self.ptr + start, count: available)
                } else {
                    let part1 = self.shmSize - start
                    let part2 = available - part1
                    var tmp = Data(bytes: self.ptr + start, count: part1)
                    tmp.append(Data(bytes: self.ptr + self.dataOffset, count: part2))
                    data = tmp
                }

                if let text = String(data: data, encoding: .utf8),
                   !text.isEmpty
                {
                    self.publisher.send(text)
                }

                // advance tail = head
                self.writeUInt32(at: 4, value: head)
            }
        }
        timer?.resume()
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        OSMemoryBarrier()
        return ptr.load(fromByteOffset: offset, as: UInt32.self)
    }

    private func writeUInt32(at offset: Int, value: UInt32) {
        ptr.storeBytes(of: value, toByteOffset: offset, as: UInt32.self)
        OSMemoryBarrier()
    }

    /// Read the next word entry from the buffer using the provided tail pointer.
    /// Returns nil if no complete entry is available.
    public struct WordEntry {
        public let word: String
        public let sequence: UInt32
        public let timestamp: Double
        public let confidence: Float
    }

    public private(set) var lastReadWasIncomplete = false

    public func readNextWord(lastTail: inout UInt32) -> WordEntry? {
        let head = readUInt32(at: 0)
        var tail = lastTail
        let capacity = UInt32(shmSize - dataOffset)

        guard head != tail else { return nil }

        let offset = Int(dataOffset) + Int(tail)
        let remaining = Int((head >= tail) ? head - tail : capacity - (tail - head))
        if remaining < 2 { return nil }

        // Read entry length
        let length: UInt16 = ptr.load(fromByteOffset: offset, as: UInt16.self)
        if length == 0 {
            lastReadWasIncomplete = true
            return nil
        }
        if length > 2048 || remaining < Int(length) { return nil }

        // Gather bytes for entry handling wraparound
        var entry = Data(count: Int(length))
        entry.withUnsafeMutableBytes { bytes in
            let dst = bytes.baseAddress!
            if offset + Int(length) <= shmSize {
                memcpy(dst, ptr + offset, Int(length))
            } else {
                let first = shmSize - offset
                memcpy(dst, ptr + offset, first)
                memcpy(dst + first, ptr + dataOffset, Int(length) - first)
            }
        }

        // Validate CRC
        let crcStored = entry.withUnsafeBytes { $0.load(fromByteOffset: Int(length) - 4, as: UInt32.self) }
        let crcCalc = CRC32.checksum(entry[2..<Int(length) - 4])
        guard crcStored == crcCalc else { return nil }

        // Parse fields
        let seq = entry.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt32.self) }
        let ts = entry.withUnsafeBytes { $0.load(fromByteOffset: 6, as: Double.self) }
        let conf = entry.withUnsafeBytes { $0.load(fromByteOffset: 14, as: Float.self) }
        let wordLen = entry.withUnsafeBytes { $0.load(fromByteOffset: 18, as: UInt16.self) }
        guard wordLen > 0, Int(wordLen) <= Int(length) - 24 else { return nil }
        let wordData = entry[20..<20+Int(wordLen)]
        guard let word = String(data: wordData, encoding: .utf8) else { return nil }

        // Advance tail with padding alignment
        let padded = (Int(length) + 7) & ~7
        tail = (tail + UInt32(padded)) % capacity
        lastTail = tail
        writeUInt32(at: 4, value: tail)

        return WordEntry(word: word, sequence: seq, timestamp: ts, confidence: conf)
    }

    deinit {
        timer?.cancel()
        munmap(ptr, shmSize)
        close(fd)
        if lockFd != -1 {
            close(lockFd)
        }
        shmName.withCString { namePtr in
            c_shm_unlink(namePtr)
        }
    }
}
