@isTest
private class PortalValidatorTest {

    @isTest
    static void zipValidation() {
        System.assert(PortalValidator.isValidUsZip('62704'));
        System.assert(PortalValidator.isValidUsZip('62704-1234'));
        System.assert(!PortalValidator.isValidUsZip('6270'));
        System.assert(!PortalValidator.isValidUsZip('ABCDE'));
        System.assert(!PortalValidator.isValidUsZip(null));
    }

    @isTest
    static void phoneWithCountryCodeIsValidatedPerCountryRules() {
        // North America (+1): exactly 10 digits after the 1.
        System.assert(PortalValidator.isValidPhone('+1 5551230001'));
        System.assert(PortalValidator.isValidPhone('+1 (555) 123-0001'));
        System.assert(!PortalValidator.isValidPhone('+1 555123000'), 'nine digits is too short for +1');
        System.assert(!PortalValidator.isValidPhone('+1 55512300012'), 'eleven digits is too long for +1');
        // Elsewhere: 8-15 digits in total.
        System.assert(PortalValidator.isValidPhone('+249 912345678'));
        System.assert(PortalValidator.isValidPhone('+44 7911 123456'));
        System.assert(!PortalValidator.isValidPhone('+249 123'), 'six digits in total is too short');
        System.assert(!PortalValidator.isValidPhone('+249 1234567890123456'));
        // Older submissions without a country code keep the 10-digit rule; free text is never valid.
        System.assert(PortalValidator.isValidPhone('5551230001'));
        System.assert(!PortalValidator.isValidPhone('555123'));
        System.assert(!PortalValidator.isValidPhone('call me 5551230001'));
        System.assert(!PortalValidator.isValidPhone(null));
    }

    @isTest
    static void phoneValidation() {
        System.assert(PortalValidator.hasAtLeastTenDigits('555-123-0001'));
        System.assert(PortalValidator.hasAtLeastTenDigits('(555) 123 0099 '));
        System.assert(!PortalValidator.hasAtLeastTenDigits('555123'));
        System.assert(!PortalValidator.hasAtLeastTenDigits(null));
    }

    @isTest
    static void addressStartedDetectsAnyField() {
        System.assert(!PortalValidator.isAddressStarted(null, null, null, null, null));
        System.assert(PortalValidator.isAddressStarted('100 Main St', null, null, null, null));
        System.assert(PortalValidator.isAddressStarted(null, null, null, '62704', null));
    }

    // The form always has a country selected, so a country by itself must not mean the donor began an address.
    @isTest
    static void countryAloneDoesNotStartAnAddress() {
        System.assert(!PortalValidator.isAddressStarted(null, null, null, null, 'United States'));
        System.assert(!PortalValidator.isAddressStarted('', ' ', '', '', 'United Kingdom'));
    }

    @isTest
    static void phoneCharacterValidation() {
        System.assert(PortalValidator.hasOnlyPhoneCharacters('+1 (555) 123-0001'));
        System.assert(PortalValidator.hasOnlyPhoneCharacters('555.123.0001 x45'));
        System.assert(!PortalValidator.hasOnlyPhoneCharacters('call me 5551230001'));
        System.assert(!PortalValidator.hasOnlyPhoneCharacters(null));
    }

    @isTest
    static void validateSubmissionIgnoresDefaultCountryWhenOnlyPhoneGiven() {
        List<PortalValidator.ValidationError> errors = PortalValidator.validateSubmission(
            true, '5551230001',
            true, '', '', '', '', 'United States'
        );
        System.assertEquals(0, errors.size());
    }

    @isTest
    static void validateSubmissionFlagsOverlongValues() {
        List<PortalValidator.ValidationError> errors = PortalValidator.validateSubmission(
            false, null,
            true, 'x'.repeat(300), 'Springfield', 'Illinois', '62704', 'United States'
        );
        System.assertEquals(1, errors.size());
        System.assertEquals('street', errors[0].field);
    }

    @isTest
    static void addressCompleteRequiresStateAndZipOnlyForUs() {
        System.assert(PortalValidator.isAddressComplete('100 Main St', 'Springfield', 'Illinois', '62704', 'United States'));
        System.assert(!PortalValidator.isAddressComplete('100 Main St', 'Springfield', null, null, 'United States'));
        System.assert(!PortalValidator.isAddressComplete('100 Main St', 'Springfield', 'Illinois', 'bad-zip', 'United States'));
        System.assert(PortalValidator.isAddressComplete('10 Downing St', 'London', null, 'SW1A 2AA', 'United Kingdom'));
        System.assert(!PortalValidator.isAddressComplete(null, 'London', null, 'SW1A 2AA', 'United Kingdom'));
    }

    @isTest
    static void validateSubmissionPassesWhenPhoneSectionComplete() {
        List<PortalValidator.ValidationError> errors = PortalValidator.validateSubmission(
            true, '5551230001',
            false, null, null, null, null, null
        );
        System.assertEquals(0, errors.size());
    }

    @isTest
    static void validateSubmissionFlagsShortPhone() {
        List<PortalValidator.ValidationError> errors = PortalValidator.validateSubmission(
            true, '12345',
            false, null, null, null, null, null
        );
        System.assertEquals(1, errors.size());
        System.assertEquals('phone', errors[0].field);
    }

    @isTest
    static void validateSubmissionFlagsHalfFilledAddress() {
        List<PortalValidator.ValidationError> errors = PortalValidator.validateSubmission(
            false, null,
            true, '300 Elm St', 'Springfield', null, null, 'United States'
        );
        Set<String> fields = new Set<String>();
        for (PortalValidator.ValidationError e : errors) {
            fields.add(e.field);
        }
        System.assert(fields.contains('state'));
        System.assert(fields.contains('postalCode'));
    }

    @isTest
    static void validateSubmissionPassesForCompleteNonUsAddress() {
        List<PortalValidator.ValidationError> errors = PortalValidator.validateSubmission(
            false, null,
            true, '10 Downing St', 'London', null, 'SW1A 2AA', 'United Kingdom'
        );
        System.assertEquals(0, errors.size());
    }

    @isTest
    static void validateSubmissionRequiresAtLeastOneSection() {
        List<PortalValidator.ValidationError> errors = PortalValidator.validateSubmission(
            true, null,
            true, null, null, null, null, null
        );
        System.assertEquals(1, errors.size());
        System.assertEquals(null, errors[0].field);
    }

    @isTest
    static void validateSubmissionPassesWithBothSectionsComplete() {
        List<PortalValidator.ValidationError> errors = PortalValidator.validateSubmission(
            true, '5551230001',
            true, '300 Elm St', 'Springfield', 'Illinois', '62704', 'United States'
        );
        System.assertEquals(0, errors.size());
    }
}