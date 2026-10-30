/**
 * Durable outbox orchestration for composite Salesforce-to-Stripe subscription changes.
 */
public without sharing class StripeRecurringScheduleChangeService {
    @TestVisible static Boolean enqueueDisabledForTest = false;

    /** Captures changes and automatically starts their Stripe processing. */
    public static void createRequestsForGiftCommitments(Set<Id> giftCommitmentIds) {
        createRequests(giftCommitmentIds, false, new Map<Id, String>());
    }

    /** Captures changes after the managed schedule transaction has committed. */
    public static void captureRequestsForGiftCommitments(Set<Id> giftCommitmentIds) {
        createRequests(giftCommitmentIds, true, new Map<Id, String>());
    }

    /** Creates or reuses the single durable request for a guided Flow transaction without enqueueing Stripe work. */
    public static Id createGuidedRequestForGiftCommitment(Id giftCommitmentId) {
        return createGuidedRequestForGiftCommitment(giftCommitmentId, null);
    }

    /** Creates a guided request while retaining the server-calculated Flow mode. */
    public static Id createGuidedRequestForGiftCommitment(Id giftCommitmentId, String changeMode) {
        return createGuidedRequestForGiftCommitment(giftCommitmentId, changeMode, null);
    }

    /** Creates a guided request with the proposed terms captured by the Flow. */
    public static Id createGuidedRequestForGiftCommitment(
        Id giftCommitmentId,
        String changeMode,
        GuidedOverride guidedOverride
    ) {
        if (giftCommitmentId == null) return null;
        Map<Id, String> modeByCommitment = new Map<Id, String>();
        if (String.isNotBlank(changeMode)) modeByCommitment.put(giftCommitmentId, changeMode);
        Map<Id, GuidedOverride> overridesByCommitment = new Map<Id, GuidedOverride>();
        if (guidedOverride != null) overridesByCommitment.put(giftCommitmentId, guidedOverride);
        return createRequests(
            new Set<Id>{ giftCommitmentId },
            true,
            modeByCommitment,
            overridesByCommitment
        ).get(giftCommitmentId);
    }

    /**
     * Creates the guided request from the fully saved parent and schedule state and starts the normal async processor.
     * @param giftCommitmentId commitment whose guided schedule change has just been saved
     * @return the durable request ID, or null when no verified Stripe request is eligible
     */
    public static Id createGuidedRequestAndEnqueueForGiftCommitment(Id giftCommitmentId) {
        return createGuidedRequestAndEnqueueForGiftCommitment(giftCommitmentId, null);
    }

    /** Creates and queues a guided request with the server-calculated Flow mode. */
    public static Id createGuidedRequestAndEnqueueForGiftCommitment(Id giftCommitmentId, String changeMode) {
        return createGuidedRequestAndEnqueueForGiftCommitment(giftCommitmentId, changeMode, null);
    }

    /** Creates and queues a guided request with the proposed terms captured by the Flow. */
    public static Id createGuidedRequestAndEnqueueForGiftCommitment(
        Id giftCommitmentId,
        String changeMode,
        GuidedOverride guidedOverride
    ) {
        if (giftCommitmentId == null) return null;
        Map<Id, String> modeByCommitment = new Map<Id, String>();
        if (String.isNotBlank(changeMode)) modeByCommitment.put(giftCommitmentId, changeMode);
        Map<Id, GuidedOverride> overridesByCommitment = new Map<Id, GuidedOverride>();
        if (guidedOverride != null) overridesByCommitment.put(giftCommitmentId, guidedOverride);
        return createRequests(
            new Set<Id>{ giftCommitmentId },
            false,
            modeByCommitment,
            overridesByCommitment
        ).get(giftCommitmentId);
    }

    /** Returns only commitments that have a subscription ID and a Stripe/card classification. */
    public static Set<Id> filterVerifiedStripeCommitmentIds(Set<Id> giftCommitmentIds) {
        Set<Id> verified = new Set<Id>();
        if (giftCommitmentIds == null || giftCommitmentIds.isEmpty()) return verified;
        Map<Id, GiftCommitment> commitments = selectCommitments(giftCommitmentIds);
        Map<Id, GiftCommitmentSchedule> schedules = selectLatestSchedules(giftCommitmentIds);
        for (Id commitmentId : giftCommitmentIds) {
            GiftCommitment commitment = commitments.get(commitmentId);
            GiftCommitmentSchedule schedule = schedules.get(commitmentId);
            if (isVerifiedStripeCommitment(commitment, schedule == null ? null : schedule.PaymentMethod)) {
                verified.add(commitmentId);
            }
        }
        return verified;
    }

    @TestVisible
    static Boolean isVerifiedStripeCommitment(GiftCommitment commitment, String schedulePaymentMethod) {
        if (commitment == null || String.isBlank(commitment.Subscription_Id__c)) return false;
        return 'Stripe'.equalsIgnoreCase(commitment.Payment_Processor__c) ||
            'Credit Card'.equalsIgnoreCase(commitment.Payment_type__c) ||
            'Credit Card'.equalsIgnoreCase(schedulePaymentMethod);
    }

    private static Map<Id, Id> createRequests(
        Set<Id> giftCommitmentIds,
        Boolean suppressAutomaticEnqueue,
        Map<Id, String> guidedModeByCommitment
    ) {
        return createRequests(
            giftCommitmentIds,
            suppressAutomaticEnqueue,
            guidedModeByCommitment,
            new Map<Id, GuidedOverride>()
        );
    }

    private static Map<Id, Id> createRequests(
        Set<Id> giftCommitmentIds,
        Boolean suppressAutomaticEnqueue,
        Map<Id, String> guidedModeByCommitment,
        Map<Id, GuidedOverride> guidedOverridesByCommitment
    ) {
        Map<Id, Id> requestIdsByCommitment = new Map<Id, Id>();
        if (giftCommitmentIds == null || giftCommitmentIds.isEmpty() || !isEnabled()) return requestIdsByCommitment;
        Map<Id, GiftCommitment> commitments = selectCommitments(giftCommitmentIds);
        Map<Id, GiftCommitmentSchedule> latestSchedules = selectLatestSchedules(giftCommitmentIds);
        if (guidedOverridesByCommitment != null && !guidedOverridesByCommitment.isEmpty()) {
            Set<Id> guidedScheduleIds = new Set<Id>();
            for (GuidedOverride guidedOverride : guidedOverridesByCommitment.values()) {
                if (guidedOverride != null && guidedOverride.targetScheduleId != null) {
                    guidedScheduleIds.add(guidedOverride.targetScheduleId);
                }
            }
            if (!guidedScheduleIds.isEmpty()) {
                for (GiftCommitmentSchedule guidedSchedule : selectSchedules(guidedScheduleIds).values()) {
                    if (giftCommitmentIds.contains(guidedSchedule.GiftCommitmentId)) {
                        latestSchedules.put(guidedSchedule.GiftCommitmentId, guidedSchedule);
                    }
                }
            }
        }
        Map<Id, GiftTransaction> nextUnpaid = selectNextUnpaid(giftCommitmentIds);

        Map<Id, Candidate> candidatesByCommitment = buildCandidates(
            giftCommitmentIds,
            commitments,
            latestSchedules,
            nextUnpaid,
            guidedModeByCommitment,
            guidedOverridesByCommitment
        );
        if (candidatesByCommitment.isEmpty()) return requestIdsByCommitment;

        Map<Id, Stripe_Subscription_Change__c> latestRequests = selectLatestRequests(
            candidatesByCommitment.keySet()
        );
        Map<Id, List<Stripe_Subscription_Change__c>> actionableRequests =
            selectActionableRequests(candidatesByCommitment.keySet());
        Set<String> candidateKeys = new Set<String>();
        for (Candidate candidate : candidatesByCommitment.values()) {
            candidateKeys.add(candidate.idempotencyKey);
        }
        Set<String> existingKeys = new Set<String>();
        for (Stripe_Subscription_Change__c existing : [
            SELECT Id, Gift_Commitment__c, Idempotency_Key__c FROM Stripe_Subscription_Change__c WHERE Idempotency_Key__c IN :candidateKeys
        ]) {
            existingKeys.add(existing.Idempotency_Key__c);
            requestIdsByCommitment.put(existing.Gift_Commitment__c, existing.Id);
        }

        for (Candidate candidate : candidatesByCommitment.values()) {
            Stripe_Subscription_Change__c latest = latestRequests.get(candidate.commitment.Id);
            Stripe_Subscription_Change__c transitionPredecessor =
                findTransitionPredecessor(actionableRequests.get(candidate.commitment.Id), candidate.recurringType);
            if (transitionPredecessor != null) {
                candidate.idempotencyKey = buildTransitionRevisionKey(candidate, transitionPredecessor.Id);
            } else if (configurationMatches(latest, candidate)) {
                candidate.idempotencyKey = latest.Idempotency_Key__c;
                existingKeys.add(latest.Idempotency_Key__c);
                requestIdsByCommitment.put(candidate.commitment.Id, latest.Id);
            } else if (latest != null &&
                latest.Requested_Recurring_Type__c != candidate.recurringType) {
                candidate.idempotencyKey = buildTransitionRevisionKey(candidate, latest.Id);
            }
        }

        candidateKeys.clear();
        for (Candidate candidate : candidatesByCommitment.values()) {
            candidateKeys.add(candidate.idempotencyKey);
        }
        for (Stripe_Subscription_Change__c existing : [
            SELECT Id, Gift_Commitment__c, Idempotency_Key__c
            FROM Stripe_Subscription_Change__c
            WHERE Idempotency_Key__c IN :candidateKeys
        ]) {
            existingKeys.add(existing.Idempotency_Key__c);
            requestIdsByCommitment.put(existing.Gift_Commitment__c, existing.Id);
        }

        supersedePriorRequests(candidatesByCommitment);
        List<Stripe_Subscription_Change__c> requests = new List<Stripe_Subscription_Change__c>();
        Map<Id, GiftCommitment> parentsToUpdate = new Map<Id, GiftCommitment>();
        for (Candidate candidate : candidatesByCommitment.values()) {
            if (existingKeys.contains(candidate.idempotencyKey)) continue;
            String validationError = validateCandidate(candidate);
            // The Flow blocks invalid Fixed dates before native DML. This
            // backstop prevents direct automation from creating a failed
            // durable request that could never be processed safely.
            if (validationError != null) continue;
            String status = 'Pending';
            requests.add(new Stripe_Subscription_Change__c(
                Gift_Commitment__c = candidate.commitment.Id,
                Gift_Commitment_Schedule__c = candidate.schedule.Id,
                Requested_Effective_Date__c = candidate.effectiveDate,
                Requested_Configuration_Start_Date__c = candidate.requestedConfigurationStartDate,
                Requested_Configuration_End_Date__c = candidate.requestedConfigurationEndDate,
                Requested_First_Payment_Date__c = candidate.firstPaymentDate,
                Requested_Final_Payment_Date__c = candidate.finalPaymentDate,
                Requested_Amount__c = candidate.requestedAmount,
                Requested_Period__c = candidate.requestedPeriod,
                Requested_Interval__c = candidate.intervalCount,
                Requested_Transaction_Day__c = candidate.transactionDay,
                Requested_Recurring_Type__c = candidate.recurringType,
                Requested_Installments__c = candidate.installments,
                Requested_Change_Mode__c = candidate.changeMode,
                Temporary_Window_End_Date__c = candidate.effectiveEndDate,
                Original_Amount__c = candidate.originalAmount,
                Original_Period__c = candidate.originalPeriod,
                Original_Interval__c = candidate.originalInterval,
                Original_Stripe_Price_Id__c = candidate.originalPriceId,
                Original_Stripe_Cancel_At__c = candidate.originalCancelAt,
                Restoration_Schedule__c = candidate.restorationScheduleId,
                Restoration_First_Payment_Date__c = candidate.restorationFirstPaymentDate,
                Stop_Stripe_Billing_Immediately__c = candidate.stopBillingImmediately,
                Stripe_Action_Mode__c = candidate.effectiveDate == Date.today() ? 'Immediate' : 'Scheduled',
                Status__c = status,
                Attempt_Count__c = 0,
                Idempotency_Key__c = candidate.idempotencyKey,
                Stripe_Subscription_Id__c = candidate.commitment.Subscription_Id__c,
                Last_Error__c = validationError
            ));
            parentsToUpdate.put(candidate.commitment.Id, new GiftCommitment(
                Id = candidate.commitment.Id,
                Stripe_Schedule_Sync_Status__c = status,
                Stripe_Schedule_Sync_Message__c = validationError == null
                    ? (candidate.stopBillingImmediately
                        ? 'Salesforce schedule saved; waiting for synchronous Stripe billing-stop confirmation.'
                        : 'Stripe composite change queued for ' + String.valueOf(candidate.effectiveDate) + '.')
                    : validationError.left(255)
            ));
        }
        if (requests.isEmpty()) return requestIdsByCommitment;
        List<Database.SaveResult> insertResults = Database.insert(requests, false);
        Set<String> concurrentKeys = new Set<String>();
        for (Integer index = 0; index < insertResults.size(); index++) {
            Database.SaveResult insertResult = insertResults[index];
            Stripe_Subscription_Change__c requestRecord = requests[index];
            if (insertResult.isSuccess()) {
                requestRecord.Id = insertResult.getId();
                requestIdsByCommitment.put(requestRecord.Gift_Commitment__c, requestRecord.Id);
                continue;
            }
            Boolean duplicateKey = false;
            for (Database.Error error : insertResult.getErrors()) {
                if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                    duplicateKey = true;
                    break;
                }
            }
            if (duplicateKey) {
                concurrentKeys.add(requestRecord.Idempotency_Key__c);
                continue;
            }
            throw new StripeRecurringScheduleServiceException(
                'Unable to create the Stripe recurring schedule change request.'
            );
        }
        if (!concurrentKeys.isEmpty()) {
            for (Stripe_Subscription_Change__c existing : [
                SELECT Id, Gift_Commitment__c
                FROM Stripe_Subscription_Change__c
                WHERE Idempotency_Key__c IN :concurrentKeys
            ]) {
                requestIdsByCommitment.put(existing.Gift_Commitment__c, existing.Id);
            }
        }
        update parentsToUpdate.values();

        List<Id> pendingRequestIds = new List<Id>();
        for (Stripe_Subscription_Change__c requestRecord : requests) {
            if (requestRecord.Id != null && requestRecord.Status__c == 'Pending') {
                pendingRequestIds.add(requestRecord.Id);
            }
        }
        if (!pendingRequestIds.isEmpty() && !suppressAutomaticEnqueue && !enqueueDisabledForTest) {
            System.enqueueJob(new StripeRecurringScheduleSyncQueueable(pendingRequestIds));
        }
        return requestIdsByCommitment;
    }

    /** Processes one durable request. Stripe is re-read on every attempt. */
    public static ProcessResult processRequest(Id requestId) {
        ProcessResult processResult = new ProcessResult();
        processResult.requestId = requestId;
        if (requestId == null) {
            processResult.success = false;
            processResult.status = 'Failed';
            processResult.errorMessage = 'A Stripe change request ID is required.';
            return processResult;
        }
        Stripe_Subscription_Change__c requestRecord = selectRequest(requestId);
        if (requestRecord.Status__c == 'Superseded' || requestRecord.Status__c == 'Synced' ||
            requestRecord.Status__c == 'Active' ||
            requestRecord.Status__c == 'Scheduled') return toProcessResult(requestRecord, true);

        if (requestRecord.Requested_Change_Mode__c == StripeRecurringChangeMode.START_DATE_CHANGE &&
            requestRecord.Requested_Effective_Date__c == Date.today() &&
            hasPaidTransactionToday(requestRecord.Gift_Commitment__c)) {
            markFailed(
                requestRecord,
                'A payment has already been taken today. You cannot change the Start Date effective today. ' +
                'Select the next unpaid payment date or a later date.',
                requestRecord.Attempt_Count__c == null ? 1 : Integer.valueOf(requestRecord.Attempt_Count__c) + 1,
                null
            );
            return toProcessResult(selectRequest(requestId), false);
        }

        Integer nextAttempt = requestRecord.Attempt_Count__c == null
            ? 1
            : Integer.valueOf(requestRecord.Attempt_Count__c) + 1;
        if (nextAttempt > getMaxAttempts()) {
            markFailed(requestRecord, 'Maximum Stripe synchronization attempts exceeded.', nextAttempt, null);
            return toProcessResult(selectRequest(requestId), false);
        }

        try {
            StripeRecurringScheduleGateway.ChangeResult result = StripeRecurringScheduleGateway.applyChange(
                toGatewayRequest(requestRecord)
            );
            if (result.hasPendingUpdate) {
                markFailed(
                    requestRecord,
                    'Stripe created a pending update because the immediate invoice was not paid. Retry after resolving the invoice.',
                    nextAttempt,
                    result
                );
                return toProcessResult(selectRequest(requestId), false);
            }
            if (requestRecord.Stop_Stripe_Billing_Immediately__c && result.billingStopVerified != true) {
                markFailed(requestRecord, 'Stripe did not verify that current billing stopped.', nextAttempt, result);
                return toProcessResult(selectRequest(requestId), false);
            }
            markAccepted(requestRecord, nextAttempt, result);
        } catch (Exception error) {
            markFailed(requestRecord, sanitize(error.getMessage()), nextAttempt, null);
        }
        Stripe_Subscription_Change__c completed = selectRequest(requestId);
        return toProcessResult(completed, completed.Status__c == 'Synced' || completed.Status__c == 'Scheduled');
    }

    /**
     * Verifies and finalizes cancellation state after Stripe applies a pending immediate update.
     * @param requestId durable Stripe change request identified by the webhook
     * @return final processing outcome
     */
    public static ProcessResult finalizeAppliedPendingRequest(Id requestId) {
        Stripe_Subscription_Change__c requestRecord = selectRequest(requestId);
        if (requestRecord.Status__c == 'Synced') return toProcessResult(requestRecord, true);
        if (requestRecord.Status__c != 'Processing' && requestRecord.Status__c != 'Failed') {
            return toProcessResult(requestRecord, false);
        }
        Integer attemptCount = requestRecord.Attempt_Count__c == null
            ? 1
            : Integer.valueOf(requestRecord.Attempt_Count__c);
        try {
            StripeRecurringScheduleGateway.ChangeResult result =
                StripeRecurringScheduleGateway.finalizeAppliedImmediateChange(toGatewayRequest(requestRecord));
            markAccepted(requestRecord, attemptCount, result);
        } catch (Exception error) {
            markFailed(requestRecord, sanitize(error.getMessage()), attemptCount, null);
        }
        Stripe_Subscription_Change__c completed = selectRequest(requestId);
        return toProcessResult(completed, completed.Status__c == 'Synced');
    }

    /** Resets a failed request to Pending so the retry queueable can safely re-read Stripe. */
    public static void prepareRetry(Id requestId) {
        Stripe_Subscription_Change__c requestRecord = selectRequest(requestId);
        if (requestRecord.Status__c != 'Failed') {
            throw new StripeRecurringScheduleServiceException('Only failed Stripe changes can be retried.');
        }
        requestRecord.Status__c = 'Pending';
        requestRecord.Last_Error__c = null;
        update requestRecord;
        update new GiftCommitment(
            Id = requestRecord.Gift_Commitment__c,
            Stripe_Schedule_Sync_Status__c = 'Pending',
            Stripe_Schedule_Sync_Message__c = 'Stripe retry queued.'
        );
    }

    private static Map<Id, GiftCommitment> selectCommitments(Set<Id> giftCommitmentIds) {
        return new Map<Id, GiftCommitment>([
            SELECT Id, Subscription_Id__c, Product_Id__c, Price_Id__c, CurrencyIsoCode,
                   Recurring_Type__c, Payment_Processor__c, Payment_type__c,
                   Stripe_Schedule_Sync_Status__c, Stripe_Schedule_Sync_Message__c
            FROM GiftCommitment WHERE Id IN :giftCommitmentIds
        ]);
    }

    private static Map<Id, GiftCommitmentSchedule> selectLatestSchedules(Set<Id> giftCommitmentIds) {
        Map<Id, GiftCommitmentSchedule> latest = new Map<Id, GiftCommitmentSchedule>();
        for (GiftCommitmentSchedule schedule : [
            SELECT Id, GiftCommitmentId, TransactionAmount, TransactionPeriod, TransactionInterval,
                   TransactionDay, StartDate, EndDate, Stripe_Change_Effective_Date__c,
                   Number_of_Planned_Installments__c, Final_Payment_Date__c,
                   Stop_Stripe_Billing_Immediately__c, PaymentMethod
            FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId IN :giftCommitmentIds
            ORDER BY GiftCommitmentId, StartDate DESC, CreatedDate DESC
        ]) {
            if (!latest.containsKey(schedule.GiftCommitmentId)) latest.put(schedule.GiftCommitmentId, schedule);
        }
        return latest;
    }

    private static Map<Id, GiftCommitmentSchedule> selectSchedules(Set<Id> scheduleIds) {
        return new Map<Id, GiftCommitmentSchedule>([
            SELECT Id, GiftCommitmentId, TransactionAmount, TransactionPeriod, TransactionInterval,
                   TransactionDay, StartDate, EndDate, Stripe_Change_Effective_Date__c,
                   Number_of_Planned_Installments__c, Final_Payment_Date__c,
                   Stop_Stripe_Billing_Immediately__c, PaymentMethod
            FROM GiftCommitmentSchedule
            WHERE Id IN :scheduleIds
        ]);
    }

    private static Map<Id, GiftTransaction> selectNextUnpaid(Set<Id> giftCommitmentIds) {
        Map<Id, GiftTransaction> nextByCommitment = new Map<Id, GiftTransaction>();
        for (GiftTransaction transactionRecord : [
            SELECT Id, GiftCommitmentId, GiftCommitmentScheduleId, OriginalAmount, TransactionDueDate, Status
            FROM GiftTransaction
            WHERE GiftCommitmentId IN :giftCommitmentIds
              AND Status IN ('Pledged', 'Unpaid')
              AND TransactionDueDate >= TODAY
            ORDER BY GiftCommitmentId, TransactionDueDate, CreatedDate
        ]) {
            if (!nextByCommitment.containsKey(transactionRecord.GiftCommitmentId)) {
                nextByCommitment.put(transactionRecord.GiftCommitmentId, transactionRecord);
            }
        }
        return nextByCommitment;
    }

    private static Map<Id, Stripe_Subscription_Change__c> selectLatestRequests(
        Set<Id> giftCommitmentIds
    ) {
        Map<Id, Stripe_Subscription_Change__c> latestByCommitment =
            new Map<Id, Stripe_Subscription_Change__c>();
        for (Stripe_Subscription_Change__c requestRecord : [
            SELECT Id, Gift_Commitment__c, Status__c, Idempotency_Key__c,
                   Stripe_Subscription_Id__c, Requested_Amount__c,
                   Requested_Period__c, Requested_Interval__c,
                   Requested_Transaction_Day__c,
                   Requested_Effective_Date__c, Requested_First_Payment_Date__c,
                   Requested_Final_Payment_Date__c, Requested_Recurring_Type__c,
                   Requested_Installments__c, Requested_Change_Mode__c,
                   Requested_Configuration_Start_Date__c, Requested_Configuration_End_Date__c,
                   Temporary_Window_End_Date__c, Original_Amount__c, Original_Period__c,
                   Original_Interval__c, Original_Stripe_Price_Id__c,
                   Original_Stripe_Cancel_At__c, Restoration_Schedule__c,
                   Restoration_First_Payment_Date__c,
                   Stop_Stripe_Billing_Immediately__c
            FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c IN :giftCommitmentIds
            ORDER BY Gift_Commitment__c, CreatedDate DESC, Id DESC
        ]) {
            if (!latestByCommitment.containsKey(requestRecord.Gift_Commitment__c)) {
                latestByCommitment.put(requestRecord.Gift_Commitment__c, requestRecord);
            }
        }
        return latestByCommitment;
    }

    private static Map<Id, List<Stripe_Subscription_Change__c>> selectActionableRequests(
        Set<Id> giftCommitmentIds
    ) {
        Map<Id, List<Stripe_Subscription_Change__c>> actionableByCommitment =
            new Map<Id, List<Stripe_Subscription_Change__c>>();
        for (Stripe_Subscription_Change__c requestRecord : [
            SELECT Id, Gift_Commitment__c, Status__c, Requested_Recurring_Type__c
            FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c IN :giftCommitmentIds
              AND Status__c IN ('Pending', 'Scheduled')
            ORDER BY Gift_Commitment__c, CreatedDate DESC, Id DESC
        ]) {
            if (!actionableByCommitment.containsKey(requestRecord.Gift_Commitment__c)) {
                actionableByCommitment.put(
                    requestRecord.Gift_Commitment__c,
                    new List<Stripe_Subscription_Change__c>()
                );
            }
            actionableByCommitment.get(requestRecord.Gift_Commitment__c).add(requestRecord);
        }
        return actionableByCommitment;
    }

    private static Stripe_Subscription_Change__c findTransitionPredecessor(
        List<Stripe_Subscription_Change__c> actionableRequests,
        String requestedRecurringType
    ) {
        if (actionableRequests == null) return null;
        for (Stripe_Subscription_Change__c prior : actionableRequests) {
            if (prior.Requested_Recurring_Type__c != requestedRecurringType) return prior;
        }
        return null;
    }

    private static Map<Id, Candidate> buildCandidates(
        Set<Id> giftCommitmentIds,
        Map<Id, GiftCommitment> commitments,
        Map<Id, GiftCommitmentSchedule> schedules,
        Map<Id, GiftTransaction> transactions,
        Map<Id, String> guidedModeByCommitment,
        Map<Id, GuidedOverride> guidedOverridesByCommitment
    ) {
        Map<Id, Candidate> candidates = new Map<Id, Candidate>();
        for (Id commitmentId : giftCommitmentIds) {
            GiftCommitment commitment = commitments.get(commitmentId);
            GiftCommitmentSchedule schedule = schedules.get(commitmentId);
            if (!isVerifiedStripeCommitment(commitment, schedule == null ? null : schedule.PaymentMethod) || schedule == null ||
                schedule.StartDate == null || schedule.TransactionAmount == null || String.isBlank(schedule.TransactionPeriod)) {
                continue;
            }
            Candidate candidate = new Candidate();
            candidate.commitment = commitment;
            candidate.schedule = schedule;
            GuidedOverride guidedOverride = guidedOverridesByCommitment == null
                ? null
                : guidedOverridesByCommitment.get(commitmentId);
            candidate.requestedAmount = guidedOverride != null && guidedOverride.amount != null
                ? guidedOverride.amount
                : schedule.TransactionAmount;
            candidate.requestedPeriod = guidedOverride != null && String.isNotBlank(guidedOverride.period)
                ? guidedOverride.period
                : schedule.TransactionPeriod;
            candidate.requestedConfigurationStartDate = guidedOverride != null &&
                guidedOverride.configurationStartDate != null
                ? guidedOverride.configurationStartDate
                : schedule.StartDate;
            candidate.requestedConfigurationEndDate = guidedOverride != null &&
                guidedOverride.configurationEndDateIsSet == true
                ? guidedOverride.configurationEndDate
                : schedule.EndDate;
            candidate.effectiveEndDate = guidedOverride == null
                ? null
                : guidedOverride.effectiveEndDate;
            candidate.originalAmount = guidedOverride != null && guidedOverride.originalAmount != null
                ? guidedOverride.originalAmount
                : schedule.TransactionAmount;
            candidate.originalPeriod = guidedOverride != null && String.isNotBlank(guidedOverride.originalPeriod)
                ? guidedOverride.originalPeriod
                : schedule.TransactionPeriod;
            candidate.originalInterval = guidedOverride != null && guidedOverride.originalInterval != null
                ? guidedOverride.originalInterval
                : (schedule.TransactionInterval == null ? 1 : Integer.valueOf(schedule.TransactionInterval));
            candidate.originalPriceId = guidedOverride != null && String.isNotBlank(guidedOverride.originalPriceId)
                ? guidedOverride.originalPriceId
                : commitment.Price_Id__c;
            candidate.originalCancelAt = guidedOverride == null ? null : guidedOverride.originalCancelAt;
            candidate.restorationScheduleId = guidedOverride == null ? null : guidedOverride.restorationScheduleId;
            candidate.restorationFirstPaymentDate = guidedOverride == null
                ? null
                : guidedOverride.restorationFirstPaymentDate;
            candidate.nextTransaction = transactions.get(commitmentId);
            candidate.effectiveDate = guidedOverride != null && guidedOverride.configurationStartDate != null
                ? guidedOverride.configurationStartDate
                : (schedule.Stripe_Change_Effective_Date__c == null
                    ? schedule.StartDate
                    : schedule.Stripe_Change_Effective_Date__c);
            candidate.intervalCount = guidedOverride != null && guidedOverride.intervalCount != null
                ? guidedOverride.intervalCount
                : (schedule.TransactionInterval == null ? 1 : Integer.valueOf(schedule.TransactionInterval));
            candidate.firstPaymentDate = guidedOverride != null && guidedOverride.firstPaymentDate != null
                ? guidedOverride.firstPaymentDate
                : (candidate.nextTransaction == null
                    ? schedule.StartDate
                    : candidate.nextTransaction.TransactionDueDate);
            if (candidate.firstPaymentDate <= Date.today()) {
                candidate.firstPaymentDate = StripeRDScheduleDateCalc.nextOccurrenceAfter(
                    candidate.firstPaymentDate,
                    Date.today(),
                    candidate.requestedPeriod,
                    candidate.intervalCount
                );
            }
            candidate.transactionDay = guidedOverride != null && String.isNotBlank(guidedOverride.transactionDay)
                ? guidedOverride.transactionDay
                : ('Monthly'.equalsIgnoreCase(candidate.requestedPeriod) && candidate.firstPaymentDate != null
                    ? String.valueOf(candidate.firstPaymentDate.day())
                    : null);
            candidate.recurringType = guidedOverride != null &&
                (guidedOverride.recurringType == 'Fixed' || guidedOverride.recurringType == 'Open')
                ? guidedOverride.recurringType
                : (commitment.Recurring_Type__c == 'Fixed' ? 'Fixed' : 'Open');
            // Open is a durable parent state, not a stale schedule EndDate.
            // Clear fixed-only date input whenever the requested parent type is
            // Open so an Open -> Fixed -> Open transition receives a distinct
            // durable configuration and the Stripe phase can be released.
            if (candidate.recurringType == 'Open') {
                candidate.requestedConfigurationEndDate = null;
            }
            candidate.changeMode = deriveSavedChangeMode(
                guidedModeByCommitment == null ? null : guidedModeByCommitment.get(commitmentId),
                guidedOverride,
                candidate
            );
            Boolean explicitDates = guidedOverride != null && guidedOverride.firstPaymentDate != null;
            if (explicitDates) {
                candidate.firstPaymentDate = guidedOverride.firstPaymentDate;
                candidate.finalPaymentDate = guidedOverride.finalPaymentDateIsSet == true
                    ? guidedOverride.finalPaymentDate
                    : candidate.finalPaymentDate;
                candidate.installments = guidedOverride.installments;
                candidate.dateCalculationError = null;
                candidate.stopBillingImmediately = schedule.Stop_Stripe_Billing_Immediately__c == true;
                candidate.idempotencyKey = buildIdempotencyKey(candidate);
                candidates.put(commitmentId, candidate);
                continue;
            }
            if (candidate.changeMode == StripeRecurringChangeMode.END_DATE_ONLY &&
                candidate.recurringType == 'Fixed' && schedule.EndDate == Date.today()) {
                // Today's paid installment is the final installment for an
                // End Date equal to today.  Do not roll it forward to the next
                // cadence occurrence when building the durable request.
                candidate.firstPaymentDate = Date.today();
                candidate.finalPaymentDate = Date.today();
                candidate.installments = 1;
                candidate.dateCalculationError = null;
                candidate.stopBillingImmediately = schedule.Stop_Stripe_Billing_Immediately__c == true;
                candidate.idempotencyKey = buildIdempotencyKey(candidate);
                candidates.put(commitmentId, candidate);
                continue;
            }
            StripeRDScheduleDateCalc.Result dateResult;
            if (candidate.firstPaymentDate == null) {
                dateResult = new StripeRDScheduleDateCalc.Result();
                dateResult.error = 'Unable to calculate the first recurring payment date.';
            } else {
                dateResult = StripeRDScheduleDateCalc.calculate(
                    candidate.firstPaymentDate,
                    candidate.requestedConfigurationEndDate,
                    candidate.firstPaymentDate.addDays(-1),
                    candidate.requestedPeriod,
                    candidate.intervalCount,
                    candidate.recurringType
                );
            }
            candidate.installments = dateResult.installments;
            candidate.finalPaymentDate = dateResult.finalPaymentDate;
            candidate.dateCalculationError = dateResult.error;
            candidate.stopBillingImmediately = schedule.Stop_Stripe_Billing_Immediately__c == true;
            candidate.idempotencyKey = buildIdempotencyKey(candidate);
            candidates.put(commitmentId, candidate);
        }
        return candidates;
    }

    /**
     * Reclassifies a guided Open/Fixed transition from the saved schedule
     * snapshot. The Flow mode is only a fallback, never the authority.
     */
    @TestVisible
    private static String deriveSavedChangeMode(
        String flowMode,
        GuidedOverride guidedOverride,
        Candidate candidate
    ) {
        if (flowMode == StripeRecurringChangeMode.TEMPORARY_TERMS) {
            return StripeRecurringChangeMode.TEMPORARY_TERMS;
        }
        if (guidedOverride != null && candidate != null &&
            guidedOverride.originalAmount != null &&
            String.isNotBlank(guidedOverride.originalPeriod) &&
            guidedOverride.originalInterval != null) {
            Boolean billingTermsChanged = guidedOverride.originalAmount != candidate.requestedAmount ||
                guidedOverride.originalPeriod != candidate.requestedPeriod ||
                guidedOverride.originalInterval != candidate.intervalCount ||
                ('Monthly'.equalsIgnoreCase(guidedOverride.originalPeriod) &&
                 'Monthly'.equalsIgnoreCase(candidate.requestedPeriod) &&
                 guidedOverride.originalTransactionDay != null &&
                 StripeRDScheduleDateCalc.normalizeTransactionDay(guidedOverride.originalTransactionDay) !=
                     StripeRDScheduleDateCalc.normalizeTransactionDay(candidate.transactionDay));
            if (billingTermsChanged) return StripeRecurringChangeMode.TERMS;
            Boolean startChanged = guidedOverride.originalStartDate != null &&
                guidedOverride.originalStartDate != candidate.requestedConfigurationStartDate;
            if (!startChanged && guidedOverride.endDateOnlyTransition == true &&
                guidedOverride.originalEndDate != candidate.requestedConfigurationEndDate) {
                return StripeRecurringChangeMode.END_DATE_ONLY;
            }
            return flowMode == StripeRecurringChangeMode.END_DATE_ONLY
                ? StripeRecurringChangeMode.TERMS
                : (String.isBlank(flowMode) ? StripeRecurringChangeMode.TERMS : flowMode);
        }
        if (guidedOverride != null && guidedOverride.endDateOnlyTransition == true &&
            candidate != null && candidate.schedule != null &&
            candidate.requestedAmount == candidate.schedule.TransactionAmount &&
            candidate.requestedPeriod == candidate.schedule.TransactionPeriod &&
            candidate.intervalCount == (candidate.schedule.TransactionInterval == null
                ? 1
                : Integer.valueOf(candidate.schedule.TransactionInterval)) &&
            candidate.requestedConfigurationStartDate == candidate.schedule.StartDate) {
            return StripeRecurringChangeMode.END_DATE_ONLY;
        }
        return String.isBlank(flowMode) ? StripeRecurringChangeMode.TERMS : flowMode;
    }

    private static void supersedePriorRequests(Map<Id, Candidate> candidatesByCommitment) {
        List<Stripe_Subscription_Change__c> toUpdate = new List<Stripe_Subscription_Change__c>();
        for (Stripe_Subscription_Change__c prior : [
            SELECT Id, Gift_Commitment__c, Idempotency_Key__c, Status__c
            FROM Stripe_Subscription_Change__c
            WHERE Gift_Commitment__c IN :candidatesByCommitment.keySet()
              AND Status__c IN ('Pending', 'Scheduled')
        ]) {
            Candidate replacement = candidatesByCommitment.get(prior.Gift_Commitment__c);
            if (replacement != null && prior.Idempotency_Key__c != replacement.idempotencyKey) {
                prior.Status__c = 'Superseded';
                prior.Last_Error__c = 'Superseded by a newer composite recurring donation change.';
                toUpdate.add(prior);
            }
        }
        if (!toUpdate.isEmpty()) update toUpdate;
    }

    private static String validateCandidate(Candidate candidate) {
        if (candidate.dateCalculationError != null) return candidate.dateCalculationError;
        if (candidate.effectiveDate < Date.today()) return 'The Stripe change effective date cannot be in the past.';
        if (candidate.firstPaymentDate < candidate.effectiveDate) {
            return 'The first Stripe payment date cannot be before the configuration effective date.';
        }
        if (candidate.recurringType == 'Fixed' && (candidate.installments == null || candidate.installments < 1)) {
            return 'Fixed recurring donations require a positive installment count.';
        }
        if (candidate.changeMode == 'TemporaryTerms') {
            if (candidate.effectiveEndDate == null || candidate.effectiveEndDate < candidate.effectiveDate) {
                return 'A temporary recurring-terms change requires an End Date on or after its Effective Start Date.';
            }
            if (candidate.originalAmount == null || candidate.originalAmount <= 0 ||
                String.isBlank(candidate.originalPeriod) || candidate.originalInterval == null ||
                candidate.originalInterval < 1 || String.isBlank(candidate.originalPriceId)) {
                return 'The original Stripe amount, cadence, interval, and Price are required for restoration.';
            }
            if (candidate.restorationScheduleId == null || candidate.restorationFirstPaymentDate == null ||
                candidate.restorationFirstPaymentDate <= candidate.effectiveEndDate) {
                return 'A verified restoration schedule and first restoration payment date are required.';
            }
        }
        return null;
    }

    private static String buildIdempotencyKey(Candidate candidate) {
        String raw = String.join(new List<String>{
            candidate.commitment.Subscription_Id__c,
            String.valueOf(candidate.requestedAmount),
            candidate.requestedPeriod,
            String.valueOf(candidate.intervalCount),
            candidate.transactionDay,
            String.valueOf(candidate.effectiveDate),
            String.valueOf(candidate.requestedConfigurationStartDate),
            String.valueOf(candidate.requestedConfigurationEndDate),
            String.valueOf(candidate.firstPaymentDate),
            String.valueOf(candidate.finalPaymentDate),
            candidate.recurringType,
            String.valueOf(candidate.installments),
            candidate.changeMode,
            String.valueOf(candidate.stopBillingImmediately),
            String.valueOf(candidate.effectiveEndDate),
            String.valueOf(candidate.originalAmount),
            candidate.originalPeriod,
            String.valueOf(candidate.originalInterval),
            candidate.originalPriceId,
            String.valueOf(candidate.originalCancelAt),
            String.valueOf(candidate.restorationScheduleId),
            String.valueOf(candidate.restorationFirstPaymentDate)
        }, '|');
        return 'sapa-rd-' + EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(raw))).toLowerCase();
    }

    private static Boolean configurationMatches(
        Stripe_Subscription_Change__c existing,
        Candidate candidate
    ) {
        if (existing == null) return false;
        Integer existingInterval = existing.Requested_Interval__c == null
            ? 1
            : Integer.valueOf(existing.Requested_Interval__c);
        Integer existingInstallments = existing.Requested_Installments__c == null
            ? null
            : Integer.valueOf(existing.Requested_Installments__c);
        return existing.Stripe_Subscription_Id__c == candidate.commitment.Subscription_Id__c &&
            existing.Requested_Amount__c == candidate.requestedAmount &&
            existing.Requested_Period__c == candidate.requestedPeriod &&
            existingInterval == candidate.intervalCount &&
            existing.Requested_Transaction_Day__c == candidate.transactionDay &&
            existing.Requested_Effective_Date__c == candidate.effectiveDate &&
            existing.Requested_Configuration_Start_Date__c == candidate.requestedConfigurationStartDate &&
            existing.Requested_Configuration_End_Date__c == candidate.requestedConfigurationEndDate &&
            existing.Requested_First_Payment_Date__c == candidate.firstPaymentDate &&
            existing.Requested_Final_Payment_Date__c == candidate.finalPaymentDate &&
            existing.Requested_Recurring_Type__c == candidate.recurringType &&
            existingInstallments == candidate.installments &&
            existing.Requested_Change_Mode__c == candidate.changeMode &&
            existing.Temporary_Window_End_Date__c == candidate.effectiveEndDate &&
            existing.Original_Amount__c == candidate.originalAmount &&
            existing.Original_Period__c == candidate.originalPeriod &&
            (existing.Original_Interval__c == null ? null : Integer.valueOf(existing.Original_Interval__c)) == candidate.originalInterval &&
            existing.Original_Stripe_Price_Id__c == candidate.originalPriceId &&
            existing.Original_Stripe_Cancel_At__c == candidate.originalCancelAt &&
            existing.Restoration_Schedule__c == candidate.restorationScheduleId &&
            existing.Restoration_First_Payment_Date__c == candidate.restorationFirstPaymentDate &&
            existing.Stop_Stripe_Billing_Immediately__c == candidate.stopBillingImmediately;
    }

    private static String buildTransitionRevisionKey(Candidate candidate, Id predecessorRequestId) {
        String raw = buildIdempotencyKey(candidate) + '|transition-from|' + String.valueOf(predecessorRequestId);
        return 'sapa-rd-' + EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(raw))
        ).toLowerCase();
    }

    private static Stripe_Subscription_Change__c selectRequest(Id requestId) {
        return [
            SELECT Id, Gift_Commitment__c, Gift_Commitment_Schedule__c,
                   Requested_Effective_Date__c, Requested_First_Payment_Date__c,
                   Requested_Final_Payment_Date__c, Requested_Amount__c, Requested_Period__c,
                   Requested_Interval__c, Requested_Transaction_Day__c,
                   Requested_Recurring_Type__c, Requested_Installments__c,
                   Requested_Change_Mode__c,
                   Requested_Configuration_Start_Date__c, Requested_Configuration_End_Date__c,
                   Temporary_Window_End_Date__c, Original_Amount__c, Original_Period__c,
                   Original_Interval__c, Original_Stripe_Price_Id__c,
                   Original_Stripe_Cancel_At__c, Restoration_Schedule__c,
                   Restoration_First_Payment_Date__c,
                   Stop_Stripe_Billing_Immediately__c, Billing_Stopped_At__c,
                   Stripe_Action_Mode__c, Status__c, Attempt_Count__c, Idempotency_Key__c,
                   Stripe_Subscription_Id__c, Stripe_Schedule_Id__c, Stripe_Price_Id__c,
                   Stripe_Invoice_Id__c, Stripe_Pending_Update_Id__c,
                   Stripe_Pending_Update_Expires_At__c, Stripe_Effective_Timestamp__c,
                   Last_Error__c,
                   Gift_Commitment__r.Product_Id__c, Gift_Commitment__r.CurrencyIsoCode
            FROM Stripe_Subscription_Change__c WHERE Id = :requestId LIMIT 1
        ];
    }

    private static StripeRecurringScheduleGateway.ChangeRequest toGatewayRequest(Stripe_Subscription_Change__c record) {
        StripeRecurringScheduleGateway.ChangeRequest request = new StripeRecurringScheduleGateway.ChangeRequest();
        request.subscriptionId = record.Stripe_Subscription_Id__c;
        request.productId = record.Gift_Commitment__r.Product_Id__c;
        request.currencyIsoCode = record.Gift_Commitment__r.CurrencyIsoCode;
        request.amount = record.Requested_Amount__c;
        request.transactionPeriod = record.Requested_Period__c;
        request.transactionInterval = Integer.valueOf(record.Requested_Interval__c);
        request.transactionDay = record.Requested_Transaction_Day__c;
        request.effectiveDate = record.Requested_Effective_Date__c;
        request.effectiveEndDate = record.Temporary_Window_End_Date__c;
        request.firstPaymentDate = record.Requested_First_Payment_Date__c;
        request.finalPaymentDate = record.Requested_Final_Payment_Date__c;
        request.recurringType = record.Requested_Recurring_Type__c;
        request.changeMode = record.Requested_Change_Mode__c;
        request.originalAmount = record.Original_Amount__c;
        request.originalPeriod = record.Original_Period__c;
        request.originalInterval = record.Original_Interval__c == null
            ? null
            : Integer.valueOf(record.Original_Interval__c);
        request.originalPriceId = record.Original_Stripe_Price_Id__c;
        request.originalCancelAt = record.Original_Stripe_Cancel_At__c == null
            ? null
            : record.Original_Stripe_Cancel_At__c.getTime() / 1000;
        request.restorationScheduleId = record.Restoration_Schedule__c;
        request.restorationFirstPaymentDate = record.Restoration_First_Payment_Date__c;
        request.plannedInstallments = record.Requested_Installments__c == null
            ? null
            : Integer.valueOf(record.Requested_Installments__c);
        request.salesforceGiftCommitmentId = String.valueOf(record.Gift_Commitment__c);
        request.salesforceChangeId = String.valueOf(record.Id);
        request.idempotencyKey = record.Idempotency_Key__c;
        request.stopBillingImmediately = record.Stop_Stripe_Billing_Immediately__c;
        request.targetPriceId = record.Stripe_Price_Id__c;
        return request;
    }

    private static void markAccepted(
        Stripe_Subscription_Change__c requestRecord,
        Integer attemptCount,
        StripeRecurringScheduleGateway.ChangeResult result
    ) {
        Boolean scheduled = result.actionMode == 'Scheduled';
        requestRecord.Status__c = scheduled ? 'Scheduled' : 'Synced';
        requestRecord.Stripe_Action_Mode__c = result.actionMode;
        requestRecord.Attempt_Count__c = attemptCount;
        requestRecord.Stripe_Schedule_Id__c = result.subscriptionScheduleId;
        requestRecord.Stripe_Price_Id__c = result.priceId;
        requestRecord.Stripe_Invoice_Id__c = result.invoiceId;
        requestRecord.Stripe_Effective_Timestamp__c = result.effectiveTimestamp;
        requestRecord.Synced_At__c = scheduled ? null : System.now();
        requestRecord.Billing_Stopped_At__c = requestRecord.Stop_Stripe_Billing_Immediately__c
            ? result.billingStoppedAt
            : null;
        requestRecord.Last_Error__c = null;
        update requestRecord;

        GiftCommitment parent = new GiftCommitment(
            Id = requestRecord.Gift_Commitment__c,
            Stripe_Schedule_Sync_Status__c = requestRecord.Status__c,
            Stripe_Schedule_Sync_Message__c = scheduled
                ? 'Stripe change is scheduled for ' + String.valueOf(requestRecord.Requested_Effective_Date__c) + '.'
                : 'Stripe subscription change applied with no proration.',
            Stripe_Schedule_Synced_At__c = scheduled ? null : System.now()
        );
        if (!scheduled) parent.Price_Id__c = result.priceId;
        update parent;
    }

    private static void markFailed(
        Stripe_Subscription_Change__c requestRecord,
        String message,
        Integer attemptCount,
        StripeRecurringScheduleGateway.ChangeResult result
    ) {
        String safeMessage = sanitize(message);
        requestRecord.Status__c = 'Failed';
        requestRecord.Attempt_Count__c = attemptCount;
        requestRecord.Last_Error__c = safeMessage;
        if (result != null) {
            requestRecord.Stripe_Action_Mode__c = result.actionMode;
            requestRecord.Stripe_Price_Id__c = result.priceId;
            requestRecord.Stripe_Invoice_Id__c = result.invoiceId;
            requestRecord.Stripe_Pending_Update_Id__c = result.invoiceId;
            requestRecord.Stripe_Pending_Update_Expires_At__c = result.pendingUpdateExpiresAt;
            requestRecord.Stripe_Effective_Timestamp__c = result.effectiveTimestamp;
        }
        update requestRecord;
        update new GiftCommitment(
            Id = requestRecord.Gift_Commitment__c,
            Stripe_Schedule_Sync_Status__c = 'Failed',
            Stripe_Schedule_Sync_Message__c = safeMessage.left(255)
        );
        // Published right after the DML above, so no later callout in this transaction is affected.
        StripeFailureLogger.record(StripeFailureLogger.failure(
                StripeFailureLogger.SOURCE_RECURRING_SYNC, StripeFailureLogger.CODE_RECURRING_SYNC_FAILED,
                'Recurring donation change could not be synced to Stripe')
            .withError(safeMessage)
            .operation('StripeRecurringScheduleChangeService.markFailed')
            .commitment(requestRecord.Gift_Commitment__c)
            .subscriptionChange(requestRecord.Id));
        StripeFailureLogger.flush();
    }

    private static Boolean isEnabled() {
        Stripe_Recurring_Sync_Config__mdt config = StripeRecurringSyncConfig.resolve();
        return config != null && config.Enabled__c == true;
    }

    private static Integer getMaxAttempts() {
        Stripe_Recurring_Sync_Config__mdt config = StripeRecurringSyncConfig.resolve();
        return config == null || config.Max_Attempts__c == null ? 3 : Integer.valueOf(config.Max_Attempts__c);
    }

    private static String sanitize(String message) {
        if (String.isBlank(message)) return 'Stripe recurring schedule synchronization failed.';
        return message.replaceAll('(?i)(sk|rk)_(test|live)_[A-Za-z0-9_]+', '[REDACTED]').left(1000);
    }

    private static Boolean hasPaidTransactionToday(Id giftCommitmentId) {
        if (giftCommitmentId == null) return false;
        Date today = Date.today();
        for (GiftTransaction transactionRecord : [
            SELECT Id, TransactionDate, TransactionDueDate
            FROM GiftTransaction
            WHERE GiftCommitmentId = :giftCommitmentId
              AND Status = 'Paid'
              AND (TransactionDate = :today OR TransactionDueDate = :today)
            LIMIT 50
        ]) {
            if (transactionRecord.TransactionDate == today ||
                (transactionRecord.TransactionDate == null && transactionRecord.TransactionDueDate == today)) {
                return true;
            }
        }
        return false;
    }

    private static ProcessResult toProcessResult(Stripe_Subscription_Change__c record, Boolean success) {
        ProcessResult result = new ProcessResult();
        result.requestId = record.Id;
        result.success = success;
        result.status = record.Status__c;
        result.billingStoppedAt = record.Billing_Stopped_At__c;
        result.scheduledPaymentDate = record.Requested_First_Payment_Date__c;
        result.stripeScheduleId = record.Stripe_Schedule_Id__c;
        result.errorMessage = record.Last_Error__c;
        return result;
    }

    public class ProcessResult {
        public Id requestId;
        public Boolean success;
        public String status;
        public Datetime billingStoppedAt;
        public Date scheduledPaymentDate;
        public String stripeScheduleId;
        public String errorMessage;
    }

    private class Candidate {
        GiftCommitment commitment;
        GiftCommitmentSchedule schedule;
        GiftTransaction nextTransaction;
        Date effectiveDate;
        Date firstPaymentDate;
        Date finalPaymentDate;
        Date requestedConfigurationStartDate;
        Date requestedConfigurationEndDate;
        Date effectiveEndDate;
        Decimal requestedAmount;
        String requestedPeriod;
        Integer intervalCount;
        String transactionDay;
        Decimal originalAmount;
        String originalPeriod;
        Integer originalInterval;
        String originalPriceId;
        Datetime originalCancelAt;
        Id restorationScheduleId;
        Date restorationFirstPaymentDate;
        String recurringType;
        Integer installments;
        String changeMode;
        Boolean stopBillingImmediately;
        String dateCalculationError;
        String idempotencyKey;
    }

    /** Values captured by the guided Flow when the managed schedule itself is locked by paid history. */
    public class GuidedOverride {
        public Id targetScheduleId;
        public Decimal amount;
        public String period;
        public Integer intervalCount;
        public String transactionDay;
        public String recurringType;
        public Date configurationStartDate;
        public Date configurationEndDate;
        public Boolean configurationEndDateIsSet;
        public Date firstPaymentDate;
        public Date finalPaymentDate;
        public Boolean finalPaymentDateIsSet;
        public Integer installments;
        public Boolean endDateOnlyTransition;
        public Date effectiveEndDate;
        public Decimal originalAmount;
        public String originalPeriod;
        public Integer originalInterval;
        public String originalTransactionDay;
        public Date originalStartDate;
        public Date originalEndDate;
        public String originalPriceId;
        public Datetime originalCancelAt;
        public Id restorationScheduleId;
        public Date restorationFirstPaymentDate;
    }

    public class StripeRecurringScheduleServiceException extends Exception {}
}