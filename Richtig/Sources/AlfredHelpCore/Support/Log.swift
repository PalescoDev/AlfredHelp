import Foundation
import os

/// Central logging. Everything stays on-device; the log never contains
/// transcript text at default level.
public enum Log {
    private static let subsystem = "io.github.PalescoDev.alfredhelp"

    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let speech = Logger(subsystem: subsystem, category: "speech")
    public static let ollama = Logger(subsystem: subsystem, category: "ollama")
    public static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}

/// A monotonic timestamp source used for the latency measurements the UI shows.
public enum Clock {
    public static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public static func millis(since start: Double) -> Int {
        Int(((now() - start) * 1000).rounded())
    }
}
