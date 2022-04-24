//
//  Session+RemoteChanges.swift
//  Session+RemoteChanges
//
//  Created by Jaehong Kang on 2021/09/01.
//

import Foundation
import Twitter
import CoreData
import UserNotifications
import Algorithms
import OrderedCollections
import BackgroundTask
import UnifiedLogging

extension Session {
    private var logger: Logger {
        Logger(subsystem: Bundle.tweetNestKit.bundleIdentifier!, category: "remote-changes")
    }
    
    func handlePersistentStoreRemoteChanges(_ notification: Notification) {
        withExtendedBackgroundExecution {
            do {
                let lastPersistentHistoryToken = try TweetNestKitUserDefaults.standard.lastPersistentHistoryTokenData.flatMap {
                    try NSKeyedUnarchiver.unarchivedObject(
                        ofClass: NSPersistentHistoryToken.self,
                        from: $0
                    )
                }

                guard let lastPersistentHistoryToken = lastPersistentHistoryToken else {
                    if let currentPersistentHistoryToken = notification.userInfo?[NSPersistentHistoryTokenKey] as? NSPersistentHistoryToken {
                        TweetNestKitUserDefaults.standard.lastPersistentHistoryTokenData = try NSKeyedArchiver.archivedData(
                            withRootObject: currentPersistentHistoryToken,
                            requiringSecureCoding: true
                        )
                    }

                    return
                }

                let context = self.persistentContainer.newBackgroundContext()
                let persistentHistoryResult = try context.performAndWait {
                    try context.execute(
                        NSPersistentHistoryChangeRequest.fetchHistory(
                            after: lastPersistentHistoryToken
                        )
                    )
                } as? NSPersistentHistoryResult

                guard
                    let persistentHistoryTransactions = persistentHistoryResult?.result as? [NSPersistentHistoryTransaction],
                    let newLastPersistentHistoryToken = persistentHistoryTransactions.last?.token
                else {
                    return
                }

                TweetNestKitUserDefaults.standard.lastPersistentHistoryTokenData = try NSKeyedArchiver.archivedData(
                    withRootObject: newLastPersistentHistoryToken,
                    requiringSecureCoding: true
                )

                Task.detached {
                    await withTaskGroup(of: Void.self) { taskGroup in
                        taskGroup.addTask(priority: .high) {
                            await self.updateNotifications(transactions: persistentHistoryTransactions)
                        }

                        taskGroup.addTask(priority: .medium) {
                            await self.updateAccountCredential(transactions: persistentHistoryTransactions)
                        }

                        taskGroup.addTask(priority: .utility) {
                            await self.cleansingAccount(transactions: persistentHistoryTransactions)
                        }

                        taskGroup.addTask(priority: .utility) {
                            await self.cleansingUser(transactions: persistentHistoryTransactions)
                        }

                        taskGroup.addTask(priority: .utility) {
                            await self.cleansingDataAssets(transactions: persistentHistoryTransactions)
                        }

                        await taskGroup.waitForAll()
                    }
                }
            } catch {
                self.logger.error("Error occurred while handle persistent store remote changes: \(error as NSError, privacy: .public)")
            }
        }
    }

    private func updateAccountCredential(transactions: [NSPersistentHistoryTransaction]) async {
        let changedAccountObjectIDs = transactions.lazy
            .compactMap(\.changes)
            .joined()
            .filter { $0.changedObjectID.entity == Account.entity() }
            .filter { $0.changeType == .update }
            .map(\.changedObjectID)
            .uniqued()

        let context = self.persistentContainer.newBackgroundContext()
        context.undoManager = nil

        for changedAccountObjectID in changedAccountObjectIDs {
            let credential: Twitter.Session.Credential? = await context.perform {
                guard let account = context.object(with: changedAccountObjectID) as? Account else {
                    return nil
                }

                return account.credential
            }

            guard let twitterSession = await self.sessionActor.twitterSessions[changedAccountObjectID.uriRepresentation()] else {
                return
            }

            await twitterSession.updateCredential(credential)
        }
    }
}

