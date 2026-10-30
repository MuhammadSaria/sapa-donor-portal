public with sharing class AllReceiptsPDFControllerForRecurring {
    public List<GiftCommitment> donations { get; set; }

    public AllReceiptsPDFControllerForRecurring() {

        donations = [
                SELECT 
    				   Receipt_Allocations__c,
                       Name,
                       Donor_Name__c, 
                       Donor_ID__c, 
                       Donor.PersonMailingStreet,
                       Donor.PersonMailingCity,
                       Donor.PersonMailingCountry,
                       Donor.PersonMailingPostalCode,
            		   Donor.Name,
                       Donor.Secondary_Full_Name__c,
                       Receipt_Number__c, 
                       Status,
    (SELECT StartDate, TransactionPeriod, TransactionAmount, PaymentMethod
     FROM GiftCommitmentSchedules)
                Id FROM GiftCommitment
            WHERE Paper_Receipt__c = 'Receipt Requested'
              AND Status = 'Active' And Payment_Profile_ID__c != null 
        ];

        
        
        } 
}