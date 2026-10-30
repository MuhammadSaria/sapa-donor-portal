/**
 * Token + expiry creation for the SAPA donor update portal.
 * Pattern reference: ALM UK GiftAidPortalTokenService.
 */
public with sharing class PortalLinkService {

    private static final Integer DEFAULT_VALIDITY_DAYS = 30;

    public static String newToken() {
        return EncodingUtil.convertToHex(Crypto.generateAesKey(256));
    }

    /**
     * Issues a fresh link on each Account: new token + expiry, status back to "Sent", and any held values or review
     * stamps from an earlier round cleared. Without the reset, a donor who was already Submitted/Accepted/Rejected
     * would get a brand-new link that immediately says "already sent". Performs no DML -- the caller updates.
     */
    public static void assignTokens(List<Account> accounts) {
        Datetime expiry = System.now().addDays(validityDays());
        for (Account acc : accounts) {
            acc.Portal_Token__c = newToken();
            acc.Portal_Token_Expiry__c = expiry;
            acc.Portal_Status__c = 'Sent';
            acc.New_Phone__c = null;
            acc.New_Street__c = null;
            acc.New_City__c = null;
            acc.New_State__c = null;
            acc.New_Postal_Code__c = null;
            acc.New_Country__c = null;
            acc.Portal_Submitted_Date__c = null;
            acc.Portal_Reject_Reason__c = null;
        }
    }

    private static Integer validityDays() {
        String configured = System.Label.Portal_Link_Validity_Days;
        if (String.isBlank(configured) || !configured.isNumeric() || Integer.valueOf(configured) < 1) {
            return DEFAULT_VALIDITY_DAYS;
        }
        return Integer.valueOf(configured);
    }
}