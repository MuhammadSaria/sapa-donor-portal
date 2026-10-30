@isTest
public class RecurringDonationStripeTriggerTest {

    /**	
     * Mock class to simulate the HTTP callout response from Stripe.
     */
    public class StripeCalloutMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"id": "sub_123", "status": "active"}');
            res.setStatusCode(200);
            return res;
        }
    }

    /**
     * Test Setup method creates required parent records 
     * once for all test methods to use.
     */
    @testSetup
    static void setupTestData() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        // Create a dummy Account to act as the Donor
        Account testDonor = new Account(LastName = 'Test Donor Account');
        insert testDonor;
    }

    @isTest
    static void testTriggerWithSubscriptionAndChange() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        // 1. Set the mock callout
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());

        // 2. Query the Donor created in setup
        Account donor = [SELECT Id FROM Account LIMIT 1];

        // 3. Create test data WITH the required DonorId
        GiftCommitment gc = new GiftCommitment(
            Name = 'Test Commitment 1', 
            DonorId = donor.Id,
            Subscription_Id__c = 'sub_1234567890',
            Recurring_Type__c = 'Open'
        );
        insert gc;

        // 4. Update the record to fire the trigger
        Test.startTest();
        gc.Recurring_Type__c = 'Fixed';
        update gc;
        Test.stopTest();

        // 5. Verify the update was successful
        GiftCommitment updatedGc = [SELECT Recurring_Type__c FROM GiftCommitment WHERE Id = :gc.Id LIMIT 1];
        System.assertEquals('Fixed', updatedGc.Recurring_Type__c, 'The Recurring Type should have been successfully updated to Fixed.');
    }

    @isTest
    static void testTriggerWithoutSubscription() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        Account donor = [SELECT Id FROM Account LIMIT 1];
        
        GiftCommitment gc = new GiftCommitment(
            Name = 'Test Commitment 2',
            DonorId = donor.Id,
            Recurring_Type__c = 'Open'
            // Subscription_Id__c is left blank intentionally
        );
        insert gc;

        Test.startTest();
        gc.Recurring_Type__c = 'Fixed';
        update gc;
        Test.stopTest();

        GiftCommitment updatedGc = [SELECT Recurring_Type__c FROM GiftCommitment WHERE Id = :gc.Id LIMIT 1];
        System.assertEquals('Fixed', updatedGc.Recurring_Type__c, 'The update should succeed without firing the Stripe callout.');
    }

    @isTest
    static void testTriggerWithNoFieldChange() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        Account donor = [SELECT Id FROM Account LIMIT 1];

        GiftCommitment gc = new GiftCommitment(
            Name = 'Test Commitment 3',
            DonorId = donor.Id,
            Subscription_Id__c = 'sub_0987654321',
            Recurring_Type__c = 'Fixed'
        );
        insert gc;

        Test.startTest();
        // Update a field OTHER than Recurring_Type__c
        gc.Name = 'Updated Test Commitment 3';
        update gc;
        Test.stopTest();

        GiftCommitment updatedGc = [SELECT Name, Recurring_Type__c FROM GiftCommitment WHERE Id = :gc.Id LIMIT 1];
        System.assertEquals('Fixed', updatedGc.Recurring_Type__c, 'Recurring Type should remain unchanged.');
        System.assertEquals('Updated Test Commitment 3', updatedGc.Name, 'The Name should have been updated.');
    }
}