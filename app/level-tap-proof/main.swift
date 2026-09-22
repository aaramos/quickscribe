// Headless level-tap proof (t_3db202e7): compiles the REAL
// AudioCapture.swift + InputDeviceResolver.swift + AppInfo.swift and
// verifies the WF1 level tap emits NON-FLAT values from the real default
// mic (webcam mic on this host). Prints JSON-ish lines; exit 0 only if
// levels are non-flat (variance > 0 across samples).
import AVFoundation
import Foundation

let capture = AudioCapture()
var levels: [Double] = []
capture.onLevel = { lvl in
    DispatchQueue.main.sync { levels.append(lvl) }
}
do {
    try capture.start()
} catch {
    print("CAPTURE_START_FAILED: \(error)")
    exit(1)
}
print("capture live: \(capture.isCapturing)")
// Room-tone proof: sample for 3s. The tap itself proves the wire; variance
// across samples proves the values are REAL audio, not a constant.
Thread.sleep(forTimeInterval: 3.0)
let secs = capture.stop()

guard !levels.isEmpty else {
    print("FAIL: level tap emitted 0 samples")
    exit(1)
}
let mn = levels.min()!, mx = levels.max()!
let mean = levels.reduce(0, +) / Double(levels.count)
let varr = levels.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(levels.count)
let nz = levels.filter { $0 > 0.001 }.count
print("level samples=\(levels.count) min=\(String(format: "%.4f", mn)) max=\(String(format: "%.4f", mx)) mean=\(String(format: "%.4f", mean)) var=\(String(format: "%.6f", varr)) nonzero=\(nz) peak_tap=\(String(format: "%.4f", capture.peakLevel))")
print("capture stopped secs=\(String(format: "%.2f", secs))")
if mx - mn < 0.005 {
    print("FAIL: waveform FLAT (spread \(String(format: "%.4f", mx - mn)) < 0.005)")
    exit(1)
}
print("PASS: level tap non-flat — \(nz) non-zero of \(levels.count), spread \(String(format: "%.4f", mx - mn))")
