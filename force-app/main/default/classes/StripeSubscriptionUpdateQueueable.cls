public class StripeSubscriptionUpdateQueueable implements Queueable, Database.AllowsCallouts {
    private Id recDonId;
    private Date oldNextPaymentDate;
    private Date oldLastPaymentDate;
    private String oldRecurringType;
    
    /**
     * Constructor to initialize the queueable with recurring donation update parameters
     * @param recDonId The ID of the recurring donation record
     * @param oldNextPaymentDate The previous next payment date value
     * @param oldLastPaymentDate The previous last payment date value
     * @param oldRecurringType The previous recurring type value
     */
    public StripeSubscriptionUpdateQueueable(
        Id recDonId, 
        Date oldNextPaymentDate, 
        Date oldLastPaymentDate, 
        String oldRecurringType
    ) {
        this.recDonId = recDonId;
        this.oldNextPaymentDate = oldNextPaymentDate;
        this.oldLastPaymentDate = oldLastPaymentDate;
        this.oldRecurringType = oldRecurringType;
    }
    
    /**
     * Execute method called by the queueable framework
     * Delegates to the synchronous version of the Stripe update method
     */
    public void execute(QueueableContext context) {
        // Catches what the try/catch below cannot, such as limit exceptions.
        System.attachFinalizer(new StripeFailureFinalizer('StripeSubscriptionUpdateQueueable.execute', recDonId));
        try {
            StripeCustomerService.updateStripeSubscription(
                recDonId,
                oldNextPaymentDate,
                oldLastPaymentDate,
                oldRecurringType
            );
        } catch (Exception e) {
            System.debug('❌ Error updating Stripe subscription: ' + e.getMessage());
            // Log the error but don't throw to prevent queueable job failure
            System.debug('Stack Trace: ' + e.getStackTraceString());
            StripeFailureLogger.record(StripeFailureLogger.failure(
                    StripeFailureLogger.SOURCE_API_CALLOUT, StripeFailureLogger.CODE_STRIPE_API_ERROR,
                    'Stripe subscription update failed')
                .withException(e)
                .operation('StripeSubscriptionUpdateQueueable.execute')
                .commitment(recDonId));
            StripeFailureLogger.flush();
        }
    }
}