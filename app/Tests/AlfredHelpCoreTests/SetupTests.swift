import Testing
import Foundation
@testable import AlfredHelpCore

/// Der Installer greift als einziger Teil der App außerhalb des eigenen
/// Sandkastens zu: er lädt ein fremdes Programm herunter und legt es in
/// `/Programme`. Was ihn davon abhält, das mit irgendeiner Datei zu tun, ist
/// allein die Signaturprüfung – die wird hier gegen echte Bündel gefahren.
@Suite("Ollama-Installer")
struct OllamaInstallerTests {

    // MARK: - Herkunftsprüfung

    @Test("Ein echtes Ollama besteht die Prüfung")
    func acceptsGenuineOllama() throws {
        guard let bundle = OllamaSupervisor.applicationURL else {
            // Auf einem Rechner ohne Ollama ist nichts zu prüfen.
            return
        }
        #expect(throws: Never.self) { try OllamaInstaller.verify(bundle) }
        #expect(throws: Never.self) { try OllamaInstaller.verifyNotarization(bundle) }
    }

    @Test("Ein fehlendes Notarisierungsticket wird nach erfolgreichem Gatekeeper-Test abgelehnt")
    func rejectsMissingNotarizationTicket() {
        let bundle = URL(fileURLWithPath: "/tmp/Ollama.app")
        var invokedTools: [String] = []
        #expect(throws: OllamaInstaller.InstallError.self) {
            try OllamaInstaller.verifyNotarization(bundle) { tool, _ in
                invokedTools.append(tool)
                return .init(
                    status: tool == "/usr/sbin/spctl" ? 0 : 1,
                    output: tool == "/usr/sbin/spctl" ? "accepted" : "ticket missing"
                )
            }
        }
        #expect(invokedTools == ["/usr/sbin/spctl", "/usr/bin/stapler"])
    }

    @Test("Ein fremdes, gültig signiertes Programm wird abgelehnt")
    func rejectsForeignPublisher() throws {
        // Systemprogramme sind einwandfrei signiert – nur eben von Apple.
        // Genau das ist der Fall, den eine reine `codesign --verify`-Prüfung
        // durchwinken würde und der hier scheitern muss.
        let apple = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try #require(FileManager.default.fileExists(atPath: apple.path))

        #expect(throws: OllamaInstaller.InstallError.self) {
            try OllamaInstaller.verify(apple)
        }
    }

    @Test("Unsigniertes wird abgelehnt")
    func rejectsUnsigned() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlfredHelpTest-\(UUID().uuidString)/Ollama.app/Contents/MacOS",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(
                at: directory.deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
            )
        }
        try Data("nicht wirklich Ollama".utf8)
            .write(to: directory.appendingPathComponent("Ollama"))

        let bundle = directory.deletingLastPathComponent().deletingLastPathComponent()
        #expect(throws: OllamaInstaller.InstallError.self) {
            try OllamaInstaller.verify(bundle)
        }
    }

    // MARK: - Fund im Archiv

    @Test("Das Bündel wird auch eine Ebene tiefer gefunden")
    func findsNestedBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlfredHelpTest-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("irgendein Ordner/Ollama.app", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(OllamaInstaller.findBundle(in: root)?.lastPathComponent == "Ollama.app")
    }

    @Test("Ein Archiv ohne Ollama liefert nichts")
    func findsNothingWithoutBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlfredHelpTest-\(UUID().uuidString)/leer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        #expect(OllamaInstaller.findBundle(in: root) == nil)
    }

    // MARK: - Ablageort

    @Test("Der Zielort ist beschreibbar und heißt Ollama.app")
    func picksWritableLocation() throws {
        let location = try OllamaInstaller.installLocation()
        #expect(location.lastPathComponent == "Ollama.app")
        // Der übergeordnete Ordner muss beschreibbar sein – sonst wäre er nicht
        // gewählt worden.
        #expect(FileManager.default.isWritableFile(
            atPath: location.deletingLastPathComponent().path
        ))
    }

    @Test("Der Supervisor kennt jeden Ort, an den installiert werden kann")
    func supervisorKnowsInstallLocation() throws {
        let location = try OllamaInstaller.installLocation()
        #expect(OllamaSupervisor.applicationPaths.contains(location.path))
    }
}

@Suite("Einrichtungsplan")
struct DependencySetupTests {

    @Test("Standardplan lädt das kleine Modell")
    func defaultPlanPullsHelper() {
        let plan = DependencySetup.Plan()
        #expect(plan.installsOllama)
        #expect(plan.pullsModel == ModelCatalog.preferredHelper.name)
    }

    @Test("Fortschritt weiß, ob er sich beziffern lässt")
    func progressKnowsWhetherItCanCount() {
        #expect(!SetupProgress(step: 1, stepCount: 3, title: "x").hasFraction)
        #expect(SetupProgress(step: 1, stepCount: 3, title: "x", fraction: 0).hasFraction)
    }

    @Test("Abgeschaltet wird nichts nachinstalliert")
    func disabledPlanInstallsNothing() async {
        let plan = DependencySetup.Plan(installsOllama: false, pullsModel: nil, speechLocales: [])
        #expect(!plan.installsOllama)
        #expect(plan.pullsModel == nil)
    }

    @Test("Byteangaben sind lesbar")
    func formatsBytes() {
        #expect(OllamaInstaller.byteText(1_500_000_000).contains("GB"))
        #expect(OllamaInstaller.byteText(12_000_000).contains("MB"))
    }
}
