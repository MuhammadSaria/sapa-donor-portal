/** Real native standard-action integration. Reads org default designation; mutates only synthetic test records. */
@IsTest(SeeAllData=true)
private class StripePauseTimelineNativeTest {
    @IsTest static void shouldPauseAcrossGapsAndGenerateSubsequentOriginalCalendarPayment() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=StripePauseTimelineTestDataFactory.createTimeline(true);
        StripePauseTimelinePlanner.Plan plan=StripePauseTimelinePlanner.plan(gift.Id,Date.today().addDays(1),
            Date.today().addDays(15),StripePauseTimelineSelector.schedules(gift.Id),StripePauseTimelineSelector.transactions(gift.Id));
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;
        StripePauseService.suppressSubscriptionUpdate=true;
        Test.startTest();
        StripePauseTimelineNativeService.pause(plan);
        Assert.isTrue(plan.applied);
        Assert.areEqual(Date.today().addDays(28),[SELECT NextTransactionDate FROM GiftCommitment WHERE Id=:gift.Id].NextTransactionDate);
        GiftTransaction future=[SELECT Id,Status FROM GiftTransaction WHERE GiftCommitmentId=:gift.Id AND Status='Unpaid' ORDER BY TransactionDueDate LIMIT 1];
        update new GiftTransaction(Id=future.Id,Status='Paid',TransactionDate=Date.today().addDays(28));
        Invocable.Action action=Invocable.Action.createStandardAction('processGiftCommitment');
        action.setInvocationParameter('giftCommitmentId',String.valueOf(gift.Id));
        Assert.isTrue(action.invoke()[0].isSuccess(),'The native recurring engine must continue, not just the first installment.');
        Assert.areEqual(Date.today().addDays(42),[SELECT NextTransactionDate FROM GiftCommitment WHERE Id=:gift.Id].NextTransactionDate);
        Test.stopTest();
        StripePauseService.suppressSubscriptionUpdate=previous;
        Assert.areEqual(0,[SELECT COUNT() FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c=:gift.Id]);
    }
    @IsTest static void shouldRollBackAllNativeSegmentsWhenSecondActionFails() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=StripePauseTimelineTestDataFactory.createTimeline(false);
        List<GiftCommitmentSchedule> before=StripePauseTimelineSelector.schedules(gift.Id);
        StripePauseTimelinePlanner.Plan plan=StripePauseTimelinePlanner.plan(gift.Id,Date.today(),Date.today().addDays(15),
            before,StripePauseTimelineSelector.transactions(gift.Id));
        StripePauseTimelineNativeService.failBeforeOperation=1;
        Test.startTest();
        try { StripePauseTimelineNativeService.pause(plan); Assert.fail('Forced second native action must fail.'); }
        catch(StripePauseTimelineNativeService.NativeException expected) { Assert.isTrue(expected.getMessage().contains('Synthetic')); }
        Test.stopTest();
        Assert.areEqual(StripePauseTimelinePlanner.fingerprint(before),
            StripePauseTimelinePlanner.fingerprint(StripePauseTimelineSelector.schedules(gift.Id)),'The first native action must roll back too.');
        Assert.isFalse(StripePauseService.suppressSubscriptionUpdate,'Suppression must restore the prior value.');
    }
    @IsTest static void shouldManuallyResumeOnlyOwnedPauseOnOriginalCalendar() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=StripePauseTimelineTestDataFactory.createTimeline(false);
        StripePauseTimelinePlanner.Plan plan=StripePauseTimelinePlanner.plan(gift.Id,Date.today(),Date.today().addDays(15),
            StripePauseTimelineSelector.schedules(gift.Id),StripePauseTimelineSelector.transactions(gift.Id));
        Test.startTest();
        StripePauseTimelineNativeService.pause(plan);
        plan.nextPaymentDate=Date.today().addDays(14);
        StripePauseTimelineNativeService.resume(plan,Date.today().addDays(1));
        Test.stopTest();
        Assert.areEqual(plan.nextPaymentDate,[SELECT NextTransactionDate FROM GiftCommitment WHERE Id=:gift.Id].NextTransactionDate);
        Assert.areEqual(2,[SELECT COUNT() FROM GiftCommitmentSchedule WHERE GiftCommitmentId=:gift.Id
            AND Type='PauseTransactions' AND StartDate>:Date.today() AND StartDate<:Date.today().addDays(14)],'Pre-existing gaps must survive.');
    }
    @IsTest static void shouldAtomicallyPauseFourConsecutiveBillingSegments() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;
        StripePauseService.suppressSubscriptionUpdate=true;
        GiftCommitment gift=StripeRecurringScheduleTestDataFactory.createCommitment('sub_multi_pause','Open');
        update new GiftCommitment(Id=gift.Id,ScheduleType='Recurring');
        List<GiftCommitmentSchedule> sources=new List<GiftCommitmentSchedule>{
            new GiftCommitmentSchedule(GiftCommitmentId=gift.Id,Type='CreateTransactions',StartDate=Date.today(),
                EndDate=Date.today(),TransactionAmount=5,TransactionPeriod='Daily',TransactionInterval=1,PaymentMethod='Credit Card')
        };
        for(Integer i=0;i<4;i++) sources.add(new GiftCommitmentSchedule(GiftCommitmentId=gift.Id,Type='CreateTransactions',
            StartDate=Date.today().addDays(i*3+1),EndDate=i==3?null:Date.today().addDays(i*3+3),TransactionAmount=6+i,
            TransactionPeriod='Daily',TransactionInterval=1,PaymentMethod='Credit Card'));
        insert sources;
        GiftTransaction paid=new GiftTransaction(Name='Protected four-source installment',DonorId=gift.DonorId,GiftCommitmentId=gift.Id,
            GiftCommitmentScheduleId=sources[0].Id,Status='Unpaid',OriginalAmount=5,TransactionDate=Date.today(),
            TransactionDueDate=Date.today(),PaymentMethod='Credit Card');
        insert paid;
        Payment__c payment=new Payment__c(Donation__c=paid.Id,Recurring_Donation__c=gift.Id,donorId__c=gift.DonorId,
            Payment_Amount__c=5,Paid__c=true,Payment_Status__c='Paid',Payment_Date__c=Date.today(),
            Payment_Method__c='Credit Card',Transaction_Id__c='synthetic-four-source-payment');
        insert payment;
        Assert.areEqual('Paid',[SELECT Status FROM GiftTransaction WHERE Id=:paid.Id].Status,
            'Use the normal Payment Flow to establish paid history before exercising pause.');
        List<GiftTransaction> unpaid=new List<GiftTransaction>();
        for(Integer i=1;i<sources.size();i++) unpaid.add(new GiftTransaction(Name='Four-source future '+i,DonorId=gift.DonorId,
            GiftCommitmentId=gift.Id,GiftCommitmentScheduleId=sources[i].Id,Status='Unpaid',OriginalAmount=5+i,
            TransactionDueDate=sources[i].StartDate,PaymentMethod='Credit Card'));
        insert unpaid;
        StripePauseTimelinePlanner.Plan plan=StripePauseTimelinePlanner.plan(gift.Id,Date.today().addDays(1),Date.today().addDays(14),
            StripePauseTimelineSelector.schedules(gift.Id),StripePauseTimelineSelector.transactions(gift.Id));
        Test.startTest();StripePauseTimelineNativeService.pause(plan);Test.stopTest();
        StripePauseService.suppressSubscriptionUpdate=previous;
        Assert.areEqual(4,plan.operations.size());
        Assert.areEqual(Date.today().addDays(14),[SELECT NextTransactionDate FROM GiftCommitment WHERE Id=:gift.Id].NextTransactionDate);
        Assert.areEqual(9,[SELECT TransactionAmount FROM GiftCommitmentSchedule WHERE Id=:plan.operations[3].restoredId].TransactionAmount);
        Assert.areEqual(0,[SELECT COUNT() FROM GiftTransaction WHERE GiftCommitmentId=:gift.Id AND Status='Unpaid' AND TransactionDueDate<:Date.today().addDays(14)]);
        Payment__c unchanged=[SELECT Donation__c,Recurring_Donation__c,Payment_Amount__c,Paid__c,Payment_Status__c FROM Payment__c WHERE Id=:payment.Id];
        Assert.areEqual(paid.Id,unchanged.Donation__c);Assert.areEqual(gift.Id,unchanged.Recurring_Donation__c);
        Assert.areEqual(5,unchanged.Payment_Amount__c);Assert.isTrue(unchanged.Paid__c);Assert.areEqual('Paid',unchanged.Payment_Status__c);
        Assert.areEqual(0,[SELECT COUNT() FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c=:gift.Id]);
    }
}