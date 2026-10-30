@IsTest
private class RecurringDonationAmendmentServiceTest {

    private static final String RD_NAME = 'Amendment Test RD';
    private static final Decimal OLD_AMOUNT = 10;
    private static final Decimal NEW_AMOUNT = 25;

    // ------------------------------------------------------------------
    // Test data: one RD on a $10 schedule split 60/40 across two funds, with
    // a paid and an unpaid donation on that schedule. Setup runs with the
    // amendment sync switched off so only the test actions exercise it.
    // ------------------------------------------------------------------
    @TestSetup
    static void setup() {
        RecurringDonationAmendmentService.enabledOverride = false;
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;

        GiftDesignation fundA = new GiftDesignation(Name = 'Amendment Fund A');
        GiftDesignation fundB = new GiftDesignation(Name = 'Amendment Fund B');
        insert new List<GiftDesignation>{ fundA, fundB };

        GiftCommitment commitment = createCommitment(RD_NAME, createDonor().Id);
        GiftCommitmentSchedule oldSchedule = buildSchedule(
            commitment.Id, OLD_AMOUNT, Date.today().addMonths(-3), Date.today().addDays(10));
        insert oldSchedule;
        update new GiftCommitment(Id = commitment.Id, CurrentGiftCmtScheduleId = oldSchedule.Id);

        GiftTransaction paid = buildDonation(commitment, oldSchedule.Id, OLD_AMOUNT, 'Paid', Date.today().addMonths(-1));
        GiftTransaction unpaid = buildDonation(commitment, oldSchedule.Id, OLD_AMOUNT, 'Unpaid', Date.today().addDays(5));
        insert new List<GiftTransaction>{ paid, unpaid };
        insertSplitDesignations(new List<GiftTransaction>{ paid, unpaid }, fundA.Id, fundB.Id, 6, 4);

        insert new List<GiftDefaultDesignation>{
            new GiftDefaultDesignation(ParentRecordId = commitment.Id, GiftDesignationId = fundA.Id,
                AllocatedPercentage = 60, Amount__c = 6),
            new GiftDefaultDesignation(ParentRecordId = commitment.Id, GiftDesignationId = fundB.Id,
                AllocatedPercentage = 40, Amount__c = 4)
        };
    }

    // ------------------------------------------------------------------
    // Insert path: NPC amendment creates a new schedule with a new amount
    // ------------------------------------------------------------------
    @IsTest
    static void amendmentLeavesTheCurrentScheduleToNpc() {
        GiftCommitment commitment = getCommitment();
        Id previousCurrent = commitment.CurrentGiftCmtScheduleId;

        Test.startTest();
        insertAmendment(commitment.Id, NEW_AMOUNT, true);
        Test.stopTest();

        Assert.areEqual(previousCurrent, getCommitment().CurrentGiftCmtScheduleId,
            'NPC owns the current schedule and switches it on the effective date; the sync must not touch it');
    }

    @IsTest
    static void amendmentResplitsDefaultDesignations() {
        Test.startTest();
        insertAmendment(getCommitment().Id, NEW_AMOUNT, true);
        Test.stopTest();

        assertAmounts(new List<Decimal>{ 15, 10 }, defaultAmounts(getCommitment().Id),
            'Default designations should carry the 60/40 split of the amended amount');
    }

    @IsTest
    static void amendmentLeavesPaidAndPreviousScheduleDonationsUnchanged() {
        Test.startTest();
        insertAmendment(getCommitment().Id, NEW_AMOUNT, true);
        Test.stopTest();

        for (GiftTransactionDesignation designation : [
            SELECT Amount, Percent FROM GiftTransactionDesignation
            WHERE GiftTransaction.GiftCommitmentId = :getCommitment().Id
        ]) {
            Assert.areEqual(designation.Percent == 60 ? 6 : 4, designation.Amount,
                'Paid donations and unpaid donations on the previous schedule must keep their amounts');
        }
    }

    @IsTest
    static void amendmentDuringPauseStillSyncs() {
        StripePauseService.suppressSubscriptionUpdate = true;

        Test.startTest();
        insertAmendment(getCommitment().Id, NEW_AMOUNT, true);
        Test.stopTest();

        assertAmounts(new List<Decimal>{ 15, 10 }, defaultAmounts(getCommitment().Id),
            'An amount changed during pause/resume should still re-split the default designations');
    }

