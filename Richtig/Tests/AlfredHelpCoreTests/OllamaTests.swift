import Testing
import Foundation
@testable import AlfredHelpCore

@Suite("Ollama-Typen")
struct OllamaTypeTests {

    @Test("Parametergröße wird gelesen", arguments: [
        ("8.0B", 8.0), ("20.9B", 20.9), ("4.3B", 4.3), ("770M", 0.77)
    ])
    func parsesParameters(_ input: String, _ expected: Double) {
        let model = OllamaModel(
            name: "test", sizeBytes: 0, parameterSize: input,
            quantization: "Q4", family: "x", modifiedAt: nil
        )
        #expect(abs((model.parameterBillions ?? -1) - expected) < 0.001)
    }

    @Test("Optionen werden nur gesetzt, wenn belegt")
    func buildsOptionPayload() {
        let empty = GenerationOptions().payload
        #expect(empty.isEmpty)

        let filled = GenerationOptions(temperature: 0.2, numPredict: 100, stop: ["</s>"]).payload
        #expect(filled["temperature"] as? Double == 0.2)
        #expect(filled["num_predict"] as? Int == 100)
        #expect(filled["stop"] as? [String] == ["</s>"])
        #expect(filled["top_p"] == nil)
    }

    @Test("Schema-Erzeugung liefert gültiges JSON")
    func buildsSchema() throws {
        let format = ResponseFormat.object([
            (name: "frage", schema: "{\"type\":\"boolean\"}"),
            (name: "text", schema: "{\"type\":\"string\"}")
        ])
        guard case .schema(let text) = format else {
            Issue.record("Kein Schema erzeugt")
            return
        }
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(object?["type"] as? String == "object")
        #expect((object?["required"] as? [String])?.sorted() == ["frage", "text"])
        let properties = object?["properties"] as? [String: Any]
        #expect(properties?.count == 2)
    }

    @Test("Tokenrate wird aus den Messwerten berechnet")
    func computesRate() {
        var metrics = GenerationMetrics()
        metrics.completionTokens = 50
        metrics.evalMilliseconds = 2000
        #expect(abs(metrics.tokensPerSecond - 25) < 0.001)
    }
}

@Suite("Modellauswahl")
struct ModelCatalogTests {

    private func model(_ name: String, _ params: String) -> OllamaModel {
        OllamaModel(
            name: name, sizeBytes: 1, parameterSize: params,
            quantization: "Q4_K_M", family: "", modifiedAt: nil
        )
    }

    @Test("Wählt bevorzugte Modelle, wenn vorhanden")
    func picksPreferred() {
        let choice = ModelCatalog.autoSelect(from: [
            model("llama3.2:3b", "3.2B"),
            model("gemma3:4b", "4.3B"),
            model("gemma3:12b", "12.2B"),
            model("qwen3:14b", "14.8B")
        ])
        #expect(choice.fast == "gemma3:4b")
        #expect(choice.quality == "gemma3:12b")
    }

    @Test("Im Benchmark durchgefallene Modelle werden nie gewählt")
    func skipsProvenBadModels() {
        let choice = ModelCatalog.autoSelect(from: [
            model("qwen3:4b", "4.0B"),
            model("gpt-oss:20b", "20.9B"),
            model("gemma3:4b", "4.3B")
        ])
        #expect(choice.fast == "gemma3:4b")
        #expect(choice.quality == "gemma3:4b")
    }

    @Test("Hält die Parametergrenze ein")
    func respectsCeiling() {
        let choice = ModelCatalog.autoSelect(
            from: [model("gemma3:4b", "4.3B"), model("riesig:70b", "70.6B")],
            maximumParameters: 20.5
        )
        #expect(choice.quality != "riesig:70b")
    }

    @Test("Ignoriert Code-Modelle")
    func skipsCoderModels() {
        let choice = ModelCatalog.autoSelect(from: [
            model("qwen2.5-coder:14b", "14.8B"),
            model("gemma3:4b", "4.3B")
        ])
        #expect(choice.fast == "gemma3:4b")
        #expect(choice.quality == "gemma3:4b")
    }

    @Test("Leere Installation liefert leere Auswahl")
    func handlesEmpty() {
        let choice = ModelCatalog.autoSelect(from: [])
        #expect(choice.fast.isEmpty)
        #expect(choice.quality.isEmpty)
    }
}

@Suite("Einstellungen")
struct SettingsTests {

    @Test("Deutsch als Gegenseite schaltet die Übersetzung ab")
    func detectsGerman() {
        var settings = AppSettings()
        settings.systemAudioLocale = "de-DE"
        #expect(settings.systemAudioIsGerman)
        settings.systemAudioLocale = "en-US"
        #expect(!settings.systemAudioIsGerman)
    }

    @Test("Gesprächssprache wird auf Deutsch benannt")
    func namesLanguage() {
        var settings = AppSettings()
        settings.systemAudioLocale = "fr-FR"
        #expect(settings.conversationLanguageName.lowercased().contains("franz"))
    }

