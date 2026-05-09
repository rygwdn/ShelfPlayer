//
//  ConvenienceDownloadSubsystem+Playback.swift
//  ShelfPlayerKit
//
//  Created by Rasmus Krämer on 09.05.25.
//

import Foundation
import OSLog
import RFNotifications

// Mirrors the private constant in ConvenienceDownloadSubsystem.swift
private let PLAYBACK_TRIGGERED_CONFIGURATION_ID = "playback-triggered"

extension PersistenceManager.ConvenienceDownloadSubsystem {
    // Called from init() in ConvenienceDownloadSubsystem.swift
    nonisolated func setupPlaybackObservers() {
        RFNotification[.playbackItemChanged].subscribe { [weak self] itemID, _, _ in
            Task { await self?.handlePlaybackItemChanged(itemID: itemID) }
        }
        RFNotification[.playStateChanged].subscribe { [weak self] isPlaying in
            Task { await self?.handlePlayStateChanged(isPlaying: isPlaying) }
        }
        RFNotification[.currentTimesChanged].subscribe { [weak self] currentTime, _ in
            Task { await self?.checkPlaybackTriggers(currentTime: currentTime) }
        }
        RFNotification[.durationsChanged].subscribe { [weak self] duration, _ in
            Task { await self?.handleDurationChanged(duration: duration) }
        }
        RFNotification[.upNextQueueChanged].subscribe { [weak self] ids in
            Task { await self?.handleUpNextQueueChanged(ids: ids) }
        }
        RFNotification[.queueChanged].subscribe { [weak self] ids in
            Task { await self?.handleQueueChanged(ids: ids) }
        }
        RFNotification[.playbackStopped].subscribe { [weak self] in
            Task { await self?.resetPlaybackState() }
        }
    }

    func handlePlaybackItemChanged(itemID: ItemIdentifier) {
        if let startDate = listenStartDate {
            accumulatedListeningTime += startDate.distance(to: .now)
        }

        currentPlayingItemID = itemID
        accumulatedListeningTime = 0
        listenStartDate = .now
        hasTriggeredCurrentItemDownload = false
        hasTriggeredNextItemDownload = false
        currentDuration = nil
        primaryQueueItemIDs = []
        upNextQueueItemIDs = []
    }

    func handlePlayStateChanged(isPlaying: Bool) {
        if isPlaying {
            listenStartDate = .now
        } else {
            if let startDate = listenStartDate {
                accumulatedListeningTime += startDate.distance(to: .now)
                listenStartDate = nil
            }
        }
    }

    func handleDurationChanged(duration: TimeInterval?) {
        currentDuration = duration
    }

    func handleUpNextQueueChanged(ids: [ItemIdentifier]) {
        upNextQueueItemIDs = ids
    }

    func handleQueueChanged(ids: [ItemIdentifier]) {
        primaryQueueItemIDs = ids
    }

    func resetPlaybackState() {
        if let startDate = listenStartDate {
            accumulatedListeningTime += startDate.distance(to: .now)
            listenStartDate = nil
        }
        currentPlayingItemID = nil
        accumulatedListeningTime = 0
        hasTriggeredCurrentItemDownload = false
        hasTriggeredNextItemDownload = false
        currentDuration = nil
        primaryQueueItemIDs = []
        upNextQueueItemIDs = []
    }

    // The item that will play after the current one (primary queue first, then up-next)
    var nextEffectiveItemID: ItemIdentifier? {
        primaryQueueItemIDs.first ?? upNextQueueItemIDs.first
    }

    func checkPlaybackTriggers(currentTime: TimeInterval?) async {
        guard Defaults[.enablePlaybackTriggeredDownloads], Defaults[.enableConvenienceDownloads] else {
            return
        }

        guard let currentTime else {
            return
        }

        let totalListeningTime = accumulatedListeningTime + (listenStartDate?.distance(to: .now) ?? 0)

        if !hasTriggeredCurrentItemDownload, let itemID = currentPlayingItemID,
           totalListeningTime >= TimeInterval(Defaults[.playbackDownloadTriggerDuration]) {
            await triggerCurrentItemDownload(itemID: itemID)
        }

        let nearEndThreshold = Defaults[.playbackDownloadNearEndThreshold]
        if !hasTriggeredNextItemDownload, nearEndThreshold > 0,
           let duration = currentDuration, duration > 0,
           duration - currentTime <= TimeInterval(nearEndThreshold) {
            await triggerNextItemDownload()
        }
    }

