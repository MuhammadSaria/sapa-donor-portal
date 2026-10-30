/** Pure classification/calendar regressions; all queried records are created by this test. */
@IsTest
private class StripePauseTimelinePlannerTest {
    @TestSetup static void setup() { StripePauseTimelineTestDataFactory.createTimeline(true); }
    private static GiftCommitment gift() {
        return [SELECT Id FROM GiftCommitment WHERE Subscription_Id__c='sub_multi_pause' LIMIT 1];
    }
    @IsTest static void shouldPreserveBiweeklyCalendarAndExistingGaps() {
        GiftCommitment gift=gift();
        StripePauseTimelinePlanner.Plan plan=StripePauseTimelinePlanner.plan(gift.Id,Date.today().addDays(1),
            Date.today().addDays(15),StripePauseTimelineSelector.schedules(gift.Id),StripePauseTimelineSelector.transactions(gift.Id));
        Assert.areEqual(1,plan.operations.size());
        Assert.areEqual(Date.today().addDays(28),plan.nextPaymentDate);
        Assert.areEqual(Date.today().addDays(14),plan.operations[0].pauseFrom);
        Assert.areEqual(1,plan.protectedPayments.size());
        StripePauseTimelinePlanner.Plan restored=(StripePauseTimelinePlanner.Plan)
            JSON.deserialize(JSON.serialize(plan),StripePauseTimelinePlanner.Plan.class);
        Assert.areEqual(plan.beforeFingerprint,restored.beforeFingerprint,'Versioned snapshots must round-trip.');
    }
    @IsTest static void shouldRejectTrueOverlapAndProtectedFuturePayment() {
        GiftCommitment gift=gift();
        List<GiftCommitmentSchedule> segments=StripePauseTimelineSelector.schedules(gift.Id);
        segments[2].EndDate=segments[3].StartDate;
        try {
            StripePauseTimelinePlanner.plan(gift.Id,Date.today().addDays(1),Date.today().addDays(15),segments,new List<GiftTransaction>());
            Assert.fail('Actual overlap must block.');
        } catch(StripePauseTimelinePlanner.TimelineException expected) { Assert.isTrue(expected.getMessage().contains('overlap')); }
        segments=StripePauseTimelineSelector.schedules(gift.Id);
        List<GiftTransaction> transactions=StripePauseTimelineSelector.transactions(gift.Id);
        transactions[1].Status='Paid'; transactions[1].TransactionDate=Date.today().addDays(14);
        try {
            StripePauseTimelinePlanner.plan(gift.Id,Date.today().addDays(1),Date.today().addDays(15),segments,transactions);
            Assert.fail('Protected future payment must block.');
        } catch(StripePauseTimelinePlanner.TimelineException expected) { Assert.isTrue(expected.getMessage().contains('paid')); }
    }
    @IsTest static void shouldUseMonthlyLateMonthAndYearlyCalendars() {
        GiftCommitmentSchedule monthly=new GiftCommitmentSchedule(StartDate=Date.newInstance(2026,1,30),
            TransactionPeriod='Monthly',TransactionInterval=1,TransactionDay='30');
        Assert.areEqual(Date.newInstance(2026,2,28),StripePauseTimelinePlanner.paymentOnOrAfter(monthly,monthly.StartDate,Date.newInstance(2026,2,1)));
        Assert.areEqual(Date.newInstance(2026,3,30),StripePauseTimelinePlanner.paymentOnOrAfter(monthly,monthly.StartDate,Date.newInstance(2026,3,1)));
        monthly.TransactionDay='LastDay';
        Assert.areEqual(Date.newInstance(2026,4,30),StripePauseTimelinePlanner.paymentOnOrAfter(monthly,monthly.StartDate,Date.newInstance(2026,4,1)));
        monthly.TransactionDay=null;
        try { StripePauseTimelinePlanner.paymentOnOrAfter(monthly,monthly.StartDate,Date.today()); Assert.fail('Blank monthly day must block.'); }
        catch(StripePauseTimelinePlanner.TimelineException expected) { Assert.isTrue(expected.getMessage().contains('Day')); }
        GiftCommitmentSchedule yearly=new GiftCommitmentSchedule(StartDate=Date.newInstance(2024,2,29),
            TransactionPeriod='Yearly',TransactionInterval=2);
        Assert.areEqual(Date.newInstance(2028,2,29),StripePauseTimelinePlanner.paymentOnOrAfter(yearly,yearly.StartDate,Date.newInstance(2026,3,1)));
    }
    @IsTest static void shouldRejectInvalidDatesUnsupportedPeriodAndFinishedWindow() {
        GiftCommitment gift=gift();
        List<GiftCommitmentSchedule> segments=StripePauseTimelineSelector.schedules(gift.Id);
        try { StripePauseTimelinePlanner.plan(gift.Id,Date.today(),Date.today(),segments,new List<GiftTransaction>()); Assert.fail('Invalid dates must block.'); }
        catch(StripePauseTimelinePlanner.TimelineException expected) { Assert.isTrue(expected.getMessage().contains('after')); }
        segments[3].EndDate=Date.today().addDays(14);
        try { StripePauseTimelinePlanner.plan(gift.Id,Date.today().addDays(1),Date.today().addDays(15),segments,new List<GiftTransaction>()); Assert.fail('No later payment must block.'); }
        catch(StripePauseTimelinePlanner.TimelineException expected) { Assert.isTrue(expected.getMessage().contains('No valid payment')); }
        segments[3].TransactionPeriod='Custom';
        try { StripePauseTimelinePlanner.paymentOnOrAfter(segments[3],segments[3].StartDate,Date.today()); Assert.fail('Unsupported period must block.'); }
        catch(StripePauseTimelinePlanner.TimelineException expected) { Assert.isTrue(expected.getMessage().contains('unsupported')); }
    }
}