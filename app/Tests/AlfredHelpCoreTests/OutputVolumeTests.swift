import Testing
@testable import AlfredHelpCore

/// Ein stummer Ausgang sieht in der Aufnahme aus wie eine entzogene Freigabe.
/// Diese Tests halten fest, wann AlfredHelp welche der beiden Ursachen nennt.
struct OutputVolumeTests {

    private func state(volume: Float?, muted: Bool) -> OutputVolume.State {
        OutputVolume.State(deviceName: "USB AUDIO", volume: volume, isMuted: muted)
    }

    @Test func stummGeschaltetGiltAlsStumm() {
        let s = state(volume: 0.8, muted: true)
        #expect(s.isSilenced)
        #expect(s.explanation?.contains("stummgeschaltet") == true)
    }

    @Test func lautstaerkeNullGiltAlsStumm() {
        let s = state(volume: 0, muted: false)
        #expect(s.isSilenced)
        #expect(s.explanation?.contains("null") == true)
    }

    @Test func hoerbareLautstaerkeErklaertNichts() {
        let s = state(volume: 0.4, muted: false)
        #expect(!s.isSilenced)
        #expect(s.explanation == nil)
    }

    /// Der Gerätewert ist nicht linear zum Systemregler: 40 % am Regler ergaben
    /// gemessen 0,06. Solche Werte dürfen nicht als stumm durchgehen, sonst
    /// verdeckt der Hinweis eine echte fehlende Freigabe.
    @Test func leiseAberHoerbarGiltNichtAlsStumm() {
        #expect(!state(volume: 0.06, muted: false).isSilenced)
        #expect(!state(volume: 0.01, muted: false).isSilenced)
        #expect(!state(volume: 0.002, muted: false).isSilenced)
    }

    /// Geräte ohne Softwareregler (viele USB-DACs) dürfen nicht fälschlich als
    /// stumm gelten.
    @Test func fehlenderReglerGiltNichtAlsStumm() {
        let s = state(volume: nil, muted: false)
        #expect(!s.isSilenced)
        #expect(s.explanation == nil)
    }

    @Test func fehlenderReglerAberStummGiltAlsStumm() {
        #expect(state(volume: nil, muted: true).isSilenced)
    }

    /// Das Gerät liest sich ohne Absturz aus, egal was gerade angeschlossen ist.
    @Test func aktuellerZustandIstLesbar() {
        #expect(!OutputVolume.current.deviceName.isEmpty)
    }
}
