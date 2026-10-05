import Foundation
import AVFoundation
import CoreMedia
import Speech

/// One recognizer result. Volatile events arrive within a few hundred
/// milliseconds and get replaced; final events are stable and are what the rest
/// of the pipeline reasons about.
public struct TranscriptEvent: Sendable {
    public let source: AudioSourceKind
    public let text: String
    public let isFinal: Bool
    public let startSeconds: Double
    public let endSeconds: Double
    public let confidence: Double?
    /// Monotonic timestamp of when this event reached us – the basis for the
    /// latency numbers shown in the UI.
    public let capturedAt: Double

    public init(
        source: AudioSourceKind,
        text: String,
        isFinal: Bool,
        startSeconds: Double,
        endSeconds: Double,
        confidence: Double?,
        capturedAt: Double = Clock.now()
    ) {
        self.source = source
        self.text = text
        self.isFinal = isFinal
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.confidence = confidence
        self.capturedAt = capturedAt
    }
}

/// Tuning knobs for the silence gate that keeps the recognizer idle while
/// nobody is speaking.
public struct SilenceGateOptions: Sendable {
    /// Linear amplitude below which audio counts as silence (≈ −55 dBFS).
    public var threshold: Float = 0.0018
    /// How long to keep feeding after the last speech-like chunk.
    public var holdSeconds: Double = 1.5
    /// How much audio to keep in reserve so the first syllable is never cut.
    public var prerollSeconds: Double = 0.5
    public var enabled: Bool = true

    public init() {}
}

/// Entscheidet, ob gerade gesprochen wird.
///
/// Reine Rechnerei auf Rahmenpositionen – bewusst herausgelöst aus
/// `SourceTranscriber`: dort steckte sie zwischen Resampler und
/// `SpeechAnalyzer` fest und war nur mit laufender Spracherkennung zu prüfen,
/// also gar nicht. Der Puffer für den Vorlauf bleibt beim Aufrufer, hier steht
/// nur die Entscheidung.
struct SilenceGate {

    enum Decision: Equatable {
        /// Durchreichen. Entweder ist die Schaltung aus oder sie steht offen.
        case pass
        /// Die Schaltung geht auf: erst den Vorlauf nachspielen, damit die
        /// erste Silbe nicht fehlt, dann diesen Block.
        case openAndReplayPreroll
        /// Zurückhalten und in den Vorlauf legen.
        case hold
    }

    let options: SilenceGateOptions
    private var lastSpeechPosition: Int64 = .min
    private var isOpen = false

    init(options: SilenceGateOptions) {
        self.options = options
    }

    /// `position` ist die Rahmennummer, bei der dieser Block beginnt.
    mutating func decide(peak: Float, position: Int64, frames: Int64, rate: Double) -> Decision {
        guard options.enabled else { return .pass }

        if peak >= options.threshold { lastSpeechPosition = position + frames }
        let holdFrames = Int64(options.holdSeconds * rate)
        let shouldBeOpen = lastSpeechPosition != .min
            && position <= lastSpeechPosition + holdFrames

        guard shouldBeOpen else {
            isOpen = false
            return .hold
        }
        guard !isOpen else { return .pass }
        isOpen = true
        return .openAndReplayPreroll
    }

    /// Nur für Tests und Diagnose.
    var isCurrentlyOpen: Bool { isOpen }
}

/// Drives one `SpeechAnalyzer` for a single audio source.
///
/// Split per source on purpose: two independent analyzers keep the two
/// speakers cleanly separated and let each side run in its own language.
public final class SourceTranscriber: @unchecked Sendable {
    /// A timed-out SpeechAnalyzer may ignore task cancellation and keep its
    /// result sequence alive. Closing this gate makes its captured callbacks
    /// inert before a replacement recognizer can start.
    private final class EventGate: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        private let onEvent: @Sendable (TranscriptEvent) -> Void
        private let onFailure: @Sendable (Error) -> Void

        init(
            onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
            onFailure: @escaping @Sendable (Error) -> Void
        ) {
            self.onEvent = onEvent
            self.onFailure = onFailure
        }

        func send(_ event: TranscriptEvent) {
            lock.withLock {
                guard active else { return }
                onEvent(event)
            }
        }

        func fail(_ error: Error) {
            lock.withLock {
                guard active else { return }
                onFailure(error)
            }
        }

