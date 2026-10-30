@isTest
private class StripeCustomerServiceTest {

    // 1. Dynamic Mock Class to handle all Stripe endpoints
    public class StripeMultiEndpointMock implements HttpCalloutMock {
        private Integer statusCode;
        
        public StripeMultiEndpointMock(Integer statusCode) {
            this.statusCode = statusCode;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(this.statusCode);
            
            String endpoint = req.getEndpoint();
            
            // Route the mock response based on the Stripe URL being called
            if (this.statusCode >= 400) {
                res.setBody('{"error": {"message": "Mock Stripe Error"}}');
            } else if (endpoint.contains('/customers')) {
                res.setBody('{"id": "cus_mock123", "email": "test@example.com"}');
            } else if (endpoint.contains('/payment_methods') && endpoint.contains('/attach')) {
                res.setBody('{"id": "pm_mock123"}');
            } else if (endpoint.contains('/payment_intents') && endpoint.contains('/confirm')) {
                res.setBody('{"id": "pi_mock123", "status": "succeeded"}');
            } else if (endpoint.contains('/payment_intents')) {
                res.setBody('{"id": "pi_mock123", "status": "requires_payment_method"}');
            } else if (endpoint.contains('/products')) {
                res.setBody('{"id": "prod_mock123"}');
            } else if (endpoint.contains('/prices')) {
                res.setBody('{"id": "price_mock123"}');
            } else if (endpoint.contains('/subscriptions')) {
                // Returns nested structure expected by createRecurringSubscription
                res.setBody('{"id": "sub_mock123", "latest_invoice": {"payment_intent": {"id": "pi_mock123"}}}');
            } else {
                res.setBody('{"status": "unknown_endpoint"}');
            }
            
            return res;
        }
    }

    // 2. Setup NPC Test Data (Person Accounts & Gift objects)
    @TestSetup
    static void setupTestData() {
        // Fetch Person Account Record Type
        Id personAccRecTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('PersonAccount').getRecordTypeId();

        // Create Donor Account
        Account donor = new Account(
            FirstName = 'Test',
            LastName = 'Donor',
            PersonEmail = 'test@example.com',
            RecordTypeId = personAccRecTypeId
        );
        insert donor;

        // ✅ FIX: Fetch the automatically created Person Contact ID
        Id personContactId = [SELECT PersonContactId FROM Account WHERE Id = :donor.Id LIMIT 1].PersonContactId;

        // Create a Gateway Log (Required for Payment_Method__c)
        Gateway_Log__c gLog = new Gateway_Log__c(
            Date__c = Date.today(),
            Result_Status__c = 'Success',
            Gateway__c = 'Stripe'
        );
        insert gLog;

        // Create a Payment Method Profile
        Payment_Method__c pm = new Payment_Method__c(
            Name = 'Test Visa',
            DonorId__c = donor.Id,
            Payment_Profile_Id__c = 'pm_existing123'
            //Is_Active__c = true
        );
        insert pm;

        // --- Recurring Donation Setup ---
        GiftCommitment gc = new GiftCommitment(
            Name = 'Test Recurring Donation',
            DonorId = donor.Id,
            Contact__c = personContactId, // ✅ Insert the Contact ID, not the Account ID
            Amount__c = 120.00,    
            EffectiveStartDate = Date.today().addDays(1)
        );
        insert gc;

        GiftCommitmentSchedule gcs = new GiftCommitmentSchedule(
            //Name = 'Test Monthly Schedule',
            GiftCommitmentId = gc.Id,
            PaymentMethod = 'Credit Card',
            TransactionPeriod = 'Monthly',
            TransactionAmount = 10.00,
            StartDate = Date.today(),
            Number_of_Planned_Installments__c = 12 
        );
        insert gcs;

        // --- Single Donation Setup ---
        GiftTransaction gt = new GiftTransaction(
            Name = 'Test Single Trx',
            PaymentMethod = 'Credit Card',
            DonorId = donor.Id,
            Contact__c = personContactId, // ✅ Insert the Contact ID, not the Account ID
            GiftCommitmentId = gc.Id,
            Status = 'Pledged',
            OriginalAmount = 10.00,
            TransactionDueDate = Date.today()
        );
        insert gt;
    }

