import AVFoundation
import XCTest
@testable import QuickScribe
@testable import QuickScribeCore

/// The whole-recording buffer: WAV bytes, the length limit, and clearing on
/// every path. Words and audio must never reach disk here.
final class RecordingBufferTests: XCTestCase {
    private func buffer(_ samples: [Float], sampleRate: Double = 16_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBytes { raw in
            memcpy(b.floatChannelData![0], raw.baseAddress!, raw.count)
        }
        return b
    }

    func testEmptyRecordingIsBareHeader() {
        let (data, overflowed) = RecordingBuffer().wav()
        XCTAssertFalse(overflowed)
        XCTAssertEqual(data.count, 44)
    }

    func testWavHeaderIsSixteenKMonoSixteenBit() {
        let rec = RecordingBuffer()
        rec.append(buffer([0.5, -0.25, 1.0, -1.0]))
        let (data, overflowed) = rec.wav()
        XCTAssertFalse(overflowed)
        let b = [UInt8](data)
        func str(_ from: Int, _ len: Int) -> String {
            String(decoding: b[from..<from + len], as: UTF8.self)
        }
        func u32(_ at: Int) -> UInt32 {
            UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
        }
        func u16(_ at: Int) -> UInt16 {
            UInt16(b[at]) | UInt16(b[at + 1]) << 8
        }
        XCTAssertEqual(str(0, 4), "RIFF")
        XCTAssertEqual(str(8, 4), "WAVE")
        XCTAssertEqual(str(12, 4), "fmt ")
        XCTAssertEqual(u32(16), 16, "fmt chunk size")
        XCTAssertEqual(u16(20), 1, "PCM")
        XCTAssertEqual(u16(22), 1, "mono")
        XCTAssertEqual(u32(24), 16_000, "sample rate")
        XCTAssertEqual(u32(28), 32_000, "byte rate")
        XCTAssertEqual(u16(32), 2, "block align")
        XCTAssertEqual(u16(34), 16, "bits")
        XCTAssertEqual(str(36, 4), "data")
        XCTAssertEqual(u32(40), 8, "four samples of two bytes")
        XCTAssertEqual(u32(4), 36 + 8, "RIFF length")
        XCTAssertEqual(data.count, 44 + 8)
    }

    func testSamplesAreClampedLittleEndianInt16() {
        let rec = RecordingBuffer()
        rec.append(buffer([0.5, -0.5, 2.0, -2.0, 0]))
        let (data, _) = rec.wav()
        let b = [UInt8](data)
        func i16(_ at: Int) -> Int16 {
            Int16(bitPattern: UInt16(b[at]) | UInt16(b[at + 1]) << 8)
        }
        XCTAssertEqual(i16(44), 16_383)
        XCTAssertEqual(i16(46), -16_384)
        XCTAssertEqual(i16(48), 32_767, "over-limit clamps, never wraps")
        XCTAssertEqual(i16(50), (-32_768))
        XCTAssertEqual(i16(52), 0)
    }

    func testFourtyEightKiloStereoBecomesSixteenKiloMono() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!   // 0.1 s
        b.frameLength = 4_800
        let rec = RecordingBuffer()
        rec.append(b)
        let (data, _) = rec.wav()
        let seconds = (Double(data.count) - 44) / 2 / 16_000
        XCTAssertEqual(seconds, 0.1, accuracy: 0.02, "resampled length, converter padding aside")
    }

    func testLengthLimitIsReachedNotSilent() {
        let rec = RecordingBuffer()
        rec.maxSeconds = 0.1          // 1600 samples
        rec.append(buffer([Float](repeating: 0, count: 1_000)))
        rec.append(buffer([Float](repeating: 0, count: 1_000)))   // crosses the limit
        rec.append(buffer([Float](repeating: 0, count: 1_000)))   // past it entirely
        let (data, overflowed) = rec.wav()
        XCTAssertTrue(overflowed, "the person must be told the clip was cut")
        XCTAssertEqual(data.count, 44 + 2 * 1_600, "exactly the limited clip, no silent extra words")
    }

    func testClearFreesTheAudio() {
        let rec = RecordingBuffer()
        rec.append(buffer([0.1, 0.2, 0.3]))
        _ = rec.wav()
        rec.clear()
        let (data, overflowed) = rec.wav()
        XCTAssertEqual(data.count, 44, "cleared: no bytes left")
        XCTAssertFalse(overflowed)
    }

    func testDiscardIgnoresInFlightAppends() {
        let rec = RecordingBuffer()
        rec.append(buffer([Float](repeating: 0.1, count: 100)))
        rec.discard()
        rec.append(buffer([Float](repeating: 0.1, count: 100)))   // already on its way
        let (data, _) = rec.wav()
        XCTAssertEqual(data.count, 44, "a discarded recording stays empty, no stray audio")
        XCTAssertEqual(rec.seconds, 0)
    }

    func testSecondsTracksResampledLength() {
        let rec = RecordingBuffer()
        rec.append(buffer([Float](repeating: 0, count: 8_000)))    // 0.5 s at 16k
        XCTAssertEqual(rec.seconds, 0.5, accuracy: 0.01)
    }
}

@MainActor
final class SpeechRouteTests: XCTestCase {
    func testAppleIsTheDefaultRoute() {
        XCTAssertEqual(SessionController.speechRoute(customChosen: false, overflowed: false, silent: false, hasClip: true),
                       .appleOnly(""))
    }

    func testCustomSpeechSendsTheWholeClip() {
        XCTAssertEqual(SessionController.speechRoute(customChosen: true, overflowed: false, silent: false, hasClip: true),
                       .customService)
    }

    /// The limit must be spoken, never dropped quietly, and Apple covers.
    func testOverflowFallsBackToAppleWithAMessage() {
        let route = SessionController.speechRoute(customChosen: true, overflowed: true, silent: false, hasClip: true)
        guard case .appleOnly(let why) = route, !why.isEmpty else { return XCTFail("\(route)") }
        XCTAssertTrue(why.contains("limit"), why)
        XCTAssertFalse(why.contains("\u{2014}"), "no em dashes on screen")
    }

    /// A fully silent session never uploads audio.
    func testSilenceNeverUploads() {
        XCTAssertEqual(SessionController.speechRoute(customChosen: true, overflowed: false, silent: true, hasClip: true),
                       .appleOnly(""))
    }

    func testEmptyClipFallsBackWithAMessage() {
        let route = SessionController.speechRoute(customChosen: true, overflowed: false, silent: false, hasClip: false)
        guard case .appleOnly(let why) = route, !why.isEmpty else { return XCTFail("\(route)") }
    }
}
