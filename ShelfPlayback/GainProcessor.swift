//
//  GainProcessor.swift
//  ShelfPlayback
//
//  Created by Rasmus Krämer on 20.04.25.
//

import AVFoundation
import Accelerate
import MediaToolbox

// MARK: - Biquad filter coefficients (normalized, direct form II transposed)

struct BiquadCoefficients {
    var b0, b1, b2, a1, a2: Float

    static let passthrough = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    // Peaking EQ filter per the Audio EQ Cookbook (R. Bristow-Johnson).
    // dbGain > 0 boosts, < 0 cuts. Returns .passthrough when dbGain == 0.
    static func peakingEQ(frequency: Float, sampleRate: Float, Q: Float, dbGain: Float) -> BiquadCoefficients {
        guard dbGain != 0 else { return .passthrough }
        let A = pow(10.0, dbGain / 40.0)
        let w0 = 2.0 * Float.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2.0 * Q)
        let a0 = 1.0 + alpha / A
        return BiquadCoefficients(
            b0: (1.0 + alpha * A) / a0,
            b1: (-2.0 * cosW0) / a0,
            b2: (1.0 - alpha * A) / a0,
            a1: (-2.0 * cosW0) / a0,
            a2: (1.0 - alpha / A) / a0
        )
    }
}

// MARK: - Shared parameter context (main-thread writes, real-time thread reads)

// Owned by LocalAudioEndpoint. All taps hold a strong reference via TapState.
final class AudioProcessingContext: @unchecked Sendable {
    var gain: Float
    var vocalBoost: Float               // dB; 0 = off
    var sampleRate: Float               // set from the first prepare callback
    var vocalBoostCoefficients: BiquadCoefficients

    init(gain: Float, vocalBoost: Float) {
        self.gain = gain
        self.vocalBoost = vocalBoost
        self.sampleRate = 44100
        self.vocalBoostCoefficients = .passthrough
    }

    // Call on the main thread after changing vocalBoost or when sampleRate is first known.
    // Not thread-safe vs. the process callback; the worst result is a brief click during transition.
    func updateVocalBoostCoefficients() {
        // Vocal presence range: centre 2500 Hz, Q 1.0 covers roughly 1 kHz – 6 kHz.
        vocalBoostCoefficients = .peakingEQ(
            frequency: 2500,
            sampleRate: sampleRate,
            Q: 1.0,
            dbGain: vocalBoost
        )
    }
}

// MARK: - Per-tap state (one instance per audio track per AVPlayerItem)

// Allocated in the tap init callback, released in finalize.
// Carries a strong reference to the shared AudioProcessingContext and owns the
// per-channel biquad history allocated in the prepare callback.
final class TapState {
    let context: AudioProcessingContext
    var channelCount: Int = 0
    var channelStates: UnsafeMutableBufferPointer<(w1: Float, w2: Float)>?

    init(context: AudioProcessingContext) {
        self.context = context
    }

    deinit {
        channelStates?.deallocate()
    }

    // Called from the (non-RT) prepare callback.
    func prepare(channelCount: Int, sampleRate: Float) {
        channelStates?.deallocate()
        let buf = UnsafeMutableBufferPointer<(w1: Float, w2: Float)>.allocate(capacity: channelCount)
        buf.initialize(repeating: (w1: 0, w2: 0))
        channelStates = buf
        self.channelCount = channelCount
        context.sampleRate = sampleRate
        context.updateVocalBoostCoefficients()
    }

    // Called from the (non-RT) unprepare callback.
    func unprepare() {
        channelStates?.deallocate()
        channelStates = nil
        channelCount = 0
    }
}

// MARK: - Tap factory

// Creates an AVMutableAudioMix that applies overall gain and a peaking vocal-boost EQ to every
// audio sample. The AudioProcessingContext is shared; updating its properties takes effect within
// the next audio callback cycle (~23 ms) without recreating any taps.
@MainActor
func makeAudioMix(for item: AVPlayerItem, context: AudioProcessingContext) async -> AVMutableAudioMix? {
    guard let tracks = try? await item.asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
        return nil
    }

    let clientInfo = Unmanaged.passUnretained(context).toOpaque()

    var callbacks = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0,
        clientInfo: clientInfo,
        init: { _, clientInfo, tapStorageOut in
            let ctx = Unmanaged<AudioProcessingContext>.fromOpaque(clientInfo!).takeUnretainedValue()
            let state = TapState(context: ctx)
            tapStorageOut.pointee = Unmanaged.passRetained(state).toOpaque()
        },
        finalize: { tap in
            Unmanaged<TapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
        },
        prepare: { tap, _, processingFormat in
            let state = Unmanaged<TapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            let desc = processingFormat.pointee
            state.prepare(channelCount: Int(desc.mChannelsPerFrame), sampleRate: Float(desc.mSampleRate))
        },
        unprepare: { tap in
            Unmanaged<TapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().unprepare()
        },
        process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
            MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)

            let state = Unmanaged<TapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            let ctx = state.context
            let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)

            // Overall gain (scalar multiply via Accelerate)
            let g = ctx.gain
            if g != 1.0 {
                for buf in buffers {
                    guard let data = buf.mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let count = vDSP_Length(Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
                    withUnsafePointer(to: g) { vDSP_vsmul(samples, 1, $0, samples, 1, count) }
                }
            }

            // Vocal boost: peaking EQ applied per channel (direct form II transposed biquad)
            guard ctx.vocalBoost != 0, let channelStates = state.channelStates else { return }
            let coeff = ctx.vocalBoostCoefficients
            let (b0, b1, b2, a1, a2) = (coeff.b0, coeff.b1, coeff.b2, coeff.a1, coeff.a2)

            for (channelIndex, buf) in buffers.enumerated() {
                guard channelIndex < state.channelCount, let data = buf.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                var (w1, w2) = channelStates[channelIndex]
                for i in 0..<count {
                    let x = samples[i]
                    let y = b0 * x + w1
                    w1 = b1 * x - a1 * y + w2
                    w2 = b2 * x - a2 * y
                    samples[i] = y
                }
                channelStates[channelIndex] = (w1, w2)
            }
        }
    )

    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
    guard status == noErr, let tap else { return nil }

    let mix = AVMutableAudioMix()
    mix.inputParameters = tracks.map { track in
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        return params
    }
    return mix
}
