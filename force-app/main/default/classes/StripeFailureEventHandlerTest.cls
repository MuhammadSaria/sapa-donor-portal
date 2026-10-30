@IsTest
private with sharing class StripeFailureEventHandlerTest {

    @IsTest
    static void bulkEventsCreateOneLogEach() {
        List<Stripe_Failure__e> events = new List<Stripe_Failure__e>();
        for (Integer i = 0; i < 200; i++) {
            events.add(event('KEY-' + i, 'STRIPE_API_ERROR'));
        }

        Test.startTest();
        EventBus.publish(events);
        Test.stopTest();

        Assert.areEqual(200, [SELECT COUNT() FROM Stripe_Failure_Log__c], 'Each distinct failure gets its own log');
    }

    @IsTest
    static void repeatsIncrementOneLog() {
        Test.startTest();
        EventBus.publish(new List<Stripe_Failure__e>{ event('KEY-A', 'STRIPE_API_ERROR'), event('KEY-A', 'STRIPE_API_ERROR') });
        Test.getEventBus().deliver();
        EventBus.publish(event('KEY-A', 'STRIPE_API_ERROR'));
        Test.stopTest();

        Stripe_Failure_Log__c log = [SELECT Occurrence_Count__c, Last_Occurred_At__c FROM Stripe_Failure_Log__c];
        Assert.areEqual(3, log.Occurrence_Count__c, 'Repeats in and across batches update one log');
        Assert.isNotNull(log.Last_Occurred_At__c, 'Latest occurrence time is kept');
    }

    @IsTest
    static void recurrenceReopensResolvedLog() {
        insert new Stripe_Failure_Log__c(Dedupe_Key__c = 'KEY-R', Status__c = 'Resolved', Notify__c = false,
            Occurrence_Count__c = 1, Reason_Code__c = 'RECURRING_SYNC_FAILED', Failure_Source__c = 'Recurring Sync');

        Test.startTest();
        EventBus.publish(event('KEY-R', 'RECURRING_SYNC_FAILED'));
        Test.stopTest();

        Stripe_Failure_Log__c log = [SELECT Status__c, Notify__c, Occurrence_Count__c FROM Stripe_Failure_Log__c];
        Assert.areEqual('New', log.Status__c, 'A resolved failure that happens again is reopened');
        Assert.isTrue(log.Notify__c, 'A reopened failure notifies again');
        Assert.areEqual(2, log.Occurrence_Count__c, 'The recurrence is counted');
    }

    @IsTest
    static void burstAlertsOncePerReasonCode() {
        List<Stripe_Failure__e> events = new List<Stripe_Failure__e>();
        for (Integer i = 0; i < 5; i++) {
            events.add(event('KEY-BURST-' + i, 'RECURRING_SYNC_FAILED'));
        }
        events.add(event('KEY-OTHER', 'REFUND_FAILED'));

        Test.startTest();
        EventBus.publish(events);
        Test.stopTest();

        Assert.areEqual(6, [SELECT COUNT() FROM Stripe_Failure_Log__c], 'Every failure is still logged');
        Assert.areEqual(1, [SELECT COUNT() FROM Stripe_Failure_Log__c WHERE Notify__c = true AND Reason_Code__c = 'RECURRING_SYNC_FAILED'],
            'A burst of the same reason code alerts once');
        Assert.areEqual(1, [SELECT COUNT() FROM Stripe_Failure_Log__c WHERE Notify__c = true AND Reason_Code__c = 'REFUND_FAILED'],
            'A different reason code still alerts');
    }

    @IsTest
    static void mutedReasonCodeDoesNotNotify() {
        StripeFailureEventHandler.notifyOverrides.put('REFUND_FAILED', false);

        Test.startTest();
        EventBus.publish(event('KEY-M', 'REFUND_FAILED'));
        Test.stopTest();

        Assert.isFalse([SELECT Notify__c FROM Stripe_Failure_Log__c].Notify__c, 'A muted code is logged without notifying');
    }

    @IsTest
    static void linksOnlyMatchingRecordTypes() {
        Account donor = personDonor();
        insert donor;
        GiftCommitment commitment = new GiftCommitment(Name = 'Failure Log RD', DonorId = donor.Id, Status = 'Active');
        insert commitment;
        Stripe_Failure__e failure = event('KEY-L', 'RD_UPDATE_FAILED');
        failure.Gift_Commitment_Id__c = commitment.Id;
        failure.Payment_Id__c = commitment.Id;           // wrong object type: ignored
        failure.Gift_Transaction_Id__c = 'not-an-id';    // malformed: ignored

        Test.startTest();
        EventBus.publish(failure);
        Test.stopTest();

        Stripe_Failure_Log__c log = [SELECT Gift_Commitment__c, Payment__c, Gift_Transaction__c FROM Stripe_Failure_Log__c];
        Assert.areEqual(commitment.Id, log.Gift_Commitment__c, 'The recurring donation is linked');
        Assert.isNull(log.Payment__c, 'An id of the wrong object type is not linked');
        Assert.isNull(log.Gift_Transaction__c, 'A malformed id is not linked');
    }

    @IsTest
    static void deletedLinkedRecordStillProducesALog() {
        Account donor = personDonor();
        insert donor;
        GiftCommitment commitment = new GiftCommitment(Name = 'Deleted RD', DonorId = donor.Id, Status = 'Active');
        insert commitment;
        Id deletedId = commitment.Id;
        delete commitment;
        Stripe_Failure__e failure = event('KEY-D', 'RD_UPDATE_FAILED');
        failure.Gift_Commitment_Id__c = deletedId;

        Test.startTest();
        EventBus.publish(failure);
        Test.stopTest();

        Stripe_Failure_Log__c log = [SELECT Gift_Commitment__c, Reason_Code__c FROM Stripe_Failure_Log__c];
        Assert.areEqual('RD_UPDATE_FAILED', log.Reason_Code__c, 'The failure is still logged');
        Assert.isNull(log.Gift_Commitment__c, 'The link to the deleted record is dropped');
    }

    // Stripe Support visibility comes from a sharing rule, which a validation deploy does not
    // apply to its own test run; it is checked through share records after deployment instead.
    @IsTest
    static void logsAreHiddenFromUsersOutsideStripeSupport() {
        User outsider = createUser('outsider');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            // Object access alone must not reveal logs: visibility is by sharing only.
            PermissionSet supportAccess = [SELECT Id FROM PermissionSet WHERE Name = 'Stripe_Failure_Log_Support'];
            insert new PermissionSetAssignment(AssigneeId = outsider.Id, PermissionSetId = supportAccess.Id);
        }

        Test.startTest();
        EventBus.publish(event('KEY-S', 'PAID_NOT_RECORDED'));
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Stripe_Failure_Log__c], 'The log exists');
        System.runAs(outsider) {
            Assert.areEqual(0, [SELECT COUNT() FROM Stripe_Failure_Log__c],
                'A user outside Stripe Support cannot see logs, even with object access');
        }
    }

    private static Stripe_Failure__e event(String key, String reasonCode) {
        return new Stripe_Failure__e(
            Dedupe_Key__c = key,
            Reason_Code__c = reasonCode,
            Failure_Source__c = 'Stripe API Callout',
            Failure_Reason__c = 'Test failure',
            Error_Message__c = 'Test error',
            Operation__c = 'StripeFailureEventHandlerTest',
            Occurred_At__c = System.now()
        );
    }

    private static Account personDonor() {
        Id personAccountTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
            .get('PersonAccount').getRecordTypeId();
        return new Account(RecordTypeId = personAccountTypeId, FirstName = 'Failure', LastName = 'Donor');
    }

    private static User createUser(String tag) {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String username = 'sfl.' + tag + '.' + String.valueOf(Crypto.getRandomInteger()).replace('-', '') + '@example.com';
        User user = new User(ProfileId = standard.Id, Username = username, Email = username, LastName = tag,
            Alias = tag.left(8), TimeZoneSidKey = 'America/New_York', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
        insert user;
        return user;
    }
}