extension Session {
    private func cleansingAccount(transactions: [NSPersistentHistoryTransaction]) async {
        let changedAccountObjectIDs = transactions.lazy
            .compactMap(\.changes)
            .joined()
            .filter { $0.changedObjectID.entity == Account.entity() }
            .filter { $0.changeType == .insert }
            .map(\.changedObjectID)
            .uniqued()

        let context = self.persistentContainer.newBackgroundContext()
        context.undoManager = nil

        for changedAccountObjectID in changedAccountObjectIDs {
            do {
                try await self.cleansingAccount(for: changedAccountObjectID, context: context)
            } catch {
                self.logger.error("Error occurred while cleansing account: \(error as NSError, privacy: .public)")
            }
        }
    }

    private func cleansingUser(transactions: [NSPersistentHistoryTransaction]) async {
        let changedUserObjectIDs = transactions.lazy
            .compactMap(\.changes)
            .joined()
            .filter { $0.changedObjectID.entity == User.entity() }
            .filter { $0.changeType == .insert }
            .map(\.changedObjectID)
            .uniqued()

        let context = self.persistentContainer.newBackgroundContext()
        context.undoManager = nil

        for changedUserObjectID in changedUserObjectIDs {
            do {
                try await self.cleansingUser(for: changedUserObjectID, context: context)
            } catch {
                self.logger.error("Error occurred while cleansing user: \(error as NSError, privacy: .public)")
            }
        }
    }

    private func cleansingDataAssets(transactions: [NSPersistentHistoryTransaction]) async {
        let changedDataAssetObjectIDs = transactions.lazy
            .compactMap(\.changes)
            .joined()
            .filter { $0.changedObjectID.entity == DataAsset.entity() }
            .filter { $0.changeType == .insert }
            .map(\.changedObjectID)
            .uniqued()

        let context = self.persistentContainer.newBackgroundContext()
        context.undoManager = nil

        for changedDataAssetObjectID in changedDataAssetObjectIDs {
            do {
                try await self.cleansingDataAsset(for: changedDataAssetObjectID, context: context)
            } catch {
                self.logger.error("Error occurred while cleansing data asset: \(error as NSError, privacy: .public)")
            }
        }
    }
}

