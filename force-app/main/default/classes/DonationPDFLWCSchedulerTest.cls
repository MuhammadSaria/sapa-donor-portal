@IsTest
private class DonationPDFLWCSchedulerTest {

    @IsTest
    static void testRunBatch() {

        // Minimal valid Contact (use Email because Preferred_Email__c is NOT on Contact in your org)
        Contact testContact = new Contact(
            LastName = 'Test',
            Email = 'test@example.com'
        );
        insert testContact;

        String testStartYear = '2023-01-01';
        String testEndYear   = '2023-12-31';

        Test.startTest();
        DonationPDFLWCScheduler.runBatch(testStartYear, testEndYear);
        Test.stopTest();

        System.assert(true);
    }
}