@IsTest
private class FundraisingFlowReadActionTest {
    @IsTest
    static void returnsCommitmentAndScheduleResourcesWithoutMutation() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment('sub_flow_read', 'Open');
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 25, 'Monthly', 1, Date.today().addDays(5), Date.today(), null
        );
        FundraisingFlowReadAction.Request byId = new FundraisingFlowReadAction.Request();
        byId.operation = 'GiftCommitmentById';
        byId.recordId = commitment.Id;
        FundraisingFlowReadAction.Request schedules = new FundraisingFlowReadAction.Request();
        schedules.operation = 'ActiveSchedulesByCommitments';
        schedules.recordIds = new List<Id>{ commitment.Id };

        Test.startTest();
        List<FundraisingFlowReadAction.Response> responses = FundraisingFlowReadAction.execute(
            new List<FundraisingFlowReadAction.Request>{ byId, schedules }
        );
        Test.stopTest();

        Assert.areEqual(commitment.Id, responses[0].giftCommitment.Id);
        Assert.areEqual('Stripe', responses[0].giftCommitment.Payment_Processor__c,
            'The Flow read action must query the parent processor used by the Stripe eligibility gate.');
        Assert.areEqual('Credit Card', responses[0].giftCommitment.Payment_type__c,
            'The Flow read action must query the parent payment type used by the Stripe eligibility gate.');
        Assert.areEqual('Open', responses[0].giftCommitment.Recurring_Type__c,
            'The parent recurring type is the guided Flow source of truth.');
        Assert.areEqual('sub_flow_read', responses[0].giftCommitment.Subscription_Id__c,
            'The Flow read action must expose the subscription ID without a second query.');
        Assert.isTrue(responses[0].isStripeClassified);
        Assert.isTrue(responses[0].isVerifiedStripe);
        Assert.isNull(responses[0].stripeEligibilityWarning);
        Assert.isNotNull(responses[1].giftCommitmentSchedules);
        Assert.isTrue(responses[1].giftCommitmentSchedules.size() >= 1);
        Assert.areEqual(schedule.Id, responses[1].giftCommitmentSchedules[0].Id);
        Assert.areEqual(0, [SELECT COUNT() FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c = :commitment.Id]);
    }

    @IsTest
    static void supportsEveryGuidedFlowReadOperationAndEmptyInputs() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment('sub_flow_all_reads', 'Open');
        GiftCommitmentSchedule pausedSchedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 30, 'Monthly', 1, Date.today().addDays(10), Date.today(), null
        );
        pausedSchedule.Type = 'PauseTransactions';
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        update pausedSchedule;
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = false;

        List<FundraisingFlowReadAction.Request> requests = new List<FundraisingFlowReadAction.Request>();
        for (String operation : new List<String>{
            'GiftCommitmentsByDonor',
            'ActiveSchedulesByCommitment',
            'PausedSchedulesByCommitment',
            'PaymentInstrumentById',
            'UnsupportedOperation'
        }) {
            FundraisingFlowReadAction.Request request = new FundraisingFlowReadAction.Request();
            request.operation = operation;
            request.recordId = operation == 'GiftCommitmentsByDonor' ? commitment.DonorId : commitment.Id;
            if (operation == 'PaymentInstrumentById') request.recordId = null;
            requests.add(request);
        }
        requests.add(null);

        Test.startTest();
        List<FundraisingFlowReadAction.Response> responses = FundraisingFlowReadAction.execute(requests);
        List<FundraisingFlowReadAction.Response> nullResponses = FundraisingFlowReadAction.execute(null);
        Test.stopTest();

        Assert.areEqual(6, responses.size());
        Assert.areEqual(commitment.Id, responses[0].giftCommitments[0].Id);
        Assert.areEqual(0, responses[1].giftCommitmentSchedules.size());
        Assert.areEqual(pausedSchedule.Id, responses[2].giftCommitmentSchedules[0].Id);
        Assert.isNull(responses[3].paymentInstrument);
        Assert.isNull(responses[4].giftCommitment);
        Assert.isNull(responses[5].giftCommitment);
        Assert.areEqual(0, nullResponses.size());
    }

    @IsTest
    static void resolvesUpdateFlowCommitmentIdsWithoutThePackagedQuerySubflow() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_flow_input_resolution', 'Open'
        );
        FundraisingFlowReadAction.Request byDonor = new FundraisingFlowReadAction.Request();
        byDonor.operation = 'GiftCommitmentIdsByInput';
        byDonor.recordId = commitment.DonorId;
        FundraisingFlowReadAction.Request byCommitment = new FundraisingFlowReadAction.Request();
        byCommitment.operation = 'GiftCommitmentIdsByInput';
        byCommitment.recordId = commitment.Id;

        List<FundraisingFlowReadAction.Response> responses = FundraisingFlowReadAction.execute(
            new List<FundraisingFlowReadAction.Request>{ byDonor, byCommitment }
        );

        Assert.isFalse(responses[0].isError);
        Assert.areEqual(new List<Id>{ commitment.Id }, responses[0].giftCommitmentIds);
        Assert.isFalse(responses[1].isError);
        Assert.areEqual(new List<Id>{ commitment.Id }, responses[1].giftCommitmentIds);
    }
}