    // 3. Test SOQL Utility Methods
    @isTest
    static void testGetContactIdMethods() {
        GiftTransaction gt = [SELECT Id FROM GiftTransaction LIMIT 1];
        GiftCommitment gc = [SELECT Id FROM GiftCommitment LIMIT 1];
        
        Test.startTest();
        Id contactIdFromOpp = StripeCustomerService.getContactIdfromOpp(gt.Id);
        Id contactIdFromRD = StripeCustomerService.getContactIdfromRD(gc.Id);
        Test.stopTest();
        
        System.assertNotEquals(null, contactIdFromOpp, 'Should retrieve ContactId from GT');
        System.assertNotEquals(null, contactIdFromRD, 'Should retrieve ContactId from GC');
    }

    // 4. Test evaluatePaymentState (With existing Customer Profile)
    @isTest
    static void testEvaluatePaymentState_ExistingCustomer() {
        Account donor = [SELECT Id FROM Account LIMIT 1];
        donor.Customer_Profile_Id_Stripe__c = 'cus_existing123';
        update donor;
        
        Test.startTest();
        Map<String, Object> result = StripeCustomerService.evaluatePaymentState(donor.Id);
        Test.stopTest();
        
        System.assertEquals(true, result.get('hasCustomer'), 'Should identify existing customer');
        //System.assertEquals('cus_existing123', result.get('customerId'));
        //System.assertEquals(true, result.get('hasPaymentProfile'), 'Should find existing active Payment Profile');
    }

    // 5. Test evaluatePaymentState (No Customer - Triggers Callout)
    @isTest
    static void testEvaluatePaymentState_NewCustomer() {
        Account donor = [SELECT Id FROM Account LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new StripeMultiEndpointMock(200));
        
        Test.startTest();
        Map<String, Object> result = StripeCustomerService.evaluatePaymentState(donor.Id);
        Test.stopTest();
        
        System.assertEquals(true, result.get('hasCustomer'), 'Should have created customer via callout');
        System.assertEquals('cus_mock123', result.get('customerId'));
    }

    // 6. Test Local Payment Method Creation
    @isTest
    static void testCreateLocalPaymentMethod() {
        Account donor = [SELECT Id FROM Account LIMIT 1];
        Gateway_Log__c gLog = [SELECT Id FROM Gateway_Log__c LIMIT 1];
        
        Test.startTest();
        Id pmId = StripeCustomerService.createLocalPaymentMethod(
            donor.Id, 'pm_new123', 12, 'Visa', gLog.Id, 2030, '4242'
        );
        Test.stopTest();
        
        System.assertNotEquals(null, pmId, 'Local Payment Method should be inserted');
    }

    // 7. Test Callouts: Payment Intent & Attach
    @isTest
    static void testPaymentIntentAndAttach() {
        Account donor = [SELECT Id FROM Account LIMIT 1];
        GiftTransaction gt = [SELECT Id FROM GiftTransaction LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new StripeMultiEndpointMock(200));
        
        Test.startTest();
        String attachedPmId = StripeCustomerService.attachPaymentMethodToCustomer('pm_123', 'cus_123');
        String responseBody = StripeCustomerService.createPaymentIntent('cus_123', donor.Id, gt.Id, 'pm_123', 'USD');
        Test.stopTest();
        
        System.assertEquals('pm_mock123', attachedPmId, 'Should return attached PM ID from mock');
        System.assert(responseBody.contains('pi_mock123'), 'Payment Intent creation should hit mock successfully');
    }

