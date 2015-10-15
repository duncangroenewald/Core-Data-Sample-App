//
//  CoreDataStackManager.swift
//
//  Created by Duncan Groenewald on 3/10/2014.
//  Copyright (c) 2014 OSSH Pty Ltd. All rights reserved.
//
// Abstract:
//
// Singleton controller to manage the main Core Data stack for the application. It
// vends a persistent store coordinator, and for convenience the managed object model
// and URL for the persistent store and application documents directory.
//
// Usage:
//
// 1. Call CoreDataStackManager.setVersion() to set the version in the Settings Bundle
//    This will show up in the iOS Settings App
//
// 2. Call CoreDataStackManager.checkCDModelVersion() to check if an upgrade is required
//    and if one is required the display the appropriate UI to the user to allow them
//    to perform the upgrade.  Note that an upgrade will first copy any iCloud file
//    to a local store before upgrading - because of issues with upgrading iCloud files
//
// 3. Register for store notifications
//
// 4. Call CoreDataStackManager.checkUserPreferenceAndSetupIfNecessary() to open the store and wait
//    for a store opened notification before enabling the UI or trying to access Core Data
// 5. Best to always check if cdManager.managedObjectContext != nil using
//    if let moc = cdManager.managedObjectContext {...} just in case things are not initialised
//    yet


import CoreData

#if os(iOS)
    import UIKit
    #else
    import Cocoa
#endif

var logLevel: Int = 0   // 0 = All, 5 = >=5

func FLOG(message:String, file: String = __FILE__, method: String = __FUNCTION__, line: Int = __LINE__) {
    if (logLevel > 0) {
        return
    }
    let date = FormatDate(NSDate())
    
    NSOperationQueue.mainQueue().addOperationWithBlock {
        
        // Get the filename only
        let url:NSURL = NSURL(fileURLWithPath: file)
        let filename = url.URLByDeletingPathExtension!.lastPathComponent
        
        print("\(date): \(filename).\(method)[\(line)]: \(message)", separator: "", terminator: "\r\n")
        
        return;
    }
    
}
func FLOG(level: Int = 0, message:String, file: String = __FILE__, method: String = __FUNCTION__, line: Int = __LINE__) {
    if (level > logLevel) {
        return
    }
    let date = FormatDate(NSDate())
    
    NSOperationQueue.mainQueue().addOperationWithBlock {
        
        // Get the filename only
        let url:NSURL = NSURL(fileURLWithPath: file)
        let filename = url.URLByDeletingPathExtension!.lastPathComponent
        
        print("\(date): \(filename).\(method)[\(line)]: \(message)", separator: "", terminator: "\r\n")
        
        return;
    }
    
}
func FormatDate(date:NSDate) -> String {
    let dateFormatter = NSDateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd h:mm:ss.SSS"
    return dateFormatter.stringFromDate(date)
}
func assert(@autoclosure condition: () -> Bool, message: String = "",
    file: String = __FILE__, line: Int = __LINE__) {
        #if DEBUG
            if !condition() {
                println("assertion failed at \(file):\(line): \(message)")
                abort()
            }
        #endif
}
func logAndAssert(@autoclosure condition: () -> Bool, message: String = "",
    file: String = __FILE__, line: Int = __LINE__) {
        
        print(message)
        assert(condition, message: message, file: file, line: line)
}

struct CDConstants {
    static let ICloudStateUpdatedNotification = "ICloudStateUpdatedNotification"
    
    static let OSFileDeletedNotification = "OSFileDeletedNotification"
    static let OSFileCreatedNotification = "OSFileCreatedNotification"
    static let OSFileClosedNotification = "OSFileClosedNotification"
    static let OSFilesUpdatedNotification = "OSFilesUpdatedNotification"
    static let OSDataUpdatedNotification = "OSCoreDataUpdated"
    static let OSStoreChangeNotification = "OSCoreDataStoreChanged"
    static let OSJobStartedNotification = "OSBackgroundJobStarted"
    static let OSJobDoneNotification = "OSBackgroundJobCompleted"
    
    static let OSModelCheckedNotification = "OSModelCheckedNotification"
    static let OSStoreOpenedNotification = "OSStoreOpenedNotification"
    
    static let KeepStore:Int =    0
    static let MoveStore:Int =    1
    static let DeleteStore:Int =  2
}

class CoreDataStackManager: NSObject {
    // MARK: Types
    
    private struct Constants {
        static let applicationDocumentsDirectoryName = "au.com.ossh.Info2"
        static let iCloudContainerID = "iCloud.au.com.ossh.iWallet2"
        static let errorDomain = "CoreDataStackManager"
        static let modelName = "Info2"
        static let persistentStoreName = "persistentStore"
        static let iCloudPersistentStoreName = "persistentStore_ICLOUD"
        static let storefileExtension = "iwallet_sqlite"
        static let iCloudPreferenceKey = "au.com.ossh.Info2.UseICloudStorage"
        static let iCloudPreferenceSelected = "au.com.ossh.Info2.iCloudStoragePreferenceSelected" // Records whether user has actually selected a preference
        static let makeBackupPreferenceKey = "au.com.ossh.Info2.MakeBackup"
        static let iCloudStoreFilenameKey = "au.com.ossh.Info2.iCloudStoreFileName"
        static let ubiquityContainerKey = "au.com.ossh.Info2.ubiquityContainerID"
        static let ubiquityTokenKey = "au.com.ossh.Info2.ubiquityToken"
        static let timerPeriod: NSTimeInterval = 2.0
    }
    
    // MARK: Properties
    
    class var sharedManager: CoreDataStackManager {
        struct Singleton {
            static let coreDataStackManager = CoreDataStackManager()
        }
        
        return Singleton.coreDataStackManager
    }
    
    
    var ubiquityContainerID: NSString? = Constants.iCloudContainerID
    var isOpening: Bool = false
    var persistentStoreCoordinator: NSPersistentStoreCoordinator? = nil
    var storeURL: NSURL? = nil
    
    var sourceModel: NSManagedObjectModel? = nil
    var query: NSMetadataQuery? = nil
    
    var useICloudStorage: Bool = false
    
    var storesChanging: Bool = false
    
    var import_or_save: Bool = false
    
    var icloud_file_exists: Bool = false
    var isDownloadingBackup: Bool = false
    var icloud_files_synced: Bool = false
    var has_checked_cloud: Bool = false
    var rebuild_from_icloud: Bool = false
    var isUpgrading: Bool = false
    var has_just_migrated: Bool = false
    var load_seed_data: Bool = false
    var deleteICloudFiles: Bool = false
    
    var isICloudEnabled: Bool = false
    var isFirstInstall: Bool = false
    
    var isFirstMetadataQueryDone: Bool = false
    
    var icloud_container_available: Bool = false
    
    var iCloudBackupFileList = [FileRepresentation]()
    var iCloudUpdateTimer: NSTimer? = nil
    
    
    // MARK: - Core Data stack
    
    // The directory the application uses to store the Core Data store file. This code uses a directory named "au.com.ossh.Info2" in the application's  Application Support directory.
    // We should not store this in the app /Documents directory because it will be backed up
    lazy var applicationDocumentsDirectory: NSURL = {
        
        let urls = NSFileManager.defaultManager().URLsForDirectory(.DocumentDirectory, inDomains: .UserDomainMask)
        
        let url = urls[urls.count-1] as NSURL
        
        #if os(iOS)
            return url
            #else
            return url.URLByAppendingPathComponent(Constants.applicationDocumentsDirectoryName)
        #endif
        }()
    
    lazy var managedObjectModel: NSManagedObjectModel = {
        // The managed object model for the application. This property is not optional. It is a fatal error for the application not to be able to find and load its model.
        if let modelURL = NSBundle.mainBundle().URLForResource(Constants.modelName, withExtension: "momd") {
            return NSManagedObjectModel(contentsOfURL: modelURL)!
        } else {
            fatalError("Unable to find Core Data model")
        }
        }()
    
    lazy var managedObjectContext: NSManagedObjectContext? = {
        // Returns the managed object context for the application (which is already bound to the persistent store coordinator for the application.) This property is optional since there are legitimate error conditions that could cause the creation of the context to fail.
        let coordinator = self.persistentStoreCoordinator
        if coordinator == nil {
            FLOG(5, message: " Error getting managedObjectContext because persistentStoreCoordinator is nil")
            return nil
        }
        var managedObjectContext = NSManagedObjectContext(concurrencyType: NSManagedObjectContextConcurrencyType.MainQueueConcurrencyType)
        managedObjectContext.persistentStoreCoordinator = coordinator
        
        // Set the MergePolicy to prioritise external inputs
        let mergePolicy = NSMergePolicy(mergeType:NSMergePolicyType.MergeByPropertyStoreTrumpMergePolicyType )
        managedObjectContext.mergePolicy = mergePolicy
        
        return managedObjectContext
        }()
    
    
    // MARK: - Core Data Saving support
    
    func saveContext () {
        if let moc = managedObjectContext {
            
            if moc.hasChanges {
                do {
                    try moc.save()
                    
                    
                } catch  {
                    //FLOG(5, message: "Unresolved error \(error), \(error!.userInfo)")
                    // Probably need a message to the user warning that a save failed!
                    
                }
            }
        }
    }
    // Checks if the file is iCloud or Local and returns the required options
    func storeOptions()->NSDictionary {
        
        if let url: NSURL = storeURL {
            if let string: NSString = url.URLByDeletingPathExtension?.lastPathComponent {
                // If it's an iCloud file
                if (string.rangeOfString("_ICLOUD").location != NSNotFound) {
                    return iCloudStoreOptions()
                } else {
                    return localStoreOptions()
                }
            }
        }
        return localStoreOptions()
    }
    
    /*! Checks for the existence of any documents without _UUID_ in the filename.  These documents are local documents only.  Returns YES if any are found.
    
    @return Returns YES of any documents are found or NO if none are found.
    */
    func localStoreExists() -> Bool {
        
        FLOG(5, message: "localStoreExists called")
        let exists = "exists"
        let doesnotexist = "does not exist"
        var isDir: ObjCBool = false
        
        
        let url = localStoreURL()
        FLOG(5, message: "localStore url is \(url)")
        
        if let path = url.path {
            
            let fileExists: Bool = NSFileManager.defaultManager().fileExistsAtPath(path, isDirectory: &isDir)
            
            
            FLOG(5, message: "  localStoreURL \(fileExists ? exists : doesnotexist)")
            
            
            return fileExists
            
        } else {
            
            return false
            
        }
        
        
    }
    /// Checks whether the user has saved a storage preference
    /// Note that the function first checks whether the user has actually selected a choice previously
    /// and if not then assumes the users iCloud choice is false.  If they have then simply return the
    /// users choice.
    ///
    var userICloudChoice: Bool = {
        
        var userDefaults: NSUserDefaults = NSUserDefaults.standardUserDefaults()
        
        userDefaults.synchronize()
        
        var userICloudChoiceSet: NSString? = userDefaults.stringForKey(Constants.iCloudPreferenceKey)
        
        var userICloudChoice: Bool = userDefaults.boolForKey(Constants.iCloudPreferenceSelected)
        
        // Call it twice as sometimes it returns an incorrect value the first time (synch issue maybe?)
        userICloudChoice = userDefaults.boolForKey(Constants.iCloudPreferenceKey)
        
        // If the user has never selected a preference then assume they have not selected iCloud so
        // return false
        if (userICloudChoiceSet?.length  == 0) {
            return false
        }
        else {
            return userICloudChoice
        }
        
        }()
    
    /// Check the Core Data version to see if its compatible or if a lightweight migration is required
    /// If a lightweight migration is required then migrate the iCloud store and open it then migrate it back to iCloud
    
    /// @Return Returns YES if model needs to be upgraded and NO if not
    func checkCDModelVersion() -> Bool {
        FLOG(5, message: " called")
        
        createFileQuery()
        
        let fileManager: NSFileManager = NSFileManager.defaultManager()
        
        let model: NSManagedObjectModel = managedObjectModel
        
        //FLOG(5, message: " app model is \(model)")
        
        //FLOG(5, message: " app model entity version hashes are \(model.entityVersionHashesByName)")
        
        let userDefaults: NSUserDefaults = NSUserDefaults.standardUserDefaults()
        
        // If user has selected iCloud
        //
        if (userICloudChoice) {
            FLOG(5, message: " userICloudChoice is true")
            
            // First find the store file - and there seems to be no easy way to determine what this filename is.
            // The only reliable way is to open it with the old version of the model (to ensure Core Data does not
            // start the upgrade !  The other way is to try and figure out how Core Data builds the path.
            
            let storeURL: NSURL? = userDefaults.URLForKey(Constants.iCloudStoreFilenameKey)
            
            // Make sure the store URL, path and file exist
            if let url = storeURL {
                
                FLOG(5, message: " iCloud storeURL is \(url)")
                
                if let path = url.path {
                    
                    if (fileManager.fileExistsAtPath(path)) {
                        
                        FLOG(5, message: " file exists :-)")
                        
                    }
                    else {
                        
                        FLOG(5, message: " file does not exist :-(")
                        return false
                    }
                } else {
                    
                    FLOG(5, message: " path  is nil")
                    return false
                }
                
            } else {
                
                FLOG(5, message: " storeURL is nil")
                return false
                
            }
            
            do {
                
                let metaData: NSDictionary = try NSPersistentStoreCoordinator.metadataForPersistentStoreOfType(NSSQLiteStoreType, URL: storeURL!)
                
                let result: Bool = model.isConfiguration(nil, compatibleWithStoreMetadata: metaData as! [String : AnyObject] )
                
                if (result) {
                    FLOG(5, message: " file is compatible with current Core Data model!")
                    return false
                    
                } else {
                    FLOG(5, message: " file is not compatible with current Core Data model!")
                    FLOG(5, message: " metadata is \(metaData)")
                    
                    sourceModel = NSManagedObjectModel.mergedModelFromBundles([NSBundle.mainBundle()], forStoreMetadata: metaData as! [String : AnyObject])
                    
                    FLOG(5, message: " source model is \(sourceModel)")
                    
                    return true
                }
                
            } catch  {
                FLOG(5, message: " problem getting metaData")
                
                return false
            }
            
            
        } else {
            FLOG(5, message: " userICloudChoice is false")
            
            // User has not selected iCloud
            // Check if local store exists and check the version
            if (localStoreExists()) {
                
                // First find the store file - and there seems to be no easy way to determine what this filename is.
                // The only reliable way is to open it with the old version of the model (to ensure Core Data does not
                // start the upgrade !  The other way is to try and figure out how Core Data builds the path.
                
                
                let storeURL: NSURL? = localStoreURL()
                
                
                // Make sure the store URL, path and file exist
                if let url = storeURL {
                    
                    FLOG(5, message: " storeURL is \(url)")
                    
                    if let path = url.path {
                        
                        FLOG(5, message: " storeURL.path is \(path)")
                        
                        if (fileManager.fileExistsAtPath(path)) {
                            
                            FLOG(5, message: " file exists :-)")
                            
                        }
                        else {
                            
                            FLOG(5, message: " file does not exist :-(")
                            return false
                        }
                    } else {
                        
                        FLOG(5, message: " path  is nil")
                        return false
                    }
                    
                } else {
                    
                    FLOG(5, message: " storeURL is nil")
                    return false
                    
                }
                
                
                
                
                do {
                    let metaData: NSDictionary = try NSPersistentStoreCoordinator.metadataForPersistentStoreOfType(NSSQLiteStoreType, URL:storeURL!)
                    
                    let result: Bool = model.isConfiguration(nil, compatibleWithStoreMetadata:metaData as! [String : AnyObject])
                    
                    if (result) {
                        FLOG(5, message: " file is compatible!")
                        
                        return false
                    } else {
                        FLOG(5, message: " file is not compatible!")
                        //FLOG(5, message: " metadata is %@", metaData)
                        sourceModel = NSManagedObjectModel.mergedModelFromBundles([NSBundle.mainBundle()], forStoreMetadata:metaData as! [String : AnyObject])
                        return true
                    }
                    
                } catch  {
                    FLOG(5, message: " Failed to get metaData for \(storeURL!)")
                    
                    return false
                }
                
            }
            else { // No local store exists so no upgrade required - first time maybe?
                FLOG(5, message: " No local store exists so can't check the version")
                return false
            }
        }
    }
    /// Creates a metadataQuery to get the list of iCloud files
    /// If iCloud is not enabled then the query will not be started
    /// The Query returns data asynchronously by calling a callback
    func createFileQuery() {
        FLOG(5, message: " called")
        
        if (NSThread.isMainThread()) {
            
            self.createMetadataQuery()
            
        } else {
            
            // Bounce back to the main queue to reload the table view and reenable the fetch button.
            NSOperationQueue.mainQueue().addOperationWithBlock {
                self.createMetadataQuery()
            }
            
        }
    }
    
