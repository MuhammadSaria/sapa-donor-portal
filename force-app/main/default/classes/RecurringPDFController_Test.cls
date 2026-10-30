@isTest
public class RecurringPDFController_Test {

    @isTest
    static void testRecurringDonationsQuery() {
        // Step 1: Create test Contact
        Account testContact = new Account(
            LastName = 'TestContact',
            personEmail = 'testcontact@example.com'
        );
        insert testContact;

        // Step 2: Create a test Recurring Donation
        GiftCommitment insertedRd = new GiftCommitment(
            Name = 'Test RD',
            DonorId = testContact.Id,
            Paper_Receipt__c = 'Receipt Requested',
            status = 'Active'
        );
        insert insertedRd;

        // Step 3: Set VF page reference with Id
        Test.setCurrentPageReference(new PageReference('/apex/Recurring_Receipt_PDF?id=' + insertedRd.Id));

        // Step 4: Instantiate the controller
        Test.startTest();
        RecurringPDFController controller = new RecurringPDFController();
        Test.stopTest();

        // Step 5: Assertions
        System.assertNotEquals(null, controller.donations, 'Donations list should not be null');
        System.assert(controller.donations.size() > 0, 'Donations list should contain records');

        Boolean found = false;
        for (GiftCommitment rd : controller.donations) {
            if (rd.Id == insertedRd.Id) { // ✅ Compare with inserted record Id
                found = true;
                //System.assertEquals(testContact.Id, rd.npe03__Contact__c, 'Contact should match');
                break;
            }
        }
        System.assert(found, 'Inserted Recurring Donation should be in the donations list');
    }

    @isTest
    static void testWithoutRecordId() {
        // Step 1: Set VF page reference without Id
        Test.setCurrentPageReference(new PageReference('/apex/Recurring_Receipt_PDF'));

        // Step 2: Instantiate the controller
        Test.startTest();
        RecurringPDFController controller = new RecurringPDFController();
        Test.stopTest();

        // Step 3: Assertions
        System.assertEquals(null, controller.recordId, 'recordId should be null');
        //System.assert(controller.donations.isEmpty(), 'Donations list should be empty');
    }
}