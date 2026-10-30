/**
 * Stripe boundary for previewing and applying effective-dated recurring donation changes.
 */
public without sharing class StripeRecurringScheduleGateway {
    private static final String STRIPE_API_BASE = 'https://api.stripe.com/v1';
    private static final String SAPA_OWNER_KEY = 'sapa_owner';
    private static final String SAPA_OWNER_VALUE = 'salesforce';
    private static final String BILLING_GAP_KEY = 'sapa_billing_gap';
    private static final String PHASE_ROLE_KEY = 'sapa_phase_role';
    private static final Integer TIMEOUT_MS = 20000;

    public class StripeRecurringScheduleException extends Exception {}

    public class ChangeRequest {
        public String subscriptionId;
        public String productId;
        public String currencyIsoCode;
        public Decimal amount;
        public String transactionPeriod;
        public Integer transactionInterval;
        public String transactionDay;
        public Date effectiveDate;
        public Date effectiveEndDate;
        public String recurringType;
        public Integer plannedInstallments;
        public Date firstPaymentDate;
        public Date finalPaymentDate;
        public String changeMode;
        public String salesforceGiftCommitmentId;
        public String salesforceChangeId;
        public String idempotencyKey;
        public Boolean stopBillingImmediately;
        public String targetPriceId;
        public Decimal originalAmount;
        public String originalPeriod;
        public Integer originalInterval;
        public String originalPriceId;
        public Long originalCancelAt;
        public String restorationScheduleId;
        public Date restorationFirstPaymentDate;
    }

    public class PreviewResult {
        public Boolean canProceed;
        public String blockingError;
        public String businessWarning;
        public Decimal currentAmount;
        public String currentPeriod;
        public Integer currentInterval;
        public Decimal requestedAmount;
        public String requestedPeriod;
        public Integer requestedInterval;
        public Date stripeCurrentPeriodEnd;
        public String actionMode;
        public Date firstPaymentDate;
        public Date finalPaymentDate;
        public Boolean willGenerateFullInvoice;
        public Boolean requiresBillingGap;
        public String changeMode;
        public Date effectiveEndDate;
        public Date lastTemporaryPaymentDate;
        public Date restorationFirstPaymentDate;
        public Integer temporaryInstallments;
        public String originalPriceId;
        public Datetime originalCancelAt;
    }

    public class ChangeResult {
        public String actionMode;
        public String subscriptionScheduleId;
        public String priceId;
        public Long effectiveTimestamp;
        public String invoiceId;
        public Boolean hasPendingUpdate;
        public Datetime pendingUpdateExpiresAt;
        public Boolean cancellationVerified;
        public Boolean billingStopVerified;
        public Datetime billingStoppedAt;
        public Long restorationEffectiveTimestamp;
    }

    private class SubscriptionContext {
        Map<String, Object> subscription;
        Map<String, Object> item;
        Map<String, Object> price;
        Map<String, Object> schedule;
        String itemId;
        String currentPriceId;
        String currentProductId;
        String productId;
        String currencyCode;
        String currentInterval;
        Integer currentIntervalCount;
        Integer quantity;
        Long currentPeriodStart;
        Long currentPeriodEnd;
        String scheduleId;
        String subscriptionStatus;
        Long trialEnd;
        Long cancelAt;
        Boolean cancelAtPeriodEnd;
    }

    private class FormValue {
        String key;
        String value;
        FormValue(String key, String value) {
            this.key = key;
            this.value = value;
        }
    }

    @TestVisible private static String secretKeyOverride;
    @TestVisible static Boolean trialBridgeEnabledOverride;

    /** Maps Salesforce schedule periods to Stripe recurring intervals. */
    public static String toStripeInterval(String transactionPeriod) {
        if (transactionPeriod == 'Daily') return 'day';
        if (transactionPeriod == 'Weekly') return 'week';
        if (transactionPeriod == 'Monthly') return 'month';
        if (transactionPeriod == 'Yearly') return 'year';
        throw new StripeRecurringScheduleException('Unsupported recurring period.');
    }

    /**
     * Retrieves the current Stripe subscription and calculates the user-facing result without mutation.
     * @param request proposed composite recurring donation change
     * @return current configuration, billing impact, payment dates, and any blocking error
     */
    public static PreviewResult previewChange(ChangeRequest request) {
        PreviewResult result = basePreview(request);
        String validationError = validateLocalRequest(request);
        if (validationError != null) {
            result.canProceed = false;
            result.blockingError = validationError;
            return result;
        }

        try {
            SubscriptionContext context = retrieveContext(request, getSecretKey());
            rejectUnownedSchedule(context, request.salesforceGiftCommitmentId);
            populatePreview(result, request, context);
            result.canProceed = true;
        } catch (Exception error) {
            result.canProceed = false;
            result.blockingError = sanitize(error.getMessage());
        }
        return result;
    }

    /**
     * Applies an immediate subscription update or creates/replaces a future SAPA-owned schedule.
     * @param request validated composite recurring donation change
     * @return identifiers and payment-gating state returned by Stripe
     */
    public static ChangeResult applyChange(ChangeRequest request) {
        String validationError = validateLocalRequest(request);
        if (validationError != null) {
            throw new StripeRecurringScheduleException(validationError);
        }
        String secretKey = getSecretKey();
        SubscriptionContext context = retrieveContext(request, secretKey);
        PreviewResult preview = basePreview(request);
        populatePreview(preview, request, context);
        if (preview.requiresBillingGap == true) {
            request.stopBillingImmediately = true;
        }
        request.firstPaymentDate = preview.firstPaymentDate;
        request.finalPaymentDate = preview.finalPaymentDate;

        // End-date/Open/Fixed transitions are cancellation-only.  They must
        // not resolve a Price, replace an item, reset the anchor, or create an
        // invoice merely because a recurring type changed.
        if (request.changeMode == StripeRecurringChangeMode.END_DATE_ONLY) {
            return applyEndDateOnly(request, context, preview, secretKey);
        }

        if (request.stopBillingImmediately == true) {
            if (!preview.willGenerateFullInvoice) {
                throw new StripeRecurringScheduleException('Stopping current billing is supported only when the billing cadence changes.');
            }
            if (!isTrialBridgeEnabled()) {
                throw new StripeRecurringScheduleException('Immediate billing stop is not enabled for this Salesforce environment.');
            }
            if (request.effectiveDate == Date.today() && context.subscriptionStatus != 'trialing') {
                throw new StripeRecurringScheduleException('A same-day restart is supported only when a SAPA billing gap is already active.');
            }
        }

        Boolean temporaryTerms = request.changeMode == 'TemporaryTerms';
        if (!temporaryTerms && preview.actionMode == 'Immediate' && context.scheduleId != null) {
            rejectUnownedSchedule(context, request.salesforceGiftCommitmentId);
            releaseOwnedSchedule(context.scheduleId, request.idempotencyKey, secretKey);
            context.scheduleId = null;
            context.schedule = null;
        } else if (preview.actionMode == 'Scheduled' && context.scheduleId != null &&
            !isSapaOwned(context.schedule, request.salesforceGiftCommitmentId) && hasMetadata(context.schedule)) {
            throw externalScheduleException();
        }

        String newPriceId = resolveTargetPriceId(request, context, secretKey);
        if (temporaryTerms) {
            return applyTemporaryScheduled(request, context, preview, newPriceId, secretKey);
        }
        if (preview.actionMode == 'Immediate') {
            return applyImmediate(request, context, preview, newPriceId, secretKey);
        }
        return applyScheduled(request, context, preview, newPriceId, secretKey);
    }

    /**
     * Finalizes Open or Fixed cancellation state after Stripe applies a payment-gated Price update.
     * @param request durable request whose target Price is already active in Stripe
     * @return verified immediate change result
     */
    public static ChangeResult finalizeAppliedImmediateChange(ChangeRequest request) {
        String validationError = validateLocalRequest(request);
        if (validationError != null) throw new StripeRecurringScheduleException(validationError);
        if (String.isBlank(request.targetPriceId)) {
            throw new StripeRecurringScheduleException('The pending Stripe update has no target Price to verify.');
        }
        String secretKey = getSecretKey();
        SubscriptionContext finalized = finalizeCancellationState(request, request.targetPriceId, secretKey);
        ChangeResult result = new ChangeResult();
        result.actionMode = 'Immediate';
        result.priceId = request.targetPriceId;
        result.effectiveTimestamp = System.now().getTime() / 1000;
        result.hasPendingUpdate = false;
        result.cancellationVerified = true;
        result.billingStopVerified = request.stopBillingImmediately != true || finalized.subscriptionStatus != 'trialing';
        if (request.stopBillingImmediately == true && result.billingStopVerified) {
            result.billingStoppedAt = System.now();
        }
        if (result.billingStopVerified != true) {
            throw new StripeRecurringScheduleException('Stripe did not confirm that the existing billing gap ended.');
        }
        return result;
    }

    /** Backward-compatible entry point retained for already-enqueued sandbox jobs. */
    public static ChangeResult applyFuturePhase(ChangeRequest request) {
        return applyChange(request);
    }

    private static PreviewResult basePreview(ChangeRequest request) {
        PreviewResult result = new PreviewResult();
        result.canProceed = false;
        result.requestedAmount = request == null ? null : request.amount;
        result.requestedPeriod = request == null ? null : request.transactionPeriod;
        result.requestedInterval = request == null ? null : request.transactionInterval;
        result.changeMode = request == null ? null : request.changeMode;
        result.willGenerateFullInvoice = false;
        return result;
    }

    private static void populatePreview(PreviewResult result, ChangeRequest request, SubscriptionContext context) {
        Long unitAmount = asLong(context.price.get('unit_amount'));
        result.currentAmount = unitAmount == null ? null : Decimal.valueOf(unitAmount) / 100;
        result.currentPeriod = fromStripeInterval(context.currentInterval);
        result.currentInterval = context.currentIntervalCount;
        result.originalPriceId = context.currentPriceId;
        result.originalCancelAt = context.cancelAt == null
            ? null
            : Datetime.newInstance(context.cancelAt * 1000);
        result.stripeCurrentPeriodEnd = unixDate(context.currentPeriodEnd);
        Long activePhaseStart = getActivePhaseStart(context);
        Boolean phaseAlreadyStarted = activePhaseStart != null &&
            request.effectiveDate <= unixDate(activePhaseStart);
        Boolean cadenceChanged = request.changeMode == StripeRecurringChangeMode.END_DATE_ONLY
            ? false
            : context.currentInterval != toStripeInterval(request.transactionPeriod) ||
            context.currentIntervalCount != request.transactionInterval;
        Date naturalFirstPaymentDate = cadenceChanged
            ? (request.effectiveDate > Date.today()
                ? request.effectiveDate
                : unixDate(context.currentPeriodEnd))
            : firstRenewalOnOrAfter(context.currentPeriodEnd, request.effectiveDate, request.transactionPeriod, request.transactionInterval);
        result.firstPaymentDate = request.firstPaymentDate == null
            ? naturalFirstPaymentDate
            : request.firstPaymentDate;
        Boolean billingAnchorChanged = !cadenceChanged &&
            request.changeMode == StripeRecurringChangeMode.TERMS &&
            'Monthly'.equalsIgnoreCase(request.transactionPeriod) &&
            StripeRDScheduleDateCalc.normalizeTransactionDay(request.transactionDay) != null &&
            request.firstPaymentDate != null && request.effectiveDate == request.firstPaymentDate &&
            naturalFirstPaymentDate != request.firstPaymentDate;
        result.actionMode = phaseAlreadyStarted ||
            (request.effectiveDate == Date.today() && billingAnchorChanged != true)
            ? 'Immediate'
            : 'Scheduled';
        // A changed Monthly Transaction Day is an intentional future anchor move,
        // even though Stripe's recurring interval remains month.
        result.willGenerateFullInvoice = cadenceChanged || billingAnchorChanged;
        result.requiresBillingGap = result.willGenerateFullInvoice == true && result.actionMode == 'Scheduled' &&
            result.stripeCurrentPeriodEnd != null && result.firstPaymentDate != null &&
            result.stripeCurrentPeriodEnd < result.firstPaymentDate;
        if (request.changeMode == 'TemporaryTerms') {
            StripeRDScheduleDateCalc.TemporaryWindowResult window =
                StripeRDScheduleDateCalc.calculateTemporaryWindow(
                    unixDate(context.currentPeriodEnd),
                    request.effectiveDate,
                    request.effectiveEndDate,
                    request.originalPeriod,
                    request.originalInterval,
                    request.transactionPeriod,
                    request.transactionInterval,
                    cadenceChanged
                );
            if (window.error != null) {
                throw new StripeRecurringScheduleException(window.error);
            }
            if (request.firstPaymentDate != null &&
                request.firstPaymentDate != window.firstTemporaryPaymentDate) {
                throw new StripeRecurringScheduleException(
                    'The requested first temporary payment does not match the calculated billing window.'
                );
            }
            if (request.restorationFirstPaymentDate != null &&
                request.restorationFirstPaymentDate != window.restorationFirstPaymentDate) {
                throw new StripeRecurringScheduleException(
                    'The requested restoration date does not match the original billing calendar.'
                );
            }
            result.actionMode = 'Scheduled';
            result.effectiveEndDate = request.effectiveEndDate;
            result.firstPaymentDate = window.firstTemporaryPaymentDate;
            result.lastTemporaryPaymentDate = window.lastTemporaryPaymentDate;
            result.restorationFirstPaymentDate = window.restorationFirstPaymentDate;
            result.temporaryInstallments = window.temporaryInstallments;
            result.requiresBillingGap = cadenceChanged && result.firstPaymentDate > request.effectiveDate;
            request.firstPaymentDate = result.firstPaymentDate;
            request.restorationFirstPaymentDate = result.restorationFirstPaymentDate;
        }
        result.finalPaymentDate = request.recurringType == 'Fixed'
            ? (request.finalPaymentDate == null
                ? addBillingPeriods(result.firstPaymentDate, request.transactionPeriod, request.transactionInterval, request.plannedInstallments - 1)
                : request.finalPaymentDate)
            : null;
        result.businessWarning = request.changeMode == 'TemporaryTerms'
            ? (cadenceChanged
                ? 'Stripe will collect only the calculated temporary-cadence payments inside the selected window, then resume the original cadence on its original billing calendar. No proration adjustments will be created.'
                : 'Stripe will use the temporary amount only for renewals inside the selected window, then restore the original amount without changing the renewal calendar or creating a boundary invoice.')
            : request.changeMode == StripeRecurringChangeMode.END_DATE_ONLY
            ? (request.recurringType == 'Fixed'
                ? 'Stripe will keep the existing amount, cadence, renewal date, and Price, then cancel one day after the final payment. No invoice or proration adjustment will be created.'
                : 'Stripe will keep the existing amount, cadence, renewal date, and Price and remove the cancellation so the subscription continues indefinitely.')
            : request.stopBillingImmediately == true || result.requiresBillingGap == true
            ? 'Stripe will stop the current cadence now, collect nothing during the gap, and charge the full new amount on the selected date with no refund or credit.'
            : result.willGenerateFullInvoice
            ? 'Stripe will create no charge today. It will charge the full new amount when the future cadence starts and issue no unused-time credit.'
            : 'Stripe will retain the existing renewal anchor. The amount changes now, but the next charge remains on the current renewal date.';
    }

    private static Long getActivePhaseStart(SubscriptionContext context) {
        Long activePhaseStart = context == null ? null : context.currentPeriodStart;
        if (context != null && context.schedule != null) {
            Map<String, Object> currentPhase = asMap(context.schedule.get('current_phase'));
            Long schedulePhaseStart = currentPhase == null ? null : asLong(currentPhase.get('start_date'));
            if (schedulePhaseStart != null) activePhaseStart = schedulePhaseStart;
        }
        return activePhaseStart;
    }

    private static SubscriptionContext retrieveContext(ChangeRequest request, String secretKey) {
        Map<String, Object> subscription = sendJson(
            'GET',
            '/subscriptions/' + encodePath(request.subscriptionId) + '?expand%5B%5D=schedule&expand%5B%5D=latest_invoice',
            null,
            null,
            secretKey
        );
        validateSupportedSubscription(subscription);

        SubscriptionContext context = new SubscriptionContext();
        context.subscription = subscription;
        context.item = getSingleSubscriptionItem(subscription);
        context.price = asMap(context.item.get('price'));
        Map<String, Object> recurring = context.price == null ? null : asMap(context.price.get('recurring'));
        context.itemId = asString(context.item.get('id'));
        context.currentPriceId = context.price == null ? null : asString(context.price.get('id'));
        context.currentProductId = context.price == null ? null : extractId(context.price.get('product'));
        context.productId = String.isBlank(request.productId) ? context.currentProductId : request.productId;
        context.currencyCode = String.isBlank(request.currencyIsoCode)
            ? asString(context.price.get('currency'))
            : request.currencyIsoCode.toLowerCase();
        context.currentInterval = recurring == null ? null : asString(recurring.get('interval'));
        context.currentIntervalCount = recurring == null ? null : asInteger(recurring.get('interval_count'));
        context.quantity = asInteger(context.item.get('quantity'));
        if (context.quantity == null || context.quantity < 1) context.quantity = 1;
        context.currentPeriodStart = firstLong(subscription.get('current_period_start'), context.item.get('current_period_start'));
        context.currentPeriodEnd = firstLong(subscription.get('current_period_end'), context.item.get('current_period_end'));
        context.scheduleId = extractId(subscription.get('schedule'));
        context.subscriptionStatus = asString(subscription.get('status'));
        context.trialEnd = asLong(subscription.get('trial_end'));
        context.cancelAt = asLong(subscription.get('cancel_at'));
        context.cancelAtPeriodEnd = subscription.get('cancel_at_period_end') == true;

        if (String.isBlank(context.itemId) || String.isBlank(context.currentPriceId) || String.isBlank(context.productId) ||
            String.isBlank(context.currencyCode) || String.isBlank(context.currentInterval) || context.currentIntervalCount == null ||
            context.currentPeriodStart == null || context.currentPeriodEnd == null) {
            throw new StripeRecurringScheduleException('Stripe subscription is missing required item, Price, currency, or billing-period data.');
        }

        if (String.isNotBlank(context.scheduleId)) {
            context.schedule = sendJson(
                'GET',
                '/subscription_schedules/' + encodePath(context.scheduleId),
                null,
                null,
                secretKey
            );
        }
        return context;
    }

    private static ChangeResult applyImmediate(
        ChangeRequest request,
        SubscriptionContext context,
        PreviewResult preview,
        String newPriceId,
        String secretKey
    ) {
        ChangeResult result = new ChangeResult();
        result.actionMode = 'Immediate';
        result.priceId = newPriceId;
        result.effectiveTimestamp = System.now().getTime() / 1000;
        result.hasPendingUpdate = false;
        result.cancellationVerified = false;
        result.billingStopVerified = request.stopBillingImmediately != true;

        Boolean pricingMutationRequired = newPriceId != context.currentPriceId ||
            preview.willGenerateFullInvoice || request.stopBillingImmediately == true;
        if (pricingMutationRequired) {
            List<FormValue> values = new List<FormValue>{
                new FormValue('proration_behavior', 'none'),
                new FormValue('payment_behavior', 'pending_if_incomplete'),
                new FormValue('metadata[salesforce_id]', request.salesforceGiftCommitmentId),
                new FormValue('metadata[salesforce_change_id]', request.salesforceChangeId),
                new FormValue('expand[]', 'latest_invoice')
            };
            if (newPriceId != context.currentPriceId) {
                values.add(new FormValue('items[0][id]', context.itemId));
                values.add(new FormValue('items[0][price]', newPriceId));
                values.add(new FormValue('items[0][quantity]', String.valueOf(context.quantity)));
            }
            if (preview.willGenerateFullInvoice) {
                values.add(new FormValue('billing_cycle_anchor', 'now'));
            }
            if (request.stopBillingImmediately == true) {
                values.add(new FormValue('trial_end', 'now'));
                values.add(new FormValue('metadata[' + BILLING_GAP_KEY + ']', 'false'));
            }

            Map<String, Object> updated = sendJson(
                'POST',
                '/subscriptions/' + encodePath(request.subscriptionId),
                encodeForm(values),
                request.idempotencyKey + '-subscription-price-v2',
                secretKey
            );
            Map<String, Object> pendingUpdate = asMap(updated.get('pending_update'));
            result.invoiceId = extractId(updated.get('latest_invoice'));
            result.hasPendingUpdate = pendingUpdate != null;
            Long expiration = pendingUpdate == null ? null : asLong(pendingUpdate.get('expires_at'));
            result.pendingUpdateExpiresAt = expiration == null ? null : Datetime.newInstance(expiration * 1000);
            if (result.hasPendingUpdate) return result;
        }

        SubscriptionContext finalized = finalizeCancellationState(request, newPriceId, secretKey);
        result.cancellationVerified = true;
        if (request.stopBillingImmediately == true) {
            if (finalized.subscriptionStatus == 'trialing') {
                throw new StripeRecurringScheduleException('Stripe did not confirm that the existing billing gap ended.');
            }
            result.billingStopVerified = true;
            result.billingStoppedAt = System.now();
        }
        return result;
    }

    /** Applies an Open/Fixed End Date change without touching Stripe pricing. */
    private static ChangeResult applyEndDateOnly(
        ChangeRequest request,
        SubscriptionContext context,
        PreviewResult preview,
        String secretKey
    ) {
        rejectUnownedSchedule(context, request.salesforceGiftCommitmentId);
        if (request.recurringType == 'Fixed' && request.finalPaymentDate == null) {
            throw new StripeRecurringScheduleException('A Fixed End Date change needs a calculated final payment date.');
        }

        if (context.scheduleId != null && isSapaOwned(context.schedule, request.salesforceGiftCommitmentId)) {
            updateScheduleEndBehavior(
                context.scheduleId,
                request.recurringType == 'Fixed' ? 'cancel' : 'release',
                request.idempotencyKey + '-schedule-end-behavior-v1',
                secretKey
            );
        }

        SubscriptionContext finalized = finalizeCancellationState(
            request,
            context.currentPriceId,
            secretKey
        );
        ChangeResult result = new ChangeResult();
        result.actionMode = request.effectiveDate > Date.today() ? 'Scheduled' : 'Immediate';
        result.subscriptionScheduleId = context.scheduleId;
        result.priceId = finalized.currentPriceId;
        result.effectiveTimestamp = request.finalPaymentDate == null
            ? dateAtStripeBillingTime(request.effectiveDate, finalized.currentPeriodEnd)
            : dateAtStripeBillingTime(request.finalPaymentDate, finalized.currentPeriodEnd);
        result.hasPendingUpdate = false;
        result.cancellationVerified = finalized.cancelAtPeriodEnd != true &&
            (request.recurringType == 'Fixed'
                ? finalized.cancelAt == dateAtStripeBillingTime(request.finalPaymentDate.addDays(1), finalized.currentPeriodEnd)
                : finalized.cancelAt == null);
        result.billingStopVerified = false;
        if (result.cancellationVerified != true) {
            throw new StripeRecurringScheduleException('Stripe did not confirm the requested Open or Fixed cancellation state.');
        }
        return result;
    }

    private static void updateScheduleEndBehavior(
        String scheduleId,
        String endBehavior,
        String idempotencyKey,
        String secretKey
    ) {
        sendJson(
            'POST',
            '/subscription_schedules/' + encodePath(scheduleId),
            encodeForm(new List<FormValue>{ new FormValue('end_behavior', endBehavior) }),
            idempotencyKey,
            secretKey
        );
    }

    private static ChangeResult applyScheduled(
        ChangeRequest request,
        SubscriptionContext context,
        PreviewResult preview,
        String newPriceId,
        String secretKey
    ) {
        String scheduleId = context.scheduleId;
        Long phaseStart = getActivePhaseStart(context);
        if (String.isBlank(scheduleId)) {
            Map<String, Object> created = sendJson(
                'POST',
                '/subscription_schedules',
                encodeForm(new List<FormValue>{
                    new FormValue('from_subscription', request.subscriptionId)
                }),
                request.idempotencyKey + '-schedule-bootstrap-v2',
                secretKey
            );
            scheduleId = asString(created.get('id'));
        } else if (!isSapaOwned(context.schedule, request.salesforceGiftCommitmentId)) {
            scheduleId = recoverBootstrapSchedule(request, context, secretKey);
        }
        if (String.isBlank(scheduleId)) {
            throw new StripeRecurringScheduleException('Stripe did not return a Subscription Schedule ID.');
        }

        Date verifiedBillingDate = request.firstPaymentDate == null
            ? request.effectiveDate
            : request.firstPaymentDate;
        Long effectiveTimestamp = dateAtStripeBillingTime(verifiedBillingDate, context.currentPeriodEnd);
        if (effectiveTimestamp <= phaseStart) {
            throw new StripeRecurringScheduleException('The future effective timestamp must be after the current Stripe phase start.');
        }
        Boolean cadenceChanged = context.currentInterval != toStripeInterval(request.transactionPeriod) ||
            context.currentIntervalCount != request.transactionInterval;
        Boolean billingAnchorChanged = !cadenceChanged &&
            request.changeMode == StripeRecurringChangeMode.TERMS &&
            'Monthly'.equalsIgnoreCase(request.transactionPeriod) &&
            StripeRDScheduleDateCalc.normalizeTransactionDay(request.transactionDay) != null &&
            request.firstPaymentDate != null && request.effectiveDate == request.firstPaymentDate &&
            request.firstPaymentDate != unixDate(context.currentPeriodEnd);
        Boolean zeroBridge = request.stopBillingImmediately == true &&
            request.effectiveDate > Date.today().addYears(2);
        if (zeroBridge && (context.currentPeriodEnd == null ||
            context.currentPeriodEnd >= effectiveTimestamp)) {
            throw new StripeRecurringScheduleException(
                'Stripe has no renewal boundary before the requested long billing gap.');
        }
        String bridgePriceId = zeroBridge
            ? resolveZeroBridgePriceId(request, context, secretKey)
            : null;
        Integer targetIndex = zeroBridge ? 2 : 1;
        List<FormValue> values = new List<FormValue>{
            new FormValue('end_behavior', request.recurringType == 'Fixed' ? 'cancel' : 'release'),
            new FormValue('proration_behavior', 'none'),
            new FormValue('metadata[' + SAPA_OWNER_KEY + ']', SAPA_OWNER_VALUE),
            new FormValue('metadata[salesforce_id]', request.salesforceGiftCommitmentId),
            new FormValue('metadata[salesforce_change_id]', request.salesforceChangeId),
            new FormValue('phases[0][start_date]', String.valueOf(phaseStart)),
            new FormValue('phases[0][end_date]', String.valueOf(
                zeroBridge ? context.currentPeriodEnd : effectiveTimestamp)),
            new FormValue('phases[0][items][0][price]', context.currentPriceId),
            new FormValue('phases[0][items][0][quantity]', String.valueOf(context.quantity)),
            new FormValue('phases[0][proration_behavior]', 'none'),
            new FormValue('phases[0][metadata][salesforce_change_id]', ''),
            new FormValue('phases[' + targetIndex + '][start_date]', String.valueOf(effectiveTimestamp)),
            new FormValue('phases[' + targetIndex + '][items][0][price]', newPriceId),
            new FormValue('phases[' + targetIndex + '][items][0][quantity]', String.valueOf(context.quantity)),
            new FormValue('phases[' + targetIndex + '][billing_cycle_anchor]',
                cadenceChanged || billingAnchorChanged ? 'phase_start' : 'automatic'),
            new FormValue('phases[' + targetIndex + '][proration_behavior]', 'none'),
            new FormValue('phases[' + targetIndex + '][metadata][' + SAPA_OWNER_KEY + ']', SAPA_OWNER_VALUE),
            new FormValue('phases[' + targetIndex + '][metadata][salesforce_id]', request.salesforceGiftCommitmentId),
            new FormValue('phases[' + targetIndex + '][metadata][salesforce_change_id]', request.salesforceChangeId),
            new FormValue('phases[' + targetIndex + '][metadata][' + BILLING_GAP_KEY + ']', 'false')
        };
        if (zeroBridge) {
            Boolean retainTrial = context.subscriptionStatus == 'trialing' && context.trialEnd != null;
            if (retainTrial) {
                values.add(new FormValue('phases[0][trial_end]', String.valueOf(context.trialEnd)));
                values.add(new FormValue('phases[0][metadata][sapa_billing_gap_change_id]', request.salesforceChangeId));
            }
            values.add(new FormValue('phases[0][metadata][' + BILLING_GAP_KEY + ']', retainTrial ? 'true' : 'false'));
            values.add(new FormValue('phases[1][start_date]', String.valueOf(context.currentPeriodEnd)));
            values.add(new FormValue('phases[1][end_date]', String.valueOf(effectiveTimestamp)));
            values.add(new FormValue('phases[1][items][0][price]', bridgePriceId));
            values.add(new FormValue('phases[1][items][0][quantity]', String.valueOf(context.quantity)));
            values.add(new FormValue('phases[1][billing_cycle_anchor]', 'phase_start'));
            values.add(new FormValue('phases[1][proration_behavior]', 'none'));
            values.add(new FormValue('phases[1][metadata][' + SAPA_OWNER_KEY + ']', SAPA_OWNER_VALUE));
            values.add(new FormValue('phases[1][metadata][salesforce_id]', request.salesforceGiftCommitmentId));
            values.add(new FormValue('phases[1][metadata][salesforce_change_id]', ''));
            values.add(new FormValue('phases[1][metadata][sapa_billing_gap_change_id]', request.salesforceChangeId));
            values.add(new FormValue('phases[1][metadata][' + BILLING_GAP_KEY + ']', 'true'));
        } else if (request.stopBillingImmediately == true) {
            values.add(new FormValue('metadata[' + BILLING_GAP_KEY + ']', 'true'));
            values.add(new FormValue('phases[0][trial_end]', String.valueOf(effectiveTimestamp)));
            values.add(new FormValue('phases[0][metadata][' + BILLING_GAP_KEY + ']', 'true'));
            values.add(new FormValue('phases[0][metadata][sapa_billing_gap_change_id]', request.salesforceChangeId));
        }
        if (request.recurringType == 'Fixed') {
            Long cancelTimestamp = dateAtStripeBillingTime(preview.finalPaymentDate.addDays(1), context.currentPeriodEnd);
            values.add(new FormValue('phases[' + targetIndex + '][end_date]', String.valueOf(cancelTimestamp)));
        }

        sendJson(
            'POST',
            '/subscription_schedules/' + encodePath(scheduleId),
            encodeForm(values),
            request.idempotencyKey + '-schedule-configure-v4',
            secretKey
        );

        verifyScheduledChange(request, scheduleId, newPriceId, effectiveTimestamp, secretKey);
        if (zeroBridge) {
            verifyZeroBridge(request, context, scheduleId, bridgePriceId, effectiveTimestamp, secretKey);
        }

        ChangeResult result = new ChangeResult();
        result.actionMode = 'Scheduled';
        result.subscriptionScheduleId = scheduleId;
        result.priceId = newPriceId;
        result.effectiveTimestamp = effectiveTimestamp;
        result.hasPendingUpdate = false;
        result.billingStopVerified = false;
        if (zeroBridge) {
            result.billingStopVerified = true;
        } else if (request.stopBillingImmediately == true) {
            verifyBillingGap(request, context, scheduleId, newPriceId, effectiveTimestamp, secretKey);
            result.billingStopVerified = true;
            result.billingStoppedAt = System.now();
        }
        return result;
    }

    private static ChangeResult applyTemporaryScheduled(
        ChangeRequest request,
        SubscriptionContext context,
        PreviewResult preview,
        String targetPriceId,
        String secretKey
    ) {
        Map<String, Object> originalPrice = request.originalPriceId == context.currentPriceId
            ? context.price
            : retrievePrice(request.originalPriceId, secretKey);
        if (!priceMatchesOriginal(originalPrice, request, context)) {
            throw new StripeRecurringScheduleException(
                'The stored original Stripe Price does not match the terms that must be restored.'
            );
        }

        String scheduleId = context.scheduleId;
        Long activePhaseStart = getActivePhaseStart(context);
        if (String.isBlank(scheduleId)) {
            Map<String, Object> created = sendJson(
                'POST',
                '/subscription_schedules',
                encodeForm(new List<FormValue>{ new FormValue('from_subscription', request.subscriptionId) }),
                request.idempotencyKey + '-temporary-schedule-bootstrap-v1',
                secretKey
            );
            scheduleId = asString(created.get('id'));
        } else if (!isSapaOwned(context.schedule, request.salesforceGiftCommitmentId)) {
            throw externalScheduleException();
        }
        if (String.isBlank(scheduleId)) {
            throw new StripeRecurringScheduleException('Stripe did not return a Subscription Schedule ID.');
        }

        Long effectiveTimestamp = dateAtStripeBillingTime(request.effectiveDate, context.currentPeriodEnd);
        Long targetTimestamp = dateAtStripeBillingTime(preview.firstPaymentDate, context.currentPeriodEnd);
        Long restoreConfigurationTimestamp = dateAtStripeBillingTime(
            request.effectiveEndDate.addDays(1), context.currentPeriodEnd
        );
        Long restorationPaymentTimestamp = dateAtStripeBillingTime(
            preview.restorationFirstPaymentDate, context.currentPeriodEnd
        );
        if (effectiveTimestamp <= activePhaseStart || targetTimestamp < effectiveTimestamp ||
            restoreConfigurationTimestamp <= targetTimestamp ||
            restorationPaymentTimestamp < restoreConfigurationTimestamp) {
            throw new StripeRecurringScheduleException('The temporary Stripe phase boundaries are invalid.');
        }

        Boolean cadenceChanged = context.currentInterval != toStripeInterval(request.transactionPeriod) ||
            context.currentIntervalCount != request.transactionInterval;
        List<FormValue> values = new List<FormValue>{
            new FormValue('end_behavior', request.originalCancelAt == null ? 'release' : 'cancel'),
            new FormValue('proration_behavior', 'none'),
            new FormValue('metadata[' + SAPA_OWNER_KEY + ']', SAPA_OWNER_VALUE),
            new FormValue('metadata[salesforce_id]', request.salesforceGiftCommitmentId),
            new FormValue('metadata[salesforce_change_id]', request.salesforceChangeId)
        };

        Integer phaseIndex = 0;
        addSchedulePhase(
            values, phaseIndex, activePhaseStart,
            targetTimestamp > effectiveTimestamp ? effectiveTimestamp : targetTimestamp,
            context.currentPriceId, context.quantity, 'automatic', false,
            'current', request.salesforceGiftCommitmentId, request.salesforceChangeId
        );
        phaseIndex++;
        if (targetTimestamp > effectiveTimestamp) {
            addSchedulePhase(
                values, phaseIndex, effectiveTimestamp, targetTimestamp,
                context.currentPriceId, context.quantity, 'automatic', true,
                'target_bridge', request.salesforceGiftCommitmentId, request.salesforceChangeId
            );
            phaseIndex++;
        }

        addSchedulePhase(
            values, phaseIndex, targetTimestamp, restoreConfigurationTimestamp,
            targetPriceId, context.quantity, cadenceChanged ? 'phase_start' : 'automatic', false,
            'target', request.salesforceGiftCommitmentId, request.salesforceChangeId
        );
        phaseIndex++;

        if (cadenceChanged && restorationPaymentTimestamp > restoreConfigurationTimestamp) {
            addSchedulePhase(
                values, phaseIndex, restoreConfigurationTimestamp, restorationPaymentTimestamp,
                request.originalPriceId, context.quantity, 'automatic', true,
                'restore_bridge', request.salesforceGiftCommitmentId, request.salesforceChangeId
            );
            phaseIndex++;
        }

        Long restoredPhaseStart = cadenceChanged
            ? restorationPaymentTimestamp
            : restoreConfigurationTimestamp;
        Long restoredPhaseEnd = request.originalCancelAt != null && request.originalCancelAt > restoredPhaseStart
            ? request.originalCancelAt
            : null;
        addSchedulePhase(
            values, phaseIndex, restoredPhaseStart, restoredPhaseEnd,
            request.originalPriceId, context.quantity, cadenceChanged ? 'phase_start' : 'automatic', false,
            'restored', request.salesforceGiftCommitmentId, request.salesforceChangeId
        );

        sendJson(
            'POST',
            '/subscription_schedules/' + encodePath(scheduleId),
            encodeForm(values),
            request.idempotencyKey + '-temporary-schedule-configure-v1',
            secretKey
        );
        verifyTemporaryScheduledChange(
            request, scheduleId, targetPriceId, targetTimestamp,
            request.originalPriceId, restoredPhaseStart, secretKey
        );

        ChangeResult result = new ChangeResult();
        result.actionMode = 'Scheduled';
        result.subscriptionScheduleId = scheduleId;
        result.priceId = targetPriceId;
        result.effectiveTimestamp = targetTimestamp;
        result.restorationEffectiveTimestamp = restoredPhaseStart;
        result.hasPendingUpdate = false;
        result.billingStopVerified = false;
        return result;
    }

    private static void addSchedulePhase(
        List<FormValue> values,
        Integer index,
        Long startTimestamp,
        Long endTimestamp,
        String priceId,
        Integer quantity,
        String billingCycleAnchor,
        Boolean trialBridge,
        String phaseRole,
        String giftCommitmentId,
        String changeId
    ) {
        String prefix = 'phases[' + index + ']';
        values.add(new FormValue(prefix + '[start_date]', String.valueOf(startTimestamp)));
        if (endTimestamp != null) values.add(new FormValue(prefix + '[end_date]', String.valueOf(endTimestamp)));
        values.add(new FormValue(prefix + '[items][0][price]', priceId));
        values.add(new FormValue(prefix + '[items][0][quantity]', String.valueOf(quantity)));
        values.add(new FormValue(prefix + '[billing_cycle_anchor]', billingCycleAnchor));
        values.add(new FormValue(prefix + '[proration_behavior]', 'none'));
        values.add(new FormValue(prefix + '[metadata][' + SAPA_OWNER_KEY + ']', SAPA_OWNER_VALUE));
        values.add(new FormValue(prefix + '[metadata][salesforce_id]', giftCommitmentId));
        values.add(new FormValue(prefix + '[metadata][salesforce_change_id]', changeId));
        values.add(new FormValue(prefix + '[metadata][' + PHASE_ROLE_KEY + ']', phaseRole));
        if (trialBridge == true) {
            values.add(new FormValue(prefix + '[trial_end]', String.valueOf(endTimestamp)));
            values.add(new FormValue(prefix + '[metadata][' + BILLING_GAP_KEY + ']', 'true'));
        }
    }

    private static void verifyBillingGap(
        ChangeRequest request,
        SubscriptionContext original,
        String scheduleId,
        String targetPriceId,
        Long effectiveTimestamp,
        String secretKey
    ) {
        SubscriptionContext verified = retrieveContext(request, secretKey);
        if (verified.subscriptionStatus != 'trialing' || verified.trialEnd != effectiveTimestamp ||
            verified.scheduleId != scheduleId || verified.itemId != original.itemId) {
            throw new StripeRecurringScheduleException('Stripe did not confirm that the no-charge billing bridge is active.');
        }
        Map<String, Object> schedule = verified.schedule;
        List<Object> phases = schedule == null ? null : (List<Object>) schedule.get('phases');
        if (phases == null || phases.size() < 2) {
            throw new StripeRecurringScheduleException('Stripe did not confirm the future billing phase.');
        }
        Map<String, Object> bridge = asMap(phases[0]);
        Map<String, Object> target = asMap(phases[phases.size() - 1]);
        Map<String, Object> bridgeMetadata = bridge == null ? null : asMap(bridge.get('metadata'));
        List<Object> targetItems = target == null ? null : (List<Object>) target.get('items');
        String verifiedTargetPrice = null;
        if (targetItems != null && targetItems.size() == 1) {
            verifiedTargetPrice = extractId(asMap(targetItems[0]).get('price'));
        }
        if (bridge == null || asLong(bridge.get('trial_end')) != effectiveTimestamp ||
            bridgeMetadata == null || asString(bridgeMetadata.get(BILLING_GAP_KEY)) != 'true' ||
            target == null || asLong(target.get('start_date')) != effectiveTimestamp ||
            verifiedTargetPrice != targetPriceId) {
            throw new StripeRecurringScheduleException('Stripe verification found a different billing-gap or target-phase configuration.');
        }
    }

    /** Reuses a SAPA-owned zero Price from an existing gap, or creates it idempotently. */
    private static String resolveZeroBridgePriceId(ChangeRequest request,
                                                    SubscriptionContext context,
                                                    String secretKey) {
        if (context.schedule != null &&
            isSapaOwned(context.schedule, request.salesforceGiftCommitmentId)) {
            List<Object> phases = (List<Object>) context.schedule.get('phases');
            if (phases != null) {
                for (Object phaseValue : phases) {
                    Map<String,Object> phase = asMap(phaseValue);
                    Map<String,Object> metadata = phase == null ? null : asMap(phase.get('metadata'));
                    if (metadata == null || asString(metadata.get(BILLING_GAP_KEY)) != 'true') continue;
                    List<Object> items = (List<Object>) phase.get('items');
                    Map<String,Object> item = items == null || items.size() != 1
                        ? null : asMap(items[0]);
                    String existingPriceId = item == null ? null : extractId(item.get('price'));
                    if (String.isBlank(existingPriceId)) continue;
                    Map<String,Object> price = retrievePrice(existingPriceId, secretKey);
                    if (isZeroBridgePrice(price, context)) return existingPriceId;
                }
            }
        }
        Map<String,Object> created = sendJson(
            'POST', '/prices',
            encodeForm(new List<FormValue>{
                new FormValue('product', context.productId),
                new FormValue('currency', context.currencyCode),
                new FormValue('unit_amount', '0'),
                new FormValue('recurring[interval]', 'year'),
                new FormValue('recurring[interval_count]', '1'),
                new FormValue('metadata[' + SAPA_OWNER_KEY + ']', SAPA_OWNER_VALUE),
                new FormValue('metadata[' + BILLING_GAP_KEY + ']', 'true'),
                new FormValue('metadata[salesforce_id]', request.salesforceGiftCommitmentId)
            }),
            request.idempotencyKey + '-zero-bridge-price-v1', secretKey
        );
        String zeroPriceId = asString(created.get('id'));
        if (String.isBlank(zeroPriceId)) {
            throw new StripeRecurringScheduleException('Stripe did not return the no-charge bridge Price.');
        }
        return zeroPriceId;
    }

    private static Boolean isZeroBridgePrice(Map<String,Object> price, SubscriptionContext context) {
        Map<String,Object> recurring = price == null ? null : asMap(price.get('recurring'));
        return price != null && recurring != null && asLong(price.get('unit_amount')) == 0 &&
            asString(price.get('currency')) == context.currencyCode &&
            extractId(price.get('product')) == context.productId &&
            asString(recurring.get('interval')) == 'year' &&
            asInteger(recurring.get('interval_count')) == 1;
    }

    /** Confirms both the no-charge phase and the original subscription item are preserved. */
    private static void verifyZeroBridge(ChangeRequest request, SubscriptionContext original,
                                         String scheduleId, String zeroPriceId,
                                         Long targetTimestamp, String secretKey) {
        SubscriptionContext verified = retrieveContext(request, secretKey);
        if (verified.scheduleId != scheduleId || verified.itemId != original.itemId ||
            !isSapaOwned(verified.schedule, request.salesforceGiftCommitmentId)) {
            throw new StripeRecurringScheduleException('Stripe did not preserve the SAPA schedule and subscription item.');
        }
        List<Object> phases = verified.schedule == null
            ? null : (List<Object>) verified.schedule.get('phases');
        if (phases == null || phases.size() != 3) {
            throw new StripeRecurringScheduleException('Stripe did not confirm the three-phase long billing gap.');
        }
        Map<String,Object> current = asMap(phases[0]);
        Map<String,Object> bridge = asMap(phases[1]);
        Map<String,Object> target = asMap(phases[2]);
        if (original.subscriptionStatus == 'trialing' && original.trialEnd != null &&
            (verified.trialEnd != original.trialEnd || current == null ||
             asLong(current.get('trial_end')) != original.trialEnd)) {
            throw new StripeRecurringScheduleException('Stripe did not preserve the existing no-charge trial before the zero-Price bridge.');
        }
        Map<String,Object> bridgeMetadata = bridge == null ? null : asMap(bridge.get('metadata'));
        List<Object> bridgeItems = bridge == null ? null : (List<Object>) bridge.get('items');
        Map<String,Object> bridgeItem = bridgeItems == null || bridgeItems.size() != 1
            ? null : asMap(bridgeItems[0]);
        if (current == null || asLong(current.get('end_date')) != original.currentPeriodEnd ||
            bridge == null || asLong(bridge.get('start_date')) != original.currentPeriodEnd ||
            asLong(bridge.get('end_date')) != targetTimestamp ||
            bridgeMetadata == null || asString(bridgeMetadata.get(BILLING_GAP_KEY)) != 'true' ||
            bridgeItem == null || extractId(bridgeItem.get('price')) != zeroPriceId ||
            !isZeroBridgePrice(retrievePrice(zeroPriceId, secretKey), original) ||
            target == null || asLong(target.get('start_date')) != targetTimestamp) {
            throw new StripeRecurringScheduleException('Stripe verification found a different no-charge bridge.');
        }
    }

    private static String createReusablePrice(ChangeRequest request, SubscriptionContext context, String secretKey) {
        Map<String, Object> created = sendJson(
            'POST',
            '/prices',
            encodeForm(new List<FormValue>{
                new FormValue('product', context.productId),
                new FormValue('currency', context.currencyCode),
                new FormValue('unit_amount', String.valueOf(toMinorUnits(request.amount))),
                new FormValue('recurring[interval]', toStripeInterval(request.transactionPeriod)),
                new FormValue('recurring[interval_count]', String.valueOf(request.transactionInterval)),
                new FormValue('metadata[' + SAPA_OWNER_KEY + ']', SAPA_OWNER_VALUE),
                new FormValue('metadata[salesforce_id]', request.salesforceGiftCommitmentId),
                new FormValue('metadata[salesforce_change_id]', request.salesforceChangeId)
            }),
            request.idempotencyKey + '-price',
            secretKey
        );
        String priceId = asString(created.get('id'));
        if (String.isBlank(priceId)) {
            throw new StripeRecurringScheduleException('Stripe did not return the reusable Price ID.');
        }
        return priceId;
    }

    private static Boolean priceMatchesRequest(
        Map<String, Object> price,
        ChangeRequest request,
        SubscriptionContext context
    ) {
        if (price == null) return false;
        Map<String, Object> recurring = asMap(price.get('recurring'));
        if (recurring == null) return false;
        String priceCurrencyCode = asString(price.get('currency'));
        return asLong(price.get('unit_amount')) == toMinorUnits(request.amount) &&
            String.isNotBlank(priceCurrencyCode) && priceCurrencyCode.toLowerCase() == context.currencyCode &&
            extractId(price.get('product')) == context.productId &&
            asString(recurring.get('interval')) == toStripeInterval(request.transactionPeriod) &&
            asInteger(recurring.get('interval_count')) == request.transactionInterval;
    }

    private static Boolean priceMatchesOriginal(
        Map<String, Object> price,
        ChangeRequest request,
        SubscriptionContext context
    ) {
        if (price == null) return false;
        Map<String, Object> recurring = asMap(price.get('recurring'));
        if (recurring == null) return false;
        String priceCurrencyCode = asString(price.get('currency'));
        return asLong(price.get('unit_amount')) == toMinorUnits(request.originalAmount) &&
            String.isNotBlank(priceCurrencyCode) && priceCurrencyCode.toLowerCase() == context.currencyCode &&
            extractId(price.get('product')) == context.productId &&
            asString(recurring.get('interval')) == toStripeInterval(request.originalPeriod) &&
            asInteger(recurring.get('interval_count')) == request.originalInterval;
    }

    private static Map<String, Object> retrievePrice(String priceId, String secretKey) {
        return sendJson(
            'GET',
            '/prices/' + encodePath(priceId),
            null,
            null,
            secretKey
        );
    }

    private static String findMatchingScheduledPriceId(
        ChangeRequest request,
        SubscriptionContext context,
        String secretKey
    ) {
        if (context.schedule == null ||
            !isSapaOwned(context.schedule, request.salesforceGiftCommitmentId)) {
            return null;
        }
        List<Object> phases = (List<Object>) context.schedule.get('phases');
        if (phases == null || phases.isEmpty()) return null;
        Map<String, Object> currentPhase = asMap(context.schedule.get('current_phase'));
        Long futureBoundary = currentPhase == null
            ? context.currentPeriodEnd
            : asLong(currentPhase.get('end_date'));
        for (Integer index = phases.size() - 1; index >= 0; index--) {
            Map<String, Object> phase = asMap(phases[index]);
            Long phaseStart = phase == null ? null : asLong(phase.get('start_date'));
            if (phaseStart == null ||
                (futureBoundary != null && phaseStart < futureBoundary)) {
                continue;
            }
            List<Object> items = (List<Object>) phase.get('items');
            Map<String, Object> item = items == null || items.size() != 1
                ? null
                : asMap(items[0]);
            String priceId = item == null ? null : extractId(item.get('price'));
            if (String.isBlank(priceId)) continue;
            Map<String, Object> price = asMap(item.get('price'));
            if (price == null || price.get('unit_amount') == null || price.get('recurring') == null) {
                price = retrievePrice(priceId, secretKey);
            }
            if (priceMatchesRequest(price, request, context)) return priceId;
        }
        return null;
    }

    private static String resolveTargetPriceId(
        ChangeRequest request,
        SubscriptionContext context,
        String secretKey
    ) {
        if (String.isNotBlank(request.targetPriceId)) {
            Map<String, Object> storedTarget = retrievePrice(request.targetPriceId, secretKey);
            if (!priceMatchesRequest(storedTarget, request, context)) {
                throw new StripeRecurringScheduleException(
                    'The stored target Stripe Price does not match the requested amount and cadence.'
                );
            }
            return request.targetPriceId;
        }
        if (priceMatchesRequest(context.price, request, context)) {
            return context.currentPriceId;
        }
        String scheduledPriceId = findMatchingScheduledPriceId(request, context, secretKey);
        return String.isNotBlank(scheduledPriceId)
            ? scheduledPriceId
            : createReusablePrice(request, context, secretKey);
    }

    private static void releaseOwnedSchedule(String scheduleId, String idempotencyKey, String secretKey) {
        sendJson(
            'POST',
            '/subscription_schedules/' + encodePath(scheduleId) + '/release',
            encodeForm(new List<FormValue>{ new FormValue('preserve_cancel_date', 'false') }),
            idempotencyKey + '-schedule-release',
            secretKey
        );
    }

    private static SubscriptionContext finalizeCancellationState(
        ChangeRequest request,
        String targetPriceId,
        String secretKey
    ) {
        SubscriptionContext context = retrieveContext(request, secretKey);
        rejectUnownedSchedule(context, request.salesforceGiftCommitmentId);
        if (context.currentPriceId != targetPriceId) {
            throw new StripeRecurringScheduleException('Stripe did not confirm the requested Price on the existing subscription item.');
        }

        if (context.cancelAtPeriodEnd == true) {
            updateCancellation(
                request,
                new FormValue('cancel_at_period_end', 'false'),
                request.idempotencyKey + '-subscription-cancel-period-v2',
                secretKey
            );
            context = retrieveContext(request, secretKey);
        }

        Long desiredCancelAt = request.recurringType == 'Fixed'
            ? dateAtStripeBillingTime(request.finalPaymentDate.addDays(1), context.currentPeriodEnd)
            : null;
        if (context.cancelAt != desiredCancelAt) {
            updateCancellation(
                request,
                new FormValue('cancel_at', desiredCancelAt == null ? '' : String.valueOf(desiredCancelAt)),
                request.idempotencyKey + '-subscription-cancel-custom-v2',
                secretKey
            );
            context = retrieveContext(request, secretKey);
        }

        Boolean cancellationMatches = context.cancelAtPeriodEnd != true &&
            (request.recurringType == 'Fixed' ? context.cancelAt == desiredCancelAt : context.cancelAt == null);
        if (!cancellationMatches || context.currentPriceId != targetPriceId) {
            throw new StripeRecurringScheduleException('Stripe did not confirm the requested Open or Fixed cancellation state.');
        }
        return context;
    }

    private static void updateCancellation(
        ChangeRequest request,
        FormValue cancellationValue,
        String idempotencyKey,
        String secretKey
    ) {
        sendJson(
            'POST',
            '/subscriptions/' + encodePath(request.subscriptionId),
            encodeForm(new List<FormValue>{
                new FormValue('proration_behavior', 'none'),
                cancellationValue
            }),
            idempotencyKey,
            secretKey
        );
    }

    private static String recoverBootstrapSchedule(
        ChangeRequest request,
        SubscriptionContext context,
        String secretKey
    ) {
        if (hasMetadata(context.schedule)) {
            throw externalScheduleException();
        }
        try {
            Map<String, Object> replayed = sendJson(
                'POST',
                '/subscription_schedules',
                encodeForm(new List<FormValue>{ new FormValue('from_subscription', request.subscriptionId) }),
                request.idempotencyKey + '-schedule-bootstrap-v2',
                secretKey
            );
            String replayedId = asString(replayed.get('id'));
            if (replayedId == context.scheduleId) return replayedId;
        } catch (Exception ignored) {
        }
        throw externalScheduleException();
    }

    private static void verifyScheduledChange(
        ChangeRequest request,
        String scheduleId,
        String targetPriceId,
        Long effectiveTimestamp,
        String secretKey
    ) {
        Map<String, Object> schedule = sendJson(
            'GET',
            '/subscription_schedules/' + encodePath(scheduleId),
            null,
            null,
            secretKey
        );
        if (asString(schedule.get('id')) != scheduleId || extractId(schedule.get('subscription')) != request.subscriptionId ||
            !isSapaOwned(schedule, request.salesforceGiftCommitmentId)) {
            throw new StripeRecurringScheduleException('Stripe did not confirm SAPA ownership of the requested Subscription Schedule.');
        }
        List<Object> phases = (List<Object>) schedule.get('phases');
        if (phases == null) {
            throw new StripeRecurringScheduleException('Stripe did not confirm the future billing phase.');
        }
        for (Object phaseValue : phases) {
            Map<String, Object> phase = asMap(phaseValue);
            if (phase == null || asLong(phase.get('start_date')) != effectiveTimestamp) continue;
            List<Object> items = (List<Object>) phase.get('items');
            Map<String, Object> item = items == null || items.size() != 1 ? null : asMap(items[0]);
            Map<String, Object> metadata = asMap(phase.get('metadata'));
            if (item != null && extractId(item.get('price')) == targetPriceId &&
                asInteger(item.get('quantity')) != null &&
                metadata != null && asString(metadata.get('salesforce_change_id')) == request.salesforceChangeId) {
                return;
            }
        }
        throw new StripeRecurringScheduleException('Stripe verification found a different future billing phase.');
    }

    private static void verifyTemporaryScheduledChange(
        ChangeRequest request,
        String scheduleId,
        String targetPriceId,
        Long targetTimestamp,
        String originalPriceId,
        Long restoredTimestamp,
        String secretKey
    ) {
        Map<String, Object> schedule = sendJson(
            'GET', '/subscription_schedules/' + encodePath(scheduleId), null, null, secretKey
        );
        if (asString(schedule.get('id')) != scheduleId ||
            extractId(schedule.get('subscription')) != request.subscriptionId ||
            !isSapaOwned(schedule, request.salesforceGiftCommitmentId)) {
            throw new StripeRecurringScheduleException(
                'Stripe did not confirm SAPA ownership of the temporary Subscription Schedule.'
            );
        }
        Boolean targetVerified = false;
        Boolean restorationVerified = false;
        List<Object> phases = (List<Object>) schedule.get('phases');
        if (phases != null) {
            for (Object phaseValue : phases) {
                Map<String, Object> phase = asMap(phaseValue);
                Map<String, Object> metadata = phase == null ? null : asMap(phase.get('metadata'));
                List<Object> items = phase == null ? null : (List<Object>) phase.get('items');
                Map<String, Object> item = items == null || items.size() != 1 ? null : asMap(items[0]);
                String phasePriceId = item == null ? null : extractId(item.get('price'));
                String role = metadata == null ? null : asString(metadata.get(PHASE_ROLE_KEY));
                if (asLong(phase == null ? null : phase.get('start_date')) == targetTimestamp &&
                    phasePriceId == targetPriceId && role == 'target') {
                    targetVerified = true;
                }
                if (asLong(phase == null ? null : phase.get('start_date')) == restoredTimestamp &&
                    phasePriceId == originalPriceId && role == 'restored') {
                    restorationVerified = true;
                }
            }
        }
        if (!targetVerified || !restorationVerified) {
            throw new StripeRecurringScheduleException(
                'Stripe verification found a different temporary or restoration phase.'
            );
        }
    }

    private static void rejectUnownedSchedule(SubscriptionContext context, String giftCommitmentId) {
        if (context != null && String.isNotBlank(context.scheduleId) && !isSapaOwned(context.schedule, giftCommitmentId)) {
            throw externalScheduleException();
        }
    }

    private static Boolean hasMetadata(Map<String, Object> schedule) {
        Map<String, Object> metadata = schedule == null ? null : asMap(schedule.get('metadata'));
        return metadata != null && !metadata.isEmpty();
    }

    private static StripeRecurringScheduleException externalScheduleException() {
        return new StripeRecurringScheduleException(
            'This subscription has an externally managed Stripe Subscription Schedule and cannot be changed from Salesforce.'
        );
    }

    private static String validateLocalRequest(ChangeRequest request) {
        if (request == null || String.isBlank(request.subscriptionId) || request.amount == null || request.amount <= 0 ||
            request.effectiveDate == null || String.isBlank(request.transactionPeriod) || request.transactionInterval == null ||
            request.transactionInterval < 1 || String.isBlank(request.idempotencyKey) || String.isBlank(request.recurringType)) {
            return 'Incomplete recurring schedule change request.';
        }
        if (request.effectiveDate < Date.today()) {
            return 'The Stripe change effective date cannot be in the past.';
        }
        if (request.firstPaymentDate != null && request.firstPaymentDate < Date.today()) {
            return 'The first Stripe payment date cannot be in the past.';
        }
        if (request.firstPaymentDate != null && request.firstPaymentDate < request.effectiveDate) {
            return 'The first Stripe payment date cannot be before the configuration effective date.';
        }
        if (request.finalPaymentDate != null && request.firstPaymentDate != null &&
            request.finalPaymentDate < request.firstPaymentDate) {
            return 'The final Stripe payment date cannot be before the first payment date.';
        }
        if (request.recurringType != 'Open' && request.recurringType != 'Fixed') {
            return 'Recurring type must be Open or Fixed.';
        }
        if (request.changeMode == StripeRecurringChangeMode.TERMS &&
            'Monthly'.equalsIgnoreCase(request.transactionPeriod) &&
            StripeRDScheduleDateCalc.normalizeTransactionDay(request.transactionDay) == null) {
            return 'Transaction Day is required for Monthly and must be a permitted day.';
        }
        if (request.changeMode == 'TemporaryTerms') {
            if (request.effectiveEndDate == null || request.effectiveEndDate < request.effectiveDate ||
                request.originalAmount == null || request.originalAmount <= 0 ||
                String.isBlank(request.originalPeriod) || request.originalInterval == null ||
                request.originalInterval < 1 || String.isBlank(request.originalPriceId)) {
                return 'A temporary terms request needs valid window dates and a complete original billing snapshot.';
            }
            toStripeInterval(request.originalPeriod);
        }
        if (request.recurringType == 'Fixed' && (request.plannedInstallments == null || request.plannedInstallments < 1)) {
            if (request.finalPaymentDate == null) {
                return 'A Fixed recurring donation needs a valid first and final payment date.';
            }
            if (request.firstPaymentDate != null) {
                StripeRDScheduleDateCalc.Result dateResult =
                    StripeRDScheduleDateCalc.calculate(
                        request.firstPaymentDate,
                        request.finalPaymentDate,
                        request.firstPaymentDate.addDays(-1),
                        request.transactionPeriod,
                        request.transactionInterval,
                        'Fixed'
                    );
                if (dateResult.error != null) return dateResult.error;
                request.plannedInstallments = dateResult.installments;
                request.finalPaymentDate = dateResult.finalPaymentDate;
            }
        }
        toStripeInterval(request.transactionPeriod);
        return null;
    }

    private static Boolean isTrialBridgeEnabled() {
        if (trialBridgeEnabledOverride != null) return trialBridgeEnabledOverride;
        Stripe_Recurring_Sync_Config__mdt config = StripeRecurringSyncConfig.resolve();
        return config != null && config.Trial_Bridge_Enabled__c == true;
    }

    private static void validateSupportedSubscription(Map<String, Object> subscription) {
        String status = asString(subscription.get('status'));
        if (status != 'active' && status != 'trialing') {
            throw new StripeRecurringScheduleException('Only active or trialing Stripe subscriptions can be changed.');
        }
        if (asString(subscription.get('collection_method')) != 'charge_automatically') {
            throw new StripeRecurringScheduleException('Only automatically charged Stripe subscriptions are supported.');
        }
        Map<String, Object> paymentSettings = asMap(subscription.get('payment_settings'));
        List<Object> paymentTypes = paymentSettings == null ? null : (List<Object>) paymentSettings.get('payment_method_types');
        if (paymentTypes != null) {
            for (Object paymentType : paymentTypes) {
                String typeName = asString(paymentType);
                if (typeName != 'card' && typeName != 'link') {
                    throw new StripeRecurringScheduleException('This Stripe payment method does not support payment-gated subscription updates.');
                }
            }
        }
    }

    private static Map<String, Object> getSingleSubscriptionItem(Map<String, Object> subscription) {
        Map<String, Object> items = asMap(subscription.get('items'));
        List<Object> data = items == null ? null : (List<Object>) items.get('data');
        if (data == null || data.size() != 1) {
            throw new StripeRecurringScheduleException('Stripe subscription must contain exactly one recurring item.');
        }
        return asMap(data[0]);
    }

    private static Boolean isSapaOwned(Map<String, Object> schedule, String giftCommitmentId) {
        Map<String, Object> metadata = schedule == null ? null : asMap(schedule.get('metadata'));
        if (metadata == null) return false;
        if (asString(metadata.get(SAPA_OWNER_KEY)) == SAPA_OWNER_VALUE) return true;
        return String.isNotBlank(giftCommitmentId) && asString(metadata.get('salesforce_id')) == giftCommitmentId;
    }

    private static Date firstRenewalOnOrAfter(Long currentPeriodEnd, Date effectiveDate, String period, Integer intervalCount) {
        Date renewalDate = unixDate(currentPeriodEnd);
        Integer guard = 0;
        while (renewalDate < effectiveDate && guard < 600) {
            renewalDate = addBillingPeriods(renewalDate, period, intervalCount, 1);
            guard++;
        }
        if (renewalDate < effectiveDate) {
            throw new StripeRecurringScheduleException('Unable to calculate the first Stripe renewal after the effective date.');
        }
        return renewalDate;
    }

    public static Date addBillingPeriods(Date startDate, String period, Integer intervalCount, Integer periods) {
        if (startDate == null || intervalCount == null || periods == null) return null;
        Integer totalIntervals = intervalCount * periods;
        if (period == 'Daily') return startDate.addDays(totalIntervals);
        if (period == 'Weekly') return startDate.addDays(totalIntervals * 7);
        if (period == 'Monthly') return startDate.addMonths(totalIntervals);
        if (period == 'Yearly') return startDate.addYears(totalIntervals);
        throw new StripeRecurringScheduleException('Unsupported recurring period.');
    }

    private static String fromStripeInterval(String intervalName) {
        if (intervalName == 'day') return 'Daily';
        if (intervalName == 'week') return 'Weekly';
        if (intervalName == 'month') return 'Monthly';
        if (intervalName == 'year') return 'Yearly';
        return intervalName;
    }

    private static Long dateAtStripeBillingTime(Date targetDate, Long referenceTimestamp) {
        Datetime reference = Datetime.newInstance(referenceTimestamp * 1000);
        List<String> parts = reference.formatGmt('HH:mm:ss').split(':');
        Datetime target = Datetime.newInstanceGmt(
            targetDate,
            Time.newInstance(Integer.valueOf(parts[0]), Integer.valueOf(parts[1]), Integer.valueOf(parts[2]), 0)
        );
        return target.getTime() / 1000;
    }

    private static Date unixDate(Long timestamp) {
        return Datetime.newInstance(timestamp * 1000).dateGmt();
    }

    private static Long toMinorUnits(Decimal amount) {
        return Long.valueOf(String.valueOf(amount.setScale(2) * 100));
    }

    private static String getSecretKey() {
        String secretKey = secretKeyOverride == null ? System.Label.Stripe_Secret : secretKeyOverride;
        if (String.isBlank(secretKey)) {
            throw new StripeRecurringScheduleException('Stripe credential is not configured.');
        }
        return secretKey;
    }

    private static Map<String, Object> sendJson(String method, String path, String body, String idempotencyKey, String secretKey) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(STRIPE_API_BASE + path);
        request.setMethod(method);
        request.setHeader('Authorization', 'Bearer ' + secretKey);
        request.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        request.setTimeout(TIMEOUT_MS);
        if (String.isNotBlank(idempotencyKey)) request.setHeader('Idempotency-Key', idempotencyKey);
        if (body != null) request.setBody(body);

        HttpResponse response = new Http().send(request);
        if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
            throw new StripeRecurringScheduleException(sanitizeStripeError(response));
        }
        if (String.isBlank(response.getBody())) return new Map<String, Object>();
        return (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
    }

    private static String sanitizeStripeError(HttpResponse response) {
        String message = 'Stripe request failed with HTTP ' + response.getStatusCode() + '.';
        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
            Map<String, Object> error = asMap(payload.get('error'));
            String stripeMessage = error == null ? null : asString(error.get('message'));
            if (String.isNotBlank(stripeMessage)) message += ' ' + stripeMessage.left(180);
        } catch (Exception ignored) {
        }
        return message;
    }

    private static String sanitize(String message) {
        if (String.isBlank(message)) return 'Stripe recurring schedule preview failed.';
        return message.replaceAll('(?i)(sk|rk)_(test|live)_[A-Za-z0-9_]+', '[REDACTED]').left(1000);
    }

    private static String encodeForm(List<FormValue> values) {
        List<String> encoded = new List<String>();
        for (FormValue value : values) {
            encoded.add(EncodingUtil.urlEncode(value.key, 'UTF-8') + '=' + EncodingUtil.urlEncode(value.value, 'UTF-8'));
        }
        return String.join(encoded, '&');
    }

    private static String encodePath(String value) {
        return EncodingUtil.urlEncode(value, 'UTF-8').replace('+', '%20');
    }

    private static Map<String, Object> asMap(Object value) {
        return value instanceof Map<String, Object> ? (Map<String, Object>) value : null;
    }

    private static String asString(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static Long asLong(Object value) {
        return value == null ? null : Long.valueOf(String.valueOf(value));
    }

    private static Long firstLong(Object preferred, Object fallback) {
        Long value = asLong(preferred);
        return value == null ? asLong(fallback) : value;
    }

    private static Integer asInteger(Object value) {
        return value == null ? null : Integer.valueOf(String.valueOf(value));
    }

    private static String extractId(Object value) {
        if (value == null) return null;
        Map<String, Object> expanded = asMap(value);
        return expanded == null ? String.valueOf(value) : asString(expanded.get('id'));
    }
}