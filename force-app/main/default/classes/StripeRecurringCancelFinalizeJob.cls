/**
 * Finalizes cancellation state after Stripe applies a payment-gated subscription update.
 */
public without sharing class StripeRecurringCancelFinalizeJob implements Queueable, Database.AllowsCallouts {
    private Id requestId;

    /**
     * @param requestId durable Stripe subscription change request
     */
    public StripeRecurringCancelFinalizeJob(Id requestId) {
        this.requestId = requestId;
    }

    /**
     * Verifies the active Stripe Price and completes the Open or Fixed cancellation state.
     * @param context queueable execution context
     */
    public void execute(QueueableContext context) {
        if (requestId == null) return;
        StripeRecurringScheduleChangeService.finalizeAppliedPendingRequest(requestId);
    }
}