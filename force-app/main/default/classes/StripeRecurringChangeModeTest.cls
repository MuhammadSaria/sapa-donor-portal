@IsTest
private class StripeRecurringChangeModeTest {
    private static GiftCommitmentSchedule schedule() {
        return new GiftCommitmentSchedule(
            TransactionAmount = 25,
            TransactionPeriod = 'Monthly',
            TransactionInterval = 1,
            StartDate = Date.today().addDays(-30),
            EndDate = Date.today().addMonths(3)
        );
    }

    @IsTest
    static void amountAndCadenceAreTerms() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        StripeRecurringChangeMode.Result amount = StripeRecurringChangeMode.classify(
            schedule(), 'Fixed', 30, 'Monthly', 1, schedule().StartDate, schedule().EndDate, 'Fixed', null
        );
        Assert.areEqual(StripeRecurringChangeMode.TERMS, amount.mode);

        StripeRecurringChangeMode.Result cadence = StripeRecurringChangeMode.classify(
            schedule(), 'Fixed', 25, 'Weekly', 1, schedule().StartDate, schedule().EndDate, 'Fixed', null
        );
        Assert.areEqual(StripeRecurringChangeMode.TERMS, cadence.mode);
    }

    @IsTest
    static void addingOrClearingEndDateIsEndDateOnly() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitmentSchedule openSchedule = schedule();
        openSchedule.EndDate = null;
        StripeRecurringChangeMode.Result openToFixed = StripeRecurringChangeMode.classify(
            openSchedule, 'Open', 25, 'Monthly', 1, openSchedule.StartDate,
            Date.today().addMonths(3), 'Fixed', null
        );
        Assert.areEqual(StripeRecurringChangeMode.END_DATE_ONLY, openToFixed.mode);

        StripeRecurringChangeMode.Result fixedToOpen = StripeRecurringChangeMode.classify(
            schedule(), 'Fixed', 25, 'Monthly', 1, schedule().StartDate, null, 'Open', null
        );
        Assert.areEqual(StripeRecurringChangeMode.END_DATE_ONLY, fixedToOpen.mode);
    }

    @IsTest
    static void startDateIsTheOnlyStartDateChangeMode() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitmentSchedule current = schedule();
        StripeRecurringChangeMode.Result result = StripeRecurringChangeMode.classify(
            current, 'Fixed', current.TransactionAmount, current.TransactionPeriod, 1,
            current.StartDate.addDays(1), current.EndDate, 'Fixed', null
        );
        Assert.areEqual(StripeRecurringChangeMode.START_DATE_CHANGE, result.mode);
        Assert.isTrue(result.startDateChanged);
    }

    @IsTest
    static void CombinedTermsAndEndDateRemainTerms() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitmentSchedule current = schedule();
        StripeRecurringChangeMode.Result result = StripeRecurringChangeMode.classify(
            current, 'Fixed', 30, 'Weekly', 1, current.StartDate,
            current.EndDate.addMonths(1), 'Fixed', StripeRecurringChangeMode.END_DATE_ONLY
        );
        Assert.areEqual(StripeRecurringChangeMode.TERMS, result.mode);
        Assert.isTrue(result.cadenceChanged);
        Assert.isTrue(result.endDateChanged);
    }
}