import { LightningElement, api } from 'lwc';

const DEFAULT_COUNTRY = 'United States';

// Prefilled values that mean a country the org lists under its full name (the donor record may hold "US", "USA", ...).
const COUNTRY_ALIASES = {
    US: 'United States', USA: 'United States', 'U.S.': 'United States', 'U.S.A.': 'United States',
    'UNITED STATES OF AMERICA': 'United States', UK: 'United Kingdom', 'U.K.': 'United Kingdom',
    'GREAT BRITAIN': 'United Kingdom'
};

// Mirrors PortalValidator.isAddressComplete / isValidUsZip for instant client-side feedback.
// The server repeats every check on submit -- this is UX only, never trusted (doc section 2 rule 7).
function isValidUsZip(zip) {
    return !!zip && /^\d{5}(-\d{4})?$/.test(zip.trim());
}

export default class DonorPortalAddressForm extends LightningElement {
    // Starting values, read once when the form is created. The form owns its own state after that, so a value
    // is never pushed back in from the parent.
    @api street;
    @api city;
    @api state;
    @api postalCode;
    @api country;
    // Every country the org accepts, each with the states it allows (empty when the org has no state list for it).
    @api countries;
    // Field errors reported by the server, keyed by field name (street, city, state, postalCode, country).
    @api serverErrors;

    streetValue = '';
    cityValue = '';
    stateValue = '';
    postalCodeValue = '';
    selectedCountry = DEFAULT_COUNTRY;
    touched = false;

    initial = {};
    countryChosenByDonor = false;
    startedWithoutCountry = false;

    connectedCallback() {
        const countryList = this.countries || [];
        const matched = this.matchCountry(this.country, countryList);

        this.startedWithoutCountry = !matched;
        this.selectedCountry = matched ? matched.label : DEFAULT_COUNTRY;

        this.streetValue = this.street || '';
        this.cityValue = this.city || '';
        this.postalCodeValue = this.postalCode || '';
        const states = this.statesOf(this.selectedCountry);
        this.stateValue = this.matchState(this.state, states);

        this.initial = {
            street: this.streetValue,
            city: this.cityValue,
            state: this.stateValue,
            postalCode: this.postalCodeValue
        };
        // Tell the parent where things start (nothing dirty, completeness of whatever was prefilled).
        this.notifyChange();
    }

    matchCountry(value, list) {
        if (!value || !value.trim()) {
            return null;
        }
        const trimmed = value.trim();
        const wanted = (COUNTRY_ALIASES[trimmed.toUpperCase()] || trimmed).toUpperCase();
        return list.find((c) => c.label.toUpperCase() === wanted || c.code.toUpperCase() === wanted) || null;
    }

    matchState(value, states) {
        if (!value || !states.length) {
            return '';
        }
        const needle = value.trim().toLowerCase();
        return states.find((s) => s.toLowerCase() === needle) || '';
    }

    statesOf(countryLabel) {
        const found = (this.countries || []).find((c) => c.label === countryLabel);
        return found && found.states ? found.states : [];
    }

    get hasCountryList() {
        return !!this.countries && this.countries.length > 0;
    }

    get countryOptions() {
        return (this.countries || []).map((c) => ({
            value: c.label,
            label: c.label,
            selected: c.label === this.selectedCountry
        }));
    }

    // The org only has state lists for a handful of countries; for every other country there is no state field.
    get stateList() {
        return this.statesOf(this.selectedCountry);
    }

    get hasStates() {
        return this.stateList.length > 0;
    }

    get stateOptions() {
        return [
            { value: '', label: 'Select a state', selected: !this.stateValue },
            ...this.stateList.map((s) => ({ value: s, label: s, selected: s === this.stateValue }))
        ];
    }

    get isUsCountry() {
        return this.selectedCountry === DEFAULT_COUNTRY;
    }

    get stateLabel() {
        return this.isUsCountry ? 'State' : 'State / Province (optional)';
    }

    get postalCodeLabel() {
        return this.isUsCountry ? 'ZIP code' : 'Postal code (optional)';
    }

    // Only street/city/state/zip changes count. A country by itself is never "an address" -- except when the donor
    // had no country on file, there IS a street and city, and they picked one: that can be the only thing missing.
    // (Just browsing the country list on an otherwise empty address must not block a phone-only submit.)
    get isDirty() {
        return this.streetValue !== this.initial.street
            || this.cityValue !== this.initial.city
            || this.stateValue !== this.initial.state
            || this.postalCodeValue !== this.initial.postalCode
            || (this.startedWithoutCountry && this.countryChosenByDonor
                && !!this.streetValue.trim() && !!this.cityValue.trim());
    }

    get isComplete() {
        if (!this.streetValue.trim() || !this.cityValue.trim() || !this.selectedCountry) {
            return false;
        }
        if (this.isUsCountry) {
            return !!this.stateValue && isValidUsZip(this.postalCodeValue);
        }
        return true;
    }

    get clientErrors() {
        if (!this.touched) {
            return {};
        }
        const errs = {};
        if (!this.streetValue.trim()) errs.street = 'Street is required.';
        if (!this.cityValue.trim()) errs.city = 'City is required.';
        if (!this.selectedCountry) errs.country = 'Country is required.';
        if (this.isUsCountry) {
            if (!this.stateValue) errs.state = 'State is required.';
            if (!isValidUsZip(this.postalCodeValue)) errs.postalCode = 'Enter a ZIP code like 12345 or 12345-6789.';
        }
        return errs;
    }

    fieldError(name) {
        return this.clientErrors[name] || (this.serverErrors && this.serverErrors[name]) || null;
    }

    get streetError() { return this.fieldError('street'); }
    get cityError() { return this.fieldError('city'); }
    get stateError() { return this.fieldError('state'); }
    get postalCodeError() { return this.fieldError('postalCode'); }
    get countryError() { return this.fieldError('country'); }

    handleStreetInput(event) { this.streetValue = event.target.value; this.touched = true; this.notifyChange(); }
    handleCityInput(event) { this.cityValue = event.target.value; this.touched = true; this.notifyChange(); }
    handleStateChange(event) { this.stateValue = event.target.value; this.touched = true; this.notifyChange(); }
    handlePostalCodeInput(event) { this.postalCodeValue = event.target.value; this.touched = true; this.notifyChange(); }

    handleCountryChange(event) {
        this.selectedCountry = event.target.value;
        this.countryChosenByDonor = true;
        this.stateValue = ''; // a state belongs to one country
        this.touched = true;
        this.notifyChange();
    }

    notifyChange() {
        this.dispatchEvent(new CustomEvent('addresschange', {
            detail: {
                street: this.streetValue.trim(),
                city: this.cityValue.trim(),
                state: this.stateValue.trim(),
                postalCode: this.postalCodeValue.trim(),
                country: this.selectedCountry,
                isComplete: this.isComplete,
                isDirty: this.isDirty
            }
        }));
    }
}
