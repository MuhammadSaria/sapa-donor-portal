@IsTest
private class FundraisingFlowDeleteSchedulesActionTest {
    @IsTest
    static void deletesTransactionsBeforeSchedulesAndReturnsCounts() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment('sub_delete_adapter', 'Open');
        GiftCommitmentSchedule schedule = StripeRecurringScheduleTestDataFactory.createSchedule(
            commitment, 25, 'Monthly', 1, Date.today().addDays(5), Date.today(), null
        );
        GiftTransaction transactionRecord = StripeRecurringScheduleTestDataFactory.createUnpaidTransaction(
            commitment, schedule, 25, Date.today().addDays(5)
        );
        FundraisingFlowDeleteSchedulesAction.Request request = new FundraisingFlowDeleteSchedulesAction.Request();
        request.scheduleIds = new List<Id>{ schedule.Id };

        Test.startTest();
        List<FundraisingFlowDeleteSchedulesAction.Response> responses =
            FundraisingFlowDeleteSchedulesAction.execute(
                new List<FundraisingFlowDeleteSchedulesAction.Request>{ request }
            );
        Test.stopTest();

        Assert.isTrue(responses[0].isSuccess);
        Assert.areEqual(1, responses[0].deletedTransactionCount);
        Assert.areEqual(1, responses[0].deletedScheduleCount);
        Assert.areEqual(0, [SELECT COUNT() FROM GiftTransaction WHERE Id = :transactionRecord.Id]);
        Assert.areEqual(0, [SELECT COUNT() FROM GiftCommitmentSchedule WHERE Id = :schedule.Id]);
    }

    @IsTest
    static void acceptsNullAndEmptyRequestsWithoutMutation() {
        FundraisingFlowDeleteSchedulesAction.Request emptyRequest = new FundraisingFlowDeleteSchedulesAction.Request();
        emptyRequest.scheduleIds = new List<Id>();

        Test.startTest();
        List<FundraisingFlowDeleteSchedulesAction.Response> responses =
            FundraisingFlowDeleteSchedulesAction.execute(
                new List<FundraisingFlowDeleteSchedulesAction.Request>{ null, emptyRequest }
            );
        List<FundraisingFlowDeleteSchedulesAction.Response> nullResponses =
            FundraisingFlowDeleteSchedulesAction.execute(null);
        Test.stopTest();

        Assert.areEqual(2, responses.size());
        Assert.isTrue(responses[0].isSuccess);
        Assert.isTrue(responses[1].isSuccess);
        Assert.areEqual(0, nullResponses.size());
    }
}