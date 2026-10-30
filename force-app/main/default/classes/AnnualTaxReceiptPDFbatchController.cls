public class AnnualTaxReceiptPDFbatchController {
    
    public list<Account> listaccount { get; set; }
    public List<GiftTransaction> listdonations { get; set; }
    public String formattedStartDate {get; set;}
    public String formattedendYearDate {get; set;}
    public String formattedGenerationDate {get; set;} // For the PDF Date 
    public list<WrapperAccount> ListWrapperAccount {get;set;}
    
    // Constructor
    public AnnualTaxReceiptPDFbatchController() {
        
        Date startYear = Date.ValueOf(ApexPages.currentPage().getParameters().get('startYear'));
        Date endYear = Date.ValueOf(ApexPages.currentPage().getParameters().get('endYear'));
        
        ListWrapperAccount = new List<WrapperAccount>();
        Set<Id> setdonorId = new Set<Id>();
        listaccount = new list<Account>();
        listdonations = new list<GiftTransaction>();
        
        // --- Date Formatting Logic ---
        List<String> monthNames = new List<String>{'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'};
        List<String> fullMonthNames = new List<String>{'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'};

        // Format Start Date
        formattedStartDate = monthNames[startYear.month() - 1] + ' ' + startYear.day() + ', ' + startYear.year();
        // Format End Date
        formattedendYearDate = monthNames[endYear.month() - 1] + ' ' + endYear.day() + ', ' + endYear.year();
        // Format Today's Date for the Letter Header 
        Date today = Date.today();
        formattedGenerationDate = fullMonthNames[today.month() - 1] + ' ' + today.day() + ', ' + today.year();

        
        // --- Fetch Transactions ---
        // Added Payment_Method__c to query to support the PDF table column 
        // Ensure you replace 'Payment_Method__c' with your actual API name
        listdonations = [
            SELECT Id, Name, Donor_ID__c, Receipt_Number__c, OriginalAmount, Status, TransactionDate, donorId, PaymentMethod 
            FROM GiftTransaction 
            WHERE Status = 'Paid' 
            AND TransactionDate >= :startYear 
            AND TransactionDate <= :endYear 
        ];
        
        // --- Group Transactions by Donor ---
        // Instead of just calculating total, we map the ID to the LIST of transactions
        Map<Id, List<GiftTransaction>> donorTransactionsMap = new Map<Id, List<GiftTransaction>>();
        
        for (GiftTransaction trans : listdonations) {
            if (trans.donorId != null) {
                setdonorId.add(trans.donorId);
                
                if (!donorTransactionsMap.containsKey(trans.donorId)) {
                    donorTransactionsMap.put(trans.donorId, new List<GiftTransaction>());
                }
                donorTransactionsMap.get(trans.donorId).add(trans);
            }
        }
        
        // --- Fetch Accounts ---
        if (!setdonorId.isEmpty()) {
            listaccount = [
    SELECT Id, Name, Secondary_Full_Name__c, personEmail, Donor_ID__c, Annual_Receipt_Serial_No__c,PersonMailingStreet, PersonMailingCity, PersonMailingState, PersonMailingPostalCode,
PersonMailingCountry FROM Account WHERE Id IN :setdonorId AND personEmail = null  ]; 
            
            // --- Prepare Wrapper ---
            for (Account con : listaccount) {                
                String receiptNo = '';
                String accAddress = '';
                Decimal totalDonation = 0;
                List<GiftTransaction> specificDonations = new List<GiftTransaction>();
                
                // Retrieve the specific list of donations for this donor
                if (donorTransactionsMap.containsKey(con.Id)) {
                    specificDonations = donorTransactionsMap.get(con.Id);
                    
                    // Calculate Total Loop
                    for(GiftTransaction t : specificDonations){
                        if(t.OriginalAmount != null){
                            totalDonation += t.OriginalAmount;
                        }
                    }
                }

                accAddress = FormattedAddress(con);
                
                // Receipt Number Logic
                if(con.Donor_ID__c != null){
                     receiptNo = con.Donor_ID__c + ' - ' + Date.Today().Year(); 
                } else {
                     receiptNo = 'REF-' + Date.Today().Year();
                }

                // Add to wrapper list, now passing the specific list of donations
                ListWrapperAccount.add(new WrapperAccount(con, totalDonation, receiptNo, accAddress, specificDonations));
            }
        }
    }

    // Helper to format address to match PDF style [cite: 2, 3]
    public String FormattedAddress(Account acc) {
        List<String> addressParts = new List<String>();

      if (!String.isBlank(acc.PersonMailingStreet)) {
        addressParts.add(acc.PersonMailingStreet);
    }
        
        // City, State ZIP
    List<String> cityStateZip = new List<String>();

    if (!String.isBlank(acc.PersonMailingCity)) {
        cityStateZip.add(acc.PersonMailingCity);
    }

    if (!String.isBlank(acc.PersonMailingState)) {
        cityStateZip.add(acc.PersonMailingState);
    }

    String cityState = String.join(cityStateZip, ', ');

    if (!String.isBlank(acc.PersonMailingPostalCode)) {
        cityState = cityState + ' ' + acc.PersonMailingPostalCode;
    }

    if (!String.isBlank(cityState)) {
        addressParts.add(cityState);
    }

    // Country (optional)
    if (!String.isBlank(acc.PersonMailingCountry)) {
        addressParts.add(acc.PersonMailingCountry);
    }


        return String.join(addressParts, '<br/>'); // Using break tag for HTML/Visualforce rendering
    }

    public class WrapperAccount 
    { 
        public Decimal TotalAmount {get; set;}
        public String receiptNo {get; set;}
        public Account acc {get; set;}
        public String accAddress {get; set;}
        public List<GiftTransaction> donList {get; set;} // Added to support the table in PDF 
        
        public WrapperAccount(Account acc, Decimal TotalAmount, String receiptNo, String accAddress, List<GiftTransaction> donList)
        {
            this.TotalAmount = TotalAmount;
            this.acc = acc;
            this.receiptNo = receiptNo;
            this.accAddress = accAddress;
            this.donList = donList;
        }
    } 
}