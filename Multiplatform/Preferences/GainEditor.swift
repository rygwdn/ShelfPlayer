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
                Button("action.reset", role: .destructive) {
                    Defaults.reset([.audioGain, .audioGainAdjustment])
                    Task {
                        await AudioPlayer.shared.setGain(Defaults[.audioGain])
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
