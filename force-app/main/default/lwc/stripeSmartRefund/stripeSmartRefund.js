import { LightningElement, api, track } from 'lwc';
import { updateRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import isRefunded from '@salesforce/apex/StripeRefundService.isRefunded';
import getPaymentIdAndType from '@salesforce/apex/StripeRefundService.getPaymentIdAndType';
import refundSubscription from '@salesforce/apex/StripeRefundService.refundSubscription';
import refundPaymentIntent from '@salesforce/apex/StripeRefundService.refundPaymentIntent';

// Fields for updating refund status
import REFUND_FIELD from '@salesforce/schema/GiftTransaction.Refunded__c';
import RD_REFUND_FIELD from '@salesforce/schema/GiftCommitment.Refunded__c';
import ID_FIELD from '@salesforce/schema/GiftTransaction.Id';
import STATUS_FIELD from '@salesforce/schema/GiftTransaction.Status';

export default class StripeSmartRefund extends LightningElement {
    @api recordId;
    @track recordType;
    @track paymentId;
    @track amount;        // in minor units for explicit refunds; null for full Stripe refunds
    @track amountMode;
    @track currencyIsoCode;
    @track displayAmount;
    @track response;
    @track loading = true;
    @track isRefunded = false; // disables refund button if true
    @track showModal = false; // for confirmation modal

    get iconName() {
        return this.isRefunded ? 'utility:check' : 'utility:close';
    }

    get iconClass() {
        return this.isRefunded ? 'slds-text-color_success' : 'slds-text-color_error';
    }

    get statusText() {
        return this.isRefunded ? 'Refunded' : 'Not Refunded';
    }

    get amountLabel() {
        return this.amountMode === 'FULL_STRIPE_REFUND' ? 'Refund Amount:' : 'Amount:';
    }

    get confirmationAmount() {
        return this.displayAmount || 'Full original Stripe charge';
    }

    connectedCallback() {
        // Fetch payment ID, type, and amount
        getPaymentIdAndType({ recordId: this.recordId })
            .then(result => {
                this.paymentId = result.paymentId;
                this.recordType = result.recordType; // Donation / RecurringDonation
                this.amount = result.amount || null;
                this.amountMode = result.amountMode;
                this.currencyIsoCode = result.currencyIsoCode;
                this.displayAmount = result.displayAmount || this.formatExplicitAmount(this.amount, this.currencyIsoCode);
                this.loading = false;

                // Check if already refunded
                return isRefunded({ recordId: this.recordId });
            })
            .then(result => {
                this.isRefunded = result;
            })
            .catch(error => {
                this.response = 'Error loading record: ' + this.normalizeErrorMessage(error, 'Unable to load refund details.');
                this.loading = false;
            });
    }

    // Open confirmation modal
    openModal() {
        this.showModal = true;
    }

    // Close modal without action
    closeModal() {
        this.showModal = false;
    }

    // User confirms refund
    confirmRefund() {
        this.showModal = false;
        this.executeRefund();
    }

    // Refund logic
    executeRefund() {
        if (!this.paymentId) {
            this.showToast('Error', 'No Transaction/Subscription ID found.', 'error');
            return;
        }

        this.loading = true;

        let refundPromise;

        if (this.recordType === 'Donation') {
            refundPromise = refundPaymentIntent({ paymentIntentId: this.paymentId, amount: this.amount, Rtype : 'Donation' });
        } else if (this.recordType === 'RDonation') {
            refundPromise = refundPaymentIntent({ paymentIntentId: this.paymentId, amount: this.amount, Rtype : 'RDonation'});
        } else if (this.recordType === 'RecurringDonation') {
            refundPromise = refundSubscription({ subscriptionId: this.paymentId, amount: this.amount });
        } else {
            this.showToast('Error', 'Unknown record type.', 'error');
            this.loading = false;
            return;
        }

        refundPromise
            .then(res => {
                this.response = res;
                return this.updateRefundField();
            })
            .then(() => {
                this.isRefunded = true;
                this.showToast('Success', 'Refund processed successfully!', 'success');
                this.loading = false;
            })
            .catch(err => {
                this.showToast('Refund Failed', this.normalizeErrorMessage(err, 'Refund failed. Please try again or contact support.'), 'error');
                this.loading = false;
            });
    }

    normalizeErrorMessage(error, fallbackMessage) {
        if (Array.isArray(error?.body)) {
            return error.body
                .map(item => item?.message)
                .filter(Boolean)
                .join(', ') || fallbackMessage;
        }

        if (typeof error?.body?.message === 'string' && error.body.message.trim()) {
            return error.body.message;
        }

        if (typeof error?.message === 'string' && error.message.trim()) {
            return error.message;
        }

        if (typeof error === 'string' && error.trim()) {
            return error;
        }

        return fallbackMessage;
    }

    formatExplicitAmount(amount, currencyIsoCode) {
        if (!amount) {
            return 'Full original Stripe charge';
        }

        const parsedAmount = Number.parseInt(amount, 10);
        if (Number.isNaN(parsedAmount)) {
            return currencyIsoCode || '';
        }

        const majorAmount = (parsedAmount / 100).toFixed(2);
        return currencyIsoCode ? `${currencyIsoCode} ${majorAmount}` : majorAmount;
    }

    updateRefundField() {
        let fields = {};
        if (this.recordType === 'Donation' || this.recordType === 'RDonation') {
            fields[ID_FIELD.fieldApiName] = this.recordId;
            fields[REFUND_FIELD.fieldApiName] = true;
            fields[STATUS_FIELD.fieldApiName] = 'Fully Refunded';
            return updateRecord({ fields });
        } else if (this.recordType === 'RecurringDonation') {
            fields['Id'] = this.recordId;
            fields[RD_REFUND_FIELD.fieldApiName] = true;
            return updateRecord({ fields });
        }
        return Promise.resolve();
    }

    showToast(title, message, variant) {
        const evt = new ShowToastEvent({ title, message, variant });
        this.dispatchEvent(evt);
    }
}