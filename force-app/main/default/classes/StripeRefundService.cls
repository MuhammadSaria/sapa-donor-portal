public without sharing class StripeRefundService {
    private static final String STRIPE_SECRET_KEY = System.Label.Stripe_Secret;
    private static final String STRIPE_API_BASE = 'https://api.stripe.com/v1';

    private static final String AMOUNT_MODE_EXPLICIT_MINOR_UNITS = 'EXPLICIT_MINOR_UNITS';
    private static final String AMOUNT_MODE_FULL_STRIPE_REFUND = 'FULL_STRIPE_REFUND';
    private static final String SOURCE_SALESFORCE = 'SALESFORCE';
    private static final String SOURCE_FUNDRAISE_UP = 'FUNDRAISE_UP';

    /**
     * Refund a Stripe subscription's latest invoice.
     */
    @AuraEnabled
    public static String refundSubscription(String subscriptionId, Integer amount) {
        if (String.isBlank(subscriptionId)) {
            throw new AuraHandledException('Subscription ID is required.');
        }

        System.debug('refundSubscription START for Subscription ID: ' + subscriptionId);

        Map<String,Object> subscriptionData = getStripeData('/subscriptions/' + subscriptionId + '?expand[]=latest_invoice.payment_intent');
        System.debug('Subscription data fetched: ' + subscriptionData);

        Map<String,Object> latestInvoice = (Map<String,Object>) subscriptionData.get('latest_invoice');
        System.debug('Latest Invoice: ' + latestInvoice);
        if (latestInvoice == null) {
            throw new AuraHandledException('No latest invoice found for subscription.');
        }

        Map<String,Object> paymentIntent = (Map<String,Object>) latestInvoice.get('payment_intent');
        System.debug('PaymentIntent fetched: ' + paymentIntent);
        if (paymentIntent == null || !paymentIntent.containsKey('id')) {
            throw new AuraHandledException('No payment intent found for the subscription invoice.');
        }

        String paymentIntentId = (String) paymentIntent.get('id');
        System.debug('Found PaymentIntent ID: ' + paymentIntentId);

        return refundPaymentIntent(paymentIntentId, amount, 'Donation');
    }

    /**
     * Refund a Stripe PaymentIntent or Charge directly.
     */
    @AuraEnabled
    public static String refundPaymentIntent(String paymentIntentId, Integer amount, String Rtype) {
        if (String.isBlank(paymentIntentId)) {
            throw new AuraHandledException('PaymentIntent ID is required.');
        }

        System.debug('refundPaymentIntent START for PaymentIntent ID: ' + paymentIntentId);

        Http http = new Http();
        HttpRequest request = new HttpRequest();
        request.setEndpoint(STRIPE_API_BASE + '/refunds');
        request.setMethod('POST');
        request.setHeader('Authorization', 'Bearer ' + STRIPE_SECRET_KEY);
        request.setHeader('Content-Type', 'application/x-www-form-urlencoded');

        String body;
        if (Rtype == 'Donation') {
            body = 'payment_intent=' + EncodingUtil.urlEncode(paymentIntentId, 'UTF-8');
        } else {
            body = 'charge=' + EncodingUtil.urlEncode(paymentIntentId, 'UTF-8');
        }

        if (amount != null) {
            body += '&amount=' + amount;
        }

        request.setBody(body);
        System.debug('Refund request body: ' + body);

        try {
            HttpResponse response = http.send(request);
            System.debug('HTTP Response Code: ' + response.getStatusCode());
            System.debug('HTTP Response Body: ' + response.getBody());

            if (response.getStatusCode() == 200) {
                System.debug('Refund succeeded for PaymentIntent ID: ' + paymentIntentId);
                return response.getBody();
            } else {
                System.debug('Stripe refund error: ' + response.getBody());
                String stripeMessage = parseStripeErrorMessage(response.getBody(), 'Unable to process the refund with Stripe.');
                logStripeFailure(StripeFailureLogger.CODE_REFUND_FAILED, 'Stripe rejected the refund', 'refundPaymentIntent',
                    paymentIntentId, response.getStatusCode(), stripeMessage);
                throw buildHandledException('Refund failed: ' + stripeMessage);
            }
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            System.debug('Exception in refundPaymentIntent: ' + e.getMessage());
            logStripeFailure(StripeFailureLogger.CODE_REFUND_FAILED, 'Refund request to Stripe could not be completed',
                'refundPaymentIntent', paymentIntentId, null, e.getMessage());
            throw new AuraHandledException('Error calling Stripe Refund API: ' + e.getMessage());
        }
    }

    // Published before the AuraHandledException is thrown, so it survives the rollback.
    private static void logStripeFailure(String reasonCode, String reason, String methodName,
                                         String stripeIdOrPath, Integer httpStatus, String message) {
        StripeFailureLogger.record(StripeFailureLogger.failure(
                StripeFailureLogger.SOURCE_REFUND_VOID, reasonCode, reason)
            .withError(message)
            .operation('StripeRefundService.' + methodName)
            .stripeObject(stripeIdFrom(stripeIdOrPath))
            .httpStatus(httpStatus));
        StripeFailureLogger.flush();
    }

    // The ids come from the refund component, so only a well-formed Stripe id is logged.
    private static String stripeIdFrom(String idOrPath) {
        if (String.isBlank(idOrPath)) return null;
        String candidate = idOrPath.substringBefore('?');
        if (candidate.contains('/')) candidate = candidate.substringAfterLast('/');
        return Pattern.matches('(pi|ch|sub|in|re)_[A-Za-z0-9]+', candidate) ? candidate : null;
    }

    private static Map<String,Object> getStripeData(String endpointPath) {
        System.debug('GET Stripe data from endpoint: ' + endpointPath);

        Http http = new Http();
        HttpRequest request = new HttpRequest();
        request.setEndpoint(STRIPE_API_BASE + endpointPath);
        request.setMethod('GET');
        request.setHeader('Authorization', 'Bearer ' + STRIPE_SECRET_KEY);
        request.setHeader('Content-Type', 'application/x-www-form-urlencoded');

        try {
            HttpResponse response = http.send(request);
            System.debug('GET Response Code: ' + response.getStatusCode());
            System.debug('GET Response Body: ' + response.getBody());

            if (response.getStatusCode() == 200) {
                return (Map<String,Object>) JSON.deserializeUntyped(response.getBody());
            } else {
                System.debug('Stripe GET request failed: ' + response.getBody());
                String stripeMessage = parseStripeErrorMessage(response.getBody(), 'Unable to retrieve subscription details from Stripe.');
                logStripeFailure(StripeFailureLogger.CODE_STRIPE_API_ERROR, 'Stripe lookup for a refund failed', 'getStripeData',
                    endpointPath, response.getStatusCode(), stripeMessage);
                throw buildHandledException('Stripe request failed: ' + stripeMessage);
            }
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            System.debug('Exception in getStripeData: ' + e.getMessage());
            logStripeFailure(StripeFailureLogger.CODE_STRIPE_API_ERROR, 'Stripe lookup for a refund could not be completed',
                'getStripeData', endpointPath, null, e.getMessage());
            throw new AuraHandledException('Error calling Stripe API: ' + e.getMessage());
        }
    }

    private static AuraHandledException buildHandledException(String message) {
        AuraHandledException exceptionToThrow = new AuraHandledException(message);
        exceptionToThrow.setMessage(message);
        return exceptionToThrow;
    }

    private static String parseStripeErrorMessage(String responseBody, String fallbackMessage) {
        if (String.isBlank(responseBody)) {
            return fallbackMessage;
        }

        try {
            Object parsedBody = JSON.deserializeUntyped(responseBody);
            if (parsedBody instanceof Map<String, Object>) {
                Map<String, Object> body = (Map<String, Object>) parsedBody;
                Object stripeError = body.get('error');

                if (stripeError instanceof Map<String, Object>) {
                    Object stripeMessage = ((Map<String, Object>) stripeError).get('message');
                    if (stripeMessage instanceof String && !String.isBlank((String) stripeMessage)) {
                        return (String) stripeMessage;
                    }
                }

                Object message = body.get('message');
                if (message instanceof String && !String.isBlank((String) message)) {
                    return (String) message;
                }
            }
        } catch (Exception e) {
            System.debug('Unable to parse Stripe error response: ' + e.getMessage());
        }

        return fallbackMessage;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean isRefunded(Id recordId) {
        List<GiftTransaction> opp = [SELECT Refunded__c FROM GiftTransaction WHERE Id = :recordId LIMIT 1];
        if (!opp.isEmpty() && opp[0].Refunded__c) {
            return true;
        }

        List<GiftCommitment> rd = [SELECT Refunded__c FROM GiftCommitment WHERE Id = :recordId LIMIT 1];
        if (!rd.isEmpty() && rd[0].Refunded__c) {
            return true;
        }

        return false;
    }

    /**
     * Get Payment ID and refund mode from a GiftTransaction or GiftCommitment record.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getPaymentIdAndType(Id recordId) {
        System.debug('getPaymentIdAndType START for Record ID: ' + recordId);

        Map<String, String> result = new Map<String, String>();

        List<GiftTransaction> donations = [
            SELECT Id,
                   Charge_Id__c,
                   CurrencyIsoCode,
                   FUp_Currency_ISO_Code__c,
                   FUp_Donation_Amount__c,
                   FundraiseUpId__c,
                   GiftCommitmentId,
                   OriginalAmount,
                   Transaction_Id__c
            FROM GiftTransaction
            WHERE Id = :recordId
            LIMIT 1
        ];
        System.debug('Donation records fetched: ' + donations);

        if (!donations.isEmpty()) {
            GiftTransaction donation = donations[0];
            String currencyIsoCode = getGiftTransactionCurrency(donation);

            if (donation.Transaction_Id__c != null && donation.FundraiseUpId__c == null && donation.GiftCommitmentId == null) {
                System.debug('Found Transaction_Id__c: ' + donation.Transaction_Id__c);
                putExplicitRefundResult(
                    result,
                    donation.Transaction_Id__c,
                    'Donation',
                    donation.OriginalAmount,
                    currencyIsoCode,
                    SOURCE_SALESFORCE
                );
                return result;
            } else if (donation.Charge_Id__c != null && donation.FundraiseUpId__c != null) {
                System.debug('Found Fundraise Up Charge_Id__c: ' + donation.Charge_Id__c);
                putFullStripeRefundResult(
                    result,
                    donation.Charge_Id__c,
                    'RDonation',
                    currencyIsoCode,
                    SOURCE_FUNDRAISE_UP,
                    'Full original Stripe charge'
                );
                return result;
            } else if (donation.Charge_Id__c != null && donation.GiftCommitmentId != null) {
                System.debug('Found recurring Charge_Id__c: ' + donation.Charge_Id__c);
                putFullStripeRefundResult(
                    result,
                    donation.Charge_Id__c,
                    'RDonation',
                    currencyIsoCode,
                    donation.FundraiseUpId__c != null ? SOURCE_FUNDRAISE_UP : SOURCE_SALESFORCE,
                    'Full original Stripe charge'
                );
                return result;
            }
        }

        List<GiftCommitment> rds = [
            SELECT Subscription_Id__c,
                   Id,
                   Amount__c,
                   CurrencyIsoCode,
                   FundraiseUpId__c,
                   (SELECT TransactionPeriod,
                           Number_of_Planned_Installments__c,
                           TransactionAmount,
                           PaymentMethod
                    FROM GiftCommitmentSchedules
                    LIMIT 1)
            FROM GiftCommitment
            WHERE Id = :recordId
            LIMIT 1
        ];

        System.debug('Recurring Donation records fetched: ' + rds);

        if (!rds.isEmpty()) {
            GiftCommitment parentRecord = rds[0];

            if (parentRecord.Subscription_Id__c != null) {
                System.debug('Found Subscription_Id__c: ' + parentRecord.Subscription_Id__c);

                putFullStripeRefundResult(
                    result,
                    parentRecord.Subscription_Id__c,
                    'RecurringDonation',
                    parentRecord.CurrencyIsoCode,
                    parentRecord.FundraiseUpId__c != null ? SOURCE_FUNDRAISE_UP : SOURCE_SALESFORCE,
                    'Full latest invoice charge'
                );
                return result;
            }
        }

        System.debug('No Transaction or Subscription ID found for record: ' + recordId);
        throw new AuraHandledException('No Transaction or Subscription ID found for this record.');
    }

    private static void putExplicitRefundResult(
        Map<String, String> result,
        String paymentId,
        String recordType,
        Decimal amount,
        String currencyIsoCode,
        String source
    ) {
        result.put('paymentId', paymentId);
        result.put('recordType', recordType);
        result.put('amountMode', AMOUNT_MODE_EXPLICIT_MINOR_UNITS);
        result.put('source', source);
        result.put('currencyIsoCode', currencyIsoCode);
        result.put('amount', amount != null ? String.valueOf((amount * 100).setScale(0)).split('\\.')[0] : null);
        result.put('displayAmount', amount != null ? formatDisplayAmount(amount, currencyIsoCode) : null);
    }

    private static void putFullStripeRefundResult(
        Map<String, String> result,
        String paymentId,
        String recordType,
        String currencyIsoCode,
        String source,
        String displayAmount
    ) {
        result.put('paymentId', paymentId);
        result.put('recordType', recordType);
        result.put('amountMode', AMOUNT_MODE_FULL_STRIPE_REFUND);
        result.put('source', source);
        result.put('currencyIsoCode', currencyIsoCode);
        result.put('amount', null);
        result.put('displayAmount', displayAmount);
    }

    private static String getGiftTransactionCurrency(GiftTransaction donation) {
        if (!String.isBlank(donation.FUp_Currency_ISO_Code__c)) {
            return donation.FUp_Currency_ISO_Code__c;
        }
        return donation.CurrencyIsoCode;
    }

    private static String formatDisplayAmount(Decimal amount, String currencyIsoCode) {
        String formattedAmount = String.valueOf(amount.setScale(2));
        return String.isBlank(currencyIsoCode) ? formattedAmount : currencyIsoCode + ' ' + formattedAmount;
    }
}