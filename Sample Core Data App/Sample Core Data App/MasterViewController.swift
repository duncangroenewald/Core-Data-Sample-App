//
//  MasterViewController.swift
//  Sample Core Data App
//
//  Created by Duncan Groenewald on 9/09/2015.
//  Copyright © 2015 OSSH Pty Ltd. All rights reserved.
//

import UIKit
import CoreData

class MasterViewController: UITableViewController, NSFetchedResultsControllerDelegate {
    
    var detailViewController: DetailViewController? = nil
    var managedObjectContext: NSManagedObjectContext? = nil
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        NSNotificationCenter.defaultCenter().addObserver(self, selector:"storeOpened", name:CDConstants.OSStoreOpenedNotification,
            object:cdManager)
        NSNotificationCenter.defaultCenter().addObserver(self, selector:"refreshUI", name:CDConstants.OSDataUpdatedNotification,
            object:cdManager)
        
        // Now open Core Data
        // This will post a StoreChanged notification when done
        
        cdManager.checkUserICloudPreferenceAndSetupIfNecessary({
            FLOG("checkUserICloudPreferenceAndSetupIfNecessary done.")
        })
        
        // Do any additional setup after loading the view, typically from a nib.
        self.navigationItem.leftBarButtonItem = self.editButtonItem()
        
        let addButton = UIBarButtonItem(barButtonSystemItem: .Add, target: self, action: "insertNewObject:")
        self.navigationItem.rightBarButtonItem = addButton
        
