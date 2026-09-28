import Foundation

/// Installiert Ollama auf einem Mac, der es noch nicht hat.
///
/// AlfredHelp wird weitergegeben, indem jemand ein Programmbündel bekommt. Wer es
/// bekommt, hat in aller Regel kein Ollama – und soll auch nicht erst eine
/// Anleitung lesen müssen. Deshalb holt sich die App die Voraussetzung selbst.
///
/// Heruntergeladen wird ausschließlich das offizielle, notarisierte Bündel von
/// ollama.com. Vor der Installation wird es geprüft, und zwar nicht nur auf eine
/// heile Signatur, sondern auf **die richtige**: Entwickler-ID-Signatur und die
/// Team-Kennung des Herstellers. Ein umgeleiteter Spiegel oder ein
/// zwischengeschalteter Proxy fliegt damit auf, bevor irgendetwas nach
/// `/Applications` wandert.
public enum OllamaInstaller {

    // MARK: - Woher, und was akzeptiert wird

    /// Offizieller Download. Der zweite Eintrag ist dieselbe Datei direkt vom
    /// GitHub-Release des Herstellers – falls ollama.com nicht erreichbar ist.
    static let sources = [
        URL(string: "https://ollama.com/download/Ollama-darwin.zip")!,
        URL(string: "https://github.com/ollama/ollama/releases/latest/download/Ollama-darwin.zip")!
    ]

    /// Apple-Team-Kennung, mit der Ollama signiert wird (Infra Technologies, Inc).
    /// Stimmt sie nicht, wird nichts installiert.
    public static let expectedTeamIdentifier = "3MU9H2V9Y9"

    /// Was der Nutzer währenddessen sieht.
    public struct Progress: Sendable, Equatable {
        public var text: String
        /// 0…1. Negativ, solange sich kein Fortschritt beziffern lässt.
        public var fraction: Double

        public init(text: String, fraction: Double) {
            self.text = text
            self.fraction = fraction
        }
    }

