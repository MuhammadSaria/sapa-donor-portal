@isTest
public class AllReceiptsPDFController_Test {

    @isTest
    static void testDonationsQuery() {
        // Step 1: Create test data
        
        // Create a Contact
        Account testContact = new Account(
            LastName = 'TestContact',
            PersonEmail = 'smith@example.com'
        );
        insert testContact;

        // Create Opportunities related to the Contact
        GiftTransaction testOpportunity1 = new GiftTransaction(
            Name = 'Opportunity 1',
            OriginalAmount = 1000.00,
            Transactiondate = Date.today().addDays(-30),
            donorId = testContact.Id,
            Status = 'Paid',
            Paper_Receipt_Requested__c = 'Receipt Requested',
            PaymentMethod = 'cash'
        );
        insert testOpportunity1;

        // Instantiate Controller
        Test.startTest();
        AllReceiptsPDFController controller = new AllReceiptsPDFController();
        Test.stopTest();

        // Assertions
        System.assertNotEquals(null, controller.donations, 'Donations list should not be null');
        System.assert(controller.donations.size() > 0, 'Donations list should contain records');

        Boolean found = false;
        for (GiftTransaction opp : controller.donations) {
            if (opp.Id == testOpportunity1.Id) {
                found = true;
                
                
                break;
            }
        }
        System.assert(found, 'Inserted Opportunity should be in the donations list');
    }
}