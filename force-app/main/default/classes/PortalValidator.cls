/**
 * Shared validation rules for the SAPA donor update portal (doc section 3, 6).
 * Pure functions only -- no SOQL/DML -- so the same rules can be mirrored in the LWC for instant feedback.
 */
public class PortalValidator {

    public class ValidationError {
        @AuraEnabled public String field;
        @AuraEnabled public String message;
        public ValidationError(String field, String message) {
            this.field = field;
            this.message = message;
        }
    }

    public static Boolean isValidUsZip(String zip) {
        if (String.isBlank(zip)) {
            return false;
        }
        return Pattern.matches('^\\d{5}(-\\d{4})?$', zip.trim());
    }

    // Field limits on Account (New_Phone__c 40, New_Street__c/New_City__c 255, New_State__c/New_Country__c 80, New_Postal_Code__c 20).
    private static final Integer MAX_PHONE = 40;
    private static final Integer MAX_STREET_CITY = 255;
    private static final Integer MAX_STATE_COUNTRY = 80;
    private static final Integer MAX_ZIP = 20;

    public static Boolean hasAtLeastTenDigits(String phone) {
        if (String.isBlank(phone)) {
            return false;
        }
        return phone.replaceAll('[^0-9]', '').length() >= 10;
    }

    // Digits plus the usual separators, with an optional extension -- rejects free text like "call me".
    public static Boolean hasOnlyPhoneCharacters(String phone) {
        if (String.isBlank(phone)) {
            return false;
        }
        return Pattern.matches('^[0-9\\s().+\\-]+([xX#]\\s?[0-9]{1,6})?$', phone.trim());
    }

    /**
     * A phone number as the form sends it: "+<country code> <number>". International numbers must have 8-15 digits in
     * total (the E.164 maximum), and a +1 (North American) number exactly 10 digits after the 1. A number without a
     * leading "+" (older submissions) keeps the original rule of at least 10 digits.
     */
    public static Boolean isValidPhone(String phone) {
        if (String.isBlank(phone) || !hasOnlyPhoneCharacters(phone)) {
            return false;
        }
        String trimmed = phone.trim();
        if (!trimmed.startsWith('+')) {
            return hasAtLeastTenDigits(trimmed);
        }
        String digits = trimmed.replaceAll('[^0-9]', '');
        if (digits.length() < 8 || digits.length() > 15) {
            return false;
        }
        return !digits.startsWith('1') || digits.length() == 11;
    }

    /**
     * Country is deliberately NOT counted: the donor form always has a country selected (it defaults to the
     * United States), so counting it made every submission look like an address the donor had started.
     */
    public static Boolean isAddressStarted(String street, String city, String state, String zip, String country) {
        return String.isNotBlank(street) || String.isNotBlank(city) || String.isNotBlank(state)
            || String.isNotBlank(zip);
    }

    /**
     * Mirrors the live Missing_Mailing_Address__c formula: street/city/country required always;
     * state + a US-format ZIP required only when the country is the United States.
     */
    public static Boolean isAddressComplete(String street, String city, String state, String zip, String country) {
        if (String.isBlank(street) || String.isBlank(city) || String.isBlank(country)) {
            return false;
        }
        if (isUnitedStates(country)) {
            return String.isNotBlank(state) && isValidUsZip(zip);
        }
        return true;
    }

    public static Boolean isUnitedStates(String country) {
        if (String.isBlank(country)) {
            return true;
        }
        String normalized = country.trim().toUpperCase();
        return normalized == 'US' || normalized == 'USA'
            || normalized == 'UNITED STATES' || normalized == 'UNITED STATES OF AMERICA';
    }

    /**
     * Server-side recompute of doc section 3's rules: a started address block must be complete,
     * and at least one editable section must actually be submitted.
     */
    public static List<ValidationError> validateSubmission(
        Boolean phoneEditable, String phone,
        Boolean addressEditable, String street, String city, String state, String zip, String country
    ) {
        List<ValidationError> errors = new List<ValidationError>();
        Boolean phoneProvided = String.isNotBlank(phone);
        Boolean addressStarted = isAddressStarted(street, city, state, zip, country);

        if (phoneEditable && phoneProvided) {
            if (!isValidPhone(phone)) {
                errors.add(new ValidationError('phone', 'Enter a valid phone number for the selected country code.'));
            } else if (phone.trim().length() > MAX_PHONE) {
                errors.add(new ValidationError('phone', 'That phone number is too long.'));
            }
        }

        Boolean addressTooLong = false;
        if (addressEditable && addressStarted) {
            Integer before = errors.size();
            addTooLong(errors, 'street', street, MAX_STREET_CITY);
            addTooLong(errors, 'city', city, MAX_STREET_CITY);
            addTooLong(errors, 'state', state, MAX_STATE_COUNTRY);
            addTooLong(errors, 'postalCode', zip, MAX_ZIP);
            addTooLong(errors, 'country', country, MAX_STATE_COUNTRY);
            addressTooLong = errors.size() > before;
        }

        if (addressEditable && addressStarted && !addressTooLong && !isAddressComplete(street, city, state, zip, country)) {
            if (String.isBlank(street)) {
                errors.add(new ValidationError('street', 'Street is required.'));
            }
            if (String.isBlank(city)) {
                errors.add(new ValidationError('city', 'City is required.'));
            }
            if (String.isBlank(country)) {
                errors.add(new ValidationError('country', 'Country is required.'));
            }
            if (isUnitedStates(country)) {
                if (String.isBlank(state)) {
                    errors.add(new ValidationError('state', 'State is required.'));
                }
                if (!isValidUsZip(zip)) {
                    errors.add(new ValidationError('postalCode', 'Enter a ZIP code like 12345 or 12345-6789.'));
                }
            }
        }

        if (errors.isEmpty()) {
            Boolean phoneSectionDone = phoneEditable && phoneProvided;
            Boolean addressSectionDone = addressEditable && addressStarted;
            if (!phoneSectionDone && !addressSectionDone) {
                errors.add(new ValidationError(null, 'Please complete at least one section before submitting.'));
            }
        }

        return errors;
    }

    private static void addTooLong(List<ValidationError> errors, String field, String value, Integer max) {
        if (value != null && value.trim().length() > max) {
            errors.add(new ValidationError(field, 'This is too long (maximum ' + max + ' characters).'));
        }
    }
}