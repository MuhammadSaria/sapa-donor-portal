@IsTest
private class StripeRDSameDayMutationActionTest {
    @IsTest
    static void amountAndCadenceChangePreservesPaidTransaction() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_same_day_mutation_terms', 'Open'
        );
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 25, 'Monthly', 1, Date.today().addDays(-30), Date.today().addDays(-30), null
        );
        GiftTransaction paid = new GiftTransaction(
            Name = 'Paid same day mutation', DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id, GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid', OriginalAmount = 25, TransactionDate = Date.today(),
            TransactionDueDate = Date.today(), PaymentMethod = 'Credit Card'
        );
        insert paid;
        GiftTransaction future = StripeRecurringScheduleTestDataFactory.createUnpaidTransaction(
            commitment, schedule, 25, Date.today().addMonths(1)
        );
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;

        StripeRDSameDayMutationAction.Request request =
            new StripeRDSameDayMutationAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.selectedScheduleId = schedule.Id;
        request.amount = 30;
        request.transactionPeriod = 'Weekly';
        request.transactionInterval = 1;
        request.effectiveDate = Date.today();
        request.proposedStartDate = schedule.StartDate;
        request.proposedEndDateIsSet = true;
        request.proposedEndDate = null;
        request.recurringType = 'Open';

        Test.startTest();
        List<StripeRDSameDayMutationAction.Response> responses =
            StripeRDSameDayMutationAction.execute(
                new List<StripeRDSameDayMutationAction.Request>{ request }
            );
        Test.stopTest();

        Assert.isTrue(responses[0].isSuccess, responses[0].errorMessage == null ? '' : responses[0].errorMessage);
        GiftTransaction paidAfter = [SELECT Status, OriginalAmount, TransactionDate FROM GiftTransaction WHERE Id = :paid.Id];
        Assert.areEqual('Paid', paidAfter.Status);
        Assert.areEqual(25, paidAfter.OriginalAmount);
        Assert.areEqual(Date.today(), paidAfter.TransactionDate);
        GiftTransaction futureAfter = [SELECT OriginalAmount, TransactionDueDate, GiftCommitmentScheduleId FROM GiftTransaction WHERE Id = :future.Id];
        Assert.areEqual(30, futureAfter.OriginalAmount);
        Assert.areEqual(Date.today().addDays(7), futureAfter.TransactionDueDate,
            'A cadence change resets only the future unpaid transaction date.');
        Assert.areEqual(schedule.Id, futureAfter.GiftCommitmentScheduleId,
            'A term change after payment keeps future work on the existing schedule.');
        GiftCommitmentSchedule scheduleAfter = [
            SELECT StartDate, EndDate
            FROM GiftCommitmentSchedule WHERE Id = :schedule.Id
        ];
        Assert.areEqual(schedule.StartDate, scheduleAfter.StartDate,
            'The existing Start Date must never be changed by this path.');
        Assert.isNull(scheduleAfter.EndDate);
        Assert.areEqual(1, [
            SELECT COUNT() FROM GiftCommitmentSchedule WHERE GiftCommitmentId = :commitment.Id
        ], 'No successor schedule may be created.');
    }

    @IsTest
    static void openToFixedEndDateOnlyCalculatesCancellationFields() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_same_day_mutation_fixed', 'Open'
        );
        // Anchor on day 1 so month-end truncation cannot change the fixture's
        // three future payments and four inclusive schedule occurrences.
        Date monthlyOrigin = Date.today().toStartOfMonth();
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 25, 'Monthly', 1, monthlyOrigin, monthlyOrigin, null
        );
        insert new GiftTransaction(
            Name = 'Paid before fixed transition', DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id, GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid', OriginalAmount = 25, TransactionDate = Date.today(),
            TransactionDueDate = Date.today(), PaymentMethod = 'Credit Card'
        );
        StripeRecurringScheduleTestDataFactory.createUnpaidTransaction(
            commitment, schedule, 25, monthlyOrigin.addMonths(1)
        );
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        StripeRecurringScheduleChangeService.enqueueDisabledForTest = true;

        Date requestedEnd = monthlyOrigin.addMonths(3);
        StripeRDSameDayMutationAction.Request request =
            new StripeRDSameDayMutationAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.selectedScheduleId = schedule.Id;
        request.amount = 25;
        request.transactionPeriod = 'Monthly';
        request.transactionInterval = 1;
        request.effectiveDate = Date.today();
        request.proposedStartDate = schedule.StartDate;
        request.proposedEndDateIsSet = true;
        request.proposedEndDate = requestedEnd;
        request.recurringType = 'Fixed';

        Test.startTest();
        List<StripeRDSameDayMutationAction.Response> responses =
            StripeRDSameDayMutationAction.execute(
                new List<StripeRDSameDayMutationAction.Request>{ request }
            );
        Test.stopTest();

        Assert.isTrue(responses[0].isSuccess, responses[0].errorMessage == null ? '' : responses[0].errorMessage);
        Assert.areEqual(3, responses[0].calculatedInstallments);
        GiftCommitment parent = [SELECT Recurring_Type__c FROM GiftCommitment WHERE Id = :commitment.Id];
        Assert.areEqual('Fixed', parent.Recurring_Type__c);
        GiftCommitmentSchedule updated = [
            SELECT StartDate, EndDate, Final_Payment_Date__c, Number_of_Planned_Installments__c
            FROM GiftCommitmentSchedule WHERE Id = :schedule.Id
        ];
        Assert.areEqual(schedule.StartDate, updated.StartDate);
        Assert.areEqual(requestedEnd, updated.EndDate);
        Assert.areEqual(requestedEnd, updated.Final_Payment_Date__c);
        // The native schedule formula counts the historical StartDate
        // occurrence as well.  The durable Stripe request uses the three
        // future payments while this persisted total remains
        // consistent with the immutable schedule StartDate.
        Assert.areEqual(4, updated.Number_of_Planned_Installments__c);
    }

}