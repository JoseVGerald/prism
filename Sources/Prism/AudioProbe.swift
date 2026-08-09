import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreGraphics

/// Measures what the Mac is actually playing, so a crossfade can be checked for
/// a real loudness dip rather than trusted on the gain maths alone.
///
/// This lives inside Prism rather than in a separate helper on purpose: TCC
/// keys screen-recording approval to a binary's signature, so a standalone
/// probe lost its grant on every rebuild and could never be kept approved.
/// Prism is already in the Screen & System Audio Recording list.
///
/// Only runs under `PRISM_EVAL=1`, and only writes to `~/.prism-eval/rms.log`.
@MainActor
final class AudioProbe: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var squares: [Float] = []
    private var lastEmit = Date.distantPast
    private let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".prism-eval/rms.log")

    /// Starts capturing unless the debug console is off.
    func startIfEnabled() {
        guard ProcessInfo.processInfo.environment["PRISM_EVAL"] == "1" else { return }
        Task { await start() }
    }

    private func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                write("[AUDIO_DEBUG] no display"); return
            }

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // Audio is the point; the video side is kept as small and as slow
            // as the API allows.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false

            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                             configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .audio,
                                  sampleHandlerQueue: DispatchQueue(label: "prism.probe"))
            try await s.startCapture()
            stream = s
            write("[AUDIO_DEBUG] capture started")
        } catch {
            write("[AUDIO_DEBUG] failed: \(error.localizedDescription)")
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(buffer) else { return }

        var listSize = 0
        var block: CMBlockBuffer?
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard listSize > 0 else { return }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPtr = raw.assumingMemoryBound(to: AudioBufferList.self)

        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: listPtr,
            bufferListSize: listSize, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr
        else { return }

        var sum: Float = 0
        var count = 0
        for b in UnsafeMutableAudioBufferListPointer(listPtr) {
            guard let data = b.mData else { continue }
            let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<n { sum += samples[i] * samples[i] }
            count += n
        }
        guard count > 0 else { return }
        let mean = sum / Float(count)
        Task { @MainActor in self.accumulate(mean) }
    }

    private func accumulate(_ meanSquare: Float) {
        squares.append(meanSquare)
        // Ten lines a second is enough to see a dip and few enough to read.
        guard Date().timeIntervalSince(lastEmit) > 0.1 else { return }
        lastEmit = Date()
        let mean = squares.reduce(0, +) / Float(squares.count)
        squares.removeAll(keepingCapacity: true)
        let rms = sqrt(mean)
        let db = 20 * log10(max(rms, 0.00001))
        write(String(format: "[AUDIO_DEBUG] RMS: %.5f | dB: %.1f", rms, db))
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        write("[AUDIO_DEBUG] stopped: \(error.localizedDescription)")
    }

    private nonisolated func write(_ line: String) {
        let stamped = String(format: "%.2f %@\n", Date().timeIntervalSince1970, line)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(stamped.utf8)); try? h.close()
        } else {
            try? stamped.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
