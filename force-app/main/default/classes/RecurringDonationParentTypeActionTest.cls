@IsTest
private class RecurringDonationParentTypeActionTest {
    @IsTest
    static void updatesOnlyTheParentRecurringType() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_parent_type_action', 'Open'
        );
        String originalName = commitment.Name;
        RecurringDonationParentTypeAction.Request request = new RecurringDonationParentTypeAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.recurringType = 'Fixed';

        Test.startTest();
        List<RecurringDonationParentTypeAction.Response> responses =
            RecurringDonationParentTypeAction.execute(
                new List<RecurringDonationParentTypeAction.Request>{ request }
            );
        Test.stopTest();

        GiftCommitment updated = [
            SELECT Name, Recurring_Type__c FROM GiftCommitment WHERE Id = :commitment.Id
        ];
        Assert.isTrue(responses[0].success);
        Assert.areEqual('Fixed', updated.Recurring_Type__c);
        Assert.areEqual(originalName, updated.Name, 'No unrelated parent field may be rewritten.');
    }

    @IsTest
    static void rejectsInvalidTypeWithoutDml() {
        GiftCommitment commitment = StripeRecurringScheduleTestDataFactory.createCommitment(
            'sub_parent_type_invalid', 'Open'
        );
        RecurringDonationParentTypeAction.Request request = new RecurringDonationParentTypeAction.Request();
        request.giftCommitmentId = commitment.Id;
        request.recurringType = 'Unknown';

        List<RecurringDonationParentTypeAction.Response> responses =
            RecurringDonationParentTypeAction.execute(
                new List<RecurringDonationParentTypeAction.Request>{ request }
            );

        Assert.isFalse(responses[0].success);
        Assert.areEqual('Open', [
            SELECT Recurring_Type__c FROM GiftCommitment WHERE Id = :commitment.Id
        ].Recurring_Type__c);
    }
}