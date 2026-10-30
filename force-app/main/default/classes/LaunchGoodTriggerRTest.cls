@isTest
private class LaunchGoodTriggerRTest {

    private static Account makePersonAccount() {
        RecordType accountRecordType = [
            SELECT Id
            FROM RecordType
            WHERE SObjectType = 'Account'
            AND DeveloperName = 'PersonAccount'
            LIMIT 1
        ];

        Account account = new Account(
            FirstName = 'LaunchGood',
            LastName = 'Recurring Test ' + String.valueOf(DateTime.now().getTime()),
            RecordTypeId = accountRecordType.Id
        );
        insert account;
        return account;
    }

    private static GiftCommitment makeGiftCommitment(String channel) {
        return makeGiftCommitment(channel, 'Stripe');
    }

    private static GiftCommitment makeGiftCommitment(String channel, String paymentProcessor) {
        Account account = makePersonAccount();
        GiftCommitment commitment = new GiftCommitment(
            Name = 'GC-' + String.valueOf(DateTime.now().getTime()),
            DonorId = account.Id,
            Channel__c = channel,
            Payment_Processor__c = paymentProcessor
        );
        insert commitment;
        return commitment;
    }

    @testSetup
    static void setupTestData() {
        // 1. Create a dummy Campaign to serve as the valid ParentRecordId
        Campaign dummyCampaign = new Campaign(
            Name = 'Test LaunchGood Campaign',
            IsActive = true
        );
        insert dummyCampaign;

        // 2. Create the specific designation the trigger looks for
        GiftDesignation launchGoodFund = new GiftDesignation(
            Name = 'Launchgood Import'
        );
        insert launchGoodFund;

        // 3. Create an alternative designation to test the exclusion logic
        GiftDesignation standardFund = new GiftDesignation(
            Name = 'Standard Annual Fund'
        );
        insert standardFund;

        // 4. Create a routing mapping so the Handler actually processes the valid record
        LaunchGood_Donation_Fund__c mapping = new LaunchGood_Donation_Fund__c(
            Project_URL__c = 'launchgood.com/triggertest',
            Active__c = true,
            Funds__c = standardFund.Id // Routing it to the standard fund
        );
        insert mapping;
    }

    @isTest
    static void testTrigger_ValidInsert() {
        GiftCommitment commitment = makeGiftCommitment('Launchgood');
        GiftDesignation lgFund = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];

        // Create a record that matches the trigger criteria
        GiftDefaultDesignation gdd = new GiftDefaultDesignation(
            ParentRecordId = commitment.Id,
            GiftDesignationId = lgFund.Id,
            AllocatedPercentage = 100, // Added required field
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/triggertest'
        );

        Test.startTest();
        insert gdd;
        Test.stopTest();

        // Re-query to verify the trigger successfully passed it to the handler
        GiftDefaultDesignation result = [
            SELECT Id, Fund_Match_Status__c, GiftDesignationId
            FROM GiftDefaultDesignation
            WHERE Id = :gdd.Id
        ];

        Assert.areEqual('Matched', result.Fund_Match_Status__c, 'The trigger should pass valid records to the handler.');
    }

    @isTest
    static void testTrigger_IgnoredRecords() {
        GiftCommitment commitment = makeGiftCommitment('Launchgood');
        GiftDesignation standardFund = [SELECT Id FROM GiftDesignation WHERE Name = 'Standard Annual Fund' LIMIT 1];

        // Create a record linked to a DIFFERENT designation name
        GiftDefaultDesignation ignoredGdd = new GiftDefaultDesignation(
            ParentRecordId = commitment.Id,
            GiftDesignationId = standardFund.Id,
            AllocatedPercentage = 25, // Added required field
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/triggertest'
        );

        Test.startTest();
        insert new List<GiftDefaultDesignation>{ignoredGdd};
        Test.stopTest();

        // Re-query
        List<GiftDefaultDesignation> results = [
            SELECT Id, Fund_Match_Status__c
            FROM GiftDefaultDesignation
            WHERE Id IN (:ignoredGdd.Id)
        ];

        for(GiftDefaultDesignation result : results) {
            Assert.isNull(result.Fund_Match_Status__c, 'Records without the "Launchgood Import" designation should bypass the handler.');
        }
    }

    @isTest
    static void testTrigger_ValidUpdate() {
        GiftCommitment commitment = makeGiftCommitment('Launchgood');
        GiftDesignation standardFund = [SELECT Id FROM GiftDesignation WHERE Name = 'Standard Annual Fund' LIMIT 1];
        GiftDesignation lgFund = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];

        // Start by inserting a record that bypasses the logic initially
        GiftDefaultDesignation gdd = new GiftDefaultDesignation(
            ParentRecordId = commitment.Id,
            GiftDesignationId = standardFund.Id,
            AllocatedPercentage = 50, // Added required field
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/triggertest'
        );
        insert gdd;

        GiftDefaultDesignation beforeUpdate = [SELECT Fund_Match_Status__c FROM GiftDefaultDesignation WHERE Id = :gdd.Id];
        Assert.isNull(beforeUpdate.Fund_Match_Status__c, 'Initial state should be null.');

        Test.startTest();
        // Update the record to match the trigger criteria
        gdd.GiftDesignationId = lgFund.Id;
        update gdd;
        Test.stopTest();

        GiftDefaultDesignation afterUpdate = [SELECT Fund_Match_Status__c FROM GiftDefaultDesignation WHERE Id = :gdd.Id];
        Assert.areEqual('Matched', afterUpdate.Fund_Match_Status__c, 'The trigger should process records modified to meet the criteria in an update context.');
    }

    @isTest
    static void testTrigger_SkipsNonLaunchGoodCommitmentChannel() {
        GiftCommitment commitment = makeGiftCommitment('Website', 'Launchgood');
        GiftDesignation lgFund = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];

        GiftDefaultDesignation gdd = new GiftDefaultDesignation(
            ParentRecordId = commitment.Id,
            GiftDesignationId = lgFund.Id,
            AllocatedPercentage = 100,
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/triggertest'
        );

        Test.startTest();
        insert gdd;
        Test.stopTest();

        GiftDefaultDesignation result = [
            SELECT Id, Fund_Match_Status__c
            FROM GiftDefaultDesignation
            WHERE Id = :gdd.Id
        ];

        Assert.isNull(result.Fund_Match_Status__c, 'Non-Launchgood recurring donations should bypass routing.');
    }
}