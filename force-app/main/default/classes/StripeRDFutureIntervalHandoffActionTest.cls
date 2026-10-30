// Native Fundraising schedule actions require the org-wide default designation,
// which is setup data unavailable in isolated Apex tests.
@IsTest(SeeAllData=true)
private class StripeRDFutureIntervalHandoffActionTest {
    private class Fixture {
        Id giftId;
        Id futureScheduleId;
        Id paidId;
        Date futureStart;
        Date expectedFirst;
    }

    private static Fixture createFixture(String requestedPeriod, Integer requestedInterval) {
        return createFixture(requestedPeriod, requestedInterval, false);
    }

    private static Fixture createFixture(String requestedPeriod, Integer requestedInterval, Boolean paidToday) {
        StripePauseService.suppressSubscriptionUpdate = true;
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;
        Date today = Date.today();
        Account donor = new Account(LastName = 'Future interval staging test');
        insert donor;
        GiftCommitment gift = new GiftCommitment(
            Name = 'Future interval staging test', DonorId = donor.Id,
            Status = 'Active', Recurring_Type__c = 'Open',
            Subscription_Id__c = 'sub_test_future_interval',
            Payment_Processor__c = 'Stripe'
        );
        insert gift;
        GiftCommitmentSchedule history = new GiftCommitmentSchedule(
            GiftCommitmentId = gift.Id, Type = 'CreateTransactions',
            StartDate = paidToday ? today : today.addDays(-2),
            EndDate = paidToday ? today.addDays(6) : today.addDays(4),
            TransactionAmount = paidToday ? 70 : 5, TransactionPeriod = 'Monthly',
            TransactionInterval = 1, TransactionDay = String.valueOf((paidToday ? today : today.addDays(-2)).day()),
            PaymentMethod = 'Credit Card'
        );
        insert history;
        GiftCommitmentSchedule future = new GiftCommitmentSchedule(
            GiftCommitmentId = gift.Id, Type = 'CreateTransactions',
            StartDate = paidToday ? today.addDays(7) : today.addDays(5),
            TransactionAmount = paidToday ? 9 : 5,
            TransactionPeriod = requestedPeriod, TransactionInterval = 1,
            PaymentMethod = 'Credit Card'
        );
        insert future;
        GiftTransaction paid = new GiftTransaction(
            Name = 'Protected paid interval', DonorId = donor.Id,
            GiftCommitmentId = gift.Id, GiftCommitmentScheduleId = history.Id,
            Status = 'Paid', OriginalAmount = paidToday ? 70 : 5,
            TransactionDate = paidToday ? today : today.addDays(-2),
            TransactionDueDate = paidToday ? today : today.addDays(-2), PaymentMethod = 'Credit Card'
        );
        insert paid;
        insert new GiftTransaction(
            Name = 'Future unpaid interval', DonorId = donor.Id,
            GiftCommitmentId = gift.Id, GiftCommitmentScheduleId = future.Id,
            Status = 'Unpaid', OriginalAmount = future.TransactionAmount,
            TransactionDueDate = future.StartDate,
            PaymentMethod = 'Credit Card'
        );
        StripePauseService.suppressSubscriptionUpdate = false;
        Fixture fixture = new Fixture();
        fixture.giftId = gift.Id;
        fixture.futureScheduleId = future.Id;
        fixture.paidId = paid.Id;
        fixture.futureStart = future.StartDate;
        fixture.expectedFirst = StripeRDScheduleDateCalc.addPeriod(
            paid.TransactionDate, requestedPeriod, requestedInterval);
        return fixture;
    }

