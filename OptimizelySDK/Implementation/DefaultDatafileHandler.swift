/****************************************************************************
* Copyright 2019, Optimizely, Inc. and contributors                        *
*                                                                          *
* Licensed under the Apache License, Version 2.0 (the "License");          *
* you may not use this file except in compliance with the License.         *
* You may obtain a copy of the License at                                  *
*                                                                          *
*    http://www.apache.org/licenses/LICENSE-2.0                            *
*                                                                          *
* Unless required by applicable law or agreed to in writing, software      *
* distributed under the License is distributed on an "AS IS" BASIS,        *
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. *
* See the License for the specific language governing permissions and      *
* limitations under the License.                                           *
***************************************************************************/

import Foundation

class DefaultDatafileHandler : OPTDatafileHandler {
    static public var endPointStringFormat = "https://cdn.optimizely.com/datafiles/%@.json"
    lazy var logger = HandlerRegistryService.shared.injectLogger()
    var timers:AtomicProperty<[String:(timer:Timer, interval:Int)]> = AtomicProperty(property: [String:(Timer,Int)]())
    let dataStore = DataStoreUserDefaults()
    
    let downloadQueue = DispatchQueue(label: "DefaultDatafileHandlerQueue", qos: DispatchQoS.default, attributes: DispatchQueue.Attributes.concurrent, autoreleaseFrequency: DispatchQueue.AutoreleaseFrequency.inherit, target: nil)
    
    required init() {
        
    }
    
    func downloadDatafile(sdkKey: String) -> Data? {
        
        var datafile:Data?
        let group = DispatchGroup()
        
        group.enter()
        
        downloadDatafile(sdkKey: sdkKey) { (result) in
            switch result {
            case .success(let data):
                datafile = data
            case .failure(let error):
                self.logger?.log(level: .error, message: error.localizedDescription)
            }
            group.leave()
        }
        
        group.wait()
        
        return datafile
    }
    
    open func getSession(resourceTimeoutInterval:Double?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        if let resourceTimeoutInterval = resourceTimeoutInterval,
            resourceTimeoutInterval > 0 {
            config.timeoutIntervalForResource = TimeInterval(resourceTimeoutInterval)
        }
        return URLSession(configuration: config)
    }
    
    open func getRequest(sdkKey:String) -> URLRequest? {
        let str = String(format: DefaultDatafileHandler.endPointStringFormat, sdkKey)
        guard let url = URL(string: str) else { return nil }
        
        var request = URLRequest(url: url)
        
        if let lastModified = dataStore.getItem(forKey: "OPTLastModified-" + sdkKey) {
            request.addValue(lastModified as! String, forHTTPHeaderField: "If-Modified-Since")
        }
        
        return request

    }
    
    open func getResponseData(sdkKey:String, response:HTTPURLResponse, url:URL?) -> Data? {
        if let url = url, let data = try? Data(contentsOf: url) {
            if let str = String(data: data, encoding: .utf8) {
                self.logger?.log(level: .debug, message: str)
            }
            self.saveDatafile(sdkKey: sdkKey, dataFile: data)
            if let lastModified = response.allHeaderFields["Last-Modified"] {
                self.dataStore.saveItem(forKey: "OPTLastModified-" + sdkKey, value: lastModified)
            }
            
            return data
        }
        
        return nil
    }
    
    open func downloadDatafile(sdkKey: String,
                               resourceTimeoutInterval:Double? = nil,
                               completionHandler: @escaping DatafileDownloadCompletionHandler) {
        
        downloadQueue.async {
            let session = self.getSession(resourceTimeoutInterval: resourceTimeoutInterval)
            
            guard let request = self.getRequest(sdkKey: sdkKey) else { return }
            
            let task = session.downloadTask(with: request) { (url, response, error) in
                var result = Result<Data?, DatafileDownloadError>.failure(DatafileDownloadError(description: "Failed to parse"))
                
                if let _ = error {
                    self.logger?.log(level: .error, message: error.debugDescription)
                    let datafiledownloadError = DatafileDownloadError(description: error.debugDescription)
                    result = Result.failure(datafiledownloadError)
                }
                else if let response = response as? HTTPURLResponse {
                    if response.statusCode == 200 {
                        let data = self.getResponseData(sdkKey: sdkKey, response: response, url: url)
                        result = Result.success(data)
                    }
                    else if response.statusCode == 304 {
                        self.logger?.log(level: .debug, message: "The datafile was not modified and won't be downloaded again")
                        result = .success(nil)
                    }
                }
                
                completionHandler(result)
                
//                self.logger?.log(level: .debug, message: response.debugDescription)
                
            }
            
            task.resume()
        }
    }
    
