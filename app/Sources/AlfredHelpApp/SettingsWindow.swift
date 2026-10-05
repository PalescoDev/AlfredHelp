import SwiftUI
import AppKit

extension OpenSettingsAction {

    /// Öffnet die Einstellungen **und bringt sie auch nach vorn**.
    ///
    /// `openSettings()` allein genügt in dieser App nicht, und zwar aus zwei
    /// Gründen, die zusammen dafür sorgten, dass auf einen Klick hin gar
    /// nichts zu sehen war.
    ///
    /// AlfredHelp läuft als `.accessory`: kein Dock-Symbol, keine eigene
    /// Menüleiste. Ein Klick in eines ihrer Menüs **aktiviert die App nicht**.
    /// Das Einstellungsfenster entsteht dann zwar und liegt vorn – aber nur
    /// innerhalb einer Anwendung, die selbst im Hintergrund ist. Vor dem
    /// Nutzer steht weiter Teams, der Browser oder was sonst gerade aktiv war.
    ///
    /// Dazu kommt der Zeitpunkt: Der Aufruf kommt aus einem geöffneten Menü,
    /// und das dreht bis zu seinem Schließen eine eigene Ereignisschleife. Erst
    /// im nächsten Durchlauf ist es fort und das Fenster kann sauber nach vorn.
    ///
    /// `NSApp.activate()` ohne Argument ist die Fassung ab macOS 14; die alte
    /// `activate(ignoringOtherApps:)` ist abgekündigt und bräche den Bau, der
    /// Warnungen als Fehler behandelt.
    @MainActor
    func bringToFront() {
        DispatchQueue.main.async {
            NSApp.activate()
            self()
        }
    }
}
