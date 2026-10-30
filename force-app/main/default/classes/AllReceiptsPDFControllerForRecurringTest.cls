@isTest
private class AllReceiptsPDFControllerForRecurringTest {
    
    @isTest
    static void testControllerQueriesDataCorrectly() {
        // 1. Set up the Test Data
        Account testDonor = new Account(
             LastName = 'TestContact',
            PersonEmail = 'smith@example.com'
        );
        insert testDonor;

        // Create the Gift Commitment ensuring it matches the controller's WHERE clause
        GiftCommitment testGc = new GiftCommitment(
            Name = 'Test Recurring Donation',
            DonorId = testDonor.Id,
            Paper_Receipt__c = 'Receipt Requested',
            Status = 'Active',
            Payment_Profile_ID__c = 'PP-987654321' // Must not be null based on your query
        );
        insert testGc;

        // Create the related Schedule for the subquery
        GiftCommitmentSchedule testSchedule = new GiftCommitmentSchedule(
            GiftCommitmentId = testGc.Id,
            TransactionAmount = 50.00,
            TransactionPeriod = 'Monthly',
            StartDate = Date.today(),
            PaymentMethod = 'Credit Card'
        );
        insert testSchedule;

        // 2. Execute the logic
        Test.startTest();
        AllReceiptsPDFControllerForRecurring controller = new AllReceiptsPDFControllerForRecurring();
        Test.stopTest();

        // 3. Assert the results to ensure everything worked
        System.assertNotEquals(null, controller.donations, 'The donations list should be initialized.');
        System.assertEquals(1, controller.donations.size(), 'The controller should return exactly one matching Gift Commitment record.');
        
        GiftCommitment queriedGc = controller.donations[0];
        System.assertEquals('Test Recurring Donation', queriedGc.Name, 'The queried record Name should match our test data.');
        System.assertEquals('Active', queriedGc.Status, 'The status should be Active.');
        System.assertEquals(1, queriedGc.GiftCommitmentSchedules.size(), 'The schedule subquery should return exactly one related record.');
    }
}