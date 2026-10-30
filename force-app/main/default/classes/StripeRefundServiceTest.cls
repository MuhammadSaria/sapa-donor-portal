@isTest
private class StripeRefundServiceTest {
    @testSetup
    static void setup() {
        Account acc = new Account(LastName = 'Test Donor');
        insert acc;

        GiftTransaction salesforceDonation = new GiftTransaction(
            Name = 'Salesforce Created Donation',
            Status = 'Paid',
            TransactionDate = System.today(),
            TransactionDueDate = System.today(),
            OriginalAmount = 50.00,
            PaymentMethod = 'credit card',
            Transaction_Id__c = 'pi_test_123',
            Refunded__c = false
        );
        insert salesforceDonation;

        GiftTransaction fundraiseUpDonation = new GiftTransaction(
            Name = 'Fundraise Up GBP Donation',
            Status = 'Paid',
            TransactionDate = System.today(),
            TransactionDueDate = System.today(),
            OriginalAmount = 5.34,
            PaymentMethod = 'credit card',
            Charge_Id__c = 'ch_fup_123',
            FundraiseUpId__c = 'FUP123456789',
            FUp_Currency_ISO_Code__c = 'GBP',
            FUp_Donation_Amount__c = 5.34,
            Refunded__c = false
        );
        insert fundraiseUpDonation;

        GiftCommitment gc = new GiftCommitment(
            Name = 'Test Commitment',
            DonorId = acc.Id,
            Subscription_Id__c = 'sub_test_456',
            Refunded__c = false
        );
        insert gc;

        GiftCommitmentSchedule gcs = new GiftCommitmentSchedule(
            GiftCommitmentId = gc.Id,
            TransactionAmount = 25.00,
            TransactionPeriod = 'Monthly',
            StartDate = System.today()
        );
        insert gcs;

        GiftTransaction recurringChargeDonation = new GiftTransaction(
            Name = 'Recurring Charge Donation',
            Status = 'Paid',
            TransactionDate = System.today(),
            TransactionDueDate = System.today(),
            OriginalAmount = 25.00,
            PaymentMethod = 'credit card',
            Charge_Id__c = 'ch_rec_123',
            GiftCommitmentId = gc.Id,
            Refunded__c = false
        );
        insert recurringChargeDonation;
    }

    @isTest
    static void testGetPaymentIdAndType_SalesforceGiftTransactionUsesExplicitAmount() {
        GiftTransaction gt = [
            SELECT Id
            FROM GiftTransaction
            WHERE Transaction_Id__c = 'pi_test_123'
            LIMIT 1
        ];

        Test.startTest();
        Map<String, String> result = StripeRefundService.getPaymentIdAndType(gt.Id);
        Test.stopTest();

        System.assertEquals('pi_test_123', result.get('paymentId'));
        System.assertEquals('Donation', result.get('recordType'));
        System.assertEquals('5000', result.get('amount'), 'Salesforce-created donations should keep explicit minor units.');
        System.assertEquals('EXPLICIT_MINOR_UNITS', result.get('amountMode'));
        System.assertEquals('SALESFORCE', result.get('source'));
        System.assert(result.get('displayAmount').contains('50.00'));
    }

    @isTest
    static void testGetPaymentIdAndType_FundraiseUpGiftTransactionUsesFullStripeRefund() {
        GiftTransaction gt = [
            SELECT Id
            FROM GiftTransaction
            WHERE Charge_Id__c = 'ch_fup_123'
            LIMIT 1
        ];

        Test.startTest();
        Map<String, String> result = StripeRefundService.getPaymentIdAndType(gt.Id);
        Test.stopTest();

        System.assertEquals('ch_fup_123', result.get('paymentId'));
        System.assertEquals('RDonation', result.get('recordType'));
        System.assertEquals(null, result.get('amount'), 'Fundraise Up charge refunds should omit amount.');
        System.assertEquals('FULL_STRIPE_REFUND', result.get('amountMode'));
        System.assertEquals('FUNDRAISE_UP', result.get('source'));
        System.assertEquals('GBP', result.get('currencyIsoCode'));
        System.assertEquals('Full original Stripe charge', result.get('displayAmount'));
    }

