public without sharing class StripeRecurringScheduleFinalizer implements Finalizer, Database.AllowsCallouts {
    private Set<Id> giftCommitmentIds;

    public StripeRecurringScheduleFinalizer(Set<Id> giftCommitmentIds) {
        this.giftCommitmentIds = giftCommitmentIds;
    }

    public void execute(FinalizerContext context) {
        if (giftCommitmentIds == null || giftCommitmentIds.isEmpty()) return;
        if (context != null && context.getResult() == ParentJobResult.UNHANDLED_EXCEPTION) {
            // One log per failed job; the affected recurring donations are listed in the error.
            List<Id> affected = new List<Id>(giftCommitmentIds);
            Exception jobError = context.getException();
            StripeFailureLogger.record(StripeFailureLogger.failure(
                    StripeFailureLogger.SOURCE_ASYNC_JOB, StripeFailureLogger.CODE_ASYNC_JOB_FAILED,
                    'Stripe recurring change capture job failed with an unhandled error')
                .withError((jobError == null ? '' : jobError.getTypeName() + ': ' + jobError.getMessage() + '\n')
                    + 'Affected recurring donations (' + affected.size() + '): ' + String.join(affected, ', '))
                .operation('StripeRecurringScheduleCaptureQueueable')
                .commitment(affected[0]));
        }
        try {
            for (Stripe_Subscription_Change__c requestRecord : [
                SELECT Id
                FROM Stripe_Subscription_Change__c
                WHERE Gift_Commitment__c IN :giftCommitmentIds
                  AND Status__c = 'Pending'
                ORDER BY CreatedDate
            ]) {
                StripeRecurringScheduleChangeService.processRequest(requestRecord.Id);
            }
        } finally {
            // After the Stripe callouts above, so publishing cannot block them.
            StripeFailureLogger.flush();
        }
    }
}