# Core-Data-Sample-App
Sample Core Data Apps for iOS and OSX using Swift.

After encountering many requests from app developers new to Core Data and iCloud for assistance I have finally decided to 
create a repository for migrating the existing sample apps into.  My aim is to update the samples to be pure Swift 2.0 
and to address the most commonly encountered questions, including:
<ul>
<li>how to create, update and delete Core Data objects.  Core Data is a hybrid object/relational database solution and as 
such requires some understanding of how to create new objects using the Core Data API, which is necessary to ensure the objects
are persisted in the underlying SQLite database system.

<li>setting up a Core Data stack to handle various iCloud scenarios, such as when the user is not using iCloud, or when they log in
or out of iCloud

<li>how to handle populating seed data in the database the first time a user runs an instance of the app and how to avoid 
creating duplicates when the app is installed and run on another device

<li>how to create a tableView and populate it with items from the database such that inserts, updates and deletes to the 
objects are automatically reflected in the tableView
</ul>
Feel free to fix any bugs and please bear in mind this app is purely for demonstration purposes to assist those just starting out
on this journey.

If you are a beginner I would recommend you start by getting early versions and make sure you understand the concepts before
you pick a version that has much additional functionality implemented.

I am not that familiar with using the GitHub repository so bear with me as I find my way around.

<b>Version 1.0</b>

iOS only version created with XCode 7 Beta 6 Master-Detail template and modified to use CoreDataStack Manager.

<i>Note that you will need to modify the company/team/developer identifiers before running the app.</i>
