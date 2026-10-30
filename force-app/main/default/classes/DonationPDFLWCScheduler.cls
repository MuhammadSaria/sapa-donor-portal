public class DonationPDFLWCScheduler {
    @AuraEnabled
    public static void runBatch( String startYear, String endYear) {
        system.debug('startYear -- '+startYear);
        system.debug('endyear  '+endYear);
        ContactEmailPDFBatch taxBatch = new ContactEmailPDFBatch(startYear,endYear);
        Database.executeBatch(taxBatch);
    }
}