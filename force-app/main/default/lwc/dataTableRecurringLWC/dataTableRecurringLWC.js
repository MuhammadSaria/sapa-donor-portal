import { LightningElement,api,wire,track } from 'lwc';
import { FlowNavigationNextEvent,FlowNavigationBackEvent } from 'lightning/flowSupport';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';
import getPicklistValues from '@salesforce/apex/DataTableRecurringCTRL.getData';

export default class DataTableLWC extends LightningElement {
    @api records;
    @api allocations;
    @track  picklistValues;
    @track locationValues;
    @track Lstofrecs;
    @api recordslst;
    @api availableActions;
    @track recordl;
    @api TotalSingle;
    @api Heading;
    @api SummarySingleAll;
    @track showValue = true;
    @track locationOptions = [];
    @track intentionOptions = [];
    fundLocationValuesByName = {};

    // --- DUMMY VARIABLES FOR DEPLOYMENT ---
    // These must exist to stop the deletion error, but your code ignores them.
    @api transactionDesignationsOutput; 
    @api recurringRecordsOutput;
    @api recurringRecords;
    // --------------------------------------

    @wire(getPicklistValues)
    wiredPicklistValues({ error, data }) {
       if (data) {
            // Raw values coming from Apex
            this.picklistValues = data.LocationValues.label;
            this.intentionValues = data.IntentionValues.label;
            this.locationOptions = this.buildOptions(data.LocationValues);
            this.intentionOptions = this.buildOptions(data.IntentionValues);
            this.fundLocationValuesByName = data.FundLocationValuesByName || {};
            this.applyLocationOptionsToRows();

            // Intention: move each record's Intention__c to the front of the intentionValues array
            let intentionOrdered = [...this.intentionValues];
            this.records.forEach((record)=> {
                intentionOrdered.forEach((item, j) => {
                    if(item == record.Intention__c) {
                        intentionOrdered.splice(j, 1);
                        intentionOrdered.unshift(item);
                    }
                })
            });
            this.intentionValues = intentionOrdered;

            // Location: same logic as intention, using Locations__c and picklistValues
            let locationOrdered = [...this.picklistValues];
            this.records.forEach((record)=> {
                locationOrdered.forEach((loc, j) => {
                    if(loc == record.Locations__c) {
                        locationOrdered.splice(j, 1);
                        locationOrdered.unshift(loc);
                    }
                })
            });
            this.picklistValues = locationOrdered;
        } else if (error) {
            // Handle error appropriately
        }
    }

    buildOptions(picklistData) {
        const labels = picklistData && picklistData.label ? picklistData.label : [];
        const values = picklistData && picklistData.values ? picklistData.values : [];

        return labels.map((label, index) => {
            return {
                label,
                value: values[index] || label
            };
        });
    }

    buildOptionsFromValues(values) {
        return (values || [])
            .map(value => value ? value.trim() : '')
            .filter(Boolean)
            .map(value => {
                return { label: value, value };
            });
    }

    getFundName(record) {
        return record ? (record.Fund_Name__c || record.Name || '') : '';
    }

    getLocationOptionsForRecord(record) {
        const fundName = this.getFundName(record);
        const fundLocations = this.fundLocationValuesByName[fundName];
        const options = fundLocations && fundLocations.length
            ? this.buildOptionsFromValues(fundLocations)
            : [...this.locationOptions];

        if (record && record.Locations__c && !options.some(option => option.value === record.Locations__c)) {
            options.unshift({ label: record.Locations__c, value: record.Locations__c });
        }

        return options;
    }

    applyLocationOptionsToRows() {
        if (!this.recordl) {
            return;
        }

        this.recordl = this.recordl.map(record => {
            return {
                ...record,
                locationOptions: this.getLocationOptionsForRecord(record)
            };
        });
    }

    getOutputRows() {
        return (this.recordl || []).map(record => {
            const outputRecord = { ...record };
            delete outputRecord.locationOptions;
            return outputRecord;
        });
    }

    Previous() {
        debugger;
       // Check if 'NEXT' action is available
       if (this.availableActions.find((action) => action === "BACK")) {
           const navigateBackEvent = new FlowNavigationBackEvent();
           this.dispatchEvent(navigateBackEvent);
       }
    }  

    connectedCallback(){
        debugger;
        //want to get the index as well
        
        this.recordl = this.records;
        var templst=[];
        var index = 0;
        this.recordl.forEach((record)=>
        {
            console.log('Object.Name : ', record);
            console.log('object ' + JSON.stringify(record)   );
            let tempRec = Object.assign({}, record);
            
            console.log('tempRec : ', tempRec);
            console.log('tempRec.Fund_Name__c : ', tempRec.Fund_Name__c);
            
            console.log('tempRec.Fund_Name__c : ', tempRec.Name);
            // Location handling removed

            tempRec.index = index++;
            tempRec.Message ='';
            tempRec.locationOptions = this.getLocationOptionsForRecord(tempRec);
            templst.push(tempRec);

        })
        this.recordl = templst;
    }

