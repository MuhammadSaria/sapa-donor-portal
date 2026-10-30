// Native Fundraising actions require the configured org-wide default designation.
// Only synthetic records created in this test transaction are mutated.
@IsTest(SeeAllData=true)
private class StripePauseNativeScheduleTest {
    private static void verifyPauseWithLaterInstallments(String recurringType, Boolean resumeNow) {
        StripePauseService.suppressSubscriptionUpdate = true;
        GiftCommitment gift = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_native_pause_boundary', recurringType);
        Date historicalStart = Date.today().addDays(-1);
        Date finalDate = recurringType == 'Fixed' ? Date.today().addDays(5) : null;
        GiftCommitmentSchedule source = StripeRecurringScheduleTestDataFactory.createSchedule(
            gift, 5, 'Daily', 1, historicalStart, historicalStart, null);
        update new GiftCommitmentSchedule(Id=source.Id,Type='CreateTransactions',EndDate=finalDate);
        GiftTransaction paid = new GiftTransaction(Name='Protected native pause payment',
            DonorId=gift.DonorId,GiftCommitmentId=gift.Id,GiftCommitmentScheduleId=source.Id,
            Status='Paid',OriginalAmount=5,TransactionDate=historicalStart,
            TransactionDueDate=historicalStart,PaymentMethod='Credit Card');
        insert paid;
        List<GiftTransaction> future = new List<GiftTransaction>();
        for(Integer i=0;i<6;i++) future.add(new GiftTransaction(Name='Future native pause '+i,
            DonorId=gift.DonorId,GiftCommitmentId=gift.Id,GiftCommitmentScheduleId=source.Id,
            Status='Unpaid',OriginalAmount=5,TransactionDueDate=Date.today().addDays(i),
            PaymentMethod='Credit Card'));
        insert future;
        Date resumeDate=Date.today().addDays(2);
        Test.startTest();
        StripePauseOrchestrator.nativePauseSchedule(source.Id,Date.today(),resumeDate.addDays(-1));
        Assert.areEqual(1,[SELECT COUNT() FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId=:gift.Id AND Type='PauseTransactions'
            AND StartDate=TODAY AND EndDate=:resumeDate.addDays(-1)],
            'The native pause must use only the requested interval.');
        List<GiftCommitmentSchedule> restoration=[SELECT Id,StartDate,EndDate
            FROM GiftCommitmentSchedule WHERE GiftCommitmentId=:gift.Id
            AND Type='CreateTransactions' AND StartDate=:resumeDate];
        Assert.areEqual(1,restoration.size(),'One native restoration segment is required.');
        Assert.areEqual(finalDate,restoration[0].EndDate,'The original Fixed final boundary must survive.');
        if (resumeNow) {
            GiftCommitmentSchedule paused=[SELECT Id FROM GiftCommitmentSchedule
                WHERE GiftCommitmentId=:gift.Id AND Type='PauseTransactions' AND StartDate=TODAY];
            StripePauseOrchestrator.nativeResumeSchedule(paused.Id,Date.today());
            Assert.areEqual(1,[SELECT COUNT() FROM GiftCommitmentSchedule
                WHERE GiftCommitmentId=:gift.Id AND Type='CreateTransactions'
                AND StartDate<=TODAY AND (EndDate=null OR EndDate>=TODAY)],
                'Resume Now must restore exactly one current billing segment.');
            GiftCommitmentSchedule resumed=[SELECT EndDate FROM GiftCommitmentSchedule
                WHERE GiftCommitmentId=:gift.Id AND Type='CreateTransactions' AND StartDate=TODAY];
            Assert.areEqual(resumeDate.addDays(-1),resumed.EndDate,
                'The native immediate segment must end before the existing restoration begins, without overlap.');
        }
        Test.stopTest();
        Assert.areEqual(historicalStart,[SELECT StartDate FROM GiftCommitmentSchedule WHERE Id=:source.Id].StartDate,
            'Historical Start Date must remain unchanged.');
        GiftTransaction protectedPayment=[SELECT Status,OriginalAmount,TransactionDate FROM GiftTransaction WHERE Id=:paid.Id];
        Assert.areEqual('Paid',protectedPayment.Status,'Paid history must remain paid.');
        Assert.areEqual(5,protectedPayment.OriginalAmount,'Paid amount must remain unchanged.');
        Assert.areEqual(historicalStart,protectedPayment.TransactionDate,'Paid date must remain unchanged.');
        Assert.areEqual(0,[SELECT COUNT() FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c=:gift.Id],
            'A pause must not create a recurring terms request.');
    }

    @IsTest static void fixedPausePreservesInstallmentsAfterResume() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        verifyPauseWithLaterInstallments('Fixed',false);
    }
    @IsTest static void openPausePreservesFutureBillingAfterResume() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        verifyPauseWithLaterInstallments('Open',false);
    }
    @IsTest static void fixedManualResumeReplacesPlannedRestoration() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        verifyPauseWithLaterInstallments('Fixed',true);
    }
    @IsTest static void openManualResumeReplacesPlannedRestoration() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        verifyPauseWithLaterInstallments('Open',true);
    }
}