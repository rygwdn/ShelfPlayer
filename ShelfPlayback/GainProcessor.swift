//
//  GainProcessor.swift
//  ShelfPlayback
//
//  Created by Rasmus Krämer on 20.04.25.
//

import AVFoundation
import Accelerate
import MediaToolbox

// Heap-allocated container shared between LocalAudioEndpoint and all active audio taps.
// Float reads/writes on ARM are word-atomic; no lock needed for the single-writer / many-reader pattern.
final class GainContext {
    var gain: Float
    init(gain: Float) { self.gain = gain }
}

// Creates an AVMutableAudioMix whose tap multiplies every audio sample by context.gain.
// Uses passUnretained — the GainContext is kept alive by LocalAudioEndpoint for the full
// lifetime of the tap (items are removed before the endpoint is deallocated).
func makeGainAudioMix(for item: AVPlayerItem, context: GainContext) async -> AVMutableAudioMix? {
    guard let tracks = try? await item.asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
        return nil
    }

    let clientInfo = Unmanaged.passUnretained(context).toOpaque()

    var callbacks = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0,
        clientInfo: clientInfo,
        `init`: { _, clientInfo, tapStorageOut in
            tapStorageOut?.pointee = clientInfo
        },
        finalize: { _ in },
        prepare: nil,
        unprepare: nil,
        process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
            MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)

            let ctx = Unmanaged<GainContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            let g = ctx.gain
            guard g != 1.0 else { return }

            let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
            for buf in buffers {
                guard let data = buf.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let count = vDSP_Length(Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
                withUnsafePointer(to: g) { vDSP_vsmul(samples, 1, $0, samples, 1, count) }
            }
        }
    )

    var tap: Unmanaged<MTAudioProcessingTap>?
    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
    guard status == noErr, let tap else { return nil }

    let mix = AVMutableAudioMix()
    mix.inputParameters = tracks.map { track in
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap.takeRetainedValue()
        return params
    }
    return mix
}
