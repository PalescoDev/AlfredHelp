import Testing
@testable import AlfredHelpCore

@Suite("ScreenCapture-Wiederherstellung")
struct ScreenCaptureRecoveryTests {
    @Test("Wiederherstellung ist auf zwei Versuche begrenzt")
    func retryLimitIsBounded() {
        #expect(ScreenCaptureAudio.RecoveryPolicy.nextAttempt(after: 0) == 1)
        #expect(ScreenCaptureAudio.RecoveryPolicy.nextAttempt(after: 1) == 2)
        #expect(ScreenCaptureAudio.RecoveryPolicy.nextAttempt(after: 2) == nil)
    }

    @Test("Ein Ausfall während eines Versuchs wird zur späteren Wiederholung vorgemerkt")
    func failureDuringRecoveryIsDeferred() {
        #expect(
            ScreenCaptureAudio.RecoveryPolicy.decision(recoveryInProgress: true, attempts: 1)
                == .deferFailure
        )
        #expect(
            ScreenCaptureAudio.RecoveryPolicy.decision(recoveryInProgress: false, attempts: 1)
                == .scheduleAttempt(2)
        )
        #expect(
            ScreenCaptureAudio.RecoveryPolicy.decision(recoveryInProgress: false, attempts: 2)
                == .exhausted
        )
    }

    @Test("Ein einzelner später Buffer setzt die Versuche nicht zurück")
    func oneLateBufferDoesNotQualifyAsStableAudio() {
        var stability = ScreenCaptureAudio.RecoveryPolicy.AudioStability()

        let firstBufferResetsAttempts = stability.recordValidBuffer(at: 0)
        #expect(!firstBufferResetsAttempts)
        let lateBufferResetsAttempts = stability.recordValidBuffer(at: 40)
        #expect(!lateBufferResetsAttempts)
        #expect(stability.stableSince == 40)
    }

    @Test("Eine Lücke über zwei Sekunden startet das Stabilitätsfenster neu")
    func bufferGapRestartsStabilityWindow() {
        var stability = ScreenCaptureAudio.RecoveryPolicy.AudioStability()
        let firstBufferResetsAttempts = stability.recordValidBuffer(at: 0)
        #expect(!firstBufferResetsAttempts)
        for second in 1...29 {
            _ = stability.recordValidBuffer(at: Double(second))
        }

        let bufferAfterGapResetsAttempts = stability.recordValidBuffer(at: 32)
        #expect(!bufferAfterGapResetsAttempts)
        #expect(stability.stableSince == 32)
        var resetAttempts = false
        for second in 1...30 {
            resetAttempts = stability.recordValidBuffer(at: 32 + Double(second))
        }
        #expect(resetAttempts)
    }
}
