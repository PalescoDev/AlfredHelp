import Testing
import Foundation
import AVFoundation
@testable import AlfredHelpCore

/// Der Antwortstrom war der teuerste Pfad der App: bei jedem Token wurde der
/// gesamte bisherige Text neu zerlegt. Der inkrementelle Aufbau darf dabei
/// nichts am Ergebnis ändern – genau das wird hier nachgewiesen, indem beide
/// Wege gegeneinander gefahren werden.
@Suite("Antwortstrom")
struct AnswerStreamFormatterTests {

    /// Schickt einen Text tokenweise durch den Formatierer.
    private func stream(_ text: String, chunkSize: Int = 3) -> TextUtilities.AnswerStreamFormatter {
        var formatter = TextUtilities.AnswerStreamFormatter()
        var rest = Substring(text)
        while !rest.isEmpty {
            let piece = rest.prefix(chunkSize)
            formatter.append(String(piece))
            rest = rest.dropFirst(piece.count)
        }
        return formatter
    }

    private static let texts: [String] = [
        "Etwa vier Stunden.",
        "Etwa vier Stunden.\n\n\(Prompts.answerDetailMarker)\nGemessen im Januar, auf der alten Hardware.",
        "Etwa vier Stunden.\n\n**\(Prompts.answerDetailMarker)**\nGemessen im Januar.",
        "Etwa vier Stunden.\n\n__\(Prompts.answerDetailMarker)__\nHintergrund dazu.",
        "TEIL 1\nEtwa vier Stunden.\n\nTEIL 2\nDetails folgen.",
        "<think>Der fragt nach der Dauer.</think>Etwa vier Stunden.",
        "<think>Erst nachdenken.</think>Vier Stunden.\n\n**\(Prompts.answerDetailMarker)**\nDetails.",
        "Vier Stunden.\n\n**\(Prompts.answerDetailMarker)**\n<think>kurz überlegen</think>Gemessen im Januar.",
        "Kurz und ohne alles",
        ""
    ]

    @Test("Das Endergebnis ist identisch zur vollständigen Rechnung", arguments: texts)
    func finishMatchesFullComputation(text: String) {
        let expected = TextUtilities.splitAnswer(TextUtilities.stripThinking(text))
        let actual = stream(text).finish()
        #expect(actual.spoken == expected.spoken)
        #expect(actual.details == expected.details)
    }

    @Test("Auch bei Einzelzeichen-Tokens stimmt das Ergebnis", arguments: texts)
    func finishMatchesWithSingleCharacterChunks(text: String) {
        let expected = TextUtilities.splitAnswer(TextUtilities.stripThinking(text))
        let actual = stream(text, chunkSize: 1).finish()
        #expect(actual.spoken == expected.spoken)
        #expect(actual.details == expected.details)
    }

    @Test("Der Zwischenstand entspricht dem, was die volle Rechnung zeigen würde")
    func currentMatchesAtEveryStep() {
        let text = "Etwa vier Stunden.\n\n**\(Prompts.answerDetailMarker)**\nGemessen im Januar."
        var formatter = TextUtilities.AnswerStreamFormatter()
        var seen = ""
        for character in text {
            formatter.append(String(character))
            seen.append(character)
            let expected = TextUtilities.splitAnswer(TextUtilities.stripThinking(seen))
            let actual = formatter.current
            #expect(actual.spoken == expected.spoken, "bei: \(seen)")
            #expect(actual.details == expected.details, "bei: \(seen)")
        }
    }

    /// Der eigentliche Zweck der Abkürzung: sobald die Trennstelle steht, wird
    /// nicht mehr gesucht. Sie darf aber erst dann stehen, wenn sie sich nicht
    /// mehr verschieben kann – aus `**Hintergrund` wird sonst `**Hintergrund**`
    /// und die `**` blieben im gesprochenen Teil stehen.
    @Test("Ein halb eingetroffener ausgezeichneter Marker rastet nicht vorzeitig ein")
    func decoratedMarkerIsNotLatchedTooEarly() {
        var formatter = TextUtilities.AnswerStreamFormatter()
        // Der nackte Marker steht schon da, die schließende Auszeichnung fehlt.
        // Wer hier festlegt, hat die Sternchen für immer im Sprechteil.
        formatter.append("Vier Stunden.\n\n**\(Prompts.answerDetailMarker)")
        // Auch der Zwischenschritt `*Marker*` darf noch nicht einrasten.
        formatter.append("*")
        formatter.append("*\nDetails.")
        #expect(formatter.current.spoken == "Vier Stunden.")
        #expect(formatter.current.details == "Details.")
        #expect(formatter.finish().spoken == "Vier Stunden.")
    }

