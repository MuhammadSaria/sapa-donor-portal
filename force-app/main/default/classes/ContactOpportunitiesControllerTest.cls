@IsTest
public class ContactOpportunitiesControllerTest {

    @TestSetup
    static void setupTestData() {

        // Create Person Account record type for test
        RecordType personRt = [
            SELECT Id 
            FROM RecordType 
            WHERE SObjectType = 'Account' 
              AND IsPersonType = true
            LIMIT 1
        ];

        // Insert test Account (Person Account)
        Account acc = new Account(
            RecordTypeId = personRt.Id,
            LastName = 'Test Donor',
            PersonEmail = 'test@example.com'
        );
        insert acc;

        // Insert GiftTransactions WITHOUT GAUs
        List<GiftTransaction> gifts = new List<GiftTransaction>();

        gifts.add(new GiftTransaction(
            Name = 'Gift 1',
            DonorId = acc.Id,
            Status = 'Paid',
            OriginalAmount = 100,
            TransactionDate = Date.today().addDays(-5),
            PaymentMethod = 'Cash'
        ));

        gifts.add(new GiftTransaction(
            Name = 'Gift 2',
            DonorId = acc.Id,
            Status = 'Paid',
            OriginalAmount = 200,
            TransactionDate = Date.today().addDays(-3),
            PaymentMethod = 'Cash'
        ));

        gifts.add(new GiftTransaction(
            Name = 'Gift 3',
            DonorId = acc.Id,
            OriginalAmount = 300,
            TransactionDate = Date.today().addDays(-1),
            PaymentMethod = 'Cash',
            Status = 'Paid'
         
        ));

        insert gifts;
    }

    @IsTest
    static void testControllerWithTransactions() {
        // Fetch Account
        Account acc = [SELECT Id FROM Account LIMIT 1];

        // Set page parameters
        Date fromDate = Date.today().addDays(-10);
        Date toDate   = Date.today();
        ApexPages.currentPage().getParameters().put('fromDate', String.valueOf(fromDate));
        ApexPages.currentPage().getParameters().put('toDate', String.valueOf(toDate));
        ApexPages.currentPage().getParameters().put('recordId', acc.Id);

        Test.startTest();
        ContactOpportunitiesController controller = new ContactOpportunitiesController();
        Test.stopTest();

        // Assertions
        System.assertNotEquals(null, controller.Account, 'Account should be fetched');
        System.assertEquals(3, controller.giftTransactions.size(), 'Should only include Paid transactions in date range');
        //System.assertEquals(2, controller.ListWrapperAccount.size(), 'Wrapper list should match number of valid GiftTransactions');

        // Totals
        System.assertEquals(0, controller.TotalSadaqah, 'No GAU: Sadaqah = 0');
        System.assertEquals(0, controller.TotalZakat, 'No GAU: Zakat = 0');
        //System.assertEquals(300, controller.TotalGeneralDonation, 'TotalGeneralDonation = sum of Posted transactions with no GAU');
        //System.assertEquals(300, controller.GrandTotal, 'GrandTotal = 300');
    }

    @IsTest
    static void testControllerNoTransactions() {
        // Insert Account with no GiftTransactions
        RecordType personRt = [SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND IsPersonType = true LIMIT 1];
        Account acc = new Account(
            RecordTypeId = personRt.Id,
            LastName = 'No Gifts'
        );
        insert acc;

        ApexPages.currentPage().getParameters().put('fromDate', String.valueOf(Date.today().addDays(-10)));
        ApexPages.currentPage().getParameters().put('toDate', String.valueOf(Date.today()));
        ApexPages.currentPage().getParameters().put('recordId', acc.Id);

        Test.startTest();
        ContactOpportunitiesController controller = new ContactOpportunitiesController();
        Test.stopTest();

        System.assertEquals(0, controller.giftTransactions.size(), 'No transactions should be fetched');
        System.assertEquals(0, controller.ListWrapperAccount.size(), 'Wrapper list should be empty');
        System.assertEquals(0, controller.GrandTotal, 'GrandTotal should be 0');
    }

    @IsTest
    static void testControllerInvalidDates() {
        // Insert test Account
        RecordType personRt = [SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND IsPersonType = true LIMIT 1];
        Account acc = new Account(
            RecordTypeId = personRt.Id,
            LastName = 'Invalid Date'
        );
        insert acc;

        ApexPages.currentPage().getParameters().put('fromDate', 'invalid-date');
        ApexPages.currentPage().getParameters().put('toDate', 'invalid-date');
        ApexPages.currentPage().getParameters().put('recordId', acc.Id);

        Test.startTest();
        ContactOpportunitiesController controller = new ContactOpportunitiesController();
        Test.stopTest();

        System.assertEquals(null, controller.startDate, 'startDate should not be set on invalid input');
        System.assertEquals(null, controller.endDate, 'endDate should not be set on invalid input');
    }
}