import Foundation

/// Ein Schritt der Ersteinrichtung, so wie ihn der Nutzer sieht.
public struct SetupProgress: Sendable, Equatable {
    public var step: Int
    public var stepCount: Int
    public var title: String
    public var detail: String
    /// 0…1. Negativ, solange sich der Fortschritt nicht beziffern lässt.
    public var fraction: Double

    public init(step: Int, stepCount: Int, title: String, detail: String = "", fraction: Double = -1) {
        self.step = step
        self.stepCount = stepCount
        self.title = title
        self.detail = detail
        self.fraction = fraction
    }

    public var hasFraction: Bool { fraction >= 0 }
}

/// Beschafft alles, was AlfredHelp zum Laufen braucht – ohne Rückfrage.
///
/// Der Hintergrund: Die App wird weitergegeben, indem jemand ein
/// Programmbündel bekommt. Auf dem fremden Mac ist üblicherweise **nichts**
/// davon vorhanden: kein Ollama, kein Sprachmodell, keine Erkennungsdaten. Wer
/// die App bekommt, soll sie starten und benutzen können – nicht erst eine
/// Installationsanleitung abarbeiten.
///
/// Deshalb prüft diese Einrichtung der Reihe nach jede Voraussetzung und holt
/// nach, was fehlt. Vorhandenes wird nie angefasst: Wer Ollama schon hat oder
/// eigene Modelle liegen hat, bekommt keinen einzigen Download.
public enum DependencySetup {

    public struct Report: Sendable {
        /// Der Dienst antwortet.
        public var ollamaRunning = false
        /// Ollama wurde in diesem Durchlauf frisch installiert.
        public var installedOllama = false
        /// Modell, das dieser Durchlauf geladen hat – sofern eines nötig war.
        public var pulledModel: String?
        /// Was schiefging. Leer heißt: alles steht.
        public var problems: [String] = []
    }

    /// Was die Einrichtung besorgen darf.
    public struct Plan: Sendable {
        /// Fehlendes Ollama nachinstallieren.
        public var installsOllama: Bool
        /// Ein Modell laden, wenn gar keines vorhanden ist.
        public var pullsModel: String?
        /// Erkennungsdaten für diese Sprachen vorbereiten.
        public var speechLocales: [String]

        public init(
            installsOllama: Bool = true,
            pullsModel: String? = ModelCatalog.preferredHelper.name,
            speechLocales: [String] = []
        ) {
            self.installsOllama = installsOllama
            self.pullsModel = pullsModel
            self.speechLocales = speechLocales
        }
    }

    /// Arbeitet den Plan ab. Meldet `nil`, sobald nichts mehr zu tun ist.
    public static func run(
        client: OllamaClient,
        plan: Plan,
        onProgress: @escaping @Sendable (SetupProgress?) -> Void
    ) async -> Report {
        var report = Report()
        let steps = 3 + (plan.speechLocales.isEmpty ? 0 : 1)
        defer { onProgress(nil) }

        // MARK: 1 – Ollama

        if !OllamaSupervisor.isInstalledAnywhere {
            guard plan.installsOllama else {
                report.problems.append(
                    "Ollama fehlt und die automatische Installation ist abgeschaltet."
                )
                return report
            }
            onProgress(SetupProgress(
                step: 1, stepCount: steps,
                title: "Ollama wird eingerichtet",
                detail: "Einmalig, danach nie wieder."
            ))
            do {
                _ = try await OllamaInstaller.install { progress in
                    onProgress(SetupProgress(
                        step: 1, stepCount: steps,
                        title: "Ollama wird eingerichtet",
                        detail: progress.text,
                        fraction: progress.fraction
                    ))
                }
                report.installedOllama = true
            } catch {
                report.problems.append(error.localizedDescription)
                return report
            }
        }

        // MARK: 2 – Dienst

        // Läuft er schon, wird auch nichts gemeldet: ein Balken, der sofort
        // wieder verschwindet, ist nur Unruhe.
        if await client.isReachable() {
            report.ollamaRunning = true
        } else {
            onProgress(SetupProgress(
                step: 2, stepCount: steps,
                title: "Ollama wird gestartet",
                detail: "Der Dienst läuft nur auf diesem Mac."
            ))
            report.ollamaRunning = await OllamaSupervisor.ensureRunning(client: client)
        }
        guard report.ollamaRunning else {
            report.problems.append("Ollama ließ sich nicht starten.")
            return report
        }

        // MARK: 3 – Modell

        let installed = (try? await client.installedModels()) ?? []
        let usable = installed.filter { !ModelCatalog.isKnownUnsuitable($0.name) }
        if usable.isEmpty, let wanted = plan.pullsModel {
            onProgress(SetupProgress(
                step: 3, stepCount: steps,
                title: "Sprachmodell wird geladen",
                detail: wanted
            ))
            do {
                for try await progress in client.pull(model: wanted) {
                    onProgress(SetupProgress(
                        step: 3, stepCount: steps,
                        title: "Sprachmodell wird geladen",
                        detail: detailText(for: progress, model: wanted),
                        fraction: progress.totalBytes > 0 ? progress.fraction : -1
                    ))
                }
                report.pulledModel = wanted
            } catch {
                report.problems.append(
                    "Das Sprachmodell \(wanted) ließ sich nicht laden: \(error.localizedDescription)"
                )
            }
        }

        // MARK: 4 – Spracherkennung

        guard !plan.speechLocales.isEmpty else { return report }
        guard SpeechAssets.isAvailable else {
            report.problems.append("Die lokale Spracherkennung ist auf diesem Mac nicht verfügbar.")
            return report
        }

        for identifier in plan.speechLocales {
            let locale = Locale(identifier: identifier)
            let name = Locale(identifier: "de_DE")
                .localizedString(forIdentifier: identifier) ?? identifier
            onProgress(SetupProgress(
                step: steps, stepCount: steps,
                title: "Spracherkennung wird vorbereitet",
                detail: name
            ))
            do {
                try await SpeechAssets.ensureModel(for: locale) { fraction in
                    onProgress(SetupProgress(
                        step: steps, stepCount: steps,
                        title: "Spracherkennung wird vorbereitet",
                        detail: name,
                        fraction: fraction
                    ))
                }
                // Der reservierte Platz wird beim Zuhören neu belegt; die
                // Einrichtung hält keinen davon fest.
                await SpeechAssets.release(locale)
            } catch {
                // Kein Abbruch: eine fehlende Zweitsprache soll die Einrichtung
                // nicht scheitern lassen.
                Log.speech.error("Erkennungsdaten für \(identifier, privacy: .public) fehlen: \(String(describing: error), privacy: .public)")
                report.problems.append(
                    "Die Spracherkennung für \(name) ließ sich nicht vorbereiten: \(error.localizedDescription)"
                )
            }
        }

        return report
    }

    private static func detailText(for progress: OllamaClient.PullProgress, model: String) -> String {
        guard progress.totalBytes > 0 else {
            return progress.status.isEmpty ? model : progress.status
        }
        return "\(model) – \(OllamaInstaller.byteText(progress.completedBytes))"
            + " von \(OllamaInstaller.byteText(progress.totalBytes))"
    }
}
