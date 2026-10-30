@isTest
private class LaunchGoodRoutingServiceTest {

    @testSetup
    static void setupTestData() {
        // 1. Create the Placeholder Fund required by the service
        GiftDesignation placeholder = new GiftDesignation(
            Name = 'Launchgood Import'
        );
        insert placeholder;

        // 2. Create a Target Fund to simulate a successful routing match
        GiftDesignation targetFund = new GiftDesignation(
            Name = 'Target Fund Mapping'
        );
        insert targetFund;

        GiftDesignation overrideFund = new GiftDesignation(
            Name = 'Food Package'
        );
        insert overrideFund;

        // 3. Create an ACTIVE mapping record (Will result in "Matched")
        LaunchGood_Donation_Fund__c activeMapping = new LaunchGood_Donation_Fund__c(
            Project_URL__c = 'launchgood.com/activeproject',
            Active__c = true,
            Funds__c = targetFund.Id,
            Location__c = 'Global'
        );
        insert activeMapping;

        LaunchGood_Donation_Fund__c overrideMapping = new LaunchGood_Donation_Fund__c(
            Project_URL__c = 'launchgood.com/activeproject',
            Active__c = true,
            Funds__c = overrideFund.Id,
            Location__c = 'Sudan'
        );
        overrideMapping.put('Special_Request__c', 'Feed 100 People');
        insert overrideMapping;

        // 4. Create an INACTIVE mapping record (Will result in "Missing Mapping")
        LaunchGood_Donation_Fund__c inactiveMapping = new LaunchGood_Donation_Fund__c(
            Project_URL__c = 'launchgood.com/inactiveproject',
            Active__c = false,
            Funds__c = targetFund.Id
        );
        insert inactiveMapping;
    }

    @isTest
    static void testRoute_SuccessfulMatch() {
        GiftDesignation placeholder = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];
        GiftDesignation targetFund = [SELECT Id FROM GiftDesignation WHERE Name = 'Target Fund Mapping' LIMIT 1];

        // Instantiate in memory. Note the trailing slash to test normaliseUrl()
        GiftTransactionDesignation gtd = new GiftTransactionDesignation(
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/activeproject/', 
            GiftDesignationId = placeholder.Id
        );

        Test.startTest();
        LaunchGoodRoutingService.route(new List<GiftTransactionDesignation>{gtd});
        Test.stopTest();