    @isTest
    static void testGetPaymentIdAndType_RecurringGiftTransactionChargeUsesFullStripeRefund() {
        GiftTransaction gt = [
            SELECT Id
            FROM GiftTransaction
            WHERE Charge_Id__c = 'ch_rec_123'
            LIMIT 1
        ];

        Test.startTest();
        Map<String, String> result = StripeRefundService.getPaymentIdAndType(gt.Id);
        Test.stopTest();

        System.assertEquals('ch_rec_123', result.get('paymentId'));
        System.assertEquals('RDonation', result.get('recordType'));
        System.assertEquals(null, result.get('amount'), 'Charge-based recurring refunds should omit amount.');
        System.assertEquals('FULL_STRIPE_REFUND', result.get('amountMode'));
        System.assertEquals('Full original Stripe charge', result.get('displayAmount'));
    }

    @isTest
    static void testGetPaymentIdAndType_GiftCommitmentUsesLatestInvoiceFullRefund() {
        GiftCommitment gc = [
            SELECT Id
            FROM GiftCommitment
            WHERE Subscription_Id__c = 'sub_test_456'
            LIMIT 1
        ];

        Test.startTest();
        Map<String, String> result = StripeRefundService.getPaymentIdAndType(gc.Id);
        Test.stopTest();

        System.assertEquals('sub_test_456', result.get('paymentId'));
        System.assertEquals('RecurringDonation', result.get('recordType'));
        System.assertEquals(null, result.get('amount'), 'Subscription refunds should full-refund the latest invoice charge.');
        System.assertEquals('FULL_STRIPE_REFUND', result.get('amountMode'));
        System.assertEquals('Full latest invoice charge', result.get('displayAmount'));
    }

    @isTest
    static void testRefundPaymentIntent_IncludesAmountWhenExplicit() {
        CapturingRefundMock explicitMock = new CapturingRefundMock(200, '{"id":"re_explicit"}');
        Test.setMock(HttpCalloutMock.class, explicitMock);

        Test.startTest();
        StripeRefundService.refundPaymentIntent('pi_test_123', 5000, 'Donation');
        Test.stopTest();

        System.assertEquals('payment_intent=pi_test_123&amount=5000', explicitMock.lastBody);
    }

    @isTest
    static void testRefundPaymentIntent_OmitsAmountForFullStripeRefund() {
        CapturingRefundMock fullMock = new CapturingRefundMock(200, '{"id":"re_full"}');
        Test.setMock(HttpCalloutMock.class, fullMock);

        Test.startTest();
        StripeRefundService.refundPaymentIntent('ch_fup_123', null, 'RDonation');
        Test.stopTest();

        System.assertEquals('charge=ch_fup_123', fullMock.lastBody);
        System.assert(!fullMock.lastBody.contains('amount='), 'Full Stripe refunds should not send amount.');
    }

    @isTest
    static void testRefundSubscription_SuccessUsesLatestInvoicePaymentIntent() {
        SequentialSubscriptionRefundMock mock = new SequentialSubscriptionRefundMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        String result = StripeRefundService.refundSubscription('sub_test_456', null);
        Test.stopTest();

        System.assertEquals('{"id":"re_sub"}', result);
        System.assertEquals('/v1/subscriptions/sub_test_456?expand[]=latest_invoice.payment_intent', mock.getEndpointPath);
        System.assertEquals('payment_intent=pi_from_sub_789', mock.refundBody);
    }

