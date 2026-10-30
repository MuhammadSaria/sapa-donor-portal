/**
 * Staff review for SAPA donor portal submissions (doc section 6). Gated by the
 * Portal_Donor_Care_Review custom permission, not just UI hiding (doc section 6).
 */
public with sharing class DonorUpdateReviewController {

    private static final String REQUIRED_PERMISSION = 'Portal_Donor_Care_Review';
    private static final Integer QUEUE_LIMIT = 200;
    private static final Integer MAX_REASON_LENGTH = 1000;
    private static final String ALREADY_PROCESSED = 'This submission has already been reviewed. Refresh the list to see the latest.';

    public class SubmissionRow {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String donorName;
        @AuraEnabled public Datetime submittedDate;
        @AuraEnabled public String currentPhone;
        @AuraEnabled public String newPhone;
        @AuraEnabled public String currentStreet;
        @AuraEnabled public String currentCity;
        @AuraEnabled public String currentState;
        @AuraEnabled public String currentPostalCode;
        @AuraEnabled public String currentCountry;
        @AuraEnabled public String newStreet;
        @AuraEnabled public String newCity;
        @AuraEnabled public String newState;
        @AuraEnabled public String newPostalCode;
        @AuraEnabled public String newCountry;
        @AuraEnabled public Boolean phoneChanged;
        @AuraEnabled public Boolean addressChanged;
    }

    // Oldest first, capped so the queue stays loadable once thousands of donors have been emailed. Accepting or
    // rejecting removes a row, so the next refresh brings the following ones into view.
    @AuraEnabled
    public static List<SubmissionRow> getPendingSubmissions() {
        requirePermission();
        List<SubmissionRow> rows = new List<SubmissionRow>();
        for (Account acc : [
            SELECT Id, Name, LastModifiedDate, Portal_Submitted_Date__c,
                   Phone, PersonMobilePhone, PersonHomePhone, WorkPhone__c,
                   PersonMailingStreet, PersonMailingCity, PersonMailingState, PersonMailingPostalCode, PersonMailingCountry,
                   New_Phone__c, New_Street__c, New_City__c, New_State__c, New_Postal_Code__c, New_Country__c
            FROM Account
            WHERE Portal_Status__c = 'Submitted'
            ORDER BY Portal_Submitted_Date__c ASC NULLS LAST, LastModifiedDate ASC
            LIMIT :QUEUE_LIMIT
        ]) {
            SubmissionRow row = new SubmissionRow();
            row.accountId = acc.Id;
            row.donorName = acc.Name;
            // Submissions made before Portal_Submitted_Date__c existed fall back to the last-modified time.
            row.submittedDate = acc.Portal_Submitted_Date__c != null ? acc.Portal_Submitted_Date__c : acc.LastModifiedDate;
            row.currentPhone = firstNonBlank(new List<String>{ acc.Phone, acc.PersonMobilePhone, acc.PersonHomePhone, acc.WorkPhone__c });
            row.newPhone = acc.New_Phone__c;
            row.currentStreet = acc.PersonMailingStreet;
            row.currentCity = acc.PersonMailingCity;
            row.currentState = acc.PersonMailingState;
            row.currentPostalCode = acc.PersonMailingPostalCode;
            row.currentCountry = acc.PersonMailingCountry;
            row.newStreet = acc.New_Street__c;
            row.newCity = acc.New_City__c;
            row.newState = acc.New_State__c;
            row.newPostalCode = acc.New_Postal_Code__c;
            row.newCountry = acc.New_Country__c;
            row.phoneChanged = String.isNotBlank(acc.New_Phone__c);
            row.addressChanged = isAddressChanged(acc);
            rows.add(row);
        }
        return rows;
    }

    @AuraEnabled
    public static void accept(Id accountId) {
        review(accountId, true, true, null);
    }

    @AuraEnabled
    public static void reject(Id accountId, String reason) {
        review(accountId, false, false, reason);
    }

    /**
     * Phone and address are decided separately. A part the donor did not submit is ignored, so only the submitted
     * parts need a decision. Anything accepted is copied to the donor record; anything rejected is dropped. The
     * submission ends as Accepted when at least one part was applied (or nothing was submitted), otherwise Rejected.
     */
    @AuraEnabled
    public static void review(Id accountId, Boolean acceptPhone, Boolean acceptAddress, String reason) {
        requirePermission();
        // FOR UPDATE so two reviewers clicking on the same row can't both pass the status check.
        List<Account> found = [
            SELECT Id, PersonEmail, Preferred_Email__c, Personal_Email__c, Work_Email__c, Alternate_Email__c,
                   New_Phone__c, New_Street__c, New_City__c, New_State__c, New_Postal_Code__c, New_Country__c,
                   Portal_Campaign__c, PersonContactId
            FROM Account
            WHERE Id = :accountId AND Portal_Status__c = 'Submitted'
            LIMIT 1
            FOR UPDATE
        ];
        if (found.isEmpty()) {
            throw friendly(ALREADY_PROCESSED);
        }
        Account acc = found[0];

        Boolean phoneSubmitted = String.isNotBlank(acc.New_Phone__c);
        Boolean addressSubmitted = isAddressChanged(acc);
        Boolean applyPhone = phoneSubmitted && acceptPhone == true;
        Boolean applyAddress = addressSubmitted && acceptAddress == true;
        List<String> rejectedParts = new List<String>();
        if (phoneSubmitted && !applyPhone) {
            rejectedParts.add('Phone');
        }
        if (addressSubmitted && !applyAddress) {
            rejectedParts.add('Address');
        }
        Boolean anyApplied = applyPhone || applyAddress;

        Account toUpdate = new Account(Id = acc.Id);
        if (applyPhone) {
            toUpdate.PersonMobilePhone = acc.New_Phone__c;
            protectPersonEmail(acc, toUpdate);
        }
        if (applyAddress) {
            // Re-resolved here as well as at submit: it also repairs rows held before submit-time normalization
            // existed (e.g. a state stored as "IL"), which the restricted State/Country picklists would reject.
            PortalAddressNormalizer.Result normalized = PortalAddressNormalizer.normalize(acc.New_Country__c, acc.New_State__c);
            if (!normalized.errors.isEmpty()) {
                throw friendly('The submitted address cannot be saved: ' + normalized.errors[0].message
                    + ' Reject the address (or the whole submission) so the donor can be sent a new link.');
            }
            toUpdate.PersonMailingStreet = acc.New_Street__c;
            toUpdate.PersonMailingCity = acc.New_City__c;
            toUpdate.PersonMailingState = normalized.state;
            toUpdate.PersonMailingPostalCode = acc.New_Postal_Code__c;
            toUpdate.PersonMailingCountry = normalized.country;
        }

        clearHeldValuesAndToken(toUpdate);
        toUpdate.Portal_Reject_Reason__c = rejectReasonFor(rejectedParts, anyApplied, reason);
        // Verified only when something was actually applied to the donor record.
        if (anyApplied || rejectedParts.isEmpty()) {
            toUpdate.Contact_Info_Verified_Date__c = Date.today();
        }
        toUpdate.Portal_Reviewed_By__c = UserInfo.getUserId();
        toUpdate.Portal_Reviewed_Date__c = System.now();
        toUpdate.Portal_Status__c = (anyApplied || rejectedParts.isEmpty()) ? 'Accepted' : 'Rejected';
        try {
            update toUpdate;
        } catch (DmlException e) {
            throw friendly('The donor record could not be updated: ' + e.getDmlMessage(0));
        }

        if (anyApplied || rejectedParts.isEmpty()) {
            markCampaignMemberResponded(acc);
        }
    }

    // A full rejection stores the reviewer's reason as typed. A partial one names the rejected part(s) so the record
    // still shows what was dropped; a full acceptance stores nothing.
    private static String rejectReasonFor(List<String> rejectedParts, Boolean anyApplied, String reason) {
        if (rejectedParts.isEmpty()) {
            return null;
        }
        String trimmed = String.isBlank(reason) ? null : reason.trim();
        if (!anyApplied) {
            return trimmed == null ? null : trimmed.left(MAX_REASON_LENGTH);
        }
        String label = String.join(rejectedParts, ' and ') + ' rejected';
        return (trimmed == null ? label : label + ': ' + trimmed).left(MAX_REASON_LENGTH);
    }

    // Writing any phone field re-runs this org's after-save "preferred contact" flow (To_update_contact_Records),
    // which re-derives PersonEmail from the donor's PREFERRED email field. If that field is blank the flow blanks
    // PersonEmail. So copy the current PersonEmail into the preferred field -- but only when that field is empty, so a
    // donor whose preferred email is already populated (or is Work/Alternate) is never overwritten or cross-filled.
    private static void protectPersonEmail(Account acc, Account toUpdate) {
        if (String.isBlank(acc.PersonEmail)) {
            return;
        }
        if (acc.Preferred_Email__c == 'Personal' && String.isBlank(acc.Personal_Email__c)) {
            toUpdate.Personal_Email__c = acc.PersonEmail;
        } else if (acc.Preferred_Email__c == 'Work' && String.isBlank(acc.Work_Email__c)) {
            toUpdate.Work_Email__c = acc.PersonEmail;
        } else if (acc.Preferred_Email__c == 'Alternate' && String.isBlank(acc.Alternate_Email__c)) {
            toUpdate.Alternate_Email__c = acc.PersonEmail;
        }
    }

    // "Responded" only exists on a campaign if it is one of that campaign's member statuses; setting any other value
    // throws, which would roll back the whole Accept. So check first, and never let this step fail the Accept.
    private static void markCampaignMemberResponded(Account acc) {
        if (acc.Portal_Campaign__c == null || acc.PersonContactId == null) {
            return;
        }
        Integer respondedStatuses = [
            SELECT COUNT() FROM CampaignMemberStatus WHERE CampaignId = :acc.Portal_Campaign__c AND Label = 'Responded'
        ];
        if (respondedStatuses == 0) {
            return;
        }
        List<CampaignMember> members = [
            SELECT Id, Status FROM CampaignMember
            WHERE CampaignId = :acc.Portal_Campaign__c AND ContactId = :acc.PersonContactId
            LIMIT 1
        ];
        if (!members.isEmpty() && members[0].Status != 'Responded') {
            members[0].Status = 'Responded';
            Database.update(members[0], false);
        }
    }

    private static void clearHeldValuesAndToken(Account toUpdate) {
        toUpdate.New_Phone__c = null;
        toUpdate.New_Street__c = null;
        toUpdate.New_City__c = null;
        toUpdate.New_State__c = null;
        toUpdate.New_Postal_Code__c = null;
        toUpdate.New_Country__c = null;
        toUpdate.Portal_Token__c = null;
        toUpdate.Portal_Token_Expiry__c = null;
    }

    private static Boolean isAddressChanged(Account acc) {
        return String.isNotBlank(acc.New_Street__c) || String.isNotBlank(acc.New_City__c)
            || String.isNotBlank(acc.New_State__c) || String.isNotBlank(acc.New_Postal_Code__c)
            || String.isNotBlank(acc.New_Country__c);
    }

    private static void requirePermission() {
        if (!FeatureManagement.checkPermission(REQUIRED_PERMISSION)) {
            throw friendly('You do not have access to review SAPA Portal submissions.');
        }
    }

    // AuraHandledException hides its message from getMessage() unless setMessage is called.
    private static AuraHandledException friendly(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    private static String firstNonBlank(List<String> candidates) {
        for (String candidate : candidates) {
            if (String.isNotBlank(candidate)) {
                return candidate;
            }
        }
        return null;
    }
}
