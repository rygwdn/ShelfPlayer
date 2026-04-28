//
//  GainEditor.swift
//  Multiplatform
//
//  Created by Rasmus Krämer on 20.04.25.
//

import SwiftUI
import ShelfPlayback

struct GainEditor: View {
    @Default(.audioGain) private var audioGain
    @Default(.audioGainAdjustment) private var audioGainAdjustment

    @Default(.audioVocalBoost) private var audioVocalBoost
    @Default(.audioVocalBoostAdjustment) private var audioVocalBoostAdjustment

    var body: some View {
        List {
            Section {
                Stepper(value: $audioGain, in: 0.25...2.0, step: audioGainAdjustment) {
                    Text(audioGain, format: .percent.precision(.fractionLength(0)))
                }
                .onChange(of: audioGain) { _, newValue in
                    Task {
                        await AudioPlayer.shared.setGain(newValue)
                    }
                }
            } footer: {
                Text("preferences.gain.footer")
            }

            Section {
                Stepper(value: $audioGainAdjustment, in: 0.01...0.25, step: 0.01) {
                    Text("preferences.gain.adjustment \(audioGainAdjustment.formatted(.percent.precision(.fractionLength(0))))")
                }
            }

            Section {
                Stepper(value: $audioVocalBoost, in: 0.0...12.0, step: audioVocalBoostAdjustment) {
                    if audioVocalBoost == 0 {
                        Text("playback.vocalBoost.off")
                    } else {
                        Text("+\(Int(audioVocalBoost)) dB")
                    }
                }
                .onChange(of: audioVocalBoost) { _, newValue in
                    Task {
                        await AudioPlayer.shared.setVocalBoost(newValue)
                    }
                }
            } header: {
                Text("preferences.vocalBoost")
            } footer: {
                Text("preferences.vocalBoost.footer")
            }

            Section {
                Stepper(value: $audioVocalBoostAdjustment, in: 0.5...3.0, step: 0.5) {
                    Text("preferences.gain.adjustment \(Int(audioVocalBoostAdjustment)) dB")
                }
            }

            Section {
                Button("action.reset", role: .destructive) {
                    Defaults.reset([.audioGain, .audioGainAdjustment, .audioVocalBoost, .audioVocalBoostAdjustment])
                    Task {
                        await AudioPlayer.shared.setGain(Defaults[.audioGain])
                        await AudioPlayer.shared.setVocalBoost(Defaults[.audioVocalBoost])
                    }
                }
            }
        }
        .navigationTitle("preferences.gain")
    }
}

#Preview {
    GainEditor()
}
