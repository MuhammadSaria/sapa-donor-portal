public with sharing class RecurringPDFController {
                public String recordId { get; set; }
                public List<GiftCommitment> donations { get; set; }

                public RecurringPDFController() {
                recordId = ApexPages.currentPage().getParameters().get('id');

                if (recordId != null) {

                donations = [
                SELECT 
    				Receipt_Allocations__c,
                    Name,
    				Donor_Name__c, 
    				Donor_ID__c, 
                    Donor.Name,
              		Donor.Secondary_Full_Name__c,
    				Donor.PersonMailingStreet,
                    Donor.PersonMailingCity,
                    Donor.PersonMailingCountry,
                    Donor.PersonMailingPostalCode,
                    Receipt_Number__c, 
                    Status,
                        (SELECT StartDate, TransactionPeriod, TransactionAmount, PaymentMethod
                         FROM GiftCommitmentSchedules)
                    FROM GiftCommitment
                                    WHERE Id = :recordId
                                    ];
                                    } else {
                                    donations = new List<GiftCommitment>();
                                    }
                                    }
                                    }