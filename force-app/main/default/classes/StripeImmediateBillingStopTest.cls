@IsTest
private class StripeImmediateBillingStopTest {
    private static List<String> bodies = new List<String>();
    private static Integer subscriptionReads = 0;

    private class VerifiedBridgeMock implements HttpCalloutMock {
        private final Long effectiveTimestamp;
        private final Long periodStart;
        private final Long currentPeriodEnd;
        private final String changeId;
        VerifiedBridgeMock(Date effectiveDate, String durableRequestId) {
            effectiveTimestamp = Datetime.newInstanceGmt(effectiveDate, Time.newInstance(12, 0, 0, 0)).getTime() / 1000;
            periodStart = Datetime.newInstanceGmt(Date.today().addDays(-3), Time.newInstance(12, 0, 0, 0)).getTime() / 1000;
            currentPeriodEnd = Datetime.newInstanceGmt(Date.today().addDays(7), Time.newInstance(12, 0, 0, 0)).getTime() / 1000;
            changeId = durableRequestId;
        }

        public HttpResponse respond(HttpRequest request) {
            bodies.add(request.getBody());
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            if (request.getMethod() == 'GET' && request.getEndpoint().contains('/subscriptions/sub_bridge')) {
                subscriptionReads++;
                Boolean verified = subscriptionReads > 1;
                response.setBody('{"id":"sub_bridge","status":"' + (verified ? 'trialing' : 'active') + '",' +
                    '"collection_method":"charge_automatically","current_period_start":' + periodStart + ',' +
                    '"current_period_end":' + currentPeriodEnd + ',"billing_cycle_anchor":' + periodStart + ',' +
                    '"trial_end":' + (verified ? String.valueOf(effectiveTimestamp) : 'null') + ',' +
                    '"schedule":' + (verified ? '"sub_sched_bridge"' : 'null') + ',' +
                    '"items":{"data":[{"id":"si_bridge","quantity":1,"price":{"id":"price_weekly",' +
                    '"unit_amount":1000,"product":"prod_bridge","currency":"usd",' +
                    '"recurring":{"interval":"week","interval_count":1}}}]}}');
            } else if (request.getMethod() == 'GET' && request.getEndpoint().contains('/subscription_schedules/sub_sched_bridge')) {
                response.setBody('{"id":"sub_sched_bridge","status":"active","subscription":"sub_bridge",' +
                    '"metadata":{"sapa_owner":"salesforce"},"current_phase":{"start_date":' + periodStart +
                    ',"end_date":' + effectiveTimestamp + '},"phases":[{"start_date":' + periodStart +
                    ',"end_date":' + effectiveTimestamp + ',"trial_end":' + effectiveTimestamp +
                    ',"metadata":{"sapa_billing_gap":"true"},"items":[{"price":"price_weekly","quantity":1}]},' +
                    '{"start_date":' + effectiveTimestamp + ',"metadata":{"sapa_billing_gap":"false",' +
                    '"salesforce_change_id":"' + changeId + '"},' +
                    '"items":[{"price":"price_monthly","quantity":1}]}]}');
            } else if (request.getEndpoint().endsWith('/prices')) {
                response.setBody('{"id":"price_monthly"}');
            } else if (request.getEndpoint().endsWith('/subscription_schedules')) {
                response.setBody('{"id":"sub_sched_bridge","subscription":"sub_bridge",' +
                    '"metadata":{"sapa_owner":"salesforce"}}');
            } else {
                response.setBody('{"id":"sub_sched_bridge","subscription":"sub_bridge",' +
                    '"metadata":{"sapa_owner":"salesforce"}}');
            }
            return response;
        }
    }

