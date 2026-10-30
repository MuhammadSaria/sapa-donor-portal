/** Multi-segment pause regression. The real native handoff has its own integration tests. */
@IsTest
private class StripePauseTimelineTest {
    @TestSetup static void setup() {
        StripeRecurringSyncConfigTestData.useMockConfiguration(); StripePauseTimelineTestDataFactory.createTimeline(true); }

    @IsTest static void shouldAllowPause_WhenConsecutiveFutureSegmentsExist() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=[SELECT Id FROM GiftCommitment WHERE Subscription_Id__c='sub_multi_pause' LIMIT 1];
        Date resume=Date.today().addDays(15);
        Test.setMock(HttpCalloutMock.class,new PauseHttpMock());
        Test.startTest();
        StripePauseResult result=StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(resume));
        Test.stopTest();
        Assert.isTrue(result.stripeConfirmed,'Legitimate future segments must not reject a Stripe pause.');
        Assert.areEqual('Scheduled',result.salesforceState,'Paid today must defer the Salesforce transition.');
        GiftCommitment saved=[SELECT Status,Stripe_Pause_State__c,Pause_Start_Date__c,Pause_Resume_Date__c
            FROM GiftCommitment WHERE Id=:gift.Id];
        Assert.areEqual('Active',saved.Status,'Today\'s paid schedule remains active.');
        Assert.areEqual(Date.today().addDays(1),saved.Pause_Start_Date__c,'Pause starts tomorrow in Salesforce.');
        Assert.areEqual(resume,saved.Pause_Resume_Date__c,'The selected resume date is retained.');
        StripePauseTimelinePlanner.Plan plan=(StripePauseTimelinePlanner.Plan)JSON.deserialize(
            [SELECT Stripe_Pause_Plan__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_Plan__c,StripePauseTimelinePlanner.Plan.class);
        Assert.areEqual(2,plan.version);Assert.areEqual(StripePauseBusinessClock.resumeEpoch(resume),plan.resumeAtEpoch);
        Assert.areEqual('Active',plan.compensationStatus);
        Assert.areEqual(0,[SELECT COUNT() FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c=:gift.Id],
            'Pause must not create an unrelated terms request.');
    }

    @IsTest static void v2ResumeTimestampIsSignedAndCannotBeChangedOutsideAction() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=[SELECT Id FROM GiftCommitment WHERE Subscription_Id__c='sub_multi_pause' LIMIT 1];
        Test.setMock(HttpCalloutMock.class,new PauseHttpMock());
        Test.startTest();
        StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(StripePauseBusinessClock.today().addDays(15)));
        StripePauseTimelinePlanner.Plan plan=(StripePauseTimelinePlanner.Plan)JSON.deserialize(
            [SELECT Stripe_Pause_Plan__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_Plan__c,StripePauseTimelinePlanner.Plan.class);
        plan.resumeAtEpoch++;
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;StripePauseService.suppressSubscriptionUpdate=true;
        update new GiftCommitment(Id=gift.Id,Stripe_Pause_Plan__c=JSON.serialize(plan));
        StripePauseService.suppressSubscriptionUpdate=previous;
        try {StripePauseOrchestrator.resume('sub_multi_pause',gift.Id);Assert.fail('Tampered v2 timestamp must be rejected before callouts.');}
        catch(AuraHandledException expected) {Assert.isTrue(expected.getMessage().contains('outside the action'));}
        Test.stopTest();
    }

    @IsTest static void v1SignatureIgnoresNewOptionalFieldsForLegacyCompatibility() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=[SELECT Id FROM GiftCommitment WHERE Subscription_Id__c='sub_multi_pause' LIMIT 1];
        StripePauseTimelinePlanner.Plan plan=StripePauseTimelinePlanner.plan(gift.Id,StripePauseBusinessClock.today().addDays(1),
            StripePauseBusinessClock.today().addDays(15),StripePauseTimelineSelector.schedules(gift.Id),StripePauseTimelineSelector.transactions(gift.Id));
        String legacySignature=StripePauseTimelineService.signature(plan);
        plan.resumeAtEpoch=1;plan.compensationStatus='Active';
        Assert.areEqual(legacySignature,StripePauseTimelineService.signature(plan),'Version 1 payloads retain their original signature inputs.');
        plan.version=2;Assert.areNotEqual(legacySignature,StripePauseTimelineService.signature(plan));
    }
    @IsTest static void multiScheduleMustRejectAChangedConfirmationBeforeStripe() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=[SELECT Id FROM GiftCommitment WHERE Subscription_Id__c='sub_multi_pause' LIMIT 1];
        try {StripePauseOrchestrator.pauseConfirmed('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(StripePauseBusinessClock.today().addDays(15)),
            String.valueOf(StripePauseBusinessClock.today()),String.valueOf(StripePauseBusinessClock.today()),false);
            Assert.fail('Paid-today multi-schedule start must be confirmed before any Stripe call.');}
        catch(AuraHandledException expected) {Assert.isTrue(expected.getMessage().contains('changed since confirmation'));}
    }

    private class PauseHttpMock implements HttpCalloutMock {
        Boolean paused=false;
        Long resumeEpoch;
        public HttpResponse respond(HttpRequest request) {
            Assert.isTrue(request.getEndpoint().endsWith('/subscriptions/sub_multi_pause'),'Only the synthetic subscription may be called.');
            if(request.getMethod()=='POST') {
                Assert.isTrue(request.getBody().startsWith('pause_collection[behavior]=void&'),'Only pause collection may mutate Stripe.');
                Assert.isNotNull(request.getHeader('Idempotency-Key'),'Pause must be idempotent.');
                paused=true;
                resumeEpoch=Long.valueOf(request.getBody().substringAfter('pause_collection[resumes_at]=').substringBefore('&'));
                Assert.areEqual(StripePauseBusinessClock.resumeEpoch(StripePauseBusinessClock.today().addDays(15)),resumeEpoch);
            }
            HttpResponse response=new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String,Object>{'id'=>'sub_multi_pause','status'=>'active',
                'livemode'=>false,'pause_collection'=>paused?new Map<String,Object>{'behavior'=>'void','resumes_at'=>resumeEpoch}:null}));
            return response;
        }
    }
}