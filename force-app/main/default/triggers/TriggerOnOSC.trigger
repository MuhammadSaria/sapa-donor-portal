trigger TriggerOnOSC on OutreachSourceCode (after insert, after update, after delete, after undelete) {
    if (!OutreachSourceCodeRollupHandler.isEnabled()) return;
    OutreachSourceCodeRollupHandler.rollupToCampaign(
        Trigger.isDelete ? null : Trigger.new,
        Trigger.isInsert || Trigger.isUndelete ? null : Trigger.old
    );
}