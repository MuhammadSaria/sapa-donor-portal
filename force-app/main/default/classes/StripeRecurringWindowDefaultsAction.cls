/**
 * Read-only Flow action that supplies the earliest safe effective date and an
 * immutable snapshot of the selected schedule before staff edit its terms.
 */
public with sharing class StripeRecurringWindowDefaultsAction {
    @InvocableMethod(
        label='Get Recurring Terms Window Defaults'
        description='Returns the earliest future unpaid date and original recurring schedule terms.'
        category='Stripe Recurring Donations'
    )
    public static List<Response> execute(List<Request> requests) {
        if (requests == null) return new List<Response>();

        Set<Id> scheduleIds = new Set<Id>();
        Set<Id> commitmentIds = new Set<Id>();
        for (Request request : requests) {
            if (request == null) continue;
            if (request.selectedScheduleId != null) scheduleIds.add(request.selectedScheduleId);
            if (request.giftCommitmentId != null) commitmentIds.add(request.giftCommitmentId);
        }

        Map<Id, GiftCommitmentSchedule> schedules = scheduleIds.isEmpty()
            ? new Map<Id, GiftCommitmentSchedule>()
            : new Map<Id, GiftCommitmentSchedule>([
                SELECT Id, GiftCommitmentId, StartDate, EndDate, TransactionAmount,
                       TransactionPeriod, TransactionInterval
                FROM GiftCommitmentSchedule
                WHERE Id IN :scheduleIds
            ]);
        Map<Id, Date> earliestFutureDate = new Map<Id, Date>();
        Date today = Date.today();
        if (!commitmentIds.isEmpty()) {
            for (GiftTransaction transactionRecord : [
                SELECT GiftCommitmentId, TransactionDueDate
                FROM GiftTransaction
                WHERE GiftCommitmentId IN :commitmentIds
                  AND Status IN ('Pledged', 'Unpaid')
                  AND TransactionDueDate >= :today
                ORDER BY GiftCommitmentId, TransactionDueDate, CreatedDate
            ]) {
                if (!earliestFutureDate.containsKey(transactionRecord.GiftCommitmentId)) {
                    earliestFutureDate.put(
                        transactionRecord.GiftCommitmentId,
                        transactionRecord.TransactionDueDate
                    );
                }
            }
        }

        List<Response> responses = new List<Response>();
        for (Request request : requests) {
            Response response = new Response();
            GiftCommitmentSchedule schedule = request == null
                ? null
                : schedules.get(request.selectedScheduleId);
            if (request == null || request.giftCommitmentId == null ||
                schedule == null || schedule.GiftCommitmentId != request.giftCommitmentId) {
                response.isSuccess = false;
                response.errorType = 'INVALID_SELECTED_SCHEDULE';
                response.errorMessage = 'Select the recurring donation schedule you want to change.';
                responses.add(response);
                continue;
            }

            response.isSuccess = true;
            response.effectiveStartDate = earliestFutureDate.get(request.giftCommitmentId);
            if (response.effectiveStartDate == null) response.effectiveStartDate = today;
            response.originalAmount = schedule.TransactionAmount;
            response.originalPeriod = schedule.TransactionPeriod;
            response.originalInterval = schedule.TransactionInterval == null
                ? 1
                : Integer.valueOf(schedule.TransactionInterval);
            response.originalEndDate = schedule.EndDate;
            responses.add(response);
        }
        return responses;
    }

    public class Request {
        @InvocableVariable(label='Gift Commitment ID' required=true)
        public Id giftCommitmentId;
        @InvocableVariable(label='Selected Gift Commitment Schedule ID' required=true)
        public Id selectedScheduleId;
    }

    public class Response {
        @InvocableVariable(label='Success') public Boolean isSuccess;
        @InvocableVariable(label='Error Type') public String errorType;
        @InvocableVariable(label='Error Message') public String errorMessage;
        @InvocableVariable(label='Default Effective Start Date') public Date effectiveStartDate;
        @InvocableVariable(label='Original Amount') public Decimal originalAmount;
        @InvocableVariable(label='Original Period') public String originalPeriod;
        @InvocableVariable(label='Original Interval') public Integer originalInterval;
        @InvocableVariable(label='Original End Date') public Date originalEndDate;
    }
}