import { LightningElement, api } from 'lwc';
import fetchRecords from '@salesforce/apex/ReusableLookupController.fetchRecords';
/** The delay used when debouncing event handlers before invoking Apex. */
const DELAY = 500;

export default class GenericLookup extends LightningElement {
    @api helpText = "custom search lookup";
    @api label = "Parent Account";
    @api required;
    @api selectedIconName = "standard:account";
    @api objectLabel = "GiftDesignation";
    recordsList = [];
   @api selectedRecordName;

    @api objectApiName = "GiftDesignation";
    @api fieldApiName = "Name";
    @api otherFieldApiName = "";
    @api searchString = "";
    @api value = "";
    @api parentRecordId;
    @api parentFieldApiName;
    @api picklistvalues;
    @api Locations;
    @api readOnlyvar;
    preventClosingOfSerachPanel = false;
get childInputValue() {
        return this.value;
    }
    get methodInput() {
        return {
            objectApiName: this.objectApiName,
            fieldApiName: this.fieldApiName,
            otherFieldApiName: this.otherFieldApiName,
            searchString: this.searchString,
            selectedRecordId: this.value,
            parentRecordId: this.parentRecordId,
            parentFieldApiName: this.parentFieldApiName
        };
    }

    get showRecentRecords() {
        if (!this.recordsList) {
            return false;
        }
        return this.recordsList.length > 0;
    }

    //getting the default selected record
    connectedCallback() {
        console.log('connectedCallback this.value : ', this.value);
       // if (this.value) {
            this.fetchSobjectRecords(true);
       // }
    }

    //call the apex method
    fetchSobjectRecords(loadEvent) {
        console.log('fetchSobjectRecords loadEvent : ', loadEvent);
        debugger;
        fetchRecords({
            inputWrapper: this.methodInput
        }).then(result => {
            console.log('result : ', result);
            if (loadEvent && result) {
                //this.selectedRecordName = result[0].mainField;
            } else if (result) {
                this.recordsList = JSON.parse(JSON.stringify(result));
            } else {
                this.recordsList = [];
            }
        }).catch(error => {
            console.log(error);
        })
    }

    get isValueSelected() {
        return this.value;
    }

    //handler for calling apex when user change the value in lookup
    handleChange(event) {
        console.log('handleChange event.target.value : ', event.target.value);
        debugger;
        this.searchString = event.target.value;
        this.fetchSobjectRecords(false);
    }

    //handler for clicking outside the selection panel
    handleBlur() {
        console.log('handleBlur');
        this.recordsList = [];
        this.preventClosingOfSerachPanel = false;
    }

    //handle the click inside the search panel to prevent it getting closed
    handleDivClick() {
        console.log('handleDivClick');
        this.preventClosingOfSerachPanel = true;
    }

    //handler for deselection of the selected item
    handleCommit() {
        console.log('handleCommit');
        if(!this.readOnlyvar)
        {
            debugger;
            this.value = "";
            this.selectedRecordName = "";
            let selectedRecord = {
                mainField:"",
                subField:"",
                id: "",
                locations: ""
        
        };
       
        this.recordsList = [];
        // Creates the event
        const selectedEvent = new CustomEvent('valueselected', {
            detail: selectedRecord
        });
        //dispatching the custom event
        this.dispatchEvent(selectedEvent);
    }
    }

    //handler for selection of records from lookup result list
    handleSelect(event) {
        console.log('handleSelect event.currentTarget.dataset.id : ', event.currentTarget.dataset.id);
        debugger;
        console.log('event : ',  event.currentTarget.dataset.subfield);
        let selectedRecord = {
            mainField: event.currentTarget.dataset.mainfield,
            subField: event.currentTarget.dataset.subfield.split(';'),
            id: event.currentTarget.dataset.id,
            locations: event.currentTarget.dataset.subfield
        
        };
        this.value = selectedRecord.id;
        this.selectedRecordName = selectedRecord.mainField;
       
        this.recordsList = [];
        console.log('selectedRecord : ', JSON.parse(JSON.stringify(selectedRecord)));
        console.log('this.selectedRecordName : ', this.selectedRecordName);
        // Creates the event
        const selectedEvent = new CustomEvent('valueselected', {
            detail: selectedRecord
        });
        //dispatching the custom event
        this.dispatchEvent(selectedEvent);
    }
    
    //to close the search panel when clicked outside of search input
    handleInputBlur(event) {
        console.log('handleInputBlur');
        debugger;
        // Debouncing this method: Do not actually invoke the Apex call as long as this function is
        // being called within a delay of DELAY. This is to avoid a very large number of Apex method calls.
        window.clearTimeout(this.delayTimeout);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.delayTimeout = setTimeout(() => {
            if (!this.preventClosingOfSerachPanel) {
                this.recordsList = [];
            }
            this.preventClosingOfSerachPanel = false;
        }, DELAY);
    }
}