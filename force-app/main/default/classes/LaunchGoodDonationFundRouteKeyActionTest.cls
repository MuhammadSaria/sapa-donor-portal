@isTest
private class LaunchGoodDonationFundRouteKeyActionTest {
    private static final String URL = 'https://www.launchgood.com/v4/campaign/test_project';

    @isTest
    static void shouldReturnSameKey_WhenBlankSpecialRequestDuplicates() {
        Test.startTest();
        String firstKey = LaunchGoodDonationFundRouteKeyService.generateRouteKey(URL, null);
        String secondKey = LaunchGoodDonationFundRouteKeyService.generateRouteKey(URL, '   ');
        Test.stopTest();

        Assert.areEqual(firstKey, secondKey, 'Blank Special Request variants should share one route key.');
        Assert.areEqual(64, firstKey.length(), 'Generated SHA-256 key should be 64 hex characters.');
    }

    @isTest
    static void shouldReturnSameKey_WhenSameSpecialRequestHasDifferentCaseAndSpacing() {
        Test.startTest();
        String firstKey = LaunchGoodDonationFundRouteKeyService.generateRouteKey(URL, 'Feed 100 People');
        String secondKey = LaunchGoodDonationFundRouteKeyService.generateRouteKey(URL, ' feed 100 people ');
        Test.stopTest();

        Assert.areEqual(firstKey, secondKey, 'Special Request case and surrounding spaces should be normalized.');
    }

    @isTest
    static void shouldReturnDifferentKey_WhenSpecialRequestDiffers() {
        Test.startTest();
        String firstKey = LaunchGoodDonationFundRouteKeyService.generateRouteKey(URL, 'Feed 100 People');
        String secondKey = LaunchGoodDonationFundRouteKeyService.generateRouteKey(URL, 'Water Pack');
        Test.stopTest();

        Assert.areNotEqual(firstKey, secondKey, 'Different Special Request values should remain separate mappings.');
    }

    @isTest
    static void shouldReturnSameKey_WhenUrlCaseAndTrailingSlashDiffer() {
        Test.startTest();
        String firstKey = LaunchGoodDonationFundRouteKeyService.generateRouteKey(URL + '/', 'Feed 100 People');
        String secondKey = LaunchGoodDonationFundRouteKeyService.generateRouteKey(URL.toUpperCase(), 'Feed 100 People');
        Test.stopTest();

        Assert.areEqual(firstKey, secondKey, 'URL case and one trailing slash should be normalized.');
    }

    @isTest
    static void shouldReturnBlankKey_WhenProjectUrlBlank() {
        Test.startTest();
        String key = LaunchGoodDonationFundRouteKeyService.generateRouteKey('   ', 'Feed 100 People');
        Test.stopTest();

        Assert.areEqual('', key, 'Blank Project URL should preserve optional Project URL behavior.');
    }

    @isTest
    static void shouldReturnRouteKey_WhenInvokedFromFlowShape() {
        LaunchGoodDonationFundRouteKeyAction.Request request =
            new LaunchGoodDonationFundRouteKeyAction.Request();
        request.projectUrl = URL;
        request.specialRequest = 'Feed 100 People';

        Test.startTest();
        List<LaunchGoodDonationFundRouteKeyAction.Response> responses =
            LaunchGoodDonationFundRouteKeyAction.generate(
                new List<LaunchGoodDonationFundRouteKeyAction.Request>{ request }
            );
        Test.stopTest();

        Assert.areEqual(1, responses.size(), 'Flow action should return one response for one request.');
        Assert.areEqual(64, responses[0].routeKey.length(), 'Flow action should return a SHA-256 route key.');
    }
}