// Issues a fresh SAPA Update Portal link for ONE donor (by Account Id) and prints it.
//
// Run:  sf apex run -f scripts/apex/generate-portal-link.apex -o SAPA-STAGGING
//   or paste into Developer Console > Debug > Open Execute Anonymous Window.
// Then look for the line starting "PORTAL LINK" in the output.
//
// Edit the two settings below first.

// The Account Id of the donor (a Person Account), e.g. '001Wr00001Gl86tIAB'.
// Find it in the donor's page URL: .../lightning/r/Account/<this part>/view
String accountId = '001XXXXXXXXXXXXXXX';

// true = save the new link on the donor. false = rehearse only (nothing is changed).
Boolean save = true;

// ---------------------------------------------------------------------------------------------------------------

Id donorId;
try {
    donorId = Id.valueOf(accountId);
} catch (Exception e) {
    donorId = null;
}

List<Account> matches = new List<Account>();
if (donorId != null && donorId.getSObjectType() == Account.SObjectType) {
    matches = [SELECT Id, Name, IsPersonAccount FROM Account WHERE Id = :donorId];
}

if (matches.isEmpty()) {
    System.debug('PORTAL LINK -- stopped: "' + accountId + '" is not the Id of an Account that exists in this org.');
} else if (!matches[0].IsPersonAccount) {
    System.debug('PORTAL LINK -- stopped: ' + matches[0].Name + ' is a business account. The portal is for Person Accounts (donors).');
} else {
    Savepoint beforeChange = Database.setSavepoint();

    Account donor = new Account(Id = donorId);
    PortalLinkService.assignTokens(new List<Account>{ donor }); // new token + 30-day expiry, status "Sent", clears old values
    donor.Portal_Sent_Date__c = Date.today();
    update donor;

    Account saved = [SELECT Name, Portal_Link__c, Portal_Token_Expiry__c, Missing_Phone__c, Missing_Mailing_Address__c
                     FROM Account WHERE Id = :donorId];
    System.debug('PORTAL LINK -- ' + saved.Name + ' (asks for phone: ' + saved.Missing_Phone__c
        + ', asks for address: ' + saved.Missing_Mailing_Address__c + ', expires ' + saved.Portal_Token_Expiry__c + ')');
    System.debug('PORTAL LINK ' + saved.Portal_Link__c);

    if (!save) {
        Database.rollback(beforeChange);
        System.debug('PORTAL LINK -- rehearsal only (save = false): nothing was changed, so the link above will NOT work.');
    }
}
