@isTest
public class ReceiptUpdateControllerTest {

    @isTest
    static void testMarkReceiptsAsSent() {
        // Step 1: Create test Opportunities
        List<GiftTransaction> oppList = new List<GiftTransaction>();

        // Opportunity that meets criteria (should be updated)
        oppList.add(new GiftTransaction(
            Name = 'Test Donation 1',
            Status = 'Paid',
            TransactionDate = Date.today(),
            paymentMethod = 'cash',
            OriginalAmount = 100.00,
            Paper_Receipt_Requested__c = 'Receipt Requested',
            GiftCommitmentId = null
        ));

        // Opportunity that does NOT meet criteria (should not be updated)
        oppList.add(new GiftTransaction(
            Name = 'Test Donation 2',
            Status = 'Unpaid',
            TransactionDate = Date.today(),
            paymentMethod = 'cash',
            OriginalAmount = 100.00,
            Paper_Receipt_Requested__c = 'Receipt Requested',
            GiftCommitmentId = null
        ));

        oppList.add(new GiftTransaction(
            Name = 'Test Donation 3',
            Status = 'Unpaid',
            TransactionDate = Date.today(),
            paymentMethod = 'cash',
            OriginalAmount = 100.00,
            Paper_Receipt_Requested__c = 'Receipt Requested',
            GiftCommitmentId = null
        ));

        insert oppList;

        // Step 2: Call the AuraEnabled method
        Test.startTest();
        ReceiptUpdateController.markReceiptsAsSent();
        Test.stopTest();

        // Step 3: Query Opportunities again to check updates
        List<GiftTransaction> updatedOpps = [
            SELECT Id, Paper_Receipt_Requested__c, Status, GiftCommitmentId
            FROM GiftTransaction
            WHERE Id IN :oppList
        ];

        // Step 4: Verify results
        for (GiftTransaction o : updatedOpps) {
            if (o.Status == 'Paid' && o.Paper_Receipt_Requested__c == 'Receipt Sent' && o.GiftCommitmentId == null) {
                System.assertEquals('Receipt Sent', o.Paper_Receipt_Requested__c, 'Opportunity should be marked as Sent');
            } else {
                System.assertNotEquals('Receipt Sent', o.Paper_Receipt_Requested__c, 'Opportunity should NOT be updated');
            }
        }
    }
}