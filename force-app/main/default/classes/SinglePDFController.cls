public with sharing class SinglePDFController {
    public String recordId { get; set; }
    public List<GiftTransaction> donations { get; set; }

    public SinglePDFController() {
        // Get Id from URL
        recordId = ApexPages.currentPage().getParameters().get('id');

        if (recordId != null) {
            donations = [
                SELECT Id,
                       Final_Amount__c,
                       Paper_Receipt_Requested__c,
                       Primary_Contact_Email__c,
                       Donor_ID__c,
                       TransactionDate,
                       PaymentMethod,
                       Receipt_Allocations__c,
                       Donation_Note__c,
                       Receipt_Number__c,
                       Donor.PersonEmail,
                       Donor.Name,
              		   Donor.Secondary_Full_Name__c,
                       Donor.PersonMailingStreet,
                       Donor.PersonMailingCity,
                       Donor.PersonMailingCountry,
                       Donor.PersonMailingPostalCode,
                       Status,
                       Name,
                       GiftCommitmentId
                  FROM GiftTransaction
                 WHERE Id = :recordId
            ];
            
            
            /* ApexPages.currentPage().getHeaders().put(
            'Content-Disposition',
            'attachment; filename=Donation_' + donations[0].Name + '.pdf');
            */
        } else {
            donations = new List<GiftTransaction>();
        }
    }
}