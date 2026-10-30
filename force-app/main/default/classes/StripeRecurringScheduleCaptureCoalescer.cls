/**
 * Transaction-scoped coalescer shared by the parent and schedule triggers.
 */
public with sharing class StripeRecurringScheduleCaptureCoalescer {
    private static Set<Id> capturedCommitmentIds = new Set<Id>();
    private static Boolean captureEnqueued = false;
    private static Set<Id> guidedSynchronousCommitmentIds = new Set<Id>();
    @TestVisible private static Integer enqueueCount = 0;

    /** Enqueues at most one capture for simultaneous changes to the same recurring donations. */
    public static void requestCapture(Set<Id> giftCommitmentIds) {
        if (giftCommitmentIds == null || giftCommitmentIds.isEmpty()) return;
        Set<Id> newIds = giftCommitmentIds.clone();
        newIds.removeAll(guidedSynchronousCommitmentIds);
        newIds.removeAll(capturedCommitmentIds);
        if (newIds.isEmpty()) return;
        capturedCommitmentIds.addAll(newIds);
        if (captureEnqueued) return;

        captureEnqueued = true;
        enqueueCount++;
        if (!StripeRecurringScheduleCaptureQueueable.captureDisabledForTest) {
            System.enqueueJob(new StripeRecurringScheduleCaptureQueueable(capturedCommitmentIds));
        }
    }

    /** Marks guided Flow changes so their triggers do not race the synchronous Stripe action. */
    public static void beginGuidedSync(Set<Id> giftCommitmentIds) {
        if (giftCommitmentIds != null) guidedSynchronousCommitmentIds.addAll(giftCommitmentIds);
    }

    @TestVisible
    static void resetForTest() {
        capturedCommitmentIds.clear();
        captureEnqueued = false;
        enqueueCount = 0;
        guidedSynchronousCommitmentIds.clear();
    }

    @TestVisible
    static Integer getEnqueueCountForTest() {
        return enqueueCount;
    }
}