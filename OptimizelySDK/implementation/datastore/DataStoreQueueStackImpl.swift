//
//  DataStoreQueueStackUserDefaults.swift
//  OptimizelySwiftSDK-iOS
//
//  Created by Thomas Zurkan on 1/18/19.
//  Copyright © 2019 Optimizely. All rights reserved.
//

import Foundation

/// Implementation of DataStoreQueueStack that takes a DataStore as a instance variable allowing for different datastore imlementations.  It is a generic and will work with any data type that supports Codable.  Keep in mind that whichever data store you use, this class stores it as Array<Data>.  Instances of DataStoreQueueStackImpl should be singletons per queueStackName (which usually corrolates to the data type as well depending on producer/consumer).
public class DataStoreQueuStackImpl<T> : DataStoreQueueStack where T:Codable {
    let queueStackName:String
    let lock:DispatchQueue
    let dataStore:OPTDataStore

    /**
     Create instance of DataStoreQueueStack queue or stack.
     - Parameter queueStackName: name used for shared stack or queue.
     - Parameter dataStore: OPTDataStore implementation.
    */
    init(queueStackName:String, dataStore:OPTDataStore) {
        self.queueStackName = queueStackName
        self.lock = DispatchQueue(label: queueStackName)
        self.dataStore = dataStore
    }
    
    /**
     Save item to the datastore QueueStack.  The item is always appended and then depending on how you want to use it you can either pop (i.e. removeLastItem) or queue (i.e. removeFirstItem)
     - Parameter item: Item to save.
    */
    public func save(item:T) {
        lock.async {
            guard let data = try? JSONEncoder().encode(item) else { return }
            if var queue = self.dataStore.getItem(forKey: self.queueStackName) as? Array<Data> {
                queue.append(data)
                self.dataStore.saveItem(forKey: self.queueStackName, value: queue)
            }
            else {
                self.dataStore.saveItem(forKey: self.queueStackName, value: [data])
            }
        }
    }
    
    public func getFirstItem() -> T? {
        var item:T?
        
        lock.sync {
            if let queue = dataStore.getItem(forKey: queueStackName) as? Array<Data> {
                if let data = queue.first {
                    item = try? JSONDecoder().decode(T.self, from: data)
                }
            }
        }
        return item
        
    }
    
    public func getLastItem() -> T? {
        var item:T?
        lock.sync {
            if let queue = dataStore.getItem(forKey: queueStackName) as? Array<Data> {
                if let data = queue.last {
                    item = try? JSONDecoder().decode(T.self, from: data)
                }
            }
        }
        return item
    }
    
    
    public func removeFirstItem() -> T? {
        var item:T?
        
        lock.sync {
            if var queue = dataStore.getItem(forKey: queueStackName) as? Array<Data> {
                if let data = queue.first {
                    item = try? JSONDecoder().decode(T.self, from: data)
                    if queue.count > 0 {
                        queue.remove(at: 0)
                        dataStore.saveItem(forKey: queueStackName, value: queue)
                    }
                }
            }
        }
        return item
    }
    
    public func removeLastItem() -> T? {
        var item:T?
        lock.sync {
            if var queue = dataStore.getItem(forKey: queueStackName) as? Array<Data> {
                if let data = queue.first {
                    item = try? JSONDecoder().decode(T.self, from: data)
                    if queue.count > 0 {
                        queue.removeLast()
                        UserDefaults.standard.set(queue, forKey: queueStackName)
                        UserDefaults.standard.synchronize()
                    }
                }
            }
        }
        return item
    }
}
