@isTest
private class StripeVoidServiceTest {

    @testSetup
    static void setup() {
        // Create a test Account (Donor) required for GiftCommitment in NPC
        Account acc = new Account(lastName = 'Test Donor');
        insert acc;

        // Create a test GiftCommitment (Recurring Donation)
        GiftCommitment gc = new GiftCommitment(
            Name = 'Test Subscription',
            DonorId = acc.Id,
            Status = 'Active',
            Cancelled_Subscription__c = false,
            Subscription_Id__c = 'sub_test_123'
        );
        insert gc;
    }

    @isTest
    static void testDeleteSubscription_Success() {
        // 1. Get the test record
        GiftCommitment gc = [SELECT Id FROM GiftCommitment LIMIT 1];
        
        // 2. Set the Mock to simulate a 200 OK response from Stripe
        Test.setMock(HttpCalloutMock.class, new StripeVoidMock(200));

        // 3. Call the service
        Test.startTest();
        Boolean result = StripeVoidService.deleteSubscription('sub_test_123', gc.Id, 'Financial Difficulty');
        Test.stopTest();

        // 4. Assertions
        System.assertEquals(true, result, 'The service should return true on a 200 response.');

        // Re-query the record to ensure the DML update happened
        GiftCommitment updatedGc = [SELECT Status, Cancelled_Subscription__c, ClosedReason__c FROM GiftCommitment WHERE Id = :gc.Id];
        System.assertEquals('Closed', updatedGc.Status, 'Status should be updated to Closed.');
        System.assertEquals(true, updatedGc.Cancelled_Subscription__c, 'Cancelled_Subscription__c should be true.');
        System.assertEquals('Financial Difficulty', updatedGc.ClosedReason__c, 'ClosedReason__c should match the input.');
    }

    @isTest
    static void testDeleteSubscription_StripeError() {
        // 1. Get the test record
        GiftCommitment gc = [SELECT Id FROM GiftCommitment LIMIT 1];
        
        // 2. Set the Mock to simulate a 400 Error response from Stripe
        Test.setMock(HttpCalloutMock.class, new StripeVoidMock(400));

        // 3. Call the service
        Test.startTest();
        Boolean result = StripeVoidService.deleteSubscription('sub_test_123', gc.Id, 'Financial Difficulty');
        Test.stopTest();

        // 4. Assertions
        System.assertEquals(false, result, 'The service should return false on a non-200 response.');
        
        // Ensure the record was NOT updated
        GiftCommitment updatedGc = [SELECT Status, Cancelled_Subscription__c FROM GiftCommitment WHERE Id = :gc.Id];
        System.assertNotEquals('Closed', updatedGc.Status, 'Status should NOT be updated on failure.');
        System.assertEquals(false, updatedGc.Cancelled_Subscription__c, 'Cancelled_Subscription__c should remain false.');
        Stripe_Failure_Log__c log = [SELECT Reason_Code__c, HTTP_Status_Code__c, Gift_Commitment__c FROM Stripe_Failure_Log__c];
        Assert.areEqual('VOID_FAILED', log.Reason_Code__c, 'A rejected cancellation should raise a failure log');
        Assert.areEqual(400, log.HTTP_Status_Code__c, 'The Stripe status code should be recorded');
        Assert.areEqual(gc.Id, log.Gift_Commitment__c, 'The log should link the recurring donation');
    }

    @isTest
    static void testDeleteSubscription_BlankSubscriptionId() {
        GiftCommitment gc = [SELECT Id FROM GiftCommitment LIMIT 1];
        
        Test.startTest();
        try {
            // Pass a blank ID to trigger the initial check
            StripeVoidService.deleteSubscription('', gc.Id, 'Financial Difficulty');
            System.assert(false, 'Expected an AuraHandledException to be thrown due to blank ID.');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('required'),e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest static void testSalesforceFailureRequiresReconciliation() {
        GiftCommitment gc=[SELECT Id FROM GiftCommitment LIMIT 1];
        StripeVoidService.failSalesforceSave=true;
        Test.setMock(HttpCalloutMock.class,new StripeVoidMock(200));
        Test.startTest();
        try {
            StripeVoidService.deleteSubscription('sub_test_123',gc.Id,'Financial Difficulty');
            System.assert(false,'Must not report success after Salesforce save failure.');
        } catch(AuraHandledException error) {
            System.assert(error.getMessage().contains('Stripe subscription was canceled'),error.getMessage());
            System.assert(error.getMessage().contains('Reconciliation required'),error.getMessage());
        }
        Test.stopTest();
        GiftCommitment actual=[SELECT Status,Cancelled_Subscription__c FROM GiftCommitment WHERE Id=:gc.Id];
        System.assertEquals('Active',actual.Status);
        System.assertEquals(false,actual.Cancelled_Subscription__c);
        Stripe_Failure_Log__c log=[SELECT Reason_Code__c,Failure_Reason__c FROM Stripe_Failure_Log__c];
        Assert.areEqual('VOID_FAILED',log.Reason_Code__c,'The reconciliation case must survive the rollback as a failure log');
        Assert.isTrue(log.Failure_Reason__c.contains('Reconciliation required'),log.Failure_Reason__c);
    }
    @IsTest static void testMismatchedSubscriptionAndInvalidReasonDoNotCallStripe() {
        GiftCommitment gc=[SELECT Id FROM GiftCommitment LIMIT 1];
        Integer calls=Limits.getCallouts();
        for(Integer i=0;i<2;i++) {
            try {
                StripeVoidService.deleteSubscription(i==0?'sub_unrelated':'sub_test_123',gc.Id,i==0?'Financial Difficulty':'Invalid reason');
                System.assert(false,'Invalid instruction must be rejected before the callout.');
            } catch(AuraHandledException expected) {
                System.assertNotEquals(null,expected.getMessage());
            }
        }
        System.assertEquals(calls,Limits.getCallouts());
    }

    // ==========================================
    // MOCK CLASS FOR STRIPE CALLOUTS
    // ==========================================
    private class StripeVoidMock implements HttpCalloutMock {
        private Integer statusCode;

        // Constructor allows us to set the desired response code in our tests
        public StripeVoidMock(Integer statusCode) {
            this.statusCode = statusCode;
        }

        public HttpResponse respond(HttpRequest req) {
            // Verify the endpoint and method
            System.assert(req.getEndpoint().contains('/subscriptions/'), 'Endpoint should contain /subscriptions/');
            System.assertEquals('DELETE', req.getMethod(), 'Method should be DELETE');

            // Build the fake response
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(this.statusCode);
            
            if (this.statusCode == 200) {
                res.setBody('{"id": "sub_test_123", "status": "canceled"}');
            } else {
                res.setBody('{"error": {"message": "Invalid subscription ID"}}');
            }
            return res;
        }
    }
}