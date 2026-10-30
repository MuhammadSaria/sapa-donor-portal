@IsTest
public class AnnualTaxReceiptPDFbatchControllerTest {

   @TestSetup
static void setupTestData() {

    // Get Person Account Record Type
    RecordType personRt = [
        SELECT Id
        FROM RecordType
        WHERE SObjectType = 'Account'
        AND IsPersonType = true
        LIMIT 1
    ];

    // Create Person Accounts
    List<Account> accList = new List<Account>();
    for (Integer i = 1; i <= 2; i++) {
        accList.add(new Account(
            RecordTypeId = personRt.Id,   // 🔴 REQUIRED
            LastName = 'Donor ' + i,      // 🔴 REQUIRED for Person Accounts
            PersonEmail = null,
            PersonMailingCity = 'City' + i,
            //PersonMailingState = 'State' + i,
            PersonMailingPostalCode = '1000' + i,
            PersonMailingCountry = 'United States'
        ));
    }
    insert accList;

    Date startDate = Date.today().addMonths(-3);
    Date endDate   = Date.today().addMonths(3);

    // Create GiftTransactions
    List<GiftTransaction> gifts = new List<GiftTransaction>{
        new GiftTransaction(
            Name = 'Cash Gift 1',
            DonorId = accList[0].Id,
            Status = 'Paid',
            PaymentMethod = 'Cash',
            TransactionDate = startDate.addDays(10),
            OriginalAmount = 100
        ),
        new GiftTransaction(
            Name = 'Cash Gift 2',
            DonorId = accList[0].Id,
            Status = 'Paid',
            PaymentMethod = 'Cash',
            TransactionDate = startDate.addDays(20),
            OriginalAmount = 50
        ),
        new GiftTransaction(
            Name = 'Cash Gift 3',
            DonorId = accList[1].Id,
            Status = 'Paid',
            PaymentMethod = 'Cash',
            TransactionDate = endDate.addDays(-5),
            OriginalAmount = 200
        )
    };
    insert gifts;
}


    @IsTest
    static void testBatchControllerWithCashPayments() {

        Date startDate = Date.today().addMonths(-3);
        Date endDate   = Date.today().addMonths(3);

        ApexPages.currentPage().getParameters().put('startYear', String.valueOf(startDate));
        ApexPages.currentPage().getParameters().put('endYear', String.valueOf(endDate));

        Test.startTest();
        AnnualTaxReceiptPDFbatchController controller =
            new AnnualTaxReceiptPDFbatchController();
        Test.stopTest();

        // Wrapper assertions
        System.assertEquals(2, controller.ListWrapperAccount.size(),
            'Two donors should be processed');

        for (AnnualTaxReceiptPDFbatchController.WrapperAccount wrap :
                controller.ListWrapperAccount) {

            System.assertNotEquals(null, wrap.acc);
            System.assert(wrap.TotalAmount > 0);

            // Receipt number validation
            System.assert(
                wrap.receiptNo.contains(wrap.acc.Donor_ID__c),
                'Receipt should contain Donor ID'
            );

            // FormattedAddress() coverage
            //System.assert(
           //     wrap.accAddress.contains(wrap.acc.PersonMailingCity)
            //);
            //System.assert(
           //     wrap.accAddress.contains(wrap.acc.PersonMailingState)
           // );
          //  System.assert(
            //    wrap.accAddress.contains(wrap.acc.PersonMailingPostalCode)
//            );
        }

        // Date formatting coverage
        System.assertNotEquals(null, controller.formattedStartDate);
        System.assertNotEquals(null, controller.formattedendYearDate);
    }
}