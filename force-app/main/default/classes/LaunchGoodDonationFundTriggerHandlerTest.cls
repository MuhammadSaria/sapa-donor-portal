@isTest
private class LaunchGoodDonationFundTriggerHandlerTest {
    private static final String URL = 'https://www.launchgood.com/v4/campaign/duplicate_test_project';
    private static final String ERROR_FRAGMENT = 'already exists for this Project URL and Special Request';

    @isTest
    static void shouldBlockDuplicate_WhenSpecialRequestIsBlank() {
        insert makeMapping(URL, null);

        Test.startTest();
        Database.SaveResult result = Database.insert(makeMapping(URL, '   '), false);
        Test.stopTest();

        assertDuplicateFailure(result);
    }

    @isTest
    static void shouldBlockDuplicate_WhenSpecialRequestMatchesAfterNormalization() {
        insert makeMapping(URL, 'Feed 100 People');

        Test.startTest();
        Database.SaveResult result = Database.insert(makeMapping(URL.toUpperCase() + '/', ' feed 100 people '), false);
        Test.stopTest();

        assertDuplicateFailure(result);
    }

    @isTest
    static void shouldAllowSameUrl_WhenSpecialRequestDiffers() {
        insert makeMapping(URL, null);

        Test.startTest();
        Database.SaveResult result = Database.insert(makeMapping(URL, 'Water Pack'), false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'Same URL with a different Special Request should be allowed.');
    }

    @isTest
    static void shouldBlockUpdate_WhenRecordBecomesDuplicate() {
        LaunchGood_Donation_Fund__c existingMapping = makeMapping(URL, 'Feed 100 People');
        LaunchGood_Donation_Fund__c mappingToUpdate = makeMapping(URL, 'Water Pack');
        insert new List<LaunchGood_Donation_Fund__c>{ existingMapping, mappingToUpdate };

        mappingToUpdate.Special_Request__c = ' feed 100 people ';

        Test.startTest();
        Database.SaveResult result = Database.update(mappingToUpdate, false);
        Test.stopTest();

        assertDuplicateFailure(result);
    }

    @isTest
    static void shouldBlockBulkDuplicates_WhenInsertedTogether() {
        List<LaunchGood_Donation_Fund__c> mappings = new List<LaunchGood_Donation_Fund__c>{
            makeMapping(URL + '/bulk', null),
            makeMapping(URL + '/bulk/', null),
            makeMapping(URL + '/bulk', 'Feed 100 People')
        };

        Test.startTest();
        List<Database.SaveResult> results = Database.insert(mappings, false);
        Test.stopTest();

        Assert.isFalse(results[0].isSuccess(), 'First in-transaction duplicate should be blocked.');
        Assert.isFalse(results[1].isSuccess(), 'Second in-transaction duplicate should be blocked.');
        Assert.isTrue(results[2].isSuccess(), 'Same URL with a different Special Request should be allowed.');
    }

    private static LaunchGood_Donation_Fund__c makeMapping(String projectUrl, String specialRequest) {
        return new LaunchGood_Donation_Fund__c(
            Name = 'Test Mapping',
            Project_URL__c = projectUrl,
            Special_Request__c = specialRequest,
            Active__c = true
        );
    }

    private static void assertDuplicateFailure(Database.SaveResult result) {
        Assert.isFalse(result.isSuccess(), 'Duplicate mapping should fail to save.');
        Assert.isTrue(
            result.getErrors()[0].getMessage().contains(ERROR_FRAGMENT),
            'Duplicate error should explain the Project URL and Special Request conflict.'
        );
    }
}