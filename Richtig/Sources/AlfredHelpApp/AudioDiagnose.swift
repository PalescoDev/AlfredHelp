import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import AlfredHelpCore

/// `AlfredHelp --audio-diagnose` – vermisst die Systemaudio-Kette Schritt für
/// Schritt und probiert mehrere Aggregat-Konfigurationen durch, statt eine
/// anzunehmen. Läuft unter der Code-Identität der App, damit die TCC-Zuordnung
/// dieselbe ist wie im Normalbetrieb.
enum AudioDiagnose {

    static func run() async -> Int32 {
        print("AlfredHelp – Audio-Diagnose\n" + String(repeating: "═", count: 74))

        // 1) Geräteumfeld
        guard let outputID = try? AudioObject.defaultOutputDeviceID,
              outputID != AudioObjectID(kAudioObjectUnknown),
              let outputUID = try? AudioObject.deviceUID(outputID) else {
            print("✗ Kein Standard-Ausgabegerät ermittelbar.")
            return 1
        }
        let outputName = AudioObject.deviceName(outputID)
        let outChannels = AudioObject.channelCount(outputID, scope: kAudioObjectPropertyScopeOutput)
        let inChannels = AudioObject.channelCount(outputID, scope: kAudioObjectPropertyScopeInput)
        let rate = (try? AudioObject.nominalSampleRate(outputID)) ?? 0
        print("Standard-Ausgabe : \(outputName)")
        print("  UID            : \(outputUID)")
        print("  Kanäle         : \(outChannels) aus / \(inChannels) ein, \(Int(rate)) Hz")

        // 2) Tap anlegen und die beiden UID-Kandidaten vergleichen
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "AlfredHelp Diagnose"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        let descriptionUUID = description.uuid.uuidString

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else {
            print("✗ AudioHardwareCreateProcessTap: \(AudioObject.Error.describe(tapStatus))")
            return 1
        }
        defer { AudioHardwareDestroyProcessTap(tapID) }

        let propertyUID = (try? AudioObject.string(
            tapID, AudioObject.address(kAudioTapPropertyUID), operation: "tap uid"
        )) ?? "—"
        var asbd = (try? AudioObject.value(
            tapID, AudioObject.address(kAudioTapPropertyFormat),
            defaultValue: AudioStreamBasicDescription(), operation: "tap format"
        )) ?? AudioStreamBasicDescription()
        let format = AVAudioFormat(streamDescription: &asbd)

        print("\nTap-Beschreibung (global, exklusiv?)")
        print("  isExclusive    : \(description.isExclusive)")
        print("  isMono         : \(description.isMono)")
        print("  isMixdown      : \(description.isMixdown)")
        print("  processes      : \(description.__processes.count) Einträge")
        print("  deviceUID      : \(description.deviceUID ?? "—")")

        print("\nTap")
        print("  Objekt-ID      : \(tapID)")
        print("  description.uuid : \(descriptionUUID)")
        print("  kAudioTapPropertyUID : \(propertyUID)")
        print("  identisch      : \(descriptionUUID.caseInsensitiveCompare(propertyUID) == .orderedSame ? "ja" : "NEIN")")
        print("  Format         : \(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) Kanäle, "
              + "\(format?.commonFormat == .pcmFormatFloat32 ? "float32" : "anderes Format")")

        // 3) Aggregat-Varianten durchmessen
        let variants: [(String, [String: Any])] = [
            ("A  Ausgabegerät als Haupt-Subgerät (bisherige Umsetzung)",
             aggregate(tapUID: propertyUID, outputUID: outputUID, includeSubDevice: true, mainIsTap: false)),
            ("B  wie A, aber Tap-UID aus description.uuid",
             aggregate(tapUID: descriptionUUID, outputUID: outputUID, includeSubDevice: true, mainIsTap: false)),
            ("C  nur Tap, kein Subgerät",
             aggregate(tapUID: propertyUID, outputUID: nil, includeSubDevice: false, mainIsTap: false)),
            ("D  nur Tap, Tap als Haupt-Subgerät",
             aggregate(tapUID: propertyUID, outputUID: nil, includeSubDevice: false, mainIsTap: true))
        ]

        // Gerätegebundener Tap: hängt am konkreten Ausgabestrom statt global.
        // Der Swift-Overlay bietet für die gerätegebundenen Initialisierer
        // keinen verfeinerten Namen – daher die __-Variante mit NSNumber-Array.
        let deviceTap = CATapDescription(
            __excludingProcesses: [], andDeviceUID: outputUID, withStream: 0
        )
        deviceTap.name = "AlfredHelp Diagnose Gerät"
        deviceTap.isPrivate = true
        deviceTap.muteBehavior = .unmuted
        deviceTap.isMono = true
        var deviceTapID = AudioObjectID(kAudioObjectUnknown)
        let deviceTapStatus = AudioHardwareCreateProcessTap(deviceTap, &deviceTapID)
        var deviceVariants: [(String, [String: Any])] = []
        if deviceTapStatus == noErr {
            let uid = (try? AudioObject.string(
                deviceTapID, AudioObject.address(kAudioTapPropertyUID), operation: "uid"
            )) ?? deviceTap.uuid.uuidString
            deviceVariants = [
                ("E  gerätegebundener Tap + Ausgabegerät",
                 aggregate(tapUID: uid, outputUID: outputUID, includeSubDevice: true, mainIsTap: false)),
                ("F  gerätegebundener Tap allein",
                 aggregate(tapUID: uid, outputUID: nil, includeSubDevice: false, mainIsTap: true))
            ]
        } else {
            print("\nGerätegebundener Tap nicht erstellbar: "
                  + AudioObject.Error.describe(deviceTapStatus))
        }
        defer { if deviceTapStatus == noErr { AudioHardwareDestroyProcessTap(deviceTapID) } }

        // Expliziter Tap über alle bekannten Audio-Prozesse statt „global".
        var processTapID = AudioObjectID(kAudioObjectUnknown)
        var processVariants: [(String, [String: Any])] = []
        if let processBytes = try? AudioObject.rawValue(
            AudioObjectID(kAudioObjectSystemObject),
            AudioObject.address(kAudioHardwarePropertyProcessObjectList),
            operation: "process list"
        ) {
            let processIDs = processBytes.withUnsafeBytes {
                Array($0.bindMemory(to: AudioObjectID.self))
            }
            print("\nAudio-Prozessobjekte: \(processIDs.count)")
            let numbers = processIDs.map { NSNumber(value: $0) }
            let allTap = CATapDescription(__monoMixdownOfProcesses: numbers)
            allTap.name = "AlfredHelp alle Prozesse"
            allTap.isPrivate = true
            allTap.muteBehavior = .unmuted
            if AudioHardwareCreateProcessTap(allTap, &processTapID) == noErr {
                let uid = (try? AudioObject.string(
                    processTapID, AudioObject.address(kAudioTapPropertyUID), operation: "uid"
                )) ?? allTap.uuid.uuidString
                processVariants = [
                    ("G  Mixdown ALLER Prozesse + Ausgabegerät",
                     aggregate(tapUID: uid, outputUID: outputUID, includeSubDevice: true, mainIsTap: false)),
                    ("H  Mixdown ALLER Prozesse allein",
                     aggregate(tapUID: uid, outputUID: nil, includeSubDevice: false, mainIsTap: true))
                ]
            }
        }
        defer {
            if processTapID != AudioObjectID(kAudioObjectUnknown) {
                AudioHardwareDestroyProcessTap(processTapID)
            }
        }

        print("\n" + String(repeating: "─", count: 74))
        print("Variante                                          Ein-Kanäle  läuft  Calls  Rahmen  Pegel")
        print(String(repeating: "─", count: 74))

        var anyWorked = false
        for (label, dictionary) in variants + deviceVariants + processVariants {
            let result = await measure(dictionary, expecting: format)
            let mark = result.frames > 0 ? "✓" : " "
            print(String(
                format: "%@ %-46@ %10d %6@ %6d %7d %6.3f",
                mark, label as NSString, result.inputChannels,
                (result.running ? "ja" : "nein") as NSString,
                result.callbacks, result.frames, result.peak
            ))
            if result.frames > 0 { anyWorked = true }
        }

        print(String(repeating: "═", count: 74))
        print(anyWorked
              ? "Mindestens eine Variante liefert echte Samples."
              : "Keine Variante liefert Samples.")
        return anyWorked ? 0 : 1
    }

