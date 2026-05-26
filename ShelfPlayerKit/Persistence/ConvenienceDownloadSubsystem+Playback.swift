//
//  ConvenienceDownloadSubsystem+Playback.swift
//  ShelfPlayerKit
//

import Foundation
import OSLog

extension PersistenceManager.ConvenienceDownloadSubsystem {
    func onPlaybackItemChanged(itemID: ItemIdentifier) async {
        playbackCurrentItemID = itemID
        playbackDuration = nil
        playbackAccumulatedListeningTime = 0
        playbackListenStartDate = nil
        playbackHasTriggeredCurrentDownload = false
        playbackHasTriggeredNextDownload = false
    }

    func onQueueChanged(queueIDs: [ItemIdentifier]) async {
        playbackQueueIDs = queueIDs
    }

    func onUpNextQueueChanged(upNextIDs: [ItemIdentifier]) async {
        playbackUpNextIDs = upNextIDs
    }

    func onPlayStateChanged(isPlaying: Bool) async {
        if isPlaying {
            playbackListenStartDate = .now
        } else if let start = playbackListenStartDate {
            playbackAccumulatedListeningTime += Date().timeIntervalSince(start)
            playbackListenStartDate = nil
        }
    }

    func onDurationsChanged(itemDuration: TimeInterval?) async {
        playbackDuration = itemDuration
    }

    func onCurrentTimesChanged(itemCurrentTime: TimeInterval?) async {
        guard AppSettings.shared.enablePlaybackTriggeredDownloads,
              let currentTime = itemCurrentTime,
              let duration = playbackDuration,
              duration > 0 else { return }

        var totalListening = playbackAccumulatedListeningTime
        if let start = playbackListenStartDate {
            totalListening += Date().timeIntervalSince(start)
        }

        if !playbackHasTriggeredCurrentDownload,
           let itemID = playbackCurrentItemID,
           totalListening >= AppSettings.shared.playbackDownloadTriggerDuration {
            playbackHasTriggeredCurrentDownload = true
            await triggerDownloadIfNeeded(itemID: itemID)
        }

        if !playbackHasTriggeredNextDownload,
           currentTime >= duration - AppSettings.shared.playbackDownloadNearEndThreshold,
           let nextItemID = playbackQueueIDs.first ?? playbackUpNextIDs.first {
            playbackHasTriggeredNextDownload = true
            await triggerDownloadIfNeeded(itemID: nextItemID)
        }
    }

    func onPlaybackStopped() async {
        if let start = playbackListenStartDate {
            playbackAccumulatedListeningTime += Date().timeIntervalSince(start)
            playbackListenStartDate = nil
        }
    }

    private func triggerDownloadIfNeeded(itemID: ItemIdentifier) async {
        do {
            let status = await PersistenceManager.shared.download.status(of: itemID)
            guard status == .none else { return }
            try await PersistenceManager.shared.download.download(itemID)
            logger.info("Playback-triggered download started for \(itemID, privacy: .public)")
        } catch {
            logger.warning("Playback-triggered download failed for \(itemID, privacy: .public): \(error, privacy: .public)")
        }
    }
}
