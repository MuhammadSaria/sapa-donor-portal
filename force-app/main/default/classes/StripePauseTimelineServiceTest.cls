/** Multi-schedule orchestrator with collection-only Stripe mocks and real native actions. */
@IsTest(SeeAllData=true)
private class StripePauseTimelineServiceTest {
    private static GiftCommitment fresh() {
        return StripePauseTimelineTestDataFactory.createTimeline(false,Date.today().addDays(-1));
    }
    private static GiftCommitment pendingCompensation() {
        GiftCommitment gift=fresh();
        StripePauseTimelinePlanner.Plan plan=StripePauseTimelinePlanner.plan(gift.Id,Date.today(),Date.today().addDays(14),
            StripePauseTimelineSelector.schedules(gift.Id),StripePauseTimelineSelector.transactions(gift.Id));
        plan.version=2;plan.compensationStatus='Active';plan.resumeAtEpoch=StripePauseBusinessClock.resumeEpoch(plan.resumeDate);
        plan.operationKey='synthetic-compensation-status';plan.compensationPauseJson='null';
        plan.snapshotSignature=StripePauseTimelineService.signature(plan);
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;StripePauseService.suppressSubscriptionUpdate=true;
        update new GiftCommitment(Id=gift.Id,Stripe_Pause_State__c='Sync Error',Stripe_Pause_Plan__c=JSON.serialize(plan),
            Stripe_Pause_Attempt_Count__c=1,Pause_Start_Date__c=plan.pauseStartDate,Pause_Resume_Date__c=plan.resumeDate);
        StripePauseService.suppressSubscriptionUpdate=previous;
        return StripePauseTimelineSelector.commitment(gift.Id);
    }
    @IsTest static void laterClosureBlocksStaleCompensationBeforeAnyStripeCall() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=pendingCompensation();
        update new GiftCommitment(Id=gift.Id,Status='Closed',Cancelled_Subscription__c=true,ClosedReason__c='Financial Difficulty');
        CollectionMock mock=new CollectionMock();Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();StripePauseTimelineService.compensate(StripePauseTimelineSelector.commitment(gift.Id));Test.stopTest();
        Assert.areEqual('Closed',[SELECT Status FROM GiftCommitment WHERE Id=:gift.Id].Status);
        Assert.areEqual(0,mock.posts,'Stale compensation must not undo the newer closure.');
        Assert.areEqual(0,mock.gets,'A newer saved Status blocks compensation before callouts.');
    }
    @IsTest static void closureDuringStripeReadBlocksCompensationWrite() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=pendingCompensation();
        CollectionMock mock=new CollectionMock();mock.closeGiftId=gift.Id;mock.closeAtGet=1;
        mock.collection=new Map<String,Object>{'behavior'=>'void','resumes_at'=>StripePauseBusinessClock.resumeEpoch(gift.Pause_Resume_Date__c)};
        Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();StripePauseTimelineService.compensate(gift);Test.stopTest();
        Assert.areEqual('Closed',[SELECT Status FROM GiftCommitment WHERE Id=:gift.Id].Status);
        Assert.areEqual(0,mock.posts,'Status must be rechecked before writing stale collection state.');
    }
    @IsTest static void closureAtFinalReadCannotBeOverwrittenByCapturedStatus() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=pendingCompensation();
        CollectionMock mock=new CollectionMock();mock.closeGiftId=gift.Id;mock.closeAtGet=2;
        mock.collection=new Map<String,Object>{'behavior'=>'void','resumes_at'=>StripePauseBusinessClock.resumeEpoch(gift.Pause_Resume_Date__c)};
        Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();StripePauseTimelineService.compensate(gift);Test.stopTest();
        GiftCommitment saved=[SELECT Status,Stripe_Pause_Last_Error__c FROM GiftCommitment WHERE Id=:gift.Id];
        Assert.areEqual('Closed',saved.Status,'Final lock must preserve the later saved Status.');
        Assert.isTrue(saved.Stripe_Pause_Last_Error__c.startsWith('CONCURRENT_ACTION:'));
        Assert.areEqual(1,mock.posts,'No further Stripe write may follow the newer instruction.');
    }
    @IsTest static void markerArrivingAtMultiScheduleHandoffBlocksSuccess() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=StripePauseTimelineTestDataFactory.createTimeline(true);
        CollectionMock mock=new CollectionMock();mock.markerGiftId=gift.Id;Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();StripePauseResult result=StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(Date.today().addDays(15)));
        Assert.isFalse(result.stripeConfirmed);Assert.areEqual(0,Limits.getQueueableJobs());Test.stopTest();
        GiftCommitment saved=[SELECT Status,Stripe_Pause_State__c,Stripe_Pause_Last_Error__c FROM GiftCommitment WHERE Id=:gift.Id];
        Assert.areEqual('Active',saved.Status);Assert.isNull(saved.Stripe_Pause_State__c);
        Assert.isTrue(saved.Stripe_Pause_Last_Error__c.startsWith('CONCURRENT_ACTION:'));
    }
    @IsTest static void shouldPauseCurrentGapAndManuallyResumeWithoutCatchup() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fresh();
        CollectionMock mock=new CollectionMock();
        Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();
        StripePauseResult paused=StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(Date.today().addDays(14)));
        Assert.areEqual('Paused',paused.salesforceState,paused.message);
        Assert.areEqual(Date.today().addDays(27),paused.nextPaymentDate);
        System.enqueueJob(new ResumeProbe(gift.Id,Date.today().addDays(13)));
        Test.stopTest();
        Assert.areEqual('Resume Scheduled',[SELECT Stripe_Pause_State__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_State__c);
        Assert.areEqual(0,[SELECT COUNT() FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c=:gift.Id]);
    }
    @IsTest static void shouldResumePendingPaidTodayPauseWithoutTouchingExistingGap() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=StripePauseTimelineTestDataFactory.createTimeline(true);
        CollectionMock mock=new CollectionMock();
        Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();
        StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(Date.today().addDays(15)));
        System.enqueueJob(new ResumeProbe(gift.Id,Date.today().addDays(14),'Active'));
        Test.stopTest();
        Assert.isNull([SELECT Stripe_Pause_State__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_State__c,
            'An already-current billing segment is active even though its next invoice is future.');
        Assert.areEqual(4,[SELECT COUNT() FROM GiftCommitmentSchedule WHERE GiftCommitmentId=:gift.Id],'Canceling a pending pause creates no native segment.');
    }
    @IsTest static void shouldCompensateAndRollBackNativeFailure() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fresh();
        CollectionMock mock=new CollectionMock();
        Test.setMock(HttpCalloutMock.class,mock);
        StripePauseTimelineNativeService.failBeforeOperation=0;
        Test.startTest();
        StripePauseResult result=StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(Date.today().addDays(14)));
        Assert.isFalse(result.stripeConfirmed,'No synchronized success after native failure.');
        Assert.areEqual('PAUSE_SYNC_ERROR',result.errorCode);
        Test.stopTest();
        Assert.areEqual('Failed',[SELECT Stripe_Pause_State__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_State__c,
            'Exact prior collection state must be restored by compensation.');
        Assert.areEqual(4,[SELECT COUNT() FROM GiftCommitmentSchedule WHERE GiftCommitmentId=:gift.Id]);
    }
    @IsTest static void shouldRejectFixedWindowBeforeAnyStripeMutation() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fresh();
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;
        StripePauseService.suppressSubscriptionUpdate=true;
        update new GiftCommitment(Id=gift.Id,Recurring_Type__c='Fixed');
        StripePauseService.suppressSubscriptionUpdate=previous;
        CollectionMock mock=new CollectionMock();
        Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();
        try {
            StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(Date.today().addDays(14)));
            Assert.fail('Fixed donation without final evidence must block.');
        } catch(AuraHandledException expected) { Assert.isTrue(expected.getMessage().contains('final installment')); }
        Test.stopTest();
        Assert.areEqual(0,mock.posts);
        Assert.areEqual(0,mock.gets,'Missing fixed-boundary evidence blocks even before reading Stripe.');
    }
    @IsTest static void shouldRejectStripeMismatchOrFailureBeforeNativeChanges() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fresh();
        CollectionMock mock=new CollectionMock(); mock.reject=true;
        Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();
        try { StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(Date.today().addDays(14))); Assert.fail('Stripe rejection must block.'); }
        catch(StripePauseCollectionGateway.CollectionException expected) { Assert.isTrue(expected.getMessage().contains('Stripe')); }
        Test.stopTest();
        Assert.areEqual(4,[SELECT COUNT() FROM GiftCommitmentSchedule WHERE GiftCommitmentId=:gift.Id]);
    }
    @IsTest static void shouldFailClosedOnNewerTimelineEditDuringDeferredPause() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=StripePauseTimelineTestDataFactory.createTimeline(true);
        Test.setMock(HttpCalloutMock.class,new CollectionMock());
        Test.startTest();
        StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(Date.today().addDays(15)));
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;
        StripePauseService.suppressSubscriptionUpdate=true;
        GiftCommitmentSchedule future=[SELECT Id FROM GiftCommitmentSchedule WHERE GiftCommitmentId=:gift.Id AND Type='CreateTransactions' ORDER BY StartDate DESC LIMIT 1];
        delete [SELECT Id FROM GiftTransaction WHERE GiftCommitmentId=:gift.Id AND Status='Unpaid'];
        update new GiftCommitmentSchedule(Id=future.Id,TransactionAmount=57);
        StripePauseService.suppressSubscriptionUpdate=previous;
        try { StripePauseOrchestrator.resume('sub_multi_pause',gift.Id); Assert.fail('Newer future edit must block.'); }
        catch(StripePauseTimelineService.TimelineSyncException expected) { Assert.isTrue(expected.getMessage().contains('changed')); }
        Test.stopTest();
        Assert.areEqual(57,[SELECT TransactionAmount FROM GiftCommitmentSchedule WHERE Id=:future.Id].TransactionAmount);
    }
    @IsTest static void shouldApplyDueWorkerUsingTheSameTimelinePlan() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fresh();
        StripePauseTimelinePlanner.Plan plan=StripePauseTimelinePlanner.plan(gift.Id,Date.today(),Date.today().addDays(14),
            StripePauseTimelineSelector.schedules(gift.Id),StripePauseTimelineSelector.transactions(gift.Id));
        plan.operationKey='synthetic-worker'; plan.compensationPauseJson='null';
        plan.snapshotSignature=StripePauseTimelineService.signature(plan);
        update new GiftCommitment(Id=gift.Id,Stripe_Pause_State__c='Scheduled',Pause_Start_Date__c=plan.pauseStartDate,
            Pause_Resume_Date__c=plan.resumeDate,Pause_Reason__c='Donor Request',Stripe_Pause_Plan__c=JSON.serialize(plan));
        CollectionMock mock=new CollectionMock();
        mock.collection=new Map<String,Object>{'behavior'=>'void','resumes_at'=>StripePauseCollectionGateway.resumeEpoch(plan.resumeDate)};
        Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest(); StripePauseOrchestrator.processDue(gift.Id); Test.stopTest();
        GiftCommitment saved=[SELECT Status,Stripe_Pause_State__c,NextTransactionDate FROM GiftCommitment WHERE Id=:gift.Id];
        Assert.areEqual('Paused',saved.Status);
        Assert.areEqual('Active',saved.Stripe_Pause_State__c);
        Assert.areEqual(Date.today().addDays(27),saved.NextTransactionDate);
        Assert.areEqual(0,mock.posts,'The due worker re-reads Stripe instead of replaying a confirmed pause.');
    }
    @IsTest static void shouldClearResumeScheduledOnlyAtTheRestoredBoundary() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=StripePauseTimelineTestDataFactory.createTimeline(true);
        StripePauseTimelinePlanner.Plan plan=StripePauseTimelinePlanner.plan(gift.Id,Date.today().addDays(1),Date.today().addDays(15),
            StripePauseTimelineSelector.schedules(gift.Id),StripePauseTimelineSelector.transactions(gift.Id));
        plan.nextPaymentDate=Date.today();plan.resuming=true;plan.compensationPauseJson='null';
        plan.snapshotSignature=StripePauseTimelineService.signature(plan);
        update new GiftCommitment(Id=gift.Id,Stripe_Pause_State__c='Resume Scheduled',Stripe_Pause_Plan__c=JSON.serialize(plan));
        Test.setMock(HttpCalloutMock.class,new CollectionMock());
        Test.startTest(); StripePauseOrchestrator.processDue(gift.Id); Test.stopTest();
        Assert.isNull([SELECT Stripe_Pause_State__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_State__c);
    }
    @IsTest static void shouldExposeReconciliationIfCompensationCannotVerify() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fresh();
        CollectionMock mock=new CollectionMock();mock.rejectAfterGet=2;
        Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();
        StripePauseResult result=StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(Date.today().addDays(14)));
        Assert.isFalse(result.stripeConfirmed);
        Test.stopTest();
        Assert.areEqual('Sync Error',[SELECT Stripe_Pause_State__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_State__c);
    }
    @IsTest static void shouldRejectTamperedSnapshotWithoutCallout() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fresh();
        StripePauseTimelinePlanner.Plan plan=StripePauseTimelinePlanner.plan(gift.Id,Date.today(),Date.today().addDays(14),
            StripePauseTimelineSelector.schedules(gift.Id),StripePauseTimelineSelector.transactions(gift.Id));
        plan.snapshotSignature='not-a-server-signature';
        update new GiftCommitment(Id=gift.Id,Stripe_Pause_State__c='Scheduled',Stripe_Pause_Plan__c=JSON.serialize(plan));
        CollectionMock mock=new CollectionMock(); Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();
        try { StripePauseOrchestrator.resume('sub_multi_pause',gift.Id);Assert.fail('Tampered snapshot must block.'); }
        catch(AuraHandledException expected) { Assert.isTrue(expected.getMessage().contains('snapshot changed')); }
        Test.stopTest();Assert.areEqual(0,mock.gets);Assert.areEqual(0,mock.posts);
    }
    @IsTest static void shouldConvergeOnConcurrentIdenticalPauseWithoutCompensation() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=StripePauseTimelineTestDataFactory.createTimeline(true);
        CollectionMock mock=new CollectionMock();mock.winnerGiftId=gift.Id;
        Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();
        StripePauseResult result=StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(Date.today().addDays(15)));
        Assert.isTrue(result.stripeConfirmed,'The duplicate must return the verified winner, not compensate it.');
        Assert.areEqual('Scheduled',result.salesforceState);
        Test.stopTest();
        GiftCommitment saved=[SELECT Stripe_Pause_State__c,Stripe_Pause_Attempt_Count__c,Stripe_Pause_Plan__c FROM GiftCommitment WHERE Id=:gift.Id];
        Assert.areEqual('Scheduled',saved.Stripe_Pause_State__c);
        Assert.areEqual(1,saved.Stripe_Pause_Attempt_Count__c,'A stale duplicate cannot increment or replace the winner.');
        Assert.areEqual(mock.winnerPayload,saved.Stripe_Pause_Plan__c);
    }
    @IsTest static void shouldPreserveNewerConflictingPauseInsteadOfCompensatingIt() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=StripePauseTimelineTestDataFactory.createTimeline(true);
        CollectionMock mock=new CollectionMock();mock.winnerGiftId=gift.Id;mock.conflictingWinner=true;
        Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();
        StripePauseResult result=StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(Date.today().addDays(15)));
        Assert.isFalse(result.stripeConfirmed);
        Assert.areEqual('CONCURRENT_ACTION',result.errorCode);
        Test.stopTest();
        GiftCommitment saved=[SELECT Stripe_Pause_State__c,Stripe_Pause_Attempt_Count__c,Stripe_Pause_Plan__c,Stripe_Pause_Last_Error__c FROM GiftCommitment WHERE Id=:gift.Id];
        Assert.areEqual('Scheduled',saved.Stripe_Pause_State__c,'Never rewrite a newer operator action.');
        Assert.areEqual(1,saved.Stripe_Pause_Attempt_Count__c);
        Assert.areEqual(mock.winnerPayload,saved.Stripe_Pause_Plan__c);
        Assert.isTrue(saved.Stripe_Pause_Last_Error__c.startsWith('CONCURRENT_ACTION:'));
    }
    @IsTest static void shouldResumeDailyOnTomorrowNotRecreateVoidedPaymentToday() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=StripePauseTimelineTestDataFactory.createDailyTimeline();
        Test.setMock(HttpCalloutMock.class,new CollectionMock());
        Test.startTest();
        StripePauseResult pauseResult=StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(Date.today().addDays(5)));
        Assert.areEqual('Paused',pauseResult.salesforceState);
        System.enqueueJob(new ResumeProbe(gift.Id,Date.today().addDays(1)));
        Test.stopTest();
        Assert.areEqual(0,[SELECT COUNT() FROM GiftTransaction WHERE GiftCommitmentId=:gift.Id AND Status='Unpaid' AND TransactionDueDate=TODAY],
            'Manual resume must not recreate today\'s voided installment.');
        Assert.areEqual(Date.today().addDays(1),[SELECT NextTransactionDate FROM GiftCommitment WHERE Id=:gift.Id].NextTransactionDate);
    }
    @IsTest static void shouldCompleteRestoredBoundaryAfterItsLegitimatePayment() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=StripePauseTimelineTestDataFactory.createDailyTimeline();
        StripePauseTimelinePlanner.Plan plan=StripePauseTimelinePlanner.plan(gift.Id,Date.today(),Date.today().addDays(5),
            StripePauseTimelineSelector.schedules(gift.Id),StripePauseTimelineSelector.transactions(gift.Id));
        StripePauseTimelineNativeService.pause(plan);
        // A previously scheduled original-calendar restoration is current before the worker runs.
        plan.nextPaymentDate=Date.today();plan.resuming=true;plan.operationKey='synthetic-restored-boundary';plan.compensationPauseJson='null';
        StripePauseTimelineNativeService.resume(plan,Date.today());
        GiftTransaction installment=[SELECT Id FROM GiftTransaction WHERE GiftCommitmentId=:gift.Id AND Status='Unpaid' AND TransactionDueDate=TODAY LIMIT 1];
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;StripePauseService.suppressSubscriptionUpdate=true;
        update new GiftTransaction(Id=installment.Id,Status='Paid',TransactionDate=Date.today());
        Invocable.Action generation=Invocable.Action.createStandardAction('processGiftCommitment');
        generation.setInvocationParameter('giftCommitmentId',String.valueOf(gift.Id));Assert.isTrue(generation.invoke()[0].isSuccess());
        plan.snapshotSignature=StripePauseTimelineService.signature(plan);
        update new GiftCommitment(Id=gift.Id,Stripe_Pause_State__c='Resume Scheduled',Stripe_Pause_Plan__c=JSON.serialize(plan));
        StripePauseService.suppressSubscriptionUpdate=previous;
        Test.setMock(HttpCalloutMock.class,new CollectionMock());
        Test.startTest();StripePauseOrchestrator.processDue(gift.Id);Test.stopTest();
        Assert.isNull([SELECT Stripe_Pause_State__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_State__c,
            'A genuine payment on the shortened pause\'s restored boundary is not a protected-date conflict.');
        Assert.areEqual('Paid',[SELECT Status FROM GiftTransaction WHERE Id=:installment.Id].Status);
    }
    @IsTest static void shouldPreserveVerifiedFixedFinalBoundaryForValidPause() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fixedTimeline();CollectionMock mock=new CollectionMock();
        mock.cancelAt=StripePauseCollectionGateway.resumeEpoch(Date.today().addDays(57));
        Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();
        StripePauseResult result=StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(Date.today().addDays(15)));
        Test.stopTest();
        Assert.isTrue(result.stripeConfirmed);Assert.areEqual('Scheduled',result.salesforceState);
        Assert.areEqual(Date.today().addDays(28),result.nextPaymentDate);
        Assert.areEqual(Date.today().addDays(56),[SELECT EndDate FROM GiftCommitmentSchedule WHERE GiftCommitmentId=:gift.Id AND Type='CreateTransactions' ORDER BY StartDate DESC LIMIT 1].EndDate);
        Assert.areEqual(0,[SELECT COUNT() FROM Stripe_Subscription_Change__c WHERE Gift_Commitment__c=:gift.Id]);
    }
    @IsTest static void shouldRejectFixedPauseWhenStripeCancelsBeforeResume() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fixedTimeline();CollectionMock mock=new CollectionMock();
        mock.cancelAt=StripePauseCollectionGateway.resumeEpoch(Date.today().addDays(14));
        Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();
        try {
            StripePauseOrchestrator.pause('sub_multi_pause',gift.Id,'Donor Request',String.valueOf(Date.today().addDays(15)));
            Assert.fail('The Stripe cancellation boundary must block before mutation.');
        } catch(AuraHandledException expected) { Assert.isTrue(expected.getMessage().contains('cancel before')); }
        Test.stopTest();
        Assert.areEqual(0,mock.posts);
        Assert.isNull([SELECT Stripe_Pause_State__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_State__c);
    }
    private static GiftCommitment fixedTimeline() {
        GiftCommitment gift=StripePauseTimelineTestDataFactory.createTimeline(true);
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;StripePauseService.suppressSubscriptionUpdate=true;
        update new GiftCommitment(Id=gift.Id,Recurring_Type__c='Fixed');
        GiftCommitmentSchedule future=[SELECT Id FROM GiftCommitmentSchedule WHERE GiftCommitmentId=:gift.Id AND Type='CreateTransactions' ORDER BY StartDate DESC LIMIT 1];
        update new GiftCommitmentSchedule(Id=future.Id,EndDate=Date.today().addDays(56),Number_of_Planned_Installments__c=4);
        StripePauseService.suppressSubscriptionUpdate=previous;
        return gift;
    }
    private class CollectionMock implements HttpCalloutMock {
        Integer posts=0,gets=0;
        Boolean reject=false;
        Integer rejectAfterGet;
        Map<String,Object> collection;
        Id winnerGiftId;
        Id markerGiftId;
        Id closeGiftId;
        Integer closeAtGet;
        Boolean conflictingWinner=false;
        String winnerPayload,writeKey;
        Long cancelAt;
        public HttpResponse respond(HttpRequest request) {
            Assert.isTrue(request.getEndpoint().endsWith('/subscriptions/sub_multi_pause'));
            if(request.getMethod()=='POST') {
                posts++;
                Assert.isNotNull(request.getHeader('Idempotency-Key'));
                String body=request.getBody();
                writeKey=request.getHeader('Idempotency-Key');
                Assert.isTrue(body.startsWith('pause_collection=&') || body.startsWith('pause_collection[behavior]=void&'));
                collection=body.startsWith('pause_collection=&')?null:new Map<String,Object>{'behavior'=>'void',
                    'resumes_at'=>Long.valueOf(body.substringAfter('pause_collection[resumes_at]=').substringBefore('&'))};
            } else {
                gets++;
                if(closeGiftId!=null && gets==closeAtGet)
                    update new GiftCommitment(Id=closeGiftId,Status='Closed',Cancelled_Subscription__c=true,ClosedReason__c='Financial Difficulty');
                if(gets==2 && markerGiftId!=null)
                    update new GiftCommitment(Id=markerGiftId,Stripe_Pause_Last_Error__c='CONCURRENT_ACTION: Synthetic competing request');
                if(gets==2 && winnerGiftId!=null) {
                    StripePauseTimelinePlanner.Plan winner=StripePauseTimelinePlanner.plan(winnerGiftId,Date.today().addDays(1),Date.today().addDays(15),
                        StripePauseTimelineSelector.schedules(winnerGiftId),StripePauseTimelineSelector.transactions(winnerGiftId));
                    winner.operationKey=writeKey.substringBeforeLast('-pause')+(conflictingWinner?'-newer':'');
                    winner.compensationPauseJson='null';
                    winner.snapshotSignature=StripePauseTimelineService.signature(winner);
                    winnerPayload=JSON.serialize(winner);
                    update new GiftCommitment(Id=winnerGiftId,Stripe_Pause_State__c='Scheduled',Stripe_Pause_Attempt_Count__c=1,
                        Pause_Start_Date__c=winner.pauseStartDate,Pause_Resume_Date__c=winner.resumeDate,
                        Pause_Reason__c='Donor Request',Stripe_Pause_Plan__c=winnerPayload);
                }
            }
            HttpResponse response=new HttpResponse(); response.setStatusCode(reject || (rejectAfterGet!=null && gets>=rejectAfterGet)?400:200);
            response.setBody(JSON.serialize(new Map<String,Object>{'id'=>'sub_multi_pause','livemode'=>false,
                'status'=>'active','pause_collection'=>collection,'cancel_at'=>cancelAt}));
            return response;
        }
    }
    private class ResumeProbe implements Queueable,Database.AllowsCallouts {
        Id giftId; Date expectedDate; String expectedState;
        ResumeProbe(Id giftId,Date expectedDate) { this(giftId,expectedDate,'Resume Scheduled'); }
        ResumeProbe(Id giftId,Date expectedDate,String expectedState) {
            this.giftId=giftId;this.expectedDate=expectedDate;this.expectedState=expectedState;
        }
        public void execute(QueueableContext context) {
            StripePauseResult result=StripePauseOrchestrator.resume('sub_multi_pause',giftId);
            Assert.areEqual(expectedState,result.salesforceState,result.message);
            Assert.areEqual(expectedDate,result.nextPaymentDate,'No catch-up payment on the resume date.');
        }
    }
}