    private class VerifiedLongGapMock implements HttpCalloutMock {
        private final Long target;
        private final Long periodStart;
        private final Long renewal;
        private final Boolean existingTrial;
        private Integer reads = 0;
        VerifiedLongGapMock(Date targetDate) {
            this(targetDate,false);
        }
        VerifiedLongGapMock(Date targetDate, Boolean existingTrial) {
            this.existingTrial = existingTrial;
            target = Datetime.newInstanceGmt(targetDate, Time.newInstance(12, 0, 0, 0)).getTime() / 1000;
            periodStart = Datetime.newInstanceGmt(Date.today().addDays(-3), Time.newInstance(12, 0, 0, 0)).getTime() / 1000;
            renewal = Datetime.newInstanceGmt(Date.today().addDays(7), Time.newInstance(12, 0, 0, 0)).getTime() / 1000;
        }
        public HttpResponse respond(HttpRequest request) {
            bodies.add(request.getBody());
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            String endpoint = request.getEndpoint();
            if (request.getMethod() == 'GET' && endpoint.contains('/subscriptions/sub_bridge')) {
                reads++;
                response.setBody('{"id":"sub_bridge","status":"' + (existingTrial ? 'trialing' : 'active') + '",' +
                    '"trial_end":' + (existingTrial ? String.valueOf(renewal) : 'null') + ',' +
                    '"collection_method":"charge_automatically","current_period_start":' + periodStart +
                    ',"current_period_end":' + renewal + ',"billing_cycle_anchor":' + periodStart +
                    ',"schedule":' + (reads > 1 || existingTrial ? '"sub_sched_bridge"' : 'null') +
                    ',"items":{"data":[{"id":"si_bridge","quantity":1,"price":{"id":"price_weekly",' +
                    '"unit_amount":1000,"product":"prod_bridge","currency":"usd",' +
                    '"recurring":{"interval":"week","interval_count":1}}}]}}');
            } else if (request.getMethod() == 'GET' && endpoint.contains('/subscription_schedules/sub_sched_bridge')) {
                response.setBody('{"id":"sub_sched_bridge","status":"active","subscription":"sub_bridge",' +
                    '"metadata":{"sapa_owner":"salesforce"},"current_phase":{"start_date":' + periodStart +
                    ',"end_date":' + renewal + '},"phases":[{"start_date":' + periodStart +
                    ',"end_date":' + renewal + ',"trial_end":' + (existingTrial ? String.valueOf(renewal) : 'null') +
                    ',"items":[{"price":"price_weekly","quantity":1}]},' +
                    '{"start_date":' + renewal + ',"end_date":' + target +
                    ',"metadata":{"sapa_billing_gap":"true"},"items":[{"price":"price_zero","quantity":1}]},' +
                    '{"start_date":' + target + ',"metadata":{"salesforce_change_id":"a00000000000001AAA"},' +
                    '"items":[{"price":"price_monthly","quantity":1}]}]}');
            } else if (request.getMethod() == 'GET' && endpoint.contains('/prices/price_zero')) {
                response.setBody('{"id":"price_zero","unit_amount":0,"currency":"usd",' +
                    '"product":"prod_bridge","recurring":{"interval":"year","interval_count":1}}');
            } else if (endpoint.endsWith('/prices')) {
                response.setBody('{"id":' + (request.getBody().contains('unit_amount=0')
                    ? '"price_zero"' : '"price_monthly"') + '}');
            } else {
                response.setBody('{"id":"sub_sched_bridge","subscription":"sub_bridge",' +
                    '"metadata":{"sapa_owner":"salesforce"}}');
            }
            return response;
        }
    }

