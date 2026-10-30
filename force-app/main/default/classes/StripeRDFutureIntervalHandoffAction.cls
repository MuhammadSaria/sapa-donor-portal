/**
 * Atomically replaces the unpaid remainder of a cadence segment with a native pause gap
 * and a new interval, then captures one durable Stripe request after verification.
 */
public with sharing class StripeRDFutureIntervalHandoffAction {
    @InvocableMethod(
        label='Apply Future Stripe Interval Handoff'
        description='Pauses the unpaid gap, applies the requested interval, verifies dates, and queues one Stripe change.'
        category='Stripe Recurring Donations'
    )
    public static List<Response> execute(List<Request> requests) {
        Response response = new Response();
        if (requests == null || requests.size() != 1 || requests[0] == null) {
            response.errorMessage = 'Process one selected recurring donation schedule at a time.';
            return new List<Response>{response};
        }
        return new List<Response>{processOne(requests[0])};
    }

    private static Response processOne(Request request) {
        Response result = new Response();
        if (request.giftCommitmentId == null || request.selectedScheduleId == null ||
            request.amount == null || request.amount <= 0 ||
            String.isBlank(request.transactionPeriod) || request.transactionInterval == null ||
            request.transactionInterval < 1) {
            result.errorMessage = 'Select a future schedule and valid amount and cadence before saving.';
            return result;
        }
        List<GiftCommitment> gifts = [
            SELECT Id, Subscription_Id__c, Payment_Processor__c, Payment_type__c,
                   Recurring_Type__c, NextTransactionDate
            FROM GiftCommitment WHERE Id = :request.giftCommitmentId LIMIT 1
        ];
        List<GiftCommitmentSchedule> sources = [
            SELECT Id, GiftCommitmentId, StartDate, EndDate, Type, TransactionAmount,
                   TransactionPeriod, TransactionInterval, TransactionDay, PaymentMethod
            FROM GiftCommitmentSchedule WHERE Id = :request.selectedScheduleId LIMIT 1
        ];
        if (gifts.isEmpty() || sources.isEmpty() ||
            sources[0].GiftCommitmentId != request.giftCommitmentId) {
            result.errorMessage = 'The selected schedule no longer belongs to this recurring donation.';
            return result;
        }
        GiftCommitment gift = gifts[0];
        GiftCommitmentSchedule source = sources[0];
        Boolean verifiedStripe = String.isNotBlank(gift.Subscription_Id__c) &&
            ('Stripe'.equalsIgnoreCase(gift.Payment_Processor__c) ||
             'Credit Card'.equalsIgnoreCase(gift.Payment_type__c) ||
             'Credit Card'.equalsIgnoreCase(source.PaymentMethod));
        if (!verifiedStripe || source.Type != 'CreateTransactions' || source.StartDate == null) {
            result.errorMessage = 'This handoff requires a verified Stripe Create Transactions schedule.';
            return result;
        }
        Boolean cadenceChanged = source.TransactionPeriod != request.transactionPeriod ||
            source.TransactionInterval != request.transactionInterval;
        if (!cadenceChanged) {
            result.errorMessage = 'This handoff applies only when the future billing cadence or interval changes.';
            return result;
        }
        Date latestPaid;
        Date earliestUnpaid;
        for (GiftTransaction payment : [
            SELECT Status, TransactionDate, TransactionDueDate
            FROM GiftTransaction WHERE GiftCommitmentId = :gift.Id
              AND Status IN ('Paid', 'Pledged', 'Unpaid')
        ]) {
            Date paymentDate = payment.TransactionDate == null
                ? payment.TransactionDueDate : payment.TransactionDate;
            if (payment.Status == 'Paid') {
                if (paymentDate != null && paymentDate > Date.today() && paymentDate >= source.StartDate) {
                    result.errorMessage = 'A paid transaction exists in the future schedule. No change was made.';
                    return result;
                }
                if (paymentDate != null && (latestPaid == null || paymentDate > latestPaid)) {
                    latestPaid = paymentDate;
                }
            } else if (payment.TransactionDueDate != null &&
                       payment.TransactionDueDate > Date.today() &&
                       (earliestUnpaid == null || payment.TransactionDueDate < earliestUnpaid)) {
                earliestUnpaid = payment.TransactionDueDate;
            }
        }
        StripeRDScheduleDateCalc.Result plan = StripeRDScheduleDateCalc.calculateTermsBoundary(
            latestPaid, earliestUnpaid, Date.today(), request.transactionPeriod,
            request.transactionInterval, true, source.TransactionDay,
            request.transactionDay
        );
        if (plan.error != null || plan.firstPaymentDate == null ||
            plan.firstPaymentDate <= source.StartDate ||
            (source.EndDate != null && plan.firstPaymentDate > source.EndDate)) {
            result.errorMessage = plan.error == null
                ? 'The next payment must fall after the selected future schedule starts and before it ends.'
                : plan.error;
            return result;
        }
        if (request.expectedFirstPaymentDate != null &&
            request.expectedFirstPaymentDate != plan.firstPaymentDate) {
            result.errorMessage = 'The payment date changed after preview. Restart the schedule action.';
            return result;
        }
        Date firstPayment = plan.firstPaymentDate;
        Date gapStart = source.StartDate > Date.today() ? source.StartDate : Date.today();
        if (latestPaid != null && latestPaid >= gapStart) gapStart = latestPaid.addDays(1);
        if (firstPayment <= gapStart) {
            result.errorMessage = 'No unpaid billing gap exists before the first new payment. Use the standard terms path.';
            return result;
        }
        Savepoint savepoint = Database.setSavepoint();
        Boolean originalSuppression = StripePauseService.suppressSubscriptionUpdate;
        try {
            StripePauseService.suppressSubscriptionUpdate = true;
            Invocable.Action pause = Invocable.Action.createStandardAction('pauseGiftCommitmentSchedule');
            pause.setInvocationParameter('giftCommitmentScheduleId', String.valueOf(source.Id));
            pause.setInvocationParameter('startDate', gapStart);
            requireNativeSuccess(pause.invoke(), 'pause');

            // A bounded pause rejects already-generated payments after the gap.
            // Native pause of the remainder followed by a planned resume preserves them.
            List<GiftCommitmentSchedule> gaps = [SELECT Id FROM GiftCommitmentSchedule
                WHERE GiftCommitmentId = :gift.Id AND Type = 'PauseTransactions'
                  AND StartDate = :gapStart];
            if (gaps.size() != 1) throw new HandoffException('Salesforce did not create one unpaid billing gap.');
            Invocable.Action resume = Invocable.Action.createStandardAction('resumeGiftCommitmentSchedule');
            resume.setInvocationParameter('giftCommitmentScheduleId', String.valueOf(gaps[0].Id));
            resume.setInvocationParameter('resumeDate', firstPayment);
            requireNativeSuccess(resume.invoke(), 'planned resume');

            List<GiftCommitmentSchedule> resumed = [
                SELECT Id, GiftCommitmentId, StartDate, EndDate, Type, TransactionAmount,
                       TransactionPeriod, TransactionInterval, TransactionDay, PaymentMethod
                FROM GiftCommitmentSchedule WHERE GiftCommitmentId = :gift.Id
                  AND Type = 'CreateTransactions' AND StartDate = :firstPayment
            ];
            if (resumed.size() != 1) throw new HandoffException(
                'Salesforce did not create one resumed schedule at the calculated first payment date.');
            GiftCommitmentSchedule proposed = resumed[0];
            proposed.TransactionAmount = request.amount;
            proposed.TransactionPeriod = request.transactionPeriod;
            proposed.TransactionInterval = request.transactionInterval;
            proposed.TransactionDay = 'Monthly'.equalsIgnoreCase(request.transactionPeriod)
                ? StripeRDScheduleDateCalc.normalizeTransactionDay(request.transactionDay)
                : null;
            Invocable.Action manage = Invocable.Action.createStandardAction('manageRcrGiftCmtSchd');
            manage.setInvocationParameter('giftCommitmentSchedule', proposed);
            manage.setInvocationParameter('effectiveFromDate', firstPayment);
            if (source.EndDate != null) manage.setInvocationParameter('effectiveToDate', source.EndDate);
            requireNativeSuccess(manage.invoke(), 'manage');

            List<GiftCommitmentSchedule> successors = [
                SELECT Id, StartDate, EndDate, TransactionAmount, TransactionPeriod,
                       TransactionInterval, TransactionDay, Type
                FROM GiftCommitmentSchedule WHERE GiftCommitmentId = :gift.Id
                  AND Type = 'CreateTransactions' AND StartDate = :firstPayment
            ];
            if (successors.size() != 1 || successors[0].TransactionAmount != request.amount ||
                successors[0].TransactionPeriod != request.transactionPeriod ||
                successors[0].TransactionInterval != request.transactionInterval ||
                ('Monthly'.equalsIgnoreCase(request.transactionPeriod) &&
                 successors[0].TransactionDay != plan.requestedTransactionDay)) {
                throw new HandoffException('The saved Salesforce successor does not match the requested amount and cadence.');
            }
            Date savedUnpaid;
            for (GiftTransaction transactionRecord : [
                SELECT TransactionDueDate FROM GiftTransaction
                WHERE GiftCommitmentId = :gift.Id AND Status IN ('Pledged', 'Unpaid')
                  AND TransactionDueDate >= TODAY ORDER BY TransactionDueDate LIMIT 1
            ]) savedUnpaid = transactionRecord.TransactionDueDate;
            Date savedNext = [SELECT NextTransactionDate FROM GiftCommitment WHERE Id = :gift.Id]
                .NextTransactionDate;
            if (savedUnpaid != firstPayment || savedNext != firstPayment) {
                throw new HandoffException('Salesforce payment-date mismatch. Expected ' +
                    String.valueOf(firstPayment) + '; earliest unpaid ' + String.valueOf(savedUnpaid) +
                    '; commitment next date ' + String.valueOf(savedNext) + '. Stripe was not queued.');
            }

            StripeRecurringScheduleStampAction.Request stamp =
                new StripeRecurringScheduleStampAction.Request();
            stamp.giftCommitmentId = gift.Id;
            stamp.selectedScheduleId = successors[0].Id;
            stamp.resolvedSourceScheduleId = source.Id;
            stamp.amount = request.amount;
            stamp.transactionPeriod = request.transactionPeriod;
            stamp.transactionInterval = request.transactionInterval;
            stamp.transactionDay = plan.requestedTransactionDay;
            stamp.effectiveDate = firstPayment;
            stamp.managedScheduleStartDate = firstPayment;
            stamp.firstPaymentDate = firstPayment;
            stamp.requestedEndDate = source.EndDate;
            stamp.previousEndDate = source.EndDate;
            stamp.originalStartDate = source.StartDate;
            stamp.recurringType = gift.Recurring_Type__c;
            stamp.changeMode = StripeRecurringChangeMode.TERMS;
            stamp.createRequestAfterSave = true;
            stamp.bridgeBillingGap = true;
            stamp.originalAmount = source.TransactionAmount;
            stamp.originalPeriod = source.TransactionPeriod;
            stamp.originalInterval = Integer.valueOf(source.TransactionInterval);
            stamp.originalTransactionDay = source.TransactionDay;
            List<StripeRecurringScheduleStampAction.Response> stamped =
                StripeRecurringScheduleStampAction.execute(
                    new List<StripeRecurringScheduleStampAction.Request>{stamp});
            if (stamped.isEmpty() || stamped[0].isSuccess != true || stamped[0].requestId == null) {
                throw new HandoffException(stamped.isEmpty() || String.isBlank(stamped[0].errorMessage)
                    ? 'The Stripe request could not be captured.' : stamped[0].errorMessage);
            }
            result.isSuccess = true;
            result.requestId = stamped[0].requestId;
            result.firstPaymentDate = firstPayment;
            result.successorScheduleId = successors[0].Id;
            result.message = 'Salesforce saved and verified the future interval. Stripe synchronization is queued.';
        } catch (Exception failed) {
            Database.rollback(savepoint);
            result.errorMessage = 'No schedule or Stripe request was saved. ' + failed.getMessage();
        } finally {
            StripePauseService.suppressSubscriptionUpdate = originalSuppression;
        }
        return result;
    }

    private static void requireNativeSuccess(List<Invocable.Action.Result> outcomes, String operation) {
        if (outcomes == null || outcomes.isEmpty() || !outcomes[0].isSuccess()) {
            throw new HandoffException('Native Salesforce ' + operation + ' action failed: ' +
                (outcomes == null || outcomes.isEmpty() ? 'no result' : String.valueOf(outcomes[0].getErrors())));
        }
    }

    public class Request {
        @InvocableVariable(required=true) public Id giftCommitmentId;
        @InvocableVariable(required=true) public Id selectedScheduleId;
        @InvocableVariable(required=true) public Decimal amount;
        @InvocableVariable(required=true) public String transactionPeriod;
        @InvocableVariable(required=true) public Integer transactionInterval;
        @InvocableVariable public String transactionDay;
        @InvocableVariable public Date expectedFirstPaymentDate;
    }

    public class Response {
        @InvocableVariable public Boolean isSuccess = false;
        @InvocableVariable public Id requestId;
        @InvocableVariable public Id successorScheduleId;
        @InvocableVariable public Date firstPaymentDate;
        @InvocableVariable public String message;
        @InvocableVariable public String errorMessage;
    }

    private class HandoffException extends Exception {}
}