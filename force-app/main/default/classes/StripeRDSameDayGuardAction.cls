/**
 * Read-only final guard for guided recurring schedule changes.
 * It re-reads Salesforce immediately before managed schedule DML so a payment
 * collected while a Flow screen was open cannot make the native action fail.
 */
public with sharing class StripeRDSameDayGuardAction {
    private static final String PAYMENT_TAKEN_TODAY_MESSAGE =
        'A payment has already been taken today. You cannot change the Start Date effective today. ' +
        'Select the next unpaid payment date or a later date.';

    /** Evaluates one or more proposed term changes without DML or callouts. */
    @InvocableMethod(
        label='Guard Same-Day Stripe Recurring Change'
        description='Rechecks same-day paid transactions immediately before a guided recurring schedule mutation.'
        category='Stripe Recurring Donations'
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
                SELECT Id, Subscription_Id__c, Payment_Processor__c, Payment_type__c,
                       Recurring_Type__c
                FROM GiftCommitment
                WHERE Id IN :commitmentIds
            ]);
        Map<Id, GiftCommitmentSchedule> schedules = new Map<Id, GiftCommitmentSchedule>();
        Map<Id, List<GiftCommitmentSchedule>> schedulesByCommitment = new Map<Id, List<GiftCommitmentSchedule>>();
        if (!commitmentIds.isEmpty()) {
            for (GiftCommitmentSchedule schedule : [
                SELECT Id, GiftCommitmentId, StartDate, EndDate, TransactionAmount,
                       TransactionPeriod, TransactionInterval, TransactionDay
                FROM GiftCommitmentSchedule
                WHERE GiftCommitmentId IN :commitmentIds
                ORDER BY GiftCommitmentId, StartDate DESC, CreatedDate DESC
            ]) {
                schedules.put(schedule.Id, schedule);
                if (!schedulesByCommitment.containsKey(schedule.GiftCommitmentId)) {
                    schedulesByCommitment.put(schedule.GiftCommitmentId, new List<GiftCommitmentSchedule>());
                }
                schedulesByCommitment.get(schedule.GiftCommitmentId).add(schedule);
            }
        }
        Date today = Date.today();
        Set<Id> paidTodayIds = new Set<Id>();
        Map<Id, Date> latestPaidDateByCommitment = new Map<Id, Date>();
        Map<Id, Date> nextUnpaidDateByCommitment = new Map<Id, Date>();
        if (!commitmentIds.isEmpty()) {
            for (GiftTransaction transactionRecord : [
                SELECT Id, GiftCommitmentId, TransactionDate, TransactionDueDate
                FROM GiftTransaction
                WHERE GiftCommitmentId IN :commitmentIds
                  AND Status = 'Paid'
            ]) {
                Date paidDate = transactionRecord.TransactionDate == null
                    ? transactionRecord.TransactionDueDate
                    : transactionRecord.TransactionDate;
                if (paidDate == today) {
                    paidTodayIds.add(transactionRecord.GiftCommitmentId);
                }
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
                if (!nextUnpaidDateByCommitment.containsKey(transactionRecord.GiftCommitmentId)) {
                    nextUnpaidDateByCommitment.put(transactionRecord.GiftCommitmentId, transactionRecord.TransactionDueDate);
                }
            }
        }

        List<Response> responses = new List<Response>();
        for (Request request : requests) {
            responses.add(checkOne(
                request,
                commitments,
                schedules,
                schedulesByCommitment,
                paidTodayIds,
                latestPaidDateByCommitment,
                nextUnpaidDateByCommitment,
                today
            ));
        }
        return responses;
    }

    private static Response checkOne(
        Request request,
        Map<Id, GiftCommitment> commitments,
        Map<Id, GiftCommitmentSchedule> schedules,
        Map<Id, List<GiftCommitmentSchedule>> schedulesByCommitment,
        Set<Id> paidTodayIds,
        Map<Id, Date> latestPaidDateByCommitment,
        Map<Id, Date> nextUnpaidDateByCommitment,
        Date today
    ) {
        Response response = new Response();
        if (request == null || request.giftCommitmentId == null || request.effectiveDate == null) {
            response.isAllowed = false;
            response.errorType = 'MISSING_REQUEST';
            response.errorMessage = 'A recurring schedule and effective date are required.';
            return response;
        }
        GiftCommitment commitment = commitments.get(request.giftCommitmentId);
        if (commitment == null) {
            response.isAllowed = false;
            response.errorType = 'MISSING_COMMITMENT';
            response.errorMessage = 'The recurring donation could not be read.';
            return response;
        }
        GiftCommitmentSchedule schedule = request.selectedScheduleId == null
            ? null
            : schedules.get(request.selectedScheduleId);
        Boolean verifiedStripe = !String.isBlank(commitment.Subscription_Id__c) &&
            ('Stripe'.equalsIgnoreCase(commitment.Payment_Processor__c) ||
             'Credit Card'.equalsIgnoreCase(commitment.Payment_type__c) ||
             'Credit Card'.equalsIgnoreCase(request.paymentMethod));
        if (verifiedStripe && (schedule == null || schedule.GiftCommitmentId != commitment.Id)) {
            response.isAllowed = false;
            response.errorType = 'MISSING_SELECTED_SCHEDULE';
            response.errorMessage = 'Select the Gift Commitment Schedule you want to change before saving.';
            return response;
        }
        if (!verifiedStripe && schedule == null) {
            response.isAllowed = true;
            response.skipped = true;
            return response;
        }
        Date proposedEndDate = request.proposedEndDateIsSet == true
            ? request.proposedEndDate
            : schedule.EndDate;
        String requestedType = String.isBlank(request.recurringType)
            ? commitment.Recurring_Type__c
            : request.recurringType;
        StripeRecurringChangeMode.Result mode = StripeRecurringChangeMode.classify(
            schedule,
            commitment.Recurring_Type__c,
            request.amount,
            request.transactionPeriod,
            request.transactionInterval,
            request.proposedStartDate,
            proposedEndDate,
            requestedType,
            request.changeModeHint
        );
        response.changeMode = mode.mode;
        if (mode.mode == StripeRecurringChangeMode.TERMS &&
            String.isNotBlank(request.transactionPeriod) && request.transactionInterval != null) {
            if ('Monthly'.equalsIgnoreCase(request.transactionPeriod) &&
                StripeRDScheduleDateCalc.normalizeTransactionDay(request.transactionDay) == null) {
                response.isAllowed = false;
                response.errorType = 'INVALID_TRANSACTION_DAY';
                response.errorMessage =
                    'Transaction Day is required for Monthly. Select a valid day before saving.';
                return response;
            }
            StripeRDScheduleDateCalc.Result boundary = StripeRDScheduleDateCalc.calculateTermsBoundary(
                latestPaidDateByCommitment.get(commitment.Id),
                nextUnpaidDateByCommitment.get(commitment.Id),
                today,
                request.transactionPeriod,
                request.transactionInterval,
                mode.cadenceChanged,
                schedule.TransactionDay,
                request.transactionDay
            );
            if (boundary.error != null) {
                response.isAllowed = false;
                response.errorType = 'INVALID_TERM_DATES';
                response.errorMessage = boundary.error;
                return response;
            }
            response.firstPaymentDate = boundary.firstPaymentDate;
            response.managedEffectiveFromDate = boundary.managedEffectiveFromDate;
            response.salesforceSuccessorStartDate = boundary.salesforceSuccessorStartDate;
            response.stripeEffectiveDate = boundary.effectiveDate;
            response.requestedTransactionDay = boundary.requestedTransactionDay;
            String expectedDay = StripeRDScheduleDateCalc.normalizeTransactionDay(
                request.expectedTransactionDay
            );
            if ((request.expectedFirstPaymentDate != null &&
                    request.expectedFirstPaymentDate != boundary.firstPaymentDate) ||
                (String.isNotBlank(request.expectedTransactionDay) &&
                    expectedDay != boundary.requestedTransactionDay)) {
                response.isAllowed = false;
                response.errorType = 'STALE_PREVIEW';
                response.errorMessage =
                    'The recurring donation changed after the preview was shown. Restart Manage Recurring Donation Schedule before saving.';
                return response;
            }
            GiftCommitmentSchedule resolvedSchedule = findScheduleOwningDate(
                schedulesByCommitment.get(commitment.Id),
                boundary.managedEffectiveFromDate
            );
            if (resolvedSchedule == null) {
                response.isAllowed = false;
                response.errorType = 'NO_SCHEDULE_OWNS_BOUNDARY';
                response.errorMessage =
                    'Salesforce could not find a recurring donation schedule that owns the calculated change date. ' +
                    'Review the schedule dates before trying again.';
                return response;
            }
            response.resolvedScheduleId = resolvedSchedule.Id;
            response.resolvedScheduleStartDate = resolvedSchedule.StartDate;
        }
        Boolean paidToday = request.effectiveDate == today && paidTodayIds.contains(commitment.Id);
        if (paidToday && mode.mode == StripeRecurringChangeMode.START_DATE_CHANGE) {
            response.isAllowed = false;
            response.errorType = 'FIRST_PAYMENT_TODAY';
            response.errorMessage = PAYMENT_TAKEN_TODAY_MESSAGE;
            response.nextAllowedEffectiveDate = nextUnpaidDateByCommitment.get(commitment.Id);
            return response;
        }
        response.isAllowed = true;
        response.skipped = !verifiedStripe;
        response.sameDayMutationRequired = paidToday && mode.mode == StripeRecurringChangeMode.END_DATE_ONLY;
        return response;
    }

    private static GiftCommitmentSchedule findScheduleOwningDate(
        List<GiftCommitmentSchedule> schedules,
        Date boundaryDate
    ) {
        if (schedules == null || boundaryDate == null) return null;
        for (GiftCommitmentSchedule schedule : schedules) {
            if (schedule.StartDate != null && schedule.StartDate <= boundaryDate &&
                (schedule.EndDate == null || schedule.EndDate >= boundaryDate)) {
                return schedule;
            }
        }
        return null;
    }

    public class Request {
        @InvocableVariable(label='Gift Commitment ID' required=true) public Id giftCommitmentId;
        @InvocableVariable(label='Selected Gift Commitment Schedule ID') public Id selectedScheduleId;
        @InvocableVariable(label='Change Effective Date' required=true) public Date effectiveDate;
        @InvocableVariable(label='Payment Method') public String paymentMethod;
        @InvocableVariable(label='Proposed Amount') public Decimal amount;
        @InvocableVariable(label='Proposed Period') public String transactionPeriod;
        @InvocableVariable(label='Proposed Interval') public Integer transactionInterval;
        @InvocableVariable(label='Proposed Transaction Day') public String transactionDay;
        @InvocableVariable(label='Proposed Start Date') public Date proposedStartDate;
        @InvocableVariable(label='Proposed End Date') public Date proposedEndDate;
        @InvocableVariable(label='Proposed End Date Is Set') public Boolean proposedEndDateIsSet;
        @InvocableVariable(label='Proposed Recurring Type') public String recurringType;
        @InvocableVariable(label='Change Mode Hint') public String changeModeHint;
        @InvocableVariable(label='Expected First Payment Date') public Date expectedFirstPaymentDate;
        @InvocableVariable(label='Expected Transaction Day') public String expectedTransactionDay;
    }

    public class Response {
        @InvocableVariable(label='Allowed') public Boolean isAllowed;
        @InvocableVariable(label='Skipped') public Boolean skipped;
        @InvocableVariable(label='Error Message') public String errorMessage;
        @InvocableVariable(label='Error Type') public String errorType;
        @InvocableVariable(label='Next Allowed Effective Date') public Date nextAllowedEffectiveDate;
        @InvocableVariable(label='Change Mode') public String changeMode;
        @InvocableVariable(label='Same-Day Mutation Required') public Boolean sameDayMutationRequired;
        @InvocableVariable(label='First Future Payment Date') public Date firstPaymentDate;
        @InvocableVariable(label='Managed Effective From Date') public Date managedEffectiveFromDate;
        @InvocableVariable(label='Salesforce Successor Start Date') public Date salesforceSuccessorStartDate;
        @InvocableVariable(label='Stripe Effective Date') public Date stripeEffectiveDate;
        @InvocableVariable(label='Resolved Schedule ID') public Id resolvedScheduleId;
        @InvocableVariable(label='Resolved Schedule Start Date') public Date resolvedScheduleStartDate;
        @InvocableVariable(label='Requested Transaction Day') public String requestedTransactionDay;
    }
}