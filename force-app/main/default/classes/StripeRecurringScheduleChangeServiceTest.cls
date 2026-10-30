@IsTest
private class StripeRecurringScheduleChangeServiceTest {
    private class SuccessfulStripeMock implements HttpCalloutMock {
        private Long periodStart;
        private Long periodEnd;
        private String changeId;
        SuccessfulStripeMock(Date effectiveDate, Id durableRequestId) {
            periodEnd = Datetime.newInstanceGmt(effectiveDate, Time.newInstance(12, 0, 0, 0)).getTime() / 1000;
            periodStart = periodEnd - 604800;
            changeId = durableRequestId;
        }
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            if (request.getMethod() == 'GET' && request.getEndpoint().contains('/subscription_schedules/')) {
                response.setBody('{"id":"sub_sched_service_1","subscription":"sub_service_1",' +
                    '"metadata":{"sapa_owner":"salesforce"},"phases":[' +
                    '{"start_date":' + periodStart + ',"end_date":' + periodEnd + ',"items":[{"price":"price_service_old","quantity":1}]},' +
                    '{"start_date":' + periodEnd + ',"items":[{"price":"price_service_old","quantity":1}],' +
                    '"metadata":{"salesforce_change_id":"' + changeId + '"}}]}');
            } else if (request.getMethod() == 'GET') {
                response.setBody('{"id":"sub_service_1","status":"active","collection_method":"charge_automatically",' +
                    '"current_period_start":' + periodStart + ',"current_period_end":' + periodEnd + ',"schedule":null,' +
                    '"items":{"data":[{"id":"si_service_1","quantity":1,"price":{"id":"price_service_old",' +
                    '"unit_amount":2000,"product":"prod_service_1","currency":"aud",' +
                    '"recurring":{"interval":"week","interval_count":1}}}]}}');
            } else if (request.getEndpoint().endsWith('/prices')) {
                response.setBody('{"id":"price_service_new"}');
            } else if (request.getEndpoint().endsWith('/subscription_schedules')) {
                response.setBody('{"id":"sub_sched_service_1","subscription":"sub_service_1"}');
            } else {
                response.setBody('{"id":"sub_sched_service_1","phases":[{"start_date":' + periodStart + ',"end_date":' + periodEnd + ',"items":[{"price":"price_service_old","quantity":1}]},{"start_date":' + periodEnd + ',"items":[{"price":"price_service_new","quantity":1}]}]}');
            }
            return response;
        }
    }

    @TestSetup
    static void setupData() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        Account donor = new Account(LastName = 'Schedule Sync Donor');
        insert donor;
        GiftCommitment commitment = new GiftCommitment(
            Name = 'Schedule Sync Commitment',
            DonorId = donor.Id,
            Status = 'Active',
            Recurring_Type__c = 'Open',
            Subscription_Id__c = 'sub_service_1',
            Payment_Processor__c = 'Stripe',
            Payment_type__c = 'Credit Card',
            Product_Id__c = 'prod_service_1',
            Price_Id__c = 'price_service_old',
            CurrencyIsoCode = 'AUD'
        );
        insert commitment;
        Date nextDate = Date.today().addDays(1);
        GiftCommitmentSchedule schedule = new GiftCommitmentSchedule(
            GiftCommitmentId = commitment.Id,
            TransactionAmount = 20,
            TransactionPeriod = 'Weekly',
            TransactionInterval = 1,
            StartDate = nextDate,
            PaymentMethod = 'Credit Card'
        );
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        insert schedule;
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = false;
        GiftTransaction nextTransaction = new GiftTransaction(
            Name = 'Next Unpaid Schedule Transaction',
            DonorId = donor.Id,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = schedule.Id,
            Status = 'Pledged',
            OriginalAmount = 20,
            TransactionDueDate = nextDate,
            PaymentMethod = 'Credit Card'
        );
        insert nextTransaction;
    }

    @IsTest
    static void createsOnePendingRequestForTheNextUnpaidSchedule() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [SELECT Id FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1];
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;

        Test.startTest();
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });
        Test.stopTest();

        List<Stripe_Subscription_Change__c> requests = [
            SELECT Status__c, Requested_Amount__c, Requested_Period__c, Requested_Interval__c,
                   Requested_Effective_Date__c, Gift_Commitment_Schedule__c, Idempotency_Key__c
            FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c = :commitment.Id
        ];
        Assert.areEqual(1, requests.size());
        Assert.areEqual('Pending', requests[0].Status__c);
        Assert.areEqual(20, requests[0].Requested_Amount__c);
        Assert.areEqual('Weekly', requests[0].Requested_Period__c);
        Assert.areEqual(1, requests[0].Requested_Interval__c);
        Assert.areEqual(Date.today().addDays(1), requests[0].Requested_Effective_Date__c);
        Assert.isNotNull(requests[0].Gift_Commitment_Schedule__c);
        Assert.isTrue(requests[0].Idempotency_Key__c.startsWith('sapa-rd-'));
    }

    @IsTest
    static void durableRequestUsesActualUnpaidDateInsteadOfScheduleStart() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        Account donor = new Account(LastName = 'Actual Billing Date Donor');
        insert donor;
        GiftCommitment commitment = new GiftCommitment(
            Name = 'Actual Billing Date Commitment',
            DonorId = donor.Id,
            Status = 'Active',
            Recurring_Type__c = 'Open',
            Subscription_Id__c = 'sub_actual_billing_date',
            Payment_Processor__c = 'Stripe',
            Payment_type__c = 'Credit Card',
            Product_Id__c = 'prod_service_1',
            Price_Id__c = 'price_service_old',
            CurrencyIsoCode = 'AUD'
        );
        insert commitment;
        Date scheduleStart = Date.today().addDays(29);
        Date actualUnpaidDate = Date.today().addDays(44);
        GiftCommitmentSchedule schedule = new GiftCommitmentSchedule(
            GiftCommitmentId = commitment.Id,
            TransactionAmount = 10,
            TransactionPeriod = 'Monthly',
            TransactionInterval = 1,
            TransactionDay = '15',
            StartDate = scheduleStart,
            PaymentMethod = 'Credit Card'
        );
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        insert schedule;
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = false;
        insert new GiftTransaction(
            Name = 'Actual October billing transaction',
            DonorId = donor.Id,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = schedule.Id,
            Status = 'Pledged',
            OriginalAmount = 10,
            TransactionDueDate = actualUnpaidDate,
            PaymentMethod = 'Credit Card'
        );
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;

        Test.startTest();
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(
            new Set<Id>{ commitment.Id }
        );
        Test.stopTest();

        Stripe_Subscription_Change__c requestRecord = [
            SELECT Requested_First_Payment_Date__c, Requested_Transaction_Day__c
            FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c = :commitment.Id
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        Assert.areEqual(actualUnpaidDate, requestRecord.Requested_First_Payment_Date__c,
            'The durable request must use the earliest real unpaid transaction date, not the schedule StartDate.');
        Assert.areEqual(String.valueOf(actualUnpaidDate.day()), requestRecord.Requested_Transaction_Day__c,
            'The durable request must retain the verified monthly billing day.');
    }

    @IsTest
    static void guidedCaptureBuildsFixedRequestAfterParentAndScheduleChanges() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [
            SELECT Id FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1
        ];
        GiftCommitmentSchedule schedule = [
            SELECT Id, StartDate FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1
        ];
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;
        StripeRecurringScheduleCaptureCoalescer.resetForTest();
        StripeRecurringScheduleCaptureCoalescer.beginGuidedSync(new Set<Id>{ commitment.Id });

        commitment.Recurring_Type__c = 'Fixed';
        update commitment;
        schedule.Number_of_Planned_Installments__c = 3;
        // The fixture cadence is weekly, so three inclusive installments span
        // the first date plus two weekly periods.
        schedule.EndDate = schedule.StartDate.addDays(14);
        update schedule;

        Test.startTest();
        Id requestId = StripeRecurringScheduleChangeService.createGuidedRequestAndEnqueueForGiftCommitment(
            commitment.Id
        );
        Test.stopTest();

        Stripe_Subscription_Change__c request = [
            SELECT Status__c, Requested_Recurring_Type__c, Requested_Installments__c,
                   Requested_Final_Payment_Date__c
            FROM Stripe_Subscription_Change__c
            WHERE Id = :requestId
        ];
        Assert.areEqual('Pending', request.Status__c,
            'The guided request should be actionable after the final schedule state is saved.');
        Assert.areEqual('Fixed', request.Requested_Recurring_Type__c);
        Assert.areEqual(3, request.Requested_Installments__c,
            'The durable request must contain the calculated Fixed installment count.');
        Assert.areEqual(schedule.StartDate.addDays(14), request.Requested_Final_Payment_Date__c,
            'The durable request must contain the final payment date from the saved schedule.');
        Assert.areEqual(0, StripeRecurringScheduleCaptureCoalescer.getEnqueueCountForTest(),
            'Guided parent and schedule updates must not enqueue a competing capture.');
    }

    @IsTest
    static void endDateOnlyModeWinsOverStaleFlowTermsHint() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitmentSchedule schedule = [
            SELECT Id, StartDate, TransactionAmount, TransactionPeriod, TransactionInterval
            FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId IN (
                SELECT Id FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1'
            )
            LIMIT 1
        ];
        StripeRecurringScheduleStampAction.Request request =
            new StripeRecurringScheduleStampAction.Request();
        request.amount = schedule.TransactionAmount;
        request.transactionPeriod = schedule.TransactionPeriod;
        request.transactionInterval = Integer.valueOf(schedule.TransactionInterval);
        request.requestedStartDate = schedule.StartDate;
        request.previousEndDate = null;
        request.requestedEndDate = schedule.StartDate.addDays(14);
        request.changeMode = StripeRecurringChangeMode.TERMS;

        Assert.areEqual(
            StripeRecurringChangeMode.END_DATE_ONLY,
            StripeRecurringScheduleStampAction.resolveFinalChangeMode(request, schedule),
            'A changed End Date with unchanged terms must remain cancellation-only.'
        );
    }

    @IsTest
    static void combinedAmountAndCadenceUsesTermsDespiteSavedSuccessorMatch() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitmentSchedule savedSuccessor = new GiftCommitmentSchedule(
            TransactionAmount = 1008,
            TransactionPeriod = 'Daily',
            TransactionInterval = 1,
            StartDate = Date.today().addDays(1),
            EndDate = Date.today().addDays(42)
        );
        StripeRecurringScheduleStampAction.Request request =
            new StripeRecurringScheduleStampAction.Request();
        request.amount = 1008;
        request.transactionPeriod = 'Daily';
        request.transactionInterval = 1;
        request.originalAmount = 12;
        request.originalPeriod = 'Weekly';
        request.originalInterval = 1;
        request.previousEndDate = null;
        request.requestedEndDate = savedSuccessor.EndDate;
        request.requestedStartDate = savedSuccessor.StartDate;
        request.changeMode = StripeRecurringChangeMode.TERMS;

        Assert.areEqual(
            StripeRecurringChangeMode.TERMS,
            StripeRecurringScheduleStampAction.resolveFinalChangeMode(request, savedSuccessor),
            'Changing amount and cadence must not become cancellation-only after Salesforce saves the successor.'
        );
    }

    @IsTest
    static void guidedServiceRejectsEndDateOnlyHintWhenBillingTermsChanged() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [
            SELECT Id FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1
        ];
        GiftCommitmentSchedule schedule = [
            SELECT Id, StartDate FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1
        ];
        StripeRecurringScheduleChangeService.GuidedOverride proposed =
            new StripeRecurringScheduleChangeService.GuidedOverride();
        proposed.targetScheduleId = schedule.Id;
        proposed.amount = 30;
        proposed.period = 'Monthly';
        proposed.intervalCount = 1;
        proposed.transactionDay = '15';
        proposed.recurringType = 'Open';
        proposed.configurationStartDate = schedule.StartDate;
        proposed.firstPaymentDate = schedule.StartDate;
        proposed.originalAmount = 20;
        proposed.originalPeriod = 'Weekly';
        proposed.originalInterval = 1;
        proposed.endDateOnlyTransition = true;
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;

        Test.startTest();
        Id requestId = StripeRecurringScheduleChangeService.createGuidedRequestForGiftCommitment(
            commitment.Id, StripeRecurringChangeMode.END_DATE_ONLY, proposed
        );
        Test.stopTest();

        Assert.isNotNull(requestId, 'The changed billing terms should produce a durable request.');
        Stripe_Subscription_Change__c change = [
            SELECT Requested_Change_Mode__c FROM Stripe_Subscription_Change__c WHERE Id = :requestId
        ];
        Assert.areEqual(StripeRecurringChangeMode.TERMS, change.Requested_Change_Mode__c,
            'A cancellation-only hint must not override the original amount and cadence.');
    }

    @IsTest
    static void guidedTemporaryTermsCapturePersistsOriginalAndRestorationSnapshot() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [
            SELECT Id, Price_Id__c FROM GiftCommitment
            WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1
        ];
        GiftCommitmentSchedule targetSchedule = [
            SELECT Id, StartDate, TransactionAmount, TransactionPeriod, TransactionInterval
            FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1
        ];
        Date effectiveStart = Date.today().addDays(7);
        Date effectiveEnd = effectiveStart.addDays(14);
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        update new GiftCommitmentSchedule(
            Id = targetSchedule.Id,
            Stripe_Change_Effective_Date__c = effectiveStart
        );
        Date restorationFirstPaymentDate = effectiveEnd.addDays(1);

        StripeRecurringScheduleChangeService.GuidedOverride guidedOverride =
            new StripeRecurringScheduleChangeService.GuidedOverride();
        guidedOverride.targetScheduleId = targetSchedule.Id;
        guidedOverride.amount = 25;
        guidedOverride.period = 'Weekly';
        guidedOverride.intervalCount = 1;
        guidedOverride.recurringType = 'Open';
        guidedOverride.configurationStartDate = effectiveStart;
        guidedOverride.firstPaymentDate = effectiveStart;
        guidedOverride.effectiveEndDate = effectiveEnd;
        guidedOverride.originalAmount = 20;
        guidedOverride.originalPeriod = 'Weekly';
        guidedOverride.originalInterval = 1;
        guidedOverride.originalPriceId = 'price_service_old';
        guidedOverride.restorationScheduleId = targetSchedule.Id;
        guidedOverride.restorationFirstPaymentDate = restorationFirstPaymentDate;
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;

        Test.startTest();
        Id requestId = StripeRecurringScheduleChangeService.createGuidedRequestForGiftCommitment(
            commitment.Id,
            'TemporaryTerms',
            guidedOverride
        );
        Test.stopTest();
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = false;

        Stripe_Subscription_Change__c requestRecord = [
            SELECT Gift_Commitment_Schedule__c, Requested_Change_Mode__c,
                   Requested_Effective_Date__c, Temporary_Window_End_Date__c,
                   Original_Amount__c, Original_Period__c, Original_Interval__c,
                   Original_Stripe_Price_Id__c, Restoration_Schedule__c,
                   Restoration_First_Payment_Date__c, Status__c
            FROM Stripe_Subscription_Change__c WHERE Id = :requestId
        ];
        Assert.areEqual(targetSchedule.Id, requestRecord.Gift_Commitment_Schedule__c);
        Assert.areEqual('TemporaryTerms', requestRecord.Requested_Change_Mode__c);
        Assert.areEqual(effectiveStart, requestRecord.Requested_Effective_Date__c);
        Assert.areEqual(effectiveEnd, requestRecord.Temporary_Window_End_Date__c);
        Assert.areEqual(20, requestRecord.Original_Amount__c);
        Assert.areEqual('Weekly', requestRecord.Original_Period__c);
        Assert.areEqual(1, requestRecord.Original_Interval__c);
        Assert.areEqual('price_service_old', requestRecord.Original_Stripe_Price_Id__c);
        Assert.areEqual(targetSchedule.Id, requestRecord.Restoration_Schedule__c);
        Assert.areEqual(restorationFirstPaymentDate,
            requestRecord.Restoration_First_Payment_Date__c);
        Assert.areEqual('Pending', requestRecord.Status__c);
    }

    @IsTest
    static void repeatedPendingChangeSupersedesTheEarlierRequest() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [SELECT Id FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1];
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });
        GiftCommitmentSchedule schedule = [SELECT Id, TransactionAmount FROM GiftCommitmentSchedule WHERE GiftCommitmentId = :commitment.Id LIMIT 1];
        GiftTransaction oldUnpaid = [SELECT Id, DonorId, GiftCommitmentId, GiftCommitmentScheduleId, Status, OriginalAmount, TransactionDueDate, PaymentMethod, Name FROM GiftTransaction WHERE GiftCommitmentId = :commitment.Id LIMIT 1];
        delete oldUnpaid;
        schedule.TransactionAmount = 30;
        update schedule;
        oldUnpaid.Id = null;
        oldUnpaid.OriginalAmount = 30;
        insert oldUnpaid;

        Test.startTest();
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });
        Test.stopTest();

        List<Stripe_Subscription_Change__c> requests = [
            SELECT Status__c, Requested_Amount__c
            FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c = :commitment.Id
            ORDER BY CreatedDate
        ];
        Assert.areEqual(2, requests.size());
        Assert.areEqual('Superseded', requests[0].Status__c);
        Assert.areEqual('Pending', requests[1].Status__c);
        Assert.areEqual(30, requests[1].Requested_Amount__c);
    }

    @IsTest
    static void doesNotCreateRequestWithoutExistingStripeSubscription() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [SELECT Id, Subscription_Id__c FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1];
        commitment.Subscription_Id__c = null;
        update commitment;
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;

        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });

        Assert.areEqual(0, [SELECT COUNT() FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c = :commitment.Id]);
    }

    @IsTest
    static void nonStripeScheduleNeverCreatesDurableStripeRequest() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [
            SELECT Id, Payment_Processor__c, Payment_type__c
            FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1
        ];
        commitment.Payment_Processor__c = 'GoCardless';
        commitment.Payment_type__c = null;
        update commitment;
        GiftCommitmentSchedule schedule = [
            SELECT Id, PaymentMethod FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1
        ];
        delete [
            SELECT Id FROM GiftTransaction
            WHERE GiftCommitmentId = :commitment.Id
        ];
        schedule.PaymentMethod = 'Cash';
        update schedule;
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;

        Test.startTest();
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });
        Test.stopTest();

        Assert.areEqual(0, [
            SELECT COUNT() FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c = :commitment.Id
        ], 'A non-Stripe schedule must remain Salesforce-only.');
    }

    @IsTest
    static void parentOpenTypeOverridesConflictingScheduleEndDate() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [
            SELECT Id FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1
        ];
        GiftCommitmentSchedule schedule = [
            SELECT Id, EndDate FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1
        ];
        schedule.EndDate = Date.today().addMonths(6);
        update schedule;
        // The parent is the source of truth. Reassert it after schedule-only
        // automation so this test cannot be affected by managed-package date logic.
        update new GiftCommitment(Id = commitment.Id, Recurring_Type__c = 'Open');
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;

        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });

        Stripe_Subscription_Change__c change = [
            SELECT Requested_Recurring_Type__c, Requested_Final_Payment_Date__c
            FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c = :commitment.Id LIMIT 1
        ];
        Assert.areEqual('Open', change.Requested_Recurring_Type__c,
            'Only GiftCommitment.Recurring_Type__c may determine Open or Fixed.');
        Assert.isNull(change.Requested_Final_Payment_Date__c,
            'Open changes must not retain a fixed final-payment date.');
    }

    @IsTest
    static void stampActionCreatesDurableRequestAfterFinalScheduleState() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [
            SELECT Id FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1
        ];
        GiftCommitmentSchedule schedule = [
            SELECT Id, StartDate, TransactionAmount, TransactionPeriod, TransactionInterval
            FROM GiftCommitmentSchedule WHERE GiftCommitmentId = :commitment.Id LIMIT 1
        ];
        update new GiftCommitment(Id = commitment.Id, Recurring_Type__c = 'Fixed');
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;

        StripeRecurringScheduleStampAction.Request request = new StripeRecurringScheduleStampAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = schedule.TransactionAmount;
        request.transactionPeriod = schedule.TransactionPeriod;
        request.transactionInterval = schedule.TransactionInterval == null
            ? 1 : Integer.valueOf(schedule.TransactionInterval);
        request.effectiveDate = schedule.StartDate;
        request.firstPaymentDate = schedule.StartDate;
        request.finalPaymentDate = schedule.StartDate.addDays(14);
        request.recurringType = 'Fixed';
        request.plannedInstallments = 3;
        request.originalAmount = schedule.TransactionAmount;
        request.originalPeriod = schedule.TransactionPeriod;
        request.originalInterval = request.transactionInterval;
        request.originalStartDate = schedule.StartDate;
        request.previousEndDate = null;
        request.requestedEndDate = request.finalPaymentDate;
        request.createRequestAfterSave = true;

        Test.startTest();
        List<StripeRecurringScheduleStampAction.Response> responses =
            StripeRecurringScheduleStampAction.execute(
                new List<StripeRecurringScheduleStampAction.Request>{ request }
            );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        Assert.isTrue(responses[0].isSuccess,
            'success=' + String.valueOf(responses[0].isSuccess) +
            ', errorType=' + String.valueOf(responses[0].errorType) +
            ', error=' + String.valueOf(responses[0].errorMessage));
        Assert.isNotNull(responses[0].requestId);
        Stripe_Subscription_Change__c change = [
            SELECT Requested_Recurring_Type__c, Requested_Installments__c,
                   Requested_Final_Payment_Date__c
            FROM Stripe_Subscription_Change__c WHERE Id = :responses[0].requestId
        ];
        Assert.areEqual('Fixed', change.Requested_Recurring_Type__c);
        Assert.areEqual(3, change.Requested_Installments__c);
        Assert.areEqual(schedule.StartDate.addDays(14), change.Requested_Final_Payment_Date__c);
    }

    @IsTest
    static void stampActionReturnsErrorWhenManagedScheduleCannotBeMatched() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [
            SELECT Id FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1
        ];
        StripeRecurringScheduleStampAction.Request request = new StripeRecurringScheduleStampAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.amount = 999;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 1;
        request.effectiveDate = Date.today().addDays(2);
        request.firstPaymentDate = request.effectiveDate;
        request.recurringType = 'Open';

        List<StripeRecurringScheduleStampAction.Response> responses =
            StripeRecurringScheduleStampAction.execute(
                new List<StripeRecurringScheduleStampAction.Request>{ request }
            );

        Assert.areEqual(1, responses.size());
        Assert.isFalse(responses[0].isSuccess);
        Assert.areEqual('SCHEDULE_NOT_FOUND', responses[0].errorType);
    }

    @IsTest
    static void stampActionCapturesOneTemporaryWindowWithVerifiedRestoration() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_temporary_stamp', 'Open'
        );
        commitment.Price_Id__c = 'price_original_monthly';
        update commitment;
        Date effectiveStart = Date.today().addDays(7);
        Date effectiveEnd = effectiveStart.addDays(14);
        GiftCommitmentSchedule originalSchedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 5, 'Monthly', 1, Date.today().addMonths(-3),
            Date.today().addMonths(-3), null
        );
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        originalSchedule.EndDate = effectiveStart.addDays(-1);
        update originalSchedule;
        GiftCommitmentSchedule temporarySchedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 25, 'Weekly', 1, effectiveStart, effectiveStart, 3
        );
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        temporarySchedule.EndDate = effectiveEnd;
        update temporarySchedule;
        GiftCommitmentSchedule restorationSchedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 5, 'Monthly', 1, effectiveEnd.addDays(1),
            effectiveEnd.addDays(1), null
        );

        StripeRecurringScheduleStampAction.Request request =
            new StripeRecurringScheduleStampAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.selectedScheduleId = originalSchedule.Id;
        request.amount = 25;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 1;
        request.effectiveDate = effectiveStart;
        request.effectiveEndDate = effectiveEnd;
        request.firstPaymentDate = effectiveStart;
        request.temporaryInstallments = 3;
        request.requestedStartDate = originalSchedule.StartDate;
        request.requestedEndDate = originalSchedule.EndDate;
        request.recurringType = 'Open';
        request.changeMode = StripeRecurringChangeMode.TEMPORARY_TERMS;
        request.originalAmount = 5;
        request.originalPeriod = 'Monthly';
        request.originalInterval = 1;
        request.originalPriceId = 'price_original_monthly';
        request.restorationFirstPaymentDate = effectiveEnd.addDays(1);
        request.createRequestAfterSave = true;

        StripeRecurringScheduleStampAction.Response response =
            StripeRecurringScheduleStampAction.execute(
                new List<StripeRecurringScheduleStampAction.Request>{ request }
            )[0];

        Assert.isTrue(response.isSuccess,
            response.errorMessage == null ? 'Temporary window stamp should succeed.' : response.errorMessage);
        Assert.areEqual(temporarySchedule.Id, response.scheduleId);
        Stripe_Subscription_Change__c change = [
            SELECT Requested_Change_Mode__c, Temporary_Window_End_Date__c,
                   Original_Amount__c, Original_Period__c, Original_Interval__c,
                   Original_Stripe_Price_Id__c, Restoration_Schedule__c,
                   Restoration_First_Payment_Date__c
            FROM Stripe_Subscription_Change__c
            WHERE Id = :response.requestId
        ];
        Assert.areEqual('TemporaryTerms', change.Requested_Change_Mode__c);
        Assert.areEqual(effectiveEnd, change.Temporary_Window_End_Date__c);
        Assert.areEqual(5, change.Original_Amount__c);
        Assert.areEqual('Monthly', change.Original_Period__c);
        Assert.areEqual(1, change.Original_Interval__c);
        Assert.areEqual('price_original_monthly', change.Original_Stripe_Price_Id__c);
        Assert.areEqual(restorationSchedule.Id, change.Restoration_Schedule__c);
        Assert.areEqual(effectiveEnd.addDays(1), change.Restoration_First_Payment_Date__c);
    }

    @IsTest
    static void stampActionDerivesFixedCountWhenFlowOmitsIt() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [
            SELECT Id FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1
        ];
        GiftCommitmentSchedule schedule = [
            SELECT Id, StartDate, TransactionAmount, TransactionPeriod, TransactionInterval
            FROM GiftCommitmentSchedule WHERE GiftCommitmentId = :commitment.Id LIMIT 1
        ];
        StripeRecurringScheduleStampAction.Request request =
            new StripeRecurringScheduleStampAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.selectedScheduleId = schedule.Id;
        request.amount = schedule.TransactionAmount;
        request.transactionPeriod = schedule.TransactionPeriod;
        request.transactionInterval = Integer.valueOf(schedule.TransactionInterval);
        request.effectiveDate = Date.today();
        request.firstPaymentDate = schedule.StartDate;
        request.finalPaymentDate = schedule.StartDate.addDays(14);
        request.requestedStartDate = schedule.StartDate;
        request.requestedEndDate = schedule.StartDate.addDays(14);
        request.recurringType = 'Fixed';
        request.changeMode = StripeRecurringChangeMode.TERMS;
        request.createRequestAfterSave = false;
        // The guided Flow normally supplies this value; this verifies the
        // server-side fallback used by older callers and retries.
        request.plannedInstallments = null;

        Test.startTest();
        List<StripeRecurringScheduleStampAction.Response> responses =
            StripeRecurringScheduleStampAction.execute(
                new List<StripeRecurringScheduleStampAction.Request>{ request }
            );
        Test.stopTest();

        Assert.isTrue(responses[0].isSuccess,
            responses[0].errorMessage == null ? '' : responses[0].errorMessage);
        GiftCommitmentSchedule updated = [
            SELECT EndDate, Number_of_Planned_Installments__c
            FROM GiftCommitmentSchedule WHERE Id = :schedule.Id
        ];
        Assert.areEqual(schedule.StartDate.addDays(14), updated.EndDate);
        Assert.areEqual(3, updated.Number_of_Planned_Installments__c);
    }

    @IsTest
    static void firstAndFinalPaymentDatesArePartOfTheIdempotencyKey() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [
            SELECT Id FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1
        ];
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        update new GiftCommitment(Id = commitment.Id, Recurring_Type__c = 'Fixed');
        GiftCommitmentSchedule schedule = [
            SELECT Id, StartDate FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1
        ];
        schedule.EndDate = schedule.StartDate.addDays(14);
        update schedule;
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });
        String firstKey = [
            SELECT Idempotency_Key__c FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c = :commitment.Id LIMIT 1
        ].Idempotency_Key__c;

        schedule.EndDate = schedule.StartDate.addDays(21);
        update schedule;
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = false;

        List<Stripe_Subscription_Change__c> requests = [
            SELECT Idempotency_Key__c, Status__c FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c = :commitment.Id ORDER BY CreatedDate
        ];
        Assert.areEqual(2, requests.size());
        Assert.areNotEqual(firstKey, requests[1].Idempotency_Key__c,
            'A different final payment date must produce a different durable request key.');
        Assert.areEqual('Superseded', requests[0].Status__c);
    }

    @IsTest
    static void mismatchedScheduleAndNextUnpaidDateRemainsOpen() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [SELECT Id, Stripe_Schedule_Sync_Status__c FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1];
        GiftCommitmentSchedule schedule = [SELECT Id, StartDate FROM GiftCommitmentSchedule WHERE GiftCommitmentId = :commitment.Id LIMIT 1];
        GiftTransaction oldUnpaid = [SELECT Id, DonorId, GiftCommitmentId, GiftCommitmentScheduleId, Status, OriginalAmount, TransactionDueDate, PaymentMethod, Name FROM GiftTransaction WHERE GiftCommitmentId = :commitment.Id LIMIT 1];
        delete oldUnpaid;
        schedule.StartDate = Date.today();
        update schedule;
        oldUnpaid.Id = null;
        insert oldUnpaid;
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;

        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });

        GiftTransaction regeneratedUnpaid = [
            SELECT TransactionDueDate
            FROM GiftTransaction
            WHERE GiftCommitmentId = :commitment.Id AND Status IN ('Pledged', 'Unpaid')
            ORDER BY TransactionDueDate
            LIMIT 1
        ];
        Stripe_Subscription_Change__c request = [SELECT Status__c, Last_Error__c, Requested_First_Payment_Date__c FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c = :commitment.Id LIMIT 1];
        Assert.areEqual('Pending', request.Status__c, 'A schedule mismatch must not fail closed.');
        Assert.isNull(request.Last_Error__c, 'Stripe preview/apply decides whether the change can proceed.');
        Assert.areEqual(regeneratedUnpaid.TransactionDueDate, request.Requested_First_Payment_Date__c,
            'The durable request must preserve the earliest actual unpaid Gift Transaction date.');
        GiftCommitment updated = [SELECT Stripe_Schedule_Sync_Status__c FROM GiftCommitment WHERE Id = :commitment.Id];
        Assert.areEqual('Pending', updated.Stripe_Schedule_Sync_Status__c);
    }

    @IsTest
    static void queueableMarksRequestAndParentScheduledAfterStripeFuturePhaseSucceeds() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [SELECT Id FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1];
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });
        Stripe_Subscription_Change__c requestRecord = [SELECT Id, Requested_Effective_Date__c FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c = :commitment.Id LIMIT 1];
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(HttpCalloutMock.class, new SuccessfulStripeMock(requestRecord.Requested_Effective_Date__c, requestRecord.Id));

        Test.startTest();
        System.enqueueJob(new StripeRecurringScheduleSyncQueueable(new List<Id>{ requestRecord.Id, requestRecord.Id }));
        Test.stopTest();

        requestRecord = [SELECT Status__c, Attempt_Count__c, Stripe_Schedule_Id__c, Stripe_Price_Id__c, Synced_At__c FROM Stripe_Subscription_Change__c WHERE Id = :requestRecord.Id];
        Assert.areEqual('Scheduled', requestRecord.Status__c);
        Assert.areEqual(1, requestRecord.Attempt_Count__c);
        Assert.areEqual('sub_sched_service_1', requestRecord.Stripe_Schedule_Id__c);
        Assert.areEqual('price_service_old', requestRecord.Stripe_Price_Id__c,
            'A schedule-only change must retain the subscription\'s current Price.');
        Assert.isNull(requestRecord.Synced_At__c);
        GiftCommitment updated = [SELECT Stripe_Schedule_Sync_Status__c, Stripe_Schedule_Synced_At__c FROM GiftCommitment WHERE Id = :commitment.Id];
        Assert.areEqual('Scheduled', updated.Stripe_Schedule_Sync_Status__c);
        Assert.isNull(updated.Stripe_Schedule_Synced_At__c);
    }

    @IsTest
    static void exhaustedAttemptsFailTheRequestAndRaiseAFailureLog() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [SELECT Id FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1];
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });
        Stripe_Subscription_Change__c requestRecord = [SELECT Id FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c = :commitment.Id LIMIT 1];
        update new Stripe_Subscription_Change__c(Id = requestRecord.Id, Attempt_Count__c = 99);

        Test.startTest();
        StripeRecurringScheduleChangeService.processRequest(requestRecord.Id);
        Test.stopTest();

        Assert.areEqual('Failed', [SELECT Status__c FROM Stripe_Subscription_Change__c WHERE Id = :requestRecord.Id].Status__c,
            'Exhausted retries should fail the request');
        Stripe_Failure_Log__c log = [
            SELECT Reason_Code__c, Failure_Source__c, Gift_Commitment__c, Stripe_Subscription_Change__c, Error_Message__c
            FROM Stripe_Failure_Log__c
        ];
        Assert.areEqual('RECURRING_SYNC_FAILED', log.Reason_Code__c, 'A failed sync should raise a failure log');
        Assert.areEqual('Recurring Sync', log.Failure_Source__c, 'Recurring sync is the source');
        Assert.areEqual(commitment.Id, log.Gift_Commitment__c, 'The log should link the recurring donation');
        Assert.areEqual(requestRecord.Id, log.Stripe_Subscription_Change__c, 'The log should link the change request');
        Assert.isTrue(log.Error_Message__c.contains('Maximum Stripe synchronization attempts'), log.Error_Message__c);
    }

    @IsTest
    static void processingAllowsConfiguredLiveCredential() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [SELECT Id FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1];
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });
        Stripe_Subscription_Change__c requestRecord = [SELECT Id, Requested_Effective_Date__c FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c = :commitment.Id LIMIT 1];
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(HttpCalloutMock.class, new SuccessfulStripeMock(requestRecord.Requested_Effective_Date__c, requestRecord.Id));

        Test.startTest();
        StripeRecurringScheduleChangeService.processRequest(requestRecord.Id);
        Test.stopTest();

        requestRecord = [SELECT Status__c, Attempt_Count__c, Last_Error__c FROM Stripe_Subscription_Change__c WHERE Id = :requestRecord.Id];
        Assert.areEqual('Scheduled', requestRecord.Status__c);
        Assert.areEqual(1, requestRecord.Attempt_Count__c);
        Assert.isNull(requestRecord.Last_Error__c,
            'A configured credential must not be rejected because of its Stripe mode.');
    }

    @IsTest
    static void finalizerProcessesPendingRequestWithoutQueueChaining() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [SELECT Id FROM GiftCommitment WHERE Subscription_Id__c = 'sub_service_1' LIMIT 1];
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(new Set<Id>{ commitment.Id });
        Stripe_Subscription_Change__c requestRecord = [
            SELECT Id, Requested_Effective_Date__c
            FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c = :commitment.Id
            LIMIT 1
        ];
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(HttpCalloutMock.class, new SuccessfulStripeMock(requestRecord.Requested_Effective_Date__c, requestRecord.Id));

        Test.startTest();
        new StripeRecurringScheduleFinalizer(new Set<Id>{ commitment.Id }).execute(null);
        Test.stopTest();

        requestRecord = [SELECT Status__c FROM Stripe_Subscription_Change__c WHERE Id = :requestRecord.Id];
        Assert.areEqual('Scheduled', requestRecord.Status__c);
    }

    @IsTest
    static void fixedToOpenCreatesNewRequestAfterEarlierOpenWasSuperseded() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        OpenFixedFixture fixture = createOpenFixedFixture();

        fixture.commitment.Recurring_Type__c = 'Open';
        update fixture.commitment;
        fixture.schedule.Number_of_Planned_Installments__c = null;
        fixture.schedule.EndDate = null;
        update fixture.schedule;
        update new GiftCommitment(Id = fixture.commitment.Id, Recurring_Type__c = 'Open');

        Test.startTest();
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(
            new Set<Id>{ fixture.commitment.Id }
        );
        Test.stopTest();

        List<Stripe_Subscription_Change__c> requests = selectRequestsNewestFirst(
            fixture.commitment.Id
        );
        Assert.areEqual(3, requests.size(),
            'Returning from Fixed to Open must create a third durable revision.');
        Assert.areEqual('Pending', requests[0].Status__c,
            'The newest Open revision must remain actionable.');
        Assert.areEqual('Open', requests[0].Requested_Recurring_Type__c,
            'The newest revision must use the parent Open recurring type.');
        Assert.isNull(requests[0].Requested_Installments__c,
            'An Open revision must not retain Fixed installments.');
        Assert.isNull(requests[0].Requested_Final_Payment_Date__c,
            'An Open revision must not retain a Fixed final payment date.');
        Assert.areEqual('Superseded', requests[1].Status__c,
            'The immediately preceding Fixed request must be superseded.');
        Assert.areEqual('Synced', requests[2].Status__c,
            'The original Open request must remain historical and unchanged.');
        Assert.areNotEqual(requests[2].Idempotency_Key__c, requests[0].Idempotency_Key__c,
            'The new Open revision must not reuse the original superseded request key.');
    }

    @IsTest
    static void repeatedCaptureReusesNewestOpenRevision() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        OpenFixedFixture fixture = createOpenFixedFixture();
        fixture.commitment.Recurring_Type__c = 'Open';
        update fixture.commitment;
        fixture.schedule.Number_of_Planned_Installments__c = null;
        fixture.schedule.EndDate = null;
        update fixture.schedule;
        update new GiftCommitment(Id = fixture.commitment.Id, Recurring_Type__c = 'Open');
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(
            new Set<Id>{ fixture.commitment.Id }
        );
        Stripe_Subscription_Change__c firstOpenRevision = selectRequestsNewestFirst(
            fixture.commitment.Id
        )[0];

        Test.startTest();
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(
            new Set<Id>{ fixture.commitment.Id }
        );
        Test.stopTest();

        List<Stripe_Subscription_Change__c> requests = selectRequestsNewestFirst(
            fixture.commitment.Id
        );
        Assert.areEqual(3, requests.size(),
            'Recapturing the unchanged latest Open edit must not create a fourth request.');
        Assert.areEqual(firstOpenRevision.Id, requests[0].Id,
            'Duplicate capture must reuse the newest Open revision.');
        Assert.areEqual('Pending', requests[0].Status__c,
            'Duplicate capture must leave the newest request actionable.');
    }

    private static OpenFixedFixture createOpenFixedFixture() {
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        OpenFixedFixture fixture = new OpenFixedFixture();
        fixture.commitment = [
            SELECT Id, Recurring_Type__c
            FROM GiftCommitment
            WHERE Subscription_Id__c = 'sub_service_1'
            LIMIT 1
        ];
        fixture.schedule = [
            SELECT Id, TransactionAmount, TransactionPeriod, TransactionInterval,
                   StartDate, Stripe_Change_Effective_Date__c,
                   Number_of_Planned_Installments__c, Final_Payment_Date__c, EndDate
            FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :fixture.commitment.Id
            LIMIT 1
        ];
        delete [
            SELECT Id
            FROM GiftTransaction
            WHERE GiftCommitmentId = :fixture.commitment.Id
        ];
        Date firstPaymentDate = Date.today().addDays(5);
        fixture.schedule.TransactionAmount = 22;
        fixture.schedule.TransactionPeriod = 'Yearly';
        fixture.schedule.TransactionInterval = 1;
        fixture.schedule.StartDate = firstPaymentDate;
        fixture.schedule.Stripe_Change_Effective_Date__c = firstPaymentDate;
        fixture.schedule.Number_of_Planned_Installments__c = null;
        fixture.schedule.EndDate = null;
        update fixture.schedule;

        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(
            new Set<Id>{ fixture.commitment.Id }
        );
        Stripe_Subscription_Change__c openRequest = selectRequestsNewestFirst(
            fixture.commitment.Id
        )[0];
        // Model the existing Open configuration as already active.  The
        // subsequent Fixed and Open edits must remain separate revisions.
        openRequest.Status__c = 'Synced';
        update openRequest;

        fixture.schedule.EndDate = firstPaymentDate.addYears(2);
        fixture.schedule.Number_of_Planned_Installments__c = null;
        update fixture.schedule;
        update new GiftCommitment(Id = fixture.commitment.Id, Recurring_Type__c = 'Fixed');
        StripeRecurringScheduleChangeService.createRequestsForGiftCommitments(
            new Set<Id>{ fixture.commitment.Id }
        );
        Stripe_Subscription_Change__c fixedRequest = selectRequestsNewestFirst(
            fixture.commitment.Id
        )[0];
        Assert.areEqual('Fixed', fixedRequest.Requested_Recurring_Type__c,
            'The fixture must create the intermediate Fixed request.');
        Assert.areEqual(3, fixedRequest.Requested_Installments__c,
            'The intermediate Fixed request must retain three installments.');
        Assert.areEqual(firstPaymentDate.addYears(2), fixedRequest.Requested_Final_Payment_Date__c,
            'The intermediate Fixed request must retain the required final payment date.');
        fixedRequest.Status__c = 'Scheduled';
        update fixedRequest;
        return fixture;
    }

    private static List<Stripe_Subscription_Change__c> selectRequestsNewestFirst(Id commitmentId) {
        return [
            SELECT Id, Status__c, Idempotency_Key__c, Requested_Recurring_Type__c,
                   Requested_Installments__c, Requested_Final_Payment_Date__c
            FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c = :commitmentId
            ORDER BY CreatedDate DESC, Id DESC
        ];
    }

    private class OpenFixedFixture {
        GiftCommitment commitment;
        GiftCommitmentSchedule schedule;
    }
}