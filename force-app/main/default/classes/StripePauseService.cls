/** Compatibility facade for existing pause callers and trigger suppression. */
public with sharing class StripePauseService {
    public static Boolean suppressSubscriptionUpdate = false;

    @AuraEnabled
    public static Boolean pauseSubscription(String subscriptionId, Id recurringDonationId,
                                            String pauseReason, String resumeDateStr) {
        StripePauseResult result = StripePauseOrchestrator.pause(
            subscriptionId, recurringDonationId, pauseReason, resumeDateStr);
        return result.stripeConfirmed &&
            (result.salesforceState == 'Paused' || result.salesforceState == 'Scheduled');
    }

    @AuraEnabled
    public static Boolean resumeSubscription(String subscriptionId, Id recurringDonationId) {
        StripePauseResult result = StripePauseOrchestrator.resume(
            subscriptionId, recurringDonationId);
        return result.stripeConfirmed && result.salesforceState == 'Active';
    }
}