@isTest
public class SinglePDFController_Test {

    @isTest
    static void testDonationsQuery() {
        // Step 1: Create test data
        
        // Create an Account
         Account testAccount = new Account(
            LastName = 'Test',
            Preferred_Email__c = 'Personal',
            PersonEmail = 'test@example.com',
            Work_Email__c = 'work@example.com',
            Alternate_Email__c = 'alternate@example.com'
        );
        insert testAccount;


        // Create an Opportunity related to the Contact
        GiftTransaction testOpportunity = new GiftTransaction(
            Name = 'Test Opportunity',
            donorId = testAccount.Id,
            status = 'Paid',
            TransactionDate = Date.today(),
            Paper_Receipt_Requested__c = 'Receipt Requested',
            Receipt_Allocations__c = 'General Fund',
            paymentMethod = 'cash',
            OriginalAmount = 100.00
        );
        insert testOpportunity;

        // Step 2: Set up VF page context with Id parameter
        Test.setCurrentPageReference(new PageReference('/apex/Single_Receipt_PDF?id=' + testOpportunity.Id));

        // Step 3: Instantiate Controller
        Test.startTest();
        SinglePDFController controller = new SinglePDFController();
        Test.stopTest();

        // Step 4: Assertions
        System.assertNotEquals(null, controller.donations, 'Donations list should not be null');
        System.assert(controller.donations.size() > 0, 'Donations list should contain records');

        Boolean found = false;
        for (GiftTransaction opp : controller.donations) {
            if (opp.Id == testOpportunity.Id) {
                found = true;
                
                System.assertEquals('Receipt Requested', opp.Paper_Receipt_Requested__c, 'Paper Receipt should match');
                //System.assertEquals(testContact.Id, opp.npsp__Primary_Contact__c, 'Primary Contact should match');
                break;
            }
        }
        System.assert(found, 'Inserted Opportunity should be in the donations list');
    }
}