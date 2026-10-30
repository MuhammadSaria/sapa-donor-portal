/**
 * The only class the SAPA Update Portal guest profile may call (doc section 2 rule 2, section 8).
 * Every check (token, expiry, status, which sections are editable) is repeated here on submit --
 * never trust what the client sends (doc section 2 rule 7).
 */
public without sharing class DonorUpdatePortalController {

    public class PortalData {
        // doc section 6 calls this "state"; renamed to avoid colliding with the address field "state" below.
        @AuraEnabled public String portalState; // READY, EXPIRED, USED, INVALID
        @AuraEnabled public String firstName;
        @AuraEnabled public String lastName;
        @AuraEnabled public String email;
        @AuraEnabled public String phone;
        @AuraEnabled public String street;
        @AuraEnabled public String city;
        @AuraEnabled public String state;
        @AuraEnabled public String postalCode;
        @AuraEnabled public String country;
        @AuraEnabled public Boolean phoneEditable;
        @AuraEnabled public Boolean addressEditable;
        @AuraEnabled public String reasonText;
    }

    public class PortalSubmitResult {
        @AuraEnabled public Boolean ok;
        @AuraEnabled public List<PortalValidator.ValidationError> errors;
    }

    private static final Set<String> USED_STATUSES = new Set<String>{ 'Submitted', 'Accepted', 'Rejected' };

    // Not cacheable: the response carries donor details keyed by a secret token, and it must reflect a
    // just-submitted link as USED rather than replay a cached READY response (the network serves Apex via CDN).
    @AuraEnabled
    public static PortalData getPortalData(String token) {
        Account acc = findByToken(token);
        PortalData data = new PortalData();
        data.portalState = determineState(acc);

        if (data.portalState != 'READY') {
            data.reasonText = System.Label.Portal_Invalid_Link_Message;
            return data; // no donor data for a bad/expired/used token -- never reveals whether a donor exists
        }

        data.firstName = acc.FirstName;
        data.lastName = acc.LastName;
        data.email = acc.PersonEmail;
        data.phone = firstNonBlank(new List<String>{ acc.Phone, acc.PersonMobilePhone, acc.PersonHomePhone, acc.WorkPhone__c });
        data.street = acc.PersonMailingStreet;
        data.city = acc.PersonMailingCity;
        data.state = acc.PersonMailingState;
        data.postalCode = acc.PersonMailingPostalCode;
        data.country = acc.PersonMailingCountry;
        data.phoneEditable = acc.Missing_Phone__c;
        data.addressEditable = acc.Missing_Mailing_Address__c;
        data.reasonText = System.Label.Portal_Reason_Text;
        return data;
    }

    // Reference data only (the org's country and state lists) -- no donor information and no token needed -- so it is
    // safe to cache. Lets the form offer every country the donor record accepts, with states only where they exist.
    @AuraEnabled(cacheable=true)
    public static List<PortalAddressNormalizer.CountryOption> getAddressOptions() {
        return PortalAddressNormalizer.getOptions();
    }

    /**
     * Takes individual fields rather than a single wrapper object: a nested Apex type as an
     * @AuraEnabled method PARAMETER was found not to deserialize at all for guest users in this
     * org (every field arrived null, though the same nested type works fine as a RETURN type --
     * see getPortalData/PortalData above, and DonorUpdateReviewController.SubmissionRow, which is
     * only ever returned, never accepted as a parameter). Confirmed via direct guest REST replay
     * and the real deployed LWC, not just a local reproduction.
     *
     * The address block counts as "started" only when street/city/state/zip has something in it (country
     * alone never does -- the form always has one selected). A donor who only gives a phone number sends the
     * address fields null and is not asked for an address.
     */
    @AuraEnabled
    public static PortalSubmitResult submitUpdate(
        String token, String phone, String street, String city, String state, String postalCode, String country
    ) {
        Account acc = findByTokenForUpdate(token);

        if (determineState(acc) != 'READY') {
            return genericFailure();
        }

        Boolean phoneEditable = acc.Missing_Phone__c;
        Boolean addressEditable = acc.Missing_Mailing_Address__c;
        Boolean addressStarted = addressEditable && PortalValidator.isAddressStarted(street, city, state, postalCode, country);

        // Resolve the typed country/state to what the org's restricted picklists accept ("IL" -> "Illinois", "USA" ->
        // "United States"), so the value stored here can actually be written to the donor record at Accept.
        List<PortalValidator.ValidationError> errors = new List<PortalValidator.ValidationError>();
        String cleanCountry = country;
        String cleanState = state;
        if (addressStarted) {
            PortalAddressNormalizer.Result normalized = PortalAddressNormalizer.normalize(country, state);
            errors.addAll(normalized.errors);
            cleanCountry = normalized.country;
            cleanState = normalized.state;
        }
        List<PortalValidator.ValidationError> ruleErrors = PortalValidator.validateSubmission(
            phoneEditable, phone,
            addressEditable, street, city, cleanState, postalCode, cleanCountry
        );
        if (hasErrorFor(errors, 'country')) {
            // An unrecognised country leaves nothing to judge state/ZIP against; don't pile on US-only complaints.
            List<PortalValidator.ValidationError> relevant = new List<PortalValidator.ValidationError>();
            for (PortalValidator.ValidationError candidate : ruleErrors) {
                if (candidate.field != 'state' && candidate.field != 'postalCode') {
                    relevant.add(candidate);
                }
            }
            ruleErrors = relevant;
        }
        mergeErrors(errors, ruleErrors);

        PortalSubmitResult result = new PortalSubmitResult();
        if (!errors.isEmpty()) {
            result.ok = false;
            result.errors = errors;
            return result;
        }

        Account toUpdate = new Account(Id = acc.Id);
        if (phoneEditable && String.isNotBlank(phone)) {
            toUpdate.New_Phone__c = phone.trim();
        }
        if (addressStarted) {
            toUpdate.New_Street__c = trimToNull(street);
            toUpdate.New_City__c = trimToNull(city);
            toUpdate.New_State__c = trimToNull(cleanState);
            toUpdate.New_Postal_Code__c = trimToNull(postalCode);
            toUpdate.New_Country__c = trimToNull(cleanCountry);
        }
        toUpdate.Portal_Status__c = 'Submitted';
        toUpdate.Portal_Submitted_Date__c = System.now();
        Database.update(toUpdate, AccessLevel.SYSTEM_MODE);

        result.ok = true;
        result.errors = new List<PortalValidator.ValidationError>();
        return result;
    }

    // Keeps the first error reported for each field (the normalizer's wording beats the validator's generic one).
    private static void mergeErrors(List<PortalValidator.ValidationError> target, List<PortalValidator.ValidationError> extra) {
        Set<String> seen = new Set<String>();
        for (PortalValidator.ValidationError existing : target) {
            seen.add(existing.field);
        }
        for (PortalValidator.ValidationError candidate : extra) {
            if (candidate.field == null || !seen.contains(candidate.field)) {
                target.add(candidate);
                seen.add(candidate.field);
            }
        }
    }

    private static Boolean hasErrorFor(List<PortalValidator.ValidationError> errors, String field) {
        for (PortalValidator.ValidationError candidate : errors) {
            if (candidate.field == field) {
                return true;
            }
        }
        return false;
    }

    private static String trimToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    private static PortalSubmitResult genericFailure() {
        PortalSubmitResult result = new PortalSubmitResult();
        result.ok = false;
        result.errors = new List<PortalValidator.ValidationError>{
            new PortalValidator.ValidationError(null, System.Label.Portal_Invalid_Link_Message)
        };
        return result;
    }

    // Note: Accept and Reject clear the token, so a donor opening an already-reviewed link lands on INVALID rather
    // than USED. Accepted/Rejected are kept in USED_STATUSES as a safeguard in case a token is ever left in place.
    private static String determineState(Account acc) {
        if (acc == null) {
            return 'INVALID';
        }
        if (acc.Portal_Token_Expiry__c == null || acc.Portal_Token_Expiry__c < System.now()) {
            return 'EXPIRED';
        }
        if (USED_STATUSES.contains(acc.Portal_Status__c)) {
            return 'USED';
        }
        return 'READY';
    }

    private static Account findByToken(String token) {
        if (String.isBlank(token)) {
            return null;
        }
        List<Account> matches = [
            SELECT Id, FirstName, LastName, PersonEmail, Phone, PersonMobilePhone, PersonHomePhone, WorkPhone__c,
                   PersonMailingStreet, PersonMailingCity, PersonMailingState, PersonMailingPostalCode, PersonMailingCountry,
                   Missing_Phone__c, Missing_Mailing_Address__c, Portal_Token_Expiry__c, Portal_Status__c
            FROM Account
            WHERE Portal_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return matches.isEmpty() ? null : matches[0];
    }

    // Row-locked variant for submitUpdate, so two near-simultaneous submits on the same token
    // can't both pass the Portal_Status__c check before either one writes (doc section 10, test 8).
    // The lock and the field read are split into two queries -- combining FOR UPDATE with
    // WITH SYSTEM_MODE on a single query was observed to break formula field evaluation
    // (Missing_Phone__c/Missing_Mailing_Address__c) for guest users specifically.
    private static Account findByTokenForUpdate(String token) {
        if (String.isBlank(token)) {
            return null;
        }
        List<Account> lockRows = [
            SELECT Id
            FROM Account
            WHERE Portal_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
            FOR UPDATE
        ];
        if (lockRows.isEmpty()) {
            return null;
        }
        List<Account> matches = [
            SELECT Id, Portal_Token_Expiry__c, Portal_Status__c, Missing_Phone__c, Missing_Mailing_Address__c
            FROM Account
            WHERE Id = :lockRows[0].Id
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return matches.isEmpty() ? null : matches[0];
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
