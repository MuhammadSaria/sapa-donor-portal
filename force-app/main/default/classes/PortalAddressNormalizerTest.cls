@isTest
private class PortalAddressNormalizerTest {

    @isTest
    static void usStateByNameCodeAndCaseResolvesToTheOrgLabel() {
        System.assertEquals('Illinois', PortalAddressNormalizer.normalize('United States', 'Illinois').state);
        System.assertEquals('Illinois', PortalAddressNormalizer.normalize('United States', 'IL').state);
        System.assertEquals('Illinois', PortalAddressNormalizer.normalize('United States', ' illinois ').state);
    }

    @isTest
    static void countryAliasesAndCodesResolveToTheOrgLabel() {
        System.assertEquals('United States', PortalAddressNormalizer.normalize('USA', null).country);
        System.assertEquals('United States', PortalAddressNormalizer.normalize('us', null).country);
        System.assertEquals('United States', PortalAddressNormalizer.normalize('United States of America', null).country);
        System.assertEquals('United Kingdom', PortalAddressNormalizer.normalize('UK', null).country);
        System.assertEquals('Sudan', PortalAddressNormalizer.normalize('sudan', null).country);
    }

    @isTest
    static void stateIsCheckedAgainstTheChosenCountry() {
        System.assertEquals('Ontario', PortalAddressNormalizer.normalize('Canada', 'ON').state);

        // "ON" is not a US state, and "Illinois" is not a Canadian province.
        PortalAddressNormalizer.Result wrongCountry = PortalAddressNormalizer.normalize('United States', 'ON');
        System.assertEquals(1, wrongCountry.errors.size());
        System.assertEquals('state', wrongCountry.errors[0].field);
        System.assertEquals(1, PortalAddressNormalizer.normalize('Canada', 'Illinois').errors.size());
    }

    @isTest
    static void optionsListEveryCountryWithStatesOnlyWhereTheOrgHasThem() {
        Map<String, PortalAddressNormalizer.CountryOption> byLabel = new Map<String, PortalAddressNormalizer.CountryOption>();
        List<PortalAddressNormalizer.CountryOption> options = PortalAddressNormalizer.getOptions();
        for (PortalAddressNormalizer.CountryOption option : options) {
            byLabel.put(option.label, option);
        }
        System.assert(options.size() > 200, 'Expected the full country list, got ' + options.size());

        PortalAddressNormalizer.CountryOption us = byLabel.get('United States');
        System.assertEquals('US', us.code);
        System.assert(us.states.size() >= 50, 'US should list its states');
        System.assert(new Set<String>(us.states).contains('Illinois'));

        System.assert(new Set<String>(byLabel.get('Canada').states).contains('Ontario'));
        System.assertEquals(0, byLabel.get('Sudan').states.size(), 'Sudan has no state list in the org');
        System.assertEquals(0, byLabel.get('Pakistan').states.size());
    }

    // Anything the form offers must be accepted by the normalizer unchanged, or a donor could pick an option we reject.
    @isTest
    static void everyOfferedCountryAndStateIsAccepted() {
        for (PortalAddressNormalizer.CountryOption option : PortalAddressNormalizer.getOptions()) {
            PortalAddressNormalizer.Result country = PortalAddressNormalizer.normalize(option.label, null);
            System.assertEquals(option.label, country.country, 'Country not accepted: ' + option.label);
            if (!option.states.isEmpty()) {
                PortalAddressNormalizer.Result state = PortalAddressNormalizer.normalize(option.label, option.states[0]);
                System.assertEquals(0, state.errors.size(), option.label + ' / ' + option.states[0]);
                System.assertEquals(option.states[0], state.state);
            }
        }
    }

    @isTest
    static void unknownCountryIsAnError() {
        PortalAddressNormalizer.Result result = PortalAddressNormalizer.normalize('Narnia', 'Anything');
        System.assertEquals(1, result.errors.size());
        System.assertEquals('country', result.errors[0].field);
        System.assertEquals(null, result.country);
    }

    @isTest
    static void blankValuesPassThroughForTheValidatorToReport() {
        PortalAddressNormalizer.Result result = PortalAddressNormalizer.normalize(null, ' ');
        System.assertEquals(0, result.errors.size());
        System.assertEquals(null, result.country);
        System.assertEquals(null, result.state);

        PortalAddressNormalizer.Result noState = PortalAddressNormalizer.normalize('Pakistan', '');
        System.assertEquals(0, noState.errors.size());
        System.assertEquals('Pakistan', noState.country);
        System.assertEquals(null, noState.state);
    }

    // A value the normalizer returns must be one the donor record can actually store -- the whole point of the class.
    @isTest
    static void normalizedValuesCanBeWrittenToAPersonAccount() {
        PortalAddressNormalizer.Result result = PortalAddressNormalizer.normalize('USA', 'IL');
        Id personType = [SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
        Account acc = new Account(
            RecordTypeId = personType, LastName = 'NormalizerWrite',
            PersonMailingStreet = '1 Main St', PersonMailingCity = 'Chicago', PersonMailingPostalCode = '60601',
            PersonMailingState = result.state, PersonMailingCountry = result.country
        );
        insert acc;
        Account saved = [SELECT PersonMailingStateCode, PersonMailingCountryCode FROM Account WHERE Id = :acc.Id];
        System.assertEquals('IL', saved.PersonMailingStateCode);
        System.assertEquals('US', saved.PersonMailingCountryCode);
    }
}
