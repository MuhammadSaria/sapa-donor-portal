trigger launchGoodTriggerR on GiftDefaultDesignation (before insert, before update) {
    LaunchGoodAllocationHandler.handle(
        Trigger.new,
        Trigger.oldMap,
        Trigger.isInsert,
        Trigger.isUpdate
    );
}