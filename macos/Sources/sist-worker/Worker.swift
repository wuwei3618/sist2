import Foundation
import SistCore
import SistExtractors

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A parser process of the scan (sist2's `scan --worker`). Reads jobs on stdin, writes documents
/// on stdout, one job at a time, until stdin closes or the scan says bye. See WorkerProtocol.swift.
@main
enum Worker {
    static func main() {
        // Frames go out on a private copy of stdout, and fd 1 is pointed at stderr: anything a
        // framework prints can then never corrupt the frame stream (sist2 uses fds 3/4 for this)
        let frameOutput = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let channel = FrameChannel(readFD: STDIN_FILENO, writeFD: frameOutput)

        let environment = ProcessInfo.processInfo.environment
        // Let tests exercise the scan's timeout and crash handling
        let hangOn = environment["SIST_WORKER_TEST_HANG_ON"]
        let crashOn = environment["SIST_WORKER_TEST_CRASH_ON"]

        let decoder = JSONDecoder()
        var parser: DocumentParser?

        do {
            while let frame = try channel.read() {
                switch frame.type {
                case .configure:
                    let options = try decoder.decode(ScanOptions.self, from: frame.payload)
                    parser = DocumentParser(options: options) { message in
                        try? channel.write(.log, json: message)
                    }

                case .job:
                    let entry = try decoder.decode(FileEntry.self, from: frame.payload)
                    if let hangOn, entry.path.hasSuffix(hangOn) {
                        while true { sleep(60) }
                    }
                    if let crashOn, entry.path.hasSuffix(crashOn) {
                        abort()
                    }
                    guard let parser else {
                        try channel.write(.done, json: JobDone(error: "Worker was not configured"))
                        continue
                    }
                    var writeError: Error?
                    parser.parse(entry) { result in
                        guard writeError == nil else { return }
                        do {
                            try channel.write(.document, json: result.document)
                            for thumbnail in result.thumbnails {
                                try channel.write(Frame(type: .thumbnail, payload: thumbnail))
                            }
                        } catch {
                            writeError = error
                        }
                    }
                    if let writeError {
                        throw writeError
                    }
                    try channel.write(.done, json: JobDone())

                case .bye:
                    exit(0)

                default:
                    FileHandle.standardError.write(Data("sist-worker: unexpected frame \(frame.type)\n".utf8))
                }
            }
        } catch {
            // The scan went away or sent garbage: nothing to report to
            FileHandle.standardError.write(Data("sist-worker: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
