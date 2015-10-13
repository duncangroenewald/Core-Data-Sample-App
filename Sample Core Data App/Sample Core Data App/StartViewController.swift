//
//  StartViewController.swift
//  Sample Core Data App
//
//  Created by Duncan Groenewald on 13/10/2015.
//  Copyright © 2015 OSSH Pty Ltd. All rights reserved.
//

import UIKit

class StartViewController: UIViewController {
    
    @IBOutlet var mainSVController: UISplitViewController!;
    @IBOutlet var message: UILabel!;
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Do any additional setup after loading the view.
        self.message("Loading...")
        
        // We must call the Core Data setup code on a background thread because 
        // some functions may take a long time, especially if iCloud is being used
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), {
            
            // Set the version number in the Settings App settings page for this App
            cdManager.setVersion()
            
            NSThread.sleepForTimeInterval(2)
            
            self.message("Performing check 1...")
            
            NSThread.sleepForTimeInterval(2)
            
            self.message("Performing check 2...")
            
            NSThread.sleepForTimeInterval(2)
            
            self.message("Performing check 3...")
            
            NSThread.sleepForTimeInterval(2)
            
            if (cdManager.checkCDModelVersion()) {
                FLOG(0, message:" Upgrade is required");
                
                FLOG(0, message:" Open the Update screens");
                
                dispatch_async(dispatch_get_main_queue(), {
                    //Now show the next view from the main thread
                    self.openUpdateViews()
                })
                
            } else {
                FLOG(0, message:" Upgrade is not required");
                FLOG(0, message:" Open the Menu screens");
                dispatch_async(dispatch_get_main_queue(), {
                    //Now show the next view from the main thread
                    //self.openMainViews()
                    self.openUpdateViews()
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
        
        self.performSegueWithIdentifier("MainViewSegue", sender: self)

        
        return
    }
    func openUpdateViews() {
        FLOG(0, message:" called")
        self.performSegueWithIdentifier("UpdateViewSegue", sender: self)
        
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
