import Foundation
import CoreAudio

/// Lautstärke und Stummschaltung des Standard-Ausgabegeräts.
///
/// Hintergrund: ScreenCaptureKit erfasst den Ton **so, wie er zum Ausgabegerät
/// geht** — also nach Lautstärkeregler und Stummschaltung. Ein stummgeschalteter
/// Mac liefert deshalb einwandfreie Rahmen, die ausschließlich Nullen enthalten.
/// Das sieht exakt aus wie eine entzogene Freigabe, ist aber etwas völlig
/// anderes. Nachgemessen auf diesem Gerät: bei `output volume 0, muted:true`
/// Spitzenpegel 0.0000, bei Lautstärke 40 derselbe Ton mit Spitzenpegel 0.9187.
///
/// Systemklänge (Warntöne) sind davon ausgenommen — sie laufen über den
/// separaten Ausgang für Signaltöne und werden auch bei stummem Hauptausgang
/// erfasst. Wer die Erfassung mit `/System/Library/Sounds/…` prüft, misst
/// deshalb möglicherweise nicht das, was er zu messen glaubt.
public enum OutputVolume {

    public struct State: Sendable {
        public let deviceName: String
        /// `nil`, wenn das Gerät keine Lautstärke in Software anbietet.
        public let volume: Float?
        public let isMuted: Bool

        /// Kann über diesen Ausgang gerade überhaupt etwas hörbar sein?
        ///
        /// Die Schwelle ist bewusst winzig: Der Gerätewert ist nicht linear zum
        /// Systemregler — gemessen ergab Regler 40 % einen Skalar von 0,06. Eine
        /// großzügigere Schwelle würde also leise, aber hörbare Einstellungen
        /// als stumm melden und damit eine echte fehlende Freigabe verdecken.
        public var isSilenced: Bool {
            if isMuted { return true }
            if let volume { return volume < 0.001 }
            return false
        }

        /// Ein Satz für Nutzer, oder `nil`, wenn alles in Ordnung ist.
        public var explanation: String? {
            guard isSilenced else { return nil }
            if isMuted {
                return "„\(deviceName)“ ist stummgeschaltet – die Aufnahme "
                     + "bekommt dieselbe Stille wie deine Ohren."
            }
            return "Die Lautstärke von „\(deviceName)“ steht auf null – die "
                 + "Aufnahme bekommt dieselbe Stille wie deine Ohren."
        }
    }

    public static var current: State {
        guard let deviceID = try? AudioObject.defaultOutputDeviceID,
              deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return State(deviceName: "Unbekanntes Gerät", volume: nil, isMuted: false)
        }
        return State(
            deviceName: AudioObject.deviceName(deviceID),
            volume: volume(of: deviceID),
            isMuted: isMuted(of: deviceID)
        )
    }

    /// Viele Geräte kennen keinen Hauptregler, sondern nur Kanäle. Deshalb erst
    /// den Hauptregler, dann die ersten Kanäle; der lauteste Kanal zählt.
    private static func volume(of deviceID: AudioObjectID) -> Float? {
        var loudest: Float?
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            let address = AudioObject.address(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: AudioObjectPropertyElement(element)
            )
            guard let value = try? AudioObject.value(
                deviceID, address, defaultValue: Float(0), operation: "read output volume"
            ) else { continue }
            loudest = max(loudest ?? 0, value)
        }
        return loudest
    }

    private static func isMuted(of deviceID: AudioObjectID) -> Bool {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            let address = AudioObject.address(
                kAudioDevicePropertyMute,
                scope: kAudioDevicePropertyScopeOutput,
                element: AudioObjectPropertyElement(element)
            )
            if let value = try? AudioObject.value(
                deviceID, address, defaultValue: UInt32(0), operation: "read output mute"
            ), value != 0 {
                return true
            }
        }
        return false
    }
}
