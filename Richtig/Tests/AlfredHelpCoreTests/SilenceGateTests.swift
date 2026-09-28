import Testing
import Foundation
@testable import AlfredHelpCore

/// Die Stilleschaltung entscheidet, ob die Spracherkennung überhaupt Arbeit
/// bekommt. Sie zu früh schließen heißt abgeschnittene Sätze, sie zu spät
/// schließen heißt Rechenlast im Leerlauf – und geprüft war sie bisher gar
/// nicht, weil sie zwischen Resampler und `SpeechAnalyzer` festsaß.
@Suite("Stilleschaltung")
struct SilenceGateTests {

    private static let rate = 16_000.0
    /// Ein Block von 100 ms bei 16 kHz.
    private static let block: Int64 = 1_600

    private func makeGate(
        enabled: Bool = true,
        hold: Double = 1.5,
        threshold: Float = 0.0018
    ) -> SilenceGate {
        var options = SilenceGateOptions()
        options.enabled = enabled
        options.holdSeconds = hold
        options.threshold = threshold
        return SilenceGate(options: options)
    }

    /// Schickt `count` Blöcke mit gleichbleibendem Pegel durch und liefert die
    /// Entscheidungen samt fortgeschriebener Position.
    @discardableResult
    private func feed(
        _ gate: inout SilenceGate,
        peak: Float,
        blocks count: Int,
        from position: inout Int64
    ) -> [SilenceGate.Decision] {
        var decisions: [SilenceGate.Decision] = []
        for _ in 0..<count {
            decisions.append(
                gate.decide(peak: peak, position: position, frames: Self.block, rate: Self.rate)
            )
            position += Self.block
        }
        return decisions
    }

    @Test("Abgeschaltet wird alles durchgereicht")
    func disabledPassesEverything() {
        var gate = makeGate(enabled: false)
        var position: Int64 = 0
        let decisions = feed(&gate, peak: 0, blocks: 10, from: &position)
        #expect(decisions.allSatisfy { $0 == .pass })
    }

    @Test("Stille wird zurückgehalten")
    func silenceIsHeld() {
        var gate = makeGate()
        var position: Int64 = 0
        let decisions = feed(&gate, peak: 0.0001, blocks: 10, from: &position)
        #expect(decisions.allSatisfy { $0 == .hold })
        #expect(!gate.isCurrentlyOpen)
    }

    @Test("Der erste laute Block öffnet und verlangt den Vorlauf")
    func firstLoudBlockOpensWithPreroll() {
        var gate = makeGate()
        var position: Int64 = 0
        feed(&gate, peak: 0.0001, blocks: 5, from: &position)

        let opening = gate.decide(peak: 0.4, position: position, frames: Self.block, rate: Self.rate)
        #expect(opening == .openAndReplayPreroll)
        #expect(gate.isCurrentlyOpen)
    }

    @Test("Solange die Schaltung offen ist, wird der Vorlauf nicht erneut verlangt")
    func stayingOpenDoesNotReplayAgain() {
        var gate = makeGate()
        var position: Int64 = 0
        _ = gate.decide(peak: 0.4, position: position, frames: Self.block, rate: Self.rate)
        position += Self.block

        let further = feed(&gate, peak: 0.4, blocks: 5, from: &position)
        #expect(further.allSatisfy { $0 == .pass })
    }

    /// Der Kern der Sache: eine Sprechpause zwischen zwei Wörtern darf die
    /// Schaltung nicht schließen. Genau daran ist die frühere Finalisierung
    /// über Textstabilität gescheitert – ein Satz zerfiel in drei Bruchstücke.
    @Test("Eine kurze Pause hält die Schaltung offen")
    func shortPauseKeepsGateOpen() {
        var gate = makeGate(hold: 1.5)
        var position: Int64 = 0
        _ = gate.decide(peak: 0.4, position: position, frames: Self.block, rate: Self.rate)
        position += Self.block

        // 1,0 s Stille – kürzer als die Haltezeit von 1,5 s.
        let during = feed(&gate, peak: 0.0001, blocks: 10, from: &position)
        #expect(during.allSatisfy { $0 == .pass })
        #expect(gate.isCurrentlyOpen)
    }

    @Test("Nach der Haltezeit schließt sie")
    func gateClosesAfterHold() {
        var gate = makeGate(hold: 1.5)
        var position: Int64 = 0
        _ = gate.decide(peak: 0.4, position: position, frames: Self.block, rate: Self.rate)
        position += Self.block

        // 2,0 s Stille – länger als die Haltezeit.
        let during = feed(&gate, peak: 0.0001, blocks: 20, from: &position)
        #expect(during.last == .hold)
        #expect(!gate.isCurrentlyOpen)
    }

    @Test("Nach dem Schließen öffnet der nächste laute Block wieder mit Vorlauf")
    func reopensWithPrerollAfterClosing() {
        var gate = makeGate(hold: 0.2)
        var position: Int64 = 0
        _ = gate.decide(peak: 0.4, position: position, frames: Self.block, rate: Self.rate)
        position += Self.block
        feed(&gate, peak: 0.0001, blocks: 10, from: &position)
        #expect(!gate.isCurrentlyOpen)

        let reopening = gate.decide(peak: 0.4, position: position, frames: Self.block, rate: Self.rate)
        #expect(reopening == .openAndReplayPreroll)
    }

    @Test("Genau auf der Schwelle gilt als Sprache")
    func thresholdIsInclusive() {
        var gate = makeGate(threshold: 0.01)
        let decision = gate.decide(peak: 0.01, position: 0, frames: Self.block, rate: Self.rate)
        #expect(decision == .openAndReplayPreroll)
    }

    @Test("Knapp unter der Schwelle nicht")
    func belowThresholdIsSilence() {
        var gate = makeGate(threshold: 0.01)
        let decision = gate.decide(peak: 0.0099, position: 0, frames: Self.block, rate: Self.rate)
        #expect(decision == .hold)
    }
}
