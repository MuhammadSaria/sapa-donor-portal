trigger GiftCommitmentScheduleTrigger on GiftCommitmentSchedule (after insert, after update) {
    Apex_Triggers__mdt settings = Apex_Triggers__mdt.getInstance('Apex_Trigger');
    if (settings == null || !settings.Gift_Commitment_Schedule__c) return;

    // Amount amendments only touch Salesforce designation data (no Stripe calls),
    // so they are synced even while pause/resume suppresses the Stripe sync below.
    if (!GiftCommitmentScheduleTriggerHandler.bypassTrigger) {
        RecurringDonationAmendmentService.handle(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
    }

    // Pause/resume owns its native schedule DML and Stripe synchronization.
    // Prevent that workflow from enqueuing an unrelated terms-sync request.
    if (StripePauseService.suppressSubscriptionUpdate) return;

    // Preserve the existing OutreachSourceCode mapping while keeping the
    // parent recurring type under Flow control. The handler no longer derives
    // Open/Fixed from EndDate, and its recursion guard prevents a second pass.
    if (!GiftCommitmentScheduleTriggerHandler.bypassTrigger) {
        GiftCommitmentScheduleTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
    }

    Set<Id> stripeSyncGiftCommitmentIds = new Set<Id>();
    for (GiftCommitmentSchedule schedule : Trigger.new) {
        GiftCommitmentSchedule oldSchedule = Trigger.isUpdate ? Trigger.oldMap.get(schedule.Id) : null;
        Boolean stripeFieldChanged = Trigger.isInsert ||
            schedule.TransactionAmount != oldSchedule.TransactionAmount ||
            schedule.TransactionPeriod != oldSchedule.TransactionPeriod ||
            schedule.TransactionInterval != oldSchedule.TransactionInterval ||
            schedule.StartDate != oldSchedule.StartDate ||
            schedule.EndDate != oldSchedule.EndDate ||
            schedule.Stripe_Change_Effective_Date__c != oldSchedule.Stripe_Change_Effective_Date__c ||
            schedule.Number_of_Planned_Installments__c != oldSchedule.Number_of_Planned_Installments__c ||
            schedule.Stop_Stripe_Billing_Immediately__c != oldSchedule.Stop_Stripe_Billing_Immediately__c;
        if (schedule.GiftCommitmentId != null && stripeFieldChanged) {
            stripeSyncGiftCommitmentIds.add(schedule.GiftCommitmentId);
        }
    }
    StripeRecurringScheduleCaptureCoalescer.requestCapture(
        StripeRecurringScheduleChangeService.filterVerifiedStripeCommitmentIds(stripeSyncGiftCommitmentIds)
    );
}