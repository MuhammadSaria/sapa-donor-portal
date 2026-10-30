/**
 * Resolves a donor-typed country/state to the exact values this org's State and Country picklists accept.
 * Needed because PersonMailingState/PersonMailingCountry are restricted picklists: "IL", "USA", "Sindh" etc.
 * are rejected at DML time (FIELD_INTEGRITY_EXCEPTION), which would leave a submission stuck at Accept.
 *
 * No SOQL/DML. Returns the picklist LABEL (what PersonMailingState/PersonMailingCountry take), or errors.
 */
public with sharing class PortalAddressNormalizer {

    public class Result {
        public String country;
        public String state;
        public List<PortalValidator.ValidationError> errors = new List<PortalValidator.ValidationError>();
    }

    // One entry per active country, for the donor form's dropdowns. "states" is empty for countries that have no state
    // list in the org (all but 10 of them), which is the form's cue to hide the state field.
    public class CountryOption {
        @AuraEnabled public String label;
        @AuraEnabled public String code;
        @AuraEnabled public List<String> states = new List<String>();
    }

    private class CountryInfo {
        String code;
        String label;
        Integer index; // position in the controlling picklist -- the bit index used by a state's validFor
    }

    private class StateInfo {
        String code;
        String label;
        List<Integer> validForBytes;
    }

    private static final Map<String, String> COUNTRY_ALIASES = new Map<String, String>{
        'USA' => 'US', 'U.S.' => 'US', 'U.S.A.' => 'US', 'AMERICA' => 'US', 'UNITED STATES OF AMERICA' => 'US',
        'UK' => 'GB', 'U.K.' => 'GB', 'GREAT BRITAIN' => 'GB'
    };
    private static final String HEX_DIGITS = '0123456789abcdef';

    private static Boolean loaded = false;
    private static Boolean picklistsAvailable = false;
    private static List<CountryInfo> countries = new List<CountryInfo>();
    private static List<StateInfo> states = new List<StateInfo>();

    public static Result normalize(String countryInput, String stateInput) {
        Result result = new Result();
        String country = String.isBlank(countryInput) ? null : countryInput.trim();
        String state = String.isBlank(stateInput) ? null : stateInput.trim();
        load();

        if (!picklistsAvailable) {
            result.country = country;
            result.state = state;
            return result;
        }
        if (country == null) {
            result.state = state; // the validator reports the missing country
            return result;
        }

        CountryInfo match = findCountry(country);
        if (match == null) {
            result.errors.add(new PortalValidator.ValidationError(
                'country', 'We could not recognise that country. Please check the spelling.'
            ));
            return result;
        }
        result.country = match.label;
        result.state = resolveState(match, state, result);
        return result;
    }

    /**
     * Every active country with the states it allows, read from the org's own State/Country picklists, so the form
     * always offers exactly what the donor record will accept. Empty when the picklists are not enabled.
     */
    public static List<CountryOption> getOptions() {
        load();
        Map<Integer, List<String>> statesByCountryIndex = new Map<Integer, List<String>>();
        for (StateInfo state : states) {
            for (Integer byteIndex = 0; byteIndex < state.validForBytes.size(); byteIndex++) {
                Integer value = state.validForBytes[byteIndex];
                if (value == 0) {
                    continue;
                }
                for (Integer bit = 0; bit < 8; bit++) {
                    if ((value & (128 >> bit)) != 0) {
                        Integer countryIndex = byteIndex * 8 + bit;
                        if (!statesByCountryIndex.containsKey(countryIndex)) {
                            statesByCountryIndex.put(countryIndex, new List<String>());
                        }
                        statesByCountryIndex.get(countryIndex).add(state.label);
                    }
                }
            }
        }

        List<CountryOption> options = new List<CountryOption>();
        for (CountryInfo country : countries) {
            CountryOption option = new CountryOption();
            option.label = country.label;
            option.code = country.code;
            if (statesByCountryIndex.containsKey(country.index)) {
                option.states = statesByCountryIndex.get(country.index);
            }
            options.add(option);
        }
        return options;
    }

    private static String resolveState(CountryInfo country, String state, Result result) {
        if (state == null) {
            return null;
        }
        List<StateInfo> valid = statesFor(country);
        if (valid.isEmpty()) {
            return null; // this country has no state list in the org, so there is nothing to validate against or store
        }
        String needle = state.toLowerCase();
        for (StateInfo candidate : valid) {
            if (candidate.label.toLowerCase() == needle || candidate.code.toLowerCase() == needle) {
                return candidate.label;
            }
        }
        result.errors.add(new PortalValidator.ValidationError(
            'state', 'Please choose a valid state or province for ' + country.label + '.'
        ));
        return null;
    }

    private static CountryInfo findCountry(String input) {
        String needle = input.toUpperCase();
        if (COUNTRY_ALIASES.containsKey(needle)) {
            needle = COUNTRY_ALIASES.get(needle);
        }
        for (CountryInfo info : countries) {
            if (info.label.toUpperCase() == needle || info.code.toUpperCase() == needle) {
                return info;
            }
        }
        return null;
    }

    private static List<StateInfo> statesFor(CountryInfo country) {
        List<StateInfo> valid = new List<StateInfo>();
        for (StateInfo info : states) {
            if (isBitSet(info.validForBytes, country.index)) {
                valid.add(info);
            }
        }
        return valid;
    }

    private static Boolean isBitSet(List<Integer> bytes, Integer bitIndex) {
        Integer byteIndex = bitIndex / 8;
        if (byteIndex >= bytes.size()) {
            return false;
        }
        return (bytes[byteIndex] & (128 >> Math.mod(bitIndex, 8))) != 0;
    }

    private static void load() {
        if (loaded) {
            return;
        }
        loaded = true;
        Schema.SObjectField countryField = Schema.SObjectType.Account.fields.getMap().get('PersonMailingCountryCode');
        Schema.SObjectField stateField = Schema.SObjectType.Account.fields.getMap().get('PersonMailingStateCode');
        if (countryField == null || stateField == null) {
            return; // State and Country picklists are not enabled in this org
        }

        List<Schema.PicklistEntry> countryEntries = countryField.getDescribe().getPicklistValues();
        for (Integer i = 0; i < countryEntries.size(); i++) {
            if (!countryEntries[i].isActive()) {
                continue;
            }
            CountryInfo info = new CountryInfo();
            info.code = countryEntries[i].getValue();
            info.label = countryEntries[i].getLabel();
            info.index = i;
            countries.add(info);
        }

        for (Schema.PicklistEntry entry : stateField.getDescribe().getPicklistValues()) {
            if (!entry.isActive()) {
                continue;
            }
            // validFor (the dependency bitmap) is not exposed by a PicklistEntry getter, but it is in its JSON form.
            Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(entry));
            StateInfo info = new StateInfo();
            info.code = entry.getValue();
            info.label = entry.getLabel();
            info.validForBytes = toBytes((String) raw.get('validFor'));
            states.add(info);
        }
        picklistsAvailable = true;
    }

    private static List<Integer> toBytes(String base64) {
        List<Integer> bytes = new List<Integer>();
        if (String.isBlank(base64)) {
            return bytes;
        }
        String hex = EncodingUtil.convertToHex(EncodingUtil.base64Decode(base64));
        for (Integer i = 0; i + 1 < hex.length(); i += 2) {
            bytes.add(HEX_DIGITS.indexOf(hex.substring(i, i + 1)) * 16 + HEX_DIGITS.indexOf(hex.substring(i + 1, i + 2)));
        }
        return bytes;
    }
}
