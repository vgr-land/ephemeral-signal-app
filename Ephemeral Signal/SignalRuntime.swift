// SignalRuntime.swift

import Foundation
import Combine
import AppKit

// Non-actor helper: turns a stream of bytes into newline-delimited lines.
private final class LineAccumulator {
    private var buffer = Data()

    func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var out: [String] = []

        while let nl = buffer.firstRange(of: Data([0x0A])) { // '\n'
            let lineData = buffer.subdata(in: 0..<nl.lowerBound)
            buffer.removeSubrange(0...nl.lowerBound)
            if let s = String(data: lineData, encoding: .utf8) {
                out.append(s)
            }
        }
        return out
    }
}

@MainActor
final class SignalRuntime: ObservableObject {
    // noVNC URL shown inside the app
    let webURL = URL(string: "https://localhost:6080/vnc.html?autoconnect=true&resize=remote&show_control_bar=false")!

    @Published var isStarting = true
    @Published var statusLine: String? = "Starting…"
    @Published var logText: String = ""

    // Notification/activity state for the macOS app
    @Published var hasActivity: Bool = false
    @Published var notificationCount: Int = 0

    private let containerName = "signal-novnc-ephemeral"
    private static let composeProject = "signal-novnc-ephemeral"
    private let imageName = "signal-novnc-ephemeral-signal"
    private var started = false
    private var stopped = false

    private var projectDir: URL?
    private let runId = UUID().uuidString

    // Long-running docker logs follower
    private var logFollower: Process?
    private var logFollowerPipe: Pipe?
    private var logFollowerAccumulator: LineAccumulator?

