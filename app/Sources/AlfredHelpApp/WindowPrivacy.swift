import AppKit

/// Hält **jedes** Fenster der App aus Bildschirmaufnahmen heraus, solange die
/// Einstellung aktiv ist.
///
/// Es genügt nicht, das Overlay zu schützen: wer während eines Calls die
/// Einstellungen oder das Einrichtungsfenster öffnet, hätte sie sonst mitten in
/// der Bildschirmfreigabe stehen. Dasselbe gilt für Menüs – das Menü der
/// Menüleiste und das „…"-Menü im Overlay sind eigene Fenster, und sie tragen
/// die Namen der Bedienpunkte offen im Bild. Und all diese Fenster entstehen
/// erst zur Laufzeit, also reicht ein einmaliges Setzen beim Start nicht.
///
/// `NSWindow.sharingType = .none` ist der von macOS vorgesehene Weg. Er wirkt
/// gegen ScreenCaptureKit – die Schnittstelle, die Teams, Zoom, Discord und
/// `screencapture` heute benutzen. Auf dem Bildschirm bleibt das Fenster für den
/// Nutzer selbst vollständig sichtbar.
@MainActor
enum WindowPrivacy {

    private static var isHidden = true
    private static var observer: CFRunLoopObserver?

    /// Übernimmt die Einstellung und hält sie ab jetzt auch für später
    /// erzeugte Fenster durch.
    static func apply(hidden: Bool) {
        isHidden = hidden
        enforce()
        hidden ? startWatching() : stopWatching()
    }

    private static func startWatching() {
        guard observer == nil else { return }
        // Ein neu erzeugtes Fenster meldet sich nirgends an; der Zustand muss
        // also nachgezogen werden. `NSApplication.didUpdateNotification` taugt
        // dafür nicht, obwohl sie danach aussieht: Sie feuert nur, während
        // AppKit Ereignisse verarbeitet. Eine Menüleisten-App liegt die meiste
        // Zeit still, und – entscheidend – solange ein Menü offen ist, dreht
        // das Menü seine eigene Ereignisschleife und die Benachrichtigung
        // bleibt vollständig aus. Genau dann steht das Menü ungeschützt im
        // Bild, und zwar so lange, wie es offen ist.
        //
        // Der Runloop selbst läuft immer. Ein Beobachter in den „common modes"
        // greift deshalb auch während der Menüverfolgung. `beforeWaiting` liegt
        // vor dem Zeichnen des Bildes, das Fenster ist also schon geschützt,
        // wenn es zum ersten Mal erscheint – und mehr braucht es nicht.
        // `beforeSources` zusätzlich zu beobachten verdoppelt bloß die
        // Frequenz, ohne einen Fall abzudecken, den `beforeWaiting` verpasst.
        let loopObserver = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            0,
            { _, _ in MainActor.assumeIsolated { enforce() } }
        )
        CFRunLoopAddObserver(CFRunLoopGetMain(), loopObserver, .commonModes)
        observer = loopObserver
    }

    /// Ist die Funktion abgeschaltet, gibt es nichts nachzuziehen.
    ///
    /// Ohne dieses Gegenstück liefe der Beobachter bis zum Programmende weiter
    /// und setzte bei jedem Durchlauf `.readOnly` – für eine Funktion, die aus
    /// ist, und dabei auch auf jedem Fenster, das aus einem anderen Grund
    /// verborgen sein soll.
    private static func stopWatching() {
        guard let existing = observer else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), existing, .commonModes)
        CFRunLoopObserverInvalidate(existing)
        observer = nil
    }

    /// Setzt den Zustand auf allen aktuellen Fenstern. Billig genug, um bei
    /// jedem Durchlauf zu laufen: gesetzt wird nur, was abweicht.
    private static func enforce() {
        let wanted: NSWindow.SharingType = isHidden ? .none : .readOnly
        for window in NSApplication.shared.windows where window.sharingType != wanted {
            window.sharingType = wanted
        }
    }

    /// Prüft, ob gerade wirklich jedes Fenster geschützt ist.
    /// Grundlage für den Selbsttest – eine Zusicherung ohne Nachweis ist wertlos.
    static var allWindowsProtected: Bool {
        NSApplication.shared.windows.allSatisfy { $0.sharingType == .none }
    }

    static var windowCount: Int { NSApplication.shared.windows.count }
}
