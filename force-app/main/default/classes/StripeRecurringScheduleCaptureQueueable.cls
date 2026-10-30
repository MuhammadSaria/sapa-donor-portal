public without sharing class StripeRecurringScheduleCaptureQueueable implements Queueable {
    public static Boolean captureDisabledForTest = false;
    private Set<Id> giftCommitmentIds;

    public StripeRecurringScheduleCaptureQueueable(Set<Id> giftCommitmentIds) {
        this.giftCommitmentIds = giftCommitmentIds;
    }

    public void execute(QueueableContext context) {
        if (giftCommitmentIds == null || giftCommitmentIds.isEmpty()) return;
        StripeRecurringScheduleChangeService.captureRequestsForGiftCommitments(giftCommitmentIds);
        if (!Test.isRunningTest()) {
            System.attachFinalizer(new StripeRecurringScheduleFinalizer(giftCommitmentIds));
        }
    }
}