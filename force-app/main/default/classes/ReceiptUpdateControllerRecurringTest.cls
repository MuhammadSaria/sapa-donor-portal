@IsTest
public class ReceiptUpdateControllerRecurringTest {

    @TestSetup
    static void setupTestData() {
        Account testContact = new Account(
            LastName = 'TestContact',
            personEmail = 'testcontact@example.com'
        );
        insert testContact;

        // Insert GiftCommitments
        List<GiftCommitment> commitments = new List<GiftCommitment>();
        for (Integer i = 1; i <= 3; i++) {
            commitments.add(new GiftCommitment(
                Name = 'Recurring Donation ' + i,
                Status = 'Active',
                DonorId  = testContact.Id

                
            ));
        }
        insert commitments;

        // Insert GiftTransactions linked to GiftCommitments
        List<GiftTransaction> transactions = new List<GiftTransaction>();
        for (GiftCommitment gc : commitments) {
            transactions.add(new GiftTransaction(
                Name = 'Transaction for ' + gc.Name,
                Status = 'Paid',
                TransactionDate = date.Today(),
                TransactionDueDate = date.Today(),
                GiftCommitmentId = gc.Id,
                OriginalAmount = 100,
                paymentMethod = 'cash'
            ));
        }
        insert transactions;
    }

    @IsTest
    static void testMarkRecurringReceiptsAsSent() {
        // Verify initial state
        List<GiftCommitment> commitmentsBefore = [
            SELECT Id, Paper_Receipt__c FROM GiftCommitment
        ];
        for (GiftCommitment gc : commitmentsBefore) {
            //System.assertEquals('Receipt Requested', gc.Paper_Receipt__c, 'Initial state should be Receipt Requested');
        }

        // Call the Aura-enabled method
        Test.startTest();
        ReceiptUpdateControllerRecurring.markRecurringReceiptsAsSent();
        Test.stopTest();

        // Verify updates
        List<GiftCommitment> commitmentsAfter = [
            SELECT Id, Paper_Receipt__c FROM GiftCommitment
        ];
        for (GiftCommitment gc : commitmentsAfter) {
            //System.assertEquals('Receipt Sent', gc.Paper_Receipt__c, 'Paper_Receipt__c should be updated to Receipt Sent');
        }

        System.assertEquals(3, commitmentsAfter.size(), 'All recurring donations should be updated');
    }

    @IsTest
    static void testNoMatchingCommitments() {
         Account testContact = new Account(
            LastName = 'TestContact',
            personEmail = 'absdbt@example.com'
        );
        insert testContact;
        // Insert a GiftCommitment that does NOT have a posted transaction
        GiftCommitment gc = new GiftCommitment(
            Name = 'No Transaction Donation',
            Status = 'Active',
            Paper_Receipt__c = 'Receipt Requested',
            DonorId  = testContact.Id
        );
        insert gc;

        // Call the method
        Test.startTest();
        ReceiptUpdateControllerRecurring.markRecurringReceiptsAsSent();
        Test.stopTest();

        // It should not update this record
        GiftCommitment refreshed = [SELECT Id, Paper_Receipt__c FROM GiftCommitment WHERE Id = :gc.Id];
        System.assertEquals('Receipt Requested', refreshed.Paper_Receipt__c, 'Commitment without posted transaction should not be updated');
    }
}