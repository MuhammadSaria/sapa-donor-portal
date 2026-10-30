@IsTest
public class AnnualTaxReceiptPDFControllerTest {

    @TestSetup
    static void setupTestData() {
        // Create a test Account (Contact)
        Account testAccount = new Account(
            LastName = 'Test Donor',
            PersonEmail = 'test@example.com',
            PersonMailingStreet = '123 Test St',
            PersonMailingCity = 'Test City',
            PersonMailingPostalCode = '12345'
        );
        insert testAccount;

        // Create GiftTransaction records for the Account
        List<GiftTransaction> gifts = new List<GiftTransaction>();
        gifts.add(new GiftTransaction(
            Name = 'Gift 1',
            Status = 'Paid',
            TransactionDate = Date.newInstance(2025, 1, 10),
            //TransactionDate = System.Today(),
            PaymentMethod = 'cash',
            OriginalAmount = 100
        ));
        gifts.add(new GiftTransaction(
            Name = 'Gift 2',
            Status = 'Paid',
            //TransactionDate = System.Today(),
            TransactionDate = Date.newInstance(2025, 5, 15),
                        PaymentMethod = 'cash',
            OriginalAmount = 200
        ));
        gifts.add(new GiftTransaction(
            Name = 'Gift 3',
            Status = 'Pending',
                        PaymentMethod = 'cash',
            //TransactionDate = System.Today(),
            TransactionDate = Date.newInstance(2025, 6, 15),
            OriginalAmount = 300
        ));
        insert gifts; 
    }

    @IsTest
    static void testAnnualTaxReceiptPDFController() {
        // Get the test Account
        Account testAccount = [SELECT Id, Donor_ID__c FROM Account LIMIT 1];

        // Set page parameters
        ApexPages.currentPage().getParameters().put('contactId', testAccount.Id);
        ApexPages.currentPage().getParameters().put('startYear', '2025-01-01');
        ApexPages.currentPage().getParameters().put('endYear', '2025-12-31');

        // Instantiate the controller
        AnnualTaxReceiptPDFController controller = new AnnualTaxReceiptPDFController();

        // Assertions
        System.assertNotEquals(null, controller.contact, 'Contact should be fetched');
        System.assertEquals(testAccount.Id, controller.contact.Id, 'Fetched contact should match test account');

        //System.assert(controller.opportunities.size() == 2, 'Should fetch 2 Posted GiftTransactions within date range');

        //System.assertEquals(300, controller.totalDonation, 'Total donation should sum only posted gifts within date range');

        // Check formatted dates
        System.assert(controller.formattedStartDate.contains('Jan 1'), 'Start date should be formatted correctly');
        System.assert(controller.formattedendYearDate.contains('Dec 31'), 'End date should be formatted correctly');

        // Check receiptNo
        System.assert(controller.receiptNo.startsWith(testAccount.Donor_ID__c), 'Receipt number should start with Donor_ID__c');

        // Check formatted address
        String formattedAddress = controller.getFormattedAddress();
        System.assert(formattedAddress.contains('Test City'), 'Address should include city');
        //System.assert(formattedAddress.contains('TS'), 'Address should include state');
        System.assert(formattedAddress.contains('12345'), 'Address should include postal code');
    }
}