        func close() {
            lock.withLock { active = false }
        }
    }


    public let source: AudioSourceKind
    private let gateOptions: SilenceGateOptions
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var resampler: StreamingResampler?
    private var analyzerFormat: AVAudioFormat?
    private var captureFormat: AVAudioFormat?
    private var eventGate: EventGate?
    /// Der Capture-Callback darf nie beliebig viele Audiopuffer in einer
    /// DispatchQueue festhalten. Ein einzelner Worker leert diesen begrenzten
    /// FIFO; bei dauerhafter Überlast wird der älteste statt immer mehr
    /// Speicher verworfen.
    private var pendingChunks: [AudioChunk] = []
    private var ingressWorkerScheduled = false
    private var acceptsAudio = false
    private static let maximumPendingChunks = 32

    // Silence gate state (only touched on `queue`).
    private var framePosition: Int64 = 0
    private var gate: SilenceGate
    private var preroll: [(position: Int64, buffer: AVAudioPCMBuffer)] = []
    private var prerollFrames: Int = 0

    public private(set) var locale: Locale

    public init(source: AudioSourceKind, locale: Locale, gate: SilenceGateOptions = SilenceGateOptions()) {
        self.source = source
        self.locale = locale
        self.gateOptions = gate
        self.gate = SilenceGate(options: gate)
        self.queue = DispatchQueue(label: "de.alfredhelp.transcribe.\(source.rawValue)", qos: .userInitiated)
    }

    /// Boots the analyzer. Throws if the locale has no on-device model.
    public func start(
        onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async throws {
        guard SpeechTranscriber.isAvailable else { throw SpeechAssetError.transcriberUnavailable }

        let module = SpeechAssets.makeTranscriber(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw SpeechAssetError.unsupportedLocale(locale.identifier)
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )

        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)

        let sourceKind = source
        let eventGate = EventGate(onEvent: onEvent, onFailure: onFailure)
        let task = Task.detached(priority: .userInitiated) {
            do {
                for try await result in module.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    eventGate.send(TranscriptEvent(
                        source: sourceKind,
                        text: text,
                        isFinal: result.isFinal,
                        startSeconds: result.range.start.seconds.isFinite ? result.range.start.seconds : 0,
                        endSeconds: result.range.end.seconds.isFinite ? result.range.end.seconds : 0,
                        confidence: Self.averageConfidence(of: result.text)
                    ))
                }
            } catch is CancellationError {
                // Normal shutdown.
            } catch {
                Log.speech.error("Result stream ended: \(String(describing: error), privacy: .public)")
                eventGate.fail(error)
            }
        }

        lock.withLock {
            self.analyzer = analyzer
            self.transcriber = module
            self.continuation = continuation
            self.resultsTask = task
            self.analyzerFormat = format
            self.eventGate = eventGate
            self.pendingChunks.removeAll(keepingCapacity: true)
            self.ingressWorkerScheduled = false
            self.acceptsAudio = true
        }

        Log.speech.info("Analyzer for \(sourceKind.rawValue, privacy: .public) ready (\(format.sampleRate, privacy: .public) Hz)")
    }

    /// Forces the recognizer to finish everything it has heard so far.
    ///
    /// Left alone, `SpeechAnalyzer` finalises a segment when it feels ready –
    /// measured on this machine that is 4 to 7 seconds after the speaker
    /// stopped, and often not until the *next* utterance arrives. Since the
    /// pipeline only answers finalised text, a question would sit unanswered
    /// until someone asked the next one. Calling this the moment the volatile
    /// hypothesis stops changing turns that wait into a fraction of a second.
    public func finalizeNow() async {
        let analyzer = lock.withLock { self.analyzer }
        guard let analyzer else { return }
        do {
            try await analyzer.finalize(through: nil)
        } catch {
            Log.speech.error("Forced finalize failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func stop() async {
        // Ab jetzt kann kein Capture-Callback mehr hinter unseren Drain-Block
        // geraten. Alles zuvor angenommene Audio wird noch verarbeitet.
        lock.withLock { acceptsAudio = false }
        queue.sync {}

        let (analyzer, continuation, task, eventGate) = lock.withLock {
            let values = (self.analyzer, self.continuation, self.resultsTask, self.eventGate)
            self.analyzer = nil
            self.transcriber = nil
            self.continuation = nil
            self.resultsTask = nil
            self.resampler = nil
            self.captureFormat = nil
            self.eventGate = nil
            self.pendingChunks.removeAll(keepingCapacity: true)
            self.ingressWorkerScheduled = false
            return values
        }

        continuation?.finish()
        // The timeout encloses *both* framework finalization and result-stream
        // draining. If either ignores cancellation, stop still returns; the
        // detached shutdown retains only its own old analyzer/task references.
        let shutdown = Task {
            if let analyzer {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    Log.speech.error("Final shutdown failed: \(String(describing: error), privacy: .public)")
                    task?.cancel()
                }
            }
            await task?.value
        }
        if await TaskTimeout.wait(for: shutdown, timeout: .seconds(2)) == false {
            shutdown.cancel()
            task?.cancel()
            Log.speech.error("Speech shutdown timed out; detached stale recognizer")
        }
        eventGate?.close()

        queue.sync {
            framePosition = 0
            gate = SilenceGate(options: gateOptions)
            preroll.removeAll()
            prerollFrames = 0
        }
    }

    /// Pushes captured audio. Safe to call from the audio thread; the actual
    /// work hops onto this transcriber's serial queue.
    public func feed(_ chunk: AudioChunk) {
        let scheduleWorker = lock.withLock { () -> Bool in
            guard acceptsAudio else { return false }
            if pendingChunks.count == Self.maximumPendingChunks {
                pendingChunks.removeFirst()
            }
            pendingChunks.append(chunk)
            guard !ingressWorkerScheduled else { return false }
            ingressWorkerScheduled = true
            return true
        }
        guard scheduleWorker else { return }
        queue.async { [weak self] in
            self?.drainIngress()
        }
    }

    private func drainIngress() {
        while true {
            let next = lock.withLock { () -> AudioChunk? in
                guard !pendingChunks.isEmpty else {
                    ingressWorkerScheduled = false
                    return nil
                }
                return pendingChunks.removeFirst()
            }
            guard let next else { return }
            process(next)
        }
    }

    private func process(_ chunk: AudioChunk) {
        lock.lock()
        let continuation = self.continuation
        let analyzerFormat = self.analyzerFormat
        var resampler = self.resampler
        let knownCaptureFormat = self.captureFormat
        lock.unlock()

        guard let continuation, let analyzerFormat else { return }

        let incomingFormat = chunk.buffer.format
        if resampler == nil || knownCaptureFormat != incomingFormat {
            guard let fresh = StreamingResampler(from: incomingFormat, to: analyzerFormat) else {
                Log.speech.error("No resampler from \(incomingFormat, privacy: .public)")
                return
            }
            resampler = fresh
            lock.lock()
            self.resampler = fresh
            self.captureFormat = incomingFormat
            lock.unlock()
        }
        guard let resampler, let converted = resampler.convert(chunk.buffer) else { return }

        let frames = Int64(converted.frameLength)
        let position = framePosition
        framePosition += frames

        let rate = analyzerFormat.sampleRate
        switch gate.decide(peak: chunk.peak, position: position, frames: frames, rate: rate) {
        case .pass:
            emit(converted, at: position, rate: rate, into: continuation)

        case .openAndReplayPreroll:
            // Speech just started: replay the pre-roll so no syllable is lost.
            for entry in preroll {
                emit(entry.buffer, at: entry.position, rate: rate, into: continuation)
            }
            preroll.removeAll()
            prerollFrames = 0
            emit(converted, at: position, rate: rate, into: continuation)

        case .hold:
            preroll.append((position, converted))
            prerollFrames += Int(frames)
            let maxPreroll = Int(gateOptions.prerollSeconds * rate)
            while prerollFrames > maxPreroll, let first = preroll.first {
                prerollFrames -= Int(first.buffer.frameLength)
                preroll.removeFirst()
            }
        }
    }

    private func emit(
        _ buffer: AVAudioPCMBuffer,
        at position: Int64,
        rate: Double,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        let time = CMTime(value: position, timescale: CMTimeScale(rate.rounded()))
        continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: time))
    }

    private static func averageConfidence(of text: AttributedString) -> Double? {
        var total = 0.0
        var count = 0
        for run in text.runs {
            if let value = run.transcriptionConfidence {
                total += value
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return total / Double(count)
    }
}
