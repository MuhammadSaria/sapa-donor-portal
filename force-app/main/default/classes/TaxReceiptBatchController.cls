public class TaxReceiptBatchController {
    @AuraEnabled
    public static void runBatch( Date startYear, Date endYear) {
        TaxReceiptBatch taxBatch = new TaxReceiptBatch(startYear,endYear);
        Database.executeBatch(taxBatch, 100);
    }
}