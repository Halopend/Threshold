// Diagnostics.swift — rebuild identity, diagnostic switches, and bounded
// persistent breadcrumbs shared by every ThresholdKit target.
//
// Breadcrumb writes are dispatched onto one private serial queue. A render,
// audio, or Metal completion thread only enqueues a small value; it never does
// filesystem work directly.

import Dispatch
import Foundation

// MARK: - Build identity

public struct ThresholdBuildIdentity: Codable, Sendable, Equatable {
    public let product: String
    public let flavor: String
    public let bundleIdentifier: String
    public let executable: String
    public let version: String
    public let build: String
    public let operatingSystem: String

    public static var current: ThresholdBuildIdentity {
        let bundle = Bundle.main
        return ThresholdBuildIdentity(
            product: "Threshold Rebuild",
            flavor: "rebuild",
            bundleIdentifier: bundle.bundleIdentifier
                ?? "com.pupppower.threshold.rebuild.swiftpm",
            executable: bundle.executableURL?.lastPathComponent
                ?? ProcessInfo.processInfo.processName,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "development",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "unversioned",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    public var summary: String {
        "\(product) [\(flavor)] \(version) (\(build)); "
            + "bundle=\(bundleIdentifier); executable=\(executable)"
    }
}

// MARK: - Diagnostic switches

public enum DiagnosticSwitch: String, CaseIterable, Sendable {
    case disableMetalFX
    case disableSpecialization
    case disableExternalDE
    case disableAnimation
    case disableAudioInput
    case disableHandInput
    case disableSceneTransitions
    case verboseGPUFaults

    public var environmentKey: String {
        switch self {
        case .disableMetalFX: "THRESHOLD_DIAG_DISABLE_METALFX"
        case .disableSpecialization: "THRESHOLD_DIAG_DISABLE_SPECIALIZATION"
        case .disableExternalDE: "THRESHOLD_DIAG_DISABLE_EXTERNAL_DE"
        case .disableAnimation: "THRESHOLD_DIAG_DISABLE_ANIMATION"
        case .disableAudioInput: "THRESHOLD_DIAG_DISABLE_AUDIO"
        case .disableHandInput: "THRESHOLD_DIAG_DISABLE_HANDS"
        case .disableSceneTransitions: "THRESHOLD_DIAG_DISABLE_TRANSITIONS"
        case .verboseGPUFaults: "THRESHOLD_GPU_FAULTS"
        }
    }

    public var defaultsKey: String {
        "com.pupppower.threshold.rebuild.diagnostics.\(rawValue)"
    }
}

public enum DiagnosticSwitches {
    public static func isEnabled(_ item: DiagnosticSwitch) -> Bool {
        if truthy(ProcessInfo.processInfo.environment[item.environmentKey]) {
            return true
        }
        return UserDefaults.standard.bool(forKey: item.defaultsKey)
    }

    public static var active: [DiagnosticSwitch] {
        DiagnosticSwitch.allCases.filter(isEnabled)
    }

    public static var summary: String {
        let names = active.map(\.rawValue)
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }
}

// MARK: - Breadcrumb facade

public enum DiagnosticBreadcrumbs {
    private static let store = BreadcrumbStore()

    public static var directoryURL: URL { store.directoryURL }

    public static func beginSession(
        identity: ThresholdBuildIdentity = .current
    ) {
        store.beginSession(identity: identity)
    }

    public static func record(
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        store.record(category: category, message: message, metadata: metadata)
    }

    public static func storeArtifact(
        prefix: String,
        data: Data,
        metadata: [String: String] = [:]
    ) {
        store.storeArtifact(prefix: prefix, data: data, metadata: metadata)
    }

    /// Synchronous so a normal termination cannot exit before the clean bit
    /// reaches disk. Never call from a real-time/render callback.
    public static func markCleanExit() {
        store.markCleanExit()
    }
}

private final class BreadcrumbStore: @unchecked Sendable {
    struct SessionState: Codable {
        var sessionID: String
        var identity: ThresholdBuildIdentity
        var startedAt: TimeInterval
        var cleanExit: Bool
    }

    struct Breadcrumb: Codable {
        var timestamp: TimeInterval
        var sessionID: String
        var category: String
        var message: String
        var metadata: [String: String]
    }

    let directoryURL: URL
    private let queue = DispatchQueue(
        label: "com.pupppower.threshold.rebuild.breadcrumbs", qos: .utility)
    private let maxBreadcrumbBytes = 512 * 1024
    private var session: SessionState?

    private var stateURL: URL { directoryURL.appendingPathComponent("session.json") }
    private var breadcrumbsURL: URL {
        directoryURL.appendingPathComponent("breadcrumbs.jsonl")
    }
    private var previousBreadcrumbsURL: URL {
        directoryURL.appendingPathComponent("breadcrumbs.previous.jsonl")
    }

    init() {
        let manager = FileManager.default
        let base = manager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        directoryURL = base
            .appendingPathComponent("ThresholdRebuild", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    func beginSession(identity: ThresholdBuildIdentity) {
        queue.sync {
            guard session == nil else { return }
            ensureDirectory()

            let previous = readState()
            let current = SessionState(
                sessionID: UUID().uuidString,
                identity: identity,
                startedAt: Date().timeIntervalSince1970,
                cleanExit: false)
            session = current
            writeState(current)

            if let previous, !previous.cleanExit {
                append(Breadcrumb(
                    timestamp: Date().timeIntervalSince1970,
                    sessionID: current.sessionID,
                    category: "lifecycle",
                    message: "previous_session_unclean_exit",
                    metadata: [
                        "previousSessionID": previous.sessionID,
                        "previousStartedAt": String(previous.startedAt),
                        "previousIdentity": previous.identity.summary,
                    ]))
            }

            append(Breadcrumb(
                timestamp: Date().timeIntervalSince1970,
                sessionID: current.sessionID,
                category: "lifecycle",
                message: "session_started",
                metadata: [
                    "identity": identity.summary,
                    "os": identity.operatingSystem,
                    "switches": DiagnosticSwitches.summary,
                ]))
        }
    }

    func record(category: String, message: String, metadata: [String: String]) {
        queue.async { [self] in
            let current = ensureSession()
            append(Breadcrumb(
                timestamp: Date().timeIntervalSince1970,
                sessionID: current.sessionID,
                category: category,
                message: message,
                metadata: metadata))
        }
    }

    func storeArtifact(prefix: String, data: Data, metadata: [String: String]) {
        queue.async { [self] in
            let current = ensureSession()
            ensureDirectory()
            let safePrefix = prefix.replacingOccurrences(of: "/", with: "-")
            let stamp = Int(Date().timeIntervalSince1970 * 1_000)
            let suffix = UUID().uuidString.prefix(8)
            let filename = "\(safePrefix)-\(stamp)-\(suffix).json"
            let url = directoryURL.appendingPathComponent(filename)
            do {
                try data.write(to: url, options: .atomic)
                var details = metadata
                details["file"] = filename
                details["bytes"] = String(data.count)
                append(Breadcrumb(
                    timestamp: Date().timeIntervalSince1970,
                    sessionID: current.sessionID,
                    category: "diagnostic",
                    message: "artifact_stored",
                    metadata: details))
            } catch {
                append(Breadcrumb(
                    timestamp: Date().timeIntervalSince1970,
                    sessionID: current.sessionID,
                    category: "diagnostic",
                    message: "artifact_store_failed",
                    metadata: ["error": String(describing: error)]))
            }
        }
    }

    func markCleanExit() {
        queue.sync {
            guard var current = session else { return }
            append(Breadcrumb(
                timestamp: Date().timeIntervalSince1970,
                sessionID: current.sessionID,
                category: "lifecycle",
                message: "session_clean_exit",
                metadata: [:]))
            current.cleanExit = true
            session = current
            writeState(current)
        }
    }

    private func ensureSession() -> SessionState {
        if let session { return session }
        let current = SessionState(
            sessionID: UUID().uuidString,
            identity: .current,
            startedAt: Date().timeIntervalSince1970,
            cleanExit: false)
        session = current
        ensureDirectory()
        writeState(current)
        return current
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
    }

    private func readState() -> SessionState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    private func writeState(_ state: SessionState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func append(_ breadcrumb: Breadcrumb) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(breadcrumb) else { return }
        data.append(0x0A)
        rotateIfNeeded(adding: data.count)
        if !FileManager.default.fileExists(atPath: breadcrumbsURL.path) {
            FileManager.default.createFile(
                atPath: breadcrumbsURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: breadcrumbsURL) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }

    private func rotateIfNeeded(adding bytes: Int) {
        let currentSize = (try? FileManager.default.attributesOfItem(
            atPath: breadcrumbsURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard currentSize + bytes > maxBreadcrumbBytes else { return }
        try? FileManager.default.removeItem(at: previousBreadcrumbsURL)
        try? FileManager.default.moveItem(
            at: breadcrumbsURL, to: previousBreadcrumbsURL)
    }
}
