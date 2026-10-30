/**
 * Permission-controlled retry entry point for failed durable Stripe changes.
 */
public with sharing class StripeRecurringScheduleRetryAction {
    @TestVisible private static Boolean permissionBypass = false;

    /** Queues a safe retry after resetting the failed request to Pending. */
    @AuraEnabled
    public static String retry(Id requestId) {
        if (!permissionBypass && !FeatureManagement.checkPermission('Retry_Stripe_Recurring_Schedule_Change')) {
            throw new AuraHandledException('You do not have permission to retry Stripe recurring donation changes.');
        }
        if (requestId == null) throw new AuraHandledException('Select a Stripe subscription change to retry.');
        try {
            StripeRecurringScheduleChangeService.prepareRetry(requestId);
            Id jobId = System.enqueueJob(new StripeRecurringScheduleSyncQueueable(new List<Id>{ requestId }));
            return String.valueOf(jobId);
        } catch (Exception error) {
            throw new AuraHandledException(sanitize(error.getMessage()));
        }
    }

    private static String sanitize(String message) {
        if (String.isBlank(message)) return 'Stripe retry could not be queued.';
        return message.replaceAll('(?i)(sk|rk)_(test|live)_[A-Za-z0-9_]+', '[REDACTED]').left(255);
    }
}