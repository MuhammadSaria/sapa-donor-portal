import { LightningElement, api, track } from 'lwc';
import sendDonationPDFs from '@salesforce/apex/DonationPDFLWCScheduler.runBatch';

export default class DonationLWCBatch extends LightningElement {
    isProcessing = false; // To handle UI while the batch is processing
    errorMessage;
    @track fromDate;
    @track toDate;

    connectedCallback() {
        // Set default values for date picker
        console.log('Initialize');
    }

    handleFromDateChange(event) {
        this.fromDate = event.target.value;
    }

    handleToDateChange(event) {
        this.toDate = event.target.value;
    }

    showToast(title, message, variant) {
        const evt = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant,
        });
        this.dispatchEvent(evt);
    }
    
    // for email batch start
    handleSendReceipts() {
        this.isProcessing = true; // Disable the button while processing
        this.errorMessage = null; // Reset any previous errors
        console.log('this.fromDate == '+this.fromDate);
        console.log('this.toDate == '+this.toDate);
        sendDonationPDFs({startYear: this.fromDate, endYear: this.toDate})
        .then(() => {
            // Show success message and reset UI
            this.isProcessing = false;
            //alert('Annual tax receipts batch started successfully.');
        })
        .catch(error => {
            // Show error message and enable the button
            this.isProcessing = false;
            this.errorMessage = 'Error starting batch process: ' + error.body.message;
            console.error('Error starting batch process:', error);
        });
    }

}