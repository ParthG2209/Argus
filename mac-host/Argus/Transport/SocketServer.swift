//
//  SocketServer.swift
//  Argus
//
//  Plain POSIX TCP socket servers bound to 127.0.0.1. Two flavours:
//    - FrameSocketServer:  Mac -> Tablet, writes [4-byte BE length][payload]
//    - LineSocketServer:   Tablet -> Mac, reads newline-delimited JSON lines
//
//  Each server accepts a single client at a time (one tablet).
//

import Foundation
import Darwin
import os

private func makeListeningSocket(port: UInt16) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    // Avoid SIGPIPE crashing the process when the tablet disconnects.
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("0.0.0.0")

    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        NSLog("[Argus] bind failed on port \(port): \(String(cString: strerror(errno)))")
        close(fd)
        return nil
    }
    guard listen(fd, 1) == 0 else {
        close(fd)
        return nil
    }
    return fd
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var ok = true
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var sent = 0
        let total = raw.count
        while sent < total {
            let n = send(fd, base + sent, total - sent, 0)
            if n <= 0 {
                ok = false
                return
            }
            sent += n
        }
    }
    return ok
}

// MARK: - Outbound (Mac -> Tablet) framed server

final class FrameSocketServer {
    private let port: UInt16
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private let acceptQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private var running = false

    // Backpressure: cap frames in flight on the write queue. When USB can't
    // drain fast enough (heavy full-screen motion), drop new frames instead of
    // queuing them — queuing would grow latency without bound. 0 = unlimited.
    private let maxInFlight: Int
    private let inFlight = OSAllocatedUnfairLock(initialState: 0)

    /// Optional frame written to the socket FIRST, synchronously, before the
    /// client is exposed to other senders — guarantees it precedes all other
    /// frames (used for the codec handshake on the video stream).
    var connectFrame: (() -> Data)?

    /// Called when a client connects (after the connect frame is written).
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    /// Called when a frame is dropped due to backpressure (maxInFlight).
    var onFrameDropped: (() -> Void)?

    /// - Parameter maxInFlight: max queued frames before dropping (0 = no cap).
    ///   Use a small value for video (drop to stay current); 0 for audio.
    init(port: UInt16, label: String, maxInFlight: Int = 0) {
        self.port = port
        self.maxInFlight = maxInFlight
        self.acceptQueue = DispatchQueue(label: "com.argus.\(label).accept")
        self.writeQueue = DispatchQueue(label: "com.argus.\(label).write",
                                        qos: .userInteractive)
    }

    var hasClient: Bool { clientFD >= 0 }
    
    var inFlightCount: Int { inFlight.withLock { $0 } }

    func start() -> Bool {
        guard let fd = makeListeningSocket(port: port) else { return false }
        listenFD = fd
        running = true
        acceptQueue.async { [weak self] in self?.acceptLoop() }
        NSLog("[Argus] FrameSocketServer listening on \(port).")
        return true
    }

    private func acceptLoop() {
        while running {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if !running { break }
                usleep(100_000)
                continue
            }
            // Replace any prior client.
            if clientFD >= 0 { close(clientFD) }
            var yes: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            
            // Limit kernel send buffer to force backpressure to user-space quickly
            // 64KB is enough for P-frames, but forces blocking on Wi-Fi congestion
            var sndBuf: Int32 = 65536
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))

            // Write the connect frame (codec handshake) BEFORE exposing the
            // socket via clientFD, so no video frame can race ahead of it.
            if let payload = connectFrame?() {
                var header = UInt32(payload.count).bigEndian
                var packet = Data(bytes: &header, count: 4)
                packet.append(payload)
                _ = writeAll(fd, packet)
            }

            clientFD = fd
            NSLog("[Argus] FrameSocketServer(\(port)) client connected.")
            onClientConnected?()
        }
    }

    /// Send one length-prefixed frame. Drops the frame if the write queue is
    /// already saturated (see maxInFlight).
    func send(frame: Data) {
        if maxInFlight > 0 {
            let drop = inFlight.withLock { count -> Bool in
                if count >= maxInFlight { return true }
                count += 1
                return false
            }
            if drop {
                onFrameDropped?()  // ask the encoder for a recovery keyframe
                return             // USB backed up — skip this frame to stay live
            }
        }

        writeQueue.async { [weak self] in
            guard let self else { return }
            defer { if self.maxInFlight > 0 { self.inFlight.withLock { $0 -= 1 } } }
            guard self.clientFD >= 0 else { return }
            var header = UInt32(frame.count).bigEndian
            var packet = Data(bytes: &header, count: 4)
            packet.append(frame)
            if !writeAll(self.clientFD, packet) {
                NSLog("[Argus] FrameSocketServer(\(self.port)) write failed; dropping client.")
                close(self.clientFD)
                self.clientFD = -1
                self.onClientDisconnected?()
            }
        }
    }

    func stop() {
        running = false
        if clientFD >= 0 { close(clientFD); clientFD = -1 }
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }
}

// MARK: - Inbound (Tablet -> Mac) line server

final class LineSocketServer {
    private let port: UInt16
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private let queue: DispatchQueue
    private var running = false

    /// Called for each newline-delimited line received.
    var onLine: ((String) -> Void)?

    init(port: UInt16, label: String) {
        self.port = port
        self.queue = DispatchQueue(label: "com.argus.\(label)")
    }

    func start() -> Bool {
        guard let fd = makeListeningSocket(port: port) else { return false }
        listenFD = fd
        running = true
        queue.async { [weak self] in self?.acceptLoop() }
        NSLog("[Argus] LineSocketServer listening on \(port).")
        return true
    }

    private func acceptLoop() {
        while running {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if !running { break }
                usleep(100_000)
                continue
            }
            clientFD = fd
            NSLog("[Argus] LineSocketServer(\(port)) client connected.")
            readLoop(fd)
            close(fd)
            clientFD = -1
        }
    }

    private func readLoop(_ fd: Int32) {
        var buffer = Data()
        let chunkSize = 16 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while running {
            let n = recv(fd, &chunk, chunkSize, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            // Split on newline.
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8),
                   !line.isEmpty {
                    onLine?(line)
                }
            }
            // Guard against unbounded growth on a malformed stream.
            if buffer.count > 1 << 20 { buffer.removeAll(keepingCapacity: true) }
        }
    }

    func stop() {
        running = false
        if clientFD >= 0 { close(clientFD); clientFD = -1 }
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }
}
