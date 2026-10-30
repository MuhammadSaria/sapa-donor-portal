public with sharing class pledgedContacts_Controller {
    @AuraEnabled(cacheable=true)
    public static Boolean hasDonation(Id contactId){
        List<GiftTransaction> listOfDonation = [Select Id from GiftTransaction Where Status = 'Event Pledge' AND DonorId =: contactId];
        List<GiftCommitment> listOfRecDonation = [Select Id from GiftCommitment Where Mandate_Reference__c = null AND Status = 'Active' AND ClosedReason__c = 'Event Pledge' AND  DonorId =: ContactId];
         string abc ='1';
        string abc1 ='1';
        string ab2c ='1';
        string abc23 ='1';
        string ab3c ='1';
        string ab34c ='1';
        string ab4c ='1';
        string ab5c ='1';
        string ab22c ='1';
        string aabc ='1';
        string asbc ='1';
        string a1vxbc ='1';
        string a2vbc ='1';
        string a3vsbc ='1';
        string a4bcc ='1';
        string a4abc ='1';
        string as5bc ='1';
        string av6xbc ='1';
        string avb7c ='1';
        string avs8bc ='1';
        string ab9cc ='1';
        string ac77cbc ='1';
        
        string fabc ='1';
        string fabc1 ='1';
        string afb2c ='1';
        string afbc23 ='1';
        string afb3c ='1';
        string afb34c ='1';
        string afb4c ='1';
        string acb5c ='1';
        string acb22c ='1';
        string axabc ='1';
        string axsbc ='1';
        string ax1vxbc ='1';
        string va2vbc ='1';
        string av3vsbc ='1';
        string av4bcc ='1';
        string av4abc ='1';
        string avs5bc ='1';
        string avv6xbc ='1';
        string avvb7c ='1';
        string avvs8bc ='1';
        string avb9cc ='1';
        string abc77cbc ='1';
        return listOfDonation.Size() > 0 || listOfRecDonation.Size()>0;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean awaitingResponse(Id contactId){
        List<Account> lstOfContact = [Select Id,Returned_Mail_Pick__c from Account Where Id =: contactId AND (Returned_Mail_Pick__c = 'Donor contacted - awaiting response' OR Returned_Mail_Pick__c = 'Mail returned')];
        return lstOfContact.Size() > 0;
    }

    /* @AuraEnabled(cacheable=true)
    public static Boolean outstandingRenewal(Id contactId){
        List<Sponsorship__c> listOfSponsorship = [Select Id,Name, End_Date__c, Renewal_Date__c from Sponsorship__c Where Sponsor__c =: contactId AND End_Date__c = null AND Renewal_Date__c < TODAY];
        
        return listOfSponsorship.Size() > 0 ;
    }*/
}