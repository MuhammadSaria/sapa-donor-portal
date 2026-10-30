/** Synchronously processes a committed durable Stripe request and returns verified status to Flow. */
public without sharing class StripeRecurringScheduleApplyNowAction {
    @InvocableMethod(
        label='Apply Stripe Recurring Change Now'
        description='Calls Stripe synchronously for a committed guided request and returns verified success or immediate failure.'
        category='Stripe Recurring Donations'
        callout=true
    )
    public static List<Response> execute(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null) return responses;
        for (Request request : requests) {
            Response response = new Response();
            responses.add(response);
            if (request == null || request.requestId == null) {
                response.success = false;
                response.status = 'Failed';
                response.errorMessage = 'The durable Stripe change request was not created.';
                continue;
            }
            try {
                StripeRecurringScheduleChangeService.ProcessResult result =
                    StripeRecurringScheduleChangeService.processRequest(request.requestId);
                response.success = result.success;
                response.status = result.status;
                response.billingStoppedAt = result.billingStoppedAt;
                response.scheduledPaymentDate = result.scheduledPaymentDate;
                response.stripeScheduleId = result.stripeScheduleId;
                response.errorMessage = result.errorMessage;
            } catch (Exception error) {
                response.success = false;
                response.status = 'Failed';
                response.errorMessage = sanitize(error.getMessage());
            }
        }
        return responses;
    }

    private static String sanitize(String message) {
        if (String.isBlank(message)) return 'Stripe did not confirm that current billing stopped.';
        return message.replaceAll('(?i)(sk|rk)_(test|live)_[A-Za-z0-9_]+', '[REDACTED]').left(1000);
    }

    public class Request {
        @InvocableVariable(label='Stripe Change Request ID' required=true)
        public Id requestId;
    }

    public class Response {
        @InvocableVariable(label='Success') public Boolean success;
        @InvocableVariable(label='Status') public String status;
        @InvocableVariable(label='Billing Stopped At') public Datetime billingStoppedAt;
        @InvocableVariable(label='Scheduled Payment Date') public Date scheduledPaymentDate;
        @InvocableVariable(label='Stripe Schedule ID') public String stripeScheduleId;
        @InvocableVariable(label='Error Message') public String errorMessage;
    }
}