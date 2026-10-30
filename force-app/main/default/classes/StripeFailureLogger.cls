/**
 * Collects Stripe processing and sync failures during a transaction and publishes them as
 * Stripe_Failure__e events. The event is Publish Immediately, so a failure is still recorded when
 * the failing transaction rolls back. StripeFailureEventHandler turns events into
 * Stripe_Failure_Log__c records, and the Stripe_Failure_Log_Notify flow alerts Stripe Support.
 *
 * record() only buffers (no DML), so it is safe before callouts. Call flush() once the entry
 * point has finished its callouts, or right after a DML statement (callouts are blocked from
 * then on anyway). The logger never throws into the calling business code.
 *
 * Usage:
 *   StripeFailureLogger.record(StripeFailureLogger.failure(
 *           StripeFailureLogger.SOURCE_WEBHOOK, StripeFailureLogger.CODE_PAYMENT_INSERT_FAILED,
 *           'Payment__c insert failed')
 *       .withException(e).operation('StripeSubscriptionRestController.processInvoice')
 *       .commitment(rd.Id).donation(donation.Id));
 *   StripeFailureLogger.flush();
 */
public inherited sharing class StripeFailureLogger {

    // Failure sources (Stripe_Failure_Log__c.Failure_Source__c).
    public static final String SOURCE_WEBHOOK = 'Stripe Webhook';
    public static final String SOURCE_WEBHOOK_SIGNATURE = 'Webhook Signature';
    public static final String SOURCE_API_CALLOUT = 'Stripe API Callout';
    public static final String SOURCE_SALESFORCE = 'Salesforce Processing';
    public static final String SOURCE_RECURRING_SYNC = 'Recurring Sync';
    public static final String SOURCE_PAUSE_RESUME = 'Pause-Resume';
    public static final String SOURCE_REFUND_VOID = 'Refund-Void';
    public static final String SOURCE_ASYNC_JOB = 'Async Job';

    // Reason codes (Stripe_Failure_Log__c.Reason_Code__c and Stripe_Failure_Setting__mdt records).
    public static final String CODE_WEBHOOK_SIGNATURE_INVALID = 'WEBHOOK_SIGNATURE_INVALID';
    public static final String CODE_WEBHOOK_UNHANDLED_EXCEPTION = 'WEBHOOK_UNHANDLED_EXCEPTION';
    public static final String CODE_INVOICE_RD_NOT_FOUND = 'INVOICE_RD_NOT_FOUND';
    public static final String CODE_INVOICE_SUBSCRIPTION_MISMATCH = 'INVOICE_SUBSCRIPTION_MISMATCH';
    public static final String CODE_PAID_NOT_RECORDED = 'PAID_NOT_RECORDED';
    public static final String CODE_PAYMENT_INSERT_FAILED = 'PAYMENT_INSERT_FAILED';
    public static final String CODE_RD_UPDATE_FAILED = 'RD_UPDATE_FAILED';
    public static final String CODE_RECURRING_SYNC_FAILED = 'RECURRING_SYNC_FAILED';
    public static final String CODE_PAUSE_RESUME_FAILED = 'PAUSE_RESUME_FAILED';
    public static final String CODE_REFUND_FAILED = 'REFUND_FAILED';
    public static final String CODE_VOID_FAILED = 'VOID_FAILED';
    public static final String CODE_STRIPE_API_ERROR = 'STRIPE_API_ERROR';
    public static final String CODE_ASYNC_JOB_FAILED = 'ASYNC_JOB_FAILED';

    private static final Integer TEXT_LIMIT = 255;
    private static final Integer LONG_TEXT_LIMIT = 32000;

    private static final List<Stripe_Failure__e> buffer = new List<Stripe_Failure__e>();

    public static Failure failure(String source, String reasonCode, String reason) {
        return new Failure(source, reasonCode, reason);
    }

    public static void record(Failure failure) {
        try {
            if (failure == null) return;
            Stripe_Failure__e event = failure.toEvent();
            // Anyone can POST to the public webhook, so bad signatures are logged at most once per day.
            if (failure.reasonCode == CODE_WEBHOOK_SIGNATURE_INVALID
                && new SignatureThrottle().alreadyLogged(event.Dedupe_Key__c)) {
                return;
            }
            buffer.add(event);
        } catch (Exception loggingError) {
            System.debug(LoggingLevel.ERROR, 'StripeFailureLogger could not record a failure: ' + loggingError.getMessage());
        }
    }

    public static void flush() {
        if (buffer.isEmpty()) return;
        List<Stripe_Failure__e> events = buffer.clone();
        buffer.clear();
        try {
            List<Database.SaveResult> results = EventBus.publish(events);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    System.debug(LoggingLevel.ERROR, 'StripeFailureLogger could not publish ' + events[i].Reason_Code__c
                        + ': ' + results[i].getErrors());
                }
            }
        } catch (Exception publishError) {
            System.debug(LoggingLevel.ERROR, 'StripeFailureLogger could not publish failures: ' + publishError.getMessage());
        }
    }

    @TestVisible
    private static Integer pendingCount() {
        return buffer.size();
    }

    // Strips anything that looks like a secret, card number or email address, then truncates.
    // Raw request/response bodies are never passed in; this guards messages built from them.
    @TestVisible
    private static String sanitize(String value, Integer maxLength) {
        if (String.isBlank(value)) return value;
        // Truncate first so the patterns never scan unbounded input.
        String cleaned = value.left(maxLength + 1000)
            .replaceAll('(sk|rk|pk)_(live|test)_[A-Za-z0-9]+', '[redacted-key]')
            .replaceAll('whsec_[A-Za-z0-9]+', '[redacted-secret]')
            .replaceAll('(?i)(bearer|basic)\\s+[A-Za-z0-9._~+/=-]+', '$1 [redacted]')
            .replaceAll('(?i)authorization\\s*[:=]\\s*\\S+', 'Authorization: [redacted]')
            .replaceAll('\\b\\d(?:[ -]?\\d){12,18}\\b', '[redacted-number]')
            .replaceAll('[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}', '[redacted-email]');
        return cleaned.length() > maxLength ? cleaned.left(maxLength) : cleaned;
    }

    /** One failure, built fluently. Only ids, codes and sanitized messages are kept. */
    public class Failure {
        private String source;
        private String reasonCode;
        private String reason;
        private String errorMessage;
        private String stackTrace;
        private String operationName;
        private Integer httpStatus;
        private String stripeEventId;
        private String stripeEventType;
        private String stripeObjectId;
        private String stripeSubscriptionId;
        private String stripeCustomerId;
        private Decimal amount;
        private Id commitmentId;
        private Id donationId;
        private Id paymentId;
        private Id subscriptionChangeId;

        private Failure(String source, String reasonCode, String reason) {
            this.source = source;
            this.reasonCode = reasonCode;
            this.reason = reason;
        }

        public Failure withError(String message) {
            this.errorMessage = message;
            return this;
        }

        public Failure withException(Exception error) {
            if (error != null) {
                this.errorMessage = error.getTypeName() + ': ' + error.getMessage();
                this.stackTrace = error.getStackTraceString();
            }
            return this;
        }

        public Failure operation(String operationName) {
            this.operationName = operationName;
            return this;
        }

        public Failure httpStatus(Integer httpStatus) {
            this.httpStatus = httpStatus;
            return this;
        }

        public Failure stripeEvent(String eventId, String eventType) {
            this.stripeEventId = eventId;
            this.stripeEventType = eventType;
            return this;
        }

        public Failure stripeObject(String objectId) {
            this.stripeObjectId = objectId;
            return this;
        }

        public Failure subscription(String subscriptionId) {
            this.stripeSubscriptionId = subscriptionId;
            return this;
        }

        public Failure customer(String customerId) {
            this.stripeCustomerId = customerId;
            return this;
        }

        public Failure amount(Decimal amount) {
            this.amount = amount;
            return this;
        }

        public Failure commitment(Id commitmentId) {
            this.commitmentId = commitmentId;
            return this;
        }

        public Failure donation(Id donationId) {
            this.donationId = donationId;
            return this;
        }

        public Failure payment(Id paymentId) {
            this.paymentId = paymentId;
            return this;
        }

        public Failure subscriptionChange(Id subscriptionChangeId) {
            this.subscriptionChangeId = subscriptionChangeId;
            return this;
        }

        private Stripe_Failure__e toEvent() {
            return new Stripe_Failure__e(
                Failure_Source__c = source,
                Reason_Code__c = reasonCode,
                Failure_Reason__c = sanitize(reason, TEXT_LIMIT),
                Error_Message__c = sanitize(errorMessage, LONG_TEXT_LIMIT),
                Stack_Trace__c = sanitize(stackTrace, LONG_TEXT_LIMIT),
                Operation__c = sanitize(operationName, TEXT_LIMIT),
                HTTP_Status_Code__c = httpStatus,
                Stripe_Event_Id__c = sanitize(stripeEventId, TEXT_LIMIT),
                Stripe_Event_Type__c = sanitize(stripeEventType, TEXT_LIMIT),
                Stripe_Object_Id__c = sanitize(stripeObjectId, TEXT_LIMIT),
                Stripe_Subscription_Id__c = sanitize(stripeSubscriptionId, TEXT_LIMIT),
                Stripe_Customer_Id__c = sanitize(stripeCustomerId, TEXT_LIMIT),
                Amount__c = amount,
                Gift_Commitment_Id__c = commitmentId,
                Gift_Transaction_Id__c = donationId,
                Payment_Id__c = paymentId,
                Subscription_Change_Id__c = subscriptionChangeId,
                Dedupe_Key__c = dedupeKey(),
                Occurred_At__c = System.now()
            );
        }

        // Same kind of failure (source, code, operation and reason) on the same Stripe object or
        // record => same key, so repeats such as Stripe webhook retries update one log, while a
        // different failure on the same record gets its own log and alert. Without ids the key is
        // bucketed by day, so unrelated failures do not merge forever. Hashed, so no raw input is
        // stored in the key.
        private String dedupeKey() {
            String stripeId = String.isNotBlank(stripeObjectId) ? stripeObjectId
                : String.isNotBlank(stripeEventId) ? stripeEventId : stripeSubscriptionId;
            Id recordId = subscriptionChangeId != null ? subscriptionChangeId
                : donationId != null ? donationId
                : paymentId != null ? paymentId : commitmentId;
            List<String> parts = new List<String>{ source, reasonCode, operationName, reason };
            if (String.isBlank(stripeId) && recordId == null) {
                parts.add(System.now().formatGmt('yyyy-MM-dd'));
            } else {
                parts.add(stripeId);
                parts.add(recordId);
            }
            return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(String.join(parts, '|'))));
        }
    }

    // The webhook runs as the site guest user, who cannot see logs. Without sharing so the
    // throttle can check whether today's signature-failure log already exists; it reads
    // nothing but that one key.
    private without sharing class SignatureThrottle {
        Boolean alreadyLogged(String dedupeKey) {
            return [SELECT COUNT() FROM Stripe_Failure_Log__c WHERE Dedupe_Key__c = :dedupeKey] > 0;
        }
    }
}