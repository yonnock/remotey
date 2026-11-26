import Foundation

/// Running a command line tool and fetching a page, each with a time limit. Both block the calling thread,
/// so they belong on a background queue: a tool that hangs must never hold up the menu.
enum Command {
    struct Result: Equatable {
        /// Nil when the tool was stopped at its time limit.
        var status: Int32?
        var stdout: String
        var stderr: String

        var timedOut: Bool { status == nil }
        var succeeded: Bool { status == 0 }
    }

    /// Runs `path` with `arguments` and gives `output` every piece of stdout and stderr as it arrives, for a
    /// tool that prints a link and then waits. Injected, so tests answer with recorded outputs.
    typealias Run = (_ path: String, _ arguments: [String], _ limit: TimeInterval, _ output: ((String) -> Void)?) -> Result

    /// What a GET answered: the status and the body, or why there was no answer.
    typealias Fetch = (_ url: URL, _ limit: TimeInterval) -> Swift.Result<(status: Int, body: Data), URLError>

    static func run(_ path: String, _ arguments: [String], limit: TimeInterval, output: ((String) -> Void)?) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // A tool that asks something would wait for an answer forever.
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let lock = NSLock()
        var stdout = Data(), stderr = Data()
        let streams = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            streams.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    streams.leave()
                    return
                }
                lock.lock()
                if isOut { stdout.append(chunk) } else { stderr.append(chunk) }
                lock.unlock()
                output?(String(decoding: chunk, as: UTF8.self))
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return Result(status: 127, stdout: "", stderr: error.localizedDescription)
        }

        var timedOut = false
        if exited.wait(timeout: .now() + limit) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        // The last bytes may still be in the pipes when the process is gone.
        _ = streams.wait(timeout: .now() + 1)
        lock.lock()
        defer { lock.unlock() }
        return Result(status: timedOut ? nil : process.terminationStatus,
                      stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }

    static func fetch(_ url: URL, limit: TimeInterval) -> Swift.Result<(status: Int, body: Data), URLError> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = limit
        configuration.timeoutIntervalForResource = limit
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let lock = NSLock()
        var result: Swift.Result<(status: Int, body: Data), URLError> = .failure(URLError(.timedOut))
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: url) { data, response, error in
            lock.lock()
            if let response = response as? HTTPURLResponse {
                result = .success((response.statusCode, data ?? Data()))
            } else {
                result = .failure(error as? URLError ?? URLError(.badServerResponse))
            }
            lock.unlock()
            done.signal()
        }.resume()
        // The session keeps its own limit; this one only guards against a session that never calls back.
        _ = done.wait(timeout: .now() + limit + 2)
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
