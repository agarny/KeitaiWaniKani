//
//  ResourceRepository.swift
//  WaniKaniKit
//
//  Copyright © 2017 Chris Laverty. All rights reserved.
//

import FMDB
import os

public extension NSNotification.Name {
    static let waniKaniAssignmentsDidChange = NSNotification.Name("waniKaniAssignmentsDidChange")
    static let waniKaniLevelProgressionDidChange = NSNotification.Name("waniKaniLevelProgressionDidChange")
    static let waniKaniReviewStatisticsDidChange = NSNotification.Name("waniKaniReviewStatisticsDidChange")
    static let waniKaniStudyMaterialsDidChange = NSNotification.Name("waniKaniStudyMaterialsDidChange")
    static let waniKaniSubjectsDidChange = NSNotification.Name("waniKaniSubjectsDidChange")
    static let waniKaniUserInformationDidChange = NSNotification.Name("waniKaniUserInformationDidChange")
}

public extension CFNotificationName {
    
    private static let notificationBaseName = "com.hellix.keitaiWaniKani.notifications"
    static let waniKaniAssignmentsDidChange = CFNotificationName("\(notificationBaseName).waniKaniAssignmentsDidChange" as CFString)
    static let waniKaniLevelProgressionDidChange = CFNotificationName("\(notificationBaseName).waniKaniLevelProgressionDidChange" as CFString)
    static let waniKaniReviewStatisticsDidChange = CFNotificationName("\(notificationBaseName).waniKaniReviewStatisticsDidChange" as CFString)
    static let waniKaniStudyMaterialsDidChange = CFNotificationName("\(notificationBaseName).waniKaniStudyMaterialsDidChange" as CFString)
    static let waniKaniSubjectsDidChange = CFNotificationName("\(notificationBaseName).waniKaniSubjectsDidChange" as CFString)
    static let waniKaniUserInformationDidChange = CFNotificationName("\(notificationBaseName).waniKaniUserInformationDidChange" as CFString)
}

extension ResourceType {
    var associatedCFNotificationName: CFNotificationName {
        switch self {
        case .assignments:
            return .waniKaniAssignmentsDidChange
        case .levelProgression:
            return .waniKaniLevelProgressionDidChange
        case .reviewStatistics:
            return .waniKaniReviewStatisticsDidChange
        case .studyMaterials:
            return .waniKaniStudyMaterialsDidChange
        case .subjects:
            return .waniKaniSubjectsDidChange
        case .user:
            return .waniKaniUserInformationDidChange
        }
    }
    
    var associatedNotificationName: NSNotification.Name {
        switch self {
        case .assignments:
            return .waniKaniAssignmentsDidChange
        case .levelProgression:
            return .waniKaniLevelProgressionDidChange
        case .reviewStatistics:
            return .waniKaniReviewStatisticsDidChange
        case .studyMaterials:
            return .waniKaniStudyMaterialsDidChange
        case .subjects:
            return .waniKaniSubjectsDidChange
        case .user:
            return .waniKaniUserInformationDidChange
        }
    }
    
    func getLastUpdateDate(in database: FMDatabase) throws -> Date? {
        let table = Tables.resourceLastUpdate
        let query = "SELECT \(table.dataUpdatedAt) FROM \(table) WHERE \(table.resourceType) = ?"
        
        return try database.dateForQuery(query, values: [rawValue])
    }
    
    func setLastUpdateDate(_ lastUpdate: Date, in database: FMDatabase) throws {
        os_log("Setting last update date for resource %@ to %@", type: .debug, rawValue, lastUpdate as NSDate)
        let table = Tables.resourceLastUpdate
        let query = """
        INSERT OR REPLACE INTO \(table.name)
        (\(table.resourceType.name), \(table.dataUpdatedAt.name))
        VALUES (?, ?)
        """
        
        let values: [Any] = [rawValue, lastUpdate]
        try database.executeUpdate(query, values: values)
    }
}

public class ResourceRepository: ResourceRepositoryReader {
    private let api: WaniKaniAPIProtocol
    
    public init(databaseManager: DatabaseManager, api: WaniKaniAPIProtocol) {
        self.api = api
        
        super.init(databaseManager: databaseManager)
    }
    
    public convenience init(databaseManager: DatabaseManager, apiKey: String, networkActivityDelegate: NetworkActivityDelegate? = nil) {
        let api = WaniKaniAPI(apiKey: apiKey)
        api.networkActivityDelegate = networkActivityDelegate
        
        self.init(databaseManager: databaseManager, api: api)
    }
    
    public func getLastUpdateDate(for resourceType: ResourceType) throws -> Date? {
        guard let databaseQueue = self.databaseQueue else {
            throw ResourceRepositoryError.noDatabase
        }
        
        return try databaseQueue.inDatabase { database in
            return try resourceType.getLastUpdateDate(in: database)
        }
    }
    