    /// Ein Modell, das `think: false` übergeht und erst **nach** der
    /// Trennstelle zu denken anfängt. Die Live-Ansicht zeigte das rohe
    /// Denkprotokoll, das im Endergebnis dann fehlte.
    @Test("Ein Denkblock hinter der Trennstelle taucht auch live nicht auf")
    func thinkingAfterTheMarkerIsStrippedLiveToo() {
        var formatter = TextUtilities.AnswerStreamFormatter()
        formatter.append("Vier Stunden.\n\n**\(Prompts.answerDetailMarker)**\n")
        formatter.append("<think>Soll ich die Zahl nennen?</think>")
        formatter.append("Gemessen im Januar.")

        #expect(!formatter.current.details.contains("<think>"))
        #expect(!formatter.current.details.contains("Soll ich die Zahl nennen?"))
        #expect(formatter.current.details == formatter.finish().details)
    }

    @Test("Der Rohtext bleibt vollständig erhalten")
    func rawTextIsPreserved() {
        let text = "Ein Satz. Noch einer."
        #expect(stream(text).rawText == text)
    }
}

/// `cleanModelText` legte beim Streamen für jedes Token sieben vollständige
/// Kleinschreib-Kopien des bisherigen Textes an. Die Abkürzung darf am
/// Verhalten nichts ändern.
@Suite("Modelltext aufräumen")
struct CleanModelTextTests {

    @Test("Präfixe verschwinden, unabhängig von der Schreibweise", arguments: [
        ("Übersetzung: Guten Tag", "Guten Tag"),
        ("ÜBERSETZUNG: Guten Tag", "Guten Tag"),
        ("Translation: Good day", "Good day"),
        ("Auf Deutsch: Guten Tag", "Guten Tag"),
        ("Antwort: Vier Stunden", "Vier Stunden"),
        ("Guten Tag", "Guten Tag")
    ])
    func stripsPrefixes(input: String, expected: String) {
        #expect(TextUtilities.cleanModelText(input) == expected)
    }

    @Test("Umschließende Anführungszeichen fallen weg", arguments: [
        "\"Guten Tag\"", "„Guten Tag“", "»Guten Tag«", "'Guten Tag'"
    ])
    func stripsQuotes(input: String) {
        #expect(TextUtilities.cleanModelText(input) == "Guten Tag")
    }

    @Test("Ein Präfix mitten im Text bleibt stehen")
    func keepsPrefixInsideText() {
        let text = "Das steht so in der Übersetzung: nirgends"
        #expect(TextUtilities.cleanModelText(text) == text)
    }

    @Test("Denkblöcke verschwinden")
    func stripsThinking() {
        #expect(TextUtilities.cleanModelText("<think>egal</think>Guten Tag") == "Guten Tag")
    }
}

/// Ein Formatwechsel zur Laufzeit – etwa beim Umschalten des Ausgabegeräts –
/// baut den Resampler neu auf. Bisher ungeprüft.
@Suite("Streaming-Resampler")
struct StreamingResamplerTests {

    private func buffer(rate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount)
        -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate,
            channels: channels, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for index in 0..<Int(frames) {
                data[index] = sin(Float(index) * 0.05)
            }
        }
        return buffer
    }

    @Test("48 kHz mono auf 16 kHz mono liefert etwa ein Drittel der Rahmen")
    func downsamplesMono() throws {
        let source = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        )!
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        )!
        let resampler = try #require(StreamingResampler(from: source, to: target))
        let output = try #require(resampler.convert(buffer(rate: 48_000, channels: 1, frames: 4_800)))
        #expect(output.format.sampleRate == 16_000)
        // Der Konverter puffert etwas; ein grober Rahmen genügt als Nachweis,
        // dass wirklich umgerechnet und nicht durchgereicht wurde.
        #expect(output.frameLength > 1_200 && output.frameLength <= 1_700)
    }

    @Test("Gleiches Format bleibt gleich lang")
    func passesThroughSameRate() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        )!
        let resampler = try #require(StreamingResampler(from: format, to: format))
        let output = try #require(resampler.convert(buffer(rate: 16_000, channels: 1, frames: 1_600)))
        #expect(output.frameLength == 1_600)
    }

    @Test("Stereo wird auf mono zusammengelegt")
    func mixesStereoDown() throws {
        let source = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
        )!
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        )!
        let resampler = try #require(StreamingResampler(from: source, to: target))
        let output = try #require(resampler.convert(buffer(rate: 48_000, channels: 2, frames: 4_800)))
        #expect(output.format.channelCount == 1)
    }
}
