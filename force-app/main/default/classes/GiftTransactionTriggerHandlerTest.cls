@IsTest
private class GiftTransactionTriggerHandlerTest {

    // -----------------------------
    // Helpers
    // -----------------------------
    private static Id getAnyRecordTypeId(String sobjectApiName) {
        Schema.SObjectType t = Schema.getGlobalDescribe().get(sobjectApiName);
        if (t == null) return null;

        Schema.DescribeSObjectResult d = t.getDescribe();
        List<Schema.RecordTypeInfo> rtis = d.getRecordTypeInfos();

        if (rtis == null || rtis.isEmpty()) return null;

        for (Schema.RecordTypeInfo rti : rtis) {
            if (rti.isAvailable() && !rti.isMaster()) {
                return rti.getRecordTypeId();
            }
        }
        for (Schema.RecordTypeInfo rti : rtis) {
            if (rti.isAvailable()) {
                return rti.getRecordTypeId();
            }
        }
        return null;
    }

    private static Account makePersonAccount() {
        RecordType accRecType = [
            SELECT Id
            FROM RecordType
            WHERE SObjectType = 'Account'
            AND DeveloperName = 'PersonAccount'
            LIMIT 1
        ];

        Account acc = new Account(
            FirstName = 'Test',
            LastName = 'User ' + String.valueOf(DateTime.now().getTime()),
            RecordTypeId = accRecType.Id
        );
        insert acc;
        return acc;
    }

    private static Campaign makeCampaign() {
        Campaign c = new Campaign(
            Name = 'UT Campaign ' + String.valueOf(DateTime.now().getTime()),
            IsActive = true
        );
        insert c;
        return c;
    }

    private static GiftCommitment makeGiftCommitment() {
        Account acc = makePersonAccount();

        GiftCommitment gc = new GiftCommitment();
        gc.Name = 'GC Test';
        gc.DonorId = acc.Id;
        gc.Receipt_Allocations__c = 'old receipt';
        gc.No_Postal_Receipt__c = false; 
        gc.Channel__c = 'Website';
        gc.Payment_Processor__c = 'Stripe';
        gc.Team__c = 'Donor Care';
        gc.Anonymous__c = false;
        gc.Notification_Recepient_Email__c = 'old@example.com';
        insert gc;
        return gc;
    }

    private static GiftDesignation makeGiftDesignation(String name) {
        GiftDesignation gd = new GiftDesignation();
        gd.Name = name;
        insert gd;
        return gd;
    }

    private static GiftTransaction makeGiftTransaction(
        Id commitmentId,
        Id campaignId,
        String intention,
        Decimal amount,
        String currencyIso,
        String fupCurrencyIso,
        String campaignName,
        String campaignCode,
        String tributeeName
    ) {
        GiftTransaction gt = new GiftTransaction();

        gt.Name = 'GT-' + String.valueOf(DateTime.now().getTime());
        gt.FUp_Donation_ID__c = 'DON-' + String.valueOf(Crypto.getRandomInteger());
        gt.FUp_Intention_Designation__c = intention;
        gt.FUp_Donation_Amount__c = amount;
        gt.CurrencyIsoCode = currencyIso;
        gt.FUp_Currency_ISO_Code__c = fupCurrencyIso;
        gt.GiftCommitmentId = commitmentId;

        gt.Channel__c = 'Website';
        gt.FUp_Payment_Processor__c = 'Stripe';
        gt.Team__c = 'Donor Care';
        gt.Anonymous__c = true;
        gt.Notification_Recipient_Email__c = 'notify@example.com';
        gt.No_Postal_Receipt__c = false;

        gt.CampaignId = campaignId;
        gt.FUp_Campaign_Name__c = campaignName;
        gt.FUp_Campaign_Code__c = campaignCode;
        gt.FUp_Tributee_s_name__c = tributeeName;

        gt.TransactionDueDate = Date.today();
        gt.Status = 'Paid';
        gt.TransactionDate = System.today();
        gt.PaymentMethod = 'Credit Card';
        gt.OriginalAmount = amount;

        insert gt;
        return gt;
    }

    private static GiftTransactionDesignation makeGTD(
        Id gtId,
        Id designationId,
        String initialIntention,
        Decimal amount
    ) {
        GiftTransactionDesignation gtd = new GiftTransactionDesignation();
        gtd.GiftTransactionId = gtId;
        gtd.GiftDesignationId = designationId;
        gtd.Intention__c = initialIntention;
        gtd.Amount = amount;
        gtd.Locations__c = 'Where Most Needed';
        gtd.Percent = 100;
        insert gtd;
        return gtd;
    }

    // -----------------------------
    // Tests
    // -----------------------------

    @IsTest
    static void test_guardClauses_null_and_empty() {
        Test.startTest();
        GiftTransactionTriggerHandler.sync(null);
        GiftTransactionTriggerHandler.sync(new Set<Id>());
        Test.stopTest();

        System.assert(true, 'Guard clauses should not fail.');
    }

