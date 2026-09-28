import Foundation
import AVFoundation
import Accelerate

/// Where a piece of audio came from. Keeping the two apart is what lets the
/// assistant answer questions the *other* side asked without reacting to the
/// user's own voice.
public enum AudioSourceKind: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Everything the Mac plays back – Teams, Zoom, a browser tab, anything.
    case system
    /// The user's own microphone.
    case microphone

    public var id: String { rawValue }

    public var germanName: String {
        switch self {
        case .system: return "Systemaudio"
        case .microphone: return "Mikrofon"
        }
    }

    /// Label shown in front of a transcript line.
    public var speakerLabel: String {
        switch self {
        case .system: return "Gegenüber"
        case .microphone: return "Ich"
        }
    }
}

/// A block of mono float samples handed from a capture backend to the
/// transcription layer.
///
/// `AVAudioPCMBuffer` is not `Sendable`, but every chunk is freshly allocated by
/// the producer and never touched again after being yielded, so passing it
/// across isolation domains is safe here.
public struct AudioChunk: @unchecked Sendable {
    public let source: AudioSourceKind
    public let buffer: AVAudioPCMBuffer
    public let time: AVAudioTime?
    /// Peak amplitude (0…1) of this chunk, used for the level meter and for
    /// cheap silence gating before any heavier work runs.
    public let peak: Float

    public init(source: AudioSourceKind, buffer: AVAudioPCMBuffer, time: AVAudioTime?, peak: Float) {
        self.source = source
        self.buffer = buffer
        self.time = time
        self.peak = peak
    }
}

extension AppSettings.SystemAudioBackend {
    /// Baut die zu dieser Einstellung gehörende Erfassung.
    ///
    /// Bewusst an genau einer Stelle: die Sitzung und die Freigabeprüfung
    /// müssen dasselbe Verfahren benutzen. Solange sie das nicht taten, prüfte
    /// die Freigabe stets *Bildschirmaufnahme*, während ein auf `processTap`
    /// gestellter Lauf tatsächlich *Audioaufnahme* braucht – die Prüfung
    /// meldete dann „Freigabe fehlt" bei erteilter Freigabe, und umgekehrt.
    public func makeCapture() -> any SystemAudioCapturing {
        switch self {
        case .screenCapture: return ScreenCaptureAudio()
        case .processTap: return SystemAudioTap()
        }
    }
}

/// Reicht **einen** Puffer an einen `AVAudioConverter` weiter.
///
/// `AVAudioConverterInputBlock` ist als `@Sendable` deklariert, obwohl der
/// Konverter ihn synchron auf demselben Thread aufruft und `convert` erst
/// zurückkehrt, wenn er fertig ist. Ein direkt eingefangener Puffer und ein
/// eingefangenes `var` sind deshalb formal ein Nebenläufigkeitsfehler, ohne
/// dass hier je zwei Threads im Spiel wären. Statt sich auf eine Warnung zu
/// verlassen, die je nach Compilerfassung erscheint oder nicht, steht die
/// Zusicherung hier ausgeschrieben.
final class ConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var consumed = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    /// Beim ersten Aufruf der Puffer, danach `nil` – so weiß der Konverter,
    /// dass nichts mehr nachkommt.
    func next(_ statusPointer: UnsafeMutablePointer<AVAudioConverterInputStatus>)
        -> AVAudioPCMBuffer? {
        guard !consumed else {
            statusPointer.pointee = .noDataNow
            return nil
        }
        consumed = true
        statusPointer.pointee = .haveData
        return buffer
    }
}

/// Common interface for the two capture backends.
public protocol AudioCapturing: AnyObject, Sendable {
    var source: AudioSourceKind { get }
    /// Native format of the delivered chunks (always mono float32).
    var captureFormat: AVAudioFormat? { get }
    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws
    func stop()
}

/// Was die beiden Systemton-Verfahren zusätzlich können müssen.
///
/// Bewusst getrennt vom allgemeinen `AudioCapturing`: das Mikrofon braucht
/// weder eine Rahmenzählung für die Freigabeprüfung noch einen Kanal für
/// Klartext-Hinweise zur Systemton-Berechtigung.
public protocol SystemAudioCapturing: AudioCapturing {
    /// Wie viele Rahmen bisher wirklich angekommen sind – die einzige Auskunft,
    /// die eine erteilte Freigabe von einer fehlenden unterscheidet. macOS
    /// meldet eine fehlende Freigabe nicht, es liefert Nullen.
    var deliveredFrameCount: Int { get }
    /// Meldet Klartext-Probleme des Backends (fehlende Freigabe, Gerätefehler).
    var onStatusChange: (@Sendable (String) -> Void)? { get set }
}

enum AudioCaptureError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case unsupportedTapFormat
    case microphonePermissionDenied
    case microphoneUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            if status == kAudioHardwareIllegalOperationError || status == kAudioDevicePermissionsError {
                return "Systemaudio darf nicht mitgehört werden. Bitte in den Systemeinstellungen unter „Datenschutz & Sicherheit › Audioaufnahme“ für AlfredHelp erlauben."
            }
            return "Systemaudio-Tap konnte nicht erstellt werden (\(AudioObject.Error.describe(status)))."
        case .aggregateDeviceFailed(let status):
            return "Internes Audiogerät konnte nicht erstellt werden (\(AudioObject.Error.describe(status)))."
        case .ioProcFailed(let status):
            return "Audio-Callback konnte nicht gestartet werden (\(AudioObject.Error.describe(status)))."
        case .unsupportedTapFormat:
            return "Das Systemaudio-Format wird nicht unterstützt."
        case .microphonePermissionDenied:
            return "Kein Zugriff auf das Mikrofon. Bitte in den Systemeinstellungen unter „Datenschutz & Sicherheit › Mikrofon“ erlauben."
        case .microphoneUnavailable(let detail):
            return "Mikrofon nicht verfügbar: \(detail)"
        }
    }
}

extension AVAudioPCMBuffer {
    /// Peak magnitude across the first channel.
    ///
    /// `vDSP_maxmgv` statt einer Schleife: das hier läuft auf dem Audio-Thread,
    /// für jeden Puffer, bei 48 kHz. Das Ergebnis ist dasselbe, die Arbeit
    /// vektorisiert.
    public var peakAmplitude: Float {
        guard let data = floatChannelData, frameLength > 0 else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(data[0], 1, &peak, vDSP_Length(frameLength))
        return peak
    }
}
