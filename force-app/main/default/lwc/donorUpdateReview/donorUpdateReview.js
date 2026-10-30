import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPendingSubmissions from '@salesforce/apex/DonorUpdateReviewController.getPendingSubmissions';
import reviewSubmission from '@salesforce/apex/DonorUpdateReviewController.review';

const QUEUE_LIMIT = 200; // keep in step with DonorUpdateReviewController.QUEUE_LIMIT
const DECISION_OPTIONS = [
    { label: 'Accept', value: 'accept' },
    { label: 'Reject', value: 'reject' }
];

export default class DonorUpdateReview extends LightningElement {
    @track rows = [];
    @track loading = true;
    decisionOptions = DECISION_OPTIONS;

    connectedCallback() {
        this.loadRows();
    }

    async loadRows() {
        this.loading = true;
        try {
            const data = await getPendingSubmissions();
            this.rows = data.map((row) => this.decorate({
                ...row,
                currentAddress: this.formatAddress(row.currentStreet, row.currentCity, row.currentState, row.currentPostalCode, row.currentCountry),
                newAddress: this.formatAddress(row.newStreet, row.newCity, row.newState, row.newPostalCode, row.newCountry),
                phoneDecision: 'accept',
                addressDecision: 'accept',
                reason: '',
                saving: false
            }));
        } catch (e) {
            this.toast('Error', this.reduceError(e), 'error');
        } finally {
            this.loading = false;
        }
    }

    // Derived flags the template needs; recomputed whenever a decision changes.
    decorate(row) {
        const rejectsPhone = row.phoneChanged && row.phoneDecision === 'reject';
        const rejectsAddress = row.addressChanged && row.addressDecision === 'reject';
        return {
            ...row,
            phoneGroup: 'phone-' + row.accountId,
            addressGroup: 'address-' + row.accountId,
            showReason: rejectsPhone || rejectsAddress
        };
    }

    formatAddress(street, city, state, postalCode, country) {
        return [street, city, state, postalCode, country].filter((part) => !!part).join(', ') || '—';
    }

    get hasRows() {
        return !this.loading && this.rows.length > 0;
    }

    get hasNoRows() {
        return !this.loading && this.rows.length === 0;
    }

    // The server returns the oldest 200 waiting submissions; once these are handled the next ones appear.
    get isQueueCapped() {
        return this.rows.length >= QUEUE_LIMIT;
    }

    updateRow(accountId, changes) {
        this.rows = this.rows.map((row) => (row.accountId === accountId ? this.decorate({ ...row, ...changes }) : row));
    }

    handlePhoneDecision(event) {
        this.updateRow(event.target.dataset.id, { phoneDecision: event.detail.value });
    }

    handleAddressDecision(event) {
        this.updateRow(event.target.dataset.id, { addressDecision: event.detail.value });
    }

    handleReasonChange(event) {
        this.updateRow(event.target.dataset.id, { reason: event.target.value });
    }

    async handleSave(event) {
        const accountId = event.target.dataset.id;
        const row = this.rows.find((r) => r.accountId === accountId);
        if (!row) {
            return;
        }
        this.updateRow(accountId, { saving: true });
        try {
            await reviewSubmission({
                accountId,
                acceptPhone: row.phoneDecision === 'accept',
                acceptAddress: row.addressDecision === 'accept',
                reason: row.reason
            });
            this.toast('Review saved', this.summaryMessage(row), 'success');
            await this.loadRows();
        } catch (e) {
            this.updateRow(accountId, { saving: false });
            this.toast('Error', this.reduceError(e), 'error');
        }
    }

    summaryMessage(row) {
        const accepted = [];
        const rejected = [];
        if (row.phoneChanged) {
            (row.phoneDecision === 'accept' ? accepted : rejected).push('phone');
        }
        if (row.addressChanged) {
            (row.addressDecision === 'accept' ? accepted : rejected).push('address');
        }
        const parts = [];
        if (accepted.length) {
            parts.push('Accepted ' + accepted.join(' and ') + '.');
        }
        if (rejected.length) {
            parts.push('Rejected ' + rejected.join(' and ') + '.');
        }
        return parts.join(' ') || 'The donor record has been updated.';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceError(e) {
        return (e && e.body && e.body.message) ? e.body.message : 'Something went wrong.';
    }
}
