// t_50da3b54: capture-start proof — post-fix. Compiles the REAL
// AudioCapture/InputDeviceResolver and starts a capture session on the
// live C920. Pre-fix this throws com.apple.coreaudio.avfaudio at
// installTap (format 16k vs live 48k) — the silent no-op the owner hit.
import AVFoundation
import Foundation

let capture = AudioCapture()
var nChunks = 0; var peak: Double = 0
capture.onChunk = { wav, secs, _ in nChunks += 1; print("chunk \(wav.count)B \(secs)s") }
capture.onLevel = { lvl in peak = max(peak, lvl) }
do {
    try capture.start()
} catch {
    print("CAPTURE_START_FAILED: \(error)")
    exit(1)
}
print("PASS: capture live, device=\(capture.activeDevice?.name ?? "?")")
RunLoop.main.run(until: Date().addingTimeInterval(3.0))
capture.flushTail()
let secs = capture.stop()
print("stopped secs=\(secs) chunks=\(nChunks) peakLevel=\(peak)")
exit(0)
