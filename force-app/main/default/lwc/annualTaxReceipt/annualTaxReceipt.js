import { LightningElement,api,track,wire } from 'lwc';
import { getRecord } from "lightning/uiRecordApi";
import sendAnnualTaxReceipts from '@salesforce/apex/TaxReceiptBatchController.runBatch';
import SendAnnualTaxReceiptSingle from '@salesforce/apex/SendAnnualTaxReceiptSingle.sendAnnualTaxReceipt';
import ConfirmPostedDonation from '@salesforce/apex/SendAnnualTaxReceiptSingle.ConfirmPostedDonations';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const FIELDS = ["Contact.Name", "Contact.Personal_Email__c","Contact.Preferred_Email__c","Contact.Work_Email__c","Contact.Alternate_Email__c"];

export default class AnnualTaxReceipt extends LightningElement {
isProcessing = false; // To handle UI while the batch is processing
errorMessage;
@track startYear;
@track endYear;

@api recordId;
@track error;
preferredEmail;
personalEmail;
workEmail;
AlternateEmail;
contactName;

/*@wire(getRecord, { recordId: "$recordId", fields: ["Contact.npe01__HomeEmail__c", "Contact.Name"] })
loadFields;*/


@wire(getRecord, { recordId: "$recordId", fields: FIELDS })
loadFields({error, data}){
    console.log('loadFields, recordId: ', this.recordId);
    if(error){
        console.log('error', JSON.parse(JSON.stringify(error)));
    }else if(data){
        console.log('data', JSON.parse(JSON.stringify(data)));
        //const paramField1 = getFieldValue(data, OBJ_FIELD1);  
        this.preferredEmail = data.fields.Preferred_Email__c.value;
        this.personalEmail = data.fields.Personal_Email__c.value;
        this.workEmail = data.fields.Work_Email__c.value;
        this.AlternateEmail = data.fields.Alternate_Email__c.value;      
        this.contactName = data.fields.Name.value;
        
        console.log('Name', this.contactName);
        console.log('preferredEmail', this.preferredEmail);
        console.log('personalEmail', this.personalEmail);
        console.log('workEmail', this.workEmail);
        console.log('AlternateEmail', this.AlternateEmail);
    }
}

handleChangeYear(event)
{
    console.log(event.target.name)
    if(event.target.name === 'startYear')
    {
        this.startYear = event.detail.value;
    }
    else
    {
        this.endYear = event.detail.value;
    }

    console.log(this.startYear)
    console.log(this.endYear)
}



// for email batch start
handleSendReceipts() {
    this.isProcessing = true; // Disable the button while processing
    this.errorMessage = null; // Reset any previous errors

    if (!this.endYear || !this.startYear) {
        this.showToast('Warning', 'Kindly select the Start and End Dates.', 'warning');
        this.isProcessing = false;
    }
    else{
        sendAnnualTaxReceipts({startYear: this.startYear, endYear: this.endYear})
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
        console.log("Either End Year or Start Year is missing");
    }
    
}
//Generate PDF for Batch Start
generatePDFforBatch() {

if (!this.endYear || !this.startYear) {
    this.showToast('Warning', 'Kindly select the Start and End Dates.', 'warning'); 
    
}else{
const vfPageUrl = `/apex/AnnualTaxReceiptPDFbatch?startYear=${this.startYear}&endYear=${this.endYear}`;
window.open(vfPageUrl, '_blank');
console.log("Either End Year or Start Year is missing");
}


}

//Generate PDF for Batch End



// for single contact

callhandleSendReceipt() {
    this.isProcessing = true;
    this.error = null;

    SendAnnualTaxReceiptSingle({
        contactId: this.recordId,
        startYear: this.startYear,
        endYear: this.endYear
    })
    .then((result) => {
        this.isProcessing = false;

        if (result === true) {
            this.showToast('Success', 'Annual Tax Receipt has been sent successfully.', 'success');
        } 
        
        /*else {
            this.showToast('Warning', 'Annual Tax Receipt has already been sent.', 'warning');
        }*/
    })
    .catch((error) => {
        this.isProcessing = false;
        this.error = 'An error occurred while sending the receipt.';
        console.error(error);
    });
}

handleSendReceipt() {
    this.isProcessing = true;
    this.error = null;

    if (!this.endYear || !this.startYear) {
        console.log('handleSendReceipt if====');
        this.showToast('Warning', 'Kindly select the Start and End Dates.', 'warning');  
        this.isProcessing = false;
    }
    else {
        console.log('handleSendReceipt Else====');
        ConfirmPostedDonation({ contactId: this.recordId, startYear: this.startYear, endYear: this.endYear })
        .then((result) => {
            this.isProcessing = false;

            if (result) {          
                // 🟢 FIX: Changed this.Personal_Email__c to this.personalEmail
                if (this.preferredEmail === "Personal" && this.personalEmail) {   
                    console.log('preferredEmail===== ', this.preferredEmail);
                    console.log('personalEmail===== ', this.personalEmail);
                    this.callhandleSendReceipt();
                }
                else if (this.preferredEmail === "Work" && this.workEmail){
                    console.log('preferredEmail===== ', this.preferredEmail);
                    console.log('workEmail===== ', this.workEmail);
                    this.callhandleSendReceipt();  
                }
                else if (this.preferredEmail === "Alternate" && this.AlternateEmail){
                    console.log('preferredEmail===== ', this.preferredEmail);
                    console.log('AlternateEmail===== ', this.AlternateEmail);
                    this.callhandleSendReceipt();
                }
                else {
                    this.showToast('Warning', 'There is no Email associated with this contact.', 'warning');
                }
                
            } else {
                // Show warning if no posted donation is found
                this.showToast('Warning', 'There is no posted donation associated with this contact.', 'warning');
            }
        })
        .catch((error) => {
            this.isProcessing = false;
            this.error = 'An error occurred while sending the receipt.';
            console.error(error); // Always good to log the actual error for debugging!
        });
    }
}

    generatePDF() {
        if (!this.endYear || this.endYear === null || this.endYear === undefined || this.endYear.toString().trim() === '' || 
    !this.startYear || this.startYear === null || this.startYear === undefined || this.startYear.toString().trim() === '') {
        this.showToast('Warning', 'Kindly select the Start and End Dates.', 'warning');            
        }
        else{

            ////////////
            ConfirmPostedDonation({ contactId: this.recordId, startYear: this.startYear, endYear: this.endYear })
        .then((result) => {
            this.isProcessing = false;

            if (result) {
                // Show success toast
                console.log('this.endYear==',this.endYear);
                console.log('this.startYear==',this.startYear);
                const vfPageUrl = `/apex/AnnualTaxReceipt?startYear=${this.startYear}&endYear=${this.endYear}&contactId=${this.recordId}`;
                window.open(vfPageUrl, '_blank');
                
            } else {
                // Show warning if Annual Tax is already sent
                this.showToast('Warning', 'There is no Paid donation associated with this contact.', 'warning');
            }
        })
        .catch((error) => {
            this.isProcessing = false;
            this.error = 'An error occurred while sending the receipt.';
        });
        console.log("Either End Year or Start Year is missing");
            /////////////            
        }
        
    }


//generate PDF for Single Contact

showToast(title, message, variant) {
    const toastEvent = new ShowToastEvent({
        title: title,
        message: message,
        variant: variant,
    });
    this.dispatchEvent(toastEvent);
}
}