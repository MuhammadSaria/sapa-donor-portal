@isTest
private class LaunchGoodAllocationHandlerTest {

    private static Account makePersonAccount() {
        RecordType accountRecordType = [
            SELECT Id
            FROM RecordType
            WHERE SObjectType = 'Account'
            AND DeveloperName = 'PersonAccount'
            LIMIT 1
        ];

        Account account = new Account(
            FirstName = 'LaunchGood',
            LastName = 'Handler Test ' + String.valueOf(DateTime.now().getTime()),
            RecordTypeId = accountRecordType.Id
        );
        insert account;
        return account;
    }

    private static GiftTransaction makeGiftTransaction(String channel) {
        GiftTransaction transactionRecord = new GiftTransaction(
            Name = 'GT-' + String.valueOf(DateTime.now().getTime()),
            Channel__c = channel,
            Status = 'Paid',
            PaymentMethod = 'Credit Card',
            OriginalAmount = 25,
            TransactionDueDate = Date.today(),
            TransactionDate = Date.today()
        );
        insert transactionRecord;
        return transactionRecord;
    }

    private static GiftCommitment makeGiftCommitment(String channel) {
        return makeGiftCommitment(channel, 'Stripe');
    }

    private static GiftCommitment makeGiftCommitment(String channel, String paymentProcessor) {
        Account account = makePersonAccount();
        GiftCommitment commitment = new GiftCommitment(
            Name = 'GC-' + String.valueOf(DateTime.now().getTime()),
            DonorId = account.Id,
            Channel__c = channel,
            Payment_Processor__c = paymentProcessor
        );
        insert commitment;
        return commitment;
    }

    @testSetup
    static void setupTestData() {
        // Create the Placeholder Fund required by the downstream routing service
        GiftDesignation placeholder = new GiftDesignation(
            Name = 'Launchgood Import'
        );
        insert placeholder;

        // Create a Target Fund for successful mapping
        GiftDesignation targetFund = new GiftDesignation(
            Name = 'Target Fund Mapping'
        );
        insert targetFund;

        // Create an active mapping record so the routing service changes the status to "Matched"
        LaunchGood_Donation_Fund__c activeMapping = new LaunchGood_Donation_Fund__c(
            Project_URL__c = 'launchgood.com/testproject',
            Active__c = true,
            Funds__c = targetFund.Id
        );
        insert activeMapping;
    }

    @isTest
    static void testHandle_ValidGiftTransactionDesignation() {
        GiftDesignation placeholder = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];
        GiftTransaction transactionRecord = makeGiftTransaction('Launchgood');

        // Create a record that passes all handler conditions
        GiftTransactionDesignation gtd = new GiftTransactionDesignation(
            GiftTransactionId = transactionRecord.Id,
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/testproject',
            GiftDesignationId = placeholder.Id,
            Fund_Match_Status__c = null
        );

        Test.startTest();
        // Invoke handler
        LaunchGoodAllocationHandler.handle(new List<SObject>{gtd}, null, true, false);
        Test.stopTest();