    // ------------------------------------------------------------------
    // Update path: the amount changes in place on the latest schedule
    // (NPC only allows that while the schedule has no donations)
    // ------------------------------------------------------------------
    @IsTest
    static void inPlaceAmountChangeResplitsDefaultDesignations() {
        GiftCommitmentSchedule newSchedule = insertAmendment(getCommitment().Id, 15, false);

        RecurringDonationAmendmentService.enabledOverride = true;
        Test.startTest();
        update new GiftCommitmentSchedule(Id = newSchedule.Id, TransactionAmount = NEW_AMOUNT);
        Test.stopTest();

        assertAmounts(new List<Decimal>{ 15, 10 }, defaultAmounts(getCommitment().Id),
            'An in-place amount change should re-split the default designations');
    }

    // ------------------------------------------------------------------
    // Schedules that are not amount amendments
    // ------------------------------------------------------------------
    @IsTest
    static void firstScheduleOfNewRdIsNotAnAmendment() {
        GiftCommitment commitment = createCommitment('Brand New RD', createDonor().Id);
        GiftDefaultDesignation designation = new GiftDefaultDesignation(ParentRecordId = commitment.Id,
            GiftDesignationId = getFunds()[0].Id, AllocatedPercentage = 100, Amount__c = 1);
        insert designation;

        RecurringDonationAmendmentService.enabledOverride = true;
        Test.startTest();
        insert buildSchedule(commitment.Id, NEW_AMOUNT, Date.today(), null);
        Test.stopTest();

        Assert.areEqual(1, [SELECT Amount__c FROM GiftDefaultDesignation WHERE Id = :designation.Id].Amount__c,
            'The first schedule of a new RD is not an amendment');
    }

    @IsTest
    static void sameAmountRenewalIsNotAnAmendment() {
        Id commitmentId = getCommitment().Id;
        markDefaultDesignations(commitmentId);

        Test.startTest();
        insertAmendment(commitmentId, OLD_AMOUNT, true);
        Test.stopTest();

        assertAmounts(new List<Decimal>{ 7, 3 }, defaultAmounts(commitmentId),
            'A new schedule with the same amount is not an amount amendment');
    }

    @IsTest
    static void pauseScheduleIsIgnored() {
        Id commitmentId = getCommitment().Id;
        markDefaultDesignations(commitmentId);
        GiftCommitmentSchedule pause = buildSchedule(commitmentId, NEW_AMOUNT, Date.today().addDays(11), null);
        pause.Type = 'PauseTransactions';

        RecurringDonationAmendmentService.enabledOverride = true;
        Test.startTest();
        insert pause;
        Test.stopTest();

        assertAmounts(new List<Decimal>{ 7, 3 }, defaultAmounts(commitmentId),
            'Pause schedules never drive the RD amounts');
    }

    @IsTest
    static void switchedOffDoesNothing() {
        Test.startTest();
        insertAmendment(getCommitment().Id, NEW_AMOUNT, false);
        Test.stopTest();

        assertAmounts(new List<Decimal>{ 6, 4 }, defaultAmounts(getCommitment().Id),
            'With RD_Amendment_Sync__c off the designations must not change');
    }

    @IsTest
    static void designationSaveFailureBlocksTheAmendmentWithAClearMessage() {
        Id commitmentId = getCommitment().Id;
        RecurringDonationAmendmentService.failDesignationSave = true;

        Test.startTest();
        try {
            insertAmendment(commitmentId, NEW_AMOUNT, true);
            Assert.fail('The amendment should be blocked when its designations cannot be updated');
        } catch (DmlException blocked) {
            Assert.isTrue(blocked.getMessage().contains('could not update the recurring donation default designation amounts'),
                blocked.getMessage());
        }
        Test.stopTest();

        assertAmounts(new List<Decimal>{ 6, 4 }, defaultAmounts(commitmentId),
            'Nothing is half-applied when the amendment is blocked');
    }

    @IsTest
    static void fundraiseUpRdWithoutCurrentScheduleIsResplit() {
        GiftCommitment commitment = getCommitment();
        update new GiftCommitment(Id = commitment.Id, CurrentGiftCmtScheduleId = null,
            FundraiseUpId__c = 'FUP-AMEND-1', ExpectedEndDate = Date.today().addYears(1));

        Test.startTest();
        insertAmendment(commitment.Id, NEW_AMOUNT, true);
        Test.stopTest();

        assertAmounts(new List<Decimal>{ 15, 10 }, defaultAmounts(commitment.Id),
            'A FundraiseUp RD with no current schedule is compared with its previous schedule and re-split');
        Assert.isNull(getCommitment().CurrentGiftCmtScheduleId, 'The current schedule is left to NPC');
    }