        if let split = self.splitViewController {
            let controllers = split.viewControllers
            self.detailViewController = (controllers[controllers.count-1] as! UINavigationController).topViewController as? DetailViewController
        }
    }
    
    override func viewWillAppear(animated: Bool) {
        self.clearsSelectionOnViewWillAppear = self.splitViewController!.collapsed
        super.viewWillAppear(animated)
    }
    // Call this when the store is opened
    func storeOpened() {
        FLOG(" called")
        FLOG("Core Data store has been opened")
        self.managedObjectContext = cdManager.managedObjectContext
        self.reloadB()
    }
    func refreshUI() {
        FLOG(" called")
        self.reloadB()
    }
    //
    func reloadB() {
        self.tableView.reloadData()
    }
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    func insertNewObject(sender: AnyObject) {
        
        if let frc = self.fetchedResultsController {
            
            let context = frc.managedObjectContext
            let entity = frc.fetchRequest.entity!
            let newManagedObject = NSEntityDescription.insertNewObjectForEntityForName(entity.name!, inManagedObjectContext: context)
            
            // If appropriate, configure the new managed object.
            // Normally you should use accessor methods, but using KVC here avoids the need to add a custom class to the template.
            newManagedObject.setValue(NSDate(), forKey: "timeStamp")
            
            // Save the context.
            do {
                try context.save()
            } catch let error as NSError {
                
                print("Unresolved error \(error), \(error.userInfo)")
                
            }
        }
    }
    
    // MARK: - Segues
    
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject?) {
        if segue.identifier == "showDetail" {
            if let indexPath = self.tableView.indexPathForSelectedRow {
                if let frc = self.fetchedResultsController {
                    let object = frc.objectAtIndexPath(indexPath)
                    let controller = (segue.destinationViewController as! UINavigationController).topViewController as! DetailViewController
                    controller.detailItem = object
                    controller.navigationItem.leftBarButtonItem = self.splitViewController?.displayModeButtonItem()
                    controller.navigationItem.leftItemsSupplementBackButton = true
                }
            }
        }
    }
    
    // MARK: - Table View
    
    override func numberOfSectionsInTableView(tableView: UITableView) -> Int {
        if let frc = self.fetchedResultsController {
            return frc.sections?.count ?? 0
        } else {
            return 0
        }
    }
    
    override func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if let frc = self.fetchedResultsController {
            let sectionInfo = frc.sections![section]
            return sectionInfo.numberOfObjects
        } else {
            return 0
        }
    }
    
    override func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellWithIdentifier("Cell", forIndexPath: indexPath)
        self.configureCell(cell, atIndexPath: indexPath)
        return cell
    }
    
    override func tableView(tableView: UITableView, canEditRowAtIndexPath indexPath: NSIndexPath) -> Bool {
        // Return false if you do not want the specified item to be editable.
        return true
    }
    
    override func tableView(tableView: UITableView, commitEditingStyle editingStyle: UITableViewCellEditingStyle, forRowAtIndexPath indexPath: NSIndexPath) {
        if editingStyle == .Delete {
            if let frc = self.fetchedResultsController {
                let context = frc.managedObjectContext
                context.deleteObject(frc.objectAtIndexPath(indexPath) as! NSManagedObject)
                
                do {
                    try context.save()
                } catch let error as NSError {
                    
                    print("Unresolved error while saving \(error), \(error.userInfo)")
                    
                }
            }
        }
    }
    // Check if FRC is not nil, if its nil then Core Data store is not initialised yet
    func configureCell(cell: UITableViewCell, atIndexPath indexPath: NSIndexPath) {
        if let frc = self.fetchedResultsController {
            let object = frc.objectAtIndexPath(indexPath)
            cell.textLabel!.text = object.valueForKey("timeStamp")!.description
        }
    }
    
    // MARK: - Fetched results controller
    
    // We have to check for a nil MOC here because the store may not be initialised yet
    var fetchedResultsController: NSFetchedResultsController? {
        if _fetchedResultsController != nil {
            return _fetchedResultsController!
        }
        
        if let moc = cdManager.managedObjectContext {
            
            let fetchRequest = NSFetchRequest()
            // Edit the entity name as appropriate.
            let entity = NSEntityDescription.entityForName("Event", inManagedObjectContext: moc)
            fetchRequest.entity = entity
            
            // Set the batch size to a suitable number.
            fetchRequest.fetchBatchSize = 20
            
            // Edit the sort key as appropriate.
            let sortDescriptor = NSSortDescriptor(key: "timeStamp", ascending: false)
            
            fetchRequest.sortDescriptors = [sortDescriptor]
            
            // Edit the section name key path and cache name if appropriate.
            // nil for section name key path means "no sections".
            let aFetchedResultsController = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: self.managedObjectContext!, sectionNameKeyPath: nil, cacheName: "Master")
            aFetchedResultsController.delegate = self
            _fetchedResultsController = aFetchedResultsController
            
            do {
                try _fetchedResultsController!.performFetch()
            } catch let error as NSError {
                print("Unresolved error while fetching data \(error), \(error.userInfo)")
                
            }
            
            return _fetchedResultsController!
            
        } else {
            
            return nil
            
        }
    }
    var _fetchedResultsController: NSFetchedResultsController? = nil
    
    func controllerWillChangeContent(controller: NSFetchedResultsController) {
        self.tableView.beginUpdates()
    }
    
    func controller(controller: NSFetchedResultsController, didChangeSection sectionInfo: NSFetchedResultsSectionInfo, atIndex sectionIndex: Int, forChangeType type: NSFetchedResultsChangeType) {
        switch type {
        case .Insert:
            self.tableView.insertSections(NSIndexSet(index: sectionIndex), withRowAnimation: .Fade)
        case .Delete:
            self.tableView.deleteSections(NSIndexSet(index: sectionIndex), withRowAnimation: .Fade)
        default:
            return
        }
    }
    
    func controller(controller: NSFetchedResultsController, didChangeObject anObject: AnyObject, atIndexPath indexPath: NSIndexPath?, forChangeType type: NSFetchedResultsChangeType, newIndexPath: NSIndexPath?) {
        switch type {
        case .Insert:
            tableView.insertRowsAtIndexPaths([newIndexPath!], withRowAnimation: .Fade)
        case .Delete:
            tableView.deleteRowsAtIndexPaths([indexPath!], withRowAnimation: .Fade)
        case .Update:
            self.configureCell(tableView.cellForRowAtIndexPath(indexPath!)!, atIndexPath: indexPath!)
        case .Move:
            tableView.deleteRowsAtIndexPaths([indexPath!], withRowAnimation: .Fade)
            tableView.insertRowsAtIndexPaths([newIndexPath!], withRowAnimation: .Fade)
        }
    }
    
    func controllerDidChangeContent(controller: NSFetchedResultsController) {
        self.tableView.endUpdates()
    }
    
    /*
    // Implementing the above methods to update the table view in response to individual changes may have performance implications if a large number of changes are made simultaneously. If this proves to be an issue, you can instead just implement controllerDidChangeContent: which notifies the delegate that all section and object changes have been processed.
    
    func controllerDidChangeContent(controller: NSFetchedResultsController) {
    // In the simplest, most efficient, case, reload the table view.
    self.tableView.reloadData()
    }
    */
    
}

