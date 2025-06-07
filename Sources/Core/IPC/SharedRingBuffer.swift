// MARK: - SharedRingBuffer.swift
//
// POSIX shared memory transport between the Python backend and Swift.
// Swift reads from the ring buffer at ~60 Hz and publishes transcript
// fragments as `String` values.
import Combine
import Darwin
import Foundation

/// A 64 KB POSIX shared‐memory ring buffer with head/tail at bytes 0–7.
/// Swift side reads new bytes every 16 ms and publishes Strings.
public final class SharedRingBuffer {
    private let shmName = "/tc_rb"
    private let shmSize = 64 * 1024
    private var fd: Int32 = -1
    private var ptr: UnsafeMutableRawPointer!
    private var lockFd: Int32 = -1
    private var timer: DispatchSourceTimer?
    public let publisher = PassthroughSubject<String, Never>()

    public init?() {
        // 1. shm_open (create if needed)
        fd = shm_open(shmName, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        if fd == -1 {
            // Attempt to unlink stale segment and retry once
            shm_unlink(shmName)
            fd = shm_open(shmName, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
            guard fd != -1 else {
                print("SharedRingBuffer: Failed to create shared memory")
                return nil
            }
        }
        // 2. ftruncate (ensure size)
        guard ftruncate(fd, off_t(shmSize)) != -1 else {
            print("SharedRingBuffer: ftruncate failed")
            return nil
        }
        // 3. mmap
        guard let m = mmap(nil, shmSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
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

        startPolling()
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
                let capacity = self.shmSize - 8
                let available = head >= tail
                    ? Int(head - tail)
                    : Int(UInt32(capacity) - (tail - head))
                guard available > 0 else {
                    return
                }
                let start = 8 + Int(tail)
                let data: Data
                if start + available <= self.shmSize {
                    data = Data(bytes: self.ptr + start, count: available)
            } else {
                let part1 = self.shmSize - start
                let part2 = available - part1
                var tmp = Data(bytes: self.ptr + start, count: part1)
                tmp.append(Data(bytes: self.ptr + 8, count: part2))
                data = tmp
            }
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    self.publisher.send(text)
                }
                // advance tail = head
                self.writeUInt32(at: 4, value: head)
            }
        }
        timer?.resume()
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        return ptr.load(fromByteOffset: offset, as: UInt32.self)
    }

    private func writeUInt32(at offset: Int, value: UInt32) {
        ptr.storeBytes(of: value, toByteOffset: offset, as: UInt32.self)
    }

    deinit {
        timer?.cancel()
        munmap(ptr, shmSize)
        close(fd)
        if lockFd != -1 {
            close(lockFd)
        }
        shm_unlink(shmName)
    }
}
