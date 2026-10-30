import { LightningElement,api } from 'lwc';

export default class RedirectToRecord extends LightningElement {
    @api recordIdToRedirect;
    @api isLoading=false;

    connectedCallback(){
        this.isLoading=true;
        window.location.href = "/"+this.recordIdToRedirect;
        this.isLoading=false;

    }
}