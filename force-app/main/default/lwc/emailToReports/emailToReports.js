import { LightningElement, track } from 'lwc';
import getReportsFromFolder from '@salesforce/apex/emailToReportsController.getReportsFromFolder';
import getEmailTemplatesFromFolder from '@salesforce/apex/emailToReportsController.getEmailTemplatesFromFolder';
import getReportEmailColumns from '@salesforce/apex/emailToReportsController.getReportEmailColumns';
import sendReportEmailsWithTable from '@salesforce/apex/sendReportViaEmail.sendReportEmailsWithTable';
import getFromEmailOptions from '@salesforce/apex/sendReportViaEmail.getFromEmailOptions';


//import getEmailTemplatePreview from '@salesforce/apex/emailToReportsController.getEmailTemplatePreview';
import getEmailTemplatePreviewWithReport from '@salesforce/apex/sendReportViaEmail.getEmailTemplatePreviewWithReport';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class emailToReports extends LightningElement {
    @track reportOptions = [];
    @track templateOptions = [];
    selectedReportId;
    selectedTemplateId;
    @track emailColumnOptions = [];
    selectedEmailColumn;
    reportColumnsLoaded = false;

    // preview modal
    @track isPreviewOpen = false;
    @track previewSubject = '';
    @track previewBody = '';

    //preview navigation
    @track previewRows = [];
    @track currentRowIndex = 0;
    @track rawTemplate = '';

    // From Email Options
    @track fromEmailOptions = [];
    selectedFromOption; // e.g. 'USER' or 'OWEA:<id>'


    connectedCallback() {
        this.loadReports();
        this.loadTemplates();
        this.loadFromEmailOptions();
    }

    loadReports() {
        getReportsFromFolder({ folderName: 'Email Reports' })
            .then(result => {
                this.reportOptions = result.map(r => ({ label: r.name, value: r.id }));
            })
            .catch(error => console.error(error));
    }

    loadTemplates() {
        getEmailTemplatesFromFolder({ folderName: 'Report Templates' })
            .then(result => {
                this.templateOptions = result.map(t => ({ label: t.name, value: t.id }));
            })
            .catch(error => console.error(error));
    }

    handleReportChange(event) {
        this.selectedReportId = event.detail.value;
        this.loadReportColumns();
    }

    loadReportColumns() {
        this.reportColumnsLoaded = false;
        this.emailColumnOptions = [];

        getReportEmailColumns({ reportId: this.selectedReportId })
            .then(result => {
                this.emailColumnOptions = result.map(col => ({ label: col, value: col }));
                this.reportColumnsLoaded = true;

                if (this.emailColumnOptions.length === 0) {
                    this.showToast('Info', 'No email-type columns found in this report.', 'info');
                } else {
                    this.selectedEmailColumn = this.emailColumnOptions[0].value;
                }
            })
            .catch(error => {
                console.error('Error loading email columns:', error);
                this.showToast('Error', 'Failed to load email columns.', 'error');
            });
    }

    handleEmailColumnChange(event) {
        this.selectedEmailColumn = event.detail.value;
    }

    handleTemplateChange(event) {
        this.selectedTemplateId = event.detail.value;
    }


    loadFromEmailOptions() {
    getFromEmailOptions({ defaultOrgWideEmail: 'info@sapa-usa.org' })
        .then((result) => {
            this.fromEmailOptions = result || [];
            // default selection (controller returns default first, but we’ll be explicit)
            this.selectedFromOption = this.fromEmailOptions?.[0]?.value;
        })
        .catch((e) => {
            console.error(e);
            this.showToast('Error', 'Failed to load From Email options.', 'error');
        });
}

handleFromChange(event) {
    this.selectedFromOption = event.detail.value;
}



    handleSendEmail() {
        if (!this.selectedReportId || !this.selectedTemplateId || !this.selectedEmailColumn || !this.selectedFromOption) {
            this.showToast('Error', 'Please select all required fields.', 'error');
            return;
        }

        sendReportEmailsWithTable({
            reportId: this.selectedReportId,
            templateId: this.selectedTemplateId,
            selectedEmailColumn: this.selectedEmailColumn,
            fromOption: this.selectedFromOption
        })
            .then(() => this.showToast('Success', 'Emails sent successfully!', 'success'))
            .catch(error => this.showToast('Error', error.body.message, 'error'));
    }

    // New method for preview
handlePreview() {
    if (!this.selectedReportId || !this.selectedTemplateId) {
        this.showToast('Error', 'Please select both a report and an email template.', 'error');
        return;
    }

    getEmailTemplatePreviewWithReport({
        reportId: this.selectedReportId,
        templateId: this.selectedTemplateId
    })
        .then(result => {
            this.previewSubject = result.subject;
            this.rawTemplate = result.template;
            this.previewRows = result.rows;
            this.currentRowIndex = 0;

            this.isPreviewOpen = true;
            this.renderPreviewRow();
        })
        .catch(error => {
            console.error(error);
            this.showToast('Error', 'Unable to load preview.', 'error');
        });
}

renderPreviewRow() {
    if (!this.previewRows || this.previewRows.length === 0) return;

    let row = this.previewRows[this.currentRowIndex];
    let body = this.rawTemplate;

    for (let i = 0; i < row.length; i++) {
        body = body.replace(`{{column${i + 1}}}`, row[i]);
    }

    // replace unused placeholders
    body = body.replace(/{{column\d+}}/g, '');

    setTimeout(() => {
        const container = this.template.querySelector('[data-id="previewBody"]');
        if (container) container.innerHTML = body;
    }, 100);
}

get isPrevDisabled() {
    return this.currentRowIndex === 0;
}

get isNextDisabled() {
    return this.previewRows.length === 0 ||
           this.currentRowIndex === this.previewRows.length - 1;
}


handleNext() {
    if (this.currentRowIndex < this.previewRows.length - 1) {
        this.currentRowIndex++;
        this.renderPreviewRow();
    }
}

handlePrev() {
    if (this.currentRowIndex > 0) {
        this.currentRowIndex--;
        this.renderPreviewRow();
    }
}






    closePreview() {
        this.isPreviewOpen = false;
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}