    Removerow(event) { 
        debugger;
        var  tempRec =[];
        var recordlst =  this.recordl;

        let index = event.target.dataset.index;
       for (let i = 0; i < recordlst.length ; i++) {
           if(i!= index)
           {
               tempRec.push(recordlst[i]);
           }
          }
          this.recordl = tempRec;
    }

    save() {
        debugger;
        var totalSum = 0;
        
        // 1. Loop through the table to calculate totals AND fix field mappings
        for (let i = 0; i < this.recordl.length ; i++) {
            totalSum += Number(this.recordl[i].Amount__c);
            
            // --- CRITICAL FIX FOR NPC STANDARD FIELDS ---
            // Copy the custom Amount__c into the standard Amount field.
            // This ensures GiftTransactionDesignation (Output 2) accepts it!
            this.recordl[i].Amount = this.recordl[i].Amount__c; 
        }

        // 2. --- SIMULTANEOUS OUTPUT ASSIGNMENT ---
        // Now that "Amount" exists on these records, the Flow will successfully 
        // read it for the GiftTransactionDesignation collection.
        const outputRows = this.getOutputRows();
        this.recordslst = outputRows; 
        this.transactionDesignationsOutput = outputRows; 
        this.recurringRecordsOutput = outputRows; 
        
        var summary;
        this.TotalSingle = totalSum;
        this.SummarySingleAll = summary;

        this.dispatchEvent(new FlowAttributeChangeEvent('recordslst', this.recordslst));
        this.dispatchEvent(new FlowAttributeChangeEvent('transactionDesignationsOutput', this.transactionDesignationsOutput));
        this.dispatchEvent(new FlowAttributeChangeEvent('recurringRecordsOutput', this.recurringRecordsOutput));
        this.dispatchEvent(new FlowAttributeChangeEvent('TotalSingle', this.TotalSingle));
        this.dispatchEvent(new FlowAttributeChangeEvent('SummarySingleAll', this.SummarySingleAll));
        
        // 3. Navigate to the next screen
        if (this.availableActions && this.availableActions.find((action) => action === 'NEXT')) {
            const navigateNextEvent = new FlowNavigationNextEvent();
            this.dispatchEvent(navigateNextEvent);
        }
    }
    handleInputChange(event) {
        debugger;
        let value = event.target.value;
        var selectedrec = event.detail;
        console.log(typeof value);
        let i = event.target.dataset.index;
        let fieldName = event.target.name;

        var  tempRec =[];
        var recordlst =  this.recordl;
        console.log('recordlst : ', JSON.stringify(recordlst));
        let index = event.target.dataset.index;
        for (let i = 0; i < recordlst.length ; i++) {
            if(i== index)
            {
                var obj = {...recordlst[i], [fieldName]: value };
                if(fieldName =='GiftDesignation')
                    {
                        console.log('selectedrec : ', selectedrec   );
                        console.log('selectedrec.mainField : ', selectedrec.mainField   );
                        // Location handling removed; keep only name update when provided
                        if(selectedrec && selectedrec.mainField){
                            obj.Name = selectedrec.mainField;
                            obj.Fund_Name__c = selectedrec.mainField;
                        }
                        if(selectedrec && selectedrec.locations) {
                            obj.locationOptions = this.buildOptionsFromValues(selectedrec.locations.split(';'));
                            if (!obj.locationOptions.some(option => option.value === obj.Locations__c)) {
                                obj.Locations__c = obj.locationOptions.length ? obj.locationOptions[0].value : '';
                            }
                        }
                    }
                if(fieldName === 'Locations__c') {
                    obj.locationOptions = recordlst[i].locationOptions;
                }
                tempRec.push(obj);

            }
            else
            { 
                var obj = recordlst[i];
                tempRec.push(obj);
            }

        }
        if(selectedrec!== undefined)
        {
        //this.showValue = false;
        } 

        this.recordl = tempRec;
    } 

    validateForm() {
         debugger;
        
        let isValid = true;

        this.recordl.forEach(item => {
            const nameInput = this.template.querySelector(`lightning-input[data-index="${item.index}"][name="TransactionAmount"]`);
            const ChildCmp = this.template.querySelector(`c-lookup-generic[data-index="${item.index}"]`);
             if (ChildCmp) {    
            if (item.GiftDesignation === '') {
                item.Message = 'Fund Allocation is required';
                isValid = false;
            }
          
        }
           else if (item.Amount__c === '') {
                item.Message = 'Allocation Amount is required';
                isValid = false;
            } 
          else
          item.Message = '';
        });

        if (isValid) {
            this.save();
        }
    } 
}