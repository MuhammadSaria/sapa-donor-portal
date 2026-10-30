trigger GiftTransactionTrigger on GiftTransaction (after insert, after update) {
    
    if (!Apex_Triggers__mdt.getInstance('Apex_Trigger').Gift_Transaction__c) {
    return;
}
    
    System.debug('GiftTransaction Trigger is Running');
    
    Set<Id> ids = new Set<Id>();
    for (GiftTransaction gt : Trigger.new) {
        if (gt.Id != null && gt.FUp_Donation_ID__c != null) ids.add(gt.Id);
    }
    if (!ids.isEmpty()) GiftTransactionTriggerHandler.sync(ids);
}