    // 8. Test Callouts: The massive Recurring Subscription flow
    @isTest
    static void testCreateRecurringSubscription() {
        Account donor = [SELECT Id FROM Account LIMIT 1];
        GiftCommitment gc = [SELECT Id FROM GiftCommitment LIMIT 1];
        GiftTransaction gt = [SELECT Id FROM GiftTransaction LIMIT 1];
        
        Test.setMock(HttpCalloutMock.class, new StripeMultiEndpointMock(200));
        
        Test.startTest();
        // This method calls createProduct, createPrice, createSubscription, and confirmMotoPaymentManual sequentially
        String subId = StripeCustomerService.createRecurringSubscription(
            'cus_123', 'pm_123', 'Monthly Donation', 'USD', gc.Id, gt.Id
        );
        Test.stopTest();
        
        System.assertEquals('sub_mock123', subId, 'Should return the mock subscription ID');
    }

    // 9. Test Payment Installment Generation
    @isTest
    static void testCreatePaymentsFromRecurringDonation() {
        GiftCommitment gc = [SELECT Id FROM GiftCommitment LIMIT 1];
        gc.Recurring_Type__c = 'Fixed';
        gc.NextTransactionAmount = 120.00; 
        update gc;

        // Let the active schedule-calculation Flow derive the count from valid Fixed dates.
        Date firstInstallment = Date.newInstance(Date.today().year(), Date.today().month(), 1);
        GiftCommitmentSchedule schedule = [
            SELECT Id FROM GiftCommitmentSchedule WHERE GiftCommitmentId = :gc.Id LIMIT 1
        ];
        schedule.StartDate = firstInstallment;
        schedule.EndDate = firstInstallment.addMonths(11);
        schedule.TransactionPeriod = 'Monthly';
        schedule.TransactionInterval = 1;
        schedule.TransactionDay = '1';
        update schedule;
        schedule = [
            SELECT Number_of_Planned_Installments__c
            FROM GiftCommitmentSchedule WHERE Id = :schedule.Id
        ];
        System.assertEquals(12, schedule.Number_of_Planned_Installments__c,
            'A twelve-month Fixed schedule must retain its automatically calculated installments.');
        
        GiftTransaction gt = [SELECT Id FROM GiftTransaction LIMIT 1];
        
        Test.startTest();
        StripeCustomerService.createPaymentsFromRecurringDonation(
            gc.Id, gt.Id, 'prod_123', 'price_123', 'sub_123', 'month', 'Fixed'
        );
        Test.stopTest();
        
        // Assert 12 installments were generated based on the Number_of_Planned_Installments__c field
        List<Payment__c> generatedPayments = [SELECT Id, Payment_Amount__c FROM Payment__c WHERE Recurring_Donation__c = :gc.Id];
        System.assertEquals(12, generatedPayments.size(), 'Should generate 12 installment payments');
        System.assertEquals(10.00, generatedPayments[0].Payment_Amount__c, 'Amount should be divided evenly');
    }

   // 10. Test Gateway Log and Helpers
    @isTest
    static void testMiscHelpers() {
        Test.setMock(HttpCalloutMock.class, new StripeMultiEndpointMock(200));
        GiftCommitment gc = [SELECT Id FROM GiftCommitment LIMIT 1];
        
        Test.startTest();
        
        // 🚨 1. DO THE HTTP CALLOUT FIRST
        Map<String, Object> openSub = StripeCustomerService.createOpenEndedSubscription('cus_123', 'price_123');
        
        // 🚨 2. DO THE DML OPERATIONS SECOND (to avoid uncommitted work error)
        Id logId = StripeCustomerService.createGatewayLog(
            'Success', Date.today(), 'Success', 'Stripe', 'Profile', '4242', '12/30', 'Visa', 'cus_123', 'pm_123', '200'
        );
        
        GiftCommitment queriedGc = StripeCustomerService.getRecurringDonation(gc.Id);
        StripeCustomerService.updateRecDonation('cus_123', 'pm_123', queriedGc, 'prod_123', 'price_123', 'sub_123');
        
        Test.stopTest();
        
        // Assertions
        System.assertNotEquals(null, logId, 'Gateway Log should be inserted');
        System.assert(openSub.containsKey('id'), 'Open ended sub should return mock response');
        
        GiftCommitment updatedGc = [SELECT Customer_Profile_Id__c FROM GiftCommitment WHERE Id = :gc.Id];
        System.assertEquals('cus_123', updatedGc.Customer_Profile_Id__c, 'GC should be updated');
    }
}