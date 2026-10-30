@RestResource(urlMapping='/stripe/subscription')
global without sharing class StripeSubscriptionRestController {

    // The Stripe event being processed, so failures raised deeper in the handler can name it.
    private static String currentEventId;
    private static String currentEventType;
    private static final String OPERATION = 'StripeSubscriptionRestController.';

    @HttpPost
    global static void handleWebhook() {
        System.debug('=== STRIPE WEBHOOK RECEIVED ===');
        System.debug('Running as: ' + UserInfo.getUserName());
        
        RestRequest req = RestContext.request;
        String payload = req.requestBody.toString();
        String sigHeader = getHeaderValueIgnoreCase(req, 'Stripe-Signature');
        
        // Verify webhook signature (critical for security)
        if (!verifySignature(payload, sigHeader)) {
            System.debug('❌ Webhook signature verification FAILED');
            RestContext.response.statusCode = 401;
            // Nothing from the unverified payload is logged.
            StripeFailureLogger.record(StripeFailureLogger.failure(
                    StripeFailureLogger.SOURCE_WEBHOOK_SIGNATURE, StripeFailureLogger.CODE_WEBHOOK_SIGNATURE_INVALID,
                    'Stripe webhook signature verification failed (missing header or webhook secret mismatch)')
                .operation(OPERATION + 'handleWebhook')
                .httpStatus(401));
            StripeFailureLogger.flush();
            return;
        }

        System.debug('✅ Webhook signature verified successfully');

        try {
            Map<String, Object> event = (Map<String, Object>) JSON.deserializeUntyped(payload);
            String eventType = (String) event.get('type');
            currentEventId = (String) event.get('id');
            currentEventType = eventType;
            System.debug('Event type: ' + eventType);
            
            Map<String, Object> invoice = (Map<String, Object>) ((Map<String, Object>) event.get('data')).get('object');
            Map<String, Object> dataObject = (Map<String, Object>) ((Map<String, Object>) event.get('data')).get('object');
            
            if (eventType == 'invoice.payment_succeeded' || eventType == 'invoice.payment_failed') {
                System.debug('Processing invoice event: ' + eventType);
                processInvoice(invoice, eventType);
            } 
            else if(eventType == 'payment_intent.succeeded'){
                System.debug('Processing invoice event: ' + eventType);
                processPaymentIntent(dataObject, eventType);
            }
            else if (eventType == 'customer.subscription.paused') {
                System.debug('Processing subscription paused event');
                processSubscriptionPauseResume(dataObject, true);
            }
            else if (eventType == 'customer.subscription.resumed') {
                System.debug('Processing subscription resumed event');
                processSubscriptionPauseResume(dataObject, false);
            }
            else if (eventType == 'subscription_schedule.updated' ||
                     eventType == 'subscription_schedule.completed' ||
                     eventType == 'subscription_schedule.released') {
                processSubscriptionSchedule(dataObject, eventType);
            }
            else if (eventType == 'customer.subscription.pending_update_applied' ||
                     eventType == 'customer.subscription.pending_update_expired') {
                processPendingSubscriptionUpdate(dataObject, eventType);
            }
            else if (eventType == 'customer.subscription.updated') {
                processScheduledSubscriptionActivation(dataObject);
            }
            else {
                System.debug('Ignoring unsupported event type: ' + eventType);
            }
            
            RestContext.response.statusCode = 200;
            System.debug('✅ Webhook handled successfully. Responding with 200.');
            
        } catch (Exception e) {
            System.debug('🔥 Exception during webhook processing: ' + e.getMessage() + ' | Stack: ' + e.getStackTraceString());
            RestContext.response.statusCode = 500;
            StripeFailureLogger.record(StripeFailureLogger.failure(
                    StripeFailureLogger.SOURCE_WEBHOOK, StripeFailureLogger.CODE_WEBHOOK_UNHANDLED_EXCEPTION,
                    'Unhandled error while processing a Stripe webhook; Stripe will retry the event')
                .withException(e)
                .operation(OPERATION + 'handleWebhook')
                .stripeEvent(currentEventId, currentEventType)
                .httpStatus(500));
        } finally {
            StripeFailureLogger.flush();
        }
    }

    // Base failure for a paid-invoice problem, identified by Stripe ids only (never the customer email).
    private static StripeFailureLogger.Failure invoiceFailure(
        String reasonCode, String reason, String invoiceId, String subscriptionId, String customerId, Decimal amount
    ) {
        return StripeFailureLogger.failure(StripeFailureLogger.SOURCE_WEBHOOK, reasonCode, reason)
            .operation(OPERATION + 'processInvoice')
            .stripeEvent(currentEventId, currentEventType)
            .stripeObject(invoiceId)
            .subscription(subscriptionId)
            .customer(customerId)
            .amount(amount);
    }

    private static String getHeaderValueIgnoreCase(RestRequest req, String headerName) {
        if (req == null || req.headers == null || String.isBlank(headerName)) {
            return null;
        }

        String headerValue = req.headers.get(headerName);
        if (!String.isBlank(headerValue)) {
            return headerValue;
        }

        for (String currentHeaderName : req.headers.keySet()) {
            if (currentHeaderName != null && currentHeaderName.equalsIgnoreCase(headerName)) {
                return req.headers.get(currentHeaderName);
            }
        }

        return null;
    }
    
    //For recurring payments
    private static void processInvoice(Map<String, Object> invoice, String eventType) {
        System.debug('=== Processing Stripe Invoice ===');
        
        String stripeInvoiceId = (String) invoice.get('id');
        String chargeId = extractObjectId(invoice.get('charge'));
        String customerId = (String) invoice.get('customer');
        Integer amountPaidCents = (Integer) invoice.get('amount_paid');
        Decimal amount = amountPaidCents != null ? (Decimal) amountPaidCents / 100 : 0;
        String status = eventType == 'invoice.payment_succeeded' ? 'Paid' : 'Failed';
        String customerEmail = (String) invoice.get('customer_email');

        if (amountPaidCents == 0 && isSapaBillingGapInvoice(invoice)) {
            System.debug('Ignoring SAPA-marked zero-value billing-gap invoice.');
            return;
        }
        
        System.debug('Stripe Invoice ID: ' + stripeInvoiceId);
        System.debug('Amount (USD): ' + amount);
        System.debug('Status: ' + status);
        System.debug('Customer Email: ' + customerEmail);

        if (String.isBlank(stripeInvoiceId)) {
            System.debug('Stripe invoice id is blank - skipping payment update');
            return;
        }

        Integer existingInvoicePaymentCount = [
            SELECT COUNT()
            FROM Payment__c
            WHERE Transaction_ID__c = :stripeInvoiceId
        ];
        if (existingInvoicePaymentCount > 0) {
            System.debug('Payment already exists for Stripe invoice: ' + stripeInvoiceId);
            return;
        }
        
        // 🔍 Extract salesforce_id from line item metadata
        Id recurringDonationId = null;
        String invoiceSubscriptionId;
        Datetime invoicePeriodStart;
        try {
            Map<String, Object> lines = (Map<String, Object>) invoice.get('lines');
            List<Object> lineData = (List<Object>) lines.get('data');
            if (lineData != null && !lineData.isEmpty()) {
                Map<String, Object> firstLine = (Map<String, Object>) lineData[0];
                Map<String, Object> lineMetadata = (Map<String, Object>) firstLine.get('metadata');
                Map<String, Object> period = (Map<String, Object>) firstLine.get('period');
                if (period != null && period.get('start') != null) {
                    Long periodStart = Long.valueOf(String.valueOf(period.get('start')));
                    invoicePeriodStart = Datetime.newInstance(periodStart * 1000);
                }
                if (lineMetadata != null && lineMetadata.containsKey('salesforce_id')) {
                    String sfIdStr = (String) lineMetadata.get('salesforce_id');
                    
                    recurringDonationId = Id.valueOf(sfIdStr);
                    System.debug('✅ Extracted Recurring Donation ID from line metadata: ' + recurringDonationId);
                    
                }
            }
        } catch (Exception e) {
            System.debug('⚠️ Error parsing line item metadata: ' + e.getMessage());
        }
        
        // Fallback: try parent.subscription_details.metadata (optional)
        if (recurringDonationId == null) {
            try {
                system.debug('Fallback recurring donation:'+recurringDonationId);
                Map<String, Object> parent = (Map<String, Object>) invoice.get('parent');
                if (parent != null && 'subscription_details'.equals(parent.get('type'))) {
                    Map<String, Object> subDetails = (Map<String, Object>) parent.get('subscription_details');
                    if (subDetails != null && subDetails.get('subscription') != null) {
                        invoiceSubscriptionId = String.valueOf(subDetails.get('subscription'));
                    }
                    Map<String, Object> subMetadata = (Map<String, Object>) subDetails.get('metadata');
                    if (subMetadata != null && subMetadata.containsKey('salesforce_id')) {
                        String sfIdStr = (String) subMetadata.get('salesforce_id');
                        
                        recurringDonationId = Id.valueOf(sfIdStr);
                        System.debug('✅ Extracted Recurring Donation ID from subscription metadata: ' + recurringDonationId);
                        
                    }
                }
            } catch (Exception e) {
                System.debug('⚠️ Error parsing subscription metadata: ' + e.getMessage());
            }
        }
        
        // Subscription id location depends on the webhook API version: top-level `subscription`
        // before 2025-03-31.basil, parent.subscription_details.subscription from basil onward.
        if (String.isBlank(invoiceSubscriptionId)) {
            invoiceSubscriptionId = parentSubscriptionId(invoice);
        }
        if (String.isBlank(invoiceSubscriptionId) && invoice.get('subscription') != null) {
            invoiceSubscriptionId = extractObjectId(invoice.get('subscription'));
        }

        if (recurringDonationId == null) {
            System.debug('❌ No salesforce_id found in invoice metadata – skipping payment update');
            return;
        }

        // 🔎 Query the Recurring Donation (just to confirm it exists)
        List<GiftCommitment> recurringDonations = [
            SELECT Id,
            Name,
            Price_Id__c,
            Subscription_Id__c,
            Product_Id__c,
            Customer_Profile_Id__c,
            Payment_Profile_ID__c,
            ClosedReason__c,
            (SELECT PaymentMethod
             FROM GiftCommitmentSchedules
             LIMIT 1)
            FROM GiftCommitment
            WHERE Id = :recurringDonationId
            LIMIT 1
        ];//npsp__ClosedReason__c,
        if (recurringDonations.isEmpty()) {
            System.debug('❌ Recurring Donation not found: ' + recurringDonationId);
            if (eventType == 'invoice.payment_succeeded') {
                // The id goes in the text: a lookup to a missing record could not be saved.
                StripeFailureLogger.record(invoiceFailure(StripeFailureLogger.CODE_INVOICE_RD_NOT_FOUND,
                    'Paid invoice names recurring donation ' + recurringDonationId + ', which does not exist in Salesforce',
                    stripeInvoiceId, invoiceSubscriptionId, customerId, amount));
            }
            return;
        }
        GiftCommitment rd = recurringDonations[0];
        System.debug('Found Recurring Donation: ' + rd.Name);

        // createRecurringSubscription() stores Subscription_Id__c only after its Stripe callouts,
        // so the first invoice webhook can arrive before that commit. The salesforce_id metadata
        // already identifies this commitment; only a different, known subscription is a mismatch.
        if (!String.isBlank(invoiceSubscriptionId) && !String.isBlank(rd.Subscription_Id__c) &&
            rd.Subscription_Id__c != invoiceSubscriptionId) {
            System.debug('Invoice subscription does not match the recurring donation - skipping payment update. ' +
                'Invoice subscription: ' + invoiceSubscriptionId + ' | GiftCommitment.Subscription_Id__c: ' + rd.Subscription_Id__c);
            if (eventType == 'invoice.payment_succeeded') {
                StripeFailureLogger.record(invoiceFailure(StripeFailureLogger.CODE_INVOICE_SUBSCRIPTION_MISMATCH,
                        'Paid invoice subscription does not match the recurring donation subscription',
                        stripeInvoiceId, invoiceSubscriptionId, customerId, amount)
                    .withError('Invoice subscription ' + invoiceSubscriptionId
                        + ', recurring donation subscription ' + rd.Subscription_Id__c)
                    .commitment(rd.Id));
            }
            return;
        }
        if (String.isBlank(rd.Subscription_Id__c)) {
            System.debug('GiftCommitment.Subscription_Id__c is not committed yet; accepting invoice subscription ' +
                invoiceSubscriptionId + ' by salesforce_id metadata.');
        }

        if (eventType != 'invoice.payment_succeeded') {
            System.debug('Invoice event is not successful - skipping Payment__c creation for event: ' + eventType);
            return;
        }

        GiftTransaction matchedTransaction = findInvoiceTransaction(rd.Id, invoicePeriodDates(invoicePeriodStart), amount);
        if (matchedTransaction == null) {
            System.debug('No matching pledged/unpaid or pre-posted GiftTransaction found for recurring donation - skipping Payment__c creation');
            StripeFailureLogger.record(invoiceFailure(StripeFailureLogger.CODE_PAID_NOT_RECORDED,
                    'Paid in Stripe, not recorded in Salesforce: no matching unpaid donation for the invoice period and amount',
                    stripeInvoiceId, invoiceSubscriptionId, customerId, amount)
                .commitment(rd.Id));
            return;
        }

        // Resolve the charge before any DML: the fallback is a Stripe callout.
        if (String.isBlank(chargeId)) {
            chargeId = resolveInvoiceChargeId(invoice);
        }
        if (String.isBlank(chargeId)) {
            System.debug('⚠️ Stripe charge id could not be resolved for invoice ' + stripeInvoiceId + '; Payment__c is recorded without it.');
        }

        // Serialize concurrent deliveries of the same invoice, then repeat the duplicate checks.
        List<GiftCommitment> lockedCommitment = [SELECT Id FROM GiftCommitment WHERE Id = :rd.Id FOR UPDATE];
        if ([SELECT COUNT() FROM Payment__c WHERE Transaction_ID__c = :stripeInvoiceId] > 0) {
            System.debug('Payment already exists for Stripe invoice: ' + stripeInvoiceId);
            return;
        }
        if ([SELECT COUNT() FROM Payment__c WHERE Donation__c = :matchedTransaction.Id] > 0) {
            System.debug('GiftTransaction ' + matchedTransaction.Id + ' already has a Payment__c - skipping Payment__c creation');
            return;
        }

        String paymentMethod = null;
        if (!rd.GiftCommitmentSchedules.isEmpty()) {
            paymentMethod = rd.GiftCommitmentSchedules[0].PaymentMethod;
        }
        // Payment Trigger Flow copies Status, Transaction_Id__c and Charge_Id__c onto Donation__c.
        Payment__c paymentToInsert = new Payment__c();
        paymentToInsert.Payment_Status__c = 'Paid';
        paymentToInsert.Transaction_ID__c = stripeInvoiceId;
        paymentToInsert.Charge_ID__c = chargeId;
        paymentToInsert.Payment_Acknowledged_Date__c = Date.Today();
        paymentToInsert.Payment_Date__c = Date.Today();
        paymentToInsert.donorId__c = matchedTransaction.DonorId;
        paymentToInsert.Recurring_Donation__c = rd.Id;
        paymentToInsert.Price_Id__c = rd.Price_Id__c;
        paymentToInsert.payment_amount__c = amount;
        paymentToInsert.Donation__c = matchedTransaction.Id;
        paymentToInsert.subscription_Id__c = String.isBlank(rd.Subscription_Id__c) ? invoiceSubscriptionId : rd.Subscription_Id__c;
        paymentToInsert.product_Id__c = rd.product_Id__c;
        paymentToInsert.Customer_Profile_Id__c = rd.Customer_Profile_Id__c;
        paymentToInsert.Payment_Profile_ID__c = rd.Payment_Profile_ID__c;
        paymentToInsert.Payment_Method__c = paymentMethod;
        paymentToInsert.Payment_Type__c = 'Recurring Payment';
        paymentToInsert.Paid__c = true;
        paymentToInsert.Result_Status__c = 'Success';
        try {
            insert paymentToInsert;
            System.debug('✅ Payment__c inserted successfully: ' + paymentToInsert.Id);
        }
        catch (Exception e) {
            System.debug('🔥 Failed to insert Payment__c: ' + e.getMessage());
            StripeFailureLogger.record(invoiceFailure(StripeFailureLogger.CODE_PAYMENT_INSERT_FAILED,
                    'Paid in Stripe, but the Payment record could not be saved in Salesforce',
                    stripeInvoiceId, paymentToInsert.subscription_Id__c, customerId, amount)
                .withException(e)
                .commitment(rd.Id)
                .donation(matchedTransaction.Id));
        }
    }

    /**
     * Prefers the pledged/unpaid installment due on the invoice period start. Otherwise accepts the
     * installment the donation wizard pre-posted as Paid ("Mark first instalment as posted
     * immediately"), which has no Payment__c and no Stripe ids yet. Never returns a transaction that
     * already carries a Payment__c or Transaction_Id__c.
     */
    private static GiftTransaction findInvoiceTransaction(Id commitmentId, List<Date> periodDates, Decimal amount) {
        List<GiftTransaction> candidates = [
            SELECT Id, DonorId, OriginalAmount, Status, TransactionDueDate, TransactionDate,
                   (SELECT Id FROM Payments__r LIMIT 1)
            FROM GiftTransaction
            WHERE GiftCommitmentId = :commitmentId
              AND Transaction_Id__c = null
              AND (Status IN ('Pledged', 'Unpaid') OR (Status = 'Paid' AND Charge_Id__c = null))
            ORDER BY TransactionDueDate, CreatedDate
            LIMIT 50
        ];
        if (periodDates.isEmpty()) {
            for (GiftTransaction candidate : candidates) {
                if (candidate.Status != 'Paid' && candidate.Payments__r.isEmpty() && candidate.OriginalAmount == amount) {
                    return candidate;
                }
            }
            return null;
        }
        for (Date periodDate : periodDates) {
            for (GiftTransaction candidate : candidates) {
                if (candidate.Status == 'Paid' || !candidate.Payments__r.isEmpty()) continue;
                if (candidate.TransactionDueDate == periodDate) return candidate;
            }
        }
        for (Date periodDate : periodDates) {
            for (GiftTransaction candidate : candidates) {
                if (candidate.Status != 'Paid' || !candidate.Payments__r.isEmpty()) continue;
                if (candidate.TransactionDueDate == periodDate || candidate.TransactionDate == periodDate) {
                    System.debug('Matched pre-posted Paid GiftTransaction without Payment__c: ' + candidate.Id);
                    return candidate;
                }
            }
        }
        return null;
    }

    /**
     * Installment dates are Los Angeles business dates; an invoice created after ~5 pm Pacific has a
     * GMT period start on the next day. Try the business date first, then the GMT date.
     */
    private static List<Date> invoicePeriodDates(Datetime periodStart) {
        List<Date> dates = new List<Date>();
        if (periodStart == null) return dates;
        dates.add(StripePauseBusinessClock.businessDate(periodStart));
        if (!dates.contains(periodStart.dateGmt())) dates.add(periodStart.dateGmt());
        return dates;
    }

    private static String parentSubscriptionId(Map<String, Object> invoice) {
        Map<String, Object> parent = mapValue(invoice.get('parent'));
        Map<String, Object> details = parent == null ? null : mapValue(parent.get('subscription_details'));
        return details == null ? null : extractObjectId(details.get('subscription'));
    }

    /**
     * `charge` and `payment_intent` were removed from Invoice in 2025-03-31.basil. Order: payload
     * invoice.payments / expanded payment_intent, then Stripe GET calls. Must run before any DML.
     */
    @TestVisible
    private static String resolveInvoiceChargeId(Map<String, Object> invoice) {
        String paymentIntentId = null;
        Map<String, Object> payments = mapValue(invoice.get('payments'));
        List<Object> paymentData = payments == null ? null : (List<Object>) payments.get('data');
        if (paymentData != null) {
            for (Object entry : paymentData) {
                Map<String, Object> invoicePayment = mapValue(entry);
                Map<String, Object> payment = invoicePayment == null ? null : mapValue(invoicePayment.get('payment'));
                if (payment == null) continue;
                if (payment.get('charge') != null) return extractObjectId(payment.get('charge'));
                Map<String, Object> intent = mapValue(payment.get('payment_intent'));
                if (intent != null && intent.get('latest_charge') != null) return extractObjectId(intent.get('latest_charge'));
                if (paymentIntentId == null && payment.get('payment_intent') != null) {
                    paymentIntentId = extractObjectId(payment.get('payment_intent'));
                }
            }
        }
        Map<String, Object> expandedIntent = mapValue(invoice.get('payment_intent'));
        if (expandedIntent != null && expandedIntent.get('latest_charge') != null) {
            return extractObjectId(expandedIntent.get('latest_charge'));
        }
        if (paymentIntentId == null && invoice.get('payment_intent') != null) {
            paymentIntentId = extractObjectId(invoice.get('payment_intent'));
        }

        try {
            if (String.isBlank(paymentIntentId)) {
                String invoiceId = (String) invoice.get('id');
                // Without a Stripe-Version header the account default version answers; older
                // versions still return charge/payment_intent on the invoice.
                Map<String, Object> fetchedInvoice = stripeGet('/invoices/' + EncodingUtil.urlEncode(invoiceId, 'UTF-8'));
                if (fetchedInvoice != null) {
                    if (fetchedInvoice.get('charge') != null) return extractObjectId(fetchedInvoice.get('charge'));
                    if (fetchedInvoice.get('payment_intent') != null) {
                        paymentIntentId = extractObjectId(fetchedInvoice.get('payment_intent'));
                    }
                }
                if (String.isBlank(paymentIntentId)) {
                    Map<String, Object> invoicePayments = stripeGet('/invoice_payments?invoice=' +
                        EncodingUtil.urlEncode(invoiceId, 'UTF-8'));
                    List<Object> rows = invoicePayments == null ? null : (List<Object>) invoicePayments.get('data');
                    if (rows != null) {
                        for (Object row : rows) {
                            Map<String, Object> payment = mapValue(mapValue(row) == null ? null : mapValue(row).get('payment'));
                            if (payment == null) continue;
                            if (payment.get('charge') != null) return extractObjectId(payment.get('charge'));
                            if (payment.get('payment_intent') != null) {
                                paymentIntentId = extractObjectId(payment.get('payment_intent'));
                                break;
                            }
                        }
                    }
                }
            }
            if (String.isNotBlank(paymentIntentId)) {
                Map<String, Object> intent = stripeGet('/payment_intents/' + EncodingUtil.urlEncode(paymentIntentId, 'UTF-8'));
                if (intent != null && intent.get('latest_charge') != null) return extractObjectId(intent.get('latest_charge'));
            }
        } catch (Exception e) {
            System.debug('⚠️ Stripe charge lookup failed: ' + e.getMessage());
        }
        return null;
    }

    private static Map<String, Object> stripeGet(String path) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint('https://api.stripe.com/v1' + path);
        request.setMethod('GET');
        request.setTimeout(20000);
        request.setHeader('Authorization', 'Bearer ' + System.Label.Stripe_Secret);
        HttpResponse response = new Http().send(request);
        if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
            System.debug('⚠️ Stripe GET ' + path + ' returned ' + response.getStatusCode());
            return null;
        }
        return (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
    }

    private static Boolean isSapaBillingGapInvoice(Map<String, Object> invoice) {
        try {
            Map<String, Object> parent = (Map<String, Object>) invoice.get('parent');
            if (parent == null || !'subscription_details'.equals(parent.get('type'))) return false;
            Map<String, Object> details = (Map<String, Object>) parent.get('subscription_details');
            Map<String, Object> metadata = details == null ? null : (Map<String, Object>) details.get('metadata');
            return metadata != null && 'true'.equalsIgnoreCase(String.valueOf(metadata.get('sapa_billing_gap')));
        } catch (Exception ignored) {
            return false;
        }
    }
    
    private static void processSubscriptionSchedule(Map<String, Object> schedule, String eventType) {
        if (schedule == null || schedule.get('id') == null) return;
        String scheduleId = String.valueOf(schedule.get('id'));
        List<Stripe_Subscription_Change__c> requests = [
            SELECT Id, Gift_Commitment__c, Status__c, Stripe_Price_Id__c,
                   Stripe_Effective_Timestamp__c, Requested_Effective_Date__c,
                   Requested_Change_Mode__c, Original_Stripe_Price_Id__c
            FROM Stripe_Subscription_Change__c
            WHERE Stripe_Schedule_Id__c = :scheduleId
              AND Status__c IN ('Scheduled', 'Active')
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (requests.isEmpty()) return;

        Stripe_Subscription_Change__c requestRecord = requests[0];
        Map<String, Object> currentPhase = mapValue(schedule.get('current_phase'));
        Long currentStart = currentPhase == null ? null : longValue(currentPhase.get('start_date'));
        Map<String, Object> activePhase = findPhaseByStart(schedule, currentStart);
        String activeChangeId = phaseMetadataValue(activePhase, 'salesforce_change_id');
        String activePriceId = phasePriceId(activePhase);
        String activePhaseRole = phaseMetadataValue(activePhase, 'sapa_phase_role');
        if (requestRecord.Requested_Change_Mode__c == StripeRecurringChangeMode.TEMPORARY_TERMS) {
            if (activePhaseRole == 'target') {
                requestRecord.Status__c = 'Active';
                requestRecord.Synced_At__c = null;
                requestRecord.Last_Error__c = null;
                update requestRecord;
                update new GiftCommitment(
                    Id = requestRecord.Gift_Commitment__c,
                    Price_Id__c = String.isBlank(activePriceId)
                        ? requestRecord.Stripe_Price_Id__c
                        : activePriceId,
                    Stripe_Schedule_Sync_Status__c = 'Active',
                    Stripe_Schedule_Sync_Message__c = 'The temporary Stripe amount or cadence is active.',
                    Stripe_Schedule_Synced_At__c = null
                );
                return;
            }
            if (activePhaseRole == 'restored' || eventType == 'subscription_schedule.completed') {
                requestRecord.Status__c = 'Synced';
                requestRecord.Synced_At__c = System.now();
                requestRecord.Last_Error__c = null;
                update requestRecord;
                update new GiftCommitment(
                    Id = requestRecord.Gift_Commitment__c,
                    Price_Id__c = String.isBlank(activePriceId)
                        ? requestRecord.Original_Stripe_Price_Id__c
                        : activePriceId,
                    Stripe_Schedule_Sync_Status__c = 'Synced',
                    Stripe_Schedule_Sync_Message__c = 'The temporary Stripe window ended and the original terms were restored.',
                    Stripe_Schedule_Synced_At__c = System.now()
                );
                return;
            }
            return;
        }
        Boolean targetIsCurrent = currentStart != null && (
            activeChangeId == String.valueOf(requestRecord.Id) ||
            (activePriceId == requestRecord.Stripe_Price_Id__c &&
             (requestRecord.Stripe_Effective_Timestamp__c == null ||
              currentStart >= Long.valueOf(String.valueOf(requestRecord.Stripe_Effective_Timestamp__c))))
        );
        if (!targetIsCurrent && eventType == 'subscription_schedule.completed') {
            targetIsCurrent = scheduleContainsTargetPhase(schedule, requestRecord);
        }
        if (!targetIsCurrent) return;

        requestRecord.Status__c = 'Synced';
        requestRecord.Synced_At__c = System.now();
        requestRecord.Last_Error__c = null;
        update requestRecord;

        update new GiftCommitment(
            Id = requestRecord.Gift_Commitment__c,
            Price_Id__c = requestRecord.Stripe_Price_Id__c,
            Stripe_Schedule_Sync_Status__c = 'Synced',
            Stripe_Schedule_Sync_Message__c = 'Stripe scheduled configuration is now active.',
            Stripe_Schedule_Synced_At__c = System.now()
        );
    }

    /** Completes only the exact permanent scheduled target from a verified Stripe event. */
    private static void processScheduledSubscriptionActivation(Map<String, Object> subscription) {
        if (subscription == null || subscription.get('status') != 'active' ||
            subscription.get('pending_update') != null) return;
        Map<String,Object> metadata=mapValue(subscription.get('metadata'));
        if (metadata==null || metadata.get('sapa_owner')!='salesforce' ||
            metadata.get('sapa_billing_gap')=='true') return;
        String changeId=(String)metadata.get('salesforce_change_id');
        if (String.isBlank(changeId) || !Pattern.matches('[a-zA-Z0-9]{15,18}',changeId)) return;
        Map<String,Object> itemCollection=mapValue(subscription.get('items'));
        List<Object> items=itemCollection==null?null:(List<Object>)itemCollection.get('data');
        if (items==null || items.size()!=1) return;
        Map<String,Object> item=mapValue(items[0]);
        if (item==null) return;
        Map<String,Object> expandedPrice=mapValue(item.get('price'));
        String activePrice=expandedPrice==null?String.valueOf(item.get('price')):(String)expandedPrice.get('id');
        Map<String,Object> expandedSchedule=mapValue(subscription.get('schedule'));
        String scheduleId=expandedSchedule==null?String.valueOf(subscription.get('schedule')):(String)expandedSchedule.get('id');
        String subscriptionId=(String)subscription.get('id');
        Long periodStart=longValue(item.get('current_period_start'));
        if (periodStart==null) periodStart=longValue(subscription.get('current_period_start'));
        List<Stripe_Subscription_Change__c> candidates=[
            SELECT Id,Gift_Commitment__c,Gift_Commitment__r.Subscription_Id__c,
                Stripe_Price_Id__c,Stripe_Effective_Timestamp__c
            FROM Stripe_Subscription_Change__c WHERE Id=:changeId AND Status__c='Scheduled'
                AND Requested_Change_Mode__c='Terms' AND Stripe_Subscription_Id__c=:subscriptionId
                AND Stripe_Schedule_Id__c=:scheduleId AND Stripe_Price_Id__c=:activePrice LIMIT 1
        ];
        if (candidates.isEmpty()) return;
        Stripe_Subscription_Change__c change=candidates[0];
        if (change.Gift_Commitment__r.Subscription_Id__c!=subscriptionId ||
            String.valueOf(change.Gift_Commitment__c)!=String.valueOf(metadata.get('salesforce_id')) ||
            periodStart==null || change.Stripe_Effective_Timestamp__c==null ||
            periodStart<Long.valueOf(String.valueOf(change.Stripe_Effective_Timestamp__c))) return;
        update new Stripe_Subscription_Change__c(Id=change.Id,Status__c='Synced',
            Synced_At__c=System.now(),Last_Error__c=null);
        update new GiftCommitment(Id=change.Gift_Commitment__c,Price_Id__c=activePrice,
            Stripe_Schedule_Sync_Status__c='Synced',Stripe_Schedule_Synced_At__c=System.now(),
            Stripe_Schedule_Sync_Message__c='Stripe scheduled configuration is now active.');
    }

    private static void processPendingSubscriptionUpdate(Map<String, Object> subscription, String eventType) {
        if (subscription == null || subscription.get('id') == null) return;
        String subscriptionId = String.valueOf(subscription.get('id'));
        Stripe_Subscription_Change__c requestRecord = findPendingSubscriptionRequest(subscription, subscriptionId);
        if (requestRecord == null || requestRecord.Status__c == 'Synced') return;
        if (eventType.endsWith('expired')) {
            if (requestRecord.Status__c != 'Failed') return;
            requestRecord.Last_Error__c = 'Stripe pending update expired without applying the requested configuration.';
            update requestRecord;
            return;
        }
        if (requestRecord.Status__c == 'Processing') return;
        requestRecord.Status__c = 'Processing';
        requestRecord.Last_Error__c = 'Stripe payment succeeded; verifying the active Price and cancellation state.';
        update requestRecord;
        update new GiftCommitment(
            Id = requestRecord.Gift_Commitment__c,
            Stripe_Schedule_Sync_Status__c = 'Processing',
            Stripe_Schedule_Sync_Message__c = 'Stripe payment succeeded; final verification is running.'
        );
        System.enqueueJob(new StripeRecurringCancelFinalizeJob(requestRecord.Id));
    }

    private static Stripe_Subscription_Change__c findPendingSubscriptionRequest(
        Map<String, Object> subscription,
        String subscriptionId
    ) {
        Map<String, Object> metadata = mapValue(subscription.get('metadata'));
        String changeId = metadata == null ? null : String.valueOf(metadata.get('salesforce_change_id'));
        if (String.isNotBlank(changeId) && Pattern.matches('[a-zA-Z0-9]{15,18}', changeId)) {
            List<Stripe_Subscription_Change__c> exact = [
                SELECT Id, Gift_Commitment__c, Stripe_Price_Id__c, Status__c
                FROM Stripe_Subscription_Change__c
                WHERE Id = :changeId
                  AND Stripe_Subscription_Id__c = :subscriptionId
                  AND Stripe_Action_Mode__c = 'Immediate'
                  AND Status__c IN ('Failed', 'Processing', 'Synced')
                LIMIT 1
            ];
            if (!exact.isEmpty()) return exact[0];
        }

        String invoiceId = extractObjectId(subscription.get('latest_invoice'));
        if (String.isNotBlank(invoiceId)) {
            List<Stripe_Subscription_Change__c> invoiceMatches = [
                SELECT Id, Gift_Commitment__c, Stripe_Price_Id__c, Status__c
                FROM Stripe_Subscription_Change__c
                WHERE Stripe_Subscription_Id__c = :subscriptionId
                  AND Stripe_Invoice_Id__c = :invoiceId
                  AND Stripe_Action_Mode__c = 'Immediate'
                  AND Status__c IN ('Failed', 'Processing', 'Synced')
                LIMIT 2
            ];
            if (invoiceMatches.size() == 1) return invoiceMatches[0];
        }

        List<Stripe_Subscription_Change__c> subscriptionMatches = [
            SELECT Id, Gift_Commitment__c, Stripe_Price_Id__c, Status__c
            FROM Stripe_Subscription_Change__c
            WHERE Stripe_Subscription_Id__c = :subscriptionId
              AND Stripe_Action_Mode__c = 'Immediate'
              AND Status__c IN ('Failed', 'Processing')
            ORDER BY CreatedDate DESC
            LIMIT 2
        ];
        return subscriptionMatches.size() == 1 ? subscriptionMatches[0] : null;
    }

    private static String extractObjectId(Object value) {
        if (value == null) return null;
        Map<String, Object> expanded = mapValue(value);
        return expanded == null ? String.valueOf(value) : String.valueOf(expanded.get('id'));
    }

    private static Map<String, Object> findPhaseByStart(Map<String, Object> schedule, Long startTimestamp) {
        if (startTimestamp == null) return null;
        List<Object> phases = (List<Object>) schedule.get('phases');
        if (phases == null) return null;
        for (Object phaseValue : phases) {
            Map<String, Object> phase = mapValue(phaseValue);
            if (phase != null && longValue(phase.get('start_date')) == startTimestamp) return phase;
        }
        return null;
    }

    private static Boolean scheduleContainsTargetPhase(
        Map<String, Object> schedule,
        Stripe_Subscription_Change__c requestRecord
    ) {
        List<Object> phases = (List<Object>) schedule.get('phases');
        if (phases == null) return false;
        for (Object phaseValue : phases) {
            Map<String, Object> phase = mapValue(phaseValue);
            if (phaseMetadataValue(phase, 'salesforce_change_id') == String.valueOf(requestRecord.Id) ||
                phasePriceId(phase) == requestRecord.Stripe_Price_Id__c) return true;
        }
        return false;
    }

    private static String phaseMetadataValue(Map<String, Object> phase, String key) {
        Map<String, Object> metadata = phase == null ? null : mapValue(phase.get('metadata'));
        return metadata == null || metadata.get(key) == null ? null : String.valueOf(metadata.get(key));
    }

    private static String phasePriceId(Map<String, Object> phase) {
        List<Object> items = phase == null ? null : (List<Object>) phase.get('items');
        if (items == null || items.isEmpty()) return null;
        Map<String, Object> item = mapValue(items[0]);
        Object priceValue = item == null ? null : item.get('price');
        Map<String, Object> price = mapValue(priceValue);
        return price == null
            ? (priceValue == null ? null : String.valueOf(priceValue))
            : String.valueOf(price.get('id'));
    }

    private static Map<String, Object> mapValue(Object value) {
        return value instanceof Map<String, Object> ? (Map<String, Object>) value : null;
    }

    private static Long longValue(Object value) {
        return value == null ? null : Long.valueOf(String.valueOf(value));
    }

    //For single payments
    private static void processPaymentIntent(Map<String, Object> paymentIntent, String eventType) {
        System.debug('=== Processing Stripe PaymentIntent (Single Donation) ===');
        
        String paymentIntentId = (String) paymentIntent.get('id');
        Integer amountCents = (Integer) paymentIntent.get('amount');
        Decimal amount = amountCents != null ? (Decimal) amountCents / 100 : 0;
        String curr = (String) paymentIntent.get('currency');
        String status = (String) paymentIntent.get('status');
        
        System.debug('PaymentIntent ID: ' + paymentIntentId);
        System.debug('Amount: ' + amount + ' ' + curr);
        System.debug('Status: ' + status);

        if (String.isBlank(paymentIntentId)) {
            System.debug('PaymentIntent id is blank - skipping payment update');
            return;
        }

        Integer existingPaymentIntentCount = [
            SELECT COUNT()
            FROM Payment__c
            WHERE Transaction_ID__c = :paymentIntentId
        ];
        if (existingPaymentIntentCount > 0) {
            System.debug('Payment already exists for Stripe PaymentIntent: ' + paymentIntentId);
            return;
        }
        
        // 🔍 Extract Salesforce Donation (Opportunity) ID
        Id donationId;
        try {
            Map<String, Object> metadata = (Map<String, Object>) paymentIntent.get('metadata');
            if (metadata != null && metadata.containsKey('donation_id')) {
                donationId = Id.valueOf((String) metadata.get('donation_id'));
                System.debug('✅ Extracted Donation ID: ' + donationId);
            }
        } catch (Exception e) {
            System.debug('⚠️ Error parsing donation_id: ' + e.getMessage());
        }
        
        if (donationId == null) {
            System.debug('❌ No donation_id found – skipping');
            return;
        }
        
        // 🔎 Load Opportunity
        List<GiftTransaction> donations = [
            SELECT Id, DonorId, Donor.Customer_Profile_Id_Stripe__c
            FROM GiftTransaction
            WHERE Id = :donationId
            LIMIT 1
        ];
        if (donations.isEmpty()) {
            System.debug('GiftTransaction not found for payment intent donation_id: ' + donationId);
            // The id goes in the text: a lookup to a missing record could not be saved.
            StripeFailureLogger.record(StripeFailureLogger.failure(
                    StripeFailureLogger.SOURCE_WEBHOOK, StripeFailureLogger.CODE_PAID_NOT_RECORDED,
                    'Paid in Stripe, not recorded in Salesforce: donation ' + donationId + ' from the payment metadata does not exist')
                .operation(OPERATION + 'processPaymentIntent')
                .stripeEvent(currentEventId, currentEventType)
                .stripeObject(paymentIntentId)
                .amount(amount));
            return;
        }

        GiftTransaction opp = donations[0];
        
        // ✏️ Create Payment__c
        Payment__c payment = new Payment__c();
        payment.Transaction_ID__c = paymentIntentId;
        payment.Payment_Status__c = status == 'succeeded' ? 'Paid' : 'Failed';
        payment.Payment_Date__c = Date.today();
        payment.Payment_Acknowledged_Date__c = Date.today();
        payment.payment_amount__c = amount;
        payment.Customer_Profile_Id__c =  opp.Donor.Customer_Profile_Id_Stripe__c;
        payment.donorId__c = opp.DonorId;
        payment.Donation__c = opp.Id;
        payment.payment_Method__c = 'Credit Card';
        payment.Payment_Type__c = 'Single Payment'; 
        payment.Paid__c = True;// (status == 'succeeded');
        
        if(status == 'succeeded'){
            payment.Result_Status__c = 'Success';
        }
        else{
            payment.Result_Status__c = 'Failed';
        }
        try {
            insert payment;
            System.debug('✅ Payment__c inserted: ' + payment.Id);
        } catch (Exception e) {
            System.debug('🔥 Failed to insert Payment__c: ' + e.getMessage());
            StripeFailureLogger.record(StripeFailureLogger.failure(
                    StripeFailureLogger.SOURCE_WEBHOOK, StripeFailureLogger.CODE_PAYMENT_INSERT_FAILED,
                    'Paid in Stripe, but the Payment record could not be saved in Salesforce')
                .withException(e)
                .operation(OPERATION + 'processPaymentIntent')
                .stripeEvent(currentEventId, currentEventType)
                .stripeObject(paymentIntentId)
                .amount(amount)
                .donation(opp.Id));
        }
    }
    
    /*private static Id findOpportunityId(String email) {
if (String.isBlank(email)) {
System.debug('Email is blank – skipping Opportunity lookup');
return null;
}

System.debug('Looking up Opportunity for email: ' + email);
List<Contact> contacts = [
SELECT Id, (SELECT Id FROM Opportunities LIMIT 1) 
FROM Contact 
WHERE Email = :email 
LIMIT 1
];

if (!contacts.isEmpty() && !contacts[0].Opportunities.isEmpty()) {
Id oppId = contacts[0].Opportunities[0].Id;
System.debug('Found Opportunity via Contact: ' + oppId);
return oppId;
}

System.debug('No Contact or Opportunity found for email: ' + email);
return null;
}*/

    /**
     * Syncs GiftCommitment.Status when Stripe fires a pause or resume webhook.
     * Acts as a reliable fallback — if the LWC Apex call partially failed,
     * this ensures Salesforce stays in sync with Stripe's actual state.
     */
    private static void processSubscriptionPauseResume(
        Map<String, Object> subscription,
        Boolean isPaused
    ) {
        System.debug('=== processSubscriptionPauseResume isPaused=' + isPaused + ' ===');

        // Extract salesforce_id from subscription metadata
        Id rdId = null;
        try {
            Map<String, Object> metadata =
                (Map<String, Object>) subscription.get('metadata');
            if (metadata != null && metadata.containsKey('salesforce_id')) {
                rdId = Id.valueOf((String) metadata.get('salesforce_id'));
                System.debug('Extracted GiftCommitment ID: ' + rdId);
            }
        } catch (Exception e) {
            System.debug('⚠️ Error parsing subscription metadata: ' + e.getMessage());
        }

        if (rdId == null) {
            System.debug('❌ No salesforce_id in subscription metadata — skipping');
            return;
        }

        GiftCommitment rd = new GiftCommitment(Id = rdId);

        if (isPaused) {
            rd.Status = 'Paused';
            // Note: Pause_Reason__c is intentionally NOT overwritten here.
            // It was already set by the LWC/Apex when the user clicked Pause.
        } else {
            rd.Status           = 'Active';
            rd.Pause_Reason__c  = null;
            // Pull next billing date from current_period_end if available
            try {
                Object periodEnd = subscription.get('current_period_end');
                if (periodEnd != null) {
                    Long ts = Long.valueOf(String.valueOf(periodEnd));
                    rd.NextTransactionDate = DateTime.newInstance(ts * 1000).date();
                    System.debug('NextTransactionDate set to: ' + rd.NextTransactionDate);
                }
            } catch (Exception e) {
                System.debug('⚠️ Could not parse current_period_end: ' + e.getMessage());
            }
        }

        try {
            update rd;
            System.debug('✅ GiftCommitment updated via webhook: Status=' + rd.Status);
        } catch (Exception e) {
            System.debug('🔥 Failed to update GiftCommitment in webhook: ' + e.getMessage());
            StripeFailureLogger.record(StripeFailureLogger.failure(
                    StripeFailureLogger.SOURCE_WEBHOOK, StripeFailureLogger.CODE_RD_UPDATE_FAILED,
                    'Stripe ' + (isPaused ? 'paused' : 'resumed') + ' the subscription, but the recurring donation status could not be updated')
                .withException(e)
                .operation(OPERATION + 'processSubscriptionPauseResume')
                .stripeEvent(currentEventId, currentEventType)
                .stripeObject((String) subscription.get('id'))
                .commitment(rdId));
        }
    }
    
    private static Boolean verifySignature(String payload, String sigHeader) {
        if (String.isBlank(sigHeader)) {
            System.debug('❌ Missing Stripe-Signature header');
            return false;
        }
        
        // ⚠️ In production, store this in Custom Metadata or Protected Custom Setting
        
        String webhookSecret = System.Label.StripeWebsecret;//'REDACTED_CREDENTIAL';
        Boolean isValid = StripeWebhookVerifier.isValid(payload, sigHeader, webhookSecret);
        System.debug('Signature verification result: ' + (isValid ? '✅ VALID' : '❌ INVALID'));
        
        return isValid;
    }
}