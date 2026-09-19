// Headless capture->STT->polish proof (t_49e2302f run 30).
// Compiles the REAL AudioCapture.swift (with macOS-27 fix from t_220b8507)
// and streams live mic audio to the sidecar, then polishes.
// Run: captures ~4s of live audio; on a silent room STT may return empty —
// that still proves capture->wire->STT path. Prints JSON lines.
import AVFoundation
import Foundation

let capture = AudioCapture()
var chunks: [Data] = []
let group = DispatchGroup()
capture.onChunk = { wav, secs in
    print("chunk wav=\(wav.count)B secs=\(String(format: "%.2f", secs))")
    chunks.append(wav)
}
do {
    try capture.start()
} catch {
    print("CAPTURE_START_FAILED: \(error)")
    exit(1)
}
print("capture live: \(capture.isCapturing)")
Thread.sleep(forTimeInterval: 4.0)
capture.flushTail()
let secs = capture.stop()
print("capture stopped secs=\(String(format: "%.2f", secs)) chunks=\(chunks.count)")

// Concatenate chunk PCM into one WAV for the proof POST
var pcm = Data()
for wav in chunks { pcm.append(wav.dropFirst(44)) } // strip RIFF headers
let full = WavWriter.wav(int16LE: pcm, sampleRate: 16000)
print("full wav bytes=\(full.count)")

func post(_ path: String, body: Data, boundary: String? = nil) -> String {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:8790\(path)")!)
    req.httpMethod = "POST"
    req.timeoutInterval = 30
    if let b = boundary {
        req.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type")
    }
    req.httpBody = body
    let sem = DispatchSemaphore(value: 0)
    var out = ""
    URLSession.shared.dataTask(with: req) { d, _, e in
        out = e != nil ? "ERR:\(e!.localizedDescription)" : (String(data: d ?? Data(), encoding: .utf8) ?? "")
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 35)
    return out
}

// multipart for /transcribe
let b = "----qsproof"
var mp = Data()
mp.append("--\(b)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"p.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
mp.append(full)
mp.append("\r\n--\(b)--\r\n".utf8)
let t0 = Date()
let tr = post("/transcribe", body: mp, boundary: b)
let msSTT = Int(Date().timeIntervalSince(t0) * 1000)
print("STT ms=\(msSTT) resp=\(tr)")

// extract text from json (crude)
var rawText = ""
if let r = tr.range(of: "\"text\":\""), let e = tr.range(of: "\"", range: r.upperBound..<tr.endIndex) {
    rawText = String(tr[r.upperBound..<e.lowerBound])
}
print("raw_text=\(rawText)")
if !rawText.isEmpty {
    var pj = "{\"text\":\"\(rawText)\",\"profile\":\"polish\"}".data(using: .utf8)!
    var req = URLRequest(url: URL(string: "http://127.0.0.1:8790/polish")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = pj
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { d, _, e in
        let t1 = Date()
        print("POLISH resp=\(String(data: d ?? Data(), encoding: .utf8) ?? "ERR:\(e?.localizedDescription ?? "?")")")
        _ = t1
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 35)
}
print("PROOF_DONE")
exit(0)
