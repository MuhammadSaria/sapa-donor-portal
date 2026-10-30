@isTest
public class AllReceiptsControllerRecurring_Test {

    @isTest
    static void testDonationsQuery() {

        // Contact
        Account testContact = new Account(
            LastName = 'TestContact',
            PersonEmail = 'smith@example.com'
        );
        insert testContact;

        // Recurring Donation
        GiftCommitment rd = new GiftCommitment(
            Name = 'Test RD',
            //TotalPaidTransactionAmount = 100,
            DonorId = testContact.Id,
            Paper_Receipt__c = 'Receipt Requested',
            Payment_Profile_ID__c = 'receipt_test_profile',
            Status = 'Active'
            
        );
        insert rd;

        //  REQUIRED: Posted child Opportunity
        GiftTransaction opp = new GiftTransaction(
            Name = 'Test Donation',
            Status = 'Paid',
            TransactionDate = Date.today(),
            TransactionDueDate = Date.today(),
            OriginalAmount = 100,
            GiftCommitmentId = rd.Id,
            PaymentMethod = 'cash'
        );
        insert opp;

        // Run controller
        Test.startTest();
        AllReceiptsPDFControllerForRecurring controller =
            new AllReceiptsPDFControllerForRecurring();
        Test.stopTest();

        // Assertions
        System.assertNotEquals(null, controller.donations,
            'Donations list should not be null');

        System.assert(controller.donations.size() > 0,
            'Donations list should contain records');

        Boolean found = false;
        for (GiftCommitment rec : controller.donations) {
            if (rec.Id == rd.Id) {
                found = true;
                break;
            }
        }

        System.assert(found,
            'Inserted Recurring Donation record should be returned');
    }
}