    public enum InstallError: LocalizedError, Equatable {
        case downloadFailed(String)
        case unpackFailed(String)
        case bundleNotFound
        case signatureInvalid(String)
        case unexpectedPublisher(String)
        case notNotarized(String)
        case noWritableLocation
        case moveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .downloadFailed(let detail):
                return "Ollama konnte nicht geladen werden: \(detail)"
            case .unpackFailed(let detail):
                return "Das Ollama-Archiv ließ sich nicht entpacken: \(detail)"
            case .bundleNotFound:
                return "Im geladenen Archiv war kein Ollama.app enthalten."
            case .signatureInvalid(let detail):
                return "Die Signatur des geladenen Ollama ist beschädigt: \(detail)"
            case .unexpectedPublisher(let detail):
                return "Das geladene Ollama stammt nicht vom Hersteller (\(detail)). Es wurde verworfen."
            case .notNotarized(let detail):
                return "Das geladene Ollama wurde von macOS nicht als notarisiert akzeptiert (\(detail)). Es wurde verworfen."
            case .noWritableLocation:
                return "Weder „/Programme“ noch der eigene Programme-Ordner ließen sich beschreiben."
            case .moveFailed(let detail):
                return "Ollama ließ sich nicht ablegen: \(detail)"
            }
        }
    }

    // MARK: - Ablauf

    /// Lädt, prüft und installiert Ollama. Gibt den Ort des fertigen Bündels
    /// zurück.
    ///
    /// Der Fortschritt wird von einem beliebigen Thread gemeldet.
    @discardableResult
    public static func install(
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlfredHelp-Ollama-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let archive = workspace.appendingPathComponent("Ollama-darwin.zip")

        // 1. Laden. Der zweite Ort ist der Ausweichweg, nicht die Regel.
        var lastError: Error?
        var loaded = false
        for source in sources {
            do {
                try await download(source, to: archive) { fraction, written, total in
                    progress(Progress(
                        text: total > 0
                            ? "Ollama wird geladen – \(byteText(written)) von \(byteText(total))"
                            : "Ollama wird geladen – \(byteText(written))",
                        fraction: fraction < 0 ? -1 : fraction * 0.85
                    ))
                }
                loaded = true
                break
            } catch {
                Log.ollama.error("Download von \(source.host ?? "?", privacy: .public) fehlgeschlagen: \(String(describing: error), privacy: .public)")
                lastError = error
                try? FileManager.default.removeItem(at: archive)
            }
        }
        guard loaded else {
            throw InstallError.downloadFailed(
                lastError.map { $0.localizedDescription } ?? "keine Verbindung"
            )
        }

        // 2. Entpacken. `ditto` statt `unzip`, weil es Bündel samt Rechten und
        //    erweiterten Attributen originalgetreu wiederherstellt – `unzip`
        //    zerlegt dabei die Signatur.
        progress(Progress(text: "Ollama wird entpackt …", fraction: 0.87))
        let unpacked = workspace.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = shell("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        guard ditto.status == 0 else {
            throw InstallError.unpackFailed(ditto.output.isEmpty ? "Status \(ditto.status)" : ditto.output)
        }

        guard let bundle = findBundle(in: unpacked) else { throw InstallError.bundleNotFound }

        // 3. Prüfen – vor jedem Schreibzugriff außerhalb des Temp-Ordners.
        progress(Progress(text: "Signatur wird geprüft …", fraction: 0.92))
        try verify(bundle)
        try verifyNotarization(bundle)

        // 4. Ablegen.
        progress(Progress(text: "Ollama wird abgelegt …", fraction: 0.96))
        let destination = try installLocation()

        // Was am Zielort liegt, ist aller Voraussicht nach eine Ruine – sonst
        // hätte der Aufrufer gar nicht erst installiert. „Aller Voraussicht
        // nach" ist aber keine Grundlage, um es zu löschen: `installLocation()`
        // kann durchaus auf ein vorhandenes Ollama zeigen, das der Supervisor
        // nur nicht erkannt hat. Deshalb wird es beiseitegelegt und erst
        // weggeworfen, wenn das Verschieben wirklich geklappt hat. Scheitert es
        // – volle Platte, gesperrte Datei –, kommt das Alte zurück, statt dass
        // der Nutzer am Ende gar kein Ollama mehr hat.
        let manager = FileManager.default
        var displaced: URL?
        if manager.fileExists(atPath: destination.path) {
            let aside = destination
                .deletingLastPathComponent()
                .appendingPathComponent("Ollama.app.ersetzt-\(UUID().uuidString)")
            do {
                try manager.moveItem(at: destination, to: aside)
                displaced = aside
            } catch {
                throw InstallError.moveFailed(error.localizedDescription)
            }
        }

        do {
            try manager.moveItem(at: bundle, to: destination)
        } catch {
            if let displaced {
                try? manager.moveItem(at: displaced, to: destination)
            }
            throw InstallError.moveFailed(error.localizedDescription)
        }
        if let displaced { try? manager.removeItem(at: displaced) }

        // Der Quarantäne-Merker führt beim Start zum Gatekeeper-Dialog. Er wird
        // erst hier entfernt – nachdem Entwickler-ID-Signatur und Team-Kennung
        // des Herstellers oben nachgewiesen wurden. Was Gatekeeper prüfen würde,
        // ist an dieser Stelle also bereits geprüft.
        _ = shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])

        progress(Progress(text: "Ollama ist installiert.", fraction: 1.0))
        Log.ollama.info("Ollama nach \(destination.path, privacy: .public) installiert")
        return destination
    }

    // MARK: - Prüfung

    /// Der Anforderungsausdruck, den das Bündel erfüllen muss.
    ///
    /// Drei Aussagen in einer: die Kette hängt an Apples Wurzel, das
    /// Blattzertifikat ist ein Entwickler-ID-Programmzertifikat (die
    /// Erweiterung `1.2.840.113635.100.6.1.13` gibt es nur dort), und die
    /// Organisationseinheit ist die Team-Kennung des Herstellers.
    /// Das führende `=` ist nicht schmückend: ohne es deutet `codesign` das
    /// Argument von `-R` als *Dateipfad* zu einer Anforderungsdatei und
    /// scheitert – jedes Bündel würde abgelehnt, auch das echte.
    static var signingRequirement: String {
        "=anchor apple generic"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\""
    }

    /// Wirft, sobald irgendetwas an der Herkunft nicht stimmt.
    ///
    /// Geprüft wird mit **einem** Aufruf gegen einen Anforderungsausdruck, nicht
    /// mit zwei Aufrufen und einem Textvergleich auf deren Ausgabe. Der
    /// Unterschied ist nicht kosmetisch: `codesign -dv` ist ein Diagnoseformat
    /// ohne Zusage über seinen Aufbau, und ein Aufruf, der gar nicht erst
    /// zustande kommt, liefert einen leeren Text – bei einer Prüfung per
    /// `contains` fällt das nur dadurch auf, dass zufällig nichts passt. Der
    /// Rückgabestatus von `-R` ist dagegen die vollständige Aussage.
    static func verify(_ bundle: URL) throws {
        let result = shell("/usr/bin/codesign", [
            "--verify", "--deep", "--strict",
            "-R", signingRequirement,
            bundle.path
        ])
        guard result.status == 0 else {
            let detail = result.output.isEmpty ? "Status \(result.status)" : result.output
            // Eine heile, aber fremde Signatur ist etwas anderes als eine
            // kaputte – der Nutzer soll die beiden auseinanderhalten können.
            let intact = shell("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
            if intact.status == 0 {
                throw InstallError.unexpectedPublisher(describePublisher(of: bundle))
            }
            throw InstallError.signatureInvalid(detail)
        }
    }

    /// Lässt Gatekeeper die Developer-ID- und Notarisierungsrichtlinie
    /// anwenden. Erst wenn auch diese Prüfung besteht, darf die Quarantäne
    /// entfernt werden; eine gültige Herstellersignatur allein genügt nicht.
    static func verifyNotarization(
        _ bundle: URL,
        runner: (String, [String]) -> ShellResult = shell
    ) throws {
        let assessment = runner("/usr/sbin/spctl", [
            "--assess", "--type", "execute", "--verbose=2", bundle.path
        ])
        guard assessment.status == 0 else {
            throw InstallError.notNotarized(
                assessment.output.isEmpty ? "Gatekeeper-Status \(assessment.status)" : assessment.output
            )
        }
        // `spctl` kann lokale Ausnahmen berücksichtigen. Das im Bundle
        // geheftete Apple-Ticket ist der unabhängige Nachweis, dass exakt
        // dieses Artefakt notarisiert wurde und später auch offline startet.
        // macOS 26 ships stapler as a system tool. Calling it through xcrun
        // would unnecessarily require a selected Xcode/CLT developer path on
        // an otherwise ordinary end-user Mac.
        let ticket = runner("/usr/bin/stapler", ["validate", bundle.path])
        guard ticket.status == 0 else {
            throw InstallError.notNotarized(
                ticket.output.isEmpty ? "Notarisierungsticket fehlt" : ticket.output
            )
        }
    }

    /// Wer das Bündel wirklich signiert hat – nur für die Fehlermeldung.
    private static func describePublisher(of bundle: URL) -> String {
        let details = shell("/usr/bin/codesign", ["-dv", "--verbose=4", bundle.path])
        return details.output
            .split(separator: "\n")
            .first { $0.hasPrefix("TeamIdentifier=") }
            .map(String.init) ?? "keine Team-Kennung"
    }

    /// Sucht das Programmbündel im entpackten Archiv – oberste Ebene zuerst.
    static func findBundle(in directory: URL) -> URL? {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return nil }

        if let direct = entries.first(where: { $0.lastPathComponent == "Ollama.app" }) {
            return direct
        }
        // Manche Archivfassungen packen noch einen Ordner drumherum.
        for entry in entries where entry.hasDirectoryPath {
            if let nested = findBundle(in: entry) { return nested }
        }
        return nil
    }

    // MARK: - Wohin

    /// `/Programme`, wenn dieser Nutzer dort schreiben darf – sonst der eigene
    /// Programme-Ordner. Letzterer braucht keine Administratorrechte, weshalb
    /// die Installation auch ohne Passwortabfrage durchläuft.
    static func installLocation() throws -> URL {
        let manager = FileManager.default
        let shared = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if manager.isWritableFile(atPath: shared.path) {
            return shared.appendingPathComponent("Ollama.app")
        }

        let personal = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        if !manager.fileExists(atPath: personal.path) {
            try? manager.createDirectory(at: personal, withIntermediateDirectories: true)
        }
        guard manager.isWritableFile(atPath: personal.path) else {
            throw InstallError.noWritableLocation
        }
        return personal.appendingPathComponent("Ollama.app")
    }

    // MARK: - Werkzeuge

    struct ShellResult {
        let status: Int32
        /// stdout und stderr zusammen – `codesign` benutzt beides.
        let output: String
    }

    @discardableResult
    static func shell(_ tool: String, _ arguments: [String]) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, output: error.localizedDescription)
        }
        // Erst lesen, dann warten: ein voller Pipe-Puffer würde sonst beide
        // Seiten blockieren.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShellResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Download mit Fortschritt

    private static func download(
        _ url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double, Int64, Int64) -> Void
    ) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true

        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Anhängen vor `resume()` – danach kann kein Abschluss mehr ins
                // Leere laufen.
                delegate.attach(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Meldet den Fortschritt eines Downloads und legt die fertige Datei ab.
///
/// `URLSession` ruft die Delegate-Methoden auf einer eigenen Queue auf, deshalb
/// `@unchecked Sendable` mit Sperre statt Aktor: die Fortsetzung darf genau
/// einmal fortgesetzt werden, egal welcher Rückruf zuerst kommt.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let destination: URL
    private let onProgress: @Sendable (Double, Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pending: Result<Void, Error>?
    private var settled = false

    init(destination: URL, progress: @escaping @Sendable (Double, Int64, Int64) -> Void) {
        self.destination = destination
        self.onProgress = progress
    }

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func settle(_ result: Result<Void, Error>) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        let waiting = continuation
        continuation = nil
        if waiting == nil { pending = result }
        lock.unlock()
        waiting?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : -1
        onProgress(fraction, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Die temporäre Datei verschwindet, sobald diese Methode zurückkehrt –
        // das Verschieben muss deshalb hier drin passieren.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            settle(.failure(OllamaInstaller.InstallError.downloadFailed("HTTP \(http.statusCode)")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            settle(.success(()))
        } catch {
            settle(.failure(OllamaInstaller.InstallError.downloadFailed(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            settle(.failure(OllamaInstaller.InstallError.downloadFailed(error.localizedDescription)))
        } else {
            // Erfolg wurde bereits in `didFinishDownloadingTo` gemeldet.
            settle(.success(()))
        }
    }
}
