import { LightningElement, api, wire, track } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import deleteSubscription from '@salesforce/apex/StripeVoidService.deleteSubscription';
import { CloseActionScreenEvent } from 'lightning/actions';

// Replace with your actual field API name
import SUBSCRIPTION_ID_FIELD from '@salesforce/schema/GiftCommitment.Subscription_Id__c';


export default class StripeVoidInvoice extends LightningElement {
    @api recordId;
    @track isLoading = false;
    @track closedReason;
    @track showConfirmModal = false;
    
    // Wire the record to get the Invoice ID field value
    @wire(getRecord, { recordId: '$recordId', fields: [SUBSCRIPTION_ID_FIELD] })
    recurringDonation;

    get subscriptionId() {
        return getFieldValue(this.recurringDonation.data, SUBSCRIPTION_ID_FIELD);
    }

    handleClosedReasonChange(event) {
        this.closedReason = event.detail.value;
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleVoid() {
        if (!this.subscriptionId) {
            this.showToast('Error', 'No Stripe Subscription ID found on this record.', 'error');
            return;
        }

        if (!this.closedReason) {
            this.showToast('Error', 'Please select a Closed Reason before cancelling.', 'error');
            return;
        }

        this.showConfirmModal = true;
    }

    closeConfirmModal() {
        this.showConfirmModal = false;
    }

    confirmCancellation() {
        this.isLoading = true;
        this.showConfirmModal = false;

        deleteSubscription({ 
            subscriptionId: this.subscriptionId,
            recurringDonationId: this.recordId,
            closedReason: this.closedReason 
        })
            .then(async (result) => {
                if (result !== true) {
                    this.showToast('Cancellation Failed', 'Stripe did not confirm cancellation. The Salesforce record was not closed.', 'error');
                    return;
                }
                try {
                    await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
                    this.showToast('Success', 'Subscription has been cancelled in Stripe and Salesforce.', 'success');
                } catch {
                    this.showToast('Subscription Cancelled', 'The subscription was cancelled. Refresh the record to see the saved Salesforce status.', 'warning');
                }
                this.dispatchEvent(new CloseActionScreenEvent());
            })
            .catch((error) => {
                this.showToast('Cancellation Error', error?.body?.message || error?.message || 'Cancellation could not be confirmed.', 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant
            })
        );
    }
}