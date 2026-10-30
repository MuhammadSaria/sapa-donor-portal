import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import sendEmail1 from '@salesforce/apex/DonationPDFLWCController.sendEmail';

export default class DonationPDFLWC extends LightningElement {
    @api recordId;
    @api objectApiName;   
    @track fromDate;
    @track toDate;

    handleFromDateChange(event) {
        this.fromDate = event.target.value;
    }

    handleToDateChange(event) {
        this.toDate = event.target.value;
    }

    handleSubmit() {
        console.log('this.fromDate====',this.fromDate);
        console.log('this.toDate====',this.toDate);
        console.log('RecordId====',this.recordId);
        const vfPageUrl = `/apex/DonationSummaryPDF?fromDate=${this.fromDate}&toDate=${this.toDate}&RecordId=${this.recordId}`;
        window.open(vfPageUrl, '_blank');
    }

    sendEmail(){
        sendEmail1({ accountId: this.recordId, fromDate : this.fromDate, toDate: this.toDate })
            .then(result => {
                console.log('TOAST1');
                console.log('rse '+result);
                this.showToast('Success', 'Email has been sent!', 'success');
                
            }).catch(error => {
                console.log(error);
            });
    }

    showToast(title, message, variant) {
        const evt = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant,
        });
        this.dispatchEvent(evt);
    }
}