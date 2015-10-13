//
//  UpgradeViewController.swift
//  Sample Core Data App
//
//  Created by Duncan Groenewald on 14/10/2015.
//  Copyright © 2015 OSSH Pty Ltd. All rights reserved.
//

import UIKit

class UpgradeViewController: UIViewController {

    @IBOutlet var message: UILabel!;
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Do any additional setup after loading the view.
        self.message("Upgrading data...")
        
        // We must call the Core Data setup code on a background thread because
        // some functions may take a long time, especially if iCloud is being used
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
            
            // Set the version number in the Settings App settings page for this App
            cdManager.setVersion()
            
            NSThread.sleepForTimeInterval(2)
            
            self.message("Backing up data...")
            
            NSThread.sleepForTimeInterval(2)
            
            self.message("Removing data from iCloud...")
            
            NSThread.sleepForTimeInterval(2)
            
            self.message("Upgrading data...")
            
            NSThread.sleepForTimeInterval(2)
            
            self.message("Restoring data to iCloud...")
            
            NSThread.sleepForTimeInterval(2)
            
            if (cdManager.checkCDModelVersion()) {
                FLOG(0, message:" Upgrade is STILL required!!");
                
               self.message("Oops something when wrong !!!")
                
            } else {
                FLOG(0, message:" Upgrade is not required");
                FLOG(0, message:" Open the Menu screens");
                dispatch_async(dispatch_get_main_queue(), {
                    //Now show the next view from the main thread
                    self.openMainViews()
                    
                })
            }
            
        })
    }
    func message(message: String) {
        dispatch_async(dispatch_get_main_queue(), {
            self.message.text = message
        })
    }
    func openMainViews() {
        FLOG(0, message:" called")
        
        self.performSegueWithIdentifier("MainViewSegue2", sender: self)
        
        
        return
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    
    
    // MARK: - Navigation
    
    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject?) {
        // Get the new view controller using segue.destinationViewController.
        // Pass the selected object to the new view controller.
        FLOG(1, message: " prepareForSegue() called");
    }

}
