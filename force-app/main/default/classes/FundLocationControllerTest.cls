@IsTest
private class FundLocationControllerTest {

    @TestSetup
    static void createTestData() {

        List<GiftDesignation> testFunds = new List<GiftDesignation>{
            new GiftDesignation(
                Name = 'Water Fund Alpha',
                IsActive = true
            ),
            new GiftDesignation(
                Name = 'Water Fund Beta',
                IsActive = true
            ),
            new GiftDesignation(
                Name = 'Education Fund',
                IsActive = true
            ),
            new GiftDesignation(
                Name = 'Inactive Water Fund'
            ),
            new GiftDesignation(
                Name = 'General Fund One',
                IsActive = true
            ),
            new GiftDesignation(
                Name = 'General Fund Two',
                IsActive = true
            ),
            new GiftDesignation(
                Name = 'General Fund Three',
                IsActive = true
            )
        };

        insert testFunds;

        // Deactivate after insertion.
        GiftDesignation inactiveFund = [
            SELECT Id, IsActive
            FROM GiftDesignation
            WHERE Name = 'Inactive Water Fund'
            LIMIT 1
        ];

        inactiveFund.IsActive = false;
        update inactiveFund;
    }

    private static FundLocationController.SearchRequest createRequest(
        String searchString,
        List<String> excludedIds
    ) {
        FundLocationController.SearchRequest request =
            new FundLocationController.SearchRequest();

        request.objectApiName = 'GiftDesignation';
        request.fieldApiName = 'Name';
        request.searchString = searchString;
        request.excludedIds = excludedIds;

        return request;
    }

    @IsTest
    static void testInactiveFundSetup() {

        GiftDesignation inactiveFund = [
            SELECT Id, Name, IsActive
            FROM GiftDesignation
            WHERE Name = 'Inactive Water Fund'
            LIMIT 1
        ];

        System.assertEquals(
            false,
            inactiveFund.IsActive,
            'Inactive Water Fund must be inactive before testing the controller.'
        );
    }

    @IsTest
    static void getFundsReturnsOnlyActiveMatchingFunds() {

        GiftDesignation activeAlpha = [
            SELECT Id
            FROM GiftDesignation
            WHERE Name = 'Water Fund Alpha'
            LIMIT 1
        ];

        GiftDesignation activeBeta = [
            SELECT Id
            FROM GiftDesignation
            WHERE Name = 'Water Fund Beta'
            LIMIT 1
        ];

        GiftDesignation inactiveFund = [
            SELECT Id
            FROM GiftDesignation
            WHERE Name = 'Inactive Water Fund'
            LIMIT 1
        ];

        FundLocationController.SearchRequest request =
            createRequest('Water Fund', null);

        Test.startTest();

        List<FundLocationController.FundResult> results =
            FundLocationController.getFunds(request);

        Test.stopTest();

        Set<String> returnedIds = getReturnedIds(results);

        System.assertEquals(
            2,
            results.size(),
            'Only the two active Water funds should be returned.'
        );

        System.assert(
            returnedIds.contains(String.valueOf(activeAlpha.Id)),
            'Water Fund Alpha should be returned.'
        );

        System.assert(
            returnedIds.contains(String.valueOf(activeBeta.Id)),
            'Water Fund Beta should be returned.'
        );

        System.assert(
            !returnedIds.contains(String.valueOf(inactiveFund.Id)),
            'Inactive Water Fund must not be returned.'
        );
    }

    @IsTest
    static void getFundsExcludesPreviouslySelectedFunds() {

        GiftDesignation excludedFund = [
            SELECT Id
            FROM GiftDesignation
            WHERE Name = 'Water Fund Alpha'
            LIMIT 1
        ];

        FundLocationController.SearchRequest request =
            createRequest(
                'Water Fund',
                new List<String>{
                    String.valueOf(excludedFund.Id)
                }
            );

        Test.startTest();

        List<FundLocationController.FundResult> results =
            FundLocationController.getFunds(request);

        Test.stopTest();

        Set<String> returnedIds = getReturnedIds(results);

        System.assertEquals(
            1,
            results.size(),
            'Only Water Fund Beta should remain.'
        );

        System.assertEquals(
            'Water Fund Beta',
            results[0].mainField,
            'The remaining fund should be Water Fund Beta.'
        );

        System.assert(
            !returnedIds.contains(String.valueOf(excludedFund.Id)),
            'Water Fund Alpha must be excluded.'
        );
    }

    @IsTest
    static void getFundsReturnsEmptyListWhenNothingMatches() {

        FundLocationController.SearchRequest request =
            createRequest('Fund That Does Not Exist', null);

        Test.startTest();

        List<FundLocationController.FundResult> results =
            FundLocationController.getFunds(request);

        Test.stopTest();

        System.assertNotEquals(
            null,
            results,
            'The controller must return a list instead of null.'
        );

        System.assertEquals(
            0,
            results.size(),
            'No funds should match this search.'
        );
    }

    @IsTest
    static void getFundsWithBlankSearchReturnsMaximumFiveActiveFunds() {

        FundLocationController.SearchRequest request =
            createRequest('', null);

        Test.startTest();

        List<FundLocationController.FundResult> results =
            FundLocationController.getFunds(request);

        Test.stopTest();

        System.assertEquals(
            5,
            results.size(),
            'The controller should return a maximum of five funds.'
        );

        Set<Id> returnedIds = new Set<Id>();

        for (FundLocationController.FundResult result : results) {
            returnedIds.add(Id.valueOf(result.id));
        }

        List<GiftDesignation> returnedFunds = [
            SELECT Id, IsActive
            FROM GiftDesignation
            WHERE Id IN :returnedIds
        ];

        for (GiftDesignation fund : returnedFunds) {
            System.assertEquals(
                true,
                fund.IsActive,
                'Every returned Gift Designation must be active.'
            );
        }
    }

    private static Set<String> getReturnedIds(
        List<FundLocationController.FundResult> results
    ) {
        Set<String> returnedIds = new Set<String>();

        for (FundLocationController.FundResult result : results) {
            returnedIds.add(result.id);
        }

        return returnedIds;
    }
}