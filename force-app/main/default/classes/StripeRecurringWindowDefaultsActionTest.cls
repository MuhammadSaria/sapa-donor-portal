@IsTest
private class StripeRecurringWindowDefaultsActionTest {
    @IsTest
    static void defaultsToEarliestFutureUnpaidAndSnapshotsOriginalTerms() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_window_defaults', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 5, 'Monthly', 1, Date.today().addMonths(-3),
            Date.today().addMonths(-3), null
        );
        insert new List<GiftTransaction>{
            new GiftTransaction(
                Name = 'Later pledged', DonorId = commitment.DonorId,
                GiftCommitmentId = commitment.Id, GiftCommitmentScheduleId = schedule.Id,
                Status = 'Pledged', OriginalAmount = 5,
                TransactionDueDate = Date.today().addDays(40), PaymentMethod = 'Credit Card'
            ),
            new GiftTransaction(
                Name = 'First pledged', DonorId = commitment.DonorId,
                GiftCommitmentId = commitment.Id, GiftCommitmentScheduleId = schedule.Id,
                Status = 'Pledged', OriginalAmount = 5,
                TransactionDueDate = Date.today().addDays(10), PaymentMethod = 'Credit Card'
            )
        };

        StripeRecurringWindowDefaultsAction.Request request =
            new StripeRecurringWindowDefaultsAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.selectedScheduleId = schedule.Id;

        StripeRecurringWindowDefaultsAction.Response response =
            StripeRecurringWindowDefaultsAction.execute(
                new List<StripeRecurringWindowDefaultsAction.Request>{ request }
            )[0];

        Assert.isTrue(response.isSuccess);
        Assert.areEqual(Date.today().addDays(10), response.effectiveStartDate);
        Assert.areEqual(5, response.originalAmount);
        Assert.areEqual('Monthly', response.originalPeriod);
        Assert.areEqual(1, response.originalInterval);
    }

    @IsTest
    static void fallsBackToTodayAndRejectsScheduleFromAnotherCommitment() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment first = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_window_defaults_first', 'Open'
        );
        GiftCommitment second = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_window_defaults_second', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            first, 9, 'Weekly', 1, Date.today().addDays(-21), Date.today().addDays(-21), null
        );

        StripeRecurringWindowDefaultsAction.Request valid =
            new StripeRecurringWindowDefaultsAction.Request();
        valid.giftCommitmentId = first.Id;
        valid.selectedScheduleId = schedule.Id;
        StripeRecurringWindowDefaultsAction.Request invalid =
            new StripeRecurringWindowDefaultsAction.Request();
        invalid.giftCommitmentId = second.Id;
        invalid.selectedScheduleId = schedule.Id;

        List<StripeRecurringWindowDefaultsAction.Response> responses =
            StripeRecurringWindowDefaultsAction.execute(
                new List<StripeRecurringWindowDefaultsAction.Request>{ valid, invalid }
            );

        Assert.isTrue(responses[0].isSuccess);
        Assert.areEqual(Date.today(), responses[0].effectiveStartDate);
        Assert.isFalse(responses[1].isSuccess);
        Assert.areEqual('INVALID_SELECTED_SCHEDULE', responses[1].errorType);
    }
}