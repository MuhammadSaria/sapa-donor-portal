import { LightningElement, api, track } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import preview from '@salesforce/apex/CampaignPortalLinkController.preview';
import generate from '@salesforce/apex/CampaignPortalLinkController.generate';

export default class GeneratePortalLinks extends LightningElement {
    @track summary;
    @track loading = true;
    @track working = false;
    @track errorText;

    _recordId;

    // Set by the record page when the action opens; the preview runs as soon as the id arrives.
    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        if (value && value !== this._recordId) {
            this._recordId = value;
            this.loadPreview();
        }
    }

    async loadPreview() {
        this.loading = true;
        this.errorText = null;
        try {
            this.summary = await preview({ campaignId: this._recordId });
        } catch (e) {
            this.errorText = this.reduceError(e);
        } finally {
            this.loading = false;
        }
    }

    async handleGenerate() {
        this.working = true;
        this.errorText = null;
        try {
            this.summary = await generate({ campaignId: this._recordId });
        } catch (e) {
            this.errorText = this.reduceError(e);
        } finally {
            this.working = false;
        }
    }

    handleClose() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    get showPreview() {
        return !this.loading && this.summary && !this.summary.generated;
    }

    get showResult() {
        return !this.loading && this.summary && this.summary.generated;
    }

    get nothingToIssue() {
        return this.summary && this.summary.toIssue === 0;
    }

    get cannotGenerate() {
        return this.working || this.nothingToIssue;
    }

    get generateLabel() {
        return this.working ? 'Creating links…' : `Create ${this.summary ? this.summary.toIssue : 0} links`;
    }

    reduceError(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong. Please try again.';
    }
}