    public func getEarliestLastUpdateDate(for resourceTypes: [ResourceType]) throws -> Date? {
        guard let databaseQueue = self.databaseQueue else {
            throw ResourceRepositoryError.noDatabase
        }
        
        return try databaseQueue.inDatabase { database in
            return try resourceTypes.lazy.compactMap({ try $0.getLastUpdateDate(in: database) }).min()
        }
    }
    
    @discardableResult public func updateUser(minimumFetchInterval: TimeInterval, completionHandler: @escaping (ResourceRefreshResult) -> Void) -> Progress {
        guard let databaseQueue = self.databaseQueue else {
            let progress = Progress(totalUnitCount: 1)
            progress.completedUnitCount = 1
            DispatchQueue.global().async {
                completionHandler(.error(ResourceRepositoryError.noDatabase))
            }
            return progress
        }
        
        let resourceType = ResourceType.user
        let requestStartTime = Date()
        
        let lastUpdate = try? databaseQueue.inDatabase { database in
            return try resourceType.getLastUpdateDate(in: database)
        }
        
        if let lastUpdate = lastUpdate, requestStartTime.timeIntervalSince(lastUpdate) < minimumFetchInterval {
            os_log("Skipping resource fetch: %.3f < %.3f", type: .info, requestStartTime.timeIntervalSince(lastUpdate), minimumFetchInterval)
            
            let progress = Progress(totalUnitCount: 1)
            progress.completedUnitCount = 1
            DispatchQueue.global().async {
                completionHandler(.noData)
            }
            return progress
        }
        
        return api.fetchResource(ofType: .user) { result in
            switch result {
            case let .failure(error):
                os_log("Got error when fetching: %@", type: .error, error as NSError)
                completionHandler(.error(error))
            case let .success(resource):
                guard let data = resource.data as? UserInformation else {
                    os_log("No data available", type: .debug)
                    self.notifyNoData(databaseQueue: databaseQueue, resourceType: resourceType, requestStartTime: requestStartTime, completionHandler: completionHandler)
                    return
                }
                
                if let lastUpdate = lastUpdate, resource.dataUpdatedAt < lastUpdate {
                    os_log("No change from last update", type: .debug)
                    self.notifyNoData(databaseQueue: databaseQueue, resourceType: resourceType, requestStartTime: requestStartTime, completionHandler: completionHandler)
                    return
                }
                
                var databaseError: Error? = nil
                databaseQueue.inImmediateTransaction { (database, rollback) in
                    os_log("Writing to database", type: .debug)
                    do {
                        try data.write(to: database)
                        
                        os_log("Setting last update date for resource %@ to %@", type: .info, resourceType.rawValue, requestStartTime as NSDate)
                        try resourceType.setLastUpdateDate(requestStartTime, in: database)
                    } catch {
                        databaseError = error
                        rollback.pointee = true
                    }
                }
                
                if let error = databaseError {
                    os_log("Error writing to database", type: .error, error as NSError)
                    completionHandler(.error(error))
                    return
                }
                
                os_log("Fetch of resource %@ finished successfully", type: .info, resourceType.rawValue)
                DispatchQueue.main.async {
                    self.postNotifications(for: resourceType)
                }
                completionHandler(.success)
            }
        }
    }
    
    @discardableResult public func updateAssignments(minimumFetchInterval: TimeInterval, completionHandler: @escaping (ResourceRefreshResult) -> Void) -> Progress {
        return updateResourceCollection(ofType: .assignments,
                                        minimumFetchInterval: minimumFetchInterval,
                                        requestForLastUpdateDate: { .assignments(filter: $0.map { AssignmentFilter(updatedAfter: $0) }) },
                                        completionHandler: completionHandler)
    }
    
    @discardableResult public func updateLevelProgression(minimumFetchInterval: TimeInterval, completionHandler: @escaping (ResourceRefreshResult) -> Void) -> Progress {
        return updateResourceCollection(ofType: .levelProgression,
                                        minimumFetchInterval: minimumFetchInterval,
                                        requestForLastUpdateDate: { .levelProgressions(filter: $0.map { LevelProgressionFilter(updatedAfter: $0) }) },
                                        completionHandler: completionHandler)
    }
    
    @discardableResult public func updateReviewStatistics(minimumFetchInterval: TimeInterval, completionHandler: @escaping (ResourceRefreshResult) -> Void) -> Progress {
        return updateResourceCollection(ofType: .reviewStatistics,
                                        minimumFetchInterval: minimumFetchInterval,
                                        requestForLastUpdateDate: { .reviewStatistics(filter: $0.map { ReviewStatisticFilter(updatedAfter: $0) }) },
                                        completionHandler: completionHandler)
    }
    
    @discardableResult public func updateStudyMaterials(minimumFetchInterval: TimeInterval, completionHandler: @escaping (ResourceRefreshResult) -> Void) -> Progress {
        return updateResourceCollection(ofType: .studyMaterials,
                                        minimumFetchInterval: minimumFetchInterval,
                                        requestForLastUpdateDate: { .studyMaterials(filter: $0.map { StudyMaterialFilter(updatedAfter: $0) }) },
                                        completionHandler: completionHandler)
    }
    
