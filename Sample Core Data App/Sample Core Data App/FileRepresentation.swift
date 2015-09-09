//
//  FileRepresentation.swift
//
//  Created by Duncan Groenewald on 5/10/2014.
//  Copyright (c) 2014 Duncan Groenewald. All rights reserved.
//
//  This class is used for iCloud MetaData Queries
//

import Foundation

@objc class FileRepresentation: NSObject {
    
    dynamic var filename: NSString? = nil
    dynamic var url: NSURL? = nil
    dynamic var fileDate: NSString? = nil
    dynamic var downloadStatus: NSString? = nil
    dynamic var nameOfSavingComputer: NSString? = nil
    dynamic var percentDownloaded: NSNumber? = nil
    dynamic var isDownloaded: NSNumber? = nil
    dynamic var isDownloading: NSNumber? = nil
    dynamic var ready: Bool = false
    
    init(filename: NSString, url: NSURL) {
        self.filename = filename
        self.url = url
    }
    init(filename: NSString, url: NSURL, date: NSString) {
        self.filename = filename
        self.url = url
        self.fileDate = date
    }
    init(filename: NSString, url: NSURL, percentDownloaded: NSNumber?) {
        self.filename = filename
        self.url = url
        self.percentDownloaded = percentDownloaded
    }
    init(filename: NSString, url: NSURL, percentDownloaded: NSNumber?, computer: NSString) {
        self.filename = filename
        self.url = url
        self.percentDownloaded = percentDownloaded
        self.nameOfSavingComputer = computer
    }
    func isEqualTo(object: FileRepresentation)->Bool
    {
        if let filename = object.filename {
            return self.filename?.isEqualToString(filename as String) ?? false
        } else {
            return false
        }
    }
    var modifiedDate: NSString? {
        
       
        var filedate: AnyObject? = nil
        
        do {
            
            try self.url?.getResourceValue(&filedate, forKey:NSURLContentModificationDateKey)
        
            
            if let date = filedate as? NSDate {
         
                let dateFormatter: NSDateFormatter = NSDateFormatter()
            
                dateFormatter.dateStyle = NSDateFormatterStyle.MediumStyle
            
                dateFormatter.timeStyle = NSDateFormatterStyle.MediumStyle
            
                return dateFormatter.stringFromDate(date)
            }
            
        } catch {
            
        }
        
        return ""

    }
}