extension Session {
    private func updateNotification(for userDetailObjectID: NSManagedObjectID, preferences: ManagedPreferences.Preferences) async {
        let notificationRequest: UNNotificationRequest? = await persistentContainer.performBackgroundTask { context in
            context.undoManager = nil

            guard
                let newUserDetail = context.object(with: userDetailObjectID) as? UserDetail,
                let newUserDetailCreationDate = newUserDetail.creationDate,
                Date(timeIntervalSinceNow: -(60 * 60)) <= newUserDetailCreationDate,
                let user = newUserDetail.user,
                let account = user.accounts?.last,
                let sortedUserDetails = user.sortedUserDetails
            else {
                return nil
            }

            let oldUserDetailIndex = sortedUserDetails.lastIndex(of: newUserDetail).flatMap { sortedUserDetails.index(before: $0) }

            guard let oldUserDetail = oldUserDetailIndex.flatMap({ sortedUserDetails.indices.contains($0) == true ? sortedUserDetails[$0] : nil }) else {
                return nil
            }

            let notificationContent = UNMutableNotificationContent()
            notificationContent.title = newUserDetail.name ?? account.objectID.description
            if let subtitle = newUserDetail.displayUsername ?? user.id?.displayUserID ?? account.userID?.displayUserID {
                notificationContent.subtitle = subtitle
            }
            notificationContent.threadIdentifier = self.persistentContainer.recordID(for: account.objectID)?.recordName ?? account.objectID.uriRepresentation().absoluteString
            notificationContent.categoryIdentifier = "NewAccountData"
            notificationContent.sound = .default
            notificationContent.interruptionLevel = .timeSensitive

            var changes: [String] = []

            if preferences.notifyProfileChanges {
                if oldUserDetail.isProfileEqual(to: newUserDetail) == false {
                    changes.append(String(localized: "New Profile", bundle: .tweetNestKit, comment: "background-refresh notification body."))
                }
            }

            if preferences.notifyFollowingChanges, let followingUserIDsChanges = newUserDetail.userIDsChanges(from: oldUserDetail, for: \.followingUserIDs) {
                if followingUserIDsChanges.addedUserIDsCount > 0 {
                    changes.append(String(localized: "\(followingUserIDsChanges.addedUserIDsCount, specifier: "%ld") New Following(s)", bundle: .tweetNestKit, comment: "background-refresh notification body."))
                }
                if followingUserIDsChanges.removedUserIDsCount > 0 {
                    changes.append(String(localized: "\(followingUserIDsChanges.removedUserIDsCount, specifier: "%ld") New Unfollowing(s)", bundle: .tweetNestKit, comment: "background-refresh notification body."))
                }
            }

            if preferences.notifyFollowerChanges, let followerUserIDsChanges = newUserDetail.userIDsChanges(from: oldUserDetail, for: \.followerUserIDs) {
                if followerUserIDsChanges.addedUserIDsCount > 0 {
                    changes.append(String(localized: "\(followerUserIDsChanges.addedUserIDsCount, specifier: "%ld") New Follower(s)", bundle: .tweetNestKit, comment: "background-refresh notification body."))
                }
                if followerUserIDsChanges.removedUserIDsCount > 0 {
                    changes.append(String(localized: "\(followerUserIDsChanges.removedUserIDsCount, specifier: "%ld") New Unfollower(s)", bundle: .tweetNestKit, comment: "background-refresh notification body."))
                }
            }

            if preferences.notifyBlockingChanges, let blockingUserIDsChanges = newUserDetail.userIDsChanges(from: oldUserDetail, for: \.blockingUserIDs) {
                if blockingUserIDsChanges.addedUserIDsCount > 0 {
                    changes.append(String(localized: "\(blockingUserIDsChanges.addedUserIDsCount, specifier: "%ld") New Block(s)", bundle: .tweetNestKit, comment: "background-refresh notification body."))
                }
                if blockingUserIDsChanges.removedUserIDsCount > 0 {
                    changes.append(String(localized: "\(blockingUserIDsChanges.removedUserIDsCount, specifier: "%ld") New Unblock(s)", bundle: .tweetNestKit, comment: "background-refresh notification body."))
                }
            }

            if preferences.notifyMutingChanges, let mutingUserIDsChanges = newUserDetail.userIDsChanges(from: oldUserDetail, for: \.mutingUserIDs) {
                if mutingUserIDsChanges.addedUserIDsCount > 0 {
                    changes.append(String(localized: "\(mutingUserIDsChanges.addedUserIDsCount, specifier: "%ld") New Mute(s)", bundle: .tweetNestKit, comment: "background-refresh notification body."))
                }
                if mutingUserIDsChanges.removedUserIDsCount > 0 {
                    changes.append(String(localized: "\(mutingUserIDsChanges.removedUserIDsCount, specifier: "%ld") New Unmute(s)", bundle: .tweetNestKit, comment: "background-refresh notification body."))
                }
            }

            guard changes.isEmpty == false else {
                self.deleteNotifications(for: userDetailObjectID)

                return nil
            }

            notificationContent.body = changes.formatted(.list(type: .and, width: .narrow))

            return UNNotificationRequest(
                identifier: self.persistentContainer.recordID(for: userDetailObjectID)?.recordName ?? userDetailObjectID.uriRepresentation().absoluteString,
                content: notificationContent,
                trigger: nil
            )
        }

        guard let notificationRequest = notificationRequest else {
            return
        }

        Task.detached {
            do {
                try await UNUserNotificationCenter.current().add(notificationRequest)
            } catch {
                self.logger.error("Error occurred while request notification: \(error as NSError, privacy: .public)")
            }
        }
    }

    private func deleteNotifications(for userDetailObjectID: NSManagedObjectID) {
        let notificationIdentifiers = Array([self.persistentContainer.recordID(for: userDetailObjectID)?.recordName, userDetailObjectID.uriRepresentation().absoluteString].compacted())

        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: notificationIdentifiers)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: notificationIdentifiers)
    }

    private func updateNotifications(transactions: [NSPersistentHistoryTransaction]) async {
        await withExtendedBackgroundExecution {
            let changes = transactions.lazy
                .compactMap(\.changes)
                .joined()
                .filter { $0.changedObjectID.entity == UserDetail.entity() }

            async let preferences = self.persistentContainer.performBackgroundTask { context in
                ManagedPreferences.managedPreferences(for: context).preferences
            }

            for change in changes {
                guard Task.isCancelled == false else { return }

                switch change.changeType {
                case .insert, .update:
                    await self.updateNotification(for: change.changedObjectID, preferences: preferences)
                case .delete:
                    self.deleteNotifications(for: change.changedObjectID)
                @unknown default:
                    break
                }
            }
        }
    }
}