    // ------------------------------------------------------------------
    // Permissions and bulk
    // ------------------------------------------------------------------
    @IsTest
    static void userWhoCannotEditDesignationsCanStillAmend() {
        // Designations are Public Read Only: a non-owner can read but not edit them.
        GiftCommitment commitment = getCommitment();
        GiftCommitmentSchedule newSchedule = insertAmendment(commitment.Id, NEW_AMOUNT, false);
        GiftCommitmentSchedule amended = [
            SELECT Id, GiftCommitmentId, Type, TransactionAmount, StartDate
            FROM GiftCommitmentSchedule WHERE Id = :newSchedule.Id
        ];
        RecurringDonationAmendmentService.enabledOverride = true;

        Test.startTest();
        System.runAs(createStandardUser()) {
            RecurringDonationAmendmentService.handle(new List<GiftCommitmentSchedule>{ amended }, null);
        }
        Test.stopTest();

        assertAmounts(new List<Decimal>{ 15, 10 }, defaultAmounts(commitment.Id),
            'Designations the amending user cannot edit should still be re-split');
    }

    @IsTest
    static void bulkAmendmentsAreSynced() {
        Integer rdCount = 200;
        List<GiftDesignation> funds = getFunds();
        Id donorId = createDonor().Id;
        List<GiftCommitment> commitments = new List<GiftCommitment>();
        for (Integer i = 0; i < rdCount; i++) {
            commitments.add(new GiftCommitment(Name = 'Bulk RD ' + i, DonorId = donorId, Status = 'Active'));
        }
        insert commitments;
        List<GiftCommitmentSchedule> oldSchedules = new List<GiftCommitmentSchedule>();
        List<GiftDefaultDesignation> designations = new List<GiftDefaultDesignation>();
        for (GiftCommitment commitment : commitments) {
            oldSchedules.add(buildSchedule(commitment.Id, OLD_AMOUNT, Date.today().addMonths(-3), Date.today().addDays(10)));
            designations.add(new GiftDefaultDesignation(ParentRecordId = commitment.Id,
                GiftDesignationId = funds[0].Id, AllocatedPercentage = 60, Amount__c = 6));
            designations.add(new GiftDefaultDesignation(ParentRecordId = commitment.Id,
                GiftDesignationId = funds[1].Id, AllocatedPercentage = 40, Amount__c = 4));
        }
        insert oldSchedules;
        insert designations;

        List<GiftCommitmentSchedule> amendments = new List<GiftCommitmentSchedule>();
        for (GiftCommitment commitment : commitments) {
            amendments.add(buildSchedule(commitment.Id, NEW_AMOUNT, Date.today().addDays(11), null));
        }
        RecurringDonationAmendmentService.enabledOverride = true;

        Test.startTest();
        insert amendments;
        Test.stopTest();

        Assert.areEqual(rdCount * 2, [
            SELECT COUNT() FROM GiftDefaultDesignation
            WHERE ParentRecordId IN :commitments AND (Amount__c = 15 OR Amount__c = 10)
        ], 'Every default designation should be re-split in bulk');
    }

    // ------------------------------------------------------------------
    // Rounding
    // ------------------------------------------------------------------
    @IsTest
    static void splitPutsRoundingRemainderOnLargestAllocation() {
        assertAmounts(new List<Decimal>{ 3.33, 3.33, 3.34 },
            RecurringDonationAmendmentService.split(new List<Decimal>{ 33.33, 33.33, 33.34 }, 10),
            'A full split should add up exactly to the total');
        assertAmounts(new List<Decimal>{ 0.00, 0.01 },
            RecurringDonationAmendmentService.split(new List<Decimal>{ 50, 50 }, 0.01),
            'Over-allocation from rounding should be taken back from one allocation');
    }

