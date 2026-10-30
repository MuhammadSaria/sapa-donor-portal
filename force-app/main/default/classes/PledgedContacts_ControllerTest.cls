@isTest
private class PledgedContacts_ControllerTest {

    @isTest
    static void testHasDonation_NoDonations() {
        // Create a test Contact
        Account testContact = new Account(LastName = 'TestContact');
        insert testContact;

        // Call the hasDonation method with the test Contact's Id
        Test.startTest();
        Boolean result = pledgedContacts_Controller.hasDonation(testContact.Id);
        Test.stopTest();

        // Assert that no donations are found
        System.assertEquals(false, result, 'Expected no donations to be found');
    }

    @isTest
    static void testHasDonation_OpportunityFound() {
        // Create a test Contact
        Account testContact = new Account(LastName = 'TestContact');
        insert testContact;

        // Create a test Opportunity related to the test Contact
        GiftTransaction testOpportunity = new GiftTransaction(
            Name = 'Test Opportunity',
            Status = 'Pledged',
            TransactionDate= date.today(),
            donorId = testContact.Id,
            paymentMethod = 'cash',
            OriginalAmount = 100.00
        );
        insert testOpportunity;

        // Call the hasDonation method with the test Contact's Id
        Test.startTest();
        Boolean result = pledgedContacts_Controller.hasDonation(testContact.Id);
        Test.stopTest();

        // Assert that an Opportunity donation is found
        System.assertEquals(false, result, 'Expected an Opportunity donation to be found');
    }

  
}