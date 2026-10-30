@IsTest
private class StripeFailureLoggerTest {

    @IsTest
    static void recordedFailureBecomesALog() {
        Test.startTest();
        StripeFailureLogger.record(StripeFailureLogger.failure(
                StripeFailureLogger.SOURCE_API_CALLOUT, StripeFailureLogger.CODE_STRIPE_API_ERROR, 'Stripe rejected the call')
            .withError('No such subscription: sub_123')
            .operation('StripeFailureLoggerTest.recordedFailureBecomesALog')
            .stripeObject('sub_123')
            .httpStatus(404)
            .amount(12.5));
        StripeFailureLogger.flush();
        Test.stopTest();

        Stripe_Failure_Log__c log = [
            SELECT Failure_Source__c, Reason_Code__c, Failure_Reason__c, Error_Message__c, HTTP_Status_Code__c,
                   Stripe_Object_Id__c, Amount__c, Status__c, Occurrence_Count__c, Notify__c, Dedupe_Key__c
            FROM Stripe_Failure_Log__c
        ];
        Assert.areEqual('Stripe API Callout', log.Failure_Source__c, 'Source should be stored');
        Assert.areEqual('STRIPE_API_ERROR', log.Reason_Code__c, 'Reason code should be stored');
        Assert.areEqual('Stripe rejected the call', log.Failure_Reason__c, 'Reason should be stored');
        Assert.areEqual('No such subscription: sub_123', log.Error_Message__c, 'Error message should be stored');
        Assert.areEqual(404, log.HTTP_Status_Code__c, 'HTTP status should be stored');
        Assert.areEqual('sub_123', log.Stripe_Object_Id__c, 'Stripe id should be stored');
        Assert.areEqual(12.5, log.Amount__c, 'Amount should be stored');
        Assert.areEqual('New', log.Status__c, 'New logs start as New');
        Assert.areEqual(1, log.Occurrence_Count__c, 'First occurrence');
        Assert.isTrue(log.Notify__c, 'Codes notify unless muted');
        Assert.areEqual(64, log.Dedupe_Key__c.length(), 'The dedupe key is a SHA-256 hash');
        Assert.isFalse(log.Dedupe_Key__c.contains('sub_123'), 'No raw input is stored in the dedupe key');
    }

    @IsTest
    static void differentFailuresOnTheSameRecordGetSeparateLogs() {
        Test.startTest();
        for (String reason : new List<String>{ 'Stripe rejected the cancellation', 'Salesforce closure failed' }) {
            StripeFailureLogger.record(StripeFailureLogger.failure(
                    StripeFailureLogger.SOURCE_REFUND_VOID, StripeFailureLogger.CODE_VOID_FAILED, reason)
                .operation('StripeFailureLoggerTest')
                .subscription('sub_same'));
        }
        StripeFailureLogger.record(StripeFailureLogger.failure(
                StripeFailureLogger.SOURCE_REFUND_VOID, StripeFailureLogger.CODE_VOID_FAILED, 'Salesforce closure failed')
            .operation('StripeFailureLoggerTest')
            .subscription('sub_same'));
        StripeFailureLogger.flush();
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM Stripe_Failure_Log__c],
            'An escalation on the same record is a separate log; a repeat of the same failure is not');
        Assert.areEqual(2, [SELECT Occurrence_Count__c FROM Stripe_Failure_Log__c WHERE Failure_Reason__c = 'Salesforce closure failed'].Occurrence_Count__c,
            'The repeat is counted on the existing log');
    }

    @IsTest
    static void everyCodeAndSourceIsAValidPicklistValueWithASetting() {
        List<String> codes = new List<String>{
            StripeFailureLogger.CODE_WEBHOOK_SIGNATURE_INVALID, StripeFailureLogger.CODE_WEBHOOK_UNHANDLED_EXCEPTION,
            StripeFailureLogger.CODE_INVOICE_RD_NOT_FOUND, StripeFailureLogger.CODE_INVOICE_SUBSCRIPTION_MISMATCH,
            StripeFailureLogger.CODE_PAID_NOT_RECORDED, StripeFailureLogger.CODE_PAYMENT_INSERT_FAILED,
            StripeFailureLogger.CODE_RD_UPDATE_FAILED, StripeFailureLogger.CODE_RECURRING_SYNC_FAILED,
            StripeFailureLogger.CODE_PAUSE_RESUME_FAILED, StripeFailureLogger.CODE_REFUND_FAILED,
            StripeFailureLogger.CODE_VOID_FAILED, StripeFailureLogger.CODE_STRIPE_API_ERROR,
            StripeFailureLogger.CODE_ASYNC_JOB_FAILED
        };
        List<String> sources = new List<String>{
            StripeFailureLogger.SOURCE_WEBHOOK, StripeFailureLogger.SOURCE_WEBHOOK_SIGNATURE,
            StripeFailureLogger.SOURCE_API_CALLOUT, StripeFailureLogger.SOURCE_SALESFORCE,
            StripeFailureLogger.SOURCE_RECURRING_SYNC, StripeFailureLogger.SOURCE_PAUSE_RESUME,
            StripeFailureLogger.SOURCE_REFUND_VOID, StripeFailureLogger.SOURCE_ASYNC_JOB
        };
        Set<String> codeValues = picklistValues(Stripe_Failure_Log__c.Reason_Code__c);
        Set<String> sourceValues = picklistValues(Stripe_Failure_Log__c.Failure_Source__c);
        for (String code : codes) {
            Assert.isTrue(codeValues.contains(code), 'Reason_Code__c picklist is missing ' + code);
            Assert.isNotNull(Stripe_Failure_Setting__mdt.getInstance(code), 'Stripe_Failure_Setting__mdt record missing for ' + code);
        }
        for (String source : sources) {
            Assert.isTrue(sourceValues.contains(source), 'Failure_Source__c picklist is missing ' + source);
        }
    }

    @IsTest
    static void recordOnlyBuffersSoCalloutsStillWork() {
        Test.setMock(HttpCalloutMock.class, new OkMock());

        Test.startTest();
        StripeFailureLogger.record(StripeFailureLogger.failure(
            StripeFailureLogger.SOURCE_WEBHOOK, StripeFailureLogger.CODE_PAYMENT_INSERT_FAILED, 'Payment insert failed'));
        Integer dmlAfterRecord = Limits.getDmlStatements();
        HttpRequest request = new HttpRequest();
        request.setEndpoint('https://api.stripe.com/v1/ping');
        request.setMethod('GET');
        HttpResponse response = new Http().send(request);
        StripeFailureLogger.flush();
        Test.stopTest();

        Assert.areEqual(0, dmlAfterRecord, 'record() must not perform DML');
        Assert.areEqual(200, response.getStatusCode(), 'A callout after record() must still be allowed');
        Assert.areEqual(1, [SELECT COUNT() FROM Stripe_Failure_Log__c], 'The buffered failure is published on flush');
    }

    @IsTest
    static void flushWithNothingBufferedDoesNothing() {
        Test.startTest();
        StripeFailureLogger.flush();
        StripeFailureLogger.record(null);
        StripeFailureLogger.flush();
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Stripe_Failure_Log__c], 'Nothing to log');
    }

    @IsTest
    static void signatureFailuresAreThrottledPerDay() {
        Test.startTest();
        StripeFailureLogger.record(signatureFailure());
        StripeFailureLogger.flush();
        Test.getEventBus().deliver();
        StripeFailureLogger.record(signatureFailure());
        Integer bufferedAfterRepeat = StripeFailureLogger.pendingCount();
        Test.stopTest();

        Assert.areEqual(0, bufferedAfterRepeat, 'A second bad signature on the same day must not publish again');
        Assert.areEqual(1, [SELECT COUNT() FROM Stripe_Failure_Log__c], 'One log per day for bad signatures');
    }

    @IsTest
    static void sanitizeRedactsSecretsCardNumbersAndEmails() {
        String raw = 'key sk_live_51Habc123 secret whsec_abcDEF Bearer abc.def-ghi '
            + 'card 4242 4242 4242 4242 mail jane.doe@example.com Authorization: tok_live_x';

        String cleaned = StripeFailureLogger.sanitize(raw, 1000);

        Assert.isFalse(cleaned.contains('sk_live_51Habc123'), 'Stripe secret keys must be removed: ' + cleaned);
        Assert.isFalse(cleaned.contains('whsec_abcDEF'), 'Webhook secrets must be removed: ' + cleaned);
        Assert.isFalse(cleaned.contains('abc.def-ghi'), 'Bearer tokens must be removed: ' + cleaned);
        Assert.isFalse(cleaned.contains('4242 4242 4242 4242'), 'Card-like numbers must be removed: ' + cleaned);
        Assert.isFalse(cleaned.contains('jane.doe@example.com'), 'Email addresses must be removed: ' + cleaned);
        Assert.isFalse(cleaned.contains('tok_live_x'), 'Authorization values must be removed: ' + cleaned);
        Assert.isTrue(cleaned.contains('[redacted-key]'), 'Redaction should be visible: ' + cleaned);
    }

    @IsTest
    static void sanitizeTruncatesAndKeepsBlanks() {
        Assert.areEqual(10, StripeFailureLogger.sanitize('x'.repeat(50), 10).length(), 'Text is cut to the field size');
        Assert.isNull(StripeFailureLogger.sanitize(null, 10), 'Null stays null');
    }

    @IsTest
    static void finalizerLogsUnhandledJobErrors() {
        Test.startTest();
        new StripeFailureFinalizer('StripeFailureLoggerTest.job', null)
            .execute(new FakeFinalizerContext(ParentJobResult.UNHANDLED_EXCEPTION, new DmlException('boom')));
        new StripeFailureFinalizer('StripeFailureLoggerTest.job', null)
            .execute(new FakeFinalizerContext(ParentJobResult.SUCCESS, null));
        Test.stopTest();

        Stripe_Failure_Log__c log = [SELECT Reason_Code__c, Error_Message__c, Failure_Source__c FROM Stripe_Failure_Log__c];
        Assert.areEqual('ASYNC_JOB_FAILED', log.Reason_Code__c, 'Unhandled job errors are logged once; successes are not');
        Assert.areEqual('Async Job', log.Failure_Source__c, 'Async source expected');
        Assert.isTrue(log.Error_Message__c.contains('boom'), 'The job error should be captured');
    }

    @IsTest
    static void recurringCaptureFinalizerLogsUnhandledJobErrors() {
        Id personAccountTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
            .get('PersonAccount').getRecordTypeId();
        Account donor = new Account(RecordTypeId = personAccountTypeId, FirstName = 'Capture', LastName = 'Donor');
        insert donor;
        GiftCommitment commitment = new GiftCommitment(Name = 'Capture RD', DonorId = donor.Id, Status = 'Active');
        insert commitment;

        Test.startTest();
        new StripeRecurringScheduleFinalizer(new Set<Id>{ commitment.Id })
            .execute(new FakeFinalizerContext(ParentJobResult.UNHANDLED_EXCEPTION, new DmlException('capture failed')));
        Test.stopTest();

        Stripe_Failure_Log__c log = [SELECT Reason_Code__c, Gift_Commitment__c, Error_Message__c FROM Stripe_Failure_Log__c];
        Assert.areEqual('ASYNC_JOB_FAILED', log.Reason_Code__c, 'An unhandled capture job error should be logged');
        Assert.areEqual(commitment.Id, log.Gift_Commitment__c, 'The log should link the recurring donation');
        Assert.isTrue(log.Error_Message__c.contains('capture failed'), 'The job error should be captured');
    }

    @IsTest
    static void subscriptionUpdateFailureIsLoggedNotThrown() {
        Test.startTest();
        // No recurring donation id: the Stripe update fails inside the job, which must log, not throw.
        System.enqueueJob(new StripeSubscriptionUpdateQueueable(null, null, null, null));
        Test.stopTest();
        Test.getEventBus().deliver();

        Stripe_Failure_Log__c log = [SELECT Reason_Code__c, Failure_Source__c, Operation__c FROM Stripe_Failure_Log__c];
        Assert.areEqual('STRIPE_API_ERROR', log.Reason_Code__c, 'A failed subscription update should be logged');
        Assert.areEqual('Stripe API Callout', log.Failure_Source__c, 'API callout source expected');
        Assert.areEqual('StripeSubscriptionUpdateQueueable.execute', log.Operation__c, 'The failing operation is named');
    }

    private static Set<String> picklistValues(Schema.SObjectField field) {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) values.add(entry.getValue());
        }
        return values;
    }

    private static StripeFailureLogger.Failure signatureFailure() {
        return StripeFailureLogger.failure(StripeFailureLogger.SOURCE_WEBHOOK_SIGNATURE,
                StripeFailureLogger.CODE_WEBHOOK_SIGNATURE_INVALID, 'Bad signature')
            .operation('StripeFailureLoggerTest')
            .httpStatus(401);
    }

    private class OkMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody('{}');
            return response;
        }
    }

    private class FakeFinalizerContext implements FinalizerContext {
        private final ParentJobResult result;
        private final Exception error;
        FakeFinalizerContext(ParentJobResult result, Exception error) {
            this.result = result;
            this.error = error;
        }
        public Id getAsyncApexJobId() { return null; }
        public Exception getException() { return error; }
        public String getRequestId() { return 'test-request'; }
        public ParentJobResult getResult() { return result; }
    }
}