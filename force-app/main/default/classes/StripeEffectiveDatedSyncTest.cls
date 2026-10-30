@IsTest
private class StripeEffectiveDatedSyncTest {
    private class ScheduledStripeMock implements HttpCalloutMock {
        private Long periodStart;
        private Long periodEnd;
        private Long effectiveTimestamp;
        private String changeId;

        ScheduledStripeMock(Date nextBillingDate, Date effectiveDate, Id durableRequestId) {
            periodEnd = Datetime.newInstanceGmt(nextBillingDate, Time.newInstance(8, 0, 0, 0)).getTime() / 1000;
            periodStart = periodEnd - 2592000;
            effectiveTimestamp = Datetime.newInstanceGmt(effectiveDate, Time.newInstance(8, 0, 0, 0)).getTime() / 1000;
            changeId = durableRequestId;
        }

        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            if (request.getMethod() == 'GET' && request.getEndpoint().contains('/subscriptions/')) {
                response.setBody('{"id":"sub_effective","status":"active","collection_method":"charge_automatically",' +
                    '"current_period_start":' + periodStart + ',"current_period_end":' + periodEnd + ',"schedule":null,' +
                    '"items":{"data":[{"id":"si_effective","quantity":1,"price":{"id":"price_original",' +
                    '"unit_amount":3000,"product":"prod_effective","currency":"usd",' +
                    '"recurring":{"interval":"month","interval_count":1}}}]}}');
            } else if (request.getEndpoint().endsWith('/prices')) {
                response.setBody('{"id":"price_scheduled"}');
            } else if (request.getEndpoint().endsWith('/subscription_schedules')) {
                response.setBody('{"id":"sub_sched_effective","subscription":"sub_effective",' +
                    '"metadata":{"sapa_owner":"salesforce"}}');
            } else {
                response.setBody('{"id":"sub_sched_effective","subscription":"sub_effective",' +
                    '"metadata":{"sapa_owner":"salesforce"},' +
                    '"phases":[{"start_date":' + periodStart + ',"items":[{"price":"price_original"}]},' +
                    '{"start_date":' + effectiveTimestamp + ',"items":[{"price":"price_scheduled","quantity":1}],' +
                    '"metadata":{"salesforce_change_id":"' + changeId + '"}}]}');
            }
            return response;
        }
    }

    @TestSetup
    static void setupSynchronousPreviewData() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        StripeRecurringScheduleTestDataFactory.createCommitment('sub_preview_dates', 'Fixed');
    }

    @IsTest
    static void createsCompositeRequestWithEffectiveAndPaymentDates() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment('sub_effective', 'Fixed');
        Date effectiveDate = Date.today().addDays(3);
        Date firstPaymentDate = effectiveDate;
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 45, 'Weekly', 1, firstPaymentDate, effectiveDate, 4
        );
        schedule.EndDate = firstPaymentDate.addDays(21);
        update schedule;
        StripeRecurringScheduleTestDataFactory.createUnpaidTransaction(commitment, schedule, 45, firstPaymentDate);
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;

        Test.startTest();
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });
        Test.stopTest();

        Stripe_Subscription_Change__c requestRecord = [
            SELECT Requested_Recurring_Type__c, Requested_Installments__c,
                   Requested_Effective_Date__c, Requested_First_Payment_Date__c,
                   Requested_Final_Payment_Date__c, Stripe_Action_Mode__c, Status__c,
                   Idempotency_Key__c
            FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c = :commitment.Id
            LIMIT 1
        ];
        Assert.areEqual('Fixed', requestRecord.Requested_Recurring_Type__c, 'Recurring type must be part of the durable request.');
        Assert.areEqual(4, requestRecord.Requested_Installments__c, 'Installment count must be durable.');
        Assert.areEqual(effectiveDate, requestRecord.Requested_Effective_Date__c, 'Chosen configuration date must be retained.');
        Assert.areEqual(firstPaymentDate, requestRecord.Requested_First_Payment_Date__c, 'First real payment date must be retained separately.');
        Assert.areEqual(firstPaymentDate.addDays(21), requestRecord.Requested_Final_Payment_Date__c, 'Final payment must be derived from four weekly installments.');
        Assert.areEqual('Scheduled', requestRecord.Stripe_Action_Mode__c, 'A future request must be classified as Scheduled.');
        Assert.areEqual('Pending', requestRecord.Status__c, 'The durable request starts Pending.');
        Assert.isTrue(requestRecord.Idempotency_Key__c.startsWith('sapa-rd-'), 'Composite requests need a stable key.');
    }

    @IsTest
    static void futureStripeAcceptanceMarksScheduledAndDoesNotActivatePrice() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment('sub_effective', 'Open');
        Date effectiveDate = Date.today().addDays(3);
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 45, 'Weekly', 1, effectiveDate, effectiveDate, null
        );
        StripeRecurringScheduleTestDataFactory.createUnpaidTransaction(commitment, schedule, 45, effectiveDate);
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });
        Stripe_Subscription_Change__c requestRecord = [
            SELECT Id FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c = :commitment.Id LIMIT 1
        ];
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(HttpCalloutMock.class, new ScheduledStripeMock(Date.today().addDays(10), effectiveDate, requestRecord.Id));

        Test.startTest();
        StripeRecurringScheduleChangeService.processRequest(requestRecord.Id);
        Test.stopTest();

        requestRecord = [
            SELECT Status__c, Stripe_Action_Mode__c, Stripe_Schedule_Id__c, Stripe_Price_Id__c, Last_Error__c
            FROM Stripe_Subscription_Change__c WHERE Id = :requestRecord.Id
        ];
        Assert.areEqual('Scheduled', requestRecord.Status__c,
            'Stripe acceptance of a future phase is Scheduled, not Synced. Error: ' + requestRecord.Last_Error__c);
        Assert.areEqual('Scheduled', requestRecord.Stripe_Action_Mode__c, 'The request must record the Stripe action mode.');
        Assert.areEqual('sub_sched_effective', requestRecord.Stripe_Schedule_Id__c, 'The visible Stripe schedule id must be retained.');
        GiftCommitment updated = [SELECT Price_Id__c, Stripe_Schedule_Sync_Status__c FROM GiftCommitment WHERE Id = :commitment.Id];
        Assert.areEqual('price_original', updated.Price_Id__c, 'Salesforce Price Id must not change until the target Price activates.');
        Assert.areEqual('Scheduled', updated.Stripe_Schedule_Sync_Status__c, 'Business users must see the future state.');
    }

    @IsTest
    static void parentAndScheduleTriggersCoalesceOneCompositeCapture() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment('sub_effective', 'Open');
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, Date.today().addDays(10), Date.today(), null
        );
        StripeRecurringScheduleTestDataFactory.createUnpaidTransaction(commitment, schedule, 30, Date.today().addDays(10));
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;
        StripeRecurringScheduleCaptureCoalescer.resetForTest();

        Test.startTest();
        schedule.Stripe_Change_Effective_Date__c = Date.today().addDays(5);
        update schedule;
        commitment.Recurring_Type__c = 'Fixed';
        update commitment;
        Test.stopTest();

        Assert.areEqual(1, StripeRecurringScheduleCaptureCoalescer.getEnqueueCountForTest(),
            'Parent and schedule changes in one transaction must enqueue one capture.');
    }

    @IsTest
    static void flowStampStoresChosenDateAndFirstPaymentSeparately() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment('sub_effective', 'Fixed');
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, Date.today().addDays(10), null, null
        );
        StripeRecurringScheduleStampAction.Request request = new StripeRecurringScheduleStampAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 30;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.effectiveDate = Date.today().addDays(2);
        request.firstPaymentDate = Date.today().addDays(10);
        request.selectedScheduleId = schedule.Id;
        request.recurringType = 'Fixed';
        request.plannedInstallments = 3;

        Test.startTest();
        List<StripeRecurringScheduleStampAction.Response> responses =
            StripeRecurringScheduleStampAction.execute(new List<StripeRecurringScheduleStampAction.Request>{ request });
        Test.stopTest();

        Assert.isTrue(responses[0].isSuccess, 'The guided action must stamp the managed schedule.');
        schedule = [
            SELECT Stripe_Change_Effective_Date__c, StartDate, EndDate, Number_of_Planned_Installments__c
            FROM GiftCommitmentSchedule WHERE Id = :schedule.Id
        ];
        Assert.areEqual(request.effectiveDate, schedule.Stripe_Change_Effective_Date__c, 'Configuration date must be stored separately.');
        Assert.areEqual(Date.today().addDays(10), schedule.StartDate,
            'The existing Start Date must remain unchanged by a guided stamp.');
        Assert.areEqual(Date.today().addDays(10).addMonths(2).year(), schedule.EndDate.year(),
            'Fixed End Date must remain in the calculated billing year.');
        Assert.areEqual(Date.today().addDays(10).addMonths(2).month(), schedule.EndDate.month(),
            'Fixed End Date must remain in the calculated billing month.');
        Assert.isTrue(schedule.Number_of_Planned_Installments__c != null &&
            schedule.Number_of_Planned_Installments__c > 0,
            'The planned installment count must be stored as a positive value.');
    }

    @IsTest
    static void flowStampCreatesFirstCadenceRequestWhenManagedBoundaryPrecedesPayment() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_first_cadence_handoff', 'Open'
        );
        Date managedScheduleStartDate = Date.today().addDays(1);
        Date firstPaymentDate = Date.today().addDays(7);
        GiftCommitmentSchedule successorSchedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment,
            25,
            'Weekly',
            1,
            managedScheduleStartDate,
            managedScheduleStartDate,
            null
        );
        StripeRecurringScheduleTestDataFactory.createUnpaidTransaction(
            commitment,
            successorSchedule,
            25,
            firstPaymentDate
        );
        update new GiftCommitment(
            Id = commitment.Id,
            NextTransactionDate = firstPaymentDate
        );
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;

        Map<String, Object> requestValues = new Map<String, Object>{
            'giftCommitmentId' => commitment.Id,
            'amount' => 25,
            'transactionPeriod' => 'Weekly',
            'transactionInterval' => 1,
            'effectiveDate' => firstPaymentDate,
            'managedScheduleStartDate' => managedScheduleStartDate,
            'firstPaymentDate' => firstPaymentDate,
            'requestedStartDate' => firstPaymentDate,
            'recurringType' => 'Open',
            'changeMode' => StripeRecurringChangeMode.TERMS,
            'createRequestAfterSave' => true
        };
        StripeRecurringScheduleStampAction.Request request =
            (StripeRecurringScheduleStampAction.Request) JSON.deserialize(
                JSON.serialize(requestValues),
                StripeRecurringScheduleStampAction.Request.class
            );

        Test.startTest();
        StripeRecurringScheduleStampAction.Response response =
            StripeRecurringScheduleStampAction.execute(
                new List<StripeRecurringScheduleStampAction.Request>{ request }
            )[0];
        Test.stopTest();

        Assert.isTrue(response.isSuccess,
            'The first cadence edit must resolve the successor schedule from its managed boundary. '
            + 'errorType=' + response.errorType + ', error=' + response.errorMessage);
        Assert.areEqual(successorSchedule.Id, response.scheduleId,
            'The durable handoff must target the newly managed successor schedule.');
        Assert.isNotNull(response.requestId,
            'The first save must create a durable Stripe request without requiring a second edit.');

        Stripe_Subscription_Change__c durableRequest = [
            SELECT Gift_Commitment_Schedule__c, Requested_Configuration_Start_Date__c,
                   Requested_First_Payment_Date__c, Requested_Amount__c,
                   Requested_Period__c, Requested_Interval__c
            FROM Stripe_Subscription_Change__c
            WHERE Id = :response.requestId
        ];
        Assert.areEqual(successorSchedule.Id, durableRequest.Gift_Commitment_Schedule__c,
            'The request must reference the successor schedule created by the first edit.');
        Assert.areEqual(managedScheduleStartDate,
            durableRequest.Requested_Configuration_Start_Date__c,
            'The Salesforce boundary must remain separate from the billing date.');
        Assert.areEqual(firstPaymentDate, durableRequest.Requested_First_Payment_Date__c,
            'The first weekly payment must remain one cadence interval after the latest payment.');
        Assert.areEqual(25, durableRequest.Requested_Amount__c,
            'The first request must retain the requested amount.');
        Assert.areEqual('Weekly', durableRequest.Requested_Period__c,
            'The first request must retain the requested cadence.');
        Assert.areEqual(1, durableRequest.Requested_Interval__c,
            'The first request must retain the requested interval.');
    }

    @IsTest
    static void flowStampRejectsAnAmbiguousManagedScheduleMatch() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        Date managedScheduleStartDate = Date.today().addDays(1);
        StripeRecurringScheduleStampAction.Request request =
            new StripeRecurringScheduleStampAction.Request();
        request.amount = 25;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 1;
        request.managedScheduleStartDate = managedScheduleStartDate;

        GiftCommitmentSchedule firstMatch = new GiftCommitmentSchedule(
            StartDate = managedScheduleStartDate,
            TransactionAmount = 25,
            TransactionPeriod = 'Weekly',
            TransactionInterval = 1
        );
        GiftCommitmentSchedule secondMatch = firstMatch.clone(false, true, false, false);

        Assert.isNull(
            StripeRecurringScheduleStampAction.findMatch(
                request,
                new List<GiftCommitmentSchedule>{ firstMatch, secondMatch }
            ),
            'The stamp action must block when a unique managed schedule cannot be resolved.'
        );
    }

    @IsTest
    static void flowPreviewRejectsPastDateWithBusinessError() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment('sub_effective', 'Open');
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, Date.today().addDays(5), Date.today().addDays(5), null
        );
        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 30;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.transactionDay = '15';
        request.effectiveDate = Date.today().addDays(-1);
        request.recurringType = 'Open';
        request.selectedScheduleId = schedule.Id;

        Test.startTest();
        List<StripeRecurringScheduleFlowAction.Response> responses =
            StripeRecurringScheduleFlowAction.execute(new List<StripeRecurringScheduleFlowAction.Request>{ request });
        Test.stopTest();

        Assert.isFalse(responses[0].isSuccess, 'The Flow preview must block past dates.');
        Assert.isTrue(responses[0].blockingError.contains('past'), 'The Flow must receive a business-readable blocking error.');
    }

    @IsTest
    static void flowPreviewNormalizesTodayOrFutureConfigurationDate() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_preview_normalized', 'Open'
        );
        Date requestedStart = Date.today().addDays(5);
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, requestedStart, requestedStart, null
        );
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(
            HttpCalloutMock.class,
            new ScheduledStripeMock(Date.today().addDays(30), requestedStart, null)
        );

        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 30;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.transactionDay = '15';
        request.effectiveDate = requestedStart;
        request.recurringType = 'Open';
        request.requestedStartDate = requestedStart;
        request.selectedScheduleId = schedule.Id;

        Test.startTest();
        List<StripeRecurringScheduleFlowAction.Response> responses =
            StripeRecurringScheduleFlowAction.execute(
                new List<StripeRecurringScheduleFlowAction.Request>{ request }
            );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        Assert.isTrue(responses[0].isSuccess,
            'The read-only preview should normalize a valid future date. Error: ' + responses[0].blockingError);
        Assert.areEqual(Date.today().addDays(30), responses[0].firstPaymentDate,
            'The existing Stripe renewal date is retained; the Flow does not offer a Start Date change.');
        Assert.isNull(responses[0].normalizedEffectiveDate,
            'No Start Date normalization is needed when the existing Start Date is retained.');
    }

    @IsTest
    static void flowPreviewRejectsUnclassifiedSubscriptionBeforeCallout() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_unclassified_preview', 'Open'
        );
        commitment.Payment_Processor__c = 'Manual';
        commitment.Payment_type__c = 'Cash';
        update commitment;
        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 30;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.effectiveDate = Date.today();
        request.recurringType = 'Open';

        List<StripeRecurringScheduleFlowAction.Response> responses =
            StripeRecurringScheduleFlowAction.execute(
                new List<StripeRecurringScheduleFlowAction.Request>{ request }
            );

        Assert.isFalse(responses[0].isSuccess);
        Assert.areEqual('NOT_VERIFIED_STRIPE', responses[0].errorType);
    }

    @IsTest
    static void flowPreviewBlocksStripeClassificationWithoutSubscriptionId() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_missing_subscription_preview', 'Open'
        );
        commitment.Subscription_Id__c = null;
        update commitment;
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, Date.today().addDays(5), Date.today().addDays(5), null
        );

        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 30;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.effectiveDate = Date.today().addDays(5);
        request.recurringType = 'Open';
        request.selectedScheduleId = schedule.Id;

        List<StripeRecurringScheduleFlowAction.Response> responses =
            StripeRecurringScheduleFlowAction.execute(
                new List<StripeRecurringScheduleFlowAction.Request>{ request }
            );

        Assert.isFalse(responses[0].isSuccess);
        Assert.areEqual('MISSING_SUBSCRIPTION', responses[0].errorType);
    }

    @IsTest
    static void flowPreviewRequiresSelectedScheduleForVerifiedTermChange() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_first_payment_guard', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, Date.today(), Date.today(), null
        );
        insert new GiftTransaction(
            Name = 'Stripe First Payment Today',
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid',
            OriginalAmount = 30,
            TransactionDate = Date.today(),
            TransactionDueDate = Date.today(),
            PaymentMethod = 'Credit Card'
        );

        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 35;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.effectiveDate = Date.today();
        request.recurringType = 'Open';
        request.paymentMethod = 'Credit Card';

        Test.startTest();
        List<StripeRecurringScheduleFlowAction.Response> responses =
            StripeRecurringScheduleFlowAction.execute(
                new List<StripeRecurringScheduleFlowAction.Request>{ request }
            );
        Test.stopTest();

        Assert.isFalse(responses[0].isSuccess, 'A verified term preview must not bypass schedule selection.');
        Assert.areEqual('MISSING_SELECTED_SCHEDULE', responses[0].errorType,
            'The preview should fail before any Stripe callout when the selected schedule is missing.');
    }

    @IsTest
    static void stampRejectsFixedRequestWithInvalidRequestedDates() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_stamp_invalid_dates', 'Fixed'
        );
        Date firstPaymentDate = Date.today().addDays(5);
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, firstPaymentDate, firstPaymentDate, null
        );

        StripeRecurringScheduleStampAction.Request request = new StripeRecurringScheduleStampAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 30;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.effectiveDate = firstPaymentDate;
        request.firstPaymentDate = firstPaymentDate;
        request.requestedStartDate = firstPaymentDate;
        request.requestedEndDate = firstPaymentDate.addDays(-1);
        request.selectedScheduleId = schedule.Id;
        request.recurringType = 'Fixed';

        List<StripeRecurringScheduleStampAction.Response> responses =
            StripeRecurringScheduleStampAction.execute(
                new List<StripeRecurringScheduleStampAction.Request>{ request }
            );

        Assert.isFalse(responses[0].isSuccess);
        Assert.areEqual('INVALID_PAYMENT_DATES', responses[0].errorType);
    }

    @IsTest
    static void flowPreviewBlocksStartDateTakenTodayAndReturnsNextUnpaidDate() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_first_payment_guard_block', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, Date.today(), Date.today(), null
        );
        insert new GiftTransaction(
            Name = 'Stripe First Payment Today',
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid',
            OriginalAmount = 30,
            TransactionDate = Date.today(),
            TransactionDueDate = Date.today(),
            PaymentMethod = 'Credit Card'
        );
        StripeRecurringScheduleTestDataFactory.createUnpaidTransaction(
            commitment, schedule, 30, Date.today().addDays(7)
        );

        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 35;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.effectiveDate = Date.today();
        request.recurringType = 'Open';
        request.paymentMethod = 'Credit Card';
        request.selectedScheduleId = schedule.Id;
        request.proposedStartDate = Date.today().addDays(1);

        Test.startTest();
        List<StripeRecurringScheduleFlowAction.Response> responses =
            StripeRecurringScheduleFlowAction.execute(
                new List<StripeRecurringScheduleFlowAction.Request>{ request }
            );
        Test.stopTest();

        Assert.isFalse(responses[0].isSuccess, 'The first payment today must block only a same-day Start Date change.');
        Assert.areEqual('FIRST_PAYMENT_TODAY', responses[0].errorType);
            Assert.areEqual(
            'A payment has already been taken today. You cannot change the Start Date effective today. ' +
            'Select the next unpaid payment date or a later date.',
            responses[0].blockingError
        );
        Assert.areEqual(Date.today().addDays(7), responses[0].nextAllowedEffectiveDate,
            'The earliest future unpaid transaction should be returned to the Flow.');
    }

    @IsTest
    static void flowPreviewAllowsTodayBeforeFirstPayment() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_first_payment_guard_allowed', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, Date.today(), Date.today(), null
        );
        StripeRecurringScheduleTestDataFactory.createUnpaidTransaction(
            commitment, schedule, 30, Date.today().addDays(7)
        );
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(
            HttpCalloutMock.class,
            new ScheduledStripeMock(Date.today().addDays(10), Date.today().addDays(7), null)
        );

        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 35;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 1;
        request.effectiveDate = Date.today();
        request.recurringType = 'Open';
        request.paymentMethod = 'Credit Card';
        request.selectedScheduleId = schedule.Id;

        Test.startTest();
        List<StripeRecurringScheduleFlowAction.Response> responses =
            StripeRecurringScheduleFlowAction.execute(
                new List<StripeRecurringScheduleFlowAction.Request>{ request }
            );
        Test.stopTest();

        Assert.isTrue(responses[0].isSuccess,
            responses[0].blockingError == null ? 'A same-day change before payment should be previewable.' : responses[0].blockingError);
    }

    @IsTest
    static void flowPreviewAllowsEstablishedScheduleTermsWithPaidToday() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_first_payment_guard_established', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, Date.today().addDays(-30), Date.today().addDays(-30), null
        );
        insert new GiftTransaction(
            Name = 'Stripe Established Payment Today',
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid',
            OriginalAmount = 30,
            TransactionDate = Date.today(),
            TransactionDueDate = Date.today(),
            PaymentMethod = 'Credit Card'
        );
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(
            HttpCalloutMock.class,
            new ScheduledStripeMock(Date.today().addDays(10), Date.today().addDays(7), null)
        );

        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 35;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 1;
        request.effectiveDate = Date.today();
        request.recurringType = 'Open';
        request.paymentMethod = 'Credit Card';
        request.selectedScheduleId = schedule.Id;

        Test.startTest();
        List<StripeRecurringScheduleFlowAction.Response> responses =
            StripeRecurringScheduleFlowAction.execute(
                new List<StripeRecurringScheduleFlowAction.Request>{ request }
            );
        Test.stopTest();

        Assert.isTrue(responses[0].isSuccess,
            responses[0].blockingError == null
                ? 'Terms changes remain allowed after payment today.'
                : responses[0].blockingError);
        Assert.areEqual('Terms', responses[0].changeMode);
        Assert.isFalse(responses[0].sameDayMutationRequired,
            'The Flow must create a future managed schedule rather than mutate the paid schedule.');
        Assert.areEqual(Date.today().addDays(7), responses[0].firstPaymentDate,
            'Weekly cadence must begin one week after the latest successful payment.');
        Assert.areEqual(Date.today().addDays(7), responses[0].normalizedEffectiveDate,
            'Stripe must receive the future first-payment date as the phase effective date.');
    }

    @IsTest
    static void flowPreviewReturnsEffectiveDate_WhenFutureCadenceIsAlreadyPlanned() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_future_cadence_preview', 'Open'
        );
        Date futureEffectiveDate = Date.today().addDays(7);
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 31, 'Monthly', 1, futureEffectiveDate, Date.today(), null
        );
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(
            HttpCalloutMock.class,
            new ScheduledStripeMock(Date.today().addDays(30), futureEffectiveDate, null)
        );

        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 31;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 1;
        request.effectiveDate = futureEffectiveDate;
        request.recurringType = 'Open';
        request.paymentMethod = 'Credit Card';
        request.selectedScheduleId = schedule.Id;
        request.requestedStartDate = schedule.StartDate;

        Test.startTest();
        List<StripeRecurringScheduleFlowAction.Response> responses =
            StripeRecurringScheduleFlowAction.execute(
                new List<StripeRecurringScheduleFlowAction.Request>{ request }
            );
        Test.stopTest();

        Assert.isTrue(
            responses[0].isSuccess,
            responses[0].blockingError == null
                ? 'Expected a successful future cadence preview.'
                : responses[0].blockingError
        );
        Assert.areEqual(
            futureEffectiveDate,
            responses[0].normalizedEffectiveDate,
            'A successful future cadence preview must return the date required by the stamp action.'
        );
    }

    @IsTest
    static void flowPreviewReturnsCompleteTemporaryAmountWindowAndRestoration() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_temporary_amount_preview', 'Open'
        );
        Date originalRenewal = Date.today().addDays(30);
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, Date.today().addMonths(-1), Date.today().addMonths(-1), null
        );
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(
            HttpCalloutMock.class,
            new ScheduledStripeMock(originalRenewal, originalRenewal, null)
        );

        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 45;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.effectiveDate = originalRenewal;
        request.effectiveEndDate = originalRenewal;
        request.recurringType = 'Open';
        request.paymentMethod = 'Credit Card';
        request.selectedScheduleId = schedule.Id;
        request.requestedStartDate = schedule.StartDate;

        Test.startTest();
        List<StripeRecurringScheduleFlowAction.Response> responses =
            StripeRecurringScheduleFlowAction.execute(
                new List<StripeRecurringScheduleFlowAction.Request>{ request }
            );
        Test.stopTest();

        StripeRecurringScheduleFlowAction.Response response = responses[0];
        Assert.isTrue(response.isSuccess,
            response.blockingError == null ? 'Expected a successful temporary preview.' : response.blockingError);
        Assert.areEqual('TemporaryTerms', response.changeMode);
        Assert.areEqual(originalRenewal, response.firstPaymentDate);
        Assert.areEqual(originalRenewal, response.lastTemporaryPaymentDate);
        Assert.areEqual(1, response.temporaryInstallments);
        Assert.areEqual(originalRenewal.addMonths(1), response.restorationFirstPaymentDate);
        Assert.areEqual(30, response.originalAmount);
        Assert.areEqual('Monthly', response.originalPeriod);
        Assert.areEqual(1, response.originalInterval);
        Assert.areEqual('price_original', response.originalPriceId);
    }

    @IsTest
    static void flowPreviewAmountOnlyRetainsEarliestFutureUnpaidDate() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_amount_future_only', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 5, 'Monthly', 1, Date.today().addMonths(-1), Date.today().addMonths(-1), null
        );
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        schedule.TransactionDay = '15';
        update schedule;
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = false;
        insert new GiftTransaction(
            Name = 'Paid amount baseline', DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id, GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid', OriginalAmount = 5, TransactionDate = Date.today(),
            TransactionDueDate = Date.today(), PaymentMethod = 'Credit Card'
        );
        Date nextUnpaidDate = Date.today().addDays(12);
        StripeRecurringScheduleTestDataFactory.createUnpaidTransaction(
            commitment, schedule, 5, nextUnpaidDate
        );
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(
            HttpCalloutMock.class,
            new ScheduledStripeMock(Date.today().addDays(30), Date.today(), null)
        );

        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 50;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.transactionDay = '15';
        request.effectiveDate = Date.today();
        request.recurringType = 'Open';
        request.paymentMethod = 'Credit Card';
        request.selectedScheduleId = schedule.Id;
        request.requestedStartDate = schedule.StartDate;

        Test.startTest();
        List<StripeRecurringScheduleFlowAction.Response> responses =
            StripeRecurringScheduleFlowAction.execute(
                new List<StripeRecurringScheduleFlowAction.Request>{ request }
            );
        Test.stopTest();

        Assert.isTrue(
            responses[0].isSuccess,
            responses[0].blockingError == null ? 'Expected a successful amount preview.' : responses[0].blockingError
        );
        Assert.areEqual(nextUnpaidDate, responses[0].firstPaymentDate,
            'Amount-only changes must retain the existing next unpaid billing date.');
        Assert.areEqual(Date.today(), responses[0].normalizedEffectiveDate,
            'The Price can change now without moving the renewal anchor or charging immediately.');
        Assert.isFalse(responses[0].willGenerateFullInvoice,
            'Amount-only changes must not generate an immediate invoice.');
    }

    @IsTest
    static void flowPreviewPreservesMonthlyDayWithPaidTodayAndNoFutureTransaction() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_preview_monthly_day', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 50, 'Monthly', 1, Date.today(), Date.today(), null
        );
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        schedule.TransactionDay = '1';
        update schedule;
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = false;
        insert new GiftTransaction(
            Name = 'Paid today before monthly day preview',
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid',
            OriginalAmount = 50,
            TransactionDate = Date.today(),
            TransactionDueDate = Date.today(),
            PaymentMethod = 'Credit Card'
        );
        Date selectedPaymentDate = StripeRDScheduleDateCalc.nextMonthlyTransactionDate(
            Date.today(), '15'
        );
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(
            HttpCalloutMock.class,
            new ScheduledStripeMock(Date.today().addMonths(1), selectedPaymentDate, null)
        );

        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 60;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.transactionDay = '15';
        request.effectiveDate = Date.today();
        request.recurringType = 'Open';
        request.paymentMethod = 'Credit Card';
        request.selectedScheduleId = schedule.Id;
        request.requestedStartDate = schedule.StartDate;

        Test.startTest();
        StripeRecurringScheduleFlowAction.Response response =
            StripeRecurringScheduleFlowAction.execute(
                new List<StripeRecurringScheduleFlowAction.Request>{ request }
            )[0];
        Test.stopTest();

        Assert.isTrue(response.isSuccess,
            response.blockingError == null ? 'Expected a successful Monthly-day preview.' : response.blockingError);
        Assert.areEqual('15', response.requestedTransactionDay);
        Assert.areEqual(selectedPaymentDate, response.firstPaymentDate);
        Assert.areEqual('Scheduled', response.actionMode);
        Assert.isTrue(response.willGenerateFullInvoice,
            'The full amount is invoiced only when the new Monthly day becomes active.');
    }

    @IsTest
    static void plannedMonthlyDay15SurvivesFutureEffectiveDateHandoff() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        assertPlannedMonthlyHandoff('15', 90, true);
    }

    @IsTest
    static void plannedMonthlyDay16SurvivesFutureEffectiveDateHandoff() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        assertPlannedMonthlyHandoff('16', 90, true);
    }

    @IsTest
    static void plannedMonthlyDayOnlySurvivesFutureEffectiveDateHandoff() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        assertPlannedMonthlyHandoff('15', 700, true);
    }

    @IsTest
    static void legacyFuturePreviewKeepsExistingRenewalWithoutOptIn() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        assertPlannedMonthlyHandoff('15', 90, false);
    }

    @IsTest
    static void changedUnpaidDateAfterPreviewStillBlocksFinalGuard() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment('sub_stale_monthly_plan', 'Open');
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 700, 'Monthly', 1, Date.today().addMonths(-1), Date.today(), null
        );
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        schedule.TransactionDay = '15';
        update schedule;
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = false;
        Date renewal = Date.newInstance(Date.today().year(), Date.today().month(), 15);
        if (renewal <= Date.today()) renewal = renewal.addMonths(1);
        GiftTransaction unpaid = StripeRecurringScheduleTestDataFactory.createUnpaidTransaction(commitment, schedule, 700, renewal);
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(HttpCalloutMock.class, new ScheduledStripeMock(renewal, Date.today(), null));
        StripeRecurringScheduleFlowAction.Request previewInput = (StripeRecurringScheduleFlowAction.Request) JSON.deserialize(
            JSON.serialize(new Map<String, Object>{
                'giftCommitmentId' => commitment.Id, 'selectedScheduleId' => schedule.Id,
                'amount' => 90, 'transactionPeriod' => 'Monthly', 'transactionInterval' => 1,
                'transactionDay' => '15', 'effectiveDate' => Date.today(),
                'requestedStartDate' => schedule.StartDate, 'recurringType' => 'Open',
                'paymentMethod' => 'Credit Card', 'usePlannedTermsBoundary' => true
            }), StripeRecurringScheduleFlowAction.Request.class
        );
        Test.startTest();
        StripeRecurringScheduleFlowAction.Response preview = StripeRecurringScheduleFlowAction.execute(
            new List<StripeRecurringScheduleFlowAction.Request>{previewInput}
        )[0];
        Assert.isTrue(preview.isSuccess, 'Amount-only preview must be valid before the competing edit.');
        Assert.areEqual(renewal, preview.firstPaymentDate, 'Amount-only preview retains the existing future unpaid date.');
        Assert.isFalse(preview.willGenerateFullInvoice, 'Amount-only preview must not create an invoice on save.');
        unpaid.TransactionDueDate = renewal.addDays(1);
        update unpaid;
        StripeRDSameDayGuardAction.Request finalInput = new StripeRDSameDayGuardAction.Request();
        finalInput.giftCommitmentId = commitment.Id;
        finalInput.selectedScheduleId = schedule.Id;
        finalInput.effectiveDate = Date.today();
        finalInput.amount = 90;
        finalInput.transactionPeriod = 'Monthly';
        finalInput.transactionInterval = 1;
        finalInput.transactionDay = '15';
        finalInput.recurringType = 'Open';
        finalInput.expectedFirstPaymentDate = preview.firstPaymentDate;
        finalInput.expectedTransactionDay = preview.requestedTransactionDay;
        Integer dmlBefore = Limits.getDmlStatements();
        Integer calloutsBefore = Limits.getCallouts();
        StripeRDSameDayGuardAction.Response finalGuard = StripeRDSameDayGuardAction.execute(
            new List<StripeRDSameDayGuardAction.Request>{finalInput}
        )[0];
        Assert.isFalse(finalGuard.isAllowed, 'An actual change to future payment dates must still block saving.');
        Assert.areEqual('STALE_PREVIEW', finalGuard.errorType, 'A genuine mismatch must retain the stale-preview protection.');
        Assert.areEqual(dmlBefore, Limits.getDmlStatements(), 'Blocked guard must perform no DML.');
        Assert.areEqual(calloutsBefore, Limits.getCallouts(), 'Blocked guard must not call Stripe.');
        Test.stopTest();
    }

    /** Exercises the real planner, preview and final guard; only Stripe HTTP is mocked. */
    private static void assertPlannedMonthlyHandoff(String selectedDay, Decimal requestedAmount, Boolean usePlanner) {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_planned_monthly_handoff', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 700, 'Monthly', 1, Date.today(), Date.today(), null
        );
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        schedule.TransactionDay = selectedDay == '15' ? '3' : '4';
        update schedule;
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = false;
        insert new GiftTransaction(
            Name = 'Paid before planned monthly handoff', DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id, GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid', OriginalAmount = 700, TransactionDate = Date.today(),
            TransactionDueDate = Date.today(), PaymentMethod = 'Credit Card'
        );
        Date expectedPayment = Date.newInstance(Date.today().year(), Date.today().month(), Integer.valueOf(selectedDay));
        if (expectedPayment <= Date.today()) expectedPayment = expectedPayment.addMonths(1);
        Date oldRenewal = Date.today().addMonths(1).addDays(2);
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(HttpCalloutMock.class, new ScheduledStripeMock(oldRenewal, expectedPayment, null));
        StripeRDSameDayGuardAction.Request planInput = new StripeRDSameDayGuardAction.Request();
        planInput.giftCommitmentId = commitment.Id;
        planInput.selectedScheduleId = schedule.Id;
        planInput.effectiveDate = Date.today();
        planInput.amount = requestedAmount;
        planInput.transactionPeriod = 'Monthly';
        planInput.transactionInterval = 1;
        planInput.transactionDay = selectedDay;
        planInput.paymentMethod = 'Credit Card';
        planInput.recurringType = 'Open';
        planInput.changeModeHint = 'Terms';

        Test.startTest();
        StripeRDSameDayGuardAction.Response planned = StripeRDSameDayGuardAction.execute(
            new List<StripeRDSameDayGuardAction.Request>{planInput}
        )[0];
        Assert.isTrue(planned.isAllowed, 'Planner must allow the selected monthly day.');
        Assert.areEqual(expectedPayment, planned.firstPaymentDate, 'Planner must select the next requested monthly day.');
        // JSON keeps this regression executable against v22, before the optional v23 input exists.
        StripeRecurringScheduleFlowAction.Request previewInput = (StripeRecurringScheduleFlowAction.Request) JSON.deserialize(
            JSON.serialize(new Map<String, Object>{
                'giftCommitmentId' => commitment.Id, 'selectedScheduleId' => schedule.Id,
                'resolvedScheduleId' => planned.resolvedScheduleId, 'amount' => requestedAmount,
                'transactionPeriod' => 'Monthly', 'transactionInterval' => 1,
                'transactionDay' => planned.requestedTransactionDay,
                'effectiveDate' => planned.stripeEffectiveDate, 'requestedStartDate' => schedule.StartDate,
                'recurringType' => 'Open', 'paymentMethod' => 'Credit Card',
                'changeModeHint' => 'Terms', 'usePlannedTermsBoundary' => usePlanner
            }), StripeRecurringScheduleFlowAction.Request.class
        );
        Integer dmlBefore = Limits.getDmlStatements();
        StripeRecurringScheduleFlowAction.Response preview = StripeRecurringScheduleFlowAction.execute(
            new List<StripeRecurringScheduleFlowAction.Request>{previewInput}
        )[0];
        Assert.isTrue(preview.isSuccess, 'Preview must succeed: ' + preview.blockingError);
        Assert.areEqual(usePlanner ? expectedPayment : oldRenewal, preview.firstPaymentDate,
            'Guided future effective dates must not fall back to the old Stripe renewal.');
        if (usePlanner) {
            Assert.areEqual(expectedPayment, preview.normalizedEffectiveDate, 'The selected day controls activation.');
            Assert.areEqual('Scheduled', preview.actionMode, 'The monthly day change must be scheduled, not invoiced on save.');
            Assert.areEqual(selectedDay, preview.requestedTransactionDay, 'The selected day must survive preview.');
            planInput.expectedFirstPaymentDate = preview.firstPaymentDate;
            planInput.expectedTransactionDay = preview.requestedTransactionDay;
            StripeRDSameDayGuardAction.Response finalGuard = StripeRDSameDayGuardAction.execute(
                new List<StripeRDSameDayGuardAction.Request>{planInput}
            )[0];
            Assert.isTrue(finalGuard.isAllowed, 'Unchanged input must not produce a false STALE_PREVIEW: ' + finalGuard.errorMessage);
            Assert.areEqual(preview.firstPaymentDate, finalGuard.firstPaymentDate, 'Preview and final guard must agree.');
        }
        Assert.areEqual(dmlBefore, Limits.getDmlStatements(), 'Planning, preview and final guard must not mutate records.');
        Test.stopTest();
        Assert.areEqual(0, [SELECT count() FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c = :commitment.Id],
            'Read-only confirmation must not create a durable request.');
        Assert.areEqual(700, [SELECT OriginalAmount FROM GiftTransaction WHERE GiftCommitmentId = :commitment.Id AND Status = 'Paid' LIMIT 1].OriginalAmount,
            'The original paid transaction must remain unchanged.');
    }

    @IsTest
    static void flowPreviewBlocksMonthlyTermsWithoutTransactionDay() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_preview_monthly_day_missing', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 50, 'Monthly', 1, Date.today(), Date.today(), null
        );

        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 60;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.effectiveDate = Date.today();
        request.recurringType = 'Open';
        request.paymentMethod = 'Credit Card';
        request.selectedScheduleId = schedule.Id;
        request.requestedStartDate = schedule.StartDate;

        StripeRecurringScheduleFlowAction.Response response =
            StripeRecurringScheduleFlowAction.execute(
                new List<StripeRecurringScheduleFlowAction.Request>{ request }
            )[0];

        Assert.isFalse(response.isSuccess);
        Assert.areEqual('INVALID_TRANSACTION_DAY', response.errorType);
    }

    @IsTest
    static void datePreviewReturnsInclusiveFixedInstallments() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [
            SELECT Id FROM GiftCommitment
            WHERE Subscription_Id__c = 'sub_preview_dates'
            LIMIT 1
        ];
        Date firstDate = Date.today().addDays(7);
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Weekly', 1, firstDate, firstDate, 4
        );
        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 30;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 1;
        request.effectiveDate = firstDate;
        request.recurringType = 'Fixed';
        request.proposedStartDate = firstDate;
        request.proposedEndDate = firstDate.addDays(21);
        request.paymentMethod = 'Credit Card';
        request.selectedScheduleId = schedule.Id;
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(HttpCalloutMock.class, new ScheduledStripeMock(Date.today().addDays(4), firstDate, null));

        Test.startTest();
        List<StripeRecurringScheduleFlowAction.Response> responses =
            StripeRecurringScheduleFlowAction.execute(
                new List<StripeRecurringScheduleFlowAction.Request>{ request }
            );
        Test.stopTest();

        Assert.isTrue(
            responses[0].isSuccess,
            responses[0].blockingError == null ? 'Expected a successful date preview.' : responses[0].blockingError
        );
        Assert.areEqual(4, responses[0].calculatedInstallments,
            'Start and end dates represent four inclusive weekly payments.');
        Assert.areEqual(firstDate.addDays(21), responses[0].finalPaymentDate);
    }

    @IsTest
    static void datePreviewSupportsOpenWhenEndDateIsCleared() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_preview_open_dates', 'Fixed'
        );
        Date firstDate = Date.today().addDays(7);
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Weekly', 1, firstDate, firstDate.addDays(21), 4
        );
        StripeRecurringScheduleFlowAction.Request request = new StripeRecurringScheduleFlowAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 30;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 1;
        request.effectiveDate = firstDate;
        request.recurringType = 'Open';
        request.proposedStartDate = firstDate;
        request.proposedEndDate = null;
        request.paymentMethod = 'Credit Card';
        request.selectedScheduleId = schedule.Id;
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(HttpCalloutMock.class, new ScheduledStripeMock(Date.today().addDays(4), firstDate, null));

        Test.startTest();
        List<StripeRecurringScheduleFlowAction.Response> responses =
            StripeRecurringScheduleFlowAction.execute(
                new List<StripeRecurringScheduleFlowAction.Request>{ request }
            );
        Test.stopTest();

        Assert.isTrue(
            responses[0].isSuccess,
            responses[0].blockingError == null ? 'Clearing End Date should preview an Open donation.' : responses[0].blockingError
        );
        Assert.isNull(responses[0].finalPaymentDate, 'Open donations must not have a final payment date.');
        Assert.isNull(responses[0].calculatedInstallments, 'Open donations must not retain fixed installments.');
    }

    @IsTest
    static void retryActionResetsFailedRequestAndQueuesSafeReread() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment('sub_effective', 'Open');
        Stripe_Subscription_Change__c requestRecord = new Stripe_Subscription_Change__c(
            Gift_Commitment__c = commitment.Id,
            Requested_Effective_Date__c = Date.today(),
            Requested_First_Payment_Date__c = Date.today().addDays(10),
            Requested_Amount__c = 30,
            Requested_Period__c = 'Monthly',
            Requested_Interval__c = 1,
            Requested_Recurring_Type__c = 'Open',
            Stripe_Action_Mode__c = 'Immediate',
            Status__c = 'Failed',
            Attempt_Count__c = 0,
            Idempotency_Key__c = 'retry-effective-dated-test',
            Stripe_Subscription_Id__c = 'sub_effective',
            Last_Error__c = 'Temporary Stripe error.'
        );
        insert requestRecord;
        StripeRecurringScheduleRetryAction.permissionBypass = true;
        StripeRecurringScheduleGateway.secretKeyOverride = '';

        Test.startTest();
        String jobId = StripeRecurringScheduleRetryAction.retry(requestRecord.Id);
        Stripe_Subscription_Change__c pending = [SELECT Status__c, Last_Error__c FROM Stripe_Subscription_Change__c WHERE Id = :requestRecord.Id];
        Assert.areEqual('Pending', pending.Status__c, 'Retry must reset the durable request before queueing.');
        Assert.isNull(pending.Last_Error__c, 'The prior transient error must be cleared for the new attempt.');
        Test.stopTest();

        Assert.isNotNull(jobId, 'The retry action must return the queueable job id.');
        requestRecord = [SELECT Status__c, Attempt_Count__c FROM Stripe_Subscription_Change__c WHERE Id = :requestRecord.Id];
        Assert.areEqual('Failed', requestRecord.Status__c, 'A missing credential on the reread must remain auditable as Failed.');
        Assert.areEqual(1, requestRecord.Attempt_Count__c, 'The retry attempt must be counted once.');
    }

    @IsTest
    static void retryActionRejectsUnauthorizedNullAndUnknownRequests() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        StripeRecurringScheduleRetryAction.permissionBypass = false;
        try {
            StripeRecurringScheduleRetryAction.retry(null);
            Assert.fail('A user without the custom permission must be rejected.');
        } catch (AuraHandledException expected) {
            Assert.isNotNull(expected);
        }

        StripeRecurringScheduleRetryAction.permissionBypass = true;
        try {
            StripeRecurringScheduleRetryAction.retry(null);
            Assert.fail('A null request id must be rejected.');
        } catch (AuraHandledException expected) {
            Assert.isNotNull(expected);
        }

        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment('sub_retry_unknown', 'Open');
        Stripe_Subscription_Change__c deletedRequest = new Stripe_Subscription_Change__c(
            Gift_Commitment__c = commitment.Id,
            Requested_Effective_Date__c = Date.today(),
            Requested_Amount__c = 30,
            Requested_Period__c = 'Monthly',
            Requested_Interval__c = 1,
            Requested_Recurring_Type__c = 'Open',
            Status__c = 'Failed',
            Attempt_Count__c = 0,
            Idempotency_Key__c = 'deleted-retry-test',
            Stripe_Subscription_Id__c = 'sub_retry_unknown'
        );
        insert deletedRequest;
        Id unknownRequestId = deletedRequest.Id;
        delete deletedRequest;
        try {
            StripeRecurringScheduleRetryAction.retry(unknownRequestId);
            Assert.fail('An unknown request must be returned as a safe retry error.');
        } catch (AuraHandledException expected) {
            Assert.isNotNull(expected);
        }
    }
}