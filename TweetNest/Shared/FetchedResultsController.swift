//
//  FetchedResultsController.swift
//  TweetNest
//
//  Created by Jaehong Kang on 2022/03/19.
//

import SwiftUI
import CoreData
import UnifiedLogging

class FetchedResultsController<Element>: NSObject, NSFetchedResultsControllerDelegate where Element: NSManagedObject {
    private lazy var fetchedResultsController: NSFetchedResultsController<Element> = newFetchedResultsController() {
        willSet {
            objectWillChange.send()
        }
    }

    private let errorHandler: ((Error) -> Void)?

    let managedObjectContext: NSManagedObjectContext
    var fetchRequest: NSFetchRequest<Element> {
        didSet {
            fetchedResultsController = newFetchedResultsController()
        }
    }
    var cacheName: String? {
        didSet {
            fetchedResultsController = newFetchedResultsController()
        }
    }

    var fetchedObjects: [Element]? {
        fetchedResultsController.fetchedObjects
    }

    init(fetchRequest: NSFetchRequest<Element>, managedObjectContext: NSManagedObjectContext, cacheName: String? = nil, onError errorHandler: ((Error) -> Void)? = nil) {
        self.fetchRequest = fetchRequest
        self.managedObjectContext = managedObjectContext
        self.cacheName = cacheName
        self.errorHandler = errorHandler
    }

    convenience init(sortDescriptors: [SortDescriptor<Element>], predicate: NSPredicate? = nil, managedObjectContext: NSManagedObjectContext, cacheName: String? = nil, onError errorHandler: ((Error) -> Void)? = nil) {
        self.init(
            fetchRequest: {
                let fetchRequest = NSFetchRequest<Element>()
                fetchRequest.entity = Element.entity()
                fetchRequest.sortDescriptors = sortDescriptors.map { NSSortDescriptor($0) }
                fetchRequest.predicate = predicate

                return fetchRequest
            }(),
            managedObjectContext: managedObjectContext,
            cacheName: cacheName,
            onError: errorHandler
        )
    }

    private func newFetchedResultsController() -> NSFetchedResultsController<Element> {
        let fetchedResultsController = NSFetchedResultsController(
            fetchRequest: fetchRequest,
            managedObjectContext: managedObjectContext,
            sectionNameKeyPath: nil,
            cacheName: cacheName
        )

        fetchedResultsController.delegate = self

        do {
            if fetchedResultsController.fetchedObjects == nil {
                try fetchedResultsController.performFetch()
            }
        } catch {
            Logger().error("Error occured on FetchedResultsController:\n\(error as NSError)")
            self.errorHandler?(error)
        }

        return fetchedResultsController
    }

    func controllerWillChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        objectWillChange.send()
    }
}

extension FetchedResultsController: RandomAccessCollection {
    typealias Index = Int

    var startIndex: Index { (fetchedObjects ?? []).startIndex }
    var endIndex: Index { (fetchedObjects ?? []).endIndex }

    subscript(position: Index) -> Element {
        get {
            (fetchedObjects ?? [])[position]
        }
    }

    func index(after i: Index) -> Index {
        (fetchedObjects ?? []).index(after: i)
    }
}

extension FetchedResultsController: ObservableObject { }