    ///  Creates and starts a metadata query for iCloud files and creates and observer for changes
    ///  which calls fileListReceived()
    func createMetadataQuery() {
        FLOG(5, message: " called.")
        
        var startedQuery: Bool = false
        
        if (query != nil) {
            FLOG(5, message: "  query already running")
            query!.stopQuery()
            return
        }
        
        // Bug workaround - not a bug - we MUST make this call first to ensure things are initialised but
        // we should only do so on  background thread !
        //DG This call needs to be moved to a background thread !
        let urlUC = NSFileManager.defaultManager().URLForUbiquityContainerIdentifier((ubiquityContainerID as! String));
        
        
        // Check if iCloud is enabled
        if let currentToken:AnyObject = NSFileManager.defaultManager().ubiquityIdentityToken {
            
            //FLOG(5, message: "  currentUbiquityIdentityToken is \(currentToken)")
            
            if let qry = query {
                
                FLOG(5, message: "  starting iCloud metadata query")
                startedQuery = qry.startQuery()
                
                if (startedQuery) {
                    FLOG(5, message: "  query started")
                } else {
                    FLOG(5, message: "  query not started !!")
                }
                
            }
            else {
                FLOG(5, message: "  Creating metadata query")
                
                query = NSMetadataQuery()
                
                query!.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope, NSMetadataQueryUbiquitousDataScope]
                
                let str: NSString = "*"
                
                query!.predicate = NSPredicate.init(format: "%K LIKE %@", argumentArray: [NSMetadataItemFSNameKey, str])
                
                let notificationCenter: NSNotificationCenter = NSNotificationCenter.defaultCenter()
                
                /*
                [notificationCenter addObserver:self selector:@selector(fileListReceived) name:NSMetadataQueryDidFinishGatheringNotification object:_query];
                
                [notificationCenter addObserver:self selector:@selector(fileListReceived) name:NSMetadataQueryDidUpdateNotification object:_query];
                */
                // Background queue for processing notifications
                notificationCenter.addObserverForName(NSMetadataQueryDidFinishGatheringNotification, object: query!, queue: NSOperationQueue(), usingBlock: { notification in
                    // disable the query while iterating
                    self.query!.disableUpdates()
                    self.fileListReceivedInitial()
                    //DG: self.fileListReceived()
                    self.query!.enableUpdates()
                    self.postModelCheckedNotification()
                })
                
                
                notificationCenter.addObserverForName(NSMetadataQueryDidUpdateNotification, object:query!, queue:NSOperationQueue(),
                    usingBlock: { notification in
                        // disable the query while iterating
                        self.query!.disableUpdates()
                        self.fileListReceived()
                        self.query!.enableUpdates()
                })
                
                FLOG(5, message: "  starting iCloud metadata query")
                startedQuery = query!.startQuery()
                if (startedQuery) {
                    FLOG(5, message: "  query started")
                } else {
                    FLOG(5, message: "  query not started !!")
                }
            }
            
        } else {
            FLOG(5, message: "Can't start a metaDataQuery because iCloud is not enabled or available")
        }
    }
    /// Extracts the name of the saving computer from the files NSFileVersion information
    ///
    /// Returns: a string cintaining the name of the computer that last saved the file
    func nameOfSavingComputer(fileURL: NSURL)->NSString {
        
        if let openedVersion: NSFileVersion = NSFileVersion.currentVersionOfItemAtURL(fileURL) {
            
            if let name = openedVersion.localizedNameOfSavingComputer {
                return name
            }
            
        }
        
        return ""
        
    }
    /// Sets a flag after having received the first query result
    func fileListReceivedInitial() {
        FLOG(3, message: " called.")
        
        if (NSThread.isMainThread())
        {
            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
                
                self.processFiles()
                self.isFirstMetadataQueryDone = true
                
                self.reportFirstQuery()
            })
            
            
        } else {
            FLOG(3, message: " called on background thread")
            self.processFiles()
            self.isFirstMetadataQueryDone = true
            self.reportFirstQuery()
        }
    }
    func reportFirstQuery(){
        FLOG(3, message: "First MetadataQuery has completed")
        FLOG(3, message: " isFirstMetadataQueryDone = \(self.isFirstMetadataQueryDone)")
        FLOG(3, message: " has_checked_cloud = \(self.has_checked_cloud)")
        FLOG(3, message: " icloud_file_exists = \(self.icloud_file_exists)")
    }
    /*! Gets called by the metadata query any time files change.  We need to be able to flag files that
    we have created so as to not think it has been deleted from iCloud.
    
    */
    func fileListReceived() {
        FLOG(3, message: " called.")
        
        if (NSThread.isMainThread())
        {
            FLOG(5, message: " called on main thread")
            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
                
                self.processFiles()
                
            })
            
            
        } else {
            //FLOG(5, message: " called on background thread");
            processFiles()
        }
        
        
    }
    
    func postFileUpdateNotification() {
        NSOperationQueue.mainQueue().addOperationWithBlock( {
            NSNotificationCenter.defaultCenter().postNotificationName(CDConstants.OSFilesUpdatedNotification,
                object:self)
        })
    }
    /// Check whether any iCloud files have changed
    /// Posts notification if new or changed files are detected
    func processFiles() {
        
        let lockQueue = dispatch_queue_create("au.com.ossh.LockQueue", DISPATCH_QUEUE_SERIAL)
        
        dispatch_sync(lockQueue) {
            
            FLOG(3, message: " called.")
            
            var notDownloaded: Bool = false
            var notUploaded: Bool = false
            var downloadingBackup: Bool = false
            var fileCount: Int32 = 0
            
            // Create a new array
            var newICloudFiles = [FileRepresentation]()
            
            //DG: self.iCloudBackupFileList.removeAll(keepCapacity: false)
            
            // Set flag
            self.icloud_file_exists = false
            
            if let queryResults = self.query?.results {
                
                for result in queryResults {
                    
                    if let mdi: NSMetadataItem = result as? NSMetadataItem {
                        
                        let fileURL: NSURL? = mdi.valueForAttribute(NSMetadataItemURLKey) as? NSURL
                        let filename: NSString? = mdi.valueForAttribute(NSMetadataItemDisplayNameKey) as? NSString
                        let downloadStatus: NSString? = mdi.valueForAttribute(NSMetadataUbiquitousItemDownloadingStatusKey) as! NSString!
                        
                        let isUploaded: NSNumber? = mdi.valueForAttribute(NSMetadataUbiquitousItemIsUploadedKey) as! NSNumber!
                        
                        let isDownloading: NSNumber? = mdi.valueForAttribute(NSMetadataUbiquitousItemIsDownloadingKey) as! NSNumber!
                        
                        let downloadPercent: NSNumber? = mdi.valueForAttribute(NSMetadataUbiquitousItemPercentDownloadedKey) as! NSNumber!
                        
                        
                        let storeFileString: NSString = "/CoreData/" + Constants.iCloudPersistentStoreName
                        
                        
                        if let url = fileURL {
                            
                            if let path: NSString = url.path {
                                
                                
                                
                                FLOG(5, message: " file \(path.lastPathComponent) found")
                                
                                
                                // Find the store file
                                if path.rangeOfString(storeFileString as String).location != NSNotFound {
                                    
                                    fileCount++
                                    
                                    
                                    if let v = downloadStatus {
                                        if (!v.isEqualToString(NSMetadataUbiquitousItemDownloadingStatusCurrent))
                                        {
                                            notDownloaded = true
                                            
                                            FLOG(5, message: " iCloud file \(filename) not downloaded")
                                            
                                        }
                                        if (v.isEqualToString(NSMetadataUbiquitousItemDownloadingStatusCurrent)) {
                                            self.icloud_file_exists = true
                                            
                                            FLOG(5, message: " iCloud file \(filename) exists")
                                            
                                        }
                                    }
                                    
                                    if let v = isUploaded {
                                        if (!v.boolValue){
                                            notUploaded = true
                                            //FLOG(5, message: " iCloud file \(filename) not uploaded")
                                        }
                                    }
                                    
                                }
                                
                                if path.rangeOfString("_Backup_").location != NSNotFound {
                                    if let fn = filename {
                                        let file: FileRepresentation = FileRepresentation.init(filename: fn, url:url, percentDownloaded:downloadPercent, computer:self.nameOfSavingComputer(url))
                                        
                                        //FLOG(5, message: "Backup file found: \(path)")
                                        //FLOG(5, message: "Backup file found: \(filename)")
                                        
                                        if let d = downloadStatus {
                                            file.isDownloaded = (d.isEqualToString(NSMetadataUbiquitousItemDownloadingStatusDownloaded) || d.isEqualToString(NSMetadataUbiquitousItemDownloadingStatusCurrent))
                                            
                                        } else {
                                            file.isDownloaded = 0
                                        }
                                        file.isDownloading = isDownloading
                                        file.downloadStatus = downloadStatus
                                        
                                        //self.iCloudBackupFileList.append(file)
                                        newICloudFiles.append(file)
                                        
                                        if let v = isDownloading {
                                            if (v.boolValue) {
                                                downloadingBackup = true
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // After processing all files check if any are still downloading and
            // if not then stop the background indicator
            if (self.isDownloadingBackup) {
                if (!downloadingBackup) {
                    self.showBackgroundTaskInactive()
                    self.isDownloadingBackup = false
                }
            }
            
            // Now sort the backup file list
            self.iCloudBackupFileList.sortInPlace {
                let file1: FileRepresentation = $0 as FileRepresentation
                let file2: FileRepresentation = $1 as FileRepresentation
                
                
                if let path1 = file1.url?.path {
                    
                    if let path2 = file2.url?.path {
                        
                        return (path1.caseInsensitiveCompare(path2) == NSComparisonResult.OrderedAscending)
                    }
                }
                return true
            }
            
            // Now check if there are any changes
            let fc = self.iCloudBackupFileList.count
            let nc = newICloudFiles.count
            var filesChanged = false
            
            // If we have the same count
            if fc == nc {
                for var i: Int = 0; i < fc; i++ {
                    let a = self.iCloudBackupFileList[i]
                    let b = newICloudFiles[i]
                    
                    if a.filename != b.filename || a.fileDate != b.fileDate {
                        filesChanged = true
                        break
                    }
                    
                }
            } else {
                filesChanged = true
            }
            
            // Now copy the files
            self.iCloudBackupFileList.removeAll(keepCapacity: true)
            self.iCloudBackupFileList.appendContentsOf(newICloudFiles)
            
            
            if filesChanged {
                FLOG(3, message: " Files have changed")
                // post a notification that files have been updated
                self.postFileUpdateNotification()
            } else {
                FLOG(3, message: " Files have not changed")
            }
            
            // If some files have not synced then start the Query again
            // otherwise we are done
            if (notDownloaded || notUploaded) {
                //FLOG(5, message: "Keep the query running because not all files are updated")
                if (self.icloud_files_synced) {
                    self.showBackgroundTaskActive()
                    self.icloud_files_synced = false
                }
            } else {
                if (fileCount > 0) {
                    FLOG(0, message: " all files CURRENT")
                    self.icloud_file_exists = true
                } else {
                    FLOG(0, message: "no iCloud files")
                }
                
                if (!self.icloud_files_synced) {
                    self.showBackgroundTaskInactive()
                    self.icloud_files_synced = true
                }
                //FLOG(5, message: "iCloud file " + (icloud_file_exists ? "exists" : "does not exist"))
                self.has_checked_cloud = true
            }
        }
        
    }
    
    func setVersion() {  // this function detects what is the CFBundle version of this application and set it in the settings bundle
        let defaults: NSUserDefaults = NSUserDefaults.standardUserDefaults()  // transfer the current version number into the defaults so that this correct value will be displayed when the user visit settings page later
        
        let version: NSString? = NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleShortVersionString") as? NSString
        
        let build: NSString? = NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleVersion") as? NSString
        
        defaults.setObject(version, forKey:"version")
        defaults.setObject(build, forKey:"build")
    }
    /// Get a list of iCloud backup documents
    ///
    ///:returns: NSArray of FileRepresentation objects
    func listAllICloudBackupDocuments()->NSArray {
        FLOG(3, message: " called")
        return iCloudBackupFileList
    }
    /*! Lists all BACKUP DOCUMENTS on a device in the local /Document directory. BACKUP DOCUMENTS are documents that have
    filenames with BACKUP appended to the filename
    
    @return Returns an array of local backup document URLs
    */
    func listAllLocalBackupDocuments()->NSArray {
        FLOG(3, message: " called")
        
        // Changing this to use applicationDocumentsDirectory
        let documentsDirectoryURL: NSURL = applicationDocumentsDirectory
        
        //FLOG(5, message: " documentsDirectoryURL = \(documentsDirectoryURL)")
        
        do {
            let docs = try NSFileManager.defaultManager().contentsOfDirectoryAtURL(documentsDirectoryURL, includingPropertiesForKeys:[NSURLCreationDateKey], options:NSDirectoryEnumerationOptions.SkipsHiddenFiles)
            
            
            let array: NSMutableArray = NSMutableArray()
            
            for document in docs {
                
                let url = document
                
                if let name: NSString = url.lastPathComponent {
                    //FLOG(5, message: " local file = \(name)")
                    
                    if (name.rangeOfString("Backup").location != NSNotFound && !name.isEqualToString(".DS_Store")) {
                        
                        //FLOG(5, message: " local backup file = \(name)")
                        
                        array.addObject(document as NSURL)
                        
                    }
                }
                
            }
            
            let sortNameDescriptor: NSSortDescriptor = NSSortDescriptor.init(key:"path", ascending: false)
            
            let sortDescriptors = [sortNameDescriptor]
            
            let sortedArray = array.sortedArrayUsingDescriptors(sortDescriptors)
            
            return sortedArray;
            
        } catch _ {
        }
        
        // Just return an empty array
        let array = NSArray()
        
        return array
    }
    
    /*! Returns the /Documents directory for the app
    
    @returns Returns the URL for the apps /Documents directory
    */
    func documentsDirectoryURL() -> NSURL?
    {
        let dataDirectoryURL = NSURL.fileURLWithPath(NSHomeDirectory(), isDirectory:true)
        
        let directory = dataDirectoryURL.URLByAppendingPathComponent("Documents")
        
        return directory
        
    }
    
    func createBackupWithCompletion(completion:(()->Void)?) {
        //FLOG(5, message: " called")
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
            
            // Some long running task you want on another thread
            self.showBackgroundTaskActive()
            self.backupCurrentStoreWithNoCheck()
            
            if (completion != nil) {
                NSOperationQueue.mainQueue().addOperationWithBlock {
                    completion!()
                }
            }
            self.showBackgroundTaskInactive()
        })
        
    }
    
    func backupCurrentStoreWithNoCheck()->Bool {
        FLOG(5, message: " called")
        sleep(1)
        
        if (userICloudChoice && iCloudStoreExists())
        {
            return backupICloudStore()
        } else
            if (!userICloudChoice && localStoreExists())
            {
                return backupLocalStore()
        }
        return false
    }
    
    func showBackgroundTaskActive() {
        FLOG(5, message: " called")
        //_job_counter++;
        //FLOG(@" _job_counter is %d", _job_counter);
        #if os(iOS)
            
            if (NSThread.isMainThread()) {
                UIApplication.sharedApplication().networkActivityIndicatorVisible = true
            } else {
                dispatch_async(dispatch_get_main_queue(), {
                    UIApplication.sharedApplication().networkActivityIndicatorVisible = true
                })
            }
            #else
            
        #endif
    }
    func showBackgroundTaskInactive() {
        //FLOG(5, message: " called");
        //_job_counter--;
        //if (_job_counter < 0) _job_counter = 0;
        //FLOG(@" _job_counter is %d", _job_counter);
        
        //if (_job_counter == 0) {
        #if os(iOS)
            
            if (NSThread.isMainThread()) {
                UIApplication.sharedApplication().networkActivityIndicatorVisible = false
            } else {
                dispatch_async(dispatch_get_main_queue(), {
                    UIApplication.sharedApplication().networkActivityIndicatorVisible = false
                })
            }
            #else
            
        #endif
        //}
    }
    
    /*! Checks for the existence of any documents with _UUID_ in the filename.  These documents are documents shared in
    iCloud.  Returns YES if any are found.
    
    @return Returns YES of any documents are found or NO if none are found.
    */
    func iCloudStoreExists()->Bool {
        FLOG(5, message: " called")
        
        // if iCloud container is not available just return NO
        if (!isICloudContainerAvailable()) {
            return false
        }
        
        //FLOG(5, message: " Checking if file exists in local ubiquity container");
        
        //DG Dont want to make this call from main thread!
        if let path = self.iCloudContainerURL()?.path {
            FLOG(5, message: "  icloudStoreURL is " + path)
            
            var isDir: Bool = false
            
            var fileExists: Bool = NSFileManager.defaultManager().fileExistsAtPath(path)
            FLOG(5, message: "  iCloudStoreURL " + (fileExists ? "exists" : "does not exist"))
            
        } else {
            FLOG(5, message: "  iCloudStoreURL is nil")
        }
        
        
        FLOG(5, message: " Now checking if file actually exists in iCloud (not up/downloaded yet perhaps)")
        // This may block for some time if a _query has not returned results yet
        let icloudFileExists: Bool = doesICloudFileExist()
        
        FLOG(5, message: "  icloud store " + (icloudFileExists ? "exists" : "does not exist"))
        
        return icloudFileExists
    }
    // This function returns true if the user is logged in to iCloud, otherwise
    // it return false
    func isICloudContainerAvailable()->Bool {
        if let _ = NSFileManager.defaultManager().ubiquityIdentityToken {
            return true
        }
        else {
            return false
        }
    }
    
    /*! Returns the CoreData persistent store's directory in the ubiquity container.  Note that Core Data
    creates a directory in the iCLoud container for each Core Data Store using the iCloud name given to
    createPersistentStore API
    
    @returns The URL for the CoreData directory in ubiquity container
    */
    func iCloudContainerURL()->NSURL? {
        
        //DG This call needs to be moved to a background thread !
        if let iCloudURL:NSURL = NSFileManager.defaultManager().URLForUbiquityContainerIdentifier(((ubiquityContainerID as! String))) {
            
            return iCloudURL.URLByAppendingPathComponent("CoreData").URLByAppendingPathComponent(Constants.iCloudPersistentStoreName)
        }
        else {
            return nil
        }
    }
    /*! Returns the CoreData directory in the ubiquity container.  Must not be called from main thread !
    
    @returns The URL for the CoreData directory in ubiquity container
    */
    func iCloudCoreDataURL()->NSURL? {
        //DG This call needs to be moved to a background thread !
        if let iCloudURL: NSURL = NSFileManager.defaultManager().URLForUbiquityContainerIdentifier((ubiquityContainerID as! String)) {
            return iCloudURL.URLByAppendingPathComponent("CoreData")
        }
        else
        {
            return nil
        }
    }
    func iCloudStoreURL()->NSURL {
        return applicationDocumentsDirectory.URLByAppendingPathComponent(Constants.iCloudPersistentStoreName).URLByAppendingPathExtension(Constants.storefileExtension)
    }
    func localStoreURL()->NSURL {
        let localUrl =  self.applicationDocumentsDirectory.URLByAppendingPathComponent(Constants.persistentStoreName).URLByAppendingPathExtension(Constants.storefileExtension)
        
        // Check if it exists and create it if not otherwise Core Data will fail to create the store at this
        // URL
        createLocalStoreFolder(localUrl);
        
        return localUrl
    }
    
    
    /// Runs in a loop waiting for the metadataQuery to return some results
    /// The metadataQuery will set the has_check_cloud flag
    ///
    func doesICloudFileExist()->Bool {
        FLOG(5, message: " called")
        
        #if os(iOS)
            var count: Int  = 0
            
            // Start with 10ms time boxes
            let ti: NSTimeInterval  = 2.0
            
            // Wait until delegate did callback
            while (!has_checked_cloud) {
                //FLOG(5, message: " has not checked iCloud yet, waiting")
                
                let date: NSDate = NSDate(timeIntervalSinceNow: ti)
                
                // Let the current run-loop do it's magif for one time-box.
                NSRunLoop.currentRunLoop().runMode(NSRunLoopCommonModes, beforeDate: date)
                
                // Double the time box, for next try, max out at 1000ms.
                //ti = MIN(1.0, ti * 2);
                count++
                if (count>10) {
                    //FLOG(5, message: " given up waiting");
                    has_checked_cloud = true
                    icloud_file_exists = true
                }
                
            }
            
            if (has_checked_cloud) {
                if (icloud_file_exists) {
                    //FLOG(5, message: " has checked iCloud, file exists");
                    has_checked_cloud = false
                    return true
                } else {
                    //FLOG(5, message: " has checked iCloud, file does not exist");
                    has_checked_cloud = false
                    return false
                }
            } else {
                //FLOG(5, message: " ERROR: has not checked iCloud yet");
                return false
            }
            #else
            return self.icloud_file_exists
        #endif
    }
    
    // Returns the local store options
    func localStoreOptions()->NSDictionary {
        return [NSMigratePersistentStoresAutomaticallyOption:true,
            NSInferMappingModelAutomaticallyOption:true,
            NSSQLitePragmasOption:["journal_mode" : "DELETE"]]
    }
    
    // Returns the iCloud store options
    func iCloudStoreOptions()->NSDictionary {
        
        let iCloudFilename: NSString = Constants.iCloudPersistentStoreName
        
        var options: NSDictionary
        
        if (rebuild_from_icloud) {
            options = [NSPersistentStoreUbiquitousContentNameKey:iCloudFilename,
                NSPersistentStoreRebuildFromUbiquitousContentOption:true,
                NSMigratePersistentStoresAutomaticallyOption:true,
                NSInferMappingModelAutomaticallyOption:true,
                NSSQLitePragmasOption:["journal_mode" : "DELETE" ]]
            rebuild_from_icloud = false
        } else {
            options = [NSPersistentStoreUbiquitousContentNameKey:iCloudFilename,
                NSMigratePersistentStoresAutomaticallyOption:true,
                NSInferMappingModelAutomaticallyOption:true,
                NSSQLitePragmasOption:["journal_mode" : "DELETE" ]]
        }
        
        return options
    }
    /*! Creates a backup of the Local store
    
    @return Returns YES of file was migrated or NO if not.
    */
    func backupLocalStore()->Bool {
        FLOG(5, message: "backupLocalStore called")
        
        // Lets use the existing PSC
        let migrationPSC: NSPersistentStoreCoordinator  = NSPersistentStoreCoordinator(managedObjectModel: managedObjectModel)
        
        
        // Open the store
        do {
            let sourceStore: NSPersistentStore = try migrationPSC.addPersistentStoreWithType(NSSQLiteStoreType, configuration: nil, URL: localStoreURL(), options: (localStoreOptions() as [NSObject : AnyObject]))
            
            
            FLOG(5, message: " Successfully added store to migrate")
            
            FLOG(5, message: " About to migrate the store...")
            let migratedStore: NSPersistentStore?
            do {
                migratedStore = try migrationPSC.migratePersistentStore(sourceStore, toURL:backupStoreURL(), options:(localStoreOptions() as [NSObject : AnyObject]), withType:NSSQLiteStoreType)
            } catch {
                
                migratedStore = nil
            }
            
            if (migratedStore != nil) {
                FLOG(5, message: "store successfully backed up")
                // GD migrationPSC = nil
                // Now reset the backup preference
                NSUserDefaults.standardUserDefaults().setBool(false, forKey:Constants.makeBackupPreferenceKey)
                NSUserDefaults.standardUserDefaults().synchronize()
                
                return true
            }
            else {
                FLOG(5, message: "Failed to backup store)")
            }
        } catch  {
            FLOG(5, message: "Failed to backup store)")
            
        }
        return false
    }
    /*! Creates a backup of the ICloud store
    @return Returns YES of file was migrated or NO if not.
    */
    func backupICloudStore()->Bool {
        FLOG(5, message: "backupICloudStore called")
        
        // Lets use the existing PSC
        let migrationPSC: NSPersistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: managedObjectModel)
        
        // Open the store
        do {
            let sourceStore: NSPersistentStore = try migrationPSC.addPersistentStoreWithType(NSSQLiteStoreType, configuration:nil, URL: iCloudStoreURL(),
                options: iCloudStoreOptions() as [NSObject : AnyObject])
            
            FLOG(5, message: " Successfully added store to migrate")
            
            FLOG(5, message: " About to migrate the store...")
            let migratedStore: NSPersistentStore?
            do {
                migratedStore = try migrationPSC.migratePersistentStore(sourceStore, toURL:backupStoreURL(), options:localStoreOptions() as [NSObject : AnyObject], withType:NSSQLiteStoreType)
            } catch  {
                
                migratedStore = nil
            }
            
            if (migratedStore != nil) {
                FLOG(5, message: "store successfully backed up")
                
                // Now reset the backup preference
                NSUserDefaults.standardUserDefaults().setBool(false, forKey:Constants.makeBackupPreferenceKey)
                NSUserDefaults.standardUserDefaults().synchronize()
                return true
            }
            else {
                FLOG(5, message: "Failed to backup store")
                
                return false
            }
        } catch _ {
        }
        return false
    }
    
    func backupStoreURL()->NSURL {
        let dateFormatter: NSDateFormatter = NSDateFormatter()
        dateFormatter.dateFormat = "yyyyMMddHHmmssSSS"
        
        let dateString: String = dateFormatter.stringFromDate(NSDate())
        
        
        let fileName: NSString = Constants.persistentStoreName + "_Backup_" + dateString
        
        return applicationDocumentsDirectory.URLByAppendingPathComponent(fileName as String).URLByAppendingPathExtension(Constants.storefileExtension)
    }
    /// Create the local folder for storing the perstitent store file
    /// Core Data will fail unless this folder exists.
    ///
    func createLocalStoreFolder(url: NSURL) {
        
        let fileManager = NSFileManager.defaultManager()
        
        // Get the directory
        if let dirUrl = url.URLByDeletingLastPathComponent {
            
            //Check if it exists
            var isDir : ObjCBool = false
            if fileManager.fileExistsAtPath(dirUrl.path!, isDirectory:&isDir) {
                // Do nothing because it already exists
            } else {
                // file does not exist
                do {
                    try fileManager.createDirectoryAtURL(dirUrl, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    FLOG(5, message: "  ERROR creating the applications Core Data folder")
                }
            }
        }
    }
    /// Run through procedure to open a store
    /// 1.
    func openPersistentStore(completion:(()->Void)?) {
        FLOG(5, message: "  openPersistentStore called... XXXXXXXXXX XXX XXX XX XX X X")
        
        isOpening = true
        
        
        let aPersistentStoreCoordinator: NSPersistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: managedObjectModel)
        
        // Make sure we have a iCloud MetaData Query running
        self.createFileQuery()
        
        if (storeURL == nil) {
            FLOG(5, message: " error storeURL is nil!")
            return
        } else {
            if let url = self.storeURL {
                FLOG(5, message: " storeURL is \(url.path)")
            }
        }
        
        // Check if the store exists, if not then set _load_seed_data flag because this must be a first time
        if (!isUpgrading && !storeExists()) {
            FLOG(5, message: " STORE DOES NOT EXIST")
            if (self.has_just_migrated) {
                FLOG(5, message: " - BUT HAS JUST MIGRATED SO DON'T LOAD SEED DATA")
                load_seed_data = false
            } else {
                FLOG(5, message: " - AND HAS NOT JUST MIGRATED SO LOAD SEED DATA")
                load_seed_data = false ///DGXXX
            }
        }
        
        FLOG(5, message: " store Options are \(self.storeOptions())")
        
        registerForStoreChanges(aPersistentStoreCoordinator)
        
        FLOG(5, message: "  addPersistentStoreWithType about to be called... ")
        
        let sOptions = storeOptions() as [NSObject : AnyObject]
        
        // Now open the store using the configured settings (local or iCloud)
        do {
            let newStore: NSPersistentStore = try aPersistentStoreCoordinator.addPersistentStoreWithType(NSSQLiteStoreType, configuration:nil, URL: storeURL,
                options: sOptions)
            
            FLOG(5, message: "  addPersistentStoreWithType completed successfully... ")
            
            persistentStoreCoordinator = aPersistentStoreCoordinator
            
            if let url: NSURL = newStore.URL {
                
                FLOG(5, message: " STORE FILE is \(url.path)")
                
                NSUserDefaults.standardUserDefaults().setURL(url, forKey:Constants.iCloudStoreFilenameKey)
            }
            
            // Set the moc here because its defined as Lazy it may be initialised to nil already by
            // something!
            let newMoc = NSManagedObjectContext(concurrencyType: NSManagedObjectContextConcurrencyType.MainQueueConcurrencyType)
            newMoc.persistentStoreCoordinator = persistentStoreCoordinator
            // Set the MergePolicy to prioritise external inputs
            let mergePolicy = NSMergePolicy(mergeType:NSMergePolicyType.MergeByPropertyStoreTrumpMergePolicyType )
            newMoc.mergePolicy = mergePolicy
            managedObjectContext = newMoc
            
            // Now load any seed data
            loadSeedDataIfRequired()
            
            // Tell the world the store has opened
            //if (!isCloudEnabled)
            postStoreOpenedNotification()
            
            
            createTimer()
            showBackgroundTaskInactive()
            isOpening = false
            
        } catch _ {
            FLOG(5, message: "  addPersistentStoreWithType failed... ")
            return
        }
        
    }
    func loadSeedDataIfRequired() {
        FLOG(5, message: " called")
        if (load_seed_data) {
            self.loadSeedData()
            load_seed_data = false
        } else {
            FLOG(5, message: " Do not load seed data")
        }
    }
    /* Loads the required seed data */
    // Usually called on a background thread and therefor we need to process the DidSave notification
    // to merge the changed with the main context so the UI gets updated
    func loadSeedData() {
        FLOG(5, message: " called")
        
        let bgContext:NSManagedObjectContext = NSManagedObjectContext(concurrencyType: NSManagedObjectContextConcurrencyType.PrivateQueueConcurrencyType)
        
        // Register for saves in order to merge any data from background threads
        NSNotificationCenter.defaultCenter().addObserver(self, selector:"storesDidSave:", name: NSManagedObjectContextDidSaveNotification, object:bgContext)
        
        while (persistentStoreCoordinator == nil) {
            //FLOG(@" persistentStoreCoordinator = nil, waiting 5 seconds to try again...");
            sleep(5);
        }
        
        bgContext.persistentStoreCoordinator = persistentStoreCoordinator
        
        
        insertNewWalletDetails(bgContext, name:"Info")
        
        insertStatusCode(bgContext, number: 0, name: "Not started")
        insertStatusCode(bgContext, number: 1, name: "Started on track")
        insertStatusCode(bgContext, number: 2, name: "Behind schedule")
        insertStatusCode(bgContext, number: 3, name: "Completed")
        insertStatusCode(bgContext, number: 4, name: "Completed behind schedule")
        insertStatusCode(bgContext, number: 5, name: "On hold or cancelled")
        
        #if os(iOS)
            insertCategory(bgContext, entityName:"AssetCategory",sortIndex: 0, name: "Property", viewName:"Property", icon:UIImage(named: "WBSMenuIcon.png"))
            
            insertCategory(bgContext, entityName:"AssetCategory", sortIndex: 1, name: "Motor Vehicles", viewName:"Motor Vehicles", icon:UIImage(named:"WBSMenuIcon.png"))
            insertCategory(bgContext, entityName:"AssetCategory", sortIndex: 2, name: "Household", viewName:"Household", icon:UIImage(named:"WBSMenuIcon.png"))
            
            //LOG(@"Creating AccountCategories...");
            insertCategory(bgContext, entityName:"BankAccountCategory", sortIndex: 0, name: "Personal", viewName:"Bank Account", icon:UIImage(named:"WBSMenuIcon.png"))
            insertCategory(bgContext, entityName:"BankAccountCategory", sortIndex: 1, name: "Business", viewName:"Bank Account", icon:UIImage(named:"WBSMenuIcon.png"))
            
            //LOG(@"Creating DocumentCategories...")
            insertCategory(bgContext, entityName:"DocumentCategory", sortIndex: 0, name: "Books", viewName:"Book", icon:UIImage(named:"WBSMenuIcon.png"))
            insertCategory(bgContext, entityName:"DocumentCategory", sortIndex: 1, name: "Memberships", viewName:"Membership", icon:UIImage(named:"WBSMenuIcon.png"))
            insertCategory(bgContext, entityName:"DocumentCategory", sortIndex: 2, name: "Recipes", viewName:"Recipes", icon:UIImage(named:"WBSMenuIcon.png"))
            insertCategory(bgContext, entityName:"DocumentCategory", sortIndex: 3, name: "Other", viewName:"Document", icon:UIImage(named:"WBSMenuIcon.png"))
            
            
            #else
            insertCategory(bgContext, entityName:"AssetCategory",sortIndex: 0, name: "Property", viewName:"Property", icon:NSImage(named: "WBSMenuIcon.png"))
            
            insertCategory(bgContext, entityName:"AssetCategory", sortIndex: 1, name: "Motor Vehicles", viewName:"Motor Vehicles", icon:NSImage(named:"WBSMenuIcon.png"))
            insertCategory(bgContext, entityName:"AssetCategory", sortIndex: 2, name: "Household", viewName:"Household", icon:NSImage(named:"WBSMenuIcon.png"))
            
            //LOG(@"Creating AccountCategories...");
            insertCategory(bgContext, entityName:"BankAccountCategory", sortIndex: 0, name: "Personal", viewName:"Bank Account", icon:NSImage(named:"WBSMenuIcon.png"))
            insertCategory(bgContext, entityName:"BankAccountCategory", sortIndex: 1, name: "Business", viewName:"Bank Account", icon:NSImage(named:"WBSMenuIcon.png"))
            
            //LOG(@"Creating DocumentCategories...")
            insertCategory(bgContext, entityName:"DocumentCategory", sortIndex: 0, name: "Books", viewName:"Book", icon:NSImage(named:"WBSMenuIcon.png"))
            insertCategory(bgContext, entityName:"DocumentCategory", sortIndex: 1, name: "Memberships", viewName:"Membership", icon:NSImage(named:"WBSMenuIcon.png"))
            insertCategory(bgContext, entityName:"DocumentCategory", sortIndex: 2, name: "Recipes", viewName:"Recipes", icon:NSImage(named:"WBSMenuIcon.png"))
            insertCategory(bgContext, entityName:"DocumentCategory", sortIndex: 3, name: "Other", viewName:"Document", icon:NSImage(named:"WBSMenuIcon.png"))
        #endif
        
        bgContext.processPendingChanges()
        
        do {
            
            try bgContext.save()
            
            FLOG(5, message: " Seed data loaded")
            
            
        } catch {
            FLOG(5, message: "  Unresolved error while saving")
        }
    }
    func insertNewWalletDetails(moc:NSManagedObjectContext, name:String)
    {
        //FLOG(5, message: " called")
        
        if let newManagedObject:NSManagedObject = NSEntityDescription.insertNewObjectForEntityForName("Details", inManagedObjectContext:moc) {
            
            newManagedObject.setValue(name, forKey:"name")
            
        }
        
    }
    func insertStatusCode(moc:NSManagedObjectContext, number:Int, name:String)
    {
        //FLOG(5, message: " called")
        
        if let newManagedObject:NSManagedObject = NSEntityDescription.insertNewObjectForEntityForName("StatusCode", inManagedObjectContext:moc) {
            
            newManagedObject.setValue(number, forKey:"number")
            newManagedObject.setValue(name, forKey:"name")
            
        }
        
    }
    #if os(iOS)
    func insertCategory(moc:NSManagedObjectContext, entityName:String, sortIndex:Int, name:String, viewName:String, icon:UIImage?)
    {
    //FLOG(5, message: " called")
    
    if let newManagedObject:NSManagedObject = NSEntityDescription.insertNewObjectForEntityForName(entityName, inManagedObjectContext:moc) {
    
    newManagedObject.setValue(sortIndex, forKey:"sortIndex")
    newManagedObject.setValue(name, forKey:"name")
    newManagedObject.setValue(viewName, forKey:"viewName")
    
    if let ic = icon {
    newManagedObject.setValue(UIImagePNGRepresentation(ic), forKey:"image")
    }
    }
    
    }
    #else
    func insertCategory(moc:NSManagedObjectContext, entityName:String, sortIndex:Int, name:String, viewName:String, icon:NSImage?)
    {
        //FLOG(5, message: " called")
        
        if let newManagedObject:NSManagedObject = NSEntityDescription.insertNewObjectForEntityForName(entityName, inManagedObjectContext:moc) {
            
            newManagedObject.setValue(sortIndex, forKey:"sortIndex")
            newManagedObject.setValue(name, forKey:"name")
            newManagedObject.setValue(viewName, forKey:"viewName")
            
            if let ic = icon {
                newManagedObject.setValue(PNGRepresentationOfImage(ic), forKey:"image")
            }
        }
        
    }
    /// Create a bitmap representation from the current image
    func PNGRepresentationOfImage(image: NSImage) -> NSData? {
        
        image.lockFocus()
        let bitmapRep = NSBitmapImageRep(focusedViewRect: NSMakeRect(0, 0, image.size.width, image.size.height))
        image.unlockFocus()
        
        let imageProps: Dictionary<String, AnyObject> = [NSImageCompressionFactor: NSNumber(float: 1.0)]
        
        if let bmp = bitmapRep {
            if let png = bmp.representationUsingType(NSBitmapImageFileType.NSPNGFileType, properties: imageProps) {
                return png
            }
        }
        return nil
    }
    #endif
    
    // MARK:  Core Data Notifications
    
    func postStoreChangedNotification() {
        NSOperationQueue.mainQueue().addOperationWithBlock( {
            NSNotificationCenter.defaultCenter().postNotificationName(CDConstants.OSStoreChangeNotification,
                object:self)
        })
    }
    
    func postStoreOpenedNotification() {
        NSOperationQueue.mainQueue().addOperationWithBlock( {
            NSNotificationCenter.defaultCenter().postNotificationName(CDConstants.OSStoreOpenedNotification,
                object:self)
        })
    }
    func postModelCheckedNotification() {
        NSOperationQueue.mainQueue().addOperationWithBlock( {
            NSNotificationCenter.defaultCenter().postNotificationName(CDConstants.OSModelCheckedNotification,
                object:self)
        })
    }
    func storeExists()->Bool {
        FLOG(5, message: " called")
        
        if (isICloudEnabled) {
            
            let result: Bool = iCloudStoreExists()
            
            FLOG(5, message: "  iCloudStoreExists returned " + (result ? "YES" : "NO"))
            
            return result
            
        } else {
            
            if let path = storeURL?.path {
                
                FLOG(5, message: "  storeURL is \(path)")
                
                let fileExists: Bool = NSFileManager.defaultManager().fileExistsAtPath( path)
                
                FLOG(5, message: "  storeURL " + (fileExists ? "exists" : "does not exist"))
                
                return fileExists
                
            } else {
                
                return false
                
            }
        }
    }
    /// This function sets the isICloudEnabled flag and then starts an asynchronous task
    /// that first checks to see if existing store files need to be migrated and if so perform
    /// the migration.  Once any required migration is completed then open the store
    func setIsCloudEnabled(isCloudEnabled: Bool)
    {
        FLOG(5, message: " called with " + (isCloudEnabled ? "YES" : "NO"))
        
        self.isICloudEnabled = isCloudEnabled
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
            
            self.migrateFilesIfRequired()
            
            self.openPersistentStore(nil)
            
            self.isFirstInstall = false
            
        })
    }
    // MARK: Migration and Moving Files
    
    /// This function will check if isICloudEnabled is true and if so then check if a local store file exists
    /// and migrate it to iCloud.  If an iCloud store already exists then the migration will fail and we should really send a message to the user indicating such.  We could remove what it there or we could merge with it!
    /// If isICloudEnabled is false then check if an iCloud file exists and migrate it to a local store
    /// Actually we should ask the user if they want to migrate it to a local store, particularly if it is a first
    /// installation.
    func migrateFilesIfRequired() {
        FLOG(5, message: "migrateFilesIfRequired called...")
        // Setting has changed to take the appropriate action
        
        if (isICloudEnabled) {
            // iCloud has been enabled so migrate local files to iCloud
            FLOG(5, message: " iCloud has been enabled so migrate local files to iCloud if they exist")
            
            if (localStoreExists()) {
                FLOG(5, message: " Local store exists so migrate it")
                
                if (migrateLocalFileToICloud()) {
                    FLOG(5, message: " Local store migrated to iCloud successfully")
                    has_just_migrated = true
                    storeURL = iCloudStoreURL()
                    
                } else {
                    FLOG(5, message: " Local store migration to iCloud FAILED because iCloud store already there")
                    
                    // Do nothing because we have posted an alert asking the user what to do and we will respond to that
                    storeURL = nil;
                }
                
            } else {
                FLOG(5, message: " No local store exists")
                storeURL = iCloudStoreURL()
            }
            
        } else {
            // iCloud has been disabled so check whether to keep or delete them
            FLOG(5, message: " iCloud has been disabled so check if there are any iCloud files and delete or migrate them")
            
            if (!isFirstInstall && iCloudStoreExists()) {
                FLOG(5, message: " iCloud store exists")
                
                if (deleteICloudFiles) {
                    FLOG(5, message: " delete iCloud Files")
                    // DG Need to add Code for this !
                    self.removeICloudStore()
                    self.deregisterForStoreChanges()
                    self.persistentStoreCoordinator = nil
                    
                    NSNotificationCenter.defaultCenter().removeObserver(self, name: NSManagedObjectContextDidSaveNotification, object:managedObjectContext)
                    
                    self.managedObjectContext = nil;
                    self.storeURL = self.localStoreURL()
                } else {
                    FLOG(5, message: " migrate iCloud Files")
                    if (migrateICloudFileToLocal()) {
                        FLOG(5, message: " iCloud store migrated to Local successfully")
                        has_just_migrated = true
                        
                        storeURL = localStoreURL()
                    } else {
                        //FLOG(5, message: " iCloud store migration to Local FAILED")
                        storeURL = localStoreURL()
                    }
                }
            } else {
                //FLOG(5, message: " no iCloud store exists so no migration required")
                storeURL = localStoreURL()
            }
        }
    }
    /*! Migrates and iCloud file to a Local file by creating a OSManagedDocument
    and calling the moveDocumentToLocal method.  The document knows how to move it
    
    @param fileURL The URL of the file to be moved
    */
    func migrateICloudFileToLocal()->Bool {
        FLOG(5, message: " migrateICloudFileToLocal")
        
        // Now check if the file is in iCloud
        if (!localStoreExists()) {
            
            return moveStoreToLocal()
            
        } else {
            
            FLOG(5, message: " error migrateICloudFileToLocal because Local file already exists!")
            return false
            
        }
    }
    /*! Moves an iCloud store to local by migrating the iCloud store to a new local store and then removes the store from iCloud.
    
    Note that even if it fails to remove the iCloud files it deletes the local copy.  User may need to clean up orphaned iCloud files using a Mac!
    
    @return Returns YES of file was migrated or NO if not.
    */
    func moveStoreToLocal()->Bool {
        FLOG(5, message: "moveStoreToLocal called")
        
        // Lets use the existing PSC
        let migrationPSC:NSPersistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: managedObjectModel)
        
        // Open the store
        do {
            let sourceStore:NSPersistentStore = try migrationPSC.addPersistentStoreWithType(NSSQLiteStoreType, configuration:nil, URL:iCloudStoreURL(), options:iCloudStoreOptions() as [NSObject : AnyObject])
            
            FLOG(5, message: " Successfully added store to migrate");
            
            
            FLOG(5, message: " About to migrate the store...")
            
            do {
                let _: NSPersistentStore = try migrationPSC.migratePersistentStore(sourceStore, toURL:localStoreURL(), options:localStoreOptions() as [NSObject : AnyObject], withType:NSSQLiteStoreType)
                
                
                FLOG(5, message: "store successfully migrated")
                deregisterForStoreChanges()
                persistentStoreCoordinator = nil
                managedObjectContext = nil
                storeURL = localStoreURL()
                removeICloudStore()
                
            } catch {
                
                FLOG(5, message: "Failed to migrate store");
                return false
            }
            
            
        } catch _ {
            
            FLOG(5, message: " failed to add old store");
            return false
        }
        
        return true
    }
    /*! Migrates a Local file to iCloud file by creating a OSManagedDocument
    and calling the moveDocumentToICloud method.  The document knows how to move it
    
    @param fileURL The URL of the file to be moved
    */
    func migrateLocalFileToICloud()->Bool {
        FLOG(5, message: " migrateLocalFileToiCloud");
        
        // Now check if the file is already in iCloud
        if (!iCloudStoreExists()) {
            
            return moveStoreToICloud()
            
        } else {
            
            FLOG(5, message: " error migrating local file to iCloud because iCloud file already exists!");
            #if os(iOS)
                
                NSOperationQueue.mainQueue().addOperationWithBlock() {
                    
                    /*
                    
                    _cloudMergeChoiceAlert = [[UIAlertView alloc] initWithTitle:@"iCloud file exists" message:@"Do you want to merge the data on this device with the existing iCloud data?" delegate:self cancelButtonTitle:@"No" otherButtonTitles:@"Yes", nil];
                    [_cloudMergeChoiceAlert show];
                    */
                    
                }
                #else
                FLOG(5, message: " Warning migrating local file to iCloud but iCloud file already exists, choose an option!")
                
                
                let result = self.mergeWithICloudChoiceAlert()
                
                    
                if result {
                    FLOG(5, message: " user selected to merge with iCloud file")
                    self.deregisterForStoreChanges()
                    self.persistentStoreCoordinator = nil
                    self.managedObjectContext = nil
                    self.moveStoreToICloud()
                    self.postStoreChangedNotification()
                }
                else {
                    FLOG(5, message: " user selected to use iCloud file")
                    self.deregisterForStoreChanges()
                    self.persistentStoreCoordinator = nil
                    self.managedObjectContext = nil
                    self.storeURL = self.iCloudStoreURL()
                    
                    // Always make a backup of the local store before migrating to iCloud
                    self.backupLocalStore()
                    
                    self.deleteLocalStore()
                    self.postStoreChangedNotification()
                }
                
            #endif
            
            return false
            
        }
    }
    /*! Moves a local document to iCloud by migrating the existing store to iCloud and then removing the original store.
    We use a local file name of persistentStore and an iCloud name of persistentStore_ICLOUD so its easy to tell if
    the file is iCloud enabled
    
    */
    func moveStoreToICloud()->Bool {
        FLOG(5, message: " called");
        return moveStoreFileToICloud(localStoreURL(), shouldDelete:true, shouldBackup:true)
    }
    func backupCurrentStore()->Bool {
        FLOG(5, message: " called");
        
        NSUserDefaults.standardUserDefaults().synchronize()
        
        let makeBackup: Bool = NSUserDefaults.standardUserDefaults().boolForKey(Constants.makeBackupPreferenceKey)
        
        if (!makeBackup) {
            FLOG(5, message: " backup not required")
            return false
        }
        
        return  backupCurrentStoreWithNoCheck()
        
    }
    // This function must be called on a background thread
    func listAllICloudDocs() {
        // returns the iCloud container /CoreData directory URL whose root directories are the UbiquityNameKeys for all Core Data documents
        if let iCloudDirectory:NSURL = iCloudCoreDataURL() {
            
            //FLOG(5, message: "  iCloudDirectory is \(iCloudDirectory)")
            
            do {
                
                if let docs = try NSFileManager.defaultManager().contentsOfDirectoryAtURL(iCloudDirectory, includingPropertiesForKeys:nil, options:NSDirectoryEnumerationOptions()) as NSArray? {
                    
                    //FLOG(5, message: "   ")
                    //FLOG(5, message: "  ICLOUD DOCUMENTS (\(docs.count))")
                    //FLOG(5, message: "  =====================")
                    for _ in docs {
                        //FLOG(5, message: "  \(document.lastPathComponent)")
                    }
                    //FLOG(5, message: "   ")
                    
                } else {
                    //FLOG(5, message: "   ")
                }
            } catch {
                
            }
            
        } else {
            
            //FLOG(5, message: "iCloud directory is nil, can't list iCloud documents")
            
            return
        }
        
        
    }
    /*! Checks whether the ubiquity token has changed and if so it means the iCloud login has changed since the application was last
    active.  If the user has signed out then they will loose access to their iCloud documents so tell them to log back in to
    access those documents.
    
    @param currenToken The current ubiquity identity.
    */
    func checkUbiquitousTokenFromPreviousLaunch(currentToken: protocol<NSCoding, NSCopying, NSObjectProtocol>?) {
        
        // Fetch a previously stored value for the ubiquity identity token from NSUserDefaults.
        // That value can be compared to the current token to determine if the iCloud login has changed since the last launch of our application
        
        if let oldTokenData: NSData = NSUserDefaults.standardUserDefaults().objectForKey(Constants.ubiquityTokenKey) as? NSData {
            
            if let oldToken: protocol<NSCoding, NSCopying, NSObjectProtocol> = NSKeyedUnarchiver.unarchiveObjectWithData(oldTokenData) as? protocol<NSCoding, NSCopying, NSObjectProtocol> {
                
                if (!oldToken.isEqual(currentToken)) {
                    // If we had a token, we were signed in before.
                    // If the token has change, a signout has occurred - either switching to another account or deleting iCloud entirely.
                    NSOperationQueue.mainQueue().addOperationWithBlock({
                        /*
                        UIAlertView* alert = [[UIAlertView alloc] initWithTitle:@"iCloud Sign-Out" message:@"You have signed out of the iCloud account previously used to store documents. Sign back in to access those documents" delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
                        [alert show];
                        */
                    })
                }
            }
        }
        
    }
    
    func storeCurrentUbiquityToken() {
        if let token:protocol<NSCoding, NSCopying, NSObjectProtocol>? = NSFileManager.defaultManager().ubiquityIdentityToken {
            // Write the ubquity identity token to NSUserDefaults if it exists.
            // Otherwise, remove the key.
            if let tk = token {
                let newTokenData: NSData = NSKeyedArchiver.archivedDataWithRootObject(tk)
                NSUserDefaults.standardUserDefaults().setObject(newTokenData, forKey:Constants.ubiquityTokenKey)
            }
            
        }
        else {
            NSUserDefaults.standardUserDefaults().removeObjectForKey(Constants.ubiquityTokenKey)
        }
        
    }
    
    /*! Checks to see whether the user has previously selected the iCloud storage option, and if so then check
    whether the iCloud identity has changed (i.e. different iCloud account being used or logged out of iCloud).
    
    If the user has previously chosen to use iCloud and we're still signed in, setup the CloudManager
    with cloud storage enabled.
    
    If iCloud is available AND if no user choice is recorded, use a UIAlert to fetch the user's preference.
    
    If iCloud is available AND if user has selected to Use iCloud then check if any local files need to be
    migrated.
    
    if iCloud is available AND if user has selected to NO Use iCloud then check if any iCloud files need to
    be migrated to local storage.
    
    */
    func checkUserICloudPreferenceAndSetupIfNecessary(completion:(()->Void)?)
    {
        FLOG(5, message: " called");
        dispatch_async(dispatch_get_main_queue(), {
            self.performInitialisationChecks(completion)
        })
    }
    
    //
    #if os(iOS)
    func performInitialisationChecks(completion:(()->Void)?) {
    //FLOG(5, message: " called");
    showBackgroundTaskActive()
    
    // Check if a backup has been requested and then backup current store
    backupCurrentStore()
    
    if let strg = ubiquityContainerID {
    
    FLOG(5, message: " ubiquityContainerID is " + (strg as String))
    
    } else {
    
    FLOG(5, message: " ubiquityContainerID is nil")
    
    }
    
    if let currentToken: protocol<NSCoding, NSCopying, NSObjectProtocol>? = NSFileManager.defaultManager().ubiquityIdentityToken {
    
    FLOG(5, message: " ubiquityIdentityToken is \(currentToken)")
    
    
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
    
    if let url = self.iCloudCoreDataURL() {
    FLOG(5, message: " iCloud container is \(url.path)")
    }
    
    
    for var i = 1; i<2; i++ {
    self.listAllICloudDocs()
    sleep(1)
    }
    })
    
    //FLOG(5, message: " iCloud is enabled");
    
    icloud_container_available = true
    
    if (isICloudEnabled) {
    
    NSNotificationCenter.defaultCenter().postNotificationName(CDConstants.ICloudStateUpdatedNotification, object:nil)
    }
    
    } else
    {
    
    //FLOG(5, message: " iCloud is not enabled");
    // If there is no token now, set our state to NO
    icloud_container_available = false
    //[self setIsCloudEnabled:NO];
    }
    
    NSUserDefaults.standardUserDefaults().synchronize()
    
    
    var storagePreferenceSelected: Bool = false
    
    // Call this twice because sometimes the first call returns incorrect value!
    let userICloudChoice = NSUserDefaults.standardUserDefaults().boolForKey(Constants.iCloudPreferenceKey)
    
    if let _ = NSUserDefaults.standardUserDefaults().stringForKey(Constants.iCloudPreferenceSelected) {
    
    //FLOG(5, message: " User preference for \(Constants.iCloudPreferenceKey) is " + (userICloudChoice ? "YES" : "NO"))
    
    storagePreferenceSelected = true
    
    if (userICloudChoice) {
    
    //FLOG(5, message: " User selected iCloud");
    useICloudStorage = true
    // Display notice if previous iCloud account is not available
    self.checkUbiquitousTokenFromPreviousLaunch(NSFileManager.defaultManager().ubiquityIdentityToken)
    
    } else {
    
    //FLOG(5, message: " User disabled iCloud");
    useICloudStorage = false
    
    }
    
    } else {
    //FLOG(5, message: " User has not selected a storage preference")
    storagePreferenceSelected = false
    useICloudStorage = false
    }
    
    
    
    // iCloud is active
    if let _: protocol<NSCoding, NSCopying, NSObjectProtocol>? = NSFileManager.defaultManager().ubiquityIdentityToken {
    
    //FLOG(5, message: " iCloud is active");
    
    // If user has not yet set preference then prompt for them to select a preference
    if (!storagePreferenceSelected) {
    
    //FLOG(5, message: " userICloudChoiceSet has not been set yet, so ask the user what they want to do");
    isFirstInstall = true  // Set this so that if there are iCloud files we can ask if they should be migrated to
    // the local store.
    
    // Use an Alert Controller with ActionSheet style
    var popup: UIAlertController? = nil
    popup = UIAlertController(title: "Choose Storage Option", message: "Should documents be stored in iCloud or on just this device?", preferredStyle: UIAlertControllerStyle.Alert)
    
    popup?.addAction(UIAlertAction(title: "Local only", style: UIAlertActionStyle.Default, handler: {(alert: UIAlertAction!) in
    
    //FLOG(5, message: " user selected local files");
    NSUserDefaults.standardUserDefaults().setBool(false, forKey:Constants.iCloudPreferenceKey)
    NSUserDefaults.standardUserDefaults().setValue("YES", forKey:Constants.iCloudPreferenceSelected)
    self.useICloudStorage = false
    NSUserDefaults.standardUserDefaults().synchronize()
    
    self.setIsCloudEnabled(false)
    // EXIT POINT so run the completion handler
    if (completion != nil) {
    NSOperationQueue.mainQueue().addOperationWithBlock {
    completion!()
    }
    }
    }))
    popup?.addAction(UIAlertAction(title: "iCloud", style: UIAlertActionStyle.Default, handler: {(alert: UIAlertAction!) in
    
    //FLOG(5, message: " user selected iCloud files");
    NSUserDefaults.standardUserDefaults().setBool(true, forKey: Constants.iCloudPreferenceKey )
    
    NSUserDefaults.standardUserDefaults().setValue("YES", forKey:Constants.iCloudPreferenceSelected)
    
    self.useICloudStorage = true
    
    NSUserDefaults.standardUserDefaults().synchronize()
    
    // Now ask about seed data
    self.promptUserAboutSeedData({
    self.setIsCloudEnabled(true)
    // EXIT POINT so run the completion handler
    if (completion != nil) {
    NSOperationQueue.mainQueue().addOperationWithBlock {
    completion!()
    }
    }
    })
    
    
    
    }))
    
    if (popup != nil) {
    
    // Present this in the center
    
    if let controller = UIApplication.sharedApplication().keyWindow?.rootViewController {
    
    
    if let view:UIView = UIApplication.sharedApplication().keyWindow?.subviews.last {
    
    popup?.popoverPresentationController?.sourceView = view
    
    // The completion block below gets called as soon as presentation
    // is done but does not wait for user to select an action
    controller.presentViewController(popup!, animated: true, completion: nil)
    return
    }
    }
    
    }
    }
    else {
    //FLOG(5, message: " userICloudChoiceSet is set");
    if (userICloudChoice) {
    //FLOG(5, message: " userICloudChoice is YES");
    // iCloud is available and user has selected to use it
    // Check if any local files need to be migrated to iCloud
    // and migrate them
    setIsCloudEnabled(true)
    
    } else  {
    //FLOG(5, message: " userICloudChoice is NO");
    // iCloud is available but user has chosen to NOT Use iCloud
    // Check that NO local file exists already
    if (!localStoreExists()) {
    
    // and IF an iCloud file exists
    if (iCloudStoreExists()) {
    //FLOG(5, message: " iCloudStoreExists exists")
    
    //  Ask the user if they want to migrate the iCloud file to a local file
    // EXIT POINT so pass in completion block
    promptUserAboutICloudDocumentStorage(completion)
    return
    } else {
    // And because no local file exists already this must the the first time therefor we need to load seed data
    load_seed_data = true
    
    // Otherwise just set iCloud enabled
    setIsCloudEnabled(false)
    }
    } else {
    // A Local file already exists so what to do ?
    // Just tell the user a file has been detected in iCloud
    // and ask if they want to start using the iCloud file
    setIsCloudEnabled(false)
    }
    }
    }
    }
    else {
    //FLOG(5, message: " iCloud is not active");
    setIsCloudEnabled(false)
    useICloudStorage = false
    NSUserDefaults.standardUserDefaults().setBool(false, forKey:Constants.iCloudPreferenceKey)
    NSUserDefaults.standardUserDefaults().synchronize()
    
    // Since the user is signed out of iCloud, reset the preference to not use iCloud, so if they sign in again we will prompt them to move data
    NSUserDefaults.standardUserDefaults().removeObjectForKey(Constants.iCloudPreferenceSelected)
    }
    storeCurrentUbiquityToken()
    
    // EXIT POINT so run the completion handler
    if (completion != nil) {
    NSOperationQueue.mainQueue().addOperationWithBlock {
    completion!()
    }
    }
    
    }
    #else
    func performInitialisationChecks(completion:(()->Void)?) {
        FLOG(5, message: " called")
        self.showBackgroundTaskActive()
        
        // Check if a backup has been requested and then backup current store
        self.backupCurrentStore()
        
        if let strg = self.ubiquityContainerID {
            
            FLOG(5, message: " ubiquityContainerID is " + (strg as String))
            
        } else {
            
            FLOG(5, message: " ubiquityContainerID is nil")
            
        }
        
        if let currentToken: protocol<NSCoding, NSCopying, NSObjectProtocol>? = NSFileManager.defaultManager().ubiquityIdentityToken {
            
            FLOG(5, message: " ubiquityIdentityToken is \(currentToken)")
            
            
            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
                
                // Must not call this from main thread !
                if let url = self.iCloudCoreDataURL() {
                    FLOG(5, message: " iCloud container is \(url.path)")
                }
                
                
                for var i = 1; i<2; i++ {
                    self.listAllICloudDocs()
                    sleep(1)
                }
            })
            
            FLOG(5, message: " iCloud is enabled")
            
            icloud_container_available = true
            
            if (self.isICloudEnabled) {
                
                NSNotificationCenter.defaultCenter().postNotificationName(CDConstants.ICloudStateUpdatedNotification, object:nil)
            }
            
        } else
        {
            
            FLOG(5, message: " iCloud is not enabled")
            // If there is no token now, set our state to NO
            icloud_container_available = false
            //[self setIsCloudEnabled:NO];
        }
        
        NSUserDefaults.standardUserDefaults().synchronize()
        
        
        var storagePreferenceSelected: Bool = false
        
        // Call this twice because sometimes the first call returns incorrect value!
        let userICloudChoice = NSUserDefaults.standardUserDefaults().boolForKey(Constants.iCloudPreferenceKey)
        let isUserICloudChoiceSelected = NSUserDefaults.standardUserDefaults().stringForKey(Constants.iCloudPreferenceSelected)
        
        
        if isUserICloudChoiceSelected != nil {
            
            FLOG(5, message: " User preference for \(Constants.iCloudPreferenceKey) is " + (userICloudChoice ? "YES" : "NO"))
            
            storagePreferenceSelected = true
            
            if (userICloudChoice) {
                
                FLOG(5, message: " User selected iCloud")
                useICloudStorage = true
                // Display notice if previous iCloud account is not available
                self.checkUbiquitousTokenFromPreviousLaunch(NSFileManager.defaultManager().ubiquityIdentityToken)
                
            } else {
                
                FLOG(5, message: " User disabled iCloud")
                useICloudStorage = false
                
            }
            
        } else {
            FLOG(5, message: " User has not selected a storage preference")
            storagePreferenceSelected = false
            useICloudStorage = false
        }
        
        
        
        // iCloud is active
        if let currentToken: protocol<NSCoding, NSCopying, NSObjectProtocol>? = NSFileManager.defaultManager().ubiquityIdentityToken {
            
            FLOG(5, message: " iCloud is active")
            
            // If user has not yet set preference then prompt for them to select a preference
            if (!storagePreferenceSelected) {
                
                FLOG(5, message: " userICloudChoiceSet has not been set yet, so ask the user what they want to do")
                isFirstInstall = true  // Set this so that if there are iCloud files we can ask if they should be migrated to
                // the local store.
                
                // Use an Alert Controller with ActionSheet style
                let res = self.cloudChoiceAlert()
                
                self.setICloudPreference(res)
                
            }
            else {
                FLOG(5, message: " userICloudChoiceSet is set")
                if (userICloudChoice) {
                    FLOG(5, message: " userICloudChoice is YES")
                    // iCloud is available and user has selected to use it
                    // Check if any local files need to be migrated to iCloud
                    // and migrate them
                    self.setIsCloudEnabled(true)
                    
                } else  {
                    FLOG(5, message: " userICloudChoice is NO")
                    // iCloud is available but user has chosen to NOT Use iCloud
                    // Check that NO local file exists already
                    if (!self.localStoreExists()) {
                        
                        // and IF an iCloud file exists
                        if (self.iCloudStoreExists()) {
                            FLOG(5, message: " iCloudStoreExists exists")
                            
                            //  Ask the user if they want to migrate the iCloud file to a local file
                            let res = self.promptUserAboutICloudDocumentStorage()
                            
                            if (res == CDConstants.KeepStore) {
                                FLOG(5, message: " 'Keep using iCloud' selected")
                                FLOG(5, message: " turn Use iCloud back ON")
                                NSUserDefaults.standardUserDefaults().setBool(true, forKey:Constants.iCloudPreferenceKey)
                                NSUserDefaults.standardUserDefaults().synchronize()
                                self.useICloudStorage = true
                                self.setIsCloudEnabled(true)
                                
                            }
                            else if (res == CDConstants.MoveStore) {
                                FLOG(5, message: " 'Keep on My Mac' selected")
                                FLOG(5, message: " copy to local storage")
                                self.useICloudStorage = false
                                self.deleteICloudFiles = false
                                self.setIsCloudEnabled(false)
                                
                            }else {
                                FLOG(5, message: " 'Delete from My Mac' selected")
                                FLOG(5, message: " delete copies from My Mac")
                                self.useICloudStorage = false
                                self.deleteICloudFiles = true
                                self.setIsCloudEnabled(false)
                            }
                            // EXIT POINT so run the completion handler
                            if (completion != nil) {
                                NSOperationQueue.mainQueue().addOperationWithBlock {
                                    completion!()
                                }
                            }
                            return
                        } else {
                            // And because no local file exists already this must the the first time therefor we need to load seed data
                            load_seed_data = true
                            
                            // Otherwise just set iCloud enabled
                            self.setIsCloudEnabled(false)
                        }
                    } else {
                        // A Local file already exists so what to do ?
                        // Just tell the user a file has been detected in iCloud
                        // and ask if they want to start using the iCloud file
                        self.setIsCloudEnabled(false)
                    }
                }
            }
        }
        else {
            FLOG(5, message: " iCloud is not active")
            self.setIsCloudEnabled(false)
            useICloudStorage = false
            NSUserDefaults.standardUserDefaults().setBool(false, forKey:Constants.iCloudPreferenceKey)
            NSUserDefaults.standardUserDefaults().synchronize()
            
            // Since the user is signed out of iCloud, reset the preference to not use iCloud, so if they sign in again we will prompt them to move data
            NSUserDefaults.standardUserDefaults().removeObjectForKey(Constants.iCloudPreferenceSelected)
        }
        self.storeCurrentUbiquityToken()
        
        // EXIT POINT so run the completion handler
        if (completion != nil) {
            NSOperationQueue.mainQueue().addOperationWithBlock {
                completion!()
            }
        }
        
    }
    
    #endif
    /// This function sets the users 'Use iCloud' preference and then calls SetIsICloudEnabled(pref)
    /// in order to setup the appropriate loca or Core Data store.
    /// If this is resulting in a change to the existing settings then a migration may be required
    func setICloudPreference(pref: Bool) {
        NSUserDefaults.standardUserDefaults().setBool(pref, forKey:Constants.iCloudPreferenceKey)
        let stringVal: NSString = "YES"
        NSUserDefaults.standardUserDefaults().setValue(stringVal, forKey:Constants.iCloudPreferenceSelected)
        
        NSUserDefaults.standardUserDefaults().synchronize()
        
        //let isUserICloudChoiceSelected = NSUserDefaults.standardUserDefaults().stringForKey(Constants.iCloudPreferenceSelected)
        
        self.setIsCloudEnabled(pref)
    }
    
    // MARK: Register and Deregister for Store Changes
    // We only care if the one we have open is changing
    func registerForStoreChanges(storeCoordinator: NSPersistentStoreCoordinator) {
        
        //FLOG(5, message: "registerForStoreChanges called")
        let nc = NSNotificationCenter.defaultCenter()
        
        nc.addObserver(self, selector: "storesWillChange:", name: NSPersistentStoreCoordinatorStoresWillChangeNotification, object: storeCoordinator)
        
        nc.addObserver(self, selector: "storesDidChange:", name: NSPersistentStoreCoordinatorStoresDidChangeNotification, object: storeCoordinator)
        
        nc.addObserver(self, selector: "storesDidImport:", name: NSPersistentStoreDidImportUbiquitousContentChangesNotification, object: storeCoordinator)
        
    }
    
    func deregisterForStoreChanges() {
        
        //FLOG(5, message: "degisterForStoreChanges called")
        let nc = NSNotificationCenter.defaultCenter()
        
        nc.removeObserver(self,  name: NSPersistentStoreCoordinatorStoresWillChangeNotification, object:nil)
        nc.removeObserver(self, name: NSPersistentStoreCoordinatorStoresDidChangeNotification, object:nil)
        nc.removeObserver(self, name: NSPersistentStoreDidImportUbiquitousContentChangesNotification, object:nil)
        
    }
    // NB - this may be called from a background thread so make sure we run on the main thread !!
    // This is when store files are being switched from fallback to iCloud store
    func storesWillChange(n: NSNotification!) {
        //FLOG(5, message: "storesWillChange called - >>>>>>>>>>>>>>>>>>>>>>>>>>>>");
        
        // Check type of transition
        if let type = n.userInfo?[NSPersistentStoreUbiquitousTransitionTypeKey] as? UInt {
            
            //FLOG(5, message: " transition type is \(type)")
            
            if (type == NSPersistentStoreUbiquitousTransitionType.InitialImportCompleted.rawValue ) {
                //FLOG(5, message: " transition type is NSPersistentStoreUbiquitousTransitionTypeInitialImportCompleted")
            } else if (type == NSPersistentStoreUbiquitousTransitionType.AccountAdded.rawValue) {
                //FLOG(5, message: " transition type is NSPersistentStoreUbiquitousTransitionTypeAccountAdded")
            } else if (type == NSPersistentStoreUbiquitousTransitionType.AccountRemoved.rawValue) {
                //FLOG(5, message: " transition type is NSPersistentStoreUbiquitousTransitionTypeAccountRemoved")
            } else if (type == NSPersistentStoreUbiquitousTransitionType.ContentRemoved.rawValue) {
                //FLOG(5, message: " transition type is NSPersistentStoreUbiquitousTransitionTypeContentRemoved")
            }
        }
        
        //let addedStores: NSArray? = n.userInfo?[NSAddedPersistentStoresKey] as? NSArray
        //let removedStores: NSArray? = n.userInfo?[NSRemovedPersistentStoresKey] as? NSArray
        //let changedStores: NSArray? = n.userInfo?[NSUUIDChangedPersistentStoresKey] as? NSArray
        
        //FLOG(5, message: " added stores are \(addedStores)");
        //FLOG(5, message: " removed stores are \(removedStores)");
        //FLOG(5, message: " changed stores are \(changedStores)");
        
        // Reset user Interface - i.e. lock the user out!
        storesChanging = true
        
        // Now save
        // We MUST call this on the  main thread because managedObjectContext is not thread safe
        // and we MUST wait for it to complete to prevent
        // Core Data from switching the store while we are doing a save
        if (NSThread.isMainThread()) {
            if let moc = managedObjectContext {
                //var error: NSError? = nil
                if moc.hasChanges {
                    do {
                        
                        try moc.save()
                        
                    } catch {
                        FLOG(5, message: "Error while saving data)")
                    }
                }
                moc.reset()
            }
            
        } else {
            
            NSOperationQueue.mainQueue().addOperationWithBlock {
                if let moc = self.managedObjectContext {
                    //var error: NSError? = nil
                    if moc.hasChanges {
                        do {
                            try moc.save()
                        } catch {
                            FLOG(5, message: "Error while saving.")
                        }
                    }
                    moc.reset()
                }
            }
        }
    }
    // NB - this may be called from a background thread so make sure we run on the main thread !!
    // This is when store files are being switched from fallback to iCloud store
    func storesDidChange(n: NSNotification!) {
        //FLOG(5, message: "storesDidChange called - >>>>>>>>>>>>>>>>>>>>>>>>>>>>");
        
        // Check type of transition
        if let type = n.userInfo?[NSPersistentStoreUbiquitousTransitionTypeKey] as? UInt {
            
            //FLOG(5, message: " transition type is \(type)")
            
            if (type == NSPersistentStoreUbiquitousTransitionType.InitialImportCompleted.rawValue ) {
                //FLOG(5, message: " transition type is NSPersistentStoreUbiquitousTransitionTypeInitialImportCompleted")
            } else if (type == NSPersistentStoreUbiquitousTransitionType.AccountAdded.rawValue) {
                //FLOG(5, message: " transition type is NSPersistentStoreUbiquitousTransitionTypeAccountAdded")
            } else if (type == NSPersistentStoreUbiquitousTransitionType.AccountRemoved.rawValue) {
                //FLOG(5, message: " transition type is NSPersistentStoreUbiquitousTransitionTypeAccountRemoved")
            } else if (type == NSPersistentStoreUbiquitousTransitionType.ContentRemoved.rawValue) {
                //FLOG(5, message: " transition type is NSPersistentStoreUbiquitousTransitionTypeContentRemoved")
            }
        }
        
        NSOperationQueue.mainQueue().addOperationWithBlock {
            
            self.storesChanging = false
            
            if let type = n.userInfo?[NSPersistentStoreUbiquitousTransitionTypeKey] as? UInt {
                
                if (type == NSPersistentStoreUbiquitousTransitionType.ContentRemoved.rawValue) {
                    
                    self.showStoreRemovedAlert()
                    //_persistentStoreCoordinator = nil;
                    // Register for saves in order to merge any data from background threads
                    NSNotificationCenter.defaultCenter().removeObserver(self, name: NSManagedObjectContextDidSaveNotification, object:self.managedObjectContext)
                    
                    self.managedObjectContext = nil;
                    
                    //FLOG(5, message: " iCloud store was removed! Wait for empty store");
                }
                self.postStoreChangedNotification()
                // Refresh user Interface
                self.createTimer()
                
            }
        }
    }
    // NB - this may be called from a background thread so make sure we run on the main thread !!
    // This is when transactoin logs are loaded
    func storesDidImport(notification: NSNotification!) {
        FLOG(5, message: "storesDidImport ");
        
        NSOperationQueue.mainQueue().addOperationWithBlock {
            FLOG(5, message: "  merge changes");
            // Process new/changed objects here and remove any unwanted items or duplicates prior to merging with current context
            //
            if let updatedObjectIDs = notification.userInfo?[NSUpdatedObjectsKey] as? NSSet {
                
                for managedObjectID in updatedObjectIDs {
                    let managedObject = self.managedObjectContext!.objectWithID(managedObjectID as! NSManagedObjectID)
                    
                    let name = managedObject.valueForKey("displayName")
                    FLOG(0, message: "Updated: \(name)")
                }
                
            }
            if let insertedObjectIDs = notification.userInfo?[NSInsertedObjectsKey] as? NSSet  {
                for managedObjectID in insertedObjectIDs {
                    let managedObject = self.managedObjectContext!.objectWithID(managedObjectID as! NSManagedObjectID)
                    
                    let name = managedObject.valueForKey("displayName")
                    FLOG(0, message: "Updated: \(name)")
                }
            }
            if let deletedObjectIDs = notification.userInfo?[NSDeletedObjectsKey] as? NSSet  {
                for managedObjectID in deletedObjectIDs {
                    let managedObject = self.managedObjectContext!.objectWithID(managedObjectID as! NSManagedObjectID)
                    
                    let name = managedObject.valueForKey("displayName")
                    FLOG(0, message: "Updated: \(name)")
                }
            }
            
            
            // Iterate over all the new, changed or deleted ManagedObjectIDs and get the NSManagedObject for the corresponding ID:
            // These come from another thread so we can't reference the objects directly
            
            
            
            // Check is some object is equal to an inserted or updated object
            //if([myEntity.objectID isEqual:managedObject.objectID]){}
            
            
            if let moc = self.managedObjectContext {
                //for(NSManagedObject *object in [[notification userInfo] objectForKey:NSUpdatedObjectsKey]) {
                //    [[managedObjectContext objectWithID:[object objectID]] willAccessValueForKey:nil];
                //}
                
                
                FLOG(5, message: "  mergeChangesFromContextDidSaveNotification called");
                moc.mergeChangesFromContextDidSaveNotification(notification)
            }
            
            // Set this so that after the timer goes off we perform a save
            // - without this the deletes don't appear to trigger the fetchedResultsController delegate methods !
            self.import_or_save = true
            
            self.createTimer()
            
        }
    }
    // NB - this may be called from a background thread so make sure we run on the main thread !!
    // This is when transaction logs are loaded
    func storesDidSave(notification: NSNotification!) {
        
        // Ignore any notifications from the main thread because we only need to merge data
        // loaded from other threads.
        if (NSThread.isMainThread()) {
            //FLOG(5, message: " main thread saved context")
            return
        }
        
        NSOperationQueue.mainQueue().addOperationWithBlock {
            FLOG(5, message: "storesDidSave ")
            // Set this so that after the timer goes off we perform a save
            // - without this the deletes don't appear to trigger the fetchedResultsController delegate methods !
            self.import_or_save = true
            
            self.createTimer()
            if let moc = self.managedObjectContext {
                moc.mergeChangesFromContextDidSaveNotification(notification)
            }
            
        }
    }
    var hasChanges: Bool {
        if let moc = self.managedObjectContext {
            if moc.hasChanges {
                return true
            }
        }
        return false
    }
    #if os(iOS)
    
    #else
    var commitEdits: Bool {
        if let moc = self.managedObjectContext {
            return moc.commitEditing()
        }
        return false
    }
    #endif
    /// Saved the context and returns nil or the error
    func save()->Bool {
        if let moc = self.managedObjectContext {
            
            do {
                try moc.save()
                return true
            } catch {
                return false
            }
        } else {
            return false
        }
    }
    func showStoreRemovedAlert() {
        //FLOG(5, message: "Store removed!")
    }
    func createTimer() {
        //FLOG(5, message: " called")
        // If not main thread then dispatch to main thread
        if NSThread.isMainThread() {
            self.setTimer()
        } else {
            dispatch_sync(dispatch_get_main_queue(), {
                self.setTimer()
            })
        }
        return
    }
    func setTimer() {
        if let timer = iCloudUpdateTimer {
            
            if timer.valid {
                //FLOG(5, message: " timer is valid so just reset it")
                timer.fireDate = NSDate(timeIntervalSinceNow: 1.0)
                return
            } else {
                //FLOG(5, message: " timer is invalid")
                timer.invalidate()
            }
        }
        
        //FLOG(5, message: " timer is nil so create one")
        
        //iCloudUpdateTimer = NSTimer.scheduledTimerWithTimeInterval(1.0, target: self, selector: "notifyOfCoreDataUpdates:", userInfo: nil, repeats: false)
        
        iCloudUpdateTimer = NSTimer(timeInterval: 1.0, target: self, selector: "notifyOfCoreDataUpdates:", userInfo: nil, repeats: false)
        NSRunLoop.currentRunLoop().addTimer(iCloudUpdateTimer!, forMode: NSRunLoopCommonModes)
        
        // If we are using iCloud then show the network activity indicator while we process the imports
        if (isICloudEnabled) {
            showBackgroundTaskActive()
        }
    }
    func notifyOfCoreDataUpdates(timer:NSTimer!) {
        
        //FLOG(5, message: " called");
        
        /* DG XX
        if (storesUpdatingAlert != nil) {
        [_storesUpdatingAlert dismissWithClickedButtonIndex:0 animated:YES];
        }
        */
        
        iCloudUpdateTimer?.invalidate()
        iCloudUpdateTimer = nil
        
        // Do a save if we have received imports or Saves from other threads
        if (self.import_or_save) {
            
            
            if let moc = managedObjectContext {
                
                
                do {
                    try moc.save()
                    self.import_or_save = false
                    
                } catch {
                    //FLOG(5, message: " error saving context, \(error), \(error!.userInfo)")
                    
                }
            }
            
        }
        postUIUpdateNotification()
        
        showBackgroundTaskInactive()
    }
    func postUIUpdateNotification() {
        NSOperationQueue.mainQueue().addOperationWithBlock( {
            NSNotificationCenter.defaultCenter().postNotificationName(CDConstants.OSDataUpdatedNotification,
                object:self)
        })
    }
    /*! Posts a notification that file has been deleted
    */
    func postFileDeletedNotification() {
        NSOperationQueue.mainQueue().addOperationWithBlock( {
            NSNotificationCenter.defaultCenter().postNotificationName(CDConstants.OSFileDeletedNotification,
                object:self)
        })
    }
    /*! Posts a notification that file has been deleted
    */
    func postFileCreatedNotification() {
        NSOperationQueue.mainQueue().addOperationWithBlock( {
            NSNotificationCenter.defaultCenter().postNotificationName(CDConstants.OSFileCreatedNotification,
                object:self)
        })
    }
    /*! Posts a notification that file has been deleted
    */
    func postFileClosedNotification() {
        NSOperationQueue.mainQueue().addOperationWithBlock( {
            NSNotificationCenter.defaultCenter().postNotificationName(CDConstants.OSFileClosedNotification,
                object:self)
        })
    }
    
    func postJobStartedNotification() {
        NSOperationQueue.mainQueue().addOperationWithBlock( {
            NSNotificationCenter.defaultCenter().postNotificationName(CDConstants.OSJobStartedNotification,
                object:self)
        })
    }
    func postJobDoneNotification() {
        NSOperationQueue.mainQueue().addOperationWithBlock( {
            NSNotificationCenter.defaultCenter().postNotificationName(CDConstants.OSJobDoneNotification,
                object:self)
        })
    }
    /**  Copies a backup file from the Apps iCloud ubiquity container to the Apps local /Documents directory.
    Note that when copying to/from the ubquity container we need to take special care because of shared
    access issues.  So we must use a NSFileCoordinator.
    */
    func asynchronousCopyFromICloudWithCompletion(fileURL:NSURL, completion:(()->Void)?)
    {
        //FLOG(5, message: " called");
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
            
            // Some long running task you want on another thread
            //FLOG(5, message: " Copy from iCloud Job started");
            self.showBackgroundTaskActive()
            self.copyFileFromICloud(fileURL)
            
            if (completion != nil) {
                NSOperationQueue.mainQueue().addOperationWithBlock {
                    completion!()
                }
            }
            self.showBackgroundTaskInactive()
        })
    }
    /**  Copies iCloud backup file to the Apps local /Documents directory, fails if target file exists.  Note that we need to take special care when reading files from the ubiquity container because its a shared container.
    
    @param fileURL  URL of the file to be copied
    */
    func copyFileFromICloud(fileURL:NSURL) {
        FLOG(5, message: " called");
        let fc:NSFileCoordinator = NSFileCoordinator()
        
        let sourceURL:NSURL = fileURL
        
        if let filename = fileURL.lastPathComponent {
            
            if let destinationURL:NSURL = documentsDirectoryURL()?.URLByAppendingPathComponent(filename) {
                
                
                var destURL = destinationURL;
                
                FLOG(5, message: " source file is \(sourceURL)")
                FLOG(5, message: " target file is \(destURL)")
                
                var cError:NSError? = nil
                
                fc.coordinateReadingItemAtURL(sourceURL, options: NSFileCoordinatorReadingOptions.WithoutChanges, error: &cError, byAccessor: {sourceURLToUse in
                    
                    var error:NSError? = nil
                    let fm:NSFileManager = NSFileManager()
                    
                    // Check if the file exists and create a new name
                    if (fm.fileExistsAtPath(destURL.path!)) {
                        FLOG(5, message: " target file exists");
                        if let newURL:NSURL = self.getNewFileURL(destURL, local:true) {
                            destURL = newURL
                            //simply copy the file over
                            let copySuccess: Bool
                            do {
                                try fm.copyItemAtPath(sourceURLToUse.path!,
                                    toPath:destURL.path!)
                                copySuccess = true
                            } catch let error1 as NSError {
                                error = error1
                                copySuccess = false
                            } catch {
                                fatalError()
                            };
                            if (copySuccess) {
                                FLOG(5, message: " copied file successfully");
                                //[self postFileUpdateNotification];
                            } else {
                                FLOG(5, message: "Error copying items Error: \(error), \(error?.userInfo)")
                            }
                        }
                    } else {
                        //simply copy the file over
                        let copySuccess: Bool
                        do {
                            try fm.copyItemAtPath(sourceURLToUse.path!,
                                toPath:destURL.path!)
                            copySuccess = true
                        } catch  {
                            
                            copySuccess = false
                        }
                        if (copySuccess) {
                            FLOG(5, message: " copied file successfully");
                            //[self postFileUpdateNotification];
                        } else {
                            FLOG(5, message: "Error copying items Error: \(error), \(error?.userInfo)")
                        }
                    }
                })
                
                if (cError != nil) {
                    FLOG(5, message: " error is \(cError), \(cError?.userInfo)");
                }
            }
        }
    }
    
    func asynchronousCopyToICloudWithCompletion(fileURL:NSURL, completion:(()->Void)?)
    {
        //FLOG(5, message: " called");
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
            
            // Some long running task you want on another thread
            //FLOG(5, message: " Copy to iCloud Job started");
            self.showBackgroundTaskActive()
            self.copyFileToICloud(fileURL)
            
            
            if (completion != nil) {
                NSOperationQueue.mainQueue().addOperationWithBlock {
                    completion!()
                }
            }
            self.showBackgroundTaskInactive()
            
        })
    }
    /**  Copies file to iCloud containers 'Documents' directory (fails if target already exists)
    
    @param fileURL  URL of the file is to be copied
    */
    func copyFileToICloud(fileURL:NSURL) {
        //FLOG(5, message: " called")
        
        let fc:NSFileCoordinator = NSFileCoordinator()
        
        let sourceURL:NSURL = fileURL
        
        if let filename = fileURL.lastPathComponent {
            
            //DG This method is called from a background thread so its OK
            // Get the default apps container
            if let url:NSURL = NSFileManager.defaultManager().URLForUbiquityContainerIdentifier(nil) {
                
                var destinationURL = url.URLByAppendingPathComponent("Documents").URLByAppendingPathComponent(filename)
                
                //FLOG(5, message: " source file is \(sourceURL)")
                //FLOG(5, message: " target file is \(destinationURL)")
                
                let fm1:NSFileManager = NSFileManager()
                
                if let path = destinationURL.path {
                    
                    if (fm1.fileExistsAtPath(path)) {
                        //FLOG(5, message: " target file exists");
                        if let newDestinationURL = getNewFileURL(destinationURL, local:false){
                            destinationURL = newDestinationURL
                            //FLOG(5, message: " new target file is \(destinationURL)")
                        } else {
                            //FLOG(5, message: "Unable to get a new destination file URL, can't continue")
                            return
                        }
                    }
                }
                
                var cError: NSError? = nil
                
                fc.coordinateReadingItemAtURL(sourceURL, options: NSFileCoordinatorReadingOptions.WithoutChanges, writingItemAtURL: destinationURL, options: NSFileCoordinatorWritingOptions.ForReplacing, error: &cError, byAccessor: {newReaderURL, newWriterURL in
                    
                    
                    
                    let fm:NSFileManager = NSFileManager()
                    
                    if let sourcePath = newReaderURL.path {
                        if let destPath = newWriterURL.path {
                            //simply copy the file over
                            let copySuccess: Bool
                            do {
                                try fm.copyItemAtPath(sourcePath,
                                    toPath:destPath)
                                copySuccess = true
                            } catch {
                                copySuccess = false
                                
                            }
                            
                            if (copySuccess) {
                                //FLOG(5, message: " copied file successfully");
                                //[self postFileUpdateNotification];
                            } else {
                                
                                //FLOG(5, message: "Error copying items Error: \(er), \(er.userInfo?)")
                                
                            }
                        }
                    }
                })
                
                if (cError != nil) {
                    //FLOG(5, message: " FileCoordinator error is \(cError), \(cError?.userInfo?)");
                }
                
            } else {
                //FLOG(5, message: " iCloud container is not available!")
            }
        }
    }
    // Check if filename exists locally or in iCloud
    func getNewFileURL(fileURL:NSURL, local:Bool)-> NSURL? {
        //FLOG(5, message: " called");
        var docCount:NSInteger = 0
        var newDocName:NSString? = nil
        if let fileExtension:NSString = fileURL.pathExtension {
            
            if let lpc:NSString = fileURL.lastPathComponent {
                
                if let prefix:NSString = lpc.stringByDeletingPathExtension {
                    
                    
                    
                    // At this point, the document list should be up-to-date.
                    let done: Bool = false
                    var first: Bool = true
                    
                    while (!done) {
                        if (first) {
                            first = false
                            newDocName = "\(prefix).\(fileExtension)"
                        } else {
                            newDocName = "\(prefix) \(docCount).\(fileExtension)"
                        }
                        
                        // Look for an existing document with the same name. If one is
                        // found, increment the docCount value and try again.
                        var nameExists: Bool = false
                        
                        if (local) {
                            nameExists = docNameExistsInLocalURLs(newDocName! as String)
                        } else {
                            nameExists = docNameExistsInICloudURLs(newDocName! as String)
                        }
                        
                        if (!nameExists) {
                            break;
                        } else {
                            docCount++;
                        }
                        
                    }
                    
                    let newURL:NSURL? = fileURL.URLByDeletingLastPathComponent?.URLByAppendingPathComponent(newDocName! as String)
                    
                    return newURL
                }
            }
        }
        return nil
    }
    func docNameExistsInLocalURLs(docName:String) -> Bool {
        //FLOG(5, message: " called");
        var nameExists:Bool = false
        
        for object in listAllLocalBackupDocuments() {
            if let fileURL = object as? NSURL {
                if let filename = fileURL.lastPathComponent {
                    if (filename.isEqual(docName)) {
                        nameExists = true
                        break
                    }
                }
            }
        }
        return nameExists
    }
    
    func docNameExistsInICloudURLs(docName:String)->Bool {
        
        //FLOG(5, message: " called with \(docName)")
        var nameExists:Bool = false
        
        for object in listAllICloudBackupDocuments() {
            
            if let fileRep = object as? FileRepresentation {
                
                //FLOG(5, message: " checking \(fileRep.url?.lastPathComponent)")
                
                if let url = fileRep.url {
                    if let filename = url.lastPathComponent {
                        if (filename.isEqual(docName)) {
                            
                            //FLOG(5, message: " file exists \(filename)")
                            nameExists = true
                            break
                        }
                    }
                }
            }
        }
        //FLOG(5, message: " file does not exist ")
        
        return nameExists;
    }
    
    func deleteBackupFile(fileURL:NSURL) {
        // We need to get the URL to the store
        //FLOG(5, message: " called with \(fileURL)")
        
        
        if let path = fileURL.path {
            // Check if the CoreDataUbiquitySupport files exist
            if (!NSFileManager.defaultManager().fileExistsAtPath(path)) {
                //FLOG(5, message: " File does not exist")
                return
            }
        }
        
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
            
            let fileCoordinator:NSFileCoordinator = NSFileCoordinator()
            
            var error:NSError? = nil
            
            fileCoordinator.coordinateWritingItemAtURL(fileURL, options: NSFileCoordinatorWritingOptions.ForDeleting,
                error: &error,
                byAccessor: {writingURL in
                    
                    let fileManager:NSFileManager = NSFileManager()
                    
                    //var er:NSError? = nil
                    //FLOG(5, message: " deleting \(writingURL));
                    
                    let res:Bool
                    do {
                        try fileManager.removeItemAtURL(writingURL)
                        res = true
                    } catch  {
                        
                        res = false
                    }
                    
                    if (res) {
                        //FLOG(5, message: "   File removed")
                        NSOperationQueue.mainQueue().addOperationWithBlock{
                            self.postFileUpdateNotification()
                        }
                    }
                    else {
                        //FLOG(5, message: "   File  NOT removed");
                        //FLOG(5, message: "   error \(er), \(er?.userInfo)")
                    }
            })
            
        })
        
        return;
    }
    func downloadFile(fr:FileRepresentation)
    {
        //FLOG(5, message: " called");
        
        if let url = fr.url {
            
            if (downloadStatus(fr) == 1) {
                
                //FLOG(5, message: "  starting download of file \(url.lastPathComponent)");
                let fm:NSFileManager = NSFileManager()
                //var er:NSError? = nil
                
                do {
                    
                    try fm.startDownloadingUbiquitousItemAtURL(url)
                    isDownloadingBackup = true
                    showBackgroundTaskActive()
                    
                } catch {
                    //FLOG(5, message: " error starting download \(er), \(er?.userInfo)");
                }
            }
        }
    }
    func downloadStatus(fr:FileRepresentation)->Int
    {
        //if (!cloudFiles) return 3;
        
        var isDownloaded:NSNumber? = fr.isDownloaded
        let isDownloading:NSNumber? = fr.isDownloading
        let downloadedPercent:NSNumber? = fr.percentDownloaded
        
        if (fr.downloadStatus != nil) {
            if (fr.downloadStatus!.isEqualToString(NSMetadataUbiquitousItemDownloadingStatusCurrent))
            {
                isDownloaded = 1
            }
        }
        
        // if (!isDownloaded) {
        //FLOG(5, message: "Checking file \(fr.url?.lastPathComponent)");
        //FLOG(5, message: "  downloadStatus is \(fr.downloadStatus)");
        //FLOG(5, message: "  isDownloaded is \(fr.isDownloaded)");
        //FLOG(5, message: "  isDownloading is \(fr.isDownloading)");
        
        if (downloadedPercent != nil){
            //FLOG(5, message: "    downloadedPercent is \(downloadedPercent?.floatValue)");
        } else {
            //FLOG(5, message: "    downloadedPercent is NIL");
        }
        
        var ds:Int = 0
        
        if (isDownloaded != nil && isDownloading != nil) {
            
            if (!isDownloaded!.boolValue && !isDownloading!.boolValue ) {
                ds = 1;
            }
            
            if (!isDownloaded!.boolValue && isDownloading!.boolValue) {
                ds = 2;
            }
            if (isDownloaded!.boolValue) {
                ds = 3;
            }
        }
        //FLOG(5, message: "  downloadStatus is \(ds)");
        
        
        return ds;
    }
    func asynchronousRestoreFile(fileURL:NSURL, completion:(()->Void)?)
    {
        //FLOG(5, message: " called");
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
            
            // Some long running task you want on another thread
            //FLOG(5, message: " Copy Job started");
            
            self.showBackgroundTaskActive()
            
            self.restoreFile(fileURL)
            
            
            if (completion != nil) {
                NSOperationQueue.mainQueue().addOperationWithBlock {
                    completion!()
                }
            }
            
            self.showBackgroundTaskInactive()
            
        })
    }
    /**  Sets the selected file as the current store.
    Creates a backup of the current store first.
    
    @param fileURL The URL for the file to use.
    */
    func restoreFile(fileURL:NSURL)->Bool {
        //FLOG(5, message: " called");
        
        // Check if we are using iCloud
        if (isICloudEnabled) {
            
            //FLOG(5, message: " using iCloud store so OK to restore");
            
            if let _:NSURL = storeURL {
                
                //FLOG(5, message: " currentURL is \(currentURL)")
                
                //FLOG(5, message: " URL to use is \(fileURL)")
                
                saveContext()
                
                backupCurrentStoreWithNoCheck()
                
                // Close the current store and delete it
                persistentStoreCoordinator = nil;
                managedObjectContext = nil;
                
                removeICloudStore()
                
                moveStoreFileToICloud(fileURL, shouldDelete:false, shouldBackup:false)
            }
            
        } else {
            //FLOG(5, message: " using local store so OK to restore")
            if let currentURL:NSURL = storeURL {
                //FLOG(5, message: " currentURL is \(currentURL)")
                
                //FLOG(5, message: " URL to use is \(fileURL)")
                
                saveContext()
                
                backupCurrentStoreWithNoCheck()
                
                if let path = currentURL.path {
                    
                    // Close the current store and delete it
                    persistentStoreCoordinator = nil;
                    managedObjectContext = nil;
                    
                    //var error:NSError? = nil
                    let fm:NSFileManager = NSFileManager()
                    
                    // Delete the current store file
                    if (fm.fileExistsAtPath(path)) {
                        
                        //FLOG(5, message: " target file exists");
                        
                        do {
                            
                            try fm.removeItemAtURL(currentURL)
                            //FLOG(5, message: " current store file removed")
                        } catch {
                            //FLOG(5, message: " error unable to remove current store file")
                            //FLOG(5, message: "Error removing item Error: \(error), \(error?.userInfo)")
                            return false;
                        }
                    }
                    
                    if let sourcePath = fileURL.path {
                        
                        //
                        //simply copy the file over
                        let copySuccess:Bool
                        do {
                            try fm.copyItemAtPath(sourcePath,
                                toPath:path)
                            copySuccess = true
                        } catch  {
                            
                            copySuccess = false
                        }
                        
                        if (copySuccess) {
                            //FLOG(5, message: " replaced current store file successfully");
                            //[self postFileUpdateNotification];
                        } else {
                            //FLOG(5, message: "Error copying items Error: \(error), \(error?.userInfo)")
                            return false
                        }
                    } else {
                        //FLOG(5, message: "Unable to restore file as source URL path is null");
                    }
                } else {
                    //FLOG(5, message: "Unable to restore file as current URL path is null");
                }
            } else {
                //FLOG(5, message: "Unable to restore file as current URL is null");
            }
        }
        
        // Now open the store again
        
        openPersistentStore(nil)
        
        return true;
    }
    func removeICloudStore() {
        var result:Bool = false
        
        do {
            // Now delete the iCloud content and file
            try NSPersistentStoreCoordinator.removeUbiquitousContentAndPersistentStoreAtURL(iCloudStoreURL(),
                options:(iCloudStoreOptions() as [NSObject : AnyObject]))
            // Now delete the iCloud content and file
            result = true
        } catch  {
            
            result = false
        }
        
        if (!result) {
            //FLOG(5, message: " error removing store")
            //FLOG(5, message: " error \(error), \(error?.userInfo)")
            return
        } else {
            //FLOG(5, message: " Core Data store removed.")
            
            // Now delete the local file
            deleteLocalCopyOfiCloudStore()
            
            return
        }
        
    }
    func moveStoreFileToICloud(fileURL:NSURL, shouldDelete:Bool, shouldBackup:Bool)->Bool {
        //FLOG(5, message: " called");
        
        // Always make a backup of the local store before migrating to iCloud
        if (shouldBackup) {
            backupLocalStore()
        }
        
        let migrationPSC:NSPersistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: managedObjectModel)
        
        // Open the existing local store using the original options
        let sourceStore: NSPersistentStore?
        do {
            sourceStore = try migrationPSC.addPersistentStoreWithType(NSSQLiteStoreType, configuration:nil, URL:fileURL, options:(localStoreOptions() as [NSObject : AnyObject]))
        } catch _ {
            sourceStore = nil
        }
        
        if (sourceStore == nil) {
            
            //FLOG(5, message: " failed to add old store")
            return false
            
        } else {
            
            //FLOG(5, message: " Successfully added store to migrate")
            
            //var moveSuccess: Bool = false
            //var error:NSError? = nil
            
            //FLOG(5, message: " About to migrate the store...");
            // Now migrate the store using the iCloud options
            let newStore:NSPersistentStore?
            do {
                newStore = try migrationPSC.migratePersistentStore(sourceStore!, toURL:iCloudStoreURL(), options:(iCloudStoreOptions() as [NSObject : AnyObject]), withType:NSSQLiteStoreType)
            } catch  {
                
                newStore = nil
            }
            
            if (newStore != nil) {
                //moveSuccess = true
                //FLOG(5, message: "store successfully migrated");
                deregisterForStoreChanges()
                persistentStoreCoordinator = nil
                managedObjectContext = nil
                storeURL = iCloudStoreURL()
                
                // Now delete the local file
                if (shouldDelete) {
                    
                    //FLOG(5, message: " deleting local store");
                    deleteLocalStore()
                    
                } else {
                    
                    //FLOG(5, message: " not deleting local store");
                    
                }
                return true
            }
            else {
                //FLOG(5, message: "Failed to migrate store: \(error), \(error?.userInfo)");
                return false
            }
            
        }
    }
    // In this case we are deleting the local copy of an iCloud document in response
    // to detecting that the iCloud file has been removed. We need to do
    // the following:
    // 1.  Delete the local /CoreDataUbiquitySupport directory using a FileCoordinator or it won't always be
    //     removed properly!
    //
    func deleteLocalCopyOfiCloudStore() {
        // We need to get the URL to the store
        //FLOG(5, message: "deleteLocalCopyOfiCloudStore called ")
        
        let coreDataSupportFiles:NSURL = localUbiquitySupportURL()
        
        //Check is this is removing the file we are currently migrating
        //FLOG(5, message: " Deleting file \(coreDataSupportFiles)");
        
        if let path = coreDataSupportFiles.path {
            
            // Check if the CoreDataUbiquitySupport files exist
            if (!NSFileManager.defaultManager().fileExistsAtPath(path)) {
                //FLOG(5, message: " CoreDataUbiquitySupport files do not exist");
                return
            }
        }
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
            
            let fileCoordinator:NSFileCoordinator = NSFileCoordinator()
            
            var error:NSError? = nil
            
            fileCoordinator.coordinateWritingItemAtURL(coreDataSupportFiles, options:
                NSFileCoordinatorWritingOptions.ForDeleting,
                error:&error,
                byAccessor: {writingURL in
                    let fileManager:NSFileManager = NSFileManager()
                    //var er:NSError? = nil
                    
                    //FLOG(5, message: " deleting \(writingURL)");
                    let res: Bool
                    do {
                        try fileManager.removeItemAtURL(writingURL)
                        res = true
                    } catch  {
                        
                        res = false
                    }
                    
                    if (res) {
                        //FLOG(5, message: "   CoreDataSupport files removed")
                        NSOperationQueue.mainQueue().addOperationWithBlock{
                            self.postFileUpdateNotification()
                            self.postStoreChangedNotification()
                        }
                    }
                    else {
                        //FLOG(5, message: "   CoreDataSupport files  NOT removed");
                        //FLOG(5, message: "   error \(er), \(er?.userInfo)");
                    }
                    
            })
        })
        
        return;
    }
    func localUbiquitySupportURL()->NSURL {
        return applicationDocumentsDirectory.URLByAppendingPathComponent("CoreDataUbiquitySupport")
    }
    // In this case we are deleting the local copy of an iCloud document in response
    // to detecting that the iCloud file has been removed. We need to do
    // the following:
    // 1.  Delete the local /CoreDataUbiquitySupport directory using a FileCoordinator or it won't always be
    //     removed properly!
    //
    func deleteLocalStore() {
        // We need to get the URL to the store
        //FLOG(5, message: "deleteLocalStore called ")
        
        let fileURL:NSURL = localStoreURL()
        
        //Check is this is removing the file we are currently migrating
        //FLOG(5, message: " Deleting file \(fileURL)")
        
        if let path = fileURL.path {
            
            // Check if the CoreDataUbiquitySupport files exist
            if (!NSFileManager.defaultManager().fileExistsAtPath(path)) {
                //FLOG(5, message: " Local store file not exist")
                return
            }
        }
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
            
            let fileCoordinator:NSFileCoordinator = NSFileCoordinator()
            var error: NSError? = nil
            
            fileCoordinator.coordinateWritingItemAtURL(fileURL, options: NSFileCoordinatorWritingOptions.ForDeleting, error: &error, byAccessor: {writingURL in
                
                let fileManager:NSFileManager = NSFileManager()
                //var er:NSError? = nil
                
                //FLOG(5, message: " deleting \(writingURL)")
                let res:Bool
                do {
                    try fileManager.removeItemAtURL(writingURL)
                    res = true
                } catch  {
                    
                    res = false
                }
                
                if (res) {
                    //FLOG(5, message: "   Local store file removed")
                    NSOperationQueue.mainQueue().addOperationWithBlock {
                        
                        self.postFileUpdateNotification()
                        self.postStoreChangedNotification()
                    }
                }
                else {
                    //FLOG(5, message: "   Local store file  NOT removed")
                    //FLOG(5, message: "   error \(er), \(er?.userInfo)")
                }
            })
            
        })
        
        return;
    }
    
    /** This is used to import files from other Apps.  For example if we emailed ourselves a backup file then
    in Mail we can open the file with this App and we call this function to save the file to the Apps local
    /Documents directory.  It should then appear in the Backup File list and we can then restore from it.
    */
    func saveFile(fileURL:NSURL) {
        //FLOG(5, message: " called");
        importFile(fileURL)
    }
    /**  Imports file to the Apps local /Documents directory, fails if target file exists
    
    @param fileURL  URL of the file to be copied
    */
    func importFile(fileURL:NSURL) {
        //FLOG(5, message: " called");
        let fc:NSFileCoordinator = NSFileCoordinator(filePresenter: nil)
        
        let sourceURL:NSURL = fileURL
        if let filename:NSString = fileURL.lastPathComponent {
            
            if var destinationURL:NSURL = documentsDirectoryURL()?.URLByAppendingPathComponent(filename as String) {
                
                //FLOG(5, message: " source file is \(sourceURL)")
                //FLOG(5, message: " target file is \(destinationURL)")
                
                var cError:NSError? = nil
                
                fc.coordinateReadingItemAtURL(sourceURL, options: NSFileCoordinatorReadingOptions.WithoutChanges, error: &cError, byAccessor: {sourceURLToUse in
                    
                    //var error:NSError? = nil
                    let fm:NSFileManager = NSFileManager()
                    
                    if (fm.fileExistsAtPath(destinationURL.path!)) {
                        //FLOG(5, message: " target file exists");
                        let newURL:NSURL = self.getNewFileURL(destinationURL, local:true)!
                        destinationURL = newURL
                    }
                    
                    //simply copy the file over
                    let copySuccess:Bool
                    do {
                        try fm.copyItemAtPath(sourceURLToUse.path!,
                            toPath:destinationURL.path!)
                        copySuccess = true
                    } catch  {
                        
                        copySuccess = false
                    }
                    
                    if (copySuccess) {
                        
                        //FLOG(5, message: " copied file successfully")
                        self.postFileUpdateNotification()
                        
                    } else {
                        
                        //FLOG(5, message: "Error copying items Error: \(error), \(error?.userInfo)")
                        
                    }
                })
                
                if (cError != nil) {
                    //FLOG(5, message: " error is \(cError)");
                }
            }
        }
    }
    // Note that we are probably getting this from another device and so we must switch out the store UUID's
    func objectForURI(url: NSURL)->NSManagedObject? {
        
        if let array = url.pathComponents {
            var i = 0
            for comp in array {
                FLOG(5, message: " component[\(i)]: \(comp)")
                i++
            }
        }
        let storeUUID = identifierForStore()
        
        // Switch the host component to be the local storeUUID
        let newURL = NSURL(scheme: url.scheme, host: (storeUUID as! String), path: url.path!)
        
        if let _ = persistentStoreCoordinator {
            if let objectID = persistentStoreCoordinator?.managedObjectIDForURIRepresentation(newURL!) {
                if let object = managedObjectContext?.objectWithID(objectID) {
                    return object
                } else {
                    FLOG(5, message: "No object found!!");
                }
            } else {
                FLOG(5, message: "No objectID found!!");
            }
        } else {
            FLOG(5, message: "No PSC !!");
        }
        return nil
    }
    func identifierForStore()->NSString? {
        if let store = persistentStoreCoordinator?.persistentStores[0] {
            
            return store.identifier
            
        } else {
            return nil
        }
        
    }
    /// Helper function to create a background thread for running this task.
    func loadDataInBackground() {
        
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
            self.loadData()
        });
        
    }
    /// We run this on a background thread to prevent holding up the UI.  To do so we must get another
    /// managed object context and we post a notification when we are done.  This notification must be processed
    /// by the main context in order to then merge the changes into the main context.
    /// Alternately the main context must register for NSManagedObjectContextDidSaveNotification notifications
    /// from this background context and then perform the merge.
    /// We can use this to load or delete records...
    func loadData() {
    }
    /*
    FLOG(5, message: " called");
    _loadJobCount++;
    self.postJobStartedNotification()
    
    //FLOG(@" waiting 5 seconds, just to slow things down to simulate a long running job...");
    sleep(5);
    self.showBackgroundTaskActive()
    
    let bgContext = NSManagedObjectContext(concurrencyType: NSConfinementConcurrencyType)
    
    // Register for saves in order to merge any data from background threads
    NSNotificationCenter.defaultCenter().addObserver(self, selector:"storesDidSave:", name: NSManagedObjectContextDidSaveNotification, object:bgContext)
    
    
    while (self.persistentStoreCoordinator == nil) {
    //FLOG(@" persistentStoreCoordinator = nil, waiting 5 seconds to try again...");
    sleep(5);
    }
    
    bgContext.persistentStoreCoordinator = self.persistentStoreCoordinator
    
    //FLOG(@" starting load...");
    
    for (let i:int = 1; i<=5; i++) {
    // Add a few companies
    self.insertNewCompany(bgContext, count:5)
    bgContext.processPendingChanges()
    
    // Save the context.
    try {
    bgContext.save()
    }catch {
    FLOG(@"  Unresolved error %@, %@", error, [error userInfo]);
    }
    //FLOG(@"   waiting 2 seconds...");
    sleep(0.01);
    }
    
    // Deregister for saves in order to merge any data from background threads
    NSNotificationCenter.defaultCenter().removeObserver(self, name: NSManagedObjectContextDidSaveNotification, object:bgContext)
    
    //FLOG(@" loading ended...");
    self.showBackgroundTaskInactive()
    
    sleep(2);
    _loadJobCount--;
    self.postJobDoneNotification()
    }
    - (void)deleteData {
    FLOG(@"deleteData called");
    _deleteJobCount++;
    [self postJobStartedNotification];
    
    FLOG(@" waiting 5 seconds...");
    sleep(5);
    [self showBackgroundTaskActive];
    
    NSManagedObjectContext *bgContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    
    // Register for saves in order to merge any data from background threads
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(storesDidSave:) name: NSManagedObjectContextDidSaveNotification object:bgContext];
    
    
    while (self.persistentStoreCoordinator == nil) {
    FLOG(@" persistentStoreCoordinator = nil, waiting 5 seconds to try again...");
    sleep(5);
    }
    
    bgContext.persistentStoreCoordinator = [self persistentStoreCoordinator];
    
    FLOG(@" fetching data...");
    
    NSArray *companies = [self getData:@"Company" sortField:@"name" predicate:nil managedObjectContext:bgContext];
    
    NSUInteger count = companies.count;
    
    if (count>2) {
    for (int i = 0; i<3; i++) {
    NSManagedObject *object = [companies objectAtIndex:i];
    
    // Must wrap this incase another thread deleted it already
    @try {
    if ([object isDeleted]) {
    FLOG(@" object has been deleted");
    } else {
    FLOG(@" deleting %@", [object valueForKey:@"name"]);
    [bgContext deleteObject:object];
    [bgContext processPendingChanges];
    NSError *error = nil;
    if (![bgContext save:&error]) {
    FLOG(@"  Unresolved error %@, %@", error, [error userInfo]);
    }
    }
    }
    @catch (NSException *exception) {
    FLOG(@" error deleting object");
    FLOG(@"   exception is %@", exception);
    }
    
    
    FLOG(@"   waiting 5 seconds...");
    sleep(0.01);
    }
    
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name: NSManagedObjectContextDidSaveNotification object:bgContext];
    
    /*
    dispatch_async(dispatch_get_main_queue(),^(void){
    [[NSNotificationCenter defaultCenter] removeObserver:self name: NSManagedObjectContextDidSaveNotification object:nil];
    });
    */
    
    FLOG(@" delete ended...");
    [self showBackgroundTaskInactive];
    _deleteJobCount--;
    [self postJobDoneNotification];
    
    }
    */
    #if os(iOS)
    // This is an EXIT POINT for checkUserICloudPreferenceAndSetupIfNecessary
    // So we much call any passed in completion block
    func promptUserAboutICloudDocumentStorage(completion:(()->Void)?) {
    
    let title: String = "You're not using iCloud"
    var message: String? = nil
    let option1: String = "Keep using iCloud"
    var option2: String? = nil
    var option3: String? = nil
    
    
    if (UIDevice.currentDevice().userInterfaceIdiom == UIUserInterfaceIdiom.Phone) {
    
    message = "What would you like to do with documents currently on this phone?"
    option2 = "Keep on My iPhone"
    option3 = "Delete from My iPhone"
    
    } else {
    
    message = "What would you like to do with documents currently on this iPad?"
    option2 = "Keep on My iPad"
    option3 = "Delete from My iPad"
    
    
    }
    
    NSOperationQueue.mainQueue().addOperationWithBlock {
    
    
    // Use an Alert Controller with ActionSheet style
    var popup: UIAlertController? = nil
    popup = UIAlertController(title: title, message: message, preferredStyle: UIAlertControllerStyle.Alert)
    
    popup?.addAction(UIAlertAction(title: option1, style: UIAlertActionStyle.Default, handler: {(alert: UIAlertAction!) in
    
    //FLOG(5, message: " 'Keep using iCloud' selected");
    //FLOG(5, message: " turn Use iCloud back ON");
    NSUserDefaults.standardUserDefaults().setBool(true, forKey:Constants.iCloudPreferenceKey)
    NSUserDefaults.standardUserDefaults().synchronize()
    self.useICloudStorage = true
    self.setIsCloudEnabled(true)
    self.postFileUpdateNotification()
    // call the completion block
    if (completion != nil) {
    NSOperationQueue.mainQueue().addOperationWithBlock {
    completion!()
    }
    }
    }))
    popup?.addAction(UIAlertAction(title: option2!, style: UIAlertActionStyle.Default, handler: {(alert: UIAlertAction!) in
    
    //FLOG(5, message: " 'Keep on My iPhone' selected");
    //FLOG(5, message: " copy to local storage");
    self.useICloudStorage = false
    self.deleteICloudFiles = false;
    self.setIsCloudEnabled(false)
    self.postFileUpdateNotification()
    // call the completion block
    if (completion != nil) {
    NSOperationQueue.mainQueue().addOperationWithBlock {
    completion!()
    }
    }
    }))
    popup?.addAction(UIAlertAction(title: option3!, style: UIAlertActionStyle.Default, handler: {(alert: UIAlertAction!) in
    
    //FLOG(5, message: " 'Delete from My iPhone' selected");
    //FLOG(5, message: " delete copies from iPhone");
    self.useICloudStorage = false
    self.deleteICloudFiles = true;
    self.setIsCloudEnabled(false)
    self.postFileUpdateNotification()
    // call the completion block
    if (completion != nil) {
    NSOperationQueue.mainQueue().addOperationWithBlock {
    completion!()
    }
    }
    
    }))
    if (popup != nil) {
    
    // Present this in the center
    
    if let controller = UIApplication.sharedApplication().keyWindow?.rootViewController {
    
    
    if let view:UIView = UIApplication.sharedApplication().keyWindow?.subviews.last {
    
    popup?.popoverPresentationController?.sourceView = view
    
    controller.presentViewController(popup!, animated: true, completion: nil)
    }
    }
    
    }
    
    }
    }
    // This is an EXIT POINT for checkUserICloudPreferenceAndSetupIfNecessary
    // So we much call any passed in completion block
    func promptUserAboutSeedData(completion:(()->Void)?) {
    
    let title: String = "You're using iCloud"
    var message: String? = nil
    var option1: String? = nil
    var option2: String? = nil
    
    
    message = "Have you already shared Info on iCloud from another device?"
    option1 = "Yes, Info is already shared in iCloud"
    option2 = "No, Info is not already shared in iCloud"
    
    NSOperationQueue.mainQueue().addOperationWithBlock {
    
    // Use an Alert Controller with ActionSheet style
    var popup: UIAlertController? = nil
    popup = UIAlertController(title: title, message: message, preferredStyle: UIAlertControllerStyle.Alert)
    
    popup?.addAction(UIAlertAction(title: option1, style: UIAlertActionStyle.Default, handler: {(alert: UIAlertAction!) in
    
    //FLOG(5, message: " Info is already shared so don't load seed data");
    self.load_seed_data = false
    // call the completion block
    if (completion != nil) {
    NSOperationQueue.mainQueue().addOperationWithBlock {
    completion!()
    }
    }
    }))
    popup?.addAction(UIAlertAction(title: option2!, style: UIAlertActionStyle.Default, handler: {(alert: UIAlertAction!) in
    
    //FLOG(5, message: " Info is NOT already shared so load seed data");
    self.load_seed_data = true
    
    // call the completion block
    if (completion != nil) {
    NSOperationQueue.mainQueue().addOperationWithBlock {
    completion!()
    }
    }
    }))
    
    if (popup != nil) {
    
    // Present this in the center
    
    if let controller = UIApplication.sharedApplication().keyWindow?.rootViewController {
    
    
    if let view:UIView = UIApplication.sharedApplication().keyWindow?.subviews.last {
    
    popup?.popoverPresentationController?.sourceView = view
    
    controller.presentViewController(popup!, animated: true, completion: nil)
    }
    }
    
    }
    }
    }
    #else
    /// DELEGATE METHODS!
    
    /// This method is called when Use iCloud preference has been turned OFF to ask the user whether they want to keep iCloud files, delete them or keep using iCloud
    ///
    ///:returns: CD.Constants.MoveStore, CDConstants.DeleteStore, CDConstants.KeepStore
    func promptUserAboutICloudDocumentStorage()->Int {
        FLOG(5, message: " called")
        
        let question = NSLocalizedString("You're not using iCloud but no local file exists and an iCloud file has been detected, what would your like to do? ", comment: "Choose Storage Option question")
        let info = NSLocalizedString("Choose a storage option", comment: "Choose Storage Option info")
        let icloudButton = NSLocalizedString("Keep using iCloud", comment: "iCloud button title")
        let keepButton = NSLocalizedString("Move to my Mac", comment: "Keep button title")
        let deleteButton = NSLocalizedString("Delete from my Mac", comment: "Keep button title")
        
        
        var answer = NSAlertFirstButtonReturn
        
        dispatch_sync(dispatch_get_main_queue(), {
            
            let alert = NSAlert()
            alert.messageText = question
            alert.informativeText = info
            alert.addButtonWithTitle(icloudButton)
            alert.addButtonWithTitle(keepButton)
            alert.addButtonWithTitle(deleteButton)
        
            answer = alert.runModal()
            
        })
        
        if (answer == NSAlertFirstButtonReturn) {
            return CDConstants.KeepStore
        }
        else if (answer == NSAlertSecondButtonReturn) {
            return CDConstants.MoveStore
        }else {
            return CDConstants.DeleteStore
        }
    }
    /// Prompts user for storage option if the option has not been set
    /// OS X Version
    ///:returns: True or False
    func mergeWithICloudChoiceAlert()->Bool {
        FLOG(5, message: " called")
        
        let question = NSLocalizedString("iCloud file detected, choose an option.", comment: "Choose Storage Option question")
        let info = NSLocalizedString("Choose a storage option", comment: "Choose Storage Option info")
        let mergeButton = NSLocalizedString("Merge data", comment: "Merge button title")
        let icloudButton = NSLocalizedString("Use the iCloud data", comment: "iCloud button title")
        
        
        var answer = NSAlertFirstButtonReturn
        
        dispatch_sync(dispatch_get_main_queue(), {
        
            let alert = NSAlert()
            alert.messageText = question
            alert.informativeText = info
            alert.addButtonWithTitle(mergeButton)
            alert.addButtonWithTitle(icloudButton)
        
            answer = alert.runModal()
            
        })
        
        if (answer == NSAlertFirstButtonReturn) {
            return true
        }
        else {
            return false
        }
    }
    /// Prompts user for storage option if its not set
    func cloudChoiceAlert()->Bool {
        FLOG(5, message: "cloudChoiceAlert called")
        
        let question = NSLocalizedString("Should documents be stored in iCloud or on just this device?", comment: "Choose Storage Option question");
        let info = NSLocalizedString("Choose a storage option", comment: "Choose Storage Option info");
        let localButton = NSLocalizedString("Local only", comment: "Local only button title");
        let icloudButton = NSLocalizedString("iCloud", comment: "iCloud button title");
        
        var answer = NSAlertFirstButtonReturn
        
        dispatch_sync(dispatch_get_main_queue(), {
            
            let alert = NSAlert()
            alert.messageText = question
            alert.informativeText = info
            alert.addButtonWithTitle(localButton)
            alert.addButtonWithTitle(icloudButton)
        
            answer = alert.runModal()
            
        })
        
        if (answer == NSAlertFirstButtonReturn) {
            // Set the preference
            NSUserDefaults.standardUserDefaults().setBool(false, forKey:Constants.iCloudPreferenceKey)
            let stringVal: NSString = "YES"
            NSUserDefaults.standardUserDefaults().setValue(stringVal, forKey:Constants.iCloudPreferenceSelected)
            self.useICloudStorage = false
            return false
        }
        else {
            // Set the preference
            NSUserDefaults.standardUserDefaults().setBool(true, forKey:Constants.iCloudPreferenceKey)
            let stringVal: NSString = "YES"
            NSUserDefaults.standardUserDefaults().setValue(stringVal, forKey:Constants.iCloudPreferenceSelected)
            self.useICloudStorage = true
            return true
        }
    }
    #endif
}