    @IsTest
    static void paidTodayWeeklyTwoUsesFutureSegmentBeyondHistoricalEnd() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        Fixture fixture = createFixture('Weekly', 2, true);
        Date expectedFirst = Date.today().addDays(14);
        StripeRDFutureIntervalHandoffAction.Request request = new StripeRDFutureIntervalHandoffAction.Request();
        request.giftCommitmentId = fixture.giftId;
        request.selectedScheduleId = fixture.futureScheduleId;
        request.amount = 9;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 2;
        request.expectedFirstPaymentDate = expectedFirst;
        Test.startTest();
        StripeRDFutureIntervalHandoffAction.Response result = StripeRDFutureIntervalHandoffAction.execute(
            new List<StripeRDFutureIntervalHandoffAction.Request>{request})[0];
        Test.stopTest();
        Assert.isTrue(result.isSuccess, result.errorMessage == null ? 'The future weekly segment must own the change.' : result.errorMessage);
        Assert.isNotNull(result.requestId, 'Exactly one durable request must be captured.');
        Assert.areEqual(expectedFirst, [SELECT NextTransactionDate FROM GiftCommitment WHERE Id = :fixture.giftId].NextTransactionDate,
            'Paid today plus two weeks must be the next payment, despite the historical segment ending sooner.');
        Assert.areEqual(1, [SELECT COUNT() FROM GiftCommitmentSchedule WHERE GiftCommitmentId = :fixture.giftId
            AND Type = 'PauseTransactions' AND StartDate = :fixture.futureStart AND EndDate = :expectedFirst.addDays(-1)],
            'The old weekly installment must become one native no-charge gap.');
        Assert.areEqual(0, [SELECT COUNT() FROM GiftTransaction WHERE GiftCommitmentId = :fixture.giftId
            AND Status IN ('Unpaid', 'Pledged') AND TransactionDueDate < :expectedFirst],
            'No old unpaid weekly payment may remain before the two-week target.');
        Assert.areEqual(70, [SELECT OriginalAmount FROM GiftTransaction WHERE Id = :fixture.paidId].OriginalAmount,
            'Today\'s paid amount must remain unchanged.');
        Assert.areEqual(1, [SELECT COUNT() FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c = :fixture.giftId],
            'The handoff must not capture duplicate requests.');
    }

    @IsTest
    static void weeklyIntervalTwoUsesFutureOwnerAndRemovesGapPayment() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        Fixture fixture = createFixture('Weekly', 2);
        StripeRDFutureIntervalHandoffAction.Request request =
            new StripeRDFutureIntervalHandoffAction.Request();
        request.giftCommitmentId = fixture.giftId;
        request.selectedScheduleId = fixture.futureScheduleId;
        request.amount = 25;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 2;
        request.expectedFirstPaymentDate = fixture.expectedFirst;
        Test.startTest();
        StripeRDFutureIntervalHandoffAction.Response result =
            StripeRDFutureIntervalHandoffAction.execute(
                new List<StripeRDFutureIntervalHandoffAction.Request>{request})[0];
        Test.stopTest();
        System.assert(result.isSuccess == true,
            result.errorMessage == null ? 'Future interval handoff failed without detail.' : result.errorMessage);
        System.assertNotEquals(null, result.requestId);
        System.assertEquals(fixture.expectedFirst, result.firstPaymentDate);
        List<GiftCommitmentSchedule> schedules = [
            SELECT Id, Type, StartDate, EndDate, TransactionAmount,
                   TransactionPeriod, TransactionInterval
            FROM GiftCommitmentSchedule WHERE GiftCommitmentId = :fixture.giftId
            ORDER BY StartDate
        ];
        Boolean foundGap = false;
        Boolean foundSuccessor = false;
        for (GiftCommitmentSchedule schedule : schedules) {
            if (schedule.Type == 'PauseTransactions' &&
                schedule.StartDate == fixture.futureStart &&
                schedule.EndDate == fixture.expectedFirst.addDays(-1)) foundGap = true;
            if (schedule.Type == 'CreateTransactions' &&
                schedule.StartDate == fixture.expectedFirst &&
                schedule.TransactionAmount == 25 &&
                schedule.TransactionInterval == 2) foundSuccessor = true;
        }
        System.assertEquals(true, foundGap);
        System.assertEquals(true, foundSuccessor);
        System.assertEquals('Paid', [SELECT Status FROM GiftTransaction
            WHERE Id = :fixture.paidId].Status);
        System.assertEquals(fixture.expectedFirst, [SELECT NextTransactionDate
            FROM GiftCommitment WHERE Id = :fixture.giftId].NextTransactionDate);
        System.assertEquals(1, [SELECT COUNT() FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c = :fixture.giftId AND Status__c = 'Pending']);
    }

    @IsTest
    static void stalePreviewRollsBackBeforeNativeMutation() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        Fixture fixture = createFixture('Weekly', 2);
        StripeRDFutureIntervalHandoffAction.Request request =
            new StripeRDFutureIntervalHandoffAction.Request();
        request.giftCommitmentId = fixture.giftId;
        request.selectedScheduleId = fixture.futureScheduleId;
        request.amount = 25;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 2;
        request.expectedFirstPaymentDate = fixture.expectedFirst.addDays(1);
        StripeRDFutureIntervalHandoffAction.Response result =
            StripeRDFutureIntervalHandoffAction.execute(
                new List<StripeRDFutureIntervalHandoffAction.Request>{request})[0];
        System.assertEquals(false, result.isSuccess);
        System.assert(result.errorMessage.contains('Restart'));
        System.assertEquals('CreateTransactions', [SELECT Type FROM GiftCommitmentSchedule
            WHERE Id = :fixture.futureScheduleId].Type);
    }

    @IsTest
    static void weeklyIntervalThreeKeepsOneFutureSequence() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        verifyLongInterval('Weekly', 3);
    }

    @IsTest
    static void yearlyIntervalTwoKeepsOneFutureSequence() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        verifyLongInterval('Yearly', 2);
    }

    @IsTest
    static void yearlyIntervalThreeKeepsOneFutureSequence() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        verifyLongInterval('Yearly', 3);
    }

    @IsTest
    static void currentMonthlyToYearlyRemovesOldUnpaidPayment() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        verifyCurrentCadenceGap('Monthly');
    }

    @IsTest
    static void currentDailyToYearlyPreservesPaidHistory() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        verifyCurrentCadenceGap('Daily');
    }

    private static void verifyCurrentCadenceGap(String originalPeriod) {
        StripePauseService.suppressSubscriptionUpdate = true;
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;
        Date paidDate = Date.today().addDays(-2);
        GiftCommitment gift = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_current_cadence_gap', 'Open');
        GiftCommitmentSchedule source = StripeRecurringScheduleTestDataFactory.createSchedule(
            gift, 5, originalPeriod, 1, paidDate, paidDate, null);
        update new GiftCommitmentSchedule(Id=source.Id,Type='CreateTransactions',
            TransactionDay=originalPeriod=='Monthly'?String.valueOf(paidDate.day()):null);
        GiftTransaction paid = new GiftTransaction(Name='Protected current cadence payment',
            DonorId=gift.DonorId,GiftCommitmentId=gift.Id,GiftCommitmentScheduleId=source.Id,
            Status='Paid',OriginalAmount=5,TransactionDate=paidDate,
            TransactionDueDate=paidDate,PaymentMethod='Credit Card');
        insert paid;
        Date oldDue = originalPeriod=='Monthly'?paidDate.addMonths(1):Date.today().addDays(1);
        insert new GiftTransaction(Name='Old cadence future payment',DonorId=gift.DonorId,
            GiftCommitmentId=gift.Id,GiftCommitmentScheduleId=source.Id,Status='Unpaid',
            OriginalAmount=5,TransactionDueDate=oldDue,PaymentMethod='Credit Card');
        StripePauseService.suppressSubscriptionUpdate = false;
        StripeRDFutureIntervalHandoffAction.Request request = new StripeRDFutureIntervalHandoffAction.Request();
        request.giftCommitmentId=gift.Id;
        request.selectedScheduleId=source.Id;
        request.amount=5;
        request.transactionPeriod='Yearly';
        request.transactionInterval=1;
        request.expectedFirstPaymentDate=paidDate.addYears(1);
        Test.startTest();
        StripeRDFutureIntervalHandoffAction.Response result=StripeRDFutureIntervalHandoffAction.execute(
            new List<StripeRDFutureIntervalHandoffAction.Request>{request})[0];
        Test.stopTest();
        Assert.isTrue(result.isSuccess,result.errorMessage==null?'The current cadence handoff must succeed.':result.errorMessage);
        Assert.isNotNull(result.requestId,'The first change must capture a durable request.');
        Assert.areEqual(paidDate.addYears(1),[SELECT NextTransactionDate FROM GiftCommitment WHERE Id=:gift.Id].NextTransactionDate,
            'The old monthly/daily unpaid payment must not remain in the gap.');
        Assert.areEqual(0,[SELECT COUNT() FROM GiftTransaction WHERE GiftCommitmentId=:gift.Id
            AND Status IN ('Unpaid','Pledged') AND TransactionDueDate<:paidDate.addYears(1)],
            'No old unpaid payment may remain before the yearly target.');
        Assert.areEqual(paidDate,[SELECT StartDate FROM GiftCommitmentSchedule WHERE Id=:source.Id].StartDate,
            'Historical Start Date must remain unchanged.');
        Assert.areEqual('Paid',[SELECT Status FROM GiftTransaction WHERE Id=:paid.Id].Status,
            'Paid history must remain unchanged.');
    }

    private static void verifyLongInterval(String period, Integer intervalCount) {
        Fixture fixture = createFixture(period, intervalCount);
        StripeRDFutureIntervalHandoffAction.Request request =
            new StripeRDFutureIntervalHandoffAction.Request();
        request.giftCommitmentId = fixture.giftId;
        request.selectedScheduleId = fixture.futureScheduleId;
        request.amount = 25;
        request.transactionPeriod = period;
        request.transactionInterval = intervalCount;
        request.expectedFirstPaymentDate = fixture.expectedFirst;
        Test.startTest();
        StripeRDFutureIntervalHandoffAction.Response result =
            StripeRDFutureIntervalHandoffAction.execute(
                new List<StripeRDFutureIntervalHandoffAction.Request>{request})[0];
        Test.stopTest();
        System.assert(result.isSuccess == true,
            result.errorMessage == null ? 'Future handoff failed without detail.' : result.errorMessage);
        System.assertEquals(fixture.expectedFirst, result.firstPaymentDate);
        Date gapEnd = fixture.expectedFirst.addDays(-1);
        System.assertEquals(1, [SELECT COUNT() FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :fixture.giftId AND Type = 'PauseTransactions'
              AND StartDate = :fixture.futureStart AND EndDate = :gapEnd]);
        System.assertEquals(1, [SELECT COUNT() FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :fixture.giftId AND Type = 'CreateTransactions'
              AND StartDate = :fixture.expectedFirst AND TransactionPeriod = :period
              AND TransactionInterval = :intervalCount]);
        System.assertEquals(1, [SELECT COUNT() FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c = :fixture.giftId AND Status__c = 'Pending']);
    }
}