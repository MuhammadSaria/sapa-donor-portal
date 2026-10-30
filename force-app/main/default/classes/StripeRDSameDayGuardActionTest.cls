@IsTest
private class StripeRDSameDayGuardActionTest {
    @IsTest
    static void allowsAmountAndCadenceAfterPaymentToday() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_same_day_final_guard', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, Date.today(), Date.today(), null
        );
        insert new GiftTransaction(
            Name = 'Paid today for final guard',
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid',
            OriginalAmount = 30,
            TransactionDate = Date.today(),
            TransactionDueDate = Date.today(),
            PaymentMethod = 'Credit Card'
        );

        StripeRDSameDayGuardAction.Request request =
            new StripeRDSameDayGuardAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.selectedScheduleId = schedule.Id;
        request.effectiveDate = Date.today();
        request.paymentMethod = 'Credit Card';
        request.proposedStartDate = schedule.StartDate;
        request.proposedEndDate = schedule.EndDate;
        request.amount = 35;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 1;
        request.recurringType = 'Open';

        List<StripeRDSameDayGuardAction.Response> responses =
            StripeRDSameDayGuardAction.execute(
                new List<StripeRDSameDayGuardAction.Request>{ request }
            );

        Assert.isTrue(responses[0].isAllowed);
        Assert.isFalse(responses[0].sameDayMutationRequired,
            'Amount/cadence changes must use a future managed schedule boundary, not mutate the paid schedule.');
        Assert.areEqual('Terms', responses[0].changeMode);
        Assert.areEqual(Date.today().addDays(7), responses[0].firstPaymentDate,
            'Weekly cadence must start one requested interval after the latest paid transaction.');
        Assert.areEqual(Date.today().addDays(1), responses[0].managedEffectiveFromDate,
            'The native managed action boundary must be strictly after the latest paid transaction.');
        Assert.areEqual(Date.today().addDays(7), responses[0].stripeEffectiveDate);
    }

    @IsTest
    static void amountOnlyKeepsEarliestFutureUnpaidDate() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_same_day_amount_boundary', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 5, 'Monthly', 1, Date.today().addMonths(-2), Date.today().addMonths(-2), null
        );
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        schedule.TransactionDay = '15';
        update schedule;
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = false;
        insert new List<GiftTransaction>{
            new GiftTransaction(
                Name = 'Historical paid amount', DonorId = commitment.DonorId,
                GiftCommitmentId = commitment.Id, GiftCommitmentScheduleId = schedule.Id,
                Status = 'Paid', OriginalAmount = 5, TransactionDate = Date.today(),
                TransactionDueDate = Date.today(), PaymentMethod = 'Credit Card'
            ),
            new GiftTransaction(
                Name = 'Existing future amount', DonorId = commitment.DonorId,
                GiftCommitmentId = commitment.Id, GiftCommitmentScheduleId = schedule.Id,
                Status = 'Pledged', OriginalAmount = 5,
                TransactionDueDate = Date.today().addDays(19), PaymentMethod = 'Credit Card'
            )
        };

        StripeRDSameDayGuardAction.Request request = new StripeRDSameDayGuardAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.selectedScheduleId = schedule.Id;
        request.effectiveDate = Date.today();
        request.paymentMethod = 'Credit Card';
        request.proposedStartDate = schedule.StartDate;
        request.proposedEndDate = schedule.EndDate;
        request.amount = 50;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.transactionDay = '15';
        request.recurringType = 'Open';

        StripeRDSameDayGuardAction.Response response =
            StripeRDSameDayGuardAction.execute(
                new List<StripeRDSameDayGuardAction.Request>{ request }
            )[0];

        Assert.isTrue(response.isAllowed);
        Assert.areEqual(Date.today().addDays(19), response.firstPaymentDate);
        Assert.areEqual(Date.today().addDays(19), response.managedEffectiveFromDate);
        Assert.areEqual(Date.today(), response.stripeEffectiveDate,
            'Amount-only Stripe updates apply now while retaining the next renewal date.');
    }

    @IsTest
    static void resolvesScheduleThatOwnsCalculatedCadenceBoundary() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_schedule_owner_boundary', 'Open'
        );
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        GiftCommitmentSchedule owningSchedule = new GiftCommitmentSchedule(
            GiftCommitmentId = commitment.Id,
            TransactionAmount = 5,
            TransactionPeriod = 'Monthly',
            TransactionInterval = 1,
            StartDate = Date.today().addDays(-1),
            EndDate = Date.today().addDays(28),
            PaymentMethod = 'Credit Card'
        );
        insert owningSchedule;
        GiftCommitmentSchedule futureSelectedSchedule = new GiftCommitmentSchedule(
            GiftCommitmentId = commitment.Id,
            TransactionAmount = 10,
            TransactionPeriod = 'Monthly',
            TransactionInterval = 1,
            StartDate = Date.today().addDays(29),
            EndDate = Date.today().addDays(90),
            PaymentMethod = 'Credit Card'
        );
        insert futureSelectedSchedule;
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = false;
        insert new GiftTransaction(
            Name = 'Latest paid before future selected schedule',
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = owningSchedule.Id,
            Status = 'Paid',
            OriginalAmount = 5,
            TransactionDate = Date.today().addDays(-1),
            TransactionDueDate = Date.today().addDays(-1),
            PaymentMethod = 'Credit Card'
        );

        StripeRDSameDayGuardAction.Request request = new StripeRDSameDayGuardAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.selectedScheduleId = futureSelectedSchedule.Id;
        request.effectiveDate = Date.today();
        request.paymentMethod = 'Credit Card';
        request.proposedStartDate = futureSelectedSchedule.StartDate;
        request.proposedEndDate = futureSelectedSchedule.EndDate;
        request.amount = 15;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 1;
        request.recurringType = 'Open';

        Test.startTest();
        StripeRDSameDayGuardAction.Response response =
            StripeRDSameDayGuardAction.execute(
                new List<StripeRDSameDayGuardAction.Request>{ request }
            )[0];
        Test.stopTest();

        Map<String, Object> responseValues = (Map<String, Object>) JSON.deserializeUntyped(
            JSON.serialize(response)
        );
        Assert.isTrue(response.isAllowed,
            'The cadence change should be allowed when a schedule owns the calculated boundary.');
        Assert.areEqual(Date.today().addDays(6), response.firstPaymentDate,
            'Weekly billing must begin one week after the latest paid date.');
        Assert.areEqual(String.valueOf(owningSchedule.Id), responseValues.get('resolvedScheduleId'),
            'The planner must return the schedule that owns the calculated Salesforce boundary.');
    }

    @IsTest
    static void blocksWhenNoScheduleOwnsCalculatedCadenceBoundary() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_missing_schedule_owner', 'Open'
        );
        GiftCommitmentSchedule futureSchedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 10, 'Monthly', 1, Date.today().addDays(29),
            Date.today().addDays(29), null
        );
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        futureSchedule.EndDate = Date.today().addDays(90);
        update futureSchedule;
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = false;
        insert new GiftTransaction(
            Name = 'Paid before any Salesforce schedule owner',
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            Status = 'Paid',
            OriginalAmount = 5,
            TransactionDate = Date.today().addDays(-1),
            TransactionDueDate = Date.today().addDays(-1),
            PaymentMethod = 'Credit Card'
        );

        StripeRDSameDayGuardAction.Request request = new StripeRDSameDayGuardAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.selectedScheduleId = futureSchedule.Id;
        request.effectiveDate = Date.today();
        request.paymentMethod = 'Credit Card';
        request.proposedStartDate = futureSchedule.StartDate;
        request.proposedEndDate = futureSchedule.EndDate;
        request.amount = 15;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 1;
        request.recurringType = 'Open';

        Test.startTest();
        StripeRDSameDayGuardAction.Response response =
            StripeRDSameDayGuardAction.execute(
                new List<StripeRDSameDayGuardAction.Request>{ request }
            )[0];
        Test.stopTest();

        Assert.isFalse(response.isAllowed,
            'The native managed action must not run when no Salesforce schedule owns the boundary.');
        Assert.areEqual('NO_SCHEDULE_OWNS_BOUNDARY', response.errorType,
            'The planner should return a business-readable ownership error.');
    }

    @IsTest
    static void blocksOnlyStartDateChangeAfterPaymentToday() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_same_day_start_date_block', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, Date.today().addDays(-30), Date.today().addDays(-30), null
        );
        insert new GiftTransaction(
            Name = 'Paid today for start date guard',
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid',
            OriginalAmount = 30,
            TransactionDate = Date.today(),
            TransactionDueDate = Date.today(),
            PaymentMethod = 'Credit Card'
        );

        StripeRDSameDayGuardAction.Request request = new StripeRDSameDayGuardAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.selectedScheduleId = schedule.Id;
        request.effectiveDate = Date.today();
        request.paymentMethod = 'Credit Card';
        request.proposedStartDate = Date.today();
        request.proposedEndDate = schedule.EndDate;
        request.amount = schedule.TransactionAmount;
        request.transactionPeriod = schedule.TransactionPeriod;
        request.transactionInterval = 1;
        request.recurringType = 'Open';

        List<StripeRDSameDayGuardAction.Response> responses =
            StripeRDSameDayGuardAction.execute(
                new List<StripeRDSameDayGuardAction.Request>{ request }
            );

        Assert.isFalse(responses[0].isAllowed);
        Assert.areEqual('StartDateChange', responses[0].changeMode);
        Assert.areEqual('FIRST_PAYMENT_TODAY', responses[0].errorType);
    }

    @IsTest
    static void allowsEndDateOnlyAfterPaymentToday() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_same_day_end_date_only', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, Date.today().addDays(-30), Date.today().addDays(-30), null
        );
        insert new GiftTransaction(
            Name = 'Paid today for end date only',
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid',
            OriginalAmount = 30,
            TransactionDate = Date.today(),
            TransactionDueDate = Date.today(),
            PaymentMethod = 'Credit Card'
        );

        StripeRDSameDayGuardAction.Request request = new StripeRDSameDayGuardAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.selectedScheduleId = schedule.Id;
        request.effectiveDate = Date.today();
        request.paymentMethod = 'Credit Card';
        request.proposedStartDate = schedule.StartDate;
        request.proposedEndDate = Date.today();
        request.proposedEndDateIsSet = true;
        request.amount = schedule.TransactionAmount;
        request.transactionPeriod = schedule.TransactionPeriod;
        request.transactionInterval = 1;
        request.recurringType = 'Fixed';

        List<StripeRDSameDayGuardAction.Response> responses =
            StripeRDSameDayGuardAction.execute(
                new List<StripeRDSameDayGuardAction.Request>{ request }
            );

        Assert.isTrue(responses[0].isAllowed);
        Assert.isTrue(responses[0].sameDayMutationRequired);
        Assert.areEqual('EndDateOnly', responses[0].changeMode);
    }

    @IsTest
    static void allowsFutureEffectiveChangeAfterPaymentToday() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_same_day_future_allowed', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, Date.today(), Date.today(), null
        );
        insert new GiftTransaction(
            Name = 'Paid today for future guard',
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid',
            OriginalAmount = 30,
            TransactionDate = Date.today(),
            TransactionDueDate = Date.today(),
            PaymentMethod = 'Credit Card'
        );

        StripeRDSameDayGuardAction.Request request =
            new StripeRDSameDayGuardAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.selectedScheduleId = schedule.Id;
        request.effectiveDate = Date.today().addDays(1);
        request.paymentMethod = 'Credit Card';

        List<StripeRDSameDayGuardAction.Response> responses =
            StripeRDSameDayGuardAction.execute(
                new List<StripeRDSameDayGuardAction.Request>{ request }
            );

        Assert.isTrue(responses[0].isAllowed);
    }

    @IsTest
    static void nonStripeChangeIsAllowedAndSkipped() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_same_day_non_stripe', 'Open'
        );
        commitment.Payment_Processor__c = 'Manual';
        commitment.Payment_type__c = 'Cash';
        update commitment;

        StripeRDSameDayGuardAction.Request request =
            new StripeRDSameDayGuardAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.effectiveDate = Date.today();
        request.paymentMethod = 'Cash';

        List<StripeRDSameDayGuardAction.Response> responses =
            StripeRDSameDayGuardAction.execute(
                new List<StripeRDSameDayGuardAction.Request>{ request }
            );

        Assert.isTrue(responses[0].isAllowed);
        Assert.isTrue(responses[0].skipped);
    }

    @IsTest
    static void monthlyDayIsPreservedWhenPaidTodayAndNoFutureTransactionExists() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_monthly_day_preserved', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 50, 'Monthly', 1, Date.today(), Date.today(), null
        );
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        schedule.TransactionDay = '1';
        update schedule;
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = false;
        insert new GiftTransaction(
            Name = 'Paid today with no future installment',
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid',
            OriginalAmount = 50,
            TransactionDate = Date.today(),
            TransactionDueDate = Date.today(),
            PaymentMethod = 'Credit Card'
        );

        for (Integer requestedDay : new List<Integer>{ 15, 16 }) {
            StripeRDSameDayGuardAction.Request request = new StripeRDSameDayGuardAction.Request();
            request.giftCommitmentId = commitment.Id;
            request.selectedScheduleId = schedule.Id;
            request.effectiveDate = Date.today();
            request.paymentMethod = 'Credit Card';
            request.proposedStartDate = schedule.StartDate;
            request.proposedEndDate = schedule.EndDate;
            request.amount = 60;
            request.transactionPeriod = 'Monthly';
            request.transactionInterval = 1;
            request.transactionDay = String.valueOf(requestedDay);
            request.recurringType = 'Open';

            StripeRDSameDayGuardAction.Response response =
                StripeRDSameDayGuardAction.execute(
                    new List<StripeRDSameDayGuardAction.Request>{ request }
                )[0];

            Assert.isTrue(response.isAllowed, 'A valid Monthly day must be allowed.');
            Assert.areEqual(String.valueOf(requestedDay), response.requestedTransactionDay,
                'The final guard must preserve the day captured by the Flow.');
            Assert.areEqual(nextMonthlyDayAfter(Date.today(), requestedDay), response.firstPaymentDate,
                'The first payment must be the selected day strictly after the latest paid transaction.');
        }
    }

    @IsTest
    static void missingMonthlyDayBlocksBeforeScheduleMutation() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_monthly_day_required', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 50, 'Monthly', 1, Date.today(), Date.today(), null
        );
        insert new GiftTransaction(
            Name = 'Paid today before missing day check',
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid',
            OriginalAmount = 50,
            TransactionDate = Date.today(),
            TransactionDueDate = Date.today(),
            PaymentMethod = 'Credit Card'
        );

        StripeRDSameDayGuardAction.Request request = new StripeRDSameDayGuardAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.selectedScheduleId = schedule.Id;
        request.effectiveDate = Date.today();
        request.paymentMethod = 'Credit Card';
        request.proposedStartDate = schedule.StartDate;
        request.amount = 60;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.recurringType = 'Open';

        StripeRDSameDayGuardAction.Response response =
            StripeRDSameDayGuardAction.execute(
                new List<StripeRDSameDayGuardAction.Request>{ request }
            )[0];

        Assert.isFalse(response.isAllowed, 'Monthly changes must not reach DML without a billing day.');
        Assert.areEqual('INVALID_TRANSACTION_DAY', response.errorType);
    }

    private static Date nextMonthlyDayAfter(Date boundary, Integer requestedDay) {
        Integer dayInMonth = Math.min(requestedDay, Date.daysInMonth(boundary.year(), boundary.month()));
        Date candidate = Date.newInstance(boundary.year(), boundary.month(), dayInMonth);
        if (candidate > boundary) return candidate;
        Date nextMonth = boundary.addMonths(1).toStartOfMonth();
        return Date.newInstance(
            nextMonth.year(),
            nextMonth.month(),
            Math.min(requestedDay, Date.daysInMonth(nextMonth.year(), nextMonth.month()))
        );
    }
}