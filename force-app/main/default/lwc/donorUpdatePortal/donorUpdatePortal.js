import { LightningElement, track } from 'lwc';
import getPortalData from '@salesforce/apex/DonorUpdatePortalController.getPortalData';
import submitUpdate from '@salesforce/apex/DonorUpdatePortalController.submitUpdate';
import getAddressOptions from '@salesforce/apex/DonorUpdatePortalController.getAddressOptions';
import { DIAL_CODES, PINNED_ISO_CODES } from 'c/portalCountryData';

// Mirrors PortalValidator.isValidPhone. UX only -- the server repeats every check.
// "+<country code> <number>": 8-15 digits in total, and exactly 10 digits after a North American +1.
function isValidPhone(phone) {
    const trimmed = (phone || '').trim();
    if (!/^[0-9\s().+-]+([xX#]\s?[0-9]{1,6})?$/.test(trimmed)) {
        return false;
    }
    const digits = trimmed.replace(/[^0-9]/g, '');
    if (!trimmed.startsWith('+')) {
        return digits.length >= 10;
    }
    if (digits.length < 8 || digits.length > 15) {
        return false;
    }
    return !digits.startsWith('1') || digits.length === 11;
}

export default class DonorUpdatePortal extends LightningElement {
    @track loading = true;
    @track submitting = false;
    @track statusScreen = null; // 'EXPIRED', 'USED', 'INVALID', 'ERROR', 'THANK_YOU' when set, replaces the form entirely
    @track serverErrors = {};
    @track genericError = null;

    token;
    firstName;
    lastName;
    email;
    onFilePhone = '';
    reasonText;
    phoneEditable = false;
    addressEditable = false;

    phone = ''; // the number as typed, WITHOUT the country code (that is chosen separately)
    dialIso = 'US'; // which country's code is selected for the phone number
    phoneTouched = false;
    countries = []; // every country the org accepts, with its states -- feeds the address form and the phone codes

    // Where the address form starts (it owns its own state after that) and what it last reported.
    initialStreet = '';
    initialCity = '';
    initialState = '';
    initialPostalCode = '';
    initialCountry = '';
    address = { street: '', city: '', state: '', postalCode: '', country: '', isComplete: false, isDirty: false };

    connectedCallback() {
        this.token = new URLSearchParams(window.location.search).get('token');
        this.loadPortalData();
    }

    async loadPortalData() {
        this.loading = true;
        try {
            // The country list is reference data, so a failure there must not look like a bad link: the form still
            // loads and the address block explains what went wrong.
            const [data, countryOptions] = await Promise.all([
                getPortalData({ token: this.token }),
                getAddressOptions().catch(() => [])
            ]);
            this.countries = countryOptions || [];
            this.firstName = data.firstName;
            this.lastName = data.lastName;
            this.email = data.email;
            this.onFilePhone = data.phone || '';
            this.reasonText = data.reasonText;
            this.phoneEditable = !!data.phoneEditable;
            this.addressEditable = !!data.addressEditable;
            this.phone = data.phone || '';
            this.initialStreet = data.street || '';
            this.initialCity = data.city || '';
            this.initialState = data.state || '';
            this.initialPostalCode = data.postalCode || '';
            this.initialCountry = data.country || '';

            if (data.portalState !== 'READY') {
                this.statusScreen = data.portalState; // EXPIRED, USED, or INVALID
            }
        } catch (e) {
            // A failed request is not the same as a bad link: don't tell the donor their link is invalid.
            this.statusScreen = 'ERROR';
        } finally {
            this.loading = false;
        }
    }

    get showForm() {
        return !this.loading && !this.statusScreen;
    }

    get hasPhoneSection() {
        return this.phoneEditable;
    }

    get hasAddressSection() {
        return this.addressEditable;
    }

    get hasAnyEditableSection() {
        return this.phoneEditable || this.addressEditable;
    }

    // What is already on file, shown back to the donor read-only (the inputs below only ever cover what is missing).
    get fullName() {
        return [this.firstName, this.lastName].filter((part) => !!part).join(' ');
    }

    get hasEmail() {
        return !!this.email;
    }

    get onFileAddress() {
        return [this.initialStreet, this.initialCity, this.initialState, this.initialPostalCode, this.initialCountry]
            .filter((part) => !!part && part.trim())
            .join(', ');
    }

    // An address with some parts on file is "incomplete", not "missing" -- say so, and the form below is prefilled.
    get addressTagText() {
        return this.onFileAddress ? 'Incomplete - please finish below' : 'Not on file yet';
    }

    get greeting() {
        return this.firstName ? `Hello ${this.firstName}` : 'Hello';
    }

    // Country-code choices: the most likely countries first, then everything else A-Z. Names come from the org's own
    // country list; only countries with a known dialling code can be offered.
    // Returned as two <optgroup>s ("Common" and "All countries"). Do NOT put a `disabled` binding on the options:
    // the framework renders disabled={false} as a real disabled attribute, which made every option unselectable.
    get dialGroups() {
        const withCode = this.countries.filter((c) => DIAL_CODES[c.code]);
        if (withCode.length === 0) {
            return [{
                key: 'common',
                label: 'Common',
                options: [{ key: 'US', value: 'US', label: 'United States (+1)', selected: true }]
            }];
        }
        const toOption = (c) => ({
            key: c.code,
            value: c.code,
            label: `${c.label} (+${DIAL_CODES[c.code]})`,
            selected: c.code === this.dialIso
        });
        const pinned = PINNED_ISO_CODES
            .map((iso) => withCode.find((c) => c.code === iso))
            .filter((c) => !!c)
            .map(toOption);
        const rest = withCode
            .filter((c) => !PINNED_ISO_CODES.includes(c.code))
            .sort((a, b) => a.label.localeCompare(b.label))
            .map(toOption);
        return [
            { key: 'common', label: 'Common', options: pinned },
            { key: 'all', label: 'All countries', options: rest }
        ];
    }

    get dialCode() {
        return DIAL_CODES[this.dialIso] || '1';
    }

    get phonePlaceholder() {
        return this.dialCode === '1' ? '555 123 4567' : 'Phone number';
    }

    // What is sent and stored: "+<code> <number>". A leading trunk zero ("0912...") is dropped outside North America.
    get fullPhone() {
        const typed = this.phone.trim();
        if (!typed) {
            return '';
        }
        if (typed.startsWith('+')) {
            return typed; // the donor typed the whole international number themselves
        }
        const national = this.dialCode === '1' ? typed : typed.replace(/^0+/, '');
        return `+${this.dialCode} ${national}`;
    }

    get phoneProvided() {
        return this.phoneEditable && this.phone.trim().length > 0;
    }

    // The address counts only if the donor actually changed something in it. Prefilled values they left alone
    // (and the country that is always selected) are not an address they started.
    get addressStarted() {
        return this.addressEditable && this.address.isDirty;
    }

    get phoneError() {
        if (this.serverErrors.phone) {
            return this.serverErrors.phone;
        }
        if ((this.phoneTouched || this.phone) && this.phoneProvided && !isValidPhone(this.fullPhone)) {
            return this.dialCode === '1'
                ? 'Enter a 10-digit phone number.'
                : 'Enter a valid phone number for the selected country code.';
        }
        return null;
    }

    get formLevelError() {
        return this.serverErrors['_form'] || this.genericError;
    }

    get hasFieldErrors() {
        return Object.keys(this.serverErrors).some((key) => key !== '_form');
    }

    get canSubmit() {
        const phoneOk = this.phoneProvided && isValidPhone(this.fullPhone);
        const addressOk = this.addressStarted && this.address.isComplete;
        // Something valid to send, and nothing half-finished that the server would refuse.
        const nothingHalfDone = (!this.phoneProvided || phoneOk) && (!this.addressStarted || addressOk);
        return (phoneOk || addressOk) && nothingHalfDone && !this.submitting;
    }

    get cannotSubmit() {
        return !this.canSubmit;
    }

    get submitLabel() {
        return this.submitting ? 'Sending…' : 'Send my details';
    }

    handlePhoneInput(event) {
        this.phone = event.target.value;
        this.phoneTouched = true;
    }

    handleDialChange(event) {
        this.dialIso = event.target.value;
        this.phoneTouched = true;
    }

    handlePhoneBlur() {
        this.phoneTouched = true;
    }

    handleAddressChange(event) {
        this.address = event.detail;
    }

    async handleSubmit() {
        this.submitting = true;
        this.serverErrors = {};
        this.genericError = null;
        const sendAddress = this.addressStarted;
        try {
            const result = await submitUpdate({
                token: this.token,
                phone: this.phoneProvided ? this.fullPhone : null,
                street: sendAddress ? this.address.street : null,
                city: sendAddress ? this.address.city : null,
                state: sendAddress ? this.address.state : null,
                postalCode: sendAddress ? this.address.postalCode : null,
                country: sendAddress ? this.address.country : null
            });

            if (result.ok) {
                this.statusScreen = 'THANK_YOU';
            } else {
                const fieldErrors = {};
                let formError = null;
                (result.errors || []).forEach((err) => {
                    if (err.field) {
                        fieldErrors[err.field] = err.message;
                    } else {
                        formError = err.message;
                    }
                });
                if (!formError && Object.keys(fieldErrors).length > 0) {
                    formError = 'Please fix the highlighted fields and try again.';
                }
                this.serverErrors = formError ? { ...fieldErrors, _form: formError } : fieldErrors;
            }
        } catch (e) {
            this.genericError = 'Something went wrong. Please try again.';
        } finally {
            this.submitting = false;
        }
    }
}
