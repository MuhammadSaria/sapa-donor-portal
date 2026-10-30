public class ContactOpportunitiesController {
    public Date startDate { get; set; }
    public Date endDate { get; set; }
    public String modifyDate { get; set; }
    public String accountId { get; set; }
    public Account Account { get; set; }

    public Decimal TotalSadaqah { get; set; }    
    public Decimal TotalZakat { get; set; }
    public Decimal TotalGeneralDonation { get; set; }
    public Decimal TotalLillah { get; set; }
    public Decimal TotalKaffara { get; set; }
    public Decimal TotalInterest { get; set; }
    public Decimal TotalQurbani { get; set; }
    public Decimal TotalFidya { get; set; }
    public Decimal TotalSadaqahJariyah { get; set; }
    public String accAddress {get; set;}

    public Decimal GrandTotal { get; set; }
    public List<GiftTransaction> giftTransactions { get; set; }
    public List<WrapperAccount> ListWrapperAccount { get; set; }

    // Constructor
    public ContactOpportunitiesController() {
        String fromDateStr = ApexPages.currentPage().getParameters().get('fromDate');
        String toDateStr = ApexPages.currentPage().getParameters().get('toDate');
        accountId = ApexPages.currentPage().getParameters().get('RecordId');
        //String accAddress = '';

        system.debug('===Constructor Start===');
        system.debug('fromDateStr=' + fromDateStr);
        system.debug('toDateStr=' + toDateStr);
        system.debug('accountId=' + accountId);

        Account = [SELECT Id, Name, Secondary_Full_Name__c, Donor_ID__c, PersonMailingStreet, PersonMailingCity, PersonMailingState, PersonMailingPostalCode, PersonMailingCountry
           FROM Account WHERE Id = :accountId];
        
         accAddress = FormattedAddress(Account);

        system.debug('Fetched Account: ' + Account);
        
        modifyDate = DateTime.Now().format('dd-MM-yyyy');

        if (fromDateStr != null && toDateStr != null && accountId != null) {
            try {
                startDate = Date.valueOf(fromDateStr);
                endDate = Date.valueOf(toDateStr);
                system.debug('Parsed Dates: startDate=' + startDate + ', endDate=' + endDate);
                fetchGiftTransactions();
            } catch (Exception e) {
                system.debug('Error parsing dates: ' + e.getMessage());
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Invalid date format in URL.'));
            }
        }
        system.debug('===Constructor End===');
    }
    
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
    
    

    public void fetchGiftTransactions() {
        system.debug('===Fetching Gift Transactions===');

        TotalSadaqah = 0; TotalZakat = 0; TotalGeneralDonation = 0; TotalLillah = 0;
        TotalKaffara = 0; TotalInterest = 0; TotalQurbani = 0; TotalFidya = 0;
        GrandTotal = 0; TotalSadaqahJariyah = 0;
        ListWrapperAccount = new List<WrapperAccount>();

        giftTransactions = [
            SELECT Id, Name, Status, PaymentMethod, TransactionDate, OriginalAmount,
                (SELECT Id, Fund_Name__c,GiftDesignation.Name, Intention__c, Locations__c, Amount 
                 FROM GiftTransactionDesignationRelation)
            FROM GiftTransaction
            WHERE TransactionDate >= :startDate 
              AND TransactionDate <= :endDate
              AND Status = 'Paid'
              AND DonorId = :accountId
            ORDER BY TransactionDate ASC
        ];

        system.debug('Total GiftTransactions found: ' + giftTransactions.size());

        for (GiftTransaction opp : giftTransactions) {
            system.debug('Processing Transaction: ' + opp.Id + ', Name=' + opp.Name + ', OriginalAmount=' + opp.OriginalAmount);

            if (opp.GiftTransactionDesignationRelation != null) {
                system.debug('Allocations found: ' + opp.GiftTransactionDesignationRelation.size());
            } else {
                system.debug('No allocations found for this transaction.');
            }

            // If GAU allocations exist
            if (opp.GiftTransactionDesignationRelation != null && !opp.GiftTransactionDesignationRelation.isEmpty()) {
                for (GiftTransactionDesignation GAU : opp.GiftTransactionDesignationRelation) {
                    system.debug('Processing GAU: Id=' + GAU.Id + ', Fund=' + GAU.Fund_Name__c + 
                                 ', Intention=' + GAU.Intention__c + ', Location=' + GAU.Locations__c + 
                                 ', Amount=' + GAU.Amount);

                    Decimal amount = (GAU.Amount != null) ? GAU.Amount : 0;
                    String intention = (GAU.Intention__c != null) ? GAU.Intention__c : '';

                    switch on intention {
                        when 'Sadaqah'          { TotalSadaqah += amount; }
                        when 'Zakat'            { TotalZakat += amount; }
                        when 'General Donation' { TotalGeneralDonation += amount; }
                        when 'Lillah'           { TotalLillah += amount; }
                        when 'Kaffara'  		{ TotalKaffara += amount; }
                        when 'Interest'         { TotalInterest += amount; }
                        when 'Qurbani'          { TotalQurbani += amount; }
                        when 'Fidya'            { TotalFidya += amount; }
                        when 'Sadaqah Jariyah'  { TotalSadaqahJariyah += amount; }
                        when else               { TotalGeneralDonation += amount; }
                    }

                    // Add wrapper for each GAU
                    ListWrapperAccount.add(new WrapperAccount(opp, GAU));
                }
            } else {
                // No GAUs: treat as General Donation
                ListWrapperAccount.add(new WrapperAccount(opp, null));
                if (opp.OriginalAmount != null) {
                    TotalGeneralDonation += opp.OriginalAmount;
                }
            }
        }

        GrandTotal = TotalSadaqah + TotalZakat + TotalGeneralDonation + TotalLillah + TotalSadaqahJariyah +
                     TotalKaffara + TotalInterest + TotalQurbani + TotalFidya;

        system.debug('Totals: Sadaqah=' + TotalSadaqah + ', Zakat=' + TotalZakat + 
                     ', GeneralDonation=' + TotalGeneralDonation + ', GrandTotal=' + GrandTotal);
        system.debug('ListWrapperAccount size: ' + ListWrapperAccount.size());
        system.debug('===Fetching Gift Transactions End===');
    }

    // Wrapper Class
    public class WrapperAccount {
        public GiftTransaction opp { get; set; }
        public GiftTransactionDesignation GAU { get; set; } 
        public Decimal OppAmount { get; set; }

        public WrapperAccount(GiftTransaction opp, GiftTransactionDesignation GAU) {
            this.opp = opp;
            this.GAU = GAU;
            this.OppAmount = (GAU != null && GAU.Amount != null) ? GAU.Amount : 
                             (opp.OriginalAmount != null ? opp.OriginalAmount : 0);
            system.debug('Wrapper created: Transaction=' + opp.Id + ', GAU=' + (GAU != null ? GAU.Id : 'null') + ', OppAmount=' + this.OppAmount);
        }
    }
}