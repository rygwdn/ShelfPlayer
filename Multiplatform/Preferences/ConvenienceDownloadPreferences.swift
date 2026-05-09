//
//  ConvenienceDownloadPreferences.swift
//  Multiplatform
//
//  Created by Rasmus Krämer on 09.05.25.
//

import SwiftUI
import ShelfPlayback

struct ConvenienceDownloadPreferences: View {
    @Default(.enableConvenienceDownloads) private var enableConvenienceDownloads
    @Default(.enableListenNowDownloads) private var enableListenNowDownloads

    @Default(.enablePlaybackTriggeredDownloads) private var enablePlaybackTriggeredDownloads
    @Default(.playbackDownloadTriggerDuration) private var playbackDownloadTriggerDuration
    @Default(.playbackDownloadNearEndThreshold) private var playbackDownloadNearEndThreshold

    @State private var totalDownloaded = 0

    @State private var configurations = [PersistenceManager.ConvenienceDownloadSubsystem.ConvenienceDownloadConfiguration]()
    @State private var loading = [ItemIdentifier: Bool]()

    @State private var notifyError = false

    var body: some View {
        List {
            Toggle("preferences.convenienceDownload.enable", isOn: $enableConvenienceDownloads)
            Toggle("preferences.convenienceDownload.enableListenNowDownloads", isOn: $enableListenNowDownloads)

            Section {
                Toggle("preferences.playbackTriggeredDownload.enable", isOn: $enablePlaybackTriggeredDownloads)

                if enablePlaybackTriggeredDownloads {
                    Picker("preferences.playbackTriggeredDownload.triggerDuration", selection: $playbackDownloadTriggerDuration) {
                        Text("preferences.playbackTriggeredDownload.triggerDuration.30s").tag(30)
                        Text("preferences.playbackTriggeredDownload.triggerDuration.1m").tag(60)
                        Text("preferences.playbackTriggeredDownload.triggerDuration.2m").tag(120)
                        Text("preferences.playbackTriggeredDownload.triggerDuration.5m").tag(300)
                    }

                    Picker("preferences.playbackTriggeredDownload.nearEnd", selection: $playbackDownloadNearEndThreshold) {
                        Text("preferences.playbackTriggeredDownload.nearEnd.disabled").tag(0)
                        Text("preferences.playbackTriggeredDownload.nearEnd.5m").tag(300)
                        Text("preferences.playbackTriggeredDownload.nearEnd.10m").tag(600)
                        Text("preferences.playbackTriggeredDownload.nearEnd.15m").tag(900)
                        Text("preferences.playbackTriggeredDownload.nearEnd.30m").tag(1800)
                    }
                }
            } header: {
                Text("preferences.playbackTriggeredDownload")
            } footer: {
                Text("preferences.playbackTriggeredDownload.footer")
            }

            Section("preferences.convenienceDownload.configurations") {
                ForEach(configurations) { configuration in
                    switch configuration {
                        case .listenNow:
                            EmptyView()
                        case .playbackTriggered:
                            EmptyView()
                        case .grouping(let itemID, let retrieval):
                            if loading[itemID] == true {
                                ProgressView()
                            } else if let parsed = ConvenienceDownloadRetrievalOption.parse(retrieval) {
                                GroupingConfigurationSheet.ConvenienceDownloadRetrievalPicker(itemType: itemID.type, retrieval: .init() { parsed } set: { updateConfiguration(itemID: itemID, retrieval: $0.resolved) }) {
                                    ItemCompactRow(itemID: itemID, context: .convenienceDownloadPreferences)
                                }
                                .listRowInsets(.init(top: 12, leading: 12, bottom: 12, trailing: 12))
                            }
                    }
                }
                .onDelete {
                    for index in $0 {
                        guard let itemID = PersistenceManager.shared.convenienceDownload.resolveItemID(from: configurations[index].id) else {
                            continue
                        }

                        removeConfiguration(itemID: itemID)
                    }
                }
            }

            if totalDownloaded > 0 {
                Text("preferences.convenienceDownload.downloadedTotal \(totalDownloaded)")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("preferences.convenienceDownload")
        .hapticFeedback(.error, trigger: notifyError)
        .task {
            loadConfigurations()
        }
        .refreshable {
            loadConfigurations()
        }
        .onReceive(RFNotification[.convenienceDownloadConfigurationsChanged].publisher()) {
            loadConfigurations()
        }
    }

    private func removeConfiguration(itemID: ItemIdentifier) {
        Task {
            loading[itemID] = true

            do {
                try await PersistenceManager.shared.convenienceDownload.setRetrieval(for: itemID, retrieval: nil)
            } catch {
                notifyError.toggle()
            }

            loading[itemID] = false
        }
    }
    private func updateConfiguration(itemID: ItemIdentifier, retrieval: PersistenceManager.ConvenienceDownloadSubsystem.GroupingRetrieval?) {
        Task {
            loading[itemID] = true

            do {
                try await PersistenceManager.shared.convenienceDownload.setRetrieval(for: itemID, retrieval: retrieval)
            } catch {
                notifyError.toggle()
            }

            loading[itemID] = false
        }
    }

    private func loadConfigurations() {
        Task {
            configurations = await PersistenceManager.shared.convenienceDownload.activeConfigurations.sorted {
                $0.id < $1.id
            }
            totalDownloaded = await PersistenceManager.shared.convenienceDownload.totalDownloadCount
        }
    }
}

#Preview {
    ConvenienceDownloadPreferences()
}
