@IsTest
private class CampaignPortalLinkControllerTest {

    private static Id personRecordTypeId() {
        return [SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
    }

    private static Account donor(String lastName, String status) {
        // No phone and no address, so both Missing_* formulas are true.
        Account acc = new Account(
            RecordTypeId = personRecordTypeId(),
            FirstName = 'Test',
            LastName = lastName,
            Personal_Email__c = lastName.toLowerCase() + '@example.com',
            Preferred_Email__c = 'Personal'
        );
        if (status != null) {
            acc.Portal_Status__c = status;
        }
        return acc;
    }

    private static void addToCampaign(Campaign c, List<Account> accounts) {
        Map<Id, Account> byId = new Map<Id, Account>(accounts);
        List<CampaignMember> members = new List<CampaignMember>();
        for (Account acc : [SELECT PersonContactId FROM Account WHERE Id IN :byId.keySet()]) {
            members.add(new CampaignMember(CampaignId = c.Id, ContactId = acc.PersonContactId));
        }
        insert members;
    }

    private static User reviewer() {
        User u = new User(
            Alias = 'cplc', Email = 'cplc@example.com', Username = 'cplc' + System.currentTimeMillis() + '@example.com',
            LastName = 'Reviewer', ProfileId = UserInfo.getProfileId(), TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        insert u;
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Portal_Donor_Care_Review'];
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        return u;
    }

    @IsTest
    static void previewAndGenerateApplyTheSkipRules() {
        Account fresh = donor('Fresh', null);
        Account submitted = donor('Submitted', 'Submitted');
        Account valid = donor('Valid', null);
        insert new List<Account>{ fresh, submitted, valid };
        valid.Portal_Token__c = 'keepme';
        valid.Portal_Token_Expiry__c = System.now().addDays(5);
        valid.Portal_Status__c = 'Sent';
        update valid;
        Campaign c = new Campaign(Name = 'Test campaign', IsActive = true);
        insert c;
        addToCampaign(c, new List<Account>{ fresh, submitted, valid });

        System.runAs(reviewer()) {
            CampaignPortalLinkController.Summary p = CampaignPortalLinkController.preview(c.Id);
            System.assertEquals(3, p.totalMembers);
            System.assertEquals(1, p.toIssue);
            System.assertEquals(1, p.alreadySubmitted);
            System.assertEquals(1, p.linkStillValid);
            System.assertEquals(false, p.generated);
            System.assertEquals(null, [SELECT Portal_Token__c FROM Account WHERE Id = :fresh.Id].Portal_Token__c, 'preview must not save');

            CampaignPortalLinkController.Summary g = CampaignPortalLinkController.generate(c.Id);
            System.assertEquals(1, g.toIssue);
            System.assertEquals(true, g.generated);
        }

        Account issued = [SELECT Portal_Token__c, Portal_Status__c, Portal_Campaign__c, Portal_Sent_Date__c FROM Account WHERE Id = :fresh.Id];
        System.assertNotEquals(null, issued.Portal_Token__c);
        System.assertEquals('Sent', issued.Portal_Status__c);
        System.assertEquals(c.Id, issued.Portal_Campaign__c);
        System.assertEquals(Date.today(), issued.Portal_Sent_Date__c);
        System.assertEquals('keepme', [SELECT Portal_Token__c FROM Account WHERE Id = :valid.Id].Portal_Token__c, 'valid link untouched');
        System.assertEquals('Submitted', [SELECT Portal_Status__c FROM Account WHERE Id = :submitted.Id].Portal_Status__c);
    }

    @IsTest
    static void membersWithoutAPersonAccountAreCountedNotIssued() {
        Campaign c = new Campaign(Name = 'Leads campaign', IsActive = true);
        insert c;
        Lead l = new Lead(LastName = 'Lead', Company = 'Acme');
        insert l;
        insert new CampaignMember(CampaignId = c.Id, LeadId = l.Id);

        System.runAs(reviewer()) {
            CampaignPortalLinkController.Summary p = CampaignPortalLinkController.preview(c.Id);
            System.assertEquals(1, p.notPersonAccount);
            System.assertEquals(0, p.toIssue);
        }
    }

    @IsTest
    static void requiresTheReviewPermission() {
        Campaign c = new Campaign(Name = 'Locked', IsActive = true);
        insert c;
        User plain = new User(
            Alias = 'nope', Email = 'nope@example.com', Username = 'nope' + System.currentTimeMillis() + '@example.com',
            LastName = 'Plain', ProfileId = UserInfo.getProfileId(), TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        insert plain;
        System.runAs(plain) {
            try {
                CampaignPortalLinkController.generate(c.Id);
                System.assert(false, 'expected a permission error');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('permission'), e.getMessage());
            }
        }
    }
}
