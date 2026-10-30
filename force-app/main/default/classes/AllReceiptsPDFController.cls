public with sharing class AllReceiptsPDFController {
    public List<GiftTransaction> donations { get; set; }

    public AllReceiptsPDFController() {
        // Query donations
        donations = [
            SELECT Id,
            Final_Amount__c,
            Paper_Receipt_Requested__c,
            Primary_Contact_Email__c,
            Donor_ID__c,
            TransactionDate,
            Receipt_Allocations__c,
            Donation_Note__c,
            Receipt_Number__c,
            Donor.Name,
            Donor.PersonMailingStreet,
                       Donor.PersonMailingCity,
                       Donor.PersonMailingCountry,
                       Donor.PersonMailingPostalCode,
             PaymentMethod,Name,
            Status,
            GiftCommitmentId
            FROM GiftTransaction
            WHERE 
            Paper_Receipt_Requested__c = 'Receipt Requested'
            AND Status = 'Paid'
            And GiftCommitmentId = null
            ORDER BY Donor.Name ASC
        ];

    }
    
}