        Assert.areEqual('Matched', gtd.get('Fund_Match_Status__c'), 'The status should update to Matched.');
        Assert.areEqual(targetFund.Id, gtd.get('GiftDesignationId'), 'The designation ID should be routed to the target fund.');
        Assert.areEqual('Global', gtd.get('Locations__c'), 'The location field should map correctly.');
    }

    @isTest
    static void testRoute_MissingMapping_NewURL() {
        GiftDesignation placeholder = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];

        GiftTransactionDesignation gtd = new GiftTransactionDesignation(
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/brandnewproject',
            GiftDesignationId = placeholder.Id
        );

        Test.startTest();
        LaunchGoodRoutingService.route(new List<GiftTransactionDesignation>{gtd});
        Test.stopTest();

        Assert.areEqual('Missing Mapping', gtd.get('Fund_Match_Status__c'), 'Status should be Missing Mapping for an unknown URL.');

        // Verify a new mapping record was automatically generated
        List<LaunchGood_Donation_Fund__c> createdMappings = [
            SELECT Id, Project_URL__c, Active__c 
            FROM LaunchGood_Donation_Fund__c 
            WHERE Project_URL__c = 'launchgood.com/brandnewproject'
        ];
        
        Assert.areEqual(1, createdMappings.size(), 'A new inactive mapping record should be created.');
        Assert.isFalse(createdMappings[0].Active__c, 'The auto-created mapping should be inactive by default.');
    }

    @isTest
    static void testRoute_SpecialRequestOverrideMatch() {
        GiftDesignation placeholder = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];
        GiftDesignation overrideFund = [SELECT Id FROM GiftDesignation WHERE Name = 'Food Package' LIMIT 1];

        GiftTransactionDesignation gtd = new GiftTransactionDesignation(
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'LAUNCHGOOD.COM/ACTIVEPROJECT/',
            GiftDesignationId = placeholder.Id
        );
        gtd.put('Special_Request__c', ' feed 100 people ');

        Test.startTest();
        LaunchGoodRoutingService.route(new List<GiftTransactionDesignation>{gtd});
        Test.stopTest();

        Assert.areEqual('Matched', gtd.get('Fund_Match_Status__c'), 'The override request should match.');
        Assert.areEqual(overrideFund.Id, gtd.get('GiftDesignationId'), 'The override should route to the Food Package fund.');
        Assert.areEqual('Sudan', gtd.get('Locations__c'), 'The override should apply its mapped location.');
    }

    @isTest
    static void testRoute_SpecialRequestFallsBackToDefaultMapping() {
        GiftDesignation placeholder = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];
        GiftDesignation defaultFund = [SELECT Id FROM GiftDesignation WHERE Name = 'Target Fund Mapping' LIMIT 1];

        GiftTransactionDesignation gtd = new GiftTransactionDesignation(
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/activeproject',
            GiftDesignationId = placeholder.Id
        );
        gtd.put('Special_Request__c', 'Water Pack');

        Test.startTest();
        LaunchGoodRoutingService.route(new List<GiftTransactionDesignation>{gtd});
        Test.stopTest();

        Assert.areEqual('Matched', gtd.get('Fund_Match_Status__c'), 'A nonmatching request should still use the default URL mapping.');
        Assert.areEqual(defaultFund.Id, gtd.get('GiftDesignationId'), 'The default mapping should remain the fallback.');
        Assert.areEqual('Global', gtd.get('Locations__c'), 'The fallback location should come from the default mapping.');
    }

    @isTest
    static void testRoute_MissingMapping_InactiveURL() {
        GiftDesignation placeholder = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];

        GiftTransactionDesignation gtd = new GiftTransactionDesignation(
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/inactiveproject',
            GiftDesignationId = placeholder.Id
        );

        Test.startTest();
        LaunchGoodRoutingService.route(new List<GiftTransactionDesignation>{gtd});
        Test.stopTest();

        Assert.areEqual('Missing Mapping', gtd.get('Fund_Match_Status__c'), 'Status should be Missing Mapping if the record is marked inactive.');
        Assert.areEqual(placeholder.Id, gtd.get('GiftDesignationId'), 'The designation ID should NOT change.');
    }

    @isTest
    static void testRoute_SkippedConditions() {
        GiftDesignation placeholder = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];
        GiftDesignation targetFund = [SELECT Id FROM GiftDesignation WHERE Name = 'Target Fund Mapping' LIMIT 1];

        List<GiftTransactionDesignation> records = new List<GiftTransactionDesignation>{
            // Condition 1: Not an Omatic Import
            new GiftTransactionDesignation(
                Omatic_Import__c = false,
                LaunchGood_Project_URL__c = 'launchgood.com/activeproject',
                GiftDesignationId = placeholder.Id
            ),
            // Condition 2: Blank URL
            new GiftTransactionDesignation(
                Omatic_Import__c = true,
                LaunchGood_Project_URL__c = '',
                GiftDesignationId = placeholder.Id
            )
        };

        GiftTransactionDesignation alreadyDesignated = new GiftTransactionDesignation(
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/activeproject',
            GiftDesignationId = targetFund.Id
        );

        Test.startTest();
        LaunchGoodRoutingService.route(records);
        LaunchGoodRoutingService.route(new List<GiftTransactionDesignation>{alreadyDesignated});
        Test.stopTest();

        for (GiftTransactionDesignation gtd : records) {
            Assert.areEqual('Skipped', gtd.get('Fund_Match_Status__c'), 'Records failing initial checks should be marked as Skipped.');
        }

        Assert.areEqual('Matched', alreadyDesignated.get('Fund_Match_Status__c'), 'The service should support rerouting previously designated LaunchGood records.');
    }

    @isTest
    static void testRoute_GiftDefaultDesignationOverload() {
        GiftDesignation placeholder = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];
        GiftDesignation targetFund = [SELECT Id FROM GiftDesignation WHERE Name = 'Target Fund Mapping' LIMIT 1];

        // Testing the overloaded method for GiftDefaultDesignation
        GiftDefaultDesignation gdd = new GiftDefaultDesignation(
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/activeproject',
            GiftDesignationId = placeholder.Id
        );

        Test.startTest();
        LaunchGoodRoutingService.route(new List<GiftDefaultDesignation>{gdd});
        Test.stopTest();

        Assert.areEqual('Matched', gdd.get('Fund_Match_Status__c'), 'The status should update to Matched for GiftDefaultDesignation.');
        Assert.areEqual(targetFund.Id, gdd.get('GiftDesignationId'), 'The designation ID should update correctly.');
    }
    
    @isTest
    static void testRoute_NullAndEmptyHandling() {
        Test.startTest();
        // Passing null and empty lists to ensure the service returns gracefully without throwing NPEs
        LaunchGoodRoutingService.route((List<GiftTransactionDesignation>)null);
        LaunchGoodRoutingService.route(new List<GiftTransactionDesignation>());
        Test.stopTest();
        
        Assert.isTrue(true, 'Service should handle null and empty inputs safely without throwing exceptions.');
    }
}