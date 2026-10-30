trigger RecurringDonationStripeTrigger on GiftCommitment (after update) {
    // Pause/resume owns its native parent update and Stripe synchronization.
    // Prevent a competing recurring-terms sync from being enqueued.
    if (StripePauseService.suppressSubscriptionUpdate) return;
    Apex_Triggers__mdt settings = Apex_Triggers__mdt.getInstance('Apex_Trigger');
    if (settings == null || !settings.RecurringDonationStripeTrigger__c) return;

    Set<Id> changedCommitmentIds = new Set<Id>();
    for (GiftCommitment currentCommitment : Trigger.new) {
        GiftCommitment priorCommitment = Trigger.oldMap.get(currentCommitment.Id);
        if (currentCommitment.Status != 'Paused' &&
            currentCommitment.Recurring_Type__c != priorCommitment.Recurring_Type__c) {
            changedCommitmentIds.add(currentCommitment.Id);
        }
    }
    StripeRecurringScheduleCaptureCoalescer.requestCapture(
        StripeRecurringScheduleChangeService.filterVerifiedStripeCommitmentIds(changedCommitmentIds)
    );
}