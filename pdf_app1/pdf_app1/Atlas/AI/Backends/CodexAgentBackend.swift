//
//  CodexAgentBackend.swift
//  Atlas
//
//  Talks to the local codex-agent sidecar, which wraps the user's Codex CLI.
//

import Foundation
import os.log

private let log = AtlasLogger.ai

final class CodexAgentBackend: LLMBackend, @unchecked Sendable {
    let displayName = "Codex Agent"
    let modelIdentifier: String
    let logTag = "CodexAgent"
    private let baseURL: String
    private let reasoningEffort: String?
    private let session: URLSession
    private let sidecarLauncher: any CodexAgentSidecarLaunching

    var isAvailable: Bool { true }

    init(
        baseURL: String = "http://127.0.0.1:8775",
        model: String = "gpt-5.3-codex-spark",
        reasoningEffort: String? = nil,
        session: URLSession? = nil,
        sidecarLauncher: any CodexAgentSidecarLaunching = CodexAgentSidecarLauncher.shared
    ) {
        self.baseURL = baseURL
        self.modelIdentifier = model
        self.reasoningEffort = reasoningEffort
        self.sidecarLauncher = sidecarLauncher
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 600
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }
    }

    func preflight() async throws {
        do {
            try await checkHealth(timeout: 5)
            return
        } catch let error as CodexAgentHealthError {
            log.info("[CodexAgent] Health check failed; attempting auto-start: \(error.localizedDescription)")
        } catch {
            throw error
        }

        do {
            try await sidecarLauncher.start()
            try await waitForHealth()
        } catch let error as AIError {
            throw error
        } catch {
            log.error("[CodexAgent] Auto-start failed: \(error.localizedDescription)")
            throw AIError.modelUnavailable(
                "Codex Agent sidecar is not running at \(baseURL), and Atlas could not start it automatically: \(error.localizedDescription)")
        }
    }

    private func checkHealth(timeout: TimeInterval) async throws {
        let url = URL(string: "\(baseURL)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIError.invalidResponse
            }
            guard http.statusCode == 200 else {
                let message = Self.errorMessage(from: data)
                    ?? "Codex Agent sidecar at \(baseURL) responded with HTTP \(http.statusCode)"
                throw AIError.modelUnavailable(message)
            }
        } catch let error as AIError {
            throw error
        } catch {
            log.error("[CodexAgent] Health check failed: \(error.localizedDescription)")
            throw CodexAgentHealthError.unreachable(error)
        }
    }

    private func waitForHealth() async throws {
        var lastError: Error?
        for _ in 0..<60 {
            do {
                try await checkHealth(timeout: 2)
                return
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        if let error = lastError as? AIError {
            throw error
        }
        throw AIError.modelUnavailable("Codex Agent sidecar did not become ready at \(baseURL) after Atlas started it.")
    }

    func transport(prompt: String) async throws -> String {
        log.info("[CodexAgent] POST \(self.baseURL)/extract (prompt: \(prompt.count) chars, model: \(self.modelIdentifier), reasoningEffort: \(self.reasoningEffort ?? "<default>"))")

        let url = URL(string: "\(baseURL)/extract")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: String] = [
            "prompt": prompt,
            "model": modelIdentifier
        ]
        if let reasoningEffort {
            payload["reasoning_effort"] = reasoningEffort
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log.error("[CodexAgent] Request failed — is the sidecar running at \(self.baseURL)? \(error.localizedDescription)")
            throw AIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            log.error("[CodexAgent] Response is not HTTPURLResponse")
            throw AIError.invalidResponse
        }

        log.info("[CodexAgent] HTTP \(httpResponse.statusCode), \(data.count) bytes")

        guard httpResponse.statusCode == 200 else {
            let message = Self.errorMessage(from: data)
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            log.error("[CodexAgent] HTTP error \(httpResponse.statusCode): \(String(message.prefix(300)))")
            throw AIError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        let parsed: CodexAgentResponse
        do {
            parsed = try JSONDecoder().decode(CodexAgentResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            log.error("[CodexAgent] Could not parse response structure: \(error). Raw (first 500): \(String(raw.prefix(500)))")
            throw AIError.invalidResponse
        }
        guard let text = parsed.text else {
            log.error("[CodexAgent] Response had no text field")
            throw AIError.invalidResponse
        }

        log.info("[CodexAgent] Got text response: \(text.count) chars")
        log.debug("[CodexAgent] Response preview: \(String(text.prefix(200)))")
        return text
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let parsed = try? JSONDecoder().decode(CodexAgentErrorResponse.self, from: data) else {
            return nil
        }
        return parsed.error
    }
}

private struct CodexAgentResponse: Decodable {
    let text: String?
}

private struct CodexAgentErrorResponse: Decodable {
    let error: String?
}

protocol CodexAgentSidecarLaunching: Sendable {
    func start() async throws
}

private enum CodexAgentHealthError: Error, LocalizedError {
    case unreachable(Error)

    var errorDescription: String? {
        switch self {
        case .unreachable(let error):
            return error.localizedDescription
        }
    }
}

actor CodexAgentSidecarLauncher: CodexAgentSidecarLaunching {
    static let shared = CodexAgentSidecarLauncher()

    private var process: Process?
    private var logHandle: FileHandle?

    func start() async throws {
        if let process, process.isRunning {
            return
        }

        let scriptURL = try resolveScriptURL()
        let supportURL = try applicationSupportURL()
        let logURL = supportURL.appendingPathComponent("codex-agent-sidecar.log")
        try FileManager.default.createDirectory(
            at: supportURL,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        let pythonURL = try resolvePythonURL()
        let launchScriptURL = try materializeLaunchScript(from: scriptURL, supportURL: supportURL)
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [launchScriptURL.path]
        process.currentDirectoryURL = supportURL
        process.environment = sidecarEnvironment(
            scriptURL: scriptURL,
            supportURL: supportURL,
            pythonURL: pythonURL
        )
        process.standardOutput = handle
        process.standardError = handle

        try process.run()
        self.process = process
        self.logHandle = handle
        log.info("[CodexAgent] Started sidecar pid=\(process.processIdentifier) log=\(logURL.path)")
    }

    private func resolveScriptURL() throws -> URL {
        let fileManager = FileManager.default
        let candidates = candidateScriptURLs()
        if let match = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return match
        }
        throw CodexAgentLauncherError.scriptNotFound(candidates.map(\.path))
    }

    private func candidateScriptURLs() -> [URL] {
        var candidates: [URL] = []
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["ATLAS_CODEX_AGENT_SIDECAR_SCRIPT"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override).standardizedFileURL)
        }

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("server.py"))
            candidates.append(resourceURL.appendingPathComponent("codex-agent-sidecar/server.py"))
        }

        return candidates
    }

    private func materializeLaunchScript(from sourceURL: URL, supportURL: URL) throws -> URL {
        let scriptsURL = supportURL.appendingPathComponent("codex-agent-sidecar", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsURL, withIntermediateDirectories: true)
        let launchURL = scriptsURL.appendingPathComponent("server.py")
        let source = try Data(contentsOf: sourceURL)
        try source.write(to: launchURL, options: .atomic)
        return launchURL
    }

    private func resolvePythonURL() throws -> URL {
        let fileManager = FileManager.default
        let candidates = candidatePythonURLs()
        if let match = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return match
        }
        throw CodexAgentLauncherError.pythonNotFound(candidates.map(\.path))
    }

    private func candidatePythonURLs() -> [URL] {
        var candidates: [URL] = []
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["ATLAS_CODEX_AGENT_PYTHON"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override).standardizedFileURL)
        }

        candidates.append(URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/python3"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/python3").standardizedFileURL)
        return candidates
    }

    private func applicationSupportURL() throws -> URL {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CodexAgentLauncherError.applicationSupportUnavailable
        }
        return baseURL.appendingPathComponent("Atlas", isDirectory: true)
    }

    private func sidecarEnvironment(scriptURL: URL, supportURL: URL, pythonURL: URL) -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var environment = current
        environment["PYTHONUNBUFFERED"] = "1"
        let pythonBinDir = pythonURL.deletingLastPathComponent().path
        let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let inheritedPath = (current["PATH"] ?? fallbackPath)
            .split(separator: ":")
            .map(String.init)
        let pathParts = ([pythonBinDir, "/opt/homebrew/bin", "/usr/local/bin"] + inheritedPath)
            .reduce(into: [String]()) { result, part in
                guard !part.isEmpty, !result.contains(part) else { return }
                result.append(part)
            }
        environment["PATH"] = pathParts.joined(separator: ":")
        if let homeURL = userHomeURL(from: [scriptURL, supportURL]) {
            environment["HOME"] = homeURL.path
            environment["CODEX_HOME"] = homeURL.appendingPathComponent(".codex").path
        }
        if let codexBin = current["CODEX_BIN"], !codexBin.isEmpty {
            environment["CODEX_BIN"] = codexBin
        } else if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/codex") {
            environment["CODEX_BIN"] = "/opt/homebrew/bin/codex"
        }
        return environment
    }

    private func userHomeURL(from urls: [URL]) -> URL? {
        for url in urls {
            let components = url.standardizedFileURL.pathComponents
            if components.count >= 3, components[0] == "/", components[1] == "Users" {
                return URL(fileURLWithPath: "/Users/\(components[2])", isDirectory: true)
            }
        }
        return nil
    }
}

private enum CodexAgentLauncherError: Error, LocalizedError {
    case scriptNotFound([String])
    case pythonNotFound([String])
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .scriptNotFound(let candidates):
            return "Could not find bundled Codex Agent sidecar server.py. Checked: \(candidates.joined(separator: ", "))"
        case .pythonNotFound(let candidates):
            return "Could not find a sandbox-usable Python 3 executable. Checked: \(candidates.joined(separator: ", "))"
        case .applicationSupportUnavailable:
            return "Could not resolve Application Support for Codex Agent sidecar startup."
        }
    }
}
