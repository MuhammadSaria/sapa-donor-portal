import { LightningElement, api, wire, track } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';

import SUBSCRIPTION_ID_FIELD from '@salesforce/schema/GiftCommitment.Subscription_Id__c';
import STATUS_FIELD from '@salesforce/schema/GiftCommitment.Status';
import PAUSE_REASON_FIELD from '@salesforce/schema/GiftCommitment.Pause_Reason__c';
import PAUSE_RESUME_DATE_FIELD from '@salesforce/schema/GiftCommitment.Pause_Resume_Date__c';
import PAUSE_START_DATE_FIELD from '@salesforce/schema/GiftCommitment.Pause_Start_Date__c';
import PAUSE_STATE_FIELD from '@salesforce/schema/GiftCommitment.Stripe_Pause_State__c';
import PAUSE_ERROR_FIELD from '@salesforce/schema/GiftCommitment.Stripe_Pause_Last_Error__c';
import NEXT_PAYMENT_FIELD from '@salesforce/schema/GiftCommitment.NextTransactionDate';

import previewPause from '@salesforce/apex/StripePauseOrchestrator.previewPause';
import pauseSubscription from '@salesforce/apex/StripePauseOrchestrator.pauseConfirmed';
import resumeSubscription from '@salesforce/apex/StripePauseOrchestrator.resume';

const FIELDS = [
    SUBSCRIPTION_ID_FIELD,
    STATUS_FIELD,
    PAUSE_REASON_FIELD,
    PAUSE_RESUME_DATE_FIELD,
    PAUSE_START_DATE_FIELD,
    PAUSE_STATE_FIELD,
    PAUSE_ERROR_FIELD,
    NEXT_PAYMENT_FIELD
];

export default class StripePauseSubscription extends LightningElement {

    @api recordId;

    @track isLoading = false;
    @track showConfirmModal = false;
    @track pauseReason = '';
    @track resumeDate = '';
    @track pendingAction = null; // 'pause' | 'resume'
    @track recordData = null;
    @track recordError = null;
    pausePreview = null;

    // ─── Wire ───────────────────────────────────────────────────────────────

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredGiftCommitment({ error, data }) {
        this.recordData = data;
        this.recordError = error;
        if (error) {
            console.error('StripePauseSubscription getRecord error', error);
        }
    }

    // ─── Derived Getters ────────────────────────────────────────────────────

    get subscriptionId() {
        if (!this.recordData) {
            console.debug('StripePauseSubscription: record data not loaded yet', this.recordId);
            return '';
        }
        return getFieldValue(this.recordData, SUBSCRIPTION_ID_FIELD) || '';
    }

    get status() {
        return getFieldValue(this.recordData, STATUS_FIELD);
    }

    get currentPauseReason() {
        return getFieldValue(this.recordData, PAUSE_REASON_FIELD);
    }

    get scheduledResumeDate() {
        return getFieldValue(this.recordData, PAUSE_RESUME_DATE_FIELD);
    }

    get scheduledStartDate() {
        return getFieldValue(this.recordData, PAUSE_START_DATE_FIELD);
    }

    get isSalesforcePauseScheduled() {
        return this.pauseState === 'Scheduled';
    }

    get isResumeScheduled() { return this.pauseState === 'Resume Scheduled'; }
    get nextPaymentDate() { return getFieldValue(this.recordData, NEXT_PAYMENT_FIELD); }

    get pauseState() {
        return getFieldValue(this.recordData, PAUSE_STATE_FIELD);
    }

    get pauseError() {
        return getFieldValue(this.recordData, PAUSE_ERROR_FIELD);
    }

    get isReconciliationRequired() {
        return this.pauseState === 'Sync Error' || this.pauseState === 'Failed' || this.pauseError?.startsWith('CONCURRENT_ACTION:');
    }

    /** True when the component should render the PAUSE form */
    get isPauseMode() {
        return !!this.recordData && !this.recordError && !this.pauseState && !this.isReconciliationRequired;
    }

    /** True when the component should render the RESUME form */
    get isResumeMode() {
        return !this.isReconciliationRequired && !this.isResumeScheduled &&
            (this.status === 'Paused' || this.pauseState === 'Scheduled' || this.pauseState === 'Active');
    }

    /** Today's date in YYYY-MM-DD format — used as min date for the date picker */
    get todayIso() {
        const parts = new Intl.DateTimeFormat('en-US', {
            timeZone: 'America/Los_Angeles',
            year: 'numeric', month: '2-digit', day: '2-digit'
        }).formatToParts(new Date());
        const value = type => parts.find(part => part.type === type).value;
        return value('year') + '-' + value('month') + '-' + value('day');
    }

    // ─── Confirm Modal Computed Properties ──────────────────────────────────

    get confirmTitle() {
        return this.pendingAction === 'pause'
            ? 'Confirm Subscription Pause'
            : 'Confirm Early Resume';
    }

    get confirmMessage() {
        return this.pendingAction === 'pause'
            ? (this.pausePreview?.paidToday
                ? 'A donation is already paid today and will remain unchanged. Stripe collection will stop immediately. Salesforce pause will start on ' + this.pausePreview.pauseStartDate + ' (America/Los_Angeles); until then the Salesforce Status remains Active with Pause Scheduled.'
                : 'Stripe collection will stop immediately. Salesforce pause will start on ' + this.pausePreview?.pauseStartDate + ' (America/Los_Angeles). Invoices generated during the pause period will be voided.')
            : 'Stripe collection will resume now. Salesforce will retain the next original-calendar payment date; no catch-up installment will be created.';
    }