        // Because it passed the handler filters, it should have been routed and updated to Matched
        Assert.areEqual('Matched', gtd.get('Fund_Match_Status__c'), 'The valid GTD record should have been processed and matched.');
    }

    @isTest
    static void testHandle_ValidGiftDefaultDesignation() {
        GiftDesignation placeholder = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];
        GiftCommitment commitment = makeGiftCommitment('Launchgood');

        // Create a record for the other supported SObject type
        GiftDefaultDesignation gdd = new GiftDefaultDesignation(
            ParentRecordId = commitment.Id,
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/testproject',
            GiftDesignationId = placeholder.Id,
            Fund_Match_Status__c = null
        );

        Test.startTest();
        LaunchGoodAllocationHandler.handle(new List<SObject>{gdd}, null, true, false);
        Test.stopTest();

        Assert.areEqual('Matched', gdd.get('Fund_Match_Status__c'), 'The valid GDD record should have been processed and matched.');
    }

    @isTest
    static void testHandle_GiftDefaultDesignationSkipsWhenOnlyPaymentProcessorIsLaunchGood() {
        GiftDesignation placeholder = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];
        GiftCommitment commitment = makeGiftCommitment('Website', 'Launchgood');

        GiftDefaultDesignation gdd = new GiftDefaultDesignation(
            ParentRecordId = commitment.Id,
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/testproject',
            GiftDesignationId = placeholder.Id,
            Fund_Match_Status__c = null
        );

        Test.startTest();
        LaunchGoodAllocationHandler.handle(new List<SObject>{gdd}, null, true, false);
        Test.stopTest();

        Assert.isNull(gdd.get('Fund_Match_Status__c'), 'Recurring records should require Launchgood on GiftCommitment.Channel__c.');
    }

    @isTest
    static void testHandle_SkipConditions() {
        GiftDesignation placeholder = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];
        GiftTransaction launchGoodTransaction = makeGiftTransaction('Launchgood');

        // Record 1: Fails Omatic Import condition
        GiftTransactionDesignation gtdNotOmatic = new GiftTransactionDesignation(
            GiftTransactionId = launchGoodTransaction.Id,
            Omatic_Import__c = false,
            LaunchGood_Project_URL__c = 'launchgood.com/testproject',
            GiftDesignationId = placeholder.Id
        );

        // Record 2: Fails Blank URL condition
        GiftTransactionDesignation gtdBlankUrl = new GiftTransactionDesignation(
            GiftTransactionId = launchGoodTransaction.Id,
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = '',
            GiftDesignationId = placeholder.Id
        );

        // Record 3: Fails Already Matched condition
        GiftTransactionDesignation gtdAlreadyMatched = new GiftTransactionDesignation(
            GiftTransactionId = launchGoodTransaction.Id,
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/testproject',
            GiftDesignationId = placeholder.Id,
            Fund_Match_Status__c = 'Matched'
        );

        List<SObject> recordsToTest = new List<SObject>{gtdNotOmatic, gtdBlankUrl, gtdAlreadyMatched};

        Test.startTest();
        LaunchGoodAllocationHandler.handle(recordsToTest, null, true, false);
        Test.stopTest();

        // If the handler worked correctly, none of these should have been routed.
        // Therefore, their statuses should remain exactly as we set them (null or 'Matched').
        Assert.isNull(gtdNotOmatic.get('Fund_Match_Status__c'), 'Status should remain null because it was not an Omatic Import.');
        Assert.isNull(gtdBlankUrl.get('Fund_Match_Status__c'), 'Status should remain null because the URL was blank.');
        Assert.areEqual('Matched', gtdAlreadyMatched.get('Fund_Match_Status__c'), 'Status should remain Matched because it was skipped.');
    }

    @isTest
    static void testHandle_SkipsNonLaunchGoodChannel() {
        GiftDesignation placeholder = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];
        GiftTransaction transactionRecord = makeGiftTransaction('Website');

        GiftTransactionDesignation gtd = new GiftTransactionDesignation(
            GiftTransactionId = transactionRecord.Id,
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/testproject',
            GiftDesignationId = placeholder.Id
        );

        Test.startTest();
        LaunchGoodAllocationHandler.handle(new List<SObject>{gtd}, null, true, false);
        Test.stopTest();

        Assert.isNull(gtd.get('Fund_Match_Status__c'), 'Non-Launchgood channel records should bypass routing.');
    }

    @isTest
    static void testHandle_RecursionBlock() {
        GiftDesignation placeholder = [SELECT Id FROM GiftDesignation WHERE Name = 'Launchgood Import' LIMIT 1];
        GiftTransaction transactionRecord = makeGiftTransaction('Launchgood');

        GiftTransactionDesignation gtd = new GiftTransactionDesignation(
            GiftTransactionId = transactionRecord.Id,
            Omatic_Import__c = true,
            LaunchGood_Project_URL__c = 'launchgood.com/testproject',
            GiftDesignationId = placeholder.Id
        );

        Test.startTest();
        // First run: Should process successfully and update the record to "Matched"
        LaunchGoodAllocationHandler.handle(new List<SObject>{gtd}, null, true, false);
        Assert.areEqual('Matched', gtd.get('Fund_Match_Status__c'));

        // Reset the status on the record artificially to test the hasRun block
        gtd.put('Fund_Match_Status__c', null);

        // Second run in the same transaction: The hasRun flag is now true, so it should return early
        LaunchGoodAllocationHandler.handle(new List<SObject>{gtd}, null, true, false);
        Test.stopTest();

        // The status should STILL be null because the handler returned immediately without routing
        Assert.isNull(gtd.get('Fund_Match_Status__c'), 'The hasRun recursive block failed to stop the second execution.');
    }

    @isTest
    static void testHandle_NullAndEmptyLists() {
        Test.startTest();
        // Should safely return without throwing a NullPointerException
        LaunchGoodAllocationHandler.handle(null, null, true, false);
        LaunchGoodAllocationHandler.handle(new List<SObject>(), null, true, false);
        Test.stopTest();

        Assert.isTrue(true, 'The handler should gracefully exit when provided with null or empty lists.');
    }
}