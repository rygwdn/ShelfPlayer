//
//  GainEditor.swift
//  ShelfPlayer
//
//  Created by Rasmus Krämer on 20.04.25.
//

import SwiftUI
import ShelfPlayerKit
import ShelfPlayback

struct GainEditor: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        List {
            Section {
                Stepper(value: $settings.audioGain, in: 0.25...2.0, step: settings.audioGainAdjustment) {
                    Text(settings.audioGain, format: .percent.precision(.fractionLength(0)))
                }
                .onChange(of: settings.audioGain) { _, newValue in
                    Task {
                        await AudioPlayer.shared.setGain(newValue)
                    }
                }
            } footer: {
                Text("preferences.gain.footer")
            }

            Section {
                Stepper(value: $settings.audioGainAdjustment, in: 0.01...0.25, step: 0.01) {
                    Text("preferences.gain.adjustment \(settings.audioGainAdjustment.formatted(.percent.precision(.fractionLength(0))))")
                }
            }

            Section {
                Stepper(value: $settings.audioVocalBoost, in: 0.0...12.0, step: settings.audioVocalBoostAdjustment) {
                    if settings.audioVocalBoost == 0 {
                        Text("playback.vocalBoost.off")
                    } else {
                        Text("+\(Int(settings.audioVocalBoost)) dB")
                    }
                }
                .onChange(of: settings.audioVocalBoost) { _, newValue in
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
                Stepper(value: $settings.audioVocalBoostAdjustment, in: 0.5...3.0, step: 0.5) {
                    Text("preferences.gain.adjustment \(Int(settings.audioVocalBoostAdjustment)) dB")
                }
            }

            Section {
                Button("action.reset", role: .destructive) {
                    settings.audioGain = 1.0
                    settings.audioGainAdjustment = 0.05
                    settings.audioVocalBoost = 0.0
                    settings.audioVocalBoostAdjustment = 1.0
                    Task {
                        await AudioPlayer.shared.setGain(settings.audioGain)
                        await AudioPlayer.shared.setVocalBoost(settings.audioVocalBoost)
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
