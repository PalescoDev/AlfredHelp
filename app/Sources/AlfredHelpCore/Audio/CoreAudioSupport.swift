import Foundation
import CoreAudio
import AudioToolbox

/// Thin, typed wrapper around the `AudioObjectGetPropertyData` family.
/// Everything else in the audio layer goes through this so the error handling
/// and the endless `UInt32` dances live in exactly one place.
public enum AudioObject {

    public struct Error: Swift.Error, CustomStringConvertible {
        public let status: OSStatus
        public let operation: String

        public var description: String {
            "\(operation) failed: \(Self.describe(status)) (\(status))"
        }

        public static func describe(_ status: OSStatus) -> String {
            switch status {
            case kAudioHardwareNoError: return "noErr"
            case kAudioHardwareNotRunningError: return "hardware not running"
            case kAudioHardwareUnspecifiedError: return "unspecified"
            case kAudioHardwareUnknownPropertyError: return "unknown property"
            case kAudioHardwareBadPropertySizeError: return "bad property size"
            case kAudioHardwareIllegalOperationError: return "illegal operation"
            case kAudioHardwareBadObjectError: return "bad object"
            case kAudioHardwareBadDeviceError: return "bad device"
            case kAudioHardwareBadStreamError: return "bad stream"
            case kAudioHardwareUnsupportedOperationError: return "unsupported operation"
            case kAudioDeviceUnsupportedFormatError: return "unsupported format"
            case kAudioDevicePermissionsError: return "permission denied"
            default:
                // Most Core Audio codes are four-character codes.
                let value = UInt32(bitPattern: status)
                let chars = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
                if chars.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
                    return "'" + String(decoding: chars, as: UTF8.self) + "'"
                }
                return "OSStatus \(status)"
            }
        }
    }

    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public static func dataSize(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        operation: String
    ) throws -> UInt32 {
        var addr = address
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
        guard status == noErr else { throw Error(status: status, operation: operation) }
        return size
    }

    /// Reads a fixed-layout property (numbers, structs, `CFTypeRef` handles).
    public static func value<T>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        defaultValue: T,
        operation: String
    ) throws -> T {
        var addr = address
        var result = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) { pointer in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw Error(status: status, operation: operation) }
        return result
    }

    /// Reads a variable-length property into raw bytes.
    public static func rawValue(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        operation: String
    ) throws -> [UInt8] {
        var addr = address
        var size = try dataSize(objectID, address, operation: operation + " (size)")
        guard size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(size))
        let status = buffer.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { throw Error(status: status, operation: operation) }
        return buffer
    }

    public static func setValue<T>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        value: T,
        operation: String
    ) throws {
        var addr = address
        var mutable = value
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &mutable) { pointer in
            AudioObjectSetPropertyData(objectID, &addr, 0, nil, size, pointer)
        }
        guard status == noErr else { throw Error(status: status, operation: operation) }
    }

    public static func string(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        operation: String
    ) throws -> String {
        let cf: CFString = try value(
            objectID, address, defaultValue: "" as CFString, operation: operation
        )
        return cf as String
    }

    // MARK: - Device helpers

    public static var defaultOutputDeviceID: AudioObjectID {
        get throws {
            try value(
                AudioObjectID(kAudioObjectSystemObject),
                address(kAudioHardwarePropertyDefaultOutputDevice),
                defaultValue: AudioObjectID(kAudioObjectUnknown),
                operation: "read default output device"
            )
        }
    }

    public static func deviceUID(_ deviceID: AudioObjectID) throws -> String {
        try string(deviceID, address(kAudioDevicePropertyDeviceUID), operation: "read device UID")
    }

    public static func deviceName(_ deviceID: AudioObjectID) -> String {
        (try? string(deviceID, address(kAudioObjectPropertyName), operation: "read device name"))
            ?? "Unbekanntes Gerät"
    }

    /// Nominal sample rate of a device, used to size the tap conversion buffers.
    public static func nominalSampleRate(_ deviceID: AudioObjectID) throws -> Double {
        try value(
            deviceID,
            address(kAudioDevicePropertyNominalSampleRate),
            defaultValue: Double(0),
            operation: "read nominal sample rate"
        )
    }

    /// Number of channels the device exposes on the given scope.
    public static func channelCount(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        let addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        guard let bytes = try? rawValue(deviceID, addr, operation: "read stream configuration"),
              !bytes.isEmpty else { return 0 }
        return bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            let list = UnsafeRawPointer(base).assumingMemoryBound(to: AudioBufferList.self)
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: list)
            )
            return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        }
    }
}

/// A registered property listener that removes itself on deinit.
final class AudioPropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private var block: AudioObjectPropertyListenerBlock?

    init(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) throws {
        self.objectID = objectID
        self.address = address
        self.queue = queue
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        self.block = block
        let status = AudioObjectAddPropertyListenerBlock(objectID, &self.address, queue, block)
        guard status == noErr else {
            self.block = nil
            throw AudioObject.Error(status: status, operation: "add property listener")
        }
    }

    deinit {
        guard let block else { return }
        var addr = address
        AudioObjectRemovePropertyListenerBlock(objectID, &addr, queue, block)
    }
}
