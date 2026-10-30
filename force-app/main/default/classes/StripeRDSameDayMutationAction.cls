/**
 * Salesforce-only mutation used after a payment has been taken today.
 * The managed NPC schedule action rejects a paid date range, so this action
 * preserves paid history and updates only future unpaid transactions when
 * Nonprofit Cloud has locked the selected schedule's terms after payment.
 */
public with sharing class StripeRDSameDayMutationAction {
    private static final String START_DATE_MESSAGE =
        'A payment has already been taken today. You cannot change the Start Date effective today. ' +
        'Select the next unpaid payment date or a later date.';

    @InvocableMethod(
        label='Apply Same-Day Recurring Donation Change'
        description='Preserves paid transactions and safely mutates future unpaid recurring transactions after a payment today.'
        category='Stripe Recurring Donations'
    )
    public static List<Response> execute(List<Request> requests) {
        if (requests == null) return new List<Response>();
        Set<Id> commitmentIds = new Set<Id>();
        Set<Id> scheduleIds = new Set<Id>();
        for (Request request : requests) {
            if (request != null) {
                if (request.giftCommitmentId != null) commitmentIds.add(request.giftCommitmentId);
                if (request.selectedScheduleId != null) scheduleIds.add(request.selectedScheduleId);
            }
        }
        Map<Id, GiftCommitment> commitments = commitmentIds.isEmpty()
            ? new Map<Id, GiftCommitment>()
            : new Map<Id, GiftCommitment>([
                SELECT Id, Recurring_Type__c, Subscription_Id__c, Payment_Processor__c, Payment_type__c
                FROM GiftCommitment
                WHERE Id IN :commitmentIds
                FOR UPDATE
            ]);
        Map<Id, GiftCommitmentSchedule> schedules = scheduleIds.isEmpty()
            ? new Map<Id, GiftCommitmentSchedule>()
            : new Map<Id, GiftCommitmentSchedule>([
                SELECT Id, GiftCommitmentId, StartDate, EndDate, TransactionAmount,
                       TransactionPeriod, TransactionInterval, PaymentMethod,
                       Stripe_Change_Effective_Date__c, Number_of_Planned_Installments__c,
                       Final_Payment_Date__c
                FROM GiftCommitmentSchedule
                WHERE Id IN :scheduleIds
                 FOR UPDATE
             ]);

        Map<Id, List<GiftTransaction>> transactionsBySchedule = new Map<Id, List<GiftTransaction>>();
        if (!scheduleIds.isEmpty()) {
            for (GiftTransaction transactionRecord : [
                SELECT Id, GiftCommitmentId, GiftCommitmentScheduleId, Status,
                       OriginalAmount, TransactionDate, TransactionDueDate
                FROM GiftTransaction
                WHERE GiftCommitmentScheduleId IN :scheduleIds
                FOR UPDATE
            ]) {
                if (!transactionsBySchedule.containsKey(transactionRecord.GiftCommitmentScheduleId)) {
                    transactionsBySchedule.put(transactionRecord.GiftCommitmentScheduleId, new List<GiftTransaction>());
                }
                transactionsBySchedule.get(transactionRecord.GiftCommitmentScheduleId).add(transactionRecord);
            }
        }

        List<Response> responses = new List<Response>();
        for (Request request : requests) {
            responses.add(applyOne(request, commitments, schedules, transactionsBySchedule));
        }
        return responses;
    }

    private static Response applyOne(
        Request request,
        Map<Id, GiftCommitment> commitments,
        Map<Id, GiftCommitmentSchedule> schedules,
        Map<Id, List<GiftTransaction>> transactionsBySchedule
    ) {
        Response response = new Response();
        Savepoint savepoint;
        try {
            if (request == null || request.giftCommitmentId == null || request.selectedScheduleId == null) {
                return fail(response, 'MISSING_REQUEST', 'A Gift Commitment and selected schedule are required.');
            }
            GiftCommitment commitment = commitments.get(request.giftCommitmentId);
            GiftCommitmentSchedule schedule = schedules.get(request.selectedScheduleId);
            if (commitment == null || schedule == null || schedule.GiftCommitmentId != commitment.Id) {
                return fail(response, 'MISSING_SELECTED_SCHEDULE', 'Select the Gift Commitment Schedule being changed.');
            }
            if (request.effectiveDate != Date.today()) {
                return fail(response, 'NOT_SAME_DAY', 'The safe Salesforce-only mutation is available only for a change effective today.');
            }
            if (String.isBlank(commitment.Subscription_Id__c) ||
                (!'Stripe'.equalsIgnoreCase(commitment.Payment_Processor__c) &&
                 !'Credit Card'.equalsIgnoreCase(commitment.Payment_type__c) &&
                 !'Credit Card'.equalsIgnoreCase(schedule.PaymentMethod))) {
                return fail(response, 'NOT_VERIFIED_STRIPE', 'This donation is not a verified Stripe or Credit Card recurring donation.');
            }

            Date proposedStartDate = request.proposedStartDate == null
                ? schedule.StartDate
                : request.proposedStartDate;
            Date proposedEndDate = request.proposedEndDateIsSet == true
                ? request.proposedEndDate
                : schedule.EndDate;
            String recurringType = request.recurringType;
            if (String.isBlank(recurringType)) recurringType = proposedEndDate == null ? 'Open' : 'Fixed';
            Integer interval = request.transactionInterval == null
                ? (schedule.TransactionInterval == null ? 1 : Integer.valueOf(schedule.TransactionInterval))
                : request.transactionInterval;
            String period = String.isBlank(request.transactionPeriod) ? schedule.TransactionPeriod : request.transactionPeriod;
            Decimal amount = request.amount == null ? schedule.TransactionAmount : request.amount;

            StripeRecurringChangeMode.Result mode = StripeRecurringChangeMode.classify(
                schedule,
                commitment.Recurring_Type__c,
                amount,
                period,
                interval,
                proposedStartDate,
                proposedEndDate,
                recurringType,
                request.changeModeHint
            );
            response.changeMode = mode.mode;
            if (mode.mode == StripeRecurringChangeMode.START_DATE_CHANGE) {
                return fail(response, 'FIRST_PAYMENT_TODAY', START_DATE_MESSAGE);
            }

            List<GiftTransaction> relatedTransactions = transactionsBySchedule.get(schedule.Id);
            Boolean paidToday = false;
            if (relatedTransactions != null) {
                for (GiftTransaction transactionRecord : relatedTransactions) {
                    if (transactionRecord.Status == 'Paid' &&
                        (transactionRecord.TransactionDate == Date.today() ||
                         (transactionRecord.TransactionDate == null && transactionRecord.TransactionDueDate == Date.today()))) {
                        paidToday = true;
                    }
                    if (transactionRecord.Status == 'Paid' &&
                        (transactionRecord.TransactionDate > Date.today() ||
                         (transactionRecord.TransactionDate == null && transactionRecord.TransactionDueDate > Date.today()))) {
                        return fail(response, 'PAID_TRANSACTION_RANGE',
                            'The requested change would affect a paid transaction in the future. No Salesforce or Stripe change was made.');
                    }
                }
            }
            if (!paidToday) {
                return fail(response, 'PAYMENT_NOT_FOUND',
                    'A same-day payment could not be re-read. Use the normal future-effective schedule path.');
            }

            StripeRecurringScheduleCaptureCoalescer.beginGuidedSync(
                new Set<Id>{ commitment.Id }
            );
            savepoint = Database.setSavepoint();

            StripeRDScheduleDateCalc.Result dateResult = calculateDates(
                schedule,
                proposedEndDate,
                period,
                interval,
                recurringType
            );
            if (dateResult.error != null) {
                return fail(response, 'INVALID_PAYMENT_DATES', dateResult.error);
            }

            Date finalPaymentDate = recurringType == 'Fixed' ? dateResult.finalPaymentDate : null;
            Integer installments = recurringType == 'Fixed' ? dateResult.installments : null;
            Boolean cadenceChanged = schedule.TransactionPeriod != period ||
                (schedule.TransactionInterval == null ? 1 : Integer.valueOf(schedule.TransactionInterval)) != interval;
            update new GiftCommitment(Id = commitment.Id, Recurring_Type__c = recurringType);

            // The managed package locks TransactionAmount/Period/Interval once
            // a schedule has transactions. Keep that schedule and its StartDate
            // intact; only future unpaid transactions are adjusted. This also
            // prevents duplicate Salesforce schedules and duplicate Stripe items.
            Date futureFirstPaymentDate = cadenceChanged
                ? StripeRDScheduleDateCalc.addPeriod(Date.today(), period, interval)
                : dateResult.firstPaymentDate;
            updateFutureTransactions(
                relatedTransactions, schedule.Id, amount, period, interval,
                cadenceChanged, finalPaymentDate, futureFirstPaymentDate
            );

            GiftCommitmentSchedule scheduleUpdate = new GiftCommitmentSchedule(Id = schedule.Id);
            scheduleUpdate.EndDate = finalPaymentDate;
            // The retained native segment includes its historical StartDate occurrence.
            // Stamp the same inclusive count as Calculate_Commitment_Amount even while
            // that developed Flow is Draft; future Stripe installments remain separate.
            scheduleUpdate.Number_of_Planned_Installments__c = nativeInstallments(schedule,finalPaymentDate);
            scheduleUpdate.Stripe_Change_Effective_Date__c = Date.today();
            update scheduleUpdate;

            response.isSuccess = true;
            response.scheduleId = schedule.Id;
            response.firstPaymentDate = dateResult.firstPaymentDate;
            response.finalPaymentDate = finalPaymentDate;
            response.calculatedInstallments = installments;
        } catch (Exception error) {
            if (savepoint != null) Database.rollback(savepoint);
            return fail(response, error.getTypeName(), sanitize(error.getMessage()));
        }
        return response;
    }

    private static Integer nativeInstallments(GiftCommitmentSchedule schedule,Date endDate) {
        if(endDate==null) return null;
        if(schedule.StartDate>endDate) return 0;
        Integer interval=schedule.TransactionInterval==null?1:Integer.valueOf(schedule.TransactionInterval);
        Integer units;
        if(schedule.TransactionPeriod=='Daily') units=schedule.StartDate.daysBetween(endDate);
        else if(schedule.TransactionPeriod=='Weekly') {
            units=schedule.StartDate.daysBetween(endDate);interval*=7;
        } else if(schedule.TransactionPeriod=='Monthly'||schedule.TransactionPeriod=='Yearly') {
            units=(endDate.year()-schedule.StartDate.year())*12+endDate.month()-schedule.StartDate.month();
            if(endDate.day()<schedule.StartDate.day()) units--;
            if(schedule.TransactionPeriod=='Yearly') interval*=12;
        } else return 1;
        return Integer.valueOf(Math.floor(Decimal.valueOf(String.valueOf(units))/interval))+1;
    }

    private static StripeRDScheduleDateCalc.Result calculateDates(
        GiftCommitmentSchedule schedule,
        Date proposedEndDate,
        String period,
        Integer interval,
        String recurringType
    ) {
        if (recurringType == 'Fixed' && proposedEndDate == Date.today() && schedule.StartDate < Date.today()) {
            StripeRDScheduleDateCalc.Result todayResult = new StripeRDScheduleDateCalc.Result();
            todayResult.effectiveDate = Date.today();
            todayResult.firstPaymentDate = Date.today();
            todayResult.finalPaymentDate = Date.today();
            todayResult.installments = 1;
            return todayResult;
        }
        return StripeRDScheduleDateCalc.calculate(
            schedule.StartDate,
            proposedEndDate,
            Date.today(),
            period,
            interval,
            recurringType
        );
    }

    private static void updateFutureTransactions(
        List<GiftTransaction> transactions,
        Id targetScheduleId,
        Decimal amount,
        String period,
        Integer interval,
        Boolean cadenceChanged,
        Date finalPaymentDate,
        Date firstCalculatedPaymentDate
    ) {
        if (transactions == null || transactions.isEmpty()) return;
        List<GiftTransaction> updates = new List<GiftTransaction>();
        List<GiftTransaction> removals = new List<GiftTransaction>();
        Date nextDate = firstCalculatedPaymentDate;
        for (GiftTransaction transactionRecord : transactions) {
            if (transactionRecord.Status == 'Paid') continue;
            if (transactionRecord.TransactionDueDate != null &&
                transactionRecord.TransactionDueDate <= Date.today() &&
                !(finalPaymentDate != null && transactionRecord.TransactionDueDate > finalPaymentDate)) {
                continue;
            }
            if (finalPaymentDate != null && transactionRecord.TransactionDueDate != null &&
                transactionRecord.TransactionDueDate > finalPaymentDate) {
                removals.add(transactionRecord);
                continue;
            }
            transactionRecord.OriginalAmount = amount;
            // The target is normally the selected schedule. Assigning it is
            // harmless for legacy callers but does not create a new schedule.
            transactionRecord.GiftCommitmentScheduleId = targetScheduleId;
            if (cadenceChanged && nextDate != null) {
                transactionRecord.TransactionDueDate = nextDate;
                nextDate = StripeRDScheduleDateCalc.addPeriod(nextDate, period, interval);
            }
            updates.add(transactionRecord);
        }
        if (!updates.isEmpty()) update updates;
        if (!removals.isEmpty()) delete removals;
    }

    private static Response fail(Response response, String errorType, String message) {
        response.isSuccess = false;
        response.errorType = errorType;
        response.errorMessage = message;
        return response;
    }

    private static String sanitize(String message) {
        if (String.isBlank(message)) return 'The same-day recurring donation change failed.';
        return message.replaceAll('(?i)(sk|rk)_(test|live)_[A-Za-z0-9_]+', '[REDACTED]').left(1000);
    }

    public class Request {
        @InvocableVariable(label='Gift Commitment ID' required=true) public Id giftCommitmentId;
        @InvocableVariable(label='Selected Schedule ID' required=true) public Id selectedScheduleId;
        @InvocableVariable(label='Amount') public Decimal amount;
        @InvocableVariable(label='Period') public String transactionPeriod;
        @InvocableVariable(label='Interval') public Integer transactionInterval;
        @InvocableVariable(label='Effective Date' required=true) public Date effectiveDate;
        @InvocableVariable(label='Proposed Start Date') public Date proposedStartDate;
        @InvocableVariable(label='Proposed End Date') public Date proposedEndDate;
        @InvocableVariable(label='Proposed End Date Is Set') public Boolean proposedEndDateIsSet;
        @InvocableVariable(label='Recurring Type') public String recurringType;
        @InvocableVariable(label='Change Mode Hint') public String changeModeHint;
    }

    public class Response {
        @InvocableVariable(label='Success') public Boolean isSuccess;
        @InvocableVariable(label='Schedule ID') public Id scheduleId;
        @InvocableVariable(label='Change Mode') public String changeMode;
        @InvocableVariable(label='First Payment Date') public Date firstPaymentDate;
        @InvocableVariable(label='Final Payment Date') public Date finalPaymentDate;
        @InvocableVariable(label='Calculated Installments') public Integer calculatedInstallments;
        @InvocableVariable(label='Error Type') public String errorType;
        @InvocableVariable(label='Error Message') public String errorMessage;
    }
}