    /// Listet alle Audiogeräte mit ihrem tatsächlichen Laufzustand auf.
    static func devices() -> Int32 {
        let defaultOutput = (try? AudioObject.defaultOutputDeviceID) ?? AudioObjectID(kAudioObjectUnknown)
        guard let bytes = try? AudioObject.rawValue(
            AudioObjectID(kAudioObjectSystemObject),
            AudioObject.address(kAudioHardwarePropertyDevices),
            operation: "device list"
        ) else {
            print("✗ Geräteliste nicht lesbar.")
            return 1
        }
        let ids = bytes.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: AudioObjectID.self))
        }
        print(String(format: "%-34@ %5@ %5@ %8@ %8@ %@",
                     "Gerät" as NSString, "aus" as NSString, "ein" as NSString,
                     "läuft" as NSString, "irgendwo" as NSString, "Standard" as NSString))
        for id in ids {
            let name = AudioObject.deviceName(id)
            let out = AudioObject.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            let inp = AudioObject.channelCount(id, scope: kAudioObjectPropertyScopeInput)
            func flag(_ selector: AudioObjectPropertySelector) -> String {
                let value: UInt32 = (try? AudioObject.value(
                    id, AudioObject.address(selector), defaultValue: UInt32(0), operation: "flag"
                )) ?? 0
                return value != 0 ? "ja" : "–"
            }
            print(String(format: "%-34@ %5d %5d %8@ %8@ %@",
                         name as NSString, out, inp,
                         flag(kAudioDevicePropertyDeviceIsRunning) as NSString,
                         flag(kAudioDevicePropertyDeviceIsRunningSomewhere) as NSString,
                         (id == defaultOutput ? "◀ Standardausgabe" : "") as NSString))
        }
        return 0
    }

    /// Zeitverlauf der echten `SystemAudioTap`-Klasse: zeigt halbsekündlich,
    /// was Aufsicht, Aggregat und Callback tatsächlich tun.
    static func watch(seconds: Int, renderSilence: Bool) async -> Int32 {
        let tap = SystemAudioTap()
        let counter = Counter()
        tap.onStatusChange = { message in print("      ↪ \(message)") }
        do {
            try tap.start { chunk in
                counter.add(frames: Int(chunk.buffer.frameLength), peak: chunk.peak)
            }
        } catch {
            print("✗ start: \(error.localizedDescription)")
            return 1
        }
        defer { tap.stop() }

        print("Zeit   Ausgabe  Aggregat  Aufbauten  Calls  Rahmen/s  Pegel")
        var previous = (frames: 0, callbacks: 0)
        for step in 1...(seconds * 2) {
            try? await Task.sleep(for: .milliseconds(500))
            let diagnostics = tap.diagnostics
            let snapshot = counter.snapshot()
            print(String(
                format: "%5.1fs  %7@  %8@  %9d %6d %9d  %.3f",
                Double(step) / 2,
                (diagnostics.outputEngineRunning ? "läuft" : "still") as NSString,
                (diagnostics.deviceIsRunning ? "läuft" : "still") as NSString,
                diagnostics.buildCount,
                diagnostics.callbacks - previous.callbacks,
                (snapshot.frames - previous.frames) * 2,
                snapshot.peak
            ))
            previous = (snapshot.frames, diagnostics.callbacks)
        }
        let final = counter.snapshot()
        print(final.frames > 0
              ? "\nErgebnis: \(final.frames) Rahmen, Spitzenpegel \(String(format: "%.3f", final.peak))"
              : "\nErgebnis: keine Rahmen")
        return final.frames > 0 ? 0 : 1
    }

    private static func silence(_ output: UnsafeMutablePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(output)
        for buffer in list {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }

    private static func aggregate(
        tapUID: String,
        outputUID: String?,
        includeSubDevice: Bool,
        mainIsTap: Bool
    ) -> [String: Any] {
        var dictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AlfredHelp Diagnose",
            kAudioAggregateDeviceUIDKey: "de.alfredhelp.diagnose.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
            ]
        ]
        if includeSubDevice, let outputUID {
            dictionary[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
            dictionary[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
        }
        if mainIsTap {
            dictionary[kAudioAggregateDeviceMainSubDeviceKey] = tapUID
        }
        return dictionary
    }

    private struct Result {
        var inputChannels = 0
        var running = false
        var callbacks = 0
        var frames = 0
        var peak: Float = 0
    }

    private static func measure(
        _ dictionary: [String: Any],
        expecting format: AVAudioFormat?
    ) async -> Result {
        var result = Result()
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregateID) == noErr,
              aggregateID != AudioObjectID(kAudioObjectUnknown) else { return result }
        defer { AudioHardwareDestroyAggregateDevice(aggregateID) }

        result.inputChannels = AudioObject.channelCount(
            aggregateID, scope: kAudioObjectPropertyScopeInput
        )

        let counter = Counter()
        var procID: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "de.alfredhelp.diagnose.io", qos: .userInitiated)
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            counter.record(input)
        }
        guard status == noErr, let procID else { return result }
        defer { AudioDeviceDestroyIOProcID(aggregateID, procID) }

        guard AudioDeviceStart(aggregateID, procID) == noErr else { return result }
        try? await Task.sleep(for: .seconds(2))

        result.running = (((try? AudioObject.value(
            aggregateID, AudioObject.address(kAudioDevicePropertyDeviceIsRunning),
            defaultValue: UInt32(0), operation: "running"
        )) ?? 0) != 0)

        let snapshot = counter.snapshot()
        result.callbacks = snapshot.callbacks
        result.frames = snapshot.frames
        result.peak = snapshot.peak

        AudioDeviceStop(aggregateID, procID)
        return result
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks = 0
    private var frames = 0
    private var peak: Float = 0

    func add(frames count: Int, peak value: Float) {
        lock.withLock {
            callbacks += 1
            frames += count
            peak = max(peak, value)
        }
    }

    func record(_ bufferList: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        var localFrames = 0
        var localPeak: Float = 0
        for buffer in list {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            localFrames += count / Int(buffer.mNumberChannels)
            for index in 0..<count {
                localPeak = max(localPeak, abs(samples[index]))
            }
        }
        lock.withLock {
            callbacks += 1
            frames += localFrames
            peak = max(peak, localPeak)
        }
    }

    func snapshot() -> (callbacks: Int, frames: Int, peak: Float) {
        lock.withLock { (callbacks, frames, peak) }
    }
}
