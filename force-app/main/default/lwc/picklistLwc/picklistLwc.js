import { LightningElement, api, track } from 'lwc';

export default class PicklistLwc extends LightningElement {
    
@api recordId;
@api recordIds;
@track picklistValues;
@api selectedVal;
@api locs;
@api SelectedRecName;
@api showDates = false;
@track IsDisabled = true;
@track selectedDate;
@api SpDate = new Date().toISOString();
@api RVDate ;
@api showSPdate;
@api Type;
@api isRenewalDateReq;
  connectedCallback(){
        debugger;
        this.showDates =false;
        this.selectedDate = new Date().toISOString();
        this.SpDate = this.selectedDate;
  }
 handleInputChange(event) {
      var selectedRecord = event.detail;
        this.picklistValues =selectedRecord.subField;
        this.recordId = selectedRecord.id;
        this.locs =selectedRecord.locations;
        this.selectedVal = selectedRecord.subField[0];
        this.SelectedRecName =selectedRecord.mainField;
        console.log('Test:',this.SelectedRecName);
        if(this.SelectedRecName){
        this.IsDisabled = false;
        }else{
        this.IsDisabled = true;
        }
         this.isOrphanOrStudent()
    }
    handleReDateChange(event)
    {
      this.RVDate = event.target.value;
       if(this.RVDate == null){
            this.isRenewalDateReq = 'true';
              }else{
                this.isRenewalDateReq = 'false';
              }
    }
     handleSpDateChange(event)
    {
      this.SpDate = event.target.value;
    }
    isOrphanOrStudent()
    {
      debugger;
        if(this.SelectedRecName == 'Student Sponsorship (Complete Course)' ||  
            this.SelectedRecName == 'Orphan Sponsorship' || 
            this.SelectedRecName == 'Orphan Sponsorship (Annual)' || 
            this.SelectedRecName == 'Student Sponsorship' || 
            this.SelectedRecName == 'Student Sponsorship (Annual)' || 
            this.SelectedRecName == 'Engineering Student Sponsorship' || 
            this.SelectedRecName == 'Medical Student Sponsorship' || 
            this.SelectedRecName == 'Medical Student Sponsorship (Annual)' || 
            this.SelectedRecName == 'Engineering Student Sponsorship (Annual)' ) {
            this.isRenewalDateReq = 'true';
            this.showDates = true;
            console.log('test1:', this.showDates);
        } else{
            this.isRenewalDateReq = 'false';
            this.showDates = false;
            console.log('test2:', this.showDates);
        }
        console.log('this.Type : ', this.Type);
       if(this.Type.includes('Single')) {
            this.showSPdate = true;
       }
       else
            this.showSPdate = false;
    }
     handlPlChange1(event)
    {
       debugger;
      let value = event.target.value;
      this.selectedVal = value;
    }
}