    @Test("Einstellungen überstehen einen Speicher-Ladezyklus")
    func roundTrips() throws {
        let defaults = UserDefaults(suiteName: "de.alfredhelp.tests.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        store.update {
            $0.systemAudioLocale = "it-IT"
            $0.maxAnswerTokens = 200
            $0.userProfile = "Testprofil"
        }
        let reloaded = SettingsStore(defaults: defaults).settings
        #expect(reloaded.systemAudioLocale == "it-IT")
        #expect(reloaded.maxAnswerTokens == 200)
        #expect(reloaded.userProfile == "Testprofil")
    }
}

@Suite("Einstellungen überleben Schema-Änderungen")
struct SettingsMigrationTests {

    @Test("Eine alte Fassung ohne neue Felder behält, was sie hatte")
    func decodesOldPayload() throws {
        // Stand der ersten Auslieferung: viele heutige Felder fehlen.
        let old = """
        {"captureSystemAudio": true, "captureMicrophone": false,
         "systemAudioLocale": "it-IT", "microphoneLocale": "de-DE",
         "fastModel": "gemma3:4b", "qualityModel": "gemma3:12b",
         "overlayHiddenFromScreenSharing": false, "maxAnswerTokens": 200}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        // Vorhandenes bleibt …
        #expect(decoded.systemAudioLocale == "it-IT")
        #expect(decoded.qualityModel == "gemma3:12b")
        #expect(decoded.captureMicrophone == false)
        #expect(decoded.overlayHiddenFromScreenSharing == false)
        #expect(decoded.maxAnswerTokens == 200)
        // … Fehlendes bekommt seinen Standard.
        #expect(decoded.autoStartSession == false)
        #expect(decoded.systemAudioBackend == .screenCapture)
        #expect(decoded.verifiedCodeHash.isEmpty)
    }

    @Test("Sogar ein leeres Objekt ergibt vollständige Standardwerte")
    func decodesEmptyPayload() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded == AppSettings())
    }

    @Test("Ein einzelnes kaputtes Feld reißt nicht alles mit")
    func toleratesWrongType() throws {
        let broken = """
        {"qualityModel": "gemma3:12b", "contextTokens": "achttausend"}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(broken.utf8))
        #expect(decoded.qualityModel == "gemma3:12b")
        #expect(decoded.contextTokens == AppSettings().contextTokens)
    }

    @Test("Automatisches Zuhören wird einmalig zum Opt-in")
    func migratesAutoStartToOptIn() throws {
        let defaults = UserDefaults(suiteName: "de.alfredhelp.tests.\(UUID().uuidString)")!
        var previous = AppSettings()
        previous.autoStartSession = true
        defaults.set(
            try JSONEncoder().encode(previous),
            forKey: "io.github.PalescoDev.alfredhelp.settings.v1"
        )

        let migrated = SettingsStore(defaults: defaults)
        #expect(migrated.settings.autoStartSession == false)

        migrated.update { $0.autoStartSession = true }
        #expect(SettingsStore(defaults: defaults).settings.autoStartSession == true)
    }

    @Test("Übernimmt Einstellungen aus der bisherigen App-Kennung")
    func migratesPreviousBundleSettings() throws {
        let oldDefaults = UserDefaults(suiteName: "de.alfredhelp.alt.\(UUID().uuidString)")!
        let newDefaults = UserDefaults(suiteName: "de.alfredhelp.neu.\(UUID().uuidString)")!
        var previous = AppSettings()
        previous.qualityModel = "gemma3:12b"
        previous.autoStartSession = true
        oldDefaults.set(
            try JSONEncoder().encode(previous),
            forKey: "io.github.fvulcan.alfredhelp.settings.v1"
        )

        let migrated = SettingsStore(defaults: newDefaults, legacyDefaults: oldDefaults)

        #expect(migrated.settings.qualityModel == "gemma3:12b")
        #expect(migrated.settings.autoStartSession == false)
        #expect(newDefaults.data(forKey: "io.github.PalescoDev.alfredhelp.settings.v1") != nil)
    }

    @Test("Übernimmt alte Einstellungen aus demselben Standardprofil")
    func migratesLegacySettingsFromStandardDomain() throws {
        let defaults = UserDefaults(suiteName: "de.alfredhelp.alt.standard.\(UUID().uuidString)")!
        var previous = AppSettings()
        previous.qualityModel = "gemma3:12b"
        defaults.set(
            try JSONEncoder().encode(previous),
            forKey: "io.github.fvulcan.alfredhelp.settings.v1"
        )

        let migrated = SettingsStore(defaults: defaults)

        #expect(migrated.settings.qualityModel == "gemma3:12b")
        #expect(defaults.data(forKey: "io.github.PalescoDev.alfredhelp.settings.v1") != nil)
    }

    @Test("Runde Reise bleibt verlustfrei")
    func roundTripsCompletely() throws {
        var settings = AppSettings()
        settings.systemAudioLocale = "fr-FR"
        settings.qualityModel = "qwen3:14b"
        settings.autoStartSession = false
        settings.userProfile = "Testprofil"
        settings.verifiedSystemAudioBackend = .processTap
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
    }
}
