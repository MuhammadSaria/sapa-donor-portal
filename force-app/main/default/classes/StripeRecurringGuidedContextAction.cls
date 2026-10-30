/** Establishes transaction-scoped context before a guided managed-schedule DML action runs. */
public with sharing class StripeRecurringGuidedContextAction {
    @InvocableMethod(
        label='Prepare Guided Stripe Billing Stop'
        description='Suppresses asynchronous Stripe capture for the guided change so the Flow can call Stripe synchronously.'
        category='Stripe Recurring Donations'
    )
    public static void execute(List<Request> requests) {
        Set<Id> commitmentIds = new Set<Id>();
        if (requests != null) {
            for (Request request : requests) {
                if (request != null && request.giftCommitmentId != null) commitmentIds.add(request.giftCommitmentId);
            }
        }
        StripeRecurringScheduleCaptureCoalescer.beginGuidedSync(commitmentIds);
    }

    public class Request {
        @InvocableVariable(label='Gift Commitment ID' required=true)
        public Id giftCommitmentId;
    }
}