    func startPeriodicUpdates(sdkKey: String, updateInterval: Int, datafileChangeNotification:((Data)->Void)?) {
        
        let now = Date()
        if #available(iOS 10.0, tvOS 10.0, *) {
            DispatchQueue.main.async {
                if let timer = self.timers.property?[sdkKey]?.timer, timer.isValid {
                    return
                }
                
                let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(updateInterval), repeats: false) { (timer) in
                    
                    self.performPerodicDownload(sdkKey: sdkKey,
                                                startTime: now,
                                                updateInterval: updateInterval,
                                                datafileChangeNotification: datafileChangeNotification)
                    
                    timer.invalidate()
                }
                self.timers.performAtomic(atomicOperation: { (timers) in
                    if let interval = timers[sdkKey]?.interval {
                        timers[sdkKey] = (timer,interval)
                    }
                    else {
                        timers[sdkKey] = (timer,updateInterval)
                    }
                })
            }
        } else {
            // Fallback on earlier versions
            DispatchQueue.main.async {
                if let timer = self.timers.property?[sdkKey]?.timer, timer.isValid {
                    return
                }

                let timer = Timer.scheduledTimer(timeInterval: TimeInterval(updateInterval), target: self, selector:#selector(self.timerFired(timer:)), userInfo: ["sdkKey": sdkKey, "startTime": Date(), "updateInterval":  updateInterval, "datafileChangeNotification":datafileChangeNotification ?? { (data) in }], repeats: false)
                
                self.timers.performAtomic(atomicOperation: { (timers) in
                    if let interval = timers[sdkKey]?.interval {
                        timers[sdkKey] = (timer,interval)
                    }
                    else {
                        timers[sdkKey] = (timer,updateInterval)
                    }
                })
            }

        }
    }
    
    @objc
    func timerFired(timer:Timer) {
        if let info = timer.userInfo as? [String:Any],
            let sdkKey = info["sdkKey"] as? String,
            let updateInterval = info["updateInterval"] as? Int,
            let startDate = info["startTime"] as? Date,
            let datafileChangeNotification = info["datafileChangeNotification"] as? ((Data)->Void){
            self.performPerodicDownload(sdkKey: sdkKey, startTime: startDate, updateInterval: updateInterval, datafileChangeNotification: datafileChangeNotification)
        }
        timer.invalidate()

    }
    
    func hasPeriodUpdates(sdkKey: String) -> Bool {
        var restart = true
        self.timers.performAtomic(atomicOperation: { (timers) in
            if !timers.contains(where: { $0.key == sdkKey} ) {
                restart = false
            }
        })
        
        return restart
    }
    
    func performPerodicDownload(sdkKey: String,
                                startTime:Date,
                                updateInterval:Int,
                                datafileChangeNotification:((Data)->Void)?) {
        self.downloadDatafile(sdkKey: sdkKey) { (result) in
            switch result {
            case .success(let data):
                if let data = data,
                    let datafileChangeNotification = datafileChangeNotification {
                    datafileChangeNotification(data)
                }
            case .failure(let error):
                self.logger?.log(level: .error, message: error.localizedDescription)
            }
            
            if self.hasPeriodUpdates(sdkKey: sdkKey) {
                let interval = self.timers.property?[sdkKey]?.interval ?? updateInterval
                let actualDiff = (Int(abs(startTime.timeIntervalSinceNow)) - updateInterval)
                var nextInterval = interval
                if actualDiff > 0 {
                    nextInterval -= actualDiff
                }
                
                self.logger?.d("next datafile download is \(nextInterval) seconds \(Date())")
                self.startPeriodicUpdates(sdkKey: sdkKey, updateInterval: nextInterval, datafileChangeNotification: datafileChangeNotification)
            }
        }
    }
    
    func stopPeriodicUpdates(sdkKey: String) {
        timers.performAtomic { (timers) in
            if let timer = timers[sdkKey] {
                logger?.log(level: .info, message: "Stopping timer for datafile updates sdkKey: \(sdkKey)")
                
                timer.timer.invalidate()
                timers.removeValue(forKey: sdkKey)
            }

        }
    }
    
    func stopPeriodicUpdates() {
        for key in timers.property?.keys ?? Dictionary<String, (timer: Timer, interval: Int)>().keys {
            logger?.log(level: .info, message: "Stopping timer for all datafile updates")
            stopPeriodicUpdates(sdkKey: key)
        }
        
    }

    
    func saveDatafile(sdkKey: String, dataFile: Data) {
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            
            let fileURL = dir.appendingPathComponent(sdkKey, isDirectory: false)
            
            //writing
            do {
                try dataFile.write(to: fileURL, options: .atomic)
            }
            catch {/* error handling here */
                logger?.log(level: .error, message: "Problem saving datafile for key " + sdkKey)
            }
        }
    }
    
    func loadSavedDatafile(sdkKey: String) -> Data? {
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            
            let fileURL = dir.appendingPathComponent(sdkKey)
            
            //reading
            do {
                let data = try Data(contentsOf: fileURL)
                return data
            }
            catch {/* error handling here */
                logger?.log(level: .error, message: "Problem loading datafile for key " + sdkKey)
            }
        }
        
        return nil
    }
    
    func isDatafileSaved(sdkKey: String) -> Bool {
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = dir.appendingPathComponent(sdkKey)
            return FileManager.default.fileExists(atPath:fileURL.path)
        }
        
        return false
    }
    
    func removeSavedDatafile(sdkKey: String) {
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = dir.appendingPathComponent(sdkKey)
            if FileManager.default.fileExists(atPath:fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

    }
}