    @discardableResult public func updateSubjects(minimumFetchInterval: TimeInterval, completionHandler: @escaping (ResourceRefreshResult) -> Void) -> Progress {
        return updateResourceCollection(ofType: .subjects,
                                        minimumFetchInterval: minimumFetchInterval,
                                        requestForLastUpdateDate: { .subjects(filter: $0.map { SubjectFilter(updatedAfter: $0) }) },
                                        completionHandler: completionHandler)
    }
    
    private func updateResourceCollection(ofType resourceType: ResourceType, minimumFetchInterval: TimeInterval, requestForLastUpdateDate: (Date?) -> ResourceCollectionRequestType, completionHandler: @escaping (ResourceRefreshResult) -> Void) -> Progress {
        guard let databaseQueue = self.databaseQueue else {
            let progress = Progress(totalUnitCount: 1)
            progress.completedUnitCount = 1
            DispatchQueue.global().async {
                completionHandler(.error(ResourceRepositoryError.noDatabase))
            }
            return progress
        }
        
        let requestStartTime = Date()
        
        let lastUpdate = try? databaseQueue.inDatabase { database in
            return try resourceType.getLastUpdateDate(in: database)
        }
        
        if let lastUpdate = lastUpdate, requestStartTime.timeIntervalSince(lastUpdate) < minimumFetchInterval {
            os_log("Skipping resource fetch: %.3f < %.3f", type: .debug, requestStartTime.timeIntervalSince(lastUpdate), minimumFetchInterval)
            
            let progress = Progress(totalUnitCount: 1)
            progress.completedUnitCount = 1
            DispatchQueue.global().async {
                completionHandler(.noData)
            }
            return progress
        }
        
        if let lastUpdate = lastUpdate {
            os_log("Fetching resource %@ (updated since %@)", type: .info, resourceType.rawValue, lastUpdate as NSDate)
        } else {
            os_log("Fetching resource %@", type: .info, resourceType.rawValue)
        }
        
        let type = requestForLastUpdateDate(lastUpdate)
        
        var totalPagesReceived = 0
        
        return api.fetchResourceCollection(ofType: type) { result -> Bool in
            switch result {
            case .failure(WaniKaniAPIError.noContent):
                os_log("No data available", type: .debug)
                self.notifyNoData(databaseQueue: databaseQueue, resourceType: resourceType, requestStartTime: requestStartTime, completionHandler: completionHandler)
                return false
            case let .failure(error):
                os_log("Got error when fetching: %@", type: .error, error as NSError)
                completionHandler(.error(error))
                return false
            case let .success(resources):
                guard resources.totalCount > 0 else {
                    os_log("No data available (response nil or total count zero)", type: .debug)
                    self.notifyNoData(databaseQueue: databaseQueue, resourceType: resourceType, requestStartTime: requestStartTime, completionHandler: completionHandler)
                    return false
                }
                
                totalPagesReceived += 1
                let isLastPage = totalPagesReceived == resources.estimatedPageCount
                
                var databaseError: Error? = nil
                databaseQueue.inImmediateTransaction { (database, rollback) in
                    os_log("Writing %d entries to database (page %d of %d)", type: .debug, resources.data.count, totalPagesReceived, resources.estimatedPageCount)
                    do {
                        try resources.write(to: database)
                        
                        if isLastPage {
                            try resourceType.setLastUpdateDate(requestStartTime, in: database)
                        }
                    } catch {
                        databaseError = error
                        rollback.pointee = true
                    }
                }
                
                if let error = databaseError {
                    os_log("Error writing to database", type: .error, error as NSError)
                    completionHandler(.error(error))
                    return false
                }
                
                if isLastPage {
                    os_log("Fetch of resource %@ finished successfully", type: .info, resourceType.rawValue)
                    DispatchQueue.main.async {
                        self.postNotifications(for: resourceType)
                    }
                    completionHandler(.success)
                    return false
                }
                
                return true
            }
        }
    }
    
    private func notifyNoData(databaseQueue: FMDatabaseQueue, resourceType: ResourceType, requestStartTime: Date, completionHandler: (ResourceRefreshResult) -> Void) {
        do {
            try databaseQueue.inDatabase { database in
                try resourceType.setLastUpdateDate(requestStartTime, in: database)
            }
            completionHandler(.noData)
        } catch {
            completionHandler(.error(error))
        }
    }
    
    private func postNotifications(for resourceType: ResourceType) {
        os_log("Sending notifications for resource %@", type: .debug, resourceType.rawValue)
        NotificationCenter.default.post(name: resourceType.associatedNotificationName, object: self)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), resourceType.associatedCFNotificationName, nil, nil, true)
    }
}
