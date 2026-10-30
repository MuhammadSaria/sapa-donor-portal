public class AnnualTaxReceiptPDFController {
    public Account contact { get; set; }
    public List<GiftTransaction> opportunities { get; set; }
    public Decimal totalDonation {get; set;}
    public String formattedStartDate {get; set;}
    public String formattedendYearDate {get; set;}
    public String receiptNo {get; set;}
   // public String donationYear {get; set;}
    
    
    // Constructor to fetch the Contact and related Opportunities
    public AnnualTaxReceiptPDFController() {
        // Get the contactId from the URL
        String contactId = ApexPages.currentPage().getParameters().get('contactId');
        Date startYear = Date.ValueOf(ApexPages.currentPage().getParameters().get('startYear'));
        Date endYear = Date.ValueOf(ApexPages.currentPage().getParameters().get('endYear'));

    
        List<String> monthNames = new List<String>{'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'};

        Integer startDay = startYear.day();
        Integer startMonth = startYear.month();
        Integer startYea = startYear.year();
        String startMonthName = monthNames[startMonth - 1];
        formattedStartDate = startMonthName + ' ' + startDay + ', ' + startYea;

        Integer endDay = endYear.day();
        Integer endMonth = endYear.month();
        Integer endYea = endYear.year();
        String endMonthName = monthNames[endMonth - 1];
        formattedendYearDate = endMonthName + ' ' + endDay + ', ' + endYea;

        totalDonation = 0;
        
        // Fetch the Contact as per recordId
        if (contactId != null) {
            contact = [SELECT Id, Name, Secondary_Full_Name__c, PersonEmail, Donor_ID__c, PersonMailingStreet, PersonMailingCity, PersonMailingState, PersonMailingPostalCode,
           PersonMailingCountry FROM Account WHERE Id = :contactId LIMIT 1];
            
           /* if(contact.Annual_Receipt_Serial_No__c == NULL || contact.Annual_Receipt_Serial_No__c == 0 )
            {
                contact.Annual_Receipt_Serial_No__c = 1;

            }
            else
            {
                contact.Annual_Receipt_Serial_No__c = contact.Annual_Receipt_Serial_No__c + 1;
            }*/
		
            receiptNo = contact.Donor_ID__c+' - '+Date.Today().Year();  ///+ '-' +contact.Annual_Receipt_Serial_No__c;

             
            // Fetch Opportunities related to the Contact
            opportunities = [SELECT Id, Name,Status, Receipt_Number__c, paymentMethod, TransactionDate,OriginalAmount FROM GiftTransaction WHERE DonorId = :contactId AND Status='Paid' AND  transactionDate >= : startYear AND transactionDate <=: endYear ];
            system.debug('opportunities pdf>> '+opportunities.Size());
            if (opportunities != null && opportunities.size() > 0){
            for(GiftTransaction opp: opportunities){
                if(opp.OriginalAmount != null){
                    //system.debug('opp.Amount==='+opp.get('convertedAmount'));    
                    totalDonation += opp.OriginalAmount;
                }
            }
            }
            
           // update contact; 
           // system.debug('Contact Serial>>' +contact.Annual_Receipt_Serial_No__c);
            
        }
    }
 public String getFormattedAddress() {
    List<String> lines = new List<String>();

    // Street
    if (!String.isBlank(contact.PersonMailingStreet)) {
        lines.add(contact.PersonMailingStreet);
    }

    // City, State ZIP
    List<String> cityStateZip = new List<String>();

    if (!String.isBlank(contact.PersonMailingCity)) {
        cityStateZip.add(contact.PersonMailingCity);
    }

    if (!String.isBlank(contact.PersonMailingState)) {
        cityStateZip.add(contact.PersonMailingState);
    }

    String cityState = String.join(cityStateZip, ', ');

    if (!String.isBlank(contact.PersonMailingPostalCode)) {
        cityState = cityState + ' ' + contact.PersonMailingPostalCode;
    }

    if (!String.isBlank(cityState)) {
        lines.add(cityState);
    }

    // Country (optional)
    if (!String.isBlank(contact.PersonMailingCountry)) {
        lines.add(contact.PersonMailingCountry);
    }

    return String.join(lines, '<br/>');
}
}