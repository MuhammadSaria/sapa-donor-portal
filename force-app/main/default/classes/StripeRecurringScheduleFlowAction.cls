/**
 * Read-only Flow action that previews a composite recurring donation change in Stripe.
 */
public with sharing class StripeRecurringScheduleFlowAction {
    private static final String FIRST_PAYMENT_TODAY_MESSAGE =
        'A payment has already been taken today. You cannot change the Start Date effective today. ' +
        'Select the next unpaid payment date or a later date.';

    /** Returns a Stripe preview for each Flow request. */
    @InvocableMethod(
        label='Preview Stripe Recurring Donation Change'
        description='Reads Stripe and returns billing impact, first payment, final payment, and warnings without making changes.'
        category='Stripe Recurring Donations'
        callout=true
    )
    public static List<Response> execute(List<Request> requests) {
        if (requests == null) return new List<Response>();
        Set<Id> commitmentIds = new Set<Id>();
        for (Request request : requests) {
            if (request != null) {
                if (request.giftCommitmentId != null) commitmentIds.add(request.giftCommitmentId);
            }
        }
        Map<Id, GiftCommitment> commitments = commitmentIds.isEmpty()
            ? new Map<Id, GiftCommitment>()
            : new Map<Id, GiftCommitment>([
                SELECT Id, Subscription_Id__c, Product_Id__c, Price_Id__c, CurrencyIsoCode,
                       Recurring_Type__c, Payment_Processor__c, Payment_type__c
                FROM GiftCommitment WHERE Id IN :commitmentIds
            ]);

        Map<Id, GiftCommitmentSchedule> selectedSchedules = new Map<Id, GiftCommitmentSchedule>();
        Map<Id, List<GiftCommitmentSchedule>> schedulesByCommitment = new Map<Id, List<GiftCommitmentSchedule>>();
        if (!commitmentIds.isEmpty()) {
            for (GiftCommitmentSchedule schedule : [
                SELECT Id, GiftCommitmentId, StartDate, EndDate, TransactionAmount,
                       TransactionPeriod, TransactionInterval, TransactionDay
                FROM GiftCommitmentSchedule
                WHERE GiftCommitmentId IN :commitmentIds
                ORDER BY GiftCommitmentId, StartDate DESC, CreatedDate DESC
            ]) {
                selectedSchedules.put(schedule.Id, schedule);
                if (!schedulesByCommitment.containsKey(schedule.GiftCommitmentId)) {
                    schedulesByCommitment.put(schedule.GiftCommitmentId, new List<GiftCommitmentSchedule>());
                }
                schedulesByCommitment.get(schedule.GiftCommitmentId).add(schedule);
            }
        }

        Set<Id> paidTodayCommitmentIds = new Set<Id>();
        Map<Id, Date> latestPaidDateByCommitment = new Map<Id, Date>();
        Map<Id, Date> nextAllowedEffectiveDateByCommitment = new Map<Id, Date>();
        if (!commitmentIds.isEmpty()) {
            Date today = Date.today();
            for (GiftTransaction transactionRecord : [
                SELECT Id, GiftCommitmentId, TransactionDate, TransactionDueDate
                FROM GiftTransaction
                WHERE GiftCommitmentId IN :commitmentIds
                  AND Status = 'Paid'
                ORDER BY GiftCommitmentId, CreatedDate
            ]) {
                Date paidDate = transactionRecord.TransactionDate == null
                    ? transactionRecord.TransactionDueDate
                    : transactionRecord.TransactionDate;
                Boolean paidToday = paidDate == today;
                if (paidToday) paidTodayCommitmentIds.add(transactionRecord.GiftCommitmentId);
                Date currentLatest = latestPaidDateByCommitment.get(transactionRecord.GiftCommitmentId);
                if (paidDate != null && (currentLatest == null || paidDate > currentLatest)) {
                    latestPaidDateByCommitment.put(transactionRecord.GiftCommitmentId, paidDate);
                }
            }
            for (GiftTransaction transactionRecord : [
                SELECT Id, GiftCommitmentId, TransactionDueDate
                FROM GiftTransaction
                WHERE GiftCommitmentId IN :commitmentIds
                  AND Status IN ('Pledged', 'Unpaid')
                  AND TransactionDueDate > :today
                ORDER BY GiftCommitmentId, TransactionDueDate, CreatedDate
            ]) {
                if (!nextAllowedEffectiveDateByCommitment.containsKey(transactionRecord.GiftCommitmentId)) {
                    nextAllowedEffectiveDateByCommitment.put(
                        transactionRecord.GiftCommitmentId,
                        transactionRecord.TransactionDueDate
                    );
                }
            }
        }

        List<Response> responses = new List<Response>();
        for (Request request : requests) {
            responses.add(previewOne(
                request,
                commitments,
                selectedSchedules,
                schedulesByCommitment,
                paidTodayCommitmentIds,
                latestPaidDateByCommitment,
                nextAllowedEffectiveDateByCommitment
            ));
        }
        return responses;
    }

    private static Response previewOne(
        Request input,
        Map<Id, GiftCommitment> commitments,
        Map<Id, GiftCommitmentSchedule> selectedSchedules,
        Map<Id, List<GiftCommitmentSchedule>> schedulesByCommitment,
        Set<Id> paidTodayCommitmentIds,
        Map<Id, Date> latestPaidDateByCommitment,
        Map<Id, Date> nextAllowedEffectiveDateByCommitment
    ) {
        Response response = new Response();
        try {
            if (input == null || input.giftCommitmentId == null) {
                response.isSuccess = false;
                response.blockingError = 'The recurring donation could not be read.';
                response.errorType = 'MISSING_COMMITMENT';
                return response;
            }
            GiftCommitment commitment = input == null ? null : commitments.get(input.giftCommitmentId);
            if (commitment == null) {
                response.isSuccess = false;
                response.blockingError = 'The recurring donation could not be read.';
                response.errorType = 'MISSING_COMMITMENT';
                return response;
            }
            Boolean stripeClassified =
                'Stripe'.equalsIgnoreCase(commitment.Payment_Processor__c) ||
                'Credit Card'.equalsIgnoreCase(commitment.Payment_type__c) ||
                'Credit Card'.equalsIgnoreCase(input == null ? null : input.paymentMethod);
            if (!stripeClassified) {
                response.isSuccess = false;
                response.blockingError =
                    'This donation is not classified as Stripe or Credit Card. Save it through the Salesforce-only schedule path.';
                response.errorType = 'NOT_VERIFIED_STRIPE';
                return response;
            }
            if (String.isBlank(commitment.Subscription_Id__c)) {
                response.isSuccess = false;
                response.blockingError =
                    'This donation is marked as Stripe or Credit Card, but it has no Stripe subscription ID. ' +
                    'Save it through the Salesforce-only schedule path.';
                response.errorType = 'MISSING_SUBSCRIPTION';
                return response;
            }
            GiftCommitmentSchedule selectedSchedule = input.selectedScheduleId == null
                ? null
                : selectedSchedules.get(input.selectedScheduleId);
            if (selectedSchedule == null || selectedSchedule.GiftCommitmentId != commitment.Id) {
                response.isSuccess = false;
                response.blockingError = 'Select the Gift Commitment Schedule you want to change before previewing Stripe.';
                response.errorType = 'MISSING_SELECTED_SCHEDULE';
                return response;
            }
            String requestedRecurringType = input.recurringType == 'Open' || input.recurringType == 'Fixed'
                ? input.recurringType
                : commitment.Recurring_Type__c;
            if (requestedRecurringType != 'Open' && requestedRecurringType != 'Fixed') {
                response.isSuccess = false;
                response.blockingError = 'Set the parent Gift Commitment recurring type to Open or Fixed before previewing Stripe.';
                response.errorType = 'MISSING_PARENT_RECURRING_TYPE';
                return response;
            }
            Date requestedStartDate = input.requestedStartDate == null
                ? (input.proposedStartDate == null ? selectedSchedule.StartDate : input.proposedStartDate)
                : input.requestedStartDate;
            Date requestedEndDate = input.requestedEndDateIsSet == true
                ? input.requestedEndDate
                : (input.requestedEndDate == null
                    ? (input.proposedEndDate == null ? selectedSchedule.EndDate : input.proposedEndDate)
                    : input.requestedEndDate);
            StripeRecurringChangeMode.Result changeMode = StripeRecurringChangeMode.classify(
                selectedSchedule,
                commitment.Recurring_Type__c,
                input.amount,
                input.transactionPeriod,
                input.transactionInterval,
                requestedStartDate,
                requestedEndDate,
                requestedRecurringType,
                input.changeModeHint
            );
            if (input.effectiveEndDate != null &&
                changeMode.mode == StripeRecurringChangeMode.TERMS) {
                changeMode.mode = StripeRecurringChangeMode.TEMPORARY_TERMS;
            }
            response.changeMode = changeMode.mode;
            Date today = Date.today();
            String normalizedTransactionDay = 'Monthly'.equalsIgnoreCase(input.transactionPeriod)
                ? StripeRDScheduleDateCalc.normalizeTransactionDay(input.transactionDay)
                : null;
            if (changeMode.mode == StripeRecurringChangeMode.TERMS &&
                'Monthly'.equalsIgnoreCase(input.transactionPeriod) &&
                normalizedTransactionDay == null) {
                response.isSuccess = false;
                response.blockingError =
                    'Transaction Day is required for Monthly. Select a valid day before saving.';
                response.errorType = 'INVALID_TRANSACTION_DAY';
                return response;
            }
            if (input.effectiveDate != null && input.effectiveDate < today) {
                response.isSuccess = false;
                response.blockingError = 'The recurring donation change effective date cannot be in the past.';
                response.errorType = 'PAST_EFFECTIVE_DATE';
                return response;
            }
            if (changeMode.mode == StripeRecurringChangeMode.TEMPORARY_TERMS &&
                input.effectiveEndDate < input.effectiveDate) {
                response.isSuccess = false;
                response.blockingError = 'Effective End Date must be on or after Effective Start Date.';
                response.errorType = 'INVALID_TEMPORARY_WINDOW';
                return response;
            }
            Boolean paidToday = input.effectiveDate == today && paidTodayCommitmentIds.contains(commitment.Id);
            if (paidToday && changeMode.mode == StripeRecurringChangeMode.START_DATE_CHANGE) {
                response.isSuccess = false;
                response.blockingError = FIRST_PAYMENT_TODAY_MESSAGE;
                response.errorType = 'FIRST_PAYMENT_TODAY';
                response.nextAllowedEffectiveDate = nextAllowedEffectiveDateByCommitment.get(commitment.Id);
                return response;
            }
            response.sameDayMutationRequired = paidToday &&
                changeMode.mode == StripeRecurringChangeMode.END_DATE_ONLY;
            StripeRDScheduleDateCalc.Result dateResult = null;
            Boolean needsDateCalculation = changeMode.mode == StripeRecurringChangeMode.START_DATE_CHANGE ||
                changeMode.mode == StripeRecurringChangeMode.END_DATE_ONLY ||
                (changeMode.mode == StripeRecurringChangeMode.TERMS && changeMode.endDateChanged == true);
            if (needsDateCalculation && requestedStartDate != null) {
                if (changeMode.mode == StripeRecurringChangeMode.END_DATE_ONLY &&
                    requestedEndDate == today && paidToday) {
                    dateResult = new StripeRDScheduleDateCalc.Result();
                    dateResult.effectiveDate = today;
                    dateResult.firstPaymentDate = today;
                    dateResult.finalPaymentDate = today;
                    dateResult.installments = 1;
                } else {
                dateResult = StripeRDScheduleDateCalc.calculate(
                    requestedStartDate,
                    requestedEndDate,
                    today,
                    input.transactionPeriod,
                    input.transactionInterval,
                    requestedRecurringType
                );
                }
                response.dateNormalizationWarning = dateResult.warning;
                if (dateResult.error != null) {
                    response.isSuccess = false;
                    response.blockingError = dateResult.error;
                    response.errorType = 'INVALID_PAYMENT_DATES';
                    return response;
                }
            }
            StripeRDScheduleDateCalc.Result termBoundary = null;
            if (changeMode.mode == StripeRecurringChangeMode.TERMS && changeMode.endDateChanged != true &&
                (input.usePlannedTermsBoundary == true || input.effectiveDate == today)) {
                termBoundary = StripeRDScheduleDateCalc.calculateTermsBoundary(
                    latestPaidDateByCommitment.get(commitment.Id),
                    nextAllowedEffectiveDateByCommitment.get(commitment.Id),
                    today,
                    input.transactionPeriod,
                    input.transactionInterval,
                    changeMode.cadenceChanged,
                    selectedSchedule.TransactionDay,
                    normalizedTransactionDay
                );
                if (termBoundary.error != null) {
                    response.isSuccess = false;
                    response.blockingError = termBoundary.error;
                    response.errorType = 'INVALID_TERM_DATES';
                    return response;
                }
                GiftCommitmentSchedule resolvedSchedule = input.resolvedScheduleId == null
                    ? findScheduleOwningDate(
                        schedulesByCommitment.get(commitment.Id),
                        termBoundary.managedEffectiveFromDate
                    )
                    : selectedSchedules.get(input.resolvedScheduleId);
                if (resolvedSchedule == null || resolvedSchedule.GiftCommitmentId != commitment.Id ||
                    !ownsDate(resolvedSchedule, termBoundary.managedEffectiveFromDate)) {
                    response.isSuccess = false;
                    response.blockingError =
                        'Salesforce could not find a recurring donation schedule that owns the calculated change date. ' +
                        'Review the schedule dates before trying again.';
                    response.errorType = 'NO_SCHEDULE_OWNS_BOUNDARY';
                    return response;
                }
                response.resolvedScheduleId = resolvedSchedule.Id;
            }
            Integer calculatedInstallments = requestedRecurringType == 'Fixed'
                ? (dateResult == null ? calculateInstallments(input) : dateResult.installments)
                : null;
            StripeRecurringScheduleGateway.ChangeRequest request = new StripeRecurringScheduleGateway.ChangeRequest();
            request.subscriptionId = commitment.Subscription_Id__c;
            request.productId = commitment.Product_Id__c;
            request.currencyIsoCode = commitment.CurrencyIsoCode;
            request.amount = input.amount;
            request.transactionPeriod = input.transactionPeriod;
            request.transactionInterval = input.transactionInterval;
            request.effectiveDate = dateResult != null
                ? dateResult.effectiveDate
                : (termBoundary != null && termBoundary.effectiveDate != null
                    ? termBoundary.effectiveDate
                    : input.effectiveDate);
            request.recurringType = requestedRecurringType;
            request.plannedInstallments = calculatedInstallments;
            request.firstPaymentDate = dateResult != null
                ? dateResult.firstPaymentDate
                : (termBoundary == null ? null : termBoundary.firstPaymentDate);
            request.transactionDay = normalizedTransactionDay;
            request.finalPaymentDate = requestedRecurringType == 'Fixed'
                ? (dateResult == null ? requestedEndDate : dateResult.finalPaymentDate)
                : null;
            request.salesforceGiftCommitmentId = String.valueOf(commitment.Id);
            request.salesforceChangeId = 'preview';
            request.idempotencyKey = 'sapa-preview-' + String.valueOf(commitment.Id);
            request.changeMode = changeMode.mode;
            if (changeMode.mode == StripeRecurringChangeMode.TEMPORARY_TERMS) {
                request.effectiveEndDate = input.effectiveEndDate;
                request.originalAmount = selectedSchedule.TransactionAmount;
                request.originalPeriod = selectedSchedule.TransactionPeriod;
                request.originalInterval = selectedSchedule.TransactionInterval == null
                    ? 1
                    : Integer.valueOf(selectedSchedule.TransactionInterval);
                request.originalPriceId = commitment.Price_Id__c;
            }

            StripeRecurringScheduleGateway.PreviewResult preview = StripeRecurringScheduleGateway.previewChange(request);
            response.isSuccess = preview.canProceed;
            response.blockingError = preview.blockingError;
            response.businessWarning = preview.businessWarning;
            response.currentAmount = preview.currentAmount;
            response.currentPeriod = preview.currentPeriod;
            response.currentInterval = preview.currentInterval;
            response.requestedAmount = preview.requestedAmount;
            response.requestedPeriod = preview.requestedPeriod;
            response.requestedInterval = preview.requestedInterval;
            response.stripeCurrentPeriodEnd = preview.stripeCurrentPeriodEnd;
            response.actionMode = preview.actionMode;
            response.firstPaymentDate = preview.firstPaymentDate;
            response.finalPaymentDate = preview.finalPaymentDate;
            response.willGenerateFullInvoice = preview.willGenerateFullInvoice;
            response.requiresBillingGap = preview.requiresBillingGap;
            response.effectiveEndDate = preview.effectiveEndDate;
            response.lastTemporaryPaymentDate = preview.lastTemporaryPaymentDate;
            response.restorationFirstPaymentDate = preview.restorationFirstPaymentDate;
            response.temporaryInstallments = preview.temporaryInstallments;
            response.originalAmount = preview.currentAmount;
            response.originalPeriod = preview.currentPeriod;
            response.originalInterval = preview.currentInterval;
            response.originalPriceId = preview.originalPriceId;
            response.originalCancelAt = preview.originalCancelAt;
            response.calculatedInstallments = calculatedInstallments;
            response.requestedTransactionDay = request.transactionDay;
            response.errorType = preview.canProceed ? null : 'BUSINESS_RULE';
            if (dateResult != null) {
                response.firstPaymentDate = dateResult.firstPaymentDate;
                response.finalPaymentDate = dateResult.finalPaymentDate;
                response.calculatedInstallments = dateResult.installments;
                response.normalizedEffectiveDate = dateResult.effectiveDate;
            } else if (termBoundary != null) {
                response.firstPaymentDate = preview.firstPaymentDate;
                response.normalizedEffectiveDate = request.effectiveDate;
                response.managedEffectiveFromDate = termBoundary.managedEffectiveFromDate;
                response.salesforceSuccessorStartDate = termBoundary.salesforceSuccessorStartDate;
            } else if (changeMode.mode == StripeRecurringChangeMode.TERMS &&
                changeMode.cadenceChanged == true) {
                response.normalizedEffectiveDate = request.effectiveDate;
            } else if (changeMode.mode == StripeRecurringChangeMode.TEMPORARY_TERMS) {
                response.normalizedEffectiveDate = request.effectiveDate;
            }
        } catch (Exception error) {
            response.isSuccess = false;
            response.blockingError = sanitize(error.getMessage());
            response.errorType = error.getTypeName();
        }
        return response;
    }

    private static GiftCommitmentSchedule findScheduleOwningDate(
        List<GiftCommitmentSchedule> schedules,
        Date boundaryDate
    ) {
        if (schedules == null || boundaryDate == null) return null;
        for (GiftCommitmentSchedule schedule : schedules) {
            if (ownsDate(schedule, boundaryDate)) return schedule;
        }
        return null;
    }

    private static Boolean ownsDate(GiftCommitmentSchedule schedule, Date boundaryDate) {
        return schedule != null && boundaryDate != null && schedule.StartDate != null &&
            schedule.StartDate <= boundaryDate &&
            (schedule.EndDate == null || schedule.EndDate >= boundaryDate);
    }

    private static String sanitize(String message) {
        if (String.isBlank(message)) return 'Stripe preview failed.';
        return message.replaceAll('(?i)(sk|rk)_(test|live)_[A-Za-z0-9_]+', '[REDACTED]').left(1000);
    }

    private static Integer calculateInstallments(Request input) {
        if (input.plannedInstallments != null && input.plannedInstallments > 0) {
            return input.plannedInstallments;
        }
        if (input.proposedStartDate == null || input.proposedEndDate == null ||
            input.proposedEndDate < input.proposedStartDate || input.transactionInterval == null ||
            input.transactionInterval < 1) {
            return input.plannedInstallments;
        }
        Integer installments = 1;
        Date billingDate = input.proposedStartDate;
        while (installments < 10000) {
            Date nextBillingDate = StripeRecurringScheduleGateway.addBillingPeriods(
                billingDate,
                input.transactionPeriod,
                input.transactionInterval,
                1
            );
            if (nextBillingDate > input.proposedEndDate) break;
            installments++;
            billingDate = nextBillingDate;
        }
        return installments;
    }

    public class Request {
        @InvocableVariable(label='Gift Commitment ID' required=true) public Id giftCommitmentId;
        @InvocableVariable(label='Requested Amount' required=true) public Decimal amount;
        @InvocableVariable(label='Requested Period' required=true) public String transactionPeriod;
        @InvocableVariable(label='Requested Interval' required=true) public Integer transactionInterval;
        @InvocableVariable(label='Requested Transaction Day') public String transactionDay;
        @InvocableVariable(label='Change Effective Date' required=true) public Date effectiveDate;
        @InvocableVariable(label='Effective End Date') public Date effectiveEndDate;
        @InvocableVariable(label='Recurring Type') public String recurringType;
        @InvocableVariable(label='Planned Installments') public Integer plannedInstallments;
        @InvocableVariable(label='Proposed First Payment Date') public Date proposedStartDate;
        @InvocableVariable(label='Proposed Final Payment Date') public Date proposedEndDate;
        @InvocableVariable(label='Requested Configuration Start Date') public Date requestedStartDate;
        @InvocableVariable(label='Requested Configuration End Date') public Date requestedEndDate;
        @InvocableVariable(label='Requested End Date Is Set') public Boolean requestedEndDateIsSet;
        @InvocableVariable(label='Selected Schedule Payment Method') public String paymentMethod;
        @InvocableVariable(label='Selected Gift Commitment Schedule ID') public Id selectedScheduleId;
        @InvocableVariable(label='Resolved Gift Commitment Schedule ID') public Id resolvedScheduleId;
        @InvocableVariable(label='Change Mode Hint') public String changeModeHint;
        @InvocableVariable(label='Use Planned Terms Boundary'
            description='Recalculate guided permanent term dates even when the planner supplied a future effective date.')
        public Boolean usePlannedTermsBoundary = false;
    }

    public class Response {
        @InvocableVariable(label='Success') public Boolean isSuccess;
        @InvocableVariable(label='Blocking Error') public String blockingError;
        @InvocableVariable(label='Business Warning') public String businessWarning;
        @InvocableVariable(label='Current Amount') public Decimal currentAmount;
        @InvocableVariable(label='Current Period') public String currentPeriod;
        @InvocableVariable(label='Current Interval') public Integer currentInterval;
        @InvocableVariable(label='Requested Amount') public Decimal requestedAmount;
        @InvocableVariable(label='Requested Period') public String requestedPeriod;
        @InvocableVariable(label='Requested Interval') public Integer requestedInterval;
        @InvocableVariable(label='Stripe Current Period End') public Date stripeCurrentPeriodEnd;
        @InvocableVariable(label='Stripe Action Mode') public String actionMode;
        @InvocableVariable(label='First Actual Payment Date') public Date firstPaymentDate;
        @InvocableVariable(label='Final Payment Date') public Date finalPaymentDate;
        @InvocableVariable(label='Full Invoice on Effective Date') public Boolean willGenerateFullInvoice;
        @InvocableVariable(label='Requires No-Charge Billing Gap') public Boolean requiresBillingGap;
        @InvocableVariable(label='Calculated Installment Count') public Integer calculatedInstallments;
        @InvocableVariable(label='Normalized Effective Date') public Date normalizedEffectiveDate;
        @InvocableVariable(label='Date Normalization Warning') public String dateNormalizationWarning;
        @InvocableVariable(label='Next Allowed Effective Date') public Date nextAllowedEffectiveDate;
        @InvocableVariable(label='Change Mode') public String changeMode;
        @InvocableVariable(label='Same-Day Mutation Required') public Boolean sameDayMutationRequired;
        @InvocableVariable(label='Managed Effective From Date') public Date managedEffectiveFromDate;
        @InvocableVariable(label='Salesforce Successor Start Date') public Date salesforceSuccessorStartDate;
        @InvocableVariable(label='Resolved Schedule ID') public Id resolvedScheduleId;
        @InvocableVariable(label='Requested Transaction Day') public String requestedTransactionDay;
        @InvocableVariable(label='Effective Window End Date') public Date effectiveEndDate;
        @InvocableVariable(label='Last Temporary Payment Date') public Date lastTemporaryPaymentDate;
        @InvocableVariable(label='Restoration First Payment Date') public Date restorationFirstPaymentDate;
        @InvocableVariable(label='Temporary Installment Count') public Integer temporaryInstallments;
        @InvocableVariable(label='Original Amount') public Decimal originalAmount;
        @InvocableVariable(label='Original Period') public String originalPeriod;
        @InvocableVariable(label='Original Interval') public Integer originalInterval;
        @InvocableVariable(label='Original Stripe Price ID') public String originalPriceId;
        @InvocableVariable(label='Original Stripe Cancel At') public Datetime originalCancelAt;
        @InvocableVariable(label='Error Type') public String errorType;
    }
}