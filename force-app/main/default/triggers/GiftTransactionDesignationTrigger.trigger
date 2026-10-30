trigger GiftTransactionDesignationTrigger on GiftTransactionDesignation (before insert, before update, after insert, after update ) {
    
   if (!Apex_Triggers__mdt.getInstance('Apex_Trigger').Gift_Transaction_Designation_Trigger__c) {
    return;
}
  
    
    
    
    Set<Id> gtIds = new Set<Id>();
      for (GiftTransactionDesignation gtd : Trigger.new) {
        if (gtd.GiftTransactionId != null){
        gtIds.add(gtd.GiftTransactionId);
        }

        
       
    }
    
  
    
    if(Trigger.isBefore && (Trigger.isInsert || Trigger.isUpdate)){
   
  

        LaunchGoodAllocationHandler.handle(
            Trigger.new, 
            Trigger.oldMap, 
            Trigger.isInsert, 
            Trigger.isUpdate
        );
    }
    
     if(Trigger.isAfter && (Trigger.isInsert || Trigger.isUpdate)){
    if (!gtIds.isEmpty()) GiftTransactionTriggerHandler.sync(gtIds);
}
}