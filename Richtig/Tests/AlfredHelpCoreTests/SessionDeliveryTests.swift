import Foundation
import Testing
@testable import AlfredHelpCore

private final class DeliveryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) { lock.withLock { values.append(value) } }
    func snapshot() -> [String] { lock.withLock { values } }
}

@Suite("Geordnete Sitzungsübergabe")
struct SessionDeliveryTests {
    private func utterance(_ text: String) -> Utterance {
        Utterance(source: .system, original: text, startSeconds: 0, endSeconds: 1)
    }

    @Test("Lieferungen erreichen die Pipeline in Erfassungsreihenfolge")
    func preservesOrder() async {
        let log = DeliveryLog()
        let delivery = OrderedUtteranceDelivery { utterance in
            if utterance.original == "A" {
                try? await Task.sleep(for: .milliseconds(40))
            }
            log.append(utterance.original)
        }
        let generation = delivery.currentGeneration

        delivery.enqueue(utterance("A"), generation: generation)
        delivery.enqueue(utterance("B"), generation: generation)
        delivery.enqueue(utterance("C"), generation: generation)
        await delivery.drain()

        #expect(log.snapshot() == ["A", "B", "C"])
    }

    @Test("Reset verwirft alte Warteschlange und steht vor der neuen Generation")
    func resetIsGenerationBarrier() async {
        let log = DeliveryLog()
        let delivery = OrderedUtteranceDelivery { utterance in
            log.append(utterance.original)
        }
        let oldGeneration = delivery.currentGeneration

        delivery.enqueue(utterance("alt"), generation: oldGeneration)
        let barrier = delivery.advanceGeneration {
            try? await Task.sleep(for: .milliseconds(30))
            log.append("reset")
        }
        let newGeneration = delivery.currentGeneration
        delivery.enqueue(utterance("veraltet"), generation: oldGeneration)
        delivery.enqueue(utterance("neu"), generation: newGeneration)

        await barrier.value
        await delivery.drain()

        let values = log.snapshot()
        #expect(!values.contains("veraltet"))
        #expect(values.suffix(2) == ["reset", "neu"])
    }
}

@Suite("Sitzungsstart")
struct SessionStartTests {
    @Test("Ohne Audioquelle bricht der Start ab und beendet den Startstatus")
    func rejectsMissingAudioSource() async throws {
        let suite = "SessionStartTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var settings = store.settings
        settings.captureSystemAudio = false
        settings.captureMicrophone = false
        store.settings = settings
        let coordinator = SessionCoordinator(settingsStore: store)
        let log = StateLog()
        coordinator.onState = { log.append($0) }

        do {
            try await coordinator.start()
            Issue.record("Start ohne Audioquelle hätte fehlschlagen müssen")
        } catch {
            #expect(error as? SessionError == .noAudioSourceEnabled)
        }

        #expect(coordinator.currentState.isRunning == false)
        #expect(coordinator.currentState.isStarting == false)
        #expect(log.snapshot().contains { $0.isStarting })
        #expect(log.snapshot().last?.isStarting == false)
    }
}

private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SessionState] = []

    func append(_ value: SessionState) { lock.withLock { values.append(value) } }
    func snapshot() -> [SessionState] { lock.withLock { values } }
}