    get confirmNote() {
        return this.pendingAction === 'pause'
            ? 'Stripe collection will automatically resume at 00:00 America/Los_Angeles on ' + this.resumeDate + '.'
            : 'This action cannot be undone. Future scheduled payments will recommence.';
    }

    get confirmButtonLabel() {
        return this.pendingAction === 'pause' ? 'Yes, Pause Subscription' : 'Yes, Resume Now';
    }

    get confirmButtonVariant() {
        return this.pendingAction === 'pause' ? 'destructive' : 'brand';
    }

    get loadingMessage() {
        return this.pendingAction === 'pause' ? 'Pausing subscription...' : 'Resuming subscription...';
    }

    // ─── Event Handlers ─────────────────────────────────────────────────────

    handlePauseReasonChange(event) {
        this.pauseReason = event.detail.value;
    }

    handleResumeDateChange(event) {
        this.resumeDate = event.detail.value;
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    async handlePauseClick() {
        if (this.isLoading) return;
        // Validate required fields before opening modal
        if (!this.subscriptionId) {
            this.showToast('Error', 'No Stripe Subscription ID found on this record.', 'error');
            return;
        }
        if (!this.pauseReason) {
            this.showToast('Error', 'Please select a Pause Reason.', 'error');
            return;
        }
        if (!this.resumeDate) {
            this.showToast('Error', 'Please enter an Auto-Resume Date.', 'error');
            return;
        }
        if (this.resumeDate <= this.todayIso) {
            this.showToast('Error', 'Resume date must be in the future.', 'error');
            return;
        }
        this.pendingAction = 'pause';
        this.isLoading = true;
        try {
            const preview = await previewPause({ subscriptionId: this.subscriptionId, commitmentId: this.recordId });
            if (!preview?.pauseStartDate || preview.timeZone !== 'America/Los_Angeles') {
                throw new Error('The pause start date could not be verified. Reopen the action before retrying.');
            }
            if (this.resumeDate <= preview.pauseStartDate) {
                this.showToast('Invalid Auto-Resume Date', 'Auto-resume must be after ' + preview.pauseStartDate + ' (America/Los_Angeles), the Salesforce pause start date.', 'error');
                return;
            }
            this.pausePreview = preview;
            this.showConfirmModal = true;
        } catch (error) {
            this.showToast('Pause date could not be checked', error?.body?.message || error?.message || 'Reopen the action before retrying.', 'error');
        } finally { this.isLoading = false; }
    }

    handleResumeClick() {
        if (!this.subscriptionId) {
            this.showToast('Error', 'No Stripe Subscription ID found on this record.', 'error');
            return;
        }
        this.pendingAction = 'resume';
        this.showConfirmModal = true;
    }

    closeConfirmModal() {
        this.showConfirmModal = false;
    }

    confirmAction() {
        if (this.isLoading) return;
        this.showConfirmModal = false;
        if (this.pendingAction === 'pause') {
            this.executePause();
        } else {
            this.executeResume();
        }
    }

    // ─── Apex Calls ─────────────────────────────────────────────────────────

    executePause() {
        if (this.isLoading) return;
        this.isLoading = true;
        pauseSubscription({
            subscriptionId: this.subscriptionId,
            commitmentId: this.recordId,
            reason: this.pauseReason,
            resumeDateStr: this.resumeDate,
            confirmedBusinessDateStr: this.pausePreview.businessDate,
            confirmedPauseStartDateStr: this.pausePreview.pauseStartDate,
            confirmedPaidToday: this.pausePreview.paidToday
        })
            .then(async result => {
                if (!result?.stripeConfirmed || !['Paused', 'Scheduled'].includes(result.salesforceState)) {
                    this.showToast('Pause requires reconciliation', result?.message || 'The pause was not verified.', 'error');
                    return;
                }
                this.showToast(result.salesforceState === 'Scheduled' ? 'Salesforce pause scheduled' : 'Subscription paused',
                    result.message, result.salesforceState === 'Scheduled' ? 'warning' : 'success');
                await this.refreshAndClose();
            })
            .catch(error => {
                const msg = error?.body?.message || error?.message || 'Unknown error';
                this.showToast('Pause Failed', msg, 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    executeResume() {
        if (this.isLoading) return;
        this.isLoading = true;
        resumeSubscription({
            subscriptionId: this.subscriptionId,
            commitmentId: this.recordId
        })
            .then(async result => {
                if (!result?.stripeConfirmed || !['Active', 'Resume Scheduled'].includes(result.salesforceState)) {
                    this.showToast('Resume requires reconciliation', result?.message || 'The resume was not verified.', 'error');
                    return;
                }
                this.showToast(result.salesforceState === 'Resume Scheduled' ? 'Salesforce resumption scheduled' : 'Subscription resumed',
                    result.message, result.salesforceState === 'Resume Scheduled' ? 'warning' : 'success');
                await this.refreshAndClose();
            })
            .catch(error => {
                const msg = error?.body?.message || error?.message || 'Unknown error';
                this.showToast('Resume Failed', msg, 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    async refreshAndClose() {
        try {
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(new CloseActionScreenEvent());
        } catch {
            this.showToast('Record refresh pending', 'The action completed. Refresh the recurring donation to see its saved state.', 'warning');
        }
    }

    // ─── Helper ─────────────────────────────────────────────────────────────

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}