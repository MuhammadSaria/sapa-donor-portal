@isTest
private class PortalLinkServiceTest {

    private static Account newPersonAccount(String lastName) {
        Id personAccountRecordTypeId = [SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
        return new Account(RecordTypeId = personAccountRecordTypeId, FirstName = 'Test', LastName = lastName);
    }

    @isTest
    static void newTokenReturns64LowercaseHexChars() {
        String token = PortalLinkService.newToken();
        System.assertEquals(64, token.length(), 'Token must be 64 characters');
        System.assert(Pattern.matches('^[0-9a-f]{64}$', token), 'Token must be lowercase hex: ' + token);
    }

    @isTest
    static void newTokenIsRandomEachCall() {
        String first = PortalLinkService.newToken();
        String second = PortalLinkService.newToken();
        System.assertNotEquals(first, second, 'Two tokens should not collide');
    }

    @isTest
    static void assignTokensSetsTokenAndExpiryWithoutDml() {
        List<Account> accounts = new List<Account>{
            newPersonAccount('AssignTokensA'),
            newPersonAccount('AssignTokensB')
        };

        Integer countBefore = [SELECT COUNT() FROM Account WHERE LastName IN ('AssignTokensA', 'AssignTokensB')];

        Datetime before = System.now();
        PortalLinkService.assignTokens(accounts);
        Datetime after = System.now();

        Integer countAfter = [SELECT COUNT() FROM Account WHERE LastName IN ('AssignTokensA', 'AssignTokensB')];
        System.assertEquals(countBefore, countAfter, 'assignTokens must perform no DML');

        Set<String> tokens = new Set<String>();
        for (Account acc : accounts) {
            System.assert(String.isNotBlank(acc.Portal_Token__c), 'Token must be set');
            System.assert(Pattern.matches('^[0-9a-f]{64}$', acc.Portal_Token__c), 'Token must be lowercase hex');
            tokens.add(acc.Portal_Token__c);

            System.assertNotEquals(null, acc.Portal_Token_Expiry__c, 'Expiry must be set');
            Datetime expectedMin = before.addDays(30).addMinutes(-1);
            Datetime expectedMax = after.addDays(30).addMinutes(1);
            System.assert(acc.Portal_Token_Expiry__c >= expectedMin && acc.Portal_Token_Expiry__c <= expectedMax,
                'Expiry should be ~30 days out (the configured Portal_Link_Validity_Days default)');
        }
        System.assertEquals(2, tokens.size(), 'Each account should get a distinct token');
    }

    // A donor who went through an earlier round (Submitted/Accepted/Rejected) must get a usable link, not one that
    // immediately reads "already sent", and must not carry held values over from that earlier round.
    @isTest
    static void assignTokensResetsStatusAndEarlierRoundValues() {
        Account acc = newPersonAccount('AssignTokensReset');
        acc.Portal_Status__c = 'Rejected';
        acc.New_Phone__c = '5551230001';
        acc.New_Street__c = '1 Old St';
        acc.Portal_Reject_Reason__c = 'Earlier reason';

        PortalLinkService.assignTokens(new List<Account>{ acc });

        System.assertEquals('Sent', acc.Portal_Status__c);
        System.assertEquals(null, acc.New_Phone__c);
        System.assertEquals(null, acc.New_Street__c);
        System.assertEquals(null, acc.Portal_Reject_Reason__c);
        System.assertEquals(null, acc.Portal_Submitted_Date__c);
    }

    @isTest
    static void assignTokensWorksWithRealDmlByCaller() {
        Account acc = newPersonAccount('AssignTokensPersisted');
        insert acc;

        PortalLinkService.assignTokens(new List<Account>{ acc });
        update acc;

        Account persisted = [SELECT Portal_Token__c, Portal_Token_Expiry__c FROM Account WHERE Id = :acc.Id];
        System.assert(String.isNotBlank(persisted.Portal_Token__c), 'Token must persist once the caller updates');
        System.assertNotEquals(null, persisted.Portal_Token_Expiry__c, 'Expiry must persist once the caller updates');
    }
}