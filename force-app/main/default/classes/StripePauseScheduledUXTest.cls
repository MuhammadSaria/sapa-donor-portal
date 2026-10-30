/** Scheduled paid-today contract; synthetic records roll back and Stripe calls are mocked. */
@IsTest(SeeAllData=true)
private class StripePauseScheduledUXTest {
    @IsTest static void shouldReturnExactScheduledDateAndClearPaidTodayWarning() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fixture(true);
        PauseMock mock=new PauseMock();Test.setMock(HttpCalloutMock.class,mock);
        Date resume=StripePauseBusinessClock.today().addDays(10);
        Test.startTest();
        StripePauseResult result=StripePauseOrchestrator.pauseConfirmed('sub_scheduled_ux',gift.Id,'Donor Request',String.valueOf(resume),
            String.valueOf(StripePauseBusinessClock.today()),String.valueOf(StripePauseBusinessClock.today().addDays(1)),true);
        Test.stopTest();
        Assert.areEqual('Scheduled',result.salesforceState,'Paid-today pause must use the supported deferred native path.');
        Assert.areEqual(StripePauseBusinessClock.today().addDays(1),result.pauseStartDate,'Return the exact date needed by confirmation and toast.');
        Assert.isTrue(result.message.contains('America/Los_Angeles'),'The confirmation must name the business timezone.');
        Assert.isTrue(result.message.contains(String.valueOf(StripePauseBusinessClock.today().addDays(1))),'The warning must show the actual native start date.');
        GiftCommitment saved=[SELECT Status,Stripe_Pause_State__c,Pause_Start_Date__c,Pause_Resume_Date__c,Pause_Reason__c FROM GiftCommitment WHERE Id=:gift.Id];
        Assert.areEqual('Active',saved.Status,'Do not falsify native Status or bypass the platform validation.');
        Assert.areEqual('Scheduled',saved.Stripe_Pause_State__c);
        Assert.areEqual('Donor Request',saved.Pause_Reason__c);Assert.areEqual(resume,saved.Pause_Resume_Date__c);
        Assert.areEqual(50,[SELECT OriginalAmount FROM GiftTransaction WHERE GiftCommitmentId=:gift.Id AND Status='Paid'].OriginalAmount);
        Assert.areEqual(50,[SELECT Payment_Amount__c FROM Payment__c WHERE Recurring_Donation__c=:gift.Id AND Paid__c=true].Payment_Amount__c);
    }
    @IsTest static void shouldResumeCollectionAtLosAngelesMidnightForNewPause() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fixture(true);PauseMock mock=new PauseMock();Test.setMock(HttpCalloutMock.class,mock);
        Date resume=StripePauseBusinessClock.today().addDays(10);
        DateTime expected=DateTime.newInstanceGmt(resume,Time.newInstance(0,0,0,0));
        TimeZone zone=TimeZone.getTimeZone('America/Los_Angeles');
        expected=expected.addSeconds(-zone.getOffset(expected)/1000);
        Test.startTest();StripePauseOrchestrator.pause('sub_scheduled_ux',gift.Id,'Donor Request',String.valueOf(resume));Test.stopTest();
        Assert.areEqual(expected.getTime()/1000,mock.epoch,'New pause must use Los Angeles midnight, not UTC noon.');
        Assert.areEqual(expected,[SELECT Stripe_Pause_Resume_At__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_Resume_At__c);
    }
    @IsTest static void previewIsReadOnlyAndUsesThePaidDate() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fixture(true);
        Integer transactions=[SELECT COUNT() FROM GiftTransaction WHERE GiftCommitmentId=:gift.Id];
        Integer schedules=[SELECT COUNT() FROM GiftCommitmentSchedule WHERE GiftCommitmentId=:gift.Id];
        StripePausePreview preview=StripePauseOrchestrator.previewPause('sub_scheduled_ux',gift.Id);
        Assert.isTrue(preview.paidToday);Assert.areEqual(StripePauseBusinessClock.today().addDays(1),preview.pauseStartDate);
        Assert.areEqual('America/Los_Angeles',preview.timeZone);
        Assert.areEqual(transactions,[SELECT COUNT() FROM GiftTransaction WHERE GiftCommitmentId=:gift.Id]);
        Assert.areEqual(schedules,[SELECT COUNT() FROM GiftCommitmentSchedule WHERE GiftCommitmentId=:gift.Id]);
        Assert.isNull([SELECT Stripe_Pause_State__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_State__c);
    }
    @IsTest static void unpaidPreviewStartsTodayAndRejectsAnotherSubscription() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fixture(false);
        StripePausePreview preview=StripePauseOrchestrator.previewPause('sub_scheduled_ux',gift.Id);
        Assert.isFalse(preview.paidToday);Assert.areEqual(StripePauseBusinessClock.today(),preview.pauseStartDate);
        try {StripePauseOrchestrator.previewPause('sub_other',gift.Id);Assert.fail('Mismatched subscriptions must fail before any callout.');}
        catch(AuraHandledException expected) {Assert.isTrue(expected.getMessage().contains('does not match'));}
    }
    @IsTest static void tomorrowResumeIsBlockedBeforeStripe() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fixture(true);
        try {StripePauseOrchestrator.pause('sub_scheduled_ux',gift.Id,'Donor Request',String.valueOf(StripePauseBusinessClock.today().addDays(1)));
            Assert.fail('A resume date on the scheduled pause date must be rejected.');}
        catch(AuraHandledException expected) {Assert.isTrue(expected.getMessage().contains('pause start'));}
        Assert.isNull([SELECT Stripe_Pause_State__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_State__c);
    }
    @IsTest static void staleCompensationCannotChangeANewerInstruction() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fixture(false);
        update new GiftCommitment(Id=gift.Id,Stripe_Pause_State__c='Sync Error',Stripe_Pause_Attempt_Count__c=5);
        StripePauseOrchestrator.compensate(gift.Id,false,4);
        Assert.areEqual(5,[SELECT Stripe_Pause_Attempt_Count__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_Attempt_Count__c);
        Assert.areEqual('Sync Error',[SELECT Stripe_Pause_State__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_State__c);
    }
    @IsTest static void legacyQueuedCompensationCannotTouchANewTimestampRequest() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fixture(false);
        update new GiftCommitment(Id=gift.Id,Stripe_Pause_State__c='Sync Error',Stripe_Pause_Attempt_Count__c=5,
            Stripe_Pause_Resume_At__c=StripePauseBusinessClock.resumeAt(StripePauseBusinessClock.today().addDays(10)));
        StripePauseOrchestrator.compensate(gift.Id,false);
        Assert.areEqual('Sync Error',[SELECT Stripe_Pause_State__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_State__c);
    }
    @IsTest static void newerInstructionWinsAndRequiresReconciliationWithoutCompensation() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fixture(true);PauseMock mock=new PauseMock();mock.supersedeId=gift.Id;Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();
        StripePauseResult result=StripePauseOrchestrator.pause('sub_scheduled_ux',gift.Id,'Donor Request',String.valueOf(StripePauseBusinessClock.today().addDays(10)));
        Assert.isFalse(result.stripeConfirmed);Assert.areEqual(0,Limits.getQueueableJobs());
        Test.stopTest();
        GiftCommitment winner=[SELECT Status,Stripe_Pause_State__c,Pause_Resume_Date__c,Stripe_Pause_Last_Error__c FROM GiftCommitment WHERE Id=:gift.Id];
        Assert.areEqual('Active',winner.Status);Assert.areEqual('Scheduled',winner.Stripe_Pause_State__c);
        Assert.areEqual(StripePauseBusinessClock.today().addDays(20),winner.Pause_Resume_Date__c);
        Assert.isTrue(winner.Stripe_Pause_Last_Error__c.startsWith('CONCURRENT_ACTION:'));
    }
    @IsTest static void markerArrivingDuringHandoffCannotBeClearedBySuccess() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fixture(true);PauseMock mock=new PauseMock();mock.supersedeId=gift.Id;mock.markerOnly=true;Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();StripePauseResult result=StripePauseOrchestrator.pause('sub_scheduled_ux',gift.Id,'Donor Request',String.valueOf(StripePauseBusinessClock.today().addDays(10)));
        Assert.isFalse(result.stripeConfirmed);Assert.areEqual(0,Limits.getQueueableJobs());Test.stopTest();
        GiftCommitment saved=[SELECT Stripe_Pause_State__c,Stripe_Pause_Last_Error__c FROM GiftCommitment WHERE Id=:gift.Id];
        Assert.isNull(saved.Stripe_Pause_State__c);Assert.isTrue(saved.Stripe_Pause_Last_Error__c.startsWith('CONCURRENT_ACTION:'));
    }
    @IsTest static void compensationVerificationFailurePreservesNewerInstructionAndMarker() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fixture(false);Date resume=StripePauseBusinessClock.today().addDays(10);
        update new GiftCommitment(Id=gift.Id,Stripe_Pause_State__c='Sync Error',Stripe_Pause_Attempt_Count__c=1,
            Pause_Start_Date__c=StripePauseBusinessClock.today(),Pause_Resume_Date__c=resume,
            Stripe_Pause_Resume_At__c=StripePauseBusinessClock.resumeAt(resume));
        PauseMock mock=new PauseMock();mock.paused=true;mock.epoch=StripePauseBusinessClock.resumeEpoch(resume);
        mock.supersedeId=gift.Id;mock.rejectAfterGet=2;Test.setMock(HttpCalloutMock.class,mock);
        Test.startTest();StripePauseOrchestrator.compensate(gift.Id,false,1);Test.stopTest();
        GiftCommitment winner=[SELECT Stripe_Pause_State__c,Stripe_Pause_Attempt_Count__c,Stripe_Pause_Last_Error__c FROM GiftCommitment WHERE Id=:gift.Id];
        Assert.areEqual('Scheduled',winner.Stripe_Pause_State__c);Assert.areEqual(5,winner.Stripe_Pause_Attempt_Count__c);
        Assert.isTrue(winner.Stripe_Pause_Last_Error__c.startsWith('CONCURRENT_ACTION:'));
    }
    @IsTest static void changedPaidStateRequiresNewConfirmationBeforeAnyStripeCall() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fixture(false);
        StripePausePreview preview=StripePauseOrchestrator.previewPause('sub_scheduled_ux',gift.Id);
        Id schedule=[SELECT Id FROM GiftCommitmentSchedule WHERE GiftCommitmentId=:gift.Id LIMIT 1].Id;
        insert new GiftTransaction(Name='Payment arrived during confirmation',DonorId=gift.DonorId,GiftCommitmentId=gift.Id,
            GiftCommitmentScheduleId=schedule,Status='Paid',OriginalAmount=50,TransactionDate=StripePauseBusinessClock.today(),
            TransactionDueDate=StripePauseBusinessClock.today(),PaymentMethod='Credit Card');
        Test.startTest();
        try {StripePauseOrchestrator.pauseConfirmed('sub_scheduled_ux',gift.Id,'Donor Request',String.valueOf(StripePauseBusinessClock.today().addDays(10)),
            String.valueOf(preview.businessDate),String.valueOf(preview.pauseStartDate),preview.paidToday);Assert.fail('Changed confirmation must block before callouts.');}
        catch(AuraHandledException expected) {Assert.isTrue(expected.getMessage().contains('changed since confirmation'));}
        Test.stopTest();Assert.isNull([SELECT Stripe_Pause_State__c FROM GiftCommitment WHERE Id=:gift.Id].Stripe_Pause_State__c);
    }
    @IsTest static void realNativeHandoffAfterPaidDayPreservesPaymentAndParentStatus() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gift=fixture(true,StripePauseBusinessClock.today().addDays(-1));
        GiftTransaction before=[SELECT Id,Status,OriginalAmount,TransactionDate,TransactionDueDate,GiftCommitmentScheduleId FROM GiftTransaction WHERE GiftCommitmentId=:gift.Id AND Status='Paid'];
        Payment__c payment=[SELECT Id,Donation__c,Recurring_Donation__c,Payment_Amount__c,Paid__c,Payment_Date__c FROM Payment__c WHERE Recurring_Donation__c=:gift.Id];
        Id source=before.GiftCommitmentScheduleId;
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;StripePauseService.suppressSubscriptionUpdate=true;
        try {
            StripePauseOrchestrator.nativePauseSchedule(source,StripePauseBusinessClock.today(),StripePauseBusinessClock.today().addDays(9));
            update new GiftCommitment(Id=gift.Id,Status='Paused');
        } finally {StripePauseService.suppressSubscriptionUpdate=previous;}
        Assert.areEqual('Paused',[SELECT Status FROM GiftCommitment WHERE Id=:gift.Id].Status);
        Assert.areEqual(before,[SELECT Id,Status,OriginalAmount,TransactionDate,TransactionDueDate,GiftCommitmentScheduleId FROM GiftTransaction WHERE Id=:before.Id]);
        Assert.areEqual(payment,[SELECT Id,Donation__c,Recurring_Donation__c,Payment_Amount__c,Paid__c,Payment_Date__c FROM Payment__c WHERE Id=:payment.Id]);
    }
    private static GiftCommitment fixture(Boolean paidToday) {
        return fixture(paidToday,StripePauseBusinessClock.today());
    }
    private static GiftCommitment fixture(Boolean paidToday,Date paidDate) {
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;StripePauseService.suppressSubscriptionUpdate=true;
        try {
            GiftCommitment gift=StripeRecurringScheduleTestDataFactory.createCommitment('sub_scheduled_ux','Open');
            update new GiftCommitment(Id=gift.Id,ScheduleType='Recurring');
            GiftCommitmentSchedule source=new GiftCommitmentSchedule(GiftCommitmentId=gift.Id,Type='CreateTransactions',
                StartDate=StripePauseBusinessClock.today().addDays(-1),TransactionAmount=50,TransactionPeriod='Monthly',TransactionInterval=1,
                TransactionDay='2',PaymentMethod='Credit Card');insert source;
            if(paidToday) {
                GiftTransaction transactionRecord=new GiftTransaction(Name='Scheduled UX protected USD50',DonorId=gift.DonorId,
                    GiftCommitmentId=gift.Id,GiftCommitmentScheduleId=source.Id,Status='Unpaid',OriginalAmount=50,
                    TransactionDate=paidDate,TransactionDueDate=paidDate,PaymentMethod='Credit Card');insert transactionRecord;
                insert new Payment__c(Donation__c=transactionRecord.Id,Recurring_Donation__c=gift.Id,donorId__c=gift.DonorId,
                    Payment_Amount__c=50,Paid__c=true,Payment_Status__c='Paid',Payment_Date__c=paidDate,
                    Payment_Method__c='Credit Card',Transaction_Id__c='synthetic-scheduled-ux');
            }
            return gift;
        } finally {StripePauseService.suppressSubscriptionUpdate=previous;}
    }
    private class PauseMock implements HttpCalloutMock {
        Long epoch;Boolean paused=false;Id supersedeId;Integer gets=0;Boolean markerOnly=false;Integer rejectAfterGet;
        public HttpResponse respond(HttpRequest request) {
            Assert.isTrue(request.getEndpoint().endsWith('/subscriptions/sub_scheduled_ux'),'Only the mocked synthetic subscription is allowed.');
            if(request.getMethod()=='POST') {
                paused=request.getBody()!='pause_collection=';
                if(paused) epoch=Long.valueOf(request.getBody().substringAfter('pause_collection[resumes_at]=').substringBefore('&'));
            }
            if(request.getMethod()=='GET' && ++gets==2 && supersedeId!=null) {
                if(markerOnly) update new GiftCommitment(Id=supersedeId,Stripe_Pause_Last_Error__c='CONCURRENT_ACTION: Synthetic competing request');
                else update new GiftCommitment(Id=supersedeId,Stripe_Pause_State__c='Scheduled',Stripe_Pause_Attempt_Count__c=5,
                    Pause_Start_Date__c=StripePauseBusinessClock.today().addDays(1),Pause_Resume_Date__c=StripePauseBusinessClock.today().addDays(20));
            }
            HttpResponse response=new HttpResponse();response.setStatusCode(rejectAfterGet!=null && gets>=rejectAfterGet?400:200);
            response.setBody(JSON.serialize(new Map<String,Object>{'id'=>'sub_scheduled_ux','livemode'=>false,'status'=>'active',
                'pause_collection'=>paused?new Map<String,Object>{'behavior'=>'void','resumes_at'=>epoch}:null}));return response;
        }
    }
}