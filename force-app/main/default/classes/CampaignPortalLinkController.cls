/**
 * "Generate Portal Links" button on Campaign. Donor Care clicks it before sending the List Email, so every member
 * who needs to give details already has a fresh token behind the Portal Link merge field.
 * Gated by the Portal_Donor_Care_Review custom permission (same as the review screen).
 */
public with sharing class CampaignPortalLinkController {

    private static final String REQUIRED_PERMISSION = 'Portal_Donor_Care_Review';
    private static final Integer MEMBER_LIMIT = 10000;

    public class Summary {
        @AuraEnabled public Integer totalMembers = 0;
        @AuraEnabled public Integer toIssue = 0;          // links created (generate) or that would be created (preview)
        @AuraEnabled public Integer alreadySubmitted = 0; // waiting for Donor Care review -- never touched
        @AuraEnabled public Integer nothingMissing = 0;   // phone and address both on file
        @AuraEnabled public Integer linkStillValid = 0;   // a link was already sent and has not expired
        @AuraEnabled public Integer notPersonAccount = 0; // leads, or contacts that are not Person Accounts
        @AuraEnabled public Boolean generated = false;
    }

    @AuraEnabled
    public static Summary preview(Id campaignId) {
        requirePermission();
        return run(campaignId, false);
    }

    @AuraEnabled
    public static Summary generate(Id campaignId) {
        requirePermission();
        return run(campaignId, true);
    }

    private static Summary run(Id campaignId, Boolean save) {
        Summary result = new Summary();
        Set<Id> accountIds = new Set<Id>();
        List<CampaignMember> members = [
            SELECT Id, ContactId, Contact.AccountId
            FROM CampaignMember
            WHERE CampaignId = :campaignId
            LIMIT :MEMBER_LIMIT + 1
        ];
        if (members.size() > MEMBER_LIMIT) {
            throw friendly('This campaign has more than ' + MEMBER_LIMIT + ' members. Please contact an administrator.');
        }
        result.totalMembers = members.size();
        for (CampaignMember cm : members) {
            if (cm.ContactId == null || cm.Contact.AccountId == null) {
                result.notPersonAccount++;
            } else {
                accountIds.add(cm.Contact.AccountId);
            }
        }

        List<Account> toIssue = new List<Account>();
        for (Account acc : [
            SELECT Id, IsPersonAccount, Portal_Status__c, Portal_Token__c, Portal_Token_Expiry__c,
                   Missing_Phone__c, Missing_Mailing_Address__c
            FROM Account
            WHERE Id IN :accountIds
        ]) {
            if (!acc.IsPersonAccount) {
                result.notPersonAccount++;
            } else if (acc.Portal_Status__c == 'Submitted') {
                result.alreadySubmitted++;
            } else if (!acc.Missing_Phone__c && !acc.Missing_Mailing_Address__c) {
                result.nothingMissing++;
            } else if (acc.Portal_Status__c == 'Sent' && String.isNotBlank(acc.Portal_Token__c)
                    && acc.Portal_Token_Expiry__c != null && acc.Portal_Token_Expiry__c > System.now()) {
                result.linkStillValid++;
            } else {
                toIssue.add(acc);
            }
        }
        result.toIssue = toIssue.size();

        if (save && !toIssue.isEmpty()) {
            PortalLinkService.assignTokens(toIssue);
            for (Account acc : toIssue) {
                acc.Portal_Sent_Date__c = System.today();
                acc.Portal_Campaign__c = campaignId;
            }
            // System mode: Donor Care is not given edit access to the token fields, only to this button.
            List<Database.SaveResult> saved = Database.update(toIssue, false, AccessLevel.SYSTEM_MODE);
            Integer failed = 0;
            for (Database.SaveResult sr : saved) {
                if (!sr.isSuccess()) {
                    failed++;
                }
            }
            result.toIssue -= failed;
            if (failed > 0) {
                throw friendly(failed + ' of ' + toIssue.size() + ' links could not be created: ' + firstError(saved));
            }
        }
        result.generated = save;
        return result;
    }

    private static String firstError(List<Database.SaveResult> saved) {
        for (Database.SaveResult sr : saved) {
            if (!sr.isSuccess()) {
                return sr.getErrors()[0].getMessage();
            }
        }
        return '';
    }

    private static void requirePermission() {
        if (!FeatureManagement.checkPermission(REQUIRED_PERMISSION)) {
            throw friendly('You do not have permission to generate portal links.');
        }
    }

    private static AuraHandledException friendly(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
