import { LightningElement, api, track } from 'lwc';
import getFunds from '@salesforce/apex/FundLocationController.getFunds';

// 1. IMPORT THE FLOW REACTIVITY MODULE
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';

export default class FundLocationSelector extends LightningElement {
    @api selectedFundId;
    @api selectedFundName;
    @api selectedLocation;

    @track searchKey = '';
    @track fundResults = [];
    @track locationOptions = [];
    @track isDropdownOpen = false;
    @track isLocationDisabled = true;

    get dropdownClasses() {
        return `slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click ${this.isDropdownOpen ? 'slds-is-open' : ''}`;
    }

    get isValueSelected() {
        return this.selectedFundId != null && this.selectedFundId !== '';
    }

    fetchFundsFromApex() {
        let inputWrapper = {
            objectApiName: "GiftDesignation",
            fieldApiName: "Name",
            searchString: this.searchKey
        };

        getFunds({ inputWrapper: inputWrapper })
            .then(result => {
                this.fundResults = result ? result : [];
                this.isDropdownOpen = this.fundResults.length > 0;
            })
            .catch(error => {
                console.error('Error fetching funds: ', error);
                this.fundResults = [];
                this.isDropdownOpen = false;
            });
    }

    openDropdown() {
        if (!this.isValueSelected) {
            this.fetchFundsFromApex(); 
        }
    }

    handleSearch(event) {
        this.searchKey = event.target.value;
        this.fetchFundsFromApex();
    }

    handleFundSelect(event) {
        // Assign the values
        this.selectedFundId = event.currentTarget.dataset.id;
        this.selectedFundName = event.currentTarget.dataset.name;
        
        // 2. DISPATCH EVENTS TO TELL THE FLOW THE VALUES CHANGED
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedFundId', this.selectedFundId));
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedFundName', this.selectedFundName));

        let locationString = event.currentTarget.dataset.locations;
        this.isDropdownOpen = false;
        this.searchKey = '';

        if (locationString && locationString !== 'undefined' && locationString.trim() !== '') {
            let locationsArray = locationString
                .split(';')
                .map(loc => loc.trim())
                .filter(Boolean);
            
            this.locationOptions = locationsArray.map(loc => {
                return { label: loc, value: loc };
            });
            
            this.isLocationDisabled = false;
            this.selectedLocation = this.locationOptions[0].value; 
            
            // Notify Flow about the default location selection
            this.dispatchEvent(new FlowAttributeChangeEvent('selectedLocation', this.selectedLocation));
        } else {
            this.resetLocation(); 
        }
    }

    preventBlur(event) {
        event.preventDefault();
    }

    closeDropdown() {
        setTimeout(() => {
            this.isDropdownOpen = false;
        }, 200);
    }

    clearSelection() {
        this.selectedFundId = '';
        this.selectedFundName = '';
        
        // Notify Flow the selection was cleared
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedFundId', this.selectedFundId));
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedFundName', this.selectedFundName));
        
        this.resetLocation();
        
        setTimeout(() => {
            let searchBox = this.template.querySelector('.fund-search-input');
            if(searchBox) searchBox.focus();
        }, 100);
    }

    handleLocationChange(event) {
        this.selectedLocation = event.detail.value;
        // Notify Flow if the user manually changes the location
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedLocation', this.selectedLocation));
    }

    resetLocation() {
        this.locationOptions = [];
        this.selectedLocation = '';
        this.isLocationDisabled = true;
        // Notify Flow the location was cleared
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedLocation', this.selectedLocation));
    }
}