    // Where we stash a per-run copy of Dockerfile + docker-compose.yml
    private lazy var runDir: URL = {
        let fm = FileManager.default
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSup
            .appendingPathComponent("SignalNoVNC", isDirectory: true)
            .appendingPathComponent("Runs", isDirectory: true)
            .appendingPathComponent(runId, isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private lazy var logURL: URL = {
        let fm = FileManager.default
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSup.appendingPathComponent("SignalNoVNC", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("signal-runtime.log")
    }()

    // MARK: - Compose helpers

    /// Build compose args with a fixed project name so every launch reuses the
    /// same network / image names regardless of the working-directory path.
    private static func composeArgs(_ subcommand: String...) -> [String] {
        ["compose", "-p", composeProject] + subcommand
    }

    // MARK: - Public lifecycle

    func start() async {
        guard !started else { return }
        started = true
        stopped = false
        isStarting = true
        statusLine = "Starting…"

        await append("========== launch \(Date()) ==========")

        do {
            let docker = await ensureDocker()
            await append("docker: \(docker)")

            // Clean up any leftovers from a previous crashed run
            statusLine = "Cleaning up stale containers…"
            await cleanupPreviousRun(docker: docker)

            statusLine = "Preparing compose context…"
            let dir = try prepareComposeProject()
            self.projectDir = dir
            await append("compose project dir: \(dir.path)")

            statusLine = "Validating compose…"
            _ = try await runStreaming(command: docker, args: Self.composeArgs("config"), cwd: dir)

            statusLine = "Building image…"
            _ = try await runStreaming(command: docker, args: Self.composeArgs("build"), cwd: dir)

            statusLine = "Starting container…"
            _ = try await runStreaming(
                command: docker,
                args: Self.composeArgs("up", "-d"),
                cwd: dir
            )

            statusLine = "Container \(containerName) — waiting for noVNC…"
            await append("container: \(containerName)")

            startFollowingLogs(docker: docker, cid: containerName, cwd: dir)

            _ = try await runStreaming(command: docker, args: ["ps", "--no-trunc"], cwd: dir)

            try await waitForHTTPReady(url: URL(string: "https://localhost:6080/")!, timeoutSeconds: 90)

            isStarting = false
            statusLine = "Ready"
            await append("ready: \(webURL.absoluteString)")
        } catch {
            isStarting = false
            statusLine = "ERROR: \(error.localizedDescription)"
            await append("ERROR: \(error.localizedDescription)")
        }
    }

    /// Remove any leftover container, network, or image from a previous run
    /// that didn't shut down cleanly (crash, force-quit, etc.).
    private func cleanupPreviousRun(docker: String) async {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Force-remove the named container if it exists
        _ = try? await runStreaming(command: docker, args: ["rm", "-f", containerName], cwd: home)

        // Tear down any compose project with our fixed name (removes network too)
        // Need a valid compose file for this, so prepare a temporary one
        if let dir = projectDir ?? (try? prepareComposeProject()) {
            _ = try? await Self.runStreamingDetached(
                command: docker,
                args: Self.composeArgs("down", "--remove-orphans", "--rmi", "local"),
                cwd: dir,
                env: Self.processEnvironment(),
                onLine: nil
            )
        }

        // Prune any dangling networks left by old random-named compose projects
        _ = try? await runStreaming(command: docker, args: ["network", "prune", "-f"], cwd: home)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true

        stopFollowingLogs()

        let dir = projectDir
        projectDir = nil

        let dockerPath = Self.dockerPath
        let env = Self.processEnvironment()
        let logURL = self.logURL
        let runDir = self.runDir
        let containerName = self.containerName
        let imageName = self.imageName
        let downArgs = Self.composeArgs("down", "--remove-orphans", "--rmi", "local")

        // Run cleanup synchronously so applicationWillTerminate blocks
        // until Docker resources are fully removed.
        func fileAppend(_ s: String) {
            let line = "[signal] \(s)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let h = try? FileHandle(forWritingTo: logURL) {
                    try? h.write(contentsOf: data)
                    try? h.close()
                }
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }

        fileAppend("========== stop \(Date()) ==========")

        if let dir {
            fileAppend("stopping compose project (down --remove-orphans --rmi local)")
            Self.runSync(dockerPath, args: downArgs, cwd: dir, env: env)
        } else {
            fileAppend("removing container: \(containerName)")
            Self.runSync(dockerPath, args: ["rm", "-f", containerName],
                         cwd: FileManager.default.temporaryDirectory, env: env)
        }

        // Belt-and-suspenders: force-remove the image if compose down didn't get it
        fileAppend("removing image: \(imageName)")
        Self.runSync(dockerPath, args: ["rmi", "-f", imageName],
                     cwd: FileManager.default.temporaryDirectory, env: env)

        fileAppend("removing run dir: \(runDir.path)")
        try? FileManager.default.removeItem(at: runDir)
    }

    /// Runs a command synchronously, blocking the calling thread until it exits.
    /// Used during shutdown so the process doesn't exit before cleanup finishes.
    private nonisolated static func runSync(
        _ command: String,
        args: [String],
        cwd: URL,
        env: [String: String]
    ) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch { }
    }

    // MARK: - Log following (docker logs -f)

    private func startFollowingLogs(docker: String, cid: String, cwd: URL) {
        stopFollowingLogs()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: docker)
        p.arguments = ["logs", "-f", "--since=0s", cid]
        p.currentDirectoryURL = cwd
        p.environment = Self.processEnvironment()

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let accumulator = LineAccumulator()
        let handle = pipe.fileHandleForReading

        handle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { return }

            let lines = accumulator.append(chunk)
            if lines.isEmpty { return }

            // Hop to MainActor for ALL state/UI mutations
            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in lines where !line.isEmpty {
                    // Docker logs -f on detached containers prepends an 8-byte
                    // binary stream header to each frame. Strip any leading
                    // non-printable bytes so the line starts with the real text.
                    let cleaned = Self.stripDockerStreamHeader(line)

                    if cleaned.contains("[notify]") {
                        self.handleNotifyLine(cleaned)
                    }
                    self.appendSync(cleaned)
                }
            }
        }

        p.terminationHandler = { _ in
            handle.readabilityHandler = nil
        }

        do {
            try p.run()
            logFollower = p
            logFollowerPipe = pipe
            logFollowerAccumulator = accumulator
            appendSync("log follower attached: docker logs -f \(cid.prefix(12))…")
        } catch {
            appendSync("log follower error: \(error.localizedDescription)")
        }
    }

    private func stopFollowingLogs() {
        if let p = logFollower {
            p.terminate()
        }
        logFollower = nil
        logFollowerPipe = nil
        logFollowerAccumulator = nil
    }

    // MARK: - Notify parsing + macOS signal

    /// Docker multiplexed stream format prepends an 8-byte binary header
    /// (stream type + 3 padding + 4-byte big-endian length) to each frame.
    /// When the container is started detached (-d) and logs are followed,
    /// these headers appear as garbage bytes at the start of each line.
    /// Strip everything up to and including the first '[' that starts a
    /// recognisable token, or fall back to dropping leading non-printable bytes.
    private nonisolated static func stripDockerStreamHeader(_ raw: String) -> String {
        // Fast path: already clean
        if raw.first?.isASCII == true && raw.first?.isLetter == true || raw.hasPrefix("[") {
            return raw
        }
        // Drop leading bytes that aren't printable ASCII (the 8-byte header)
        var s = raw
        while let first = s.unicodeScalars.first,
              first.value < 0x20 || first.value > 0x7E {
            s = String(s.unicodeScalars.dropFirst())
        }
        return s
    }

    private func handleNotifyLine(_ line: String) {
        hasActivity = true
        notificationCount += 1
        NSApplication.shared.dockTile.badgeLabel = "\(notificationCount)"
    }
    
    /// Call this to clear the notification badge (e.g., when user opens app or views notifications)
    func clearNotifications() {
        notificationCount = 0
        NSApplication.shared.dockTile.badgeLabel = nil
        hasActivity = false
    }

    // MARK: - Project extraction (bundled Dockerfile + compose)

    private func prepareComposeProject() throws -> URL {
        try copyResource(named: "docker-compose", ext: "yml", to: runDir.appendingPathComponent("docker-compose.yml"))
        try copyResource(named: "Dockerfile", ext: nil, to: runDir.appendingPathComponent("Dockerfile"))
        return runDir
    }

    private func copyResource(named name: String, ext: String?, to dst: URL) throws {
        guard let src = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw RuntimeError("Missing bundled resource: \(name)\(ext.map { ".\($0)" } ?? "") — add it to Copy Bundle Resources.")
        }
        if FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: src, to: dst)
    }

    // MARK: - Docker env / path

    private static let dockerPath = "/usr/local/bin/docker"

    /// Show a critical alert and terminate the app.
    private static func fatalAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }

    /// Verify Docker is installed and the daemon is running.
    /// If Docker.app exists but the daemon isn't up, launch it and wait up to 60s.
    /// Shows an NSAlert and terminates on failure.
    private func ensureDocker() async -> String {
        // 1. Check if the docker CLI binary exists
        guard FileManager.default.isExecutableFile(atPath: Self.dockerPath) else {
            Self.fatalAlert("Docker is not installed.")
            return Self.dockerPath // unreachable, terminate called above
        }

        // 2. Check if the daemon is already running
        let env = Self.processEnvironment()
        let home = FileManager.default.homeDirectoryForCurrentUser
        if (try? await Self.runStreamingDetached(
            command: Self.dockerPath, args: ["version"], cwd: home, env: env, onLine: nil
        )) != nil {
            return Self.dockerPath
        }

        // 3. Daemon not running — try to launch Docker Desktop
        await append("Docker daemon not running, launching Docker Desktop…")
        statusLine = "Waiting for Docker Desktop to start…"
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Docker.app"))

        let start = Date()
        while Date().timeIntervalSince(start) < 60 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if (try? await Self.runStreamingDetached(
                command: Self.dockerPath, args: ["version"], cwd: home, env: env, onLine: nil
            )) != nil {
                await append("Docker Desktop is ready.")
                return Self.dockerPath
            }
        }

        Self.fatalAlert("Docker failed to start in time.")
        return Self.dockerPath // unreachable
    }

    private static func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let pathParts = [
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/Applications/Docker.app/Contents/Resources/bin"
        ]
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = (pathParts + [existing]).joined(separator: ":")
        } else {
            env["PATH"] = pathParts.joined(separator: ":")
        }
        return env
    }

    // MARK: - Streaming runner (command runner used during build/start)

    private func runStreaming(command: String, args: [String], cwd: URL) async throws -> String {
        await append("$ \(command) \(args.joined(separator: " "))")
        await append("cwd: \(cwd.path)")
        let env = Self.processEnvironment()
        await append("PATH: \(env["PATH"] ?? "")")

        return try await Self.runStreamingDetached(
            command: command,
            args: args,
            cwd: cwd,
            env: env,
            onLine: { line in
                Task { @MainActor in
                    let cleaned = Self.stripDockerStreamHeader(line)
                    if cleaned.contains("[notify]") {
                        self.handleNotifyLine(cleaned)
                    }
                    self.appendSync(cleaned)
                }
            }
        )
    }

    private static func runStreamingDetached(
        command: String,
        args: [String],
        cwd: URL,
        env: [String: String],
        onLine: (@Sendable (String) -> Void)?
    ) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: command)
            p.arguments = args
            p.currentDirectoryURL = cwd
            p.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe

            let collector = OutputCollector()

            let outHandle = outPipe.fileHandleForReading
            let errHandle = errPipe.fileHandleForReading

            func installReadableHandler(_ handle: FileHandle) {
                handle.readabilityHandler = { h in
                    let chunk = h.availableData
                    if chunk.isEmpty { return }
                    collector.append(chunk)
                    if let s = String(data: chunk, encoding: .utf8) {
                        for line in s.split(whereSeparator: \.isNewline) {
                            onLine?(String(line))
                        }
                    }
                }
            }

            installReadableHandler(outHandle)
            installReadableHandler(errHandle)

            p.terminationHandler = { _ in
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil

                let all = collector.snapshot()
                let text = String(data: all, encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    cont.resume(returning: text)
                } else {
                    let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: RuntimeError("Command failed (\(p.terminationStatus)): \(msg.isEmpty ? "unknown error" : msg)"))
                }
            }

            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    // Thread-safe accumulator for captured output
    final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            let copy = data
            lock.unlock()
            return copy
        }
    }

    // MARK: - Logging helpers

    private func append(_ s: String) async { appendSync(s) }

    private func appendSync(_ s: String) {
        let line = "[signal] \(s)"
        logText.append(line + "\n")
        writeToFile(line)
    }

    private func writeToFile(_ s: String) {
        let line = "[signal] \(s)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logURL.path) {
            if let h = try? FileHandle(forWritingTo: logURL) {
                try? h.write(contentsOf: data)
                try? h.close()
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    // MARK: - Readiness

    /// URLSession delegate that trusts self-signed certs for localhost only.
    private final class LocalhostTrustDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.host == "localhost",
               challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    private func waitForHTTPReady(url: URL, timeoutSeconds: TimeInterval) async throws {
        let session = URLSession(configuration: .ephemeral, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 2
                let (_, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, (200...499).contains(http.statusCode) { return }
            } catch { }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw RuntimeError("Timed out waiting for \(url.absoluteString)")
    }
}

struct RuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