    @IsTest
    static void test_sync_ignores_GT_when_donation_id_null() {
        GiftTransaction gt = new GiftTransaction();
        gt.Name = 'GT-NoDonation';
        gt.TransactionDate = system.today();
        gt.Status = 'Paid'; 
        gt.PaymentMethod = 'Credit Card';
        gt.OriginalAmount = 10;
        gt.TransactionDueDate = Date.today();
        insert gt;

        Test.startTest();
        GiftTransactionTriggerHandler.sync(new Set<Id>{ gt.Id });
        Test.stopTest();

        System.assertNotEquals(null, gt.Id, 'GT should insert and sync should no-op.');
    }

    @IsTest
    static void test_sync_updates_GTD_GC_GDD_and_OSC() {
        GiftCommitment gc = makeGiftCommitment();
        Campaign camp = makeCampaign();
        GiftDesignation gd = makeGiftDesignation('UT Designation A');

        GiftTransaction gt = makeGiftTransaction(
            gc.Id,
            camp.Id,
            'Scholarships',
            50,
            'USD',
            'GBP',
            'Ramadan Appeal',
            'RAM-001',
            'In Memory Of X'
        );

        GiftTransactionDesignation gtd = makeGTD(
            gt.Id,
            gd.Id,
            'Old Intention',
            50
        );

        Test.startTest();
        GiftTransactionTriggerHandler.sync(new Set<Id>{ gt.Id });
        Test.stopTest();

        // GTD updated
        GiftTransactionDesignation gtdAfter = [
            SELECT Id, Intention__c, Tribute_or_Plaque__c, GiftDesignationId
            FROM GiftTransactionDesignation
            WHERE Id = :gtd.Id
        ];
        System.assertEquals('Scholarships', gtdAfter.Intention__c);
        System.assertEquals('In Memory Of X', gtdAfter.Tribute_or_Plaque__c);
        System.assertEquals(gd.Id, gtdAfter.GiftDesignationId);

        // OSC inserted and GT updated
        GiftTransaction gtAfter = [
            SELECT Id, OutreachSourceCodeId, No_Postal_Receipt__c, Receipt_Allocations__c
            FROM GiftTransaction
            WHERE Id = :gt.Id
        ];
        System.assertNotEquals(null, gtAfter.OutreachSourceCodeId, 'OSC should be linked.');
        System.assertEquals(true, gtAfter.No_Postal_Receipt__c, 'No postal receipt should be forced true.');
        System.assert(gtAfter.Receipt_Allocations__c != null, 'Receipt should be populated.');
        System.assert(gtAfter.Receipt_Allocations__c.contains('UT Designation A'));
        System.assert(gtAfter.Receipt_Allocations__c.contains('Scholarships'));
        System.assert(gtAfter.Receipt_Allocations__c.contains('USD'));

        OutreachSourceCode osc = [
            SELECT Id, Name, CampaignId, FUp_Campaign_Code__c, SourceCode
            FROM OutreachSourceCode
            WHERE Id = :gtAfter.OutreachSourceCodeId
        ];
        System.assertEquals('Ramadan Appeal', osc.Name);
        System.assertEquals(camp.Id, osc.CampaignId);
        System.assertEquals('RAM-001', osc.FUp_Campaign_Code__c);
        System.assert(String.isNotBlank(osc.SourceCode), 'SourceCode should be generated.');

        // GC updated
        GiftCommitment gcAfter = [
            SELECT Id,
                   Receipt_Allocations__c,
                   No_Postal_Receipt__c,
                   Channel__c,
                   Payment_Processor__c,
                   Team__c,
                   Anonymous__c,
                   Notification_Recepient_Email__c
            FROM GiftCommitment
            WHERE Id = :gc.Id
        ];
        System.assertEquals(true, gcAfter.No_Postal_Receipt__c);
        System.assertEquals('Website', gcAfter.Channel__c);
        System.assertEquals('Stripe', gcAfter.Payment_Processor__c);
        System.assertEquals('Donor Care', gcAfter.Team__c);
        System.assertEquals(true, gcAfter.Anonymous__c);
        System.assertEquals('notify@example.com', gcAfter.Notification_Recepient_Email__c);
        System.assert(gcAfter.Receipt_Allocations__c.contains('UT Designation A'));
        System.assert(gcAfter.Receipt_Allocations__c.contains('Scholarships'));

        // GDD inserted
        List<GiftDefaultDesignation> gdds = [
            SELECT Id, ParentRecordId, GiftDesignationId, Intention__c,
                   Amount__c, Locations__c, AllocatedPercentage, Tribute_or_Plaque__c
            FROM GiftDefaultDesignation
            WHERE ParentRecordId = :gc.Id
        ];
        System.assertEquals(1, gdds.size());
        System.assertEquals(gc.Id, gdds[0].ParentRecordId);
        System.assertEquals(gd.Id, gdds[0].GiftDesignationId);
        System.assertEquals('Scholarships', gdds[0].Intention__c);
        System.assertEquals('Where Most Needed', gdds[0].Locations__c);
        System.assertEquals('In Memory Of X', gdds[0].Tribute_or_Plaque__c);
        System.assertEquals(100, Integer.valueOf(gdds[0].AllocatedPercentage));
    }

