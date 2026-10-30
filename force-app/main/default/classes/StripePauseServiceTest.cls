@IsTest
private class StripePauseServiceTest {
    @TestSetup
    static void setup() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        Account donor = new Account(LastName = 'Pause scenario donor');
        insert donor;
        GiftCommitment commitment = new GiftCommitment(
            Name = 'Pause scenario recurring gift', DonorId = donor.Id,
            Status = 'Active', Subscription_Id__c = 'sub_test_pause_123'
        );
        insert commitment;
        insert new GiftCommitmentSchedule(
            GiftCommitmentId = commitment.Id, Type = 'CreateTransactions',
            StartDate = Date.today(), TransactionAmount = 2,
            TransactionPeriod = 'Monthly', TransactionInterval = 1,
            TransactionDay = String.valueOf(Date.today().day()),
            PaymentMethod = 'Credit Card'
        );
        StripePauseService.suppressSubscriptionUpdate = true;
        GiftCommitment fixedCommitment = new GiftCommitment(
            Name = 'Fixed pause boundary donation', DonorId = donor.Id,
            Status = 'Active', Recurring_Type__c = 'Fixed',
            Subscription_Id__c = 'sub_test_pause_123'
        );
        insert fixedCommitment;
        insert new GiftCommitmentSchedule(
            GiftCommitmentId = fixedCommitment.Id, Type = 'CreateTransactions',
            StartDate = Date.today(), EndDate = Date.today().addDays(4),
            TransactionAmount = 2, TransactionPeriod = 'Daily',
            TransactionInterval = 1, PaymentMethod = 'Credit Card', Number_of_Planned_Installments__c = 5
        );
        StripePauseService.suppressSubscriptionUpdate = false;
    }

    private static GiftCommitment gift() {
        return [SELECT Id, DonorId, Status, Pause_Start_Date__c, Pause_Resume_Date__c,
                       Stripe_Pause_State__c, Stripe_Pause_Last_Error__c
                FROM GiftCommitment WHERE Name = 'Pause scenario recurring gift' LIMIT 1];
    }

    private static Date resumeDate() { return Date.today().addDays(7); }

    @IsTest
    static void fixedPauseRejectsResumeAfterFinalInstallmentBeforeStripe() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [
            SELECT Id, Recurring_Type__c, Stripe_Pause_State__c
            FROM GiftCommitment WHERE Name = 'Fixed pause boundary donation' LIMIT 1
        ];
        GiftCommitmentSchedule schedule = [
            SELECT Id, Final_Payment_Date__c FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1
        ];
        Date finalDate = Date.today().addDays(4);
        System.assertEquals(finalDate, schedule.Final_Payment_Date__c);
        MockStripe mock = new MockStripe();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        try {
            System.runAs(new User(Id = UserInfo.getUserId())) {
                StripePauseOrchestrator.pause('sub_test_pause_123', commitment.Id,
                    'Donor Request', String.valueOf(finalDate.addDays(2)));
            }
            System.assert(false, 'A Fixed donation cannot resume after its final installment.');
        } catch (AuraHandledException expected) {
            System.assert(expected.getMessage().contains('final installment'), expected.getMessage());
        }
        Test.stopTest();
        System.assertEquals(0, mock.pausePosts);
        System.assertEquals(null, [SELECT Stripe_Pause_State__c FROM GiftCommitment
            WHERE Id = :commitment.Id].Stripe_Pause_State__c);
        System.assertEquals('CreateTransactions', [
            SELECT Type FROM GiftCommitmentSchedule WHERE Id = :schedule.Id
        ].Type);
    }

    @IsTest
    static void fixedPauseAllowsResumeBeforeFinalInstallment() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [
            SELECT Id FROM GiftCommitment WHERE Name = 'Fixed pause boundary donation' LIMIT 1
        ];
        MockStripe mock = new MockStripe();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        StripePauseResult result = StripePauseOrchestrator.pause(
            'sub_test_pause_123', commitment.Id, 'Donor Request',
            String.valueOf(Date.today().addDays(2)));
        Test.stopTest();
        System.assertEquals(true, result.stripeConfirmed);
        System.assertEquals(1, mock.pausePosts);
    }

    @IsTest
    static void deferredFixedPauseRechecksShortenedFinalDate() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [SELECT Id FROM GiftCommitment
            WHERE Name = 'Fixed pause boundary donation' LIMIT 1];
        GiftCommitmentSchedule schedule = [SELECT Id FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1];
        Date originallyValidResume = Date.today().addDays(3);
        StripePauseService.suppressSubscriptionUpdate = true;
        update new GiftCommitment(Id = commitment.Id,
            Stripe_Pause_State__c = 'Scheduled', Pause_Start_Date__c = Date.today(),
            Pause_Resume_Date__c = originallyValidResume, Pause_Reason__c = 'Other');
        update new GiftCommitmentSchedule(Id = schedule.Id, EndDate = Date.today().addDays(1), Number_of_Planned_Installments__c = 2);
        StripePauseService.suppressSubscriptionUpdate = false;
        MockStripe mock = new MockStripe();
        mock.paused = true;
        mock.resumeEpoch = DateTime.newInstanceGmt(originallyValidResume.year(),
            originallyValidResume.month(), originallyValidResume.day(), 12, 0, 0).getTime() / 1000;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        StripePauseOrchestrator.processDue(commitment.Id);
        GiftCommitment beforeCompensation = [SELECT Stripe_Pause_Last_Error__c
            FROM GiftCommitment WHERE Id = :commitment.Id];
        System.assert(beforeCompensation.Stripe_Pause_Last_Error__c.contains('final installment'),
            beforeCompensation.Stripe_Pause_Last_Error__c);
        Test.stopTest();

        System.assertEquals(0, mock.pausePosts);
        System.assertEquals(0, [SELECT COUNT() FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id AND Type = 'PauseTransactions']);
        GiftCommitment after = [SELECT Stripe_Pause_State__c, Stripe_Pause_Last_Error__c
            FROM GiftCommitment WHERE Id = :commitment.Id];
        System.assertEquals('Failed', after.Stripe_Pause_State__c);
    }

    @IsTest
    static void noPaidPaymentNativePauseAndVerifiedStripeState() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        Integer requestsBefore = [SELECT COUNT() FROM Stripe_Subscription_Change__c
                                  WHERE Gift_Commitment__c = :commitment.Id];
        MockStripe mock = new MockStripe();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        StripePauseResult result = StripePauseOrchestrator.pause(
            'sub_test_pause_123', commitment.Id, 'Donor Request', String.valueOf(resumeDate()));
        Test.stopTest();
        System.assertEquals(true, result.stripeConfirmed);
        System.assertEquals('Paused', result.salesforceState);
        commitment = gift();
        System.assertEquals('Paused', commitment.Status);
        System.assertEquals('Active', commitment.Stripe_Pause_State__c);
        System.assertEquals(resumeDate(), commitment.Pause_Resume_Date__c);
        System.assertEquals('PauseTransactions',
            [SELECT Type FROM GiftCommitmentSchedule WHERE GiftCommitmentId = :commitment.Id LIMIT 1].Type);
        System.assertEquals(1, mock.pausePosts, 'Only one Stripe mutation is allowed.');
        System.assertEquals(requestsBefore, [SELECT COUNT() FROM Stripe_Subscription_Change__c
                                WHERE Gift_Commitment__c = :commitment.Id],
            'Native pause must not enqueue a recurring terms request.');
    }

    @IsTest
    static void paidTodayStopsStripeAndDefersSalesforcePause() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        GiftCommitmentSchedule schedule = [SELECT Id FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1];
        GiftTransaction paid = new GiftTransaction(
            Name = 'Protected paid installment', DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id, GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid', OriginalAmount = 2, TransactionDate = Date.today(),
            TransactionDueDate = Date.today(), PaymentMethod = 'Credit Card'
        );
        insert paid;
        MockStripe mock = new MockStripe();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        StripePauseResult result = StripePauseOrchestrator.pause(
            'sub_test_pause_123', commitment.Id, 'Donor Request', String.valueOf(resumeDate()));
        Test.stopTest();
        System.assertEquals(true, result.stripeConfirmed);
        System.assertEquals('Scheduled', result.salesforceState,
            'Today\'s protected payment must not force parent Status Paused.');
        commitment = gift();
        System.assertEquals('Active', commitment.Status);
        System.assertEquals('Scheduled', commitment.Stripe_Pause_State__c);
        System.assertEquals(Date.today().addDays(1), commitment.Pause_Start_Date__c);
        System.assertEquals('Paid', [SELECT Status FROM GiftTransaction WHERE Id = :paid.Id].Status);
        System.assertEquals('CreateTransactions',
            [SELECT Type FROM GiftCommitmentSchedule WHERE Id = :schedule.Id].Type);
        System.assertEquals(1, mock.pausePosts);
    }

    @IsTest
    static void paidTodayRequiresResumeAfterDeferredStart() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        GiftCommitmentSchedule schedule = [SELECT Id FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1];
        insert new GiftTransaction(Name = 'Paid today', DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id, GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid', OriginalAmount = 2, TransactionDate = Date.today(),
            TransactionDueDate = Date.today(), PaymentMethod = 'Credit Card');
        MockStripe mock = new MockStripe();
        Test.setMock(HttpCalloutMock.class, mock);
        try {
            StripePauseOrchestrator.pause('sub_test_pause_123', commitment.Id, 'Donor Request',
                String.valueOf(Date.today().addDays(1)));
            System.assert(false, 'Resume on the pause start date must be rejected.');
        } catch (AuraHandledException expected) {
            System.assert(expected.getMessage().contains('after'));
        }
        System.assertEquals(0, mock.pausePosts);
    }

    @IsTest
    static void stripeRejectionLeavesSalesforceUntouched() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        MockStripe mock = new MockStripe();
        mock.rejectPause = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        try {
            StripePauseOrchestrator.pause('sub_test_pause_123', commitment.Id, 'Other',
                String.valueOf(resumeDate()));
            System.assert(false, 'Stripe rejection must be reported.');
        } catch (AuraHandledException expected) {
            System.assert(expected.getMessage().contains('Stripe pause failed'));
        }
        Test.stopTest();
        commitment = gift();
        System.assertEquals('Active', commitment.Status);
        System.assertEquals(null, commitment.Stripe_Pause_State__c);
    }

    @IsTest
    static void paidFutureTransactionBlocksBeforeStripe() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        GiftCommitmentSchedule schedule = [SELECT Id FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1];
        insert new GiftTransaction(Name = 'Protected future payment', DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id, GiftCommitmentScheduleId = schedule.Id,
            Status = 'Paid', OriginalAmount = 2, TransactionDate = Date.today().addDays(2),
            TransactionDueDate = Date.today().addDays(2), PaymentMethod = 'Credit Card');
        MockStripe mock = new MockStripe();
        Test.setMock(HttpCalloutMock.class, mock);
        try {
            StripePauseOrchestrator.pause('sub_test_pause_123', commitment.Id,
                'Other', String.valueOf(resumeDate()));
            System.assert(false, 'Future paid payment must be protected.');
        } catch (AuraHandledException expected) {
            System.assert(expected.getMessage().contains('paid transaction'));
        }
        System.assertEquals(0, mock.pausePosts);
    }

    @IsTest
    static void lostResponseHasClearMessageAndNoSalesforceMutation() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        MockStripe mock = new MockStripe();
        mock.timeoutOnPause = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        try {
            StripePauseOrchestrator.pause('sub_test_pause_123', commitment.Id,
                'Other', String.valueOf(resumeDate()));
            System.assert(false, 'A lost Stripe response cannot be reported as success.');
        } catch (AuraHandledException expected) {
            System.assert(expected.getMessage().contains('did not confirm'));
        }
        Test.stopTest();
        System.assertEquals('Active', gift().Status);
        System.assertEquals(null, gift().Stripe_Pause_State__c);
    }

    @IsTest
    static void nativeFailureReturnsReconciliationAndCompensates() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        MockStripe mock = new MockStripe();
        Test.setMock(HttpCalloutMock.class, mock);
        StripePauseOrchestrator.forceNativeFailure = true;
        Test.startTest();
        StripePauseResult result = StripePauseOrchestrator.pause(
            'sub_test_pause_123', commitment.Id, 'Other', String.valueOf(resumeDate()));
        System.assertEquals(false, result.stripeConfirmed);
        System.assertEquals('Reconciliation Required', result.salesforceState);
        System.assertEquals('Sync Error', gift().Stripe_Pause_State__c);
        Test.stopTest();
        System.assertEquals('Active', gift().Status);
        System.assertEquals('Failed', gift().Stripe_Pause_State__c,
            'Verified compensation leaves a reviewable failed attempt.');
    }

    @IsTest
    static void manualResumeVerifiesBothSystems() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        GiftCommitmentSchedule schedule = [SELECT Id FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1];
        update new GiftCommitmentSchedule(Id = schedule.Id, Type = 'PauseTransactions');
        update new GiftCommitment(Id = commitment.Id, Status = 'Paused',
            Pause_Start_Date__c = Date.today(), Pause_Resume_Date__c = resumeDate(),
            Stripe_Pause_State__c = 'Active', Pause_Reason__c = 'Other');
        MockStripe mock = new MockStripe();
        mock.paused = true;
        mock.resumeEpoch = DateTime.newInstanceGmt(resumeDate().year(), resumeDate().month(),
            resumeDate().day(), 12, 0, 0).getTime() / 1000;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        StripePauseResult result = StripePauseOrchestrator.resume(
            'sub_test_pause_123', commitment.Id);
        Test.stopTest();
        System.assertEquals(true, result.stripeConfirmed);
        System.assertEquals('Active', result.salesforceState);
        System.assertEquals('Active', gift().Status);
        System.assertEquals(null, gift().Stripe_Pause_State__c);
        System.assertEquals(null, gift().Pause_Resume_Date__c);
        System.assertEquals(1, mock.resumePosts);
    }

    @IsTest
    static void matchingExistingStripePauseIsSafeLostResponseRetry() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        MockStripe mock = new MockStripe();
        mock.paused = true;
        mock.resumeEpoch = StripePauseBusinessClock.resumeEpoch(resumeDate());
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        StripePauseResult result = StripePauseOrchestrator.pause(
            'sub_test_pause_123', commitment.Id, 'Other', String.valueOf(resumeDate()));
        Test.stopTest();
        System.assertEquals(true, result.stripeConfirmed);
        System.assertEquals(0, mock.pausePosts, 'A lost response must not cause a second mutation.');
    }

    @IsTest
    static void duplicatePauseIsRejectedBeforeSecondStripeMutation() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        MockStripe mock = new MockStripe();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        StripePauseOrchestrator.pause('sub_test_pause_123', commitment.Id,
            'Other', String.valueOf(resumeDate()));
        try {
            StripePauseOrchestrator.pause('sub_test_pause_123', commitment.Id,
                'Other', String.valueOf(resumeDate()));
            System.assert(false, 'Duplicate click must be refused.');
        } catch (AuraHandledException expected) {
            System.assert(expected.getMessage().contains('not eligible'));
        }
        Test.stopTest();
        System.assertEquals(1, mock.pausePosts);
    }

    @IsTest
    static void legacyBooleanPauseFacadeUsesVerifiedResult() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        MockStripe mock = new MockStripe();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        Boolean confirmed = StripePauseService.pauseSubscription('sub_test_pause_123',
            commitment.Id, 'Other', String.valueOf(resumeDate()));
        Test.stopTest();
        System.assertEquals(true, confirmed);
        System.assertEquals('Paused', gift().Status);
    }

    @IsTest
    static void legacyBooleanResumeFacadeUsesVerifiedResult() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        GiftCommitmentSchedule schedule = [SELECT Id FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1];
        update new GiftCommitmentSchedule(Id = schedule.Id, Type = 'PauseTransactions');
        update new GiftCommitment(Id = commitment.Id, Status = 'Paused',
            Pause_Start_Date__c = Date.today(), Pause_Resume_Date__c = resumeDate(),
            Stripe_Pause_State__c = 'Active');
        MockStripe mock = new MockStripe();
        mock.paused = true;
        mock.resumeEpoch = DateTime.newInstanceGmt(resumeDate().year(), resumeDate().month(),
            resumeDate().day(), 12, 0, 0).getTime() / 1000;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        Boolean confirmed = StripePauseService.resumeSubscription('sub_test_pause_123', commitment.Id);
        Test.stopTest();
        System.assertEquals(true, confirmed);
        System.assertEquals('Active', gift().Status);
    }

    @IsTest
    static void dueWorkerActivatesDeferredNativePause() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        Date startDate = Date.today();
        update new GiftCommitment(Id = commitment.Id, Stripe_Pause_State__c = 'Scheduled',
            Pause_Start_Date__c = startDate, Pause_Resume_Date__c = resumeDate(),
            Pause_Reason__c = 'Other');
        MockStripe mock = new MockStripe();
        mock.paused = true;
        mock.resumeEpoch = DateTime.newInstanceGmt(resumeDate().year(), resumeDate().month(),
            resumeDate().day(), 12, 0, 0).getTime() / 1000;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        new StripePauseWorker().execute((SchedulableContext)null);
        Test.stopTest();
        System.assertEquals('Paused', gift().Status);
        System.assertEquals('Active', gift().Stripe_Pause_State__c);
    }

    @IsTest
    static void dueWorkerAutomaticallyRestoresSalesforceAfterStripeResume() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        GiftCommitmentSchedule schedule = [SELECT Id FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1];
        update new GiftCommitmentSchedule(Id = schedule.Id, Type = 'PauseTransactions',
            StartDate = Date.today().addDays(-1), EndDate = Date.today().addDays(-1));
        update new GiftCommitment(Id = commitment.Id, Status = 'Active',
            Stripe_Pause_State__c = 'Active', Pause_Start_Date__c = Date.today().addDays(-1),
            Pause_Resume_Date__c = Date.today(), Pause_Reason__c = 'Other');
        MockStripe mock = new MockStripe();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        Database.executeBatch(new StripePauseWorker(), 1);
        Test.stopTest();
        System.assertEquals('Active', gift().Status);
        System.assertEquals(null, gift().Stripe_Pause_State__c);
        System.assertEquals(0, mock.resumePosts, 'Stripe already auto-resumed; no duplicate mutation.');
    }

    @IsTest
    static void dueWorkerAcceptsNativeCreateSegmentAlreadyRestored() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = gift();
        GiftCommitmentSchedule oldSegment = [SELECT Id, GiftCommitmentId FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id LIMIT 1];
        update new GiftCommitmentSchedule(Id = oldSegment.Id, Type = 'PauseTransactions',
            StartDate = Date.today().addDays(-1), EndDate = Date.today().addDays(-1));
        insert new GiftCommitmentSchedule(
            GiftCommitmentId = commitment.Id, Type = 'CreateTransactions',
            StartDate = Date.today(), TransactionAmount = 2,
            TransactionPeriod = 'Monthly', TransactionInterval = 1,
            TransactionDay = String.valueOf(Date.today().day()),
            PaymentMethod = 'Credit Card'
        );
        update new GiftCommitment(Id = commitment.Id, Stripe_Pause_State__c = 'Active',
            Pause_Start_Date__c = Date.today().addDays(-1),
            Pause_Resume_Date__c = Date.today());
        MockStripe mock = new MockStripe();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        Database.executeBatch(new StripePauseWorker(), 1);
        Test.stopTest();
        System.assertEquals('Active', gift().Status);
        System.assertEquals(null, gift().Stripe_Pause_State__c);
        System.assertEquals(0, mock.resumePosts);
    }

    private class MockStripe implements HttpCalloutMock {
        Boolean paused = false;
        Boolean rejectPause = false;
        Boolean timeoutOnPause = false;
        Long resumeEpoch;
        Integer pausePosts = 0;
        Integer resumePosts = 0;
        public HttpResponse respond(HttpRequest request) {
            System.assert(request.getEndpoint().contains('/subscriptions/sub_test_pause_123'));
            HttpResponse response = new HttpResponse();
            response.setHeader('Content-Type', 'application/json');
            if (request.getMethod() == 'POST') {
                System.assertNotEquals(null, request.getHeader('Idempotency-Key'));
                if (request.getBody() == 'pause_collection=') {
                    resumePosts++;
                    paused = false;
                } else {
                    pausePosts++;
                    if (timeoutOnPause) throw new CalloutException('Simulated lost response');
                    if (rejectPause) {
                        response.setStatusCode(400);
                        response.setBody('{"error":{"message":"test decline"}}');
                        return response;
                    }
                    paused = true;
                    String[] pieces = request.getBody().split('pause_collection\\[resumes_at\\]=');
                    resumeEpoch = Long.valueOf(pieces[1]);
                }
            }
            response.setStatusCode(200);
            Map<String,Object> subscription = new Map<String,Object>{
                'id' => 'sub_test_pause_123', 'status' => 'active',
                'pause_collection' => paused
                    ? new Map<String,Object>{'behavior' => 'void', 'resumes_at' => resumeEpoch}
                    : null
            };
            response.setBody(JSON.serialize(subscription));
            return response;
        }
    }
}