    func triggerCurrentItemDownload(itemID: ItemIdentifier) async {
        hasTriggeredCurrentItemDownload = true

        guard await PersistenceManager.shared.download.status(of: itemID) == .none else {
            logger.info("Skipping playback-triggered download, already downloaded/downloading: \(itemID)")
            return
        }

        guard await !isManaged(itemID: itemID) else {
            logger.info("Skipping playback-triggered download, already managed by convenience downloads: \(itemID)")
            return
        }

        do {
            try await PersistenceManager.shared.download.download(itemID)
            try await registerPlaybackTriggeredDownload(itemID: itemID)
            logger.info("Auto-downloaded item after listening threshold: \(itemID)")
        } catch PersistenceError.existing, PersistenceError.busy {
            logger.info("Skipping playback-triggered download because item already exists or is busy: \(itemID)")
        } catch {
            logger.error("Failed to trigger playback download for \(itemID): \(error)")
        }
    }

    func triggerNextItemDownload() async {
        hasTriggeredNextItemDownload = true

        guard let nextItemID = nextEffectiveItemID else {
            logger.info("Skipping near-end pre-download: queue is empty")
            return
        }

        guard await PersistenceManager.shared.download.status(of: nextItemID) == .none else {
            logger.info("Skipping near-end pre-download, already downloaded/downloading: \(nextItemID)")
            return
        }

        guard await !isManaged(itemID: nextItemID) else {
            logger.info("Skipping near-end pre-download, already managed by convenience downloads: \(nextItemID)")
            return
        }

        do {
            try await PersistenceManager.shared.download.download(nextItemID)
            try await registerPlaybackTriggeredDownload(itemID: nextItemID)
            logger.info("Pre-downloaded next queue item when nearing end: \(nextItemID)")
        } catch PersistenceError.existing, PersistenceError.busy {
            logger.info("Skipping near-end pre-download because item already exists or is busy: \(nextItemID)")
        } catch {
            logger.error("Failed to pre-download next queue item \(nextItemID): \(error)")
        }
    }

    nonisolated func registerPlaybackTriggeredDownload(itemID: ItemIdentifier) async throws {
        let associatedKey = PersistenceManager.KeyValueSubsystem.Key<Set<String>>(
            identifier: "associatedConfigurationIDs-\(itemID)",
            cluster: "associatedConfigurationIDs",
            isCachePurgeable: false
        )
        let downloadedKey = PersistenceManager.KeyValueSubsystem.Key<Set<ItemIdentifier>>(
            identifier: "downloadedItemIDs-\(PLAYBACK_TRIGGERED_CONFIGURATION_ID)",
            cluster: "downloadedItemIDs",
            isCachePurgeable: false
        )

        var associated = await PersistenceManager.shared.keyValue[associatedKey] ?? .init()
        associated.insert(PLAYBACK_TRIGGERED_CONFIGURATION_ID)
        try await PersistenceManager.shared.keyValue.set(associatedKey, associated)

        var downloaded = await PersistenceManager.shared.keyValue[downloadedKey] ?? .init()
        downloaded.insert(itemID)
        try await PersistenceManager.shared.keyValue.set(downloadedKey, downloaded)
    }

    nonisolated func purgePlaybackTriggeredDownloads() async {
        let downloadedKey = PersistenceManager.KeyValueSubsystem.Key<Set<ItemIdentifier>>(
            identifier: "downloadedItemIDs-\(PLAYBACK_TRIGGERED_CONFIGURATION_ID)",
            cluster: "downloadedItemIDs",
            isCachePurgeable: false
        )

        guard let downloaded = await PersistenceManager.shared.keyValue[downloadedKey] else {
            return
        }

        for itemID in downloaded {
            await remove(itemID: itemID, configurationID: PLAYBACK_TRIGGERED_CONFIGURATION_ID)
        }

        do {
            try await PersistenceManager.shared.keyValue.set(downloadedKey, nil as Set<ItemIdentifier>?)
        } catch {
            logger.error("Failed to clear playback-triggered download tracking: \(error)")
        }

        logger.info("Purged all playback-triggered downloads")
    }
}
