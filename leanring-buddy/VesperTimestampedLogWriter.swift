//
//  VesperTimestampedLogWriter.swift
//  leanring-buddy
//
//  Writes everything Vesper prints (and anything system frameworks write to
//  stderr) to ~/Library/Logs/Vesper.log with the date and time on every
//  line, so the log reads as a timeline of each interaction: hotkey, mic,
//  transcript, voice check, Claude, speech, actions, errors.
//  scripts/vesper-log-report.py reads it back and lists what went right and
//  what went wrong.
//
//  stdout and stderr are pointed at a pipe; a background reader stamps each
//  line and appends it to the file. Past 5 MB the file is kept as
//  Vesper.log.1 (replacing an older one) so recent history survives.
//

import Foundation

nonisolated final class VesperTimestampedLogWriter: @unchecked Sendable {
    static let maximumLogFileBytes = 5 * 1024 * 1024

    private let logFileURL: URL
    private let pipe = Pipe()
    private var logFileHandle: FileHandle?
    private var unfinishedLineBytes = Data()
    private var bytesWrittenSinceOpen = 0
    private let lineStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(logFileURL: URL) {
        self.logFileURL = logFileURL
    }

    /// Redirects stdout and stderr into the stamping pipe. Call once, early.
    func start() {
        openLogFile()
        let pipeWriteDescriptor = pipe.fileHandleForWriting.fileDescriptor
        dup2(pipeWriteDescriptor, STDOUT_FILENO)
        dup2(pipeWriteDescriptor, STDERR_FILENO)
        // Line buffering: each line reaches the pipe as it's printed.
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] readableHandle in
            let newlyAvailableBytes = readableHandle.availableData
            guard !newlyAvailableBytes.isEmpty else { return }
            self?.appendStampedLines(from: newlyAvailableBytes)
        }
    }

    private func openLogFile() {
        let existingSize = (try? FileManager.default.attributesOfItem(atPath: logFileURL.path)[.size] as? Int) ?? 0
        if existingSize > Self.maximumLogFileBytes {
            keepCurrentLogAsPrevious()
        }
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        logFileHandle = try? FileHandle(forWritingTo: logFileURL)
        _ = try? logFileHandle?.seekToEnd()
        bytesWrittenSinceOpen = (try? FileManager.default.attributesOfItem(atPath: logFileURL.path)[.size] as? Int) ?? 0
    }

    private func keepCurrentLogAsPrevious() {
        let previousLogFileURL = logFileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previousLogFileURL)
        try? FileManager.default.moveItem(at: logFileURL, to: previousLogFileURL)
    }

    /// Runs on the pipe's reader thread only.
    private func appendStampedLines(from newlyAvailableBytes: Data) {
        unfinishedLineBytes.append(newlyAvailableBytes)
        var stampedOutput = ""
        while let newlineIndex = unfinishedLineBytes.firstIndex(of: 0x0A) {
            let lineBytes = unfinishedLineBytes[unfinishedLineBytes.startIndex..<newlineIndex]
            unfinishedLineBytes.removeSubrange(unfinishedLineBytes.startIndex...newlineIndex)
            let lineText = String(decoding: lineBytes, as: UTF8.self)
            stampedOutput += "[\(lineStampFormatter.string(from: Date()))] \(lineText)\n"
        }
        guard !stampedOutput.isEmpty, let stampedData = stampedOutput.data(using: .utf8) else { return }
        logFileHandle?.write(stampedData)
        bytesWrittenSinceOpen += stampedData.count
        if bytesWrittenSinceOpen > Self.maximumLogFileBytes {
            try? logFileHandle?.close()
            keepCurrentLogAsPrevious()
            openLogFile()
        }
    }
}
