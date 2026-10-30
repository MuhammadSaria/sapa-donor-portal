global class ContactEmailPDFBatch implements Database.Batchable<SObject> {
    
    private String startYear;
    private String endYear;
    
    public ContactEmailPDFBatch(String startYear, String endYear)
    {
        system.debug('startYear -- '+startYear);
        system.debug('endyear  '+endYear);
        this.startYear = startYear;
        this.endYear = endYear;
    }
    
    global Database.QueryLocator start(Database.BatchableContext BC) {
        List<Id> recordIds = new List<Id>{'003D100000auXIJIA2'};
            
            // Query all contacts you want to process
            return Database.getQueryLocator('select id, name,Preferred_Email__c,PersonEmail,Alternate_Email__c, Work_Email__c from Account'); // Adjust the query as needed
    }
    
    global void execute(Database.BatchableContext BC, List<SObject> scope) {
        // Convert scope to list of Contacts
        List<Contact> contacts = (List<Contact>) scope;
        
        // Define the date range (example dates; adjust as needed)
        Date fromDate = Date.ValueOF(startYear); // 30 days ago
        Date toDate = Date.ValueOF(endYear);
        
        // Process each contact
        for (Contact con : contacts) {
            DonationPDFLWCController.sendEmail(con.Id, fromDate, toDate);
        }
    }
    
    global void finish(Database.BatchableContext BC) {
        // Optional: Any post-processing, logging, or chaining another batch
    }
}