    @IsTest
    static void test_sync_normalizes_where_most_needed_to_general_donation() {
        GiftCommitment gc = makeGiftCommitment();
        GiftDesignation gd = makeGiftDesignation('UT Designation B');

        GiftTransaction gt = makeGiftTransaction(
            gc.Id,
            null,
            'Where Most Needed',
            20,
            'USD',
            null,
            null,
            null,
            null
        );

        GiftTransactionDesignation gtd = makeGTD(
            gt.Id,
            gd.Id,
            'Old Value',
            20
        );

        Test.startTest();
        GiftTransactionTriggerHandler.sync(new Set<Id>{ gt.Id });
        Test.stopTest();

        GiftTransactionDesignation gtdAfter = [
            SELECT Id, Intention__c
            FROM GiftTransactionDesignation
            WHERE Id = :gtd.Id
        ];
        System.assertEquals(
            'General Donation',
            gtdAfter.Intention__c,
            'Where Most Needed should normalize to General Donation'
        );

        GiftDefaultDesignation gddAfter = [
            SELECT Id, Intention__c
            FROM GiftDefaultDesignation
            WHERE ParentRecordId = :gc.Id
            LIMIT 1
        ];
        System.assertEquals(
            'General Donation',
            gddAfter.Intention__c,
            'GDD should also store normalized intention'
        );
    }

    @IsTest
    
static void test_sync_updates_existing_GDD() { 
    GiftCommitment gc = makeGiftCommitment();
    GiftDesignation gd = makeGiftDesignation('UT Designation C');

    GiftTransaction gt = makeGiftTransaction(
        gc.Id,
        null,
        'Zakat',
        75,
        'USD',
        null,
        null,
        null,
        'Tribute Test'
    );

    // Insert existing GDD FIRST, before GTD insert fires sync
    GiftDefaultDesignation existing = new GiftDefaultDesignation(
        ParentRecordId = gc.Id,
        GiftDesignationId = gd.Id,
        Intention__c = 'Old Intention',
        Amount__c = 10,
        Locations__c = 'Old Location',
        AllocatedPercentage = 100
    );
    insert existing;

    // Now insert GTD
    GiftTransactionDesignation gtd = makeGTD(
        gt.Id,
        gd.Id,
        'Old Intention',
        75
    );

    Test.startTest();
    GiftTransactionTriggerHandler.sync(new Set<Id>{ gt.Id });
    Test.stopTest();

    GiftDefaultDesignation gddAfter = [
        SELECT Id, Intention__c, Amount__c, Locations__c, AllocatedPercentage
        FROM GiftDefaultDesignation
        WHERE Id = :existing.Id
    ];

    System.assertEquals('Zakat', gddAfter.Intention__c);
    System.assertEquals(75, gddAfter.Amount__c); 
   // System.assertEquals('Old Location', gddAfter.Locations__c);
    System.assertEquals(100, Integer.valueOf(gddAfter.AllocatedPercentage));
}
    @IsTest
    static void test_sync_reuses_existing_OSC_instead_of_inserting_duplicate() {
        GiftCommitment gc = makeGiftCommitment();
        Campaign camp = makeCampaign();
        GiftDesignation gd = makeGiftDesignation('UT Designation D');

        OutreachSourceCode existingOsc = new OutreachSourceCode(
            Name = 'Existing Appeal',
            CampaignId = camp.Id,
            SourceCode = 'SRC-' + String.valueOf(Math.abs(Crypto.getRandomInteger())),
            FUp_Campaign_Code__c = 'EX-001'
        );
        insert existingOsc;

        GiftTransaction gt = makeGiftTransaction(
            gc.Id,
            camp.Id,
            'Lillah',
            30,
            'USD',
            null,
            'Existing Appeal',
            'EX-001',
            null
        );

        makeGTD(gt.Id, gd.Id, 'Old', 30);

        Test.startTest();
        GiftTransactionTriggerHandler.sync(new Set<Id>{ gt.Id });
        Test.stopTest();

        GiftTransaction gtAfter = [
            SELECT Id, OutreachSourceCodeId
            FROM GiftTransaction
            WHERE Id = :gt.Id
        ];
        System.assertEquals(
            existingOsc.Id,
            gtAfter.OutreachSourceCodeId,
            'Existing OSC should be reused'
        );

        Integer countOsc = [
            SELECT Count()
            FROM OutreachSourceCode
            WHERE Name = 'Existing Appeal'
            AND CampaignId = :camp.Id
        ];
        System.assertEquals(1, countOsc, 'Duplicate OSC should not be created.');
    }
}