    @isTest
    static void testIsRefunded() {
        GiftTransaction gt = [
            SELECT Id, Refunded__c
            FROM GiftTransaction
            WHERE Transaction_Id__c = 'pi_test_123'
            LIMIT 1
        ];

        System.assertEquals(false, StripeRefundService.isRefunded(gt.Id));

        gt.Refunded__c = true;
        update gt;

        System.assertEquals(true, StripeRefundService.isRefunded(gt.Id));
    }

    @isTest
    static void testRefund_ErrorHandling() {
        Test.setMock(HttpCalloutMock.class, new ErrorMock('{"error": {"message": "Stripe refund failed: Invalid ID"}}'));

        Test.startTest();
        try {
            StripeRefundService.refundPaymentIntent('pi_invalid', 100, 'Donation');
            System.assert(false, 'Exception should have been thrown');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Stripe refund failed: Invalid ID'), 'Expected the clean Stripe error message.');
            System.assert(!e.getMessage().contains('{"error"'), 'Expected the raw Stripe JSON to be hidden.');
        }
        Test.stopTest();

        Stripe_Failure_Log__c log = [SELECT Reason_Code__c, HTTP_Status_Code__c, Stripe_Object_Id__c, Error_Message__c FROM Stripe_Failure_Log__c];
        Assert.areEqual('REFUND_FAILED', log.Reason_Code__c, 'A rejected refund should raise a failure log');
        Assert.areEqual(400, log.HTTP_Status_Code__c, 'The Stripe status code should be recorded');
        Assert.areEqual('pi_invalid', log.Stripe_Object_Id__c, 'The log should name the payment');
        Assert.isTrue(log.Error_Message__c.contains('Invalid ID'), 'The Stripe reason should be captured: ' + log.Error_Message__c);
    }

    @isTest
    static void testRefund_MalformedErrorFallback() {
        Test.setMock(HttpCalloutMock.class, new ErrorMock('not json'));

        Test.startTest();
        try {
            StripeRefundService.refundPaymentIntent('pi_invalid', 100, 'Donation');
            System.assert(false, 'Exception should have been thrown');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Unable to process the refund with Stripe.'), 'Expected the refund fallback message.');
            System.assert(!e.getMessage().contains('not json'), 'Expected the malformed Stripe body to be hidden.');
        }
        Test.stopTest();
    }

    @isTest
    static void testRefund_BlankErrorFallback() {
        Test.setMock(HttpCalloutMock.class, new ErrorMock(''));

        Test.startTest();
        try {
            StripeRefundService.refundPaymentIntent('pi_invalid', 100, 'Donation');
            System.assert(false, 'Exception should have been thrown');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Unable to process the refund with Stripe.'), 'Expected the refund fallback message.');
        }
        Test.stopTest();
    }

    private class CapturingRefundMock implements HttpCalloutMock {
        private Integer responseCode;
        private String responseBody;
        String lastBody;

        CapturingRefundMock(Integer responseCode, String responseBody) {
            this.responseCode = responseCode;
            this.responseBody = responseBody;
        }

        public HttpResponse respond(HttpRequest req) {
            lastBody = req.getBody();

            HttpResponse res = new HttpResponse();
            res.setStatusCode(responseCode);
            res.setBody(responseBody);
            return res;
        }
    }

    private class SequentialSubscriptionRefundMock implements HttpCalloutMock {
        String getEndpointPath;
        String refundBody;

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');

            if (req.getMethod() == 'GET') {
                getEndpointPath = req.getEndpoint().substringAfter('https://api.stripe.com');
                res.setBody('{"id":"sub_test_456","latest_invoice":{"payment_intent":{"id":"pi_from_sub_789"}}}');
            } else {
                refundBody = req.getBody();
                res.setBody('{"id":"re_sub"}');
            }

            return res;
        }
    }

    private class ErrorMock implements HttpCalloutMock {
        private String responseBody;

        ErrorMock(String responseBody) {
            this.responseBody = responseBody;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setBody(responseBody);
            return res;
        }
    }
}