    @IsTest
    static void splitLeavesPartialAllocationsUnadjusted() {
        assertAmounts(new List<Decimal>{ 3.33 },
            RecurringDonationAmendmentService.split(new List<Decimal>{ 33.33 }, 10),
            'Allocations that do not make up 100% should not absorb the remainder');
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    private static Account createDonor() {
        Id personAccountTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
            .get('PersonAccount').getRecordTypeId();
        Account donor = new Account(RecordTypeId = personAccountTypeId, FirstName = 'Amend', LastName = 'Donor');
        insert donor;
        return donor;
    }

    private static GiftCommitment createCommitment(String name, Id donorId) {
        GiftCommitment commitment = new GiftCommitment(Name = name, DonorId = donorId, Status = 'Active');
        insert commitment;
        return commitment;
    }

    private static GiftCommitmentSchedule buildSchedule(Id commitmentId, Decimal amount, Date startDate, Date endDate) {
        return new GiftCommitmentSchedule(
            GiftCommitmentId = commitmentId,
            Type = 'CreateTransactions',
            TransactionAmount = amount,
            TransactionPeriod = 'Monthly',
            TransactionInterval = 1,
            StartDate = startDate,
            EndDate = endDate,
            PaymentMethod = 'Credit Card'
        );
    }

    // Mirrors an NPC amendment: a new schedule that starts after the previous one ends.
    private static GiftCommitmentSchedule insertAmendment(Id commitmentId, Decimal amount, Boolean syncEnabled) {
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        RecurringDonationAmendmentService.enabledOverride = syncEnabled;
        GiftCommitmentSchedule amendment = buildSchedule(commitmentId, amount, Date.today().addDays(11), null);
        insert amendment;
        return amendment;
    }

    private static GiftTransaction buildDonation(GiftCommitment commitment, Id scheduleId, Decimal amount,
                                                 String status, Date dueDate) {
        return new GiftTransaction(
            Name = 'Amendment Donation ' + status,
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = scheduleId,
            Status = status,
            OriginalAmount = amount,
            TransactionDueDate = dueDate,
            TransactionDate = status == 'Paid' ? Date.today() : null,
            PaymentMethod = 'Credit Card'
        );
    }

    private static void insertSplitDesignations(List<GiftTransaction> donations, Id fundA, Id fundB,
                                                Decimal amountA, Decimal amountB) {
        List<GiftTransactionDesignation> designations = new List<GiftTransactionDesignation>();
        for (GiftTransaction donation : donations) {
            designations.add(new GiftTransactionDesignation(GiftTransactionId = donation.Id,
                GiftDesignationId = fundA, Percent = 60, Amount = amountA));
            designations.add(new GiftTransactionDesignation(GiftTransactionId = donation.Id,
                GiftDesignationId = fundB, Percent = 40, Amount = amountB));
        }
        insert designations;
    }

    // Sets sentinel amounts so a test can prove the designations were not recalculated.
    private static void markDefaultDesignations(Id commitmentId) {
        List<GiftDefaultDesignation> designations = [
            SELECT Id, AllocatedPercentage FROM GiftDefaultDesignation WHERE ParentRecordId = :commitmentId
        ];
        for (GiftDefaultDesignation designation : designations) {
            designation.Amount__c = designation.AllocatedPercentage == 60 ? 7 : 3;
        }
        update designations;
    }

    private static GiftCommitment getCommitment() {
        return [
            SELECT Id, DonorId, CurrentGiftCmtScheduleId
            FROM GiftCommitment WHERE Name = :RD_NAME LIMIT 1
        ];
    }

    private static List<GiftDesignation> getFunds() {
        return [SELECT Id FROM GiftDesignation WHERE Name LIKE 'Amendment Fund %' ORDER BY Name];
    }

    // Amounts ordered 60% first, then 40%.
    private static List<Decimal> defaultAmounts(Id commitmentId) {
        List<Decimal> amounts = new List<Decimal>();
        for (GiftDefaultDesignation designation : [
            SELECT Amount__c FROM GiftDefaultDesignation
            WHERE ParentRecordId = :commitmentId ORDER BY AllocatedPercentage DESC
        ]) {
            amounts.add(designation.Amount__c);
        }
        return amounts;
    }

    // Compares amounts at cent scale: the database returns 9.00 where a literal is 9.
    private static void assertAmounts(List<Decimal> expected, List<Decimal> actual, String message) {
        List<String> expectedText = new List<String>();
        for (Decimal amount : expected) expectedText.add(String.valueOf(amount.setScale(2)));
        List<String> actualText = new List<String>();
        for (Decimal amount : actual) actualText.add(amount == null ? 'null' : String.valueOf(amount.setScale(2)));
        Assert.areEqual(String.join(expectedText, ','), String.join(actualText, ','), message);
    }

    private static User createStandardUser() {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniqueName = 'rd.amend.' + String.valueOf(Crypto.getRandomInteger()).replace('-', '') + '@example.com';
        User user = new User(
            ProfileId = standard.Id,
            Username = uniqueName,
            Email = uniqueName,
            LastName = 'Amender',
            Alias = 'rdamend',
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert user;
        return user;
    }
}