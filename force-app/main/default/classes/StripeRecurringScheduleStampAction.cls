/**
 * Stamps the managed schedule with the chosen Stripe date and calculated payment dates.
 */
public with sharing class StripeRecurringScheduleStampAction {
    /** Finds the managed schedule created by the guided action and stamps Stripe planning fields. */
    @InvocableMethod(
        label='Stamp Stripe Recurring Donation Schedule'
        description='Stores the chosen configuration date, first payment date, recurring type, and installment plan on the managed schedule.'
        category='Stripe Recurring Donations'
    )
    public static List<Response> execute(List<Request> requests) {
        if (requests == null) return new List<Response>();
        Set<Id> commitmentIds = new Set<Id>();
        for (Request request : requests) {
            if (request != null && request.giftCommitmentId != null && request.effectiveDate != null) {
                commitmentIds.add(request.giftCommitmentId);
            }
        }
        Map<Id, List<GiftCommitmentSchedule>> schedulesByCommitment = new Map<Id, List<GiftCommitmentSchedule>>();
        Map<Id, GiftCommitmentSchedule> schedulesById = new Map<Id, GiftCommitmentSchedule>();
        if (!commitmentIds.isEmpty()) {
            for (GiftCommitmentSchedule schedule : [
                SELECT Id, GiftCommitmentId, TransactionAmount, TransactionPeriod, TransactionInterval,
                       StartDate, EndDate, TransactionDay, Stripe_Change_Effective_Date__c, Number_of_Planned_Installments__c
                       , Stop_Stripe_Billing_Immediately__c
                FROM GiftCommitmentSchedule
                WHERE GiftCommitmentId IN :commitmentIds
                ORDER BY LastModifiedDate DESC, CreatedDate DESC
            ]) {
                if (!schedulesByCommitment.containsKey(schedule.GiftCommitmentId)) {
                    schedulesByCommitment.put(schedule.GiftCommitmentId, new List<GiftCommitmentSchedule>());
                }
                schedulesByCommitment.get(schedule.GiftCommitmentId).add(schedule);
                schedulesById.put(schedule.Id, schedule);
            }
        }

        Map<Id, GiftCommitment> commitmentsById = commitmentIds.isEmpty()
            ? new Map<Id, GiftCommitment>()
            : new Map<Id, GiftCommitment>([
                SELECT Id, NextTransactionDate
                FROM GiftCommitment
                WHERE Id IN :commitmentIds
            ]);
        Map<Id, Date> earliestUnpaidByCommitment = new Map<Id, Date>();
        if (!commitmentIds.isEmpty()) {
            for (GiftTransaction transactionRecord : [
                SELECT GiftCommitmentId, TransactionDueDate
                FROM GiftTransaction
                WHERE GiftCommitmentId IN :commitmentIds
                  AND Status IN ('Pledged', 'Unpaid')
                  AND TransactionDueDate >= TODAY
                ORDER BY GiftCommitmentId, TransactionDueDate, CreatedDate
            ]) {
                if (!earliestUnpaidByCommitment.containsKey(transactionRecord.GiftCommitmentId)) {
                    earliestUnpaidByCommitment.put(
                        transactionRecord.GiftCommitmentId,
                        transactionRecord.TransactionDueDate
                    );
                }
            }
        }

        List<Response> responses = new List<Response>();
        List<GiftCommitmentSchedule> updates = new List<GiftCommitmentSchedule>();
        List<Integer> responseIndexes = new List<Integer>();
        for (Request request : requests) {
            Response response = new Response();
            responses.add(response);
            if (request == null || request.effectiveDate == null) {
                response.isSuccess = true;
                continue;
            }
            GiftCommitmentSchedule match = request.selectedScheduleId == null
                ? null
                : schedulesById.get(request.selectedScheduleId);
            if (match != null && match.GiftCommitmentId != request.giftCommitmentId) match = null;
            if (request.changeMode == StripeRecurringChangeMode.TEMPORARY_TERMS &&
                !scheduleMatchesTemporaryTarget(match, request)) {
                match = null;
            }
            if (match == null) match = findMatch(request, schedulesByCommitment.get(request.giftCommitmentId));
            if (match == null) {
                response.isSuccess = false;
                response.errorMessage = 'The managed schedule created for the Stripe change could not be identified.';
                response.errorType = 'SCHEDULE_NOT_FOUND';
                continue;
            }
            // Reclassify the final saved terms instead of trusting a stale
            // Flow hint. End-Date-only Open/Fixed transitions never go down
            // the Price-changing Terms path.
            request.changeMode = resolveFinalChangeMode(request, match);
            String normalizedTransactionDay = 'Monthly'.equalsIgnoreCase(request.transactionPeriod)
                ? StripeRDScheduleDateCalc.normalizeTransactionDay(request.transactionDay)
                : null;
            if (request.changeMode == StripeRecurringChangeMode.TERMS &&
                'Monthly'.equalsIgnoreCase(request.transactionPeriod) &&
                normalizedTransactionDay == null) {
                response.isSuccess = false;
                response.errorMessage =
                    'Transaction Day is required for Monthly. Stripe was not updated.';
                response.errorType = 'INVALID_TRANSACTION_DAY';
                continue;
            }
            if (request.changeMode == StripeRecurringChangeMode.TERMS &&
                'Monthly'.equalsIgnoreCase(request.transactionPeriod) &&
                match.TransactionDay != normalizedTransactionDay) {
                response.isSuccess = false;
                response.errorMessage =
                    'Salesforce did not preserve the requested Monthly Transaction Day. Stripe was not updated.';
                response.errorType = 'SALESFORCE_TRANSACTION_DAY_MISMATCH';
                continue;
            }
            GiftCommitmentSchedule restorationSchedule = null;
            if (request.changeMode == StripeRecurringChangeMode.TEMPORARY_TERMS) {
                restorationSchedule = findRestorationSchedule(
                    request,
                    schedulesByCommitment.get(request.giftCommitmentId)
                );
                if (request.effectiveEndDate == null || restorationSchedule == null) {
                    response.isSuccess = false;
                    response.errorMessage = 'The managed restoration schedule for the temporary change could not be verified.';
                    response.errorType = 'RESTORATION_SCHEDULE_NOT_FOUND';
                    continue;
                }
            }
            Date normalizedFirstPaymentDate = request.firstPaymentDate;
            Date normalizedFinalPaymentDate = request.finalPaymentDate;
            Integer normalizedInstallments = request.plannedInstallments;
            Date requestedStartDate = request.requestedStartDate;
            Date requestedEndDate = request.requestedEndDate;
            Boolean preserveExistingStartDate = request.changeMode == StripeRecurringChangeMode.END_DATE_ONLY ||
                request.changeMode == StripeRecurringChangeMode.TEMPORARY_TERMS ||
                (request.changeMode == StripeRecurringChangeMode.TERMS &&
                 request.effectiveDate == Date.today() &&
                 requestedStartDate == match.StartDate);
            if (requestedStartDate != null && !preserveExistingStartDate) {
                StripeRDScheduleDateCalc.Result dateResult =
                    StripeRDScheduleDateCalc.calculate(
                        requestedStartDate,
                        requestedEndDate,
                        Date.today(),
                        request.transactionPeriod,
                        request.transactionInterval,
                        request.recurringType
                    );
                if (dateResult.error != null) {
                    response.isSuccess = false;
                    response.errorMessage = dateResult.error;
                    response.errorType = 'INVALID_PAYMENT_DATES';
                    continue;
                }
                normalizedFirstPaymentDate = dateResult.firstPaymentDate;
                normalizedFinalPaymentDate = dateResult.finalPaymentDate;
                normalizedInstallments = dateResult.installments;
            }
            if (normalizedFirstPaymentDate == null) {
                response.isSuccess = false;
                response.errorMessage = 'The first recurring payment date could not be calculated.';
                response.errorType = 'MISSING_FIRST_PAYMENT_DATE';
                continue;
            }
            // Preserve compatibility for callers that still provide only an
            // installment count. Guided Update Dates requests always supply
            // requestedStartDate/requestedEndDate and therefore take the
            // server-derived path above.
            if (request.recurringType == 'Fixed' && normalizedFinalPaymentDate == null &&
                normalizedInstallments != null && normalizedInstallments > 0) {
                normalizedFinalPaymentDate = normalizedFirstPaymentDate;
                for (Integer installmentIndex = 1; installmentIndex < normalizedInstallments; installmentIndex++) {
                    normalizedFinalPaymentDate = StripeRDScheduleDateCalc.addPeriod(
                        normalizedFinalPaymentDate,
                        request.transactionPeriod,
                        request.transactionInterval
                    );
                }
            }
            // Derive Fixed values server-side when a legacy caller supplies
            // the dates but omits the count.  This is especially important
            // after a payment: the immutable historical StartDate must remain
            // untouched, while the count must begin at the first future
            // payment and not be inferred from paid history.
            if (request.recurringType == 'Fixed' &&
                (normalizedInstallments == null || normalizedFinalPaymentDate == null) &&
                requestedStartDate != null && requestedEndDate != null) {
                StripeRDScheduleDateCalc.Result derivedFixedDates =
                    StripeRDScheduleDateCalc.calculate(
                        requestedStartDate,
                        requestedEndDate,
                        Date.today(),
                        request.transactionPeriod,
                        request.transactionInterval,
                        'Fixed'
                    );
                if (derivedFixedDates.error != null) {
                    response.isSuccess = false;
                    response.errorMessage = derivedFixedDates.error;
                    response.errorType = 'INVALID_PAYMENT_DATES';
                    continue;
                }
                normalizedFirstPaymentDate = derivedFixedDates.firstPaymentDate;
                normalizedFinalPaymentDate = derivedFixedDates.finalPaymentDate;
                normalizedInstallments = derivedFixedDates.installments;
            }
            if (request.recurringType == 'Fixed' &&
                (normalizedInstallments == null || normalizedInstallments < 1 || normalizedFinalPaymentDate == null)) {
                response.isSuccess = false;
                response.errorMessage = 'A Fixed recurring donation needs a valid end date and calculated installments.';
                response.errorType = 'INVALID_FIXED_DATES';
                continue;
            }
            if (request.changeMode == StripeRecurringChangeMode.TERMS &&
                request.createRequestAfterSave == true) {
                GiftCommitment commitment = commitmentsById.get(request.giftCommitmentId);
                Date earliestUnpaid = earliestUnpaidByCommitment.get(request.giftCommitmentId);
                if (commitment == null || earliestUnpaid == null ||
                    normalizedFirstPaymentDate != earliestUnpaid ||
                    normalizedFirstPaymentDate != commitment.NextTransactionDate) {
                    response.isSuccess = false;
                    response.expectedFirstPaymentDate = normalizedFirstPaymentDate;
                    response.salesforceNextTransactionDate = commitment == null
                        ? null
                        : commitment.NextTransactionDate;
                    response.earliestFutureUnpaidDate = earliestUnpaid;
                    response.sourceScheduleId = request.resolvedSourceScheduleId;
                    response.successorScheduleId = match.Id;
                    response.errorMessage =
                        'Salesforce billing-date mismatch. Expected first payment: ' +
                        String.valueOf(normalizedFirstPaymentDate) +
                        '; Gift Commitment next payment: ' +
                        String.valueOf(response.salesforceNextTransactionDate) +
                        '; earliest future unpaid payment: ' +
                        String.valueOf(earliestUnpaid) +
                        '; source schedule: ' + String.valueOf(request.resolvedSourceScheduleId) +
                        '; successor schedule: ' + String.valueOf(match.Id) +
                        '. Stripe was not updated.';
                    response.errorType = 'SALESFORCE_BILLING_DATE_MISMATCH';
                    continue;
                }
            }
            match.Stripe_Change_Effective_Date__c = request.effectiveDate;
            match.Stop_Stripe_Billing_Immediately__c = request.stopBillingImmediately == true ||
                request.bridgeBillingGap == true;
            match.Number_of_Planned_Installments__c = request.changeMode == StripeRecurringChangeMode.TEMPORARY_TERMS
                ? request.temporaryInstallments
                : (request.recurringType == 'Fixed' ? normalizedInstallments : null);
            match.EndDate = request.changeMode == StripeRecurringChangeMode.TEMPORARY_TERMS
                ? request.effectiveEndDate
                : (request.recurringType == 'Fixed' ? normalizedFinalPaymentDate : null);
            updates.add(match);
            responseIndexes.add(responses.size() - 1);
        }

        if (!updates.isEmpty()) {
            Database.SaveResult[] saveResults = Database.update(updates, false);
            for (Integer index = 0; index < saveResults.size(); index++) {
                Response response = responses[responseIndexes[index]];
                if (saveResults[index].isSuccess()) {
                    response.isSuccess = true;
                    response.scheduleId = updates[index].Id;
                    StripeRecurringScheduleStampAction.Request completedRequest =
                        requests[responseIndexes[index]];
                    if (completedRequest.stopBillingImmediately == true ||
                        completedRequest.bridgeBillingGap == true ||
                        completedRequest.createRequestAfterSave == true) {
                        StripeRecurringScheduleChangeService.GuidedOverride guidedOverride =
                            new StripeRecurringScheduleChangeService.GuidedOverride();
                        guidedOverride.targetScheduleId = updates[index].Id;
                        guidedOverride.amount = completedRequest.amount;
                        guidedOverride.period = completedRequest.transactionPeriod;
                        guidedOverride.intervalCount = completedRequest.transactionInterval;
                        guidedOverride.transactionDay = 'Monthly'.equalsIgnoreCase(completedRequest.transactionPeriod)
                            ? StripeRDScheduleDateCalc.normalizeTransactionDay(completedRequest.transactionDay)
                            : null;
                        guidedOverride.recurringType = completedRequest.recurringType;
                        guidedOverride.configurationStartDate = completedRequest.changeMode == StripeRecurringChangeMode.TEMPORARY_TERMS
                            ? completedRequest.effectiveDate
                            : updates[index].StartDate;
                        guidedOverride.configurationEndDate = completedRequest.recurringType == 'Fixed'
                            ? updates[index].EndDate
                            : null;
                        guidedOverride.configurationEndDateIsSet = true;
                        guidedOverride.firstPaymentDate = completedRequest.firstPaymentDate;
                        guidedOverride.finalPaymentDate = completedRequest.recurringType == 'Fixed'
                            ? updates[index].EndDate
                            : null;
                        guidedOverride.finalPaymentDateIsSet = true;
                        guidedOverride.installments = completedRequest.recurringType == 'Fixed'
                            ? updates[index].Number_of_Planned_Installments__c == null
                                ? null
                                : Integer.valueOf(updates[index].Number_of_Planned_Installments__c)
                            : null;
                        guidedOverride.endDateOnlyTransition = completedRequest.changeMode ==
                            StripeRecurringChangeMode.END_DATE_ONLY;
                        guidedOverride.originalAmount = completedRequest.originalAmount;
                        guidedOverride.originalPeriod = completedRequest.originalPeriod;
                        guidedOverride.originalInterval = completedRequest.originalInterval;
                        guidedOverride.originalTransactionDay = completedRequest.originalTransactionDay;
                        guidedOverride.originalStartDate = completedRequest.originalStartDate;
                        guidedOverride.originalEndDate = completedRequest.previousEndDate;
                        if (completedRequest.changeMode == StripeRecurringChangeMode.TEMPORARY_TERMS) {
                            guidedOverride.effectiveEndDate = completedRequest.effectiveEndDate;
                            guidedOverride.originalPriceId = completedRequest.originalPriceId;
                            guidedOverride.originalCancelAt = completedRequest.originalCancelAt;
                            GiftCommitmentSchedule restored = findRestorationSchedule(
                                completedRequest,
                                schedulesByCommitment.get(completedRequest.giftCommitmentId)
                            );
                            guidedOverride.restorationScheduleId = restored == null ? null : restored.Id;
                            guidedOverride.restorationFirstPaymentDate = completedRequest.restorationFirstPaymentDate;
                        }
                        response.requestId = completedRequest.stopBillingImmediately == true
                            ? StripeRecurringScheduleChangeService.createGuidedRequestForGiftCommitment(
                                completedRequest.giftCommitmentId,
                                completedRequest.changeMode,
                                guidedOverride
                            )
                            : StripeRecurringScheduleChangeService.createGuidedRequestAndEnqueueForGiftCommitment(
                                completedRequest.giftCommitmentId,
                                completedRequest.changeMode,
                                guidedOverride
                            );
                        if (response.requestId == null) {
                            response.isSuccess = false;
                            response.errorMessage = 'The durable Stripe change request could not be created.';
                            response.errorType = 'REQUEST_NOT_CREATED';
                        }
                    }
                } else {
                    response.isSuccess = false;
                    response.errorMessage = saveResults[index].getErrors()[0].getMessage().left(1000);
                    response.errorType = String.valueOf(saveResults[index].getErrors()[0].getStatusCode());
                }
            }
        }
        return responses;
    }

    @TestVisible
    private static GiftCommitmentSchedule findMatch(Request request, List<GiftCommitmentSchedule> schedules) {
        if (schedules == null) return null;
        Date managedScheduleStartDate = request.managedScheduleStartDate == null
            ? request.firstPaymentDate
            : request.managedScheduleStartDate;
        GiftCommitmentSchedule matchedSchedule;
        for (GiftCommitmentSchedule schedule : schedules) {
            Integer intervalCount = schedule.TransactionInterval == null ? 1 : Integer.valueOf(schedule.TransactionInterval);
            Boolean dateMatches = request.changeMode == StripeRecurringChangeMode.TEMPORARY_TERMS
                ? schedule.StartDate == request.effectiveDate
                : schedule.StartDate == managedScheduleStartDate;
            if (dateMatches &&
                schedule.TransactionAmount == request.amount &&
                schedule.TransactionPeriod == request.transactionPeriod &&
                intervalCount == request.transactionInterval &&
                (!'Monthly'.equalsIgnoreCase(request.transactionPeriod) ||
                    schedule.TransactionDay == StripeRDScheduleDateCalc.normalizeTransactionDay(request.transactionDay))) {
                if (matchedSchedule != null) return null;
                matchedSchedule = schedule;
            }
        }
        return matchedSchedule;
    }

    private static Boolean scheduleMatchesTemporaryTarget(
        GiftCommitmentSchedule schedule,
        Request request
    ) {
        if (schedule == null || request == null) return false;
        Integer intervalCount = schedule.TransactionInterval == null
            ? 1
            : Integer.valueOf(schedule.TransactionInterval);
        return schedule.StartDate == request.effectiveDate &&
            schedule.TransactionAmount == request.amount &&
            schedule.TransactionPeriod == request.transactionPeriod &&
            intervalCount == request.transactionInterval;
    }

    private static GiftCommitmentSchedule findRestorationSchedule(
        Request request,
        List<GiftCommitmentSchedule> schedules
    ) {
        if (request == null || schedules == null || request.effectiveEndDate == null) return null;
        Date restorationStart = request.effectiveEndDate.addDays(1);
        for (GiftCommitmentSchedule schedule : schedules) {
            Integer intervalCount = schedule.TransactionInterval == null
                ? 1
                : Integer.valueOf(schedule.TransactionInterval);
            if (schedule.StartDate == restorationStart &&
                schedule.TransactionAmount == request.originalAmount &&
                schedule.TransactionPeriod == request.originalPeriod &&
                intervalCount == request.originalInterval) {
                return schedule;
            }
        }
        return null;
    }

    /**
     * Derives the durable mode from the original End Date and the schedule
     * Salesforce actually saved. This makes cancellation-only transitions
     * resilient to stale Flow output variables.
     */
    @TestVisible
    private static String resolveFinalChangeMode(Request request, GiftCommitmentSchedule savedSchedule) {
        if (request == null || savedSchedule == null) return StripeRecurringChangeMode.TERMS;
        if (request.changeMode == StripeRecurringChangeMode.TEMPORARY_TERMS) {
            return StripeRecurringChangeMode.TEMPORARY_TERMS;
        }
        if (request.originalAmount != null && String.isNotBlank(request.originalPeriod) &&
            request.originalInterval != null) {
            Boolean billingTermsChanged = request.originalAmount != request.amount ||
                request.originalPeriod != request.transactionPeriod ||
                request.originalInterval != request.transactionInterval ||
                ('Monthly'.equalsIgnoreCase(request.originalPeriod) &&
                 'Monthly'.equalsIgnoreCase(request.transactionPeriod) &&
                 request.originalTransactionDay != null &&
                 StripeRDScheduleDateCalc.normalizeTransactionDay(request.originalTransactionDay) !=
                     StripeRDScheduleDateCalc.normalizeTransactionDay(request.transactionDay));
            if (billingTermsChanged) return StripeRecurringChangeMode.TERMS;
            Boolean startChanged = request.originalStartDate != null &&
                request.requestedStartDate != null &&
                request.originalStartDate != request.requestedStartDate;
            if (!startChanged && request.previousEndDate != request.requestedEndDate) {
                return StripeRecurringChangeMode.END_DATE_ONLY;
            }
            return request.changeMode == StripeRecurringChangeMode.END_DATE_ONLY
                ? StripeRecurringChangeMode.TERMS
                : request.changeMode;
        }
        Integer savedInterval = savedSchedule.TransactionInterval == null
            ? 1
            : Integer.valueOf(savedSchedule.TransactionInterval);
        Boolean onlyEndDateChanged = request.previousEndDate != request.requestedEndDate &&
            (request.requestedStartDate == null || request.requestedStartDate == savedSchedule.StartDate) &&
            request.amount == savedSchedule.TransactionAmount &&
            request.transactionPeriod == savedSchedule.TransactionPeriod &&
            request.transactionInterval == savedInterval;
        return onlyEndDateChanged
            ? StripeRecurringChangeMode.END_DATE_ONLY
            : request.changeMode;
    }

    public class Request {
        @InvocableVariable(label='Gift Commitment ID' required=true) public Id giftCommitmentId;
        @InvocableVariable(label='Requested Amount' required=true) public Decimal amount;
        @InvocableVariable(label='Requested Period' required=true) public String transactionPeriod;
        @InvocableVariable(label='Requested Interval' required=true) public Integer transactionInterval;
        @InvocableVariable(label='Requested Transaction Day') public String transactionDay;
        @InvocableVariable(label='Change Effective Date' required=true) public Date effectiveDate;
        @InvocableVariable(label='Effective End Date') public Date effectiveEndDate;
        @InvocableVariable(label='Managed Salesforce Schedule Start Date') public Date managedScheduleStartDate;
        @InvocableVariable(label='First Actual Payment Date' required=true) public Date firstPaymentDate;
        @InvocableVariable(label='Final Payment Date') public Date finalPaymentDate;
        @InvocableVariable(label='Requested Configuration Start Date') public Date requestedStartDate;
        @InvocableVariable(label='Requested Configuration End Date') public Date requestedEndDate;
        @InvocableVariable(label='Previous Configuration End Date') public Date previousEndDate;
        @InvocableVariable(label='Change Mode') public String changeMode;
        @InvocableVariable(label='Selected Gift Commitment Schedule ID') public Id selectedScheduleId;
        @InvocableVariable(label='Resolved Source Schedule ID') public Id resolvedSourceScheduleId;
        @InvocableVariable(label='Recurring Type' required=true) public String recurringType;
        @InvocableVariable(label='Planned Installments') public Integer plannedInstallments;
        @InvocableVariable(label='Stop Stripe Billing Immediately') public Boolean stopBillingImmediately;
        @InvocableVariable(label='Bridge Future Billing Gap') public Boolean bridgeBillingGap;
        @InvocableVariable(label='Create Durable Request After Save') public Boolean createRequestAfterSave;
        @InvocableVariable(label='Temporary Installment Count') public Integer temporaryInstallments;
        @InvocableVariable(label='Original Amount') public Decimal originalAmount;
        @InvocableVariable(label='Original Period') public String originalPeriod;
        @InvocableVariable(label='Original Interval') public Integer originalInterval;
        @InvocableVariable(label='Original Transaction Day') public String originalTransactionDay;
        @InvocableVariable(label='Original Schedule Start Date') public Date originalStartDate;
        @InvocableVariable(label='Original Stripe Price ID') public String originalPriceId;
        @InvocableVariable(label='Original Stripe Cancel At') public Datetime originalCancelAt;
        @InvocableVariable(label='Restoration First Payment Date') public Date restorationFirstPaymentDate;
    }

    public class Response {
        @InvocableVariable(label='Success') public Boolean isSuccess;
        @InvocableVariable(label='Schedule ID') public Id scheduleId;
        @InvocableVariable(label='Stripe Change Request ID') public Id requestId;
        @InvocableVariable(label='Error Message') public String errorMessage;
        @InvocableVariable(label='Error Type') public String errorType;
        @InvocableVariable(label='Expected First Payment Date') public Date expectedFirstPaymentDate;
        @InvocableVariable(label='Salesforce Next Transaction Date') public Date salesforceNextTransactionDate;
        @InvocableVariable(label='Earliest Future Unpaid Date') public Date earliestFutureUnpaidDate;
        @InvocableVariable(label='Source Schedule ID') public Id sourceScheduleId;
        @InvocableVariable(label='Successor Schedule ID') public Id successorScheduleId;
    }
}