    @IsTest
    static void longGapReplacementPreservesExistingTrialUntilZeroPhase() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        bodies.clear();
        Date effectiveDate=Date.today().addYears(3).addDays(10);
        Test.setMock(HttpCalloutMock.class,new VerifiedLongGapMock(effectiveDate,true));
        StripeRecurringScheduleGateway.secretKeyOverride='REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.trialBridgeEnabledOverride=true;
        StripeRecurringScheduleGateway.ChangeRequest request=gatewayRequest(effectiveDate);
        request.stopBillingImmediately=true;
        Test.startTest();
        StripeRecurringScheduleGateway.applyChange(request);
        Test.stopTest();
        String body=findBodyContaining('phases%5B1%5D%5Bitems%5D%5B0%5D%5Bprice%5D=price_zero');
        Long existingTrialEnd=Datetime.newInstanceGmt(Date.today().addDays(7),Time.newInstance(12,0,0,0)).getTime()/1000;
        Assert.isNotNull(body);
        Assert.isTrue(body.contains('phases%5B0%5D%5Btrial_end%5D='+existingTrialEnd),
            'Replacing the future plan must not end an existing trial and invoice the old annual Price.');
        Assert.isTrue(body.contains('phases%5B0%5D%5Bmetadata%5D%5Bsapa_billing_gap%5D=true'),
            'The retained trial remains a no-charge billing gap.');
    }

    @IsTest
    static void threeYearCadenceGapUsesVerifiedZeroPricePhaseNotTrial() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        bodies.clear();
        Date effectiveDate = Date.today().addYears(3).addDays(10);
        Test.setMock(HttpCalloutMock.class, new VerifiedLongGapMock(effectiveDate));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.trialBridgeEnabledOverride = true;
        StripeRecurringScheduleGateway.ChangeRequest request = gatewayRequest(effectiveDate);
        request.stopBillingImmediately = true;

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result = StripeRecurringScheduleGateway.applyChange(request);
        Test.stopTest();

        Assert.areEqual('Scheduled', result.actionMode);
        Assert.isTrue(result.billingStopVerified);
        Assert.isNull(result.billingStoppedAt, 'The zero-Price gap starts at the next renewal, not at save.');
        String scheduleBody = findBodyContaining('phases%5B1%5D%5Bitems%5D%5B0%5D%5Bprice%5D=price_zero');
        Assert.isNotNull(scheduleBody, 'A separate zero-Price phase must bridge the long gap.');
        Assert.isTrue(scheduleBody.contains('phases%5B2%5D%5Bitems%5D%5B0%5D%5Bprice%5D=price_monthly'));
        Assert.isTrue(scheduleBody.contains('phases%5B1%5D%5Bproration_behavior%5D=none'));
        Assert.isFalse(scheduleBody.contains('trial_end'), 'Stripe trial_end cannot span a three-year gap.');
        assertBridgeIsNotTarget(scheduleBody, 0, null);
        assertBridgeIsNotTarget(scheduleBody, 1, request.salesforceChangeId);
    }

    @IsTest
    static void futureCadenceStopCreatesAndVerifiesNoChargeBridge() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        bodies.clear();
        subscriptionReads = 0;
        Date effectiveDate = Date.today().addDays(20);
        Test.setMock(HttpCalloutMock.class, new VerifiedBridgeMock(effectiveDate, 'a00000000000001AAA'));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.trialBridgeEnabledOverride = true;
        StripeRecurringScheduleGateway.ChangeRequest request = gatewayRequest(effectiveDate);
        request.stopBillingImmediately = true;

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result = StripeRecurringScheduleGateway.applyChange(request);
        Test.stopTest();

        Assert.areEqual('Scheduled', result.actionMode);
        Assert.isTrue(result.billingStopVerified, 'Success requires a post-mutation Stripe re-read.');
        Assert.isNotNull(result.billingStoppedAt);
        Assert.areEqual('sub_sched_bridge', result.subscriptionScheduleId);
        Assert.areEqual(2, subscriptionReads, 'Stripe must be read before and after mutation.');
        String scheduleBody = findBodyContaining('phases%5B0%5D%5Btrial_end%5D');
        Assert.isNotNull(scheduleBody, 'The current phase must become a no-charge trial bridge.');
        Assert.isTrue(scheduleBody.contains('phases%5B0%5D%5Bmetadata%5D%5Bsapa_billing_gap%5D=true'));
        Assert.isTrue(scheduleBody.contains('phases%5B1%5D%5Bbilling_cycle_anchor%5D=phase_start'));
        Assert.isTrue(scheduleBody.contains('phases%5B1%5D%5Bproration_behavior%5D=none'));
        assertBridgeIsNotTarget(scheduleBody, 0, request.salesforceChangeId);
    }

    @IsTest
    static void futureCadenceAutomaticallyBridgesWhenOldBillingWouldRunFirst() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        bodies.clear();
        subscriptionReads = 0;
        Date effectiveDate = Date.today().addDays(20);
        Test.setMock(HttpCalloutMock.class, new VerifiedBridgeMock(effectiveDate, 'a00000000000001AAA'));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.trialBridgeEnabledOverride = true;
        StripeRecurringScheduleGateway.ChangeRequest request = gatewayRequest(effectiveDate);

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result = StripeRecurringScheduleGateway.applyChange(request);
        Test.stopTest();

        Assert.areEqual('Scheduled', result.actionMode);
        Assert.isTrue(result.billingStopVerified,
            'A cadence gap must be enabled automatically when the old renewal occurs before the new cadence date.');
        String scheduleBody = findBodyContaining('phases%5B0%5D%5Btrial_end%5D');
        Assert.isNotNull(scheduleBody, 'The old cadence must become a no-charge bridge automatically.');
    }

    @IsTest
    static void guidedCaptureSuppressesQueueableAndCreatesOneDurableRequest() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment('sub_bridge', 'Open');
        Date effectiveDate = Date.today().addDays(20);
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 40, 'Monthly', 1, effectiveDate, effectiveDate, null
        );
        StripeRecurringScheduleTestDataFactory.createUnpaidTransaction(commitment, schedule, 40, effectiveDate);
        StripeRecurringScheduleCaptureCoalescer.resetForTest();
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = false;

        Test.startTest();
        StripeRecurringGuidedContextAction.Request contextRequest = new StripeRecurringGuidedContextAction.Request();
        contextRequest.giftCommitmentId = commitment.Id;
        StripeRecurringGuidedContextAction.execute(
            new List<StripeRecurringGuidedContextAction.Request>{ contextRequest }
        );
        schedule.Stop_Stripe_Billing_Immediately__c = true;
        update schedule;
        Id requestId = StripeRecurringScheduleChangeService.createGuidedRequestForGiftCommitment(commitment.Id);
        Test.stopTest();

        Assert.areEqual(0, StripeRecurringScheduleCaptureCoalescer.getEnqueueCountForTest(),
            'The guided transaction must not enqueue asynchronous processing.');
        Stripe_Subscription_Change__c requestRecord = [
            SELECT Stop_Stripe_Billing_Immediately__c, Status__c, Idempotency_Key__c
            FROM Stripe_Subscription_Change__c WHERE Id = :requestId
        ];
        Assert.isTrue(requestRecord.Stop_Stripe_Billing_Immediately__c);
        Assert.areEqual('Pending', requestRecord.Status__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c = :commitment.Id]);
    }

    @IsTest
    static void synchronousActionNeverReportsSuccessWithoutStripeVerification() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment('sub_bridge', 'Open');
        Stripe_Subscription_Change__c requestRecord = new Stripe_Subscription_Change__c(
            Gift_Commitment__c = commitment.Id,
            Requested_Effective_Date__c = Date.today().addDays(20),
            Requested_First_Payment_Date__c = Date.today().addDays(20),
            Requested_Amount__c = 40,
            Requested_Period__c = 'Monthly',
            Requested_Interval__c = 1,
            Requested_Recurring_Type__c = 'Open',
            Stop_Stripe_Billing_Immediately__c = true,
            Stripe_Action_Mode__c = 'Scheduled',
            Status__c = 'Pending',
            Attempt_Count__c = 0,
            Idempotency_Key__c = 'sapa-rd-guided-failure',
            Stripe_Subscription_Id__c = 'sub_bridge'
        );
        insert requestRecord;
        StripeRecurringScheduleGateway.secretKeyOverride = '';
        StripeRecurringScheduleApplyNowAction.Request input = new StripeRecurringScheduleApplyNowAction.Request();
        input.requestId = requestRecord.Id;

        Test.startTest();
        List<StripeRecurringScheduleApplyNowAction.Response> responses =
            StripeRecurringScheduleApplyNowAction.execute(new List<StripeRecurringScheduleApplyNowAction.Request>{ input });
        Test.stopTest();

        Assert.isFalse(responses[0].success, 'A Stripe failure must be shown immediately.');
        Assert.areEqual('Failed', responses[0].status);
        requestRecord = [SELECT Status__c, Billing_Stopped_At__c FROM Stripe_Subscription_Change__c WHERE Id = :requestRecord.Id];
        Assert.areEqual('Failed', requestRecord.Status__c);
        Assert.isNull(requestRecord.Billing_Stopped_At__c);
    }

    @IsTest
    static void synchronousActionReturnsVerifiedStripeStopDetails() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        subscriptionReads = 0;
        Date effectiveDate = Date.today().addDays(20);
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment('sub_bridge', 'Open');
        Stripe_Subscription_Change__c requestRecord = new Stripe_Subscription_Change__c(
            Gift_Commitment__c = commitment.Id,
            Requested_Effective_Date__c = effectiveDate,
            Requested_First_Payment_Date__c = effectiveDate,
            Requested_Amount__c = 40,
            Requested_Period__c = 'Monthly',
            Requested_Interval__c = 1,
            Requested_Recurring_Type__c = 'Open',
            Stop_Stripe_Billing_Immediately__c = true,
            Stripe_Action_Mode__c = 'Scheduled',
            Status__c = 'Pending',
            Attempt_Count__c = 0,
            Idempotency_Key__c = 'sapa-rd-guided-success',
            Stripe_Subscription_Id__c = 'sub_bridge'
        );
        insert requestRecord;
        Test.setMock(HttpCalloutMock.class, new VerifiedBridgeMock(effectiveDate, requestRecord.Id));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.trialBridgeEnabledOverride = true;
        StripeRecurringScheduleApplyNowAction.Request input = new StripeRecurringScheduleApplyNowAction.Request();
        input.requestId = requestRecord.Id;

        Test.startTest();
        List<StripeRecurringScheduleApplyNowAction.Response> responses =
            StripeRecurringScheduleApplyNowAction.execute(new List<StripeRecurringScheduleApplyNowAction.Request>{ input });
        Test.stopTest();

        Assert.isTrue(
            responses[0].success,
            responses[0].errorMessage == null ? 'Synchronous action did not return a failure message.' : responses[0].errorMessage
        );
        Assert.areEqual('Scheduled', responses[0].status);
        Assert.isNotNull(responses[0].billingStoppedAt);
        Assert.areEqual(effectiveDate, responses[0].scheduledPaymentDate);
        Assert.areEqual('sub_sched_bridge', responses[0].stripeScheduleId);
    }

    @IsTest
    static void synchronousActionRejectsMissingDurableRequest() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        Test.startTest();
        List<StripeRecurringScheduleApplyNowAction.Response> responses =
            StripeRecurringScheduleApplyNowAction.execute(
                new List<StripeRecurringScheduleApplyNowAction.Request>{ null }
            );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        Assert.isFalse(responses[0].success);
        Assert.areEqual('Failed', responses[0].status);
        Assert.isTrue(responses[0].errorMessage.contains('not created'));
    }

    private static StripeRecurringScheduleGateway.ChangeRequest gatewayRequest(Date effectiveDate) {
        StripeRecurringScheduleGateway.ChangeRequest request = new StripeRecurringScheduleGateway.ChangeRequest();
        request.subscriptionId = 'sub_bridge';
        request.productId = 'prod_bridge';
        request.currencyIsoCode = 'USD';
        request.amount = 40;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.effectiveDate = effectiveDate;
        request.recurringType = 'Open';
        request.salesforceGiftCommitmentId = '6gc000000000001AAA';
        request.salesforceChangeId = 'a00000000000001AAA';
        request.idempotencyKey = 'sapa-rd-trial-bridge';
        return request;
    }

    private static void assertBridgeIsNotTarget(String body, Integer phaseIndex, String gapChangeId) {
        Map<String,String> form = new Map<String,String>();
        for (String part : body.split('&')) {
            Integer equalsAt=part.indexOf('=');
            if (equalsAt >= 0) form.put(EncodingUtil.urlDecode(part.substring(0,equalsAt),'UTF-8'),
                EncodingUtil.urlDecode(part.substring(equalsAt+1),'UTF-8'));
        }
        String prefix='phases['+phaseIndex+'][metadata]';
        Assert.areEqual('',form.get(prefix+'[salesforce_change_id]'),
            'Clear a stale target marker; bridge activation must not mark the target request Synced.');
        if (gapChangeId != null) Assert.areEqual(gapChangeId,form.get(prefix+'[sapa_billing_gap_change_id]'),
            'Keep gap audit metadata separate from the target activation marker.');
    }

    private static String findBodyContaining(String fragment) {
        for (String body : bodies) if (body != null && body.contains(fragment)) return body;
        return null;
    }
}