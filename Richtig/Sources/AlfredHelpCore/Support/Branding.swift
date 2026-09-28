import Foundation

/// Name, Urheber und Wasserzeichen an genau einer Stelle.
public enum Branding {
    public static let appName = "AlfredHelp"
    // Die macOS-Kennung bleibt für vorhandene Datenschutzfreigaben stabil.
    public static let bundleIdentifier = "io.github.fvulcan.alfredhelp"

    /// Das Wasserzeichen. Erscheint dezent im Overlay, im Einrichtungsfenster,
    /// in den Einstellungen und in jedem exportierten Protokoll.
    public static let watermark = "PalescoDev"

    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// Eine Zeile für Fußzeilen und Dateiköpfe.
    public static var signature: String {
        "\(appName) \(version) · \(watermark)"
    }
}

/// Übernimmt Einstellungen und Protokolle aus der Vorgängerfassung, damit eine
/// Umbenennung den Nutzer nicht die Einrichtung wiederholen lässt.
public enum LegacyMigration {

    private static let previousDefaultsDomain = "de.simultan.app"
    private static let previousSettingsKey = "de.simultan.settings.v1"
    private static let previousSupportFolder = "Simultan"

    /// Läuft einmalig beim Start. Vorhandene neue Daten werden nie überschrieben.
    public static func run(into store: SettingsStore) {
        migrateSettings(into: store)
        migrateSupportFolder()
    }

    private static func migrateSettings(into store: SettingsStore) {
        // Nur wenn hier noch nichts steht.
        guard store.settings.qualityModel.isEmpty else { return }
        guard let defaults = UserDefaults(suiteName: previousDefaultsDomain),
              let data = defaults.data(forKey: previousSettingsKey),
              let previous = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return
        }
        var migrated = previous
        // Die Signatur gehört zur alten Anwendung – die Freigabe muss neu erteilt
        // werden, und das soll die App auch merken.
        migrated.systemAudioVerified = false
        migrated.verifiedCodeHash = ""
        store.settings = migrated
        Log.ui.info("Einstellungen aus der Vorgängerfassung übernommen")
    }

    private static func migrateSupportFolder() {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent(previousSupportFolder, isDirectory: true)
        let new = base.appendingPathComponent(Branding.appName, isDirectory: true)
        guard manager.fileExists(atPath: old.path),
              !manager.fileExists(atPath: new.path) else { return }
        try? manager.moveItem(at: old, to: new)
        Log.ui.info("Protokollordner übernommen")
    }
}
