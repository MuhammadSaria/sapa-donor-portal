/**
 * Compatibility action for the managed fundraising records that current Flow
 * versions no longer permit Delete Records elements to delete directly.
 */
public with sharing class FundraisingFlowDeleteSchedulesAction {
    @InvocableMethod(
        label='Delete Custom Gift Commitment Schedules'
        description='Deletes Gift Transactions for the selected schedules, then deletes the schedules atomically.'
        category='Recurring Donations'
    )
    public static List<Response> execute(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null) return responses;
        for (Request request : requests) responses.add(deleteOne(request));
        return responses;
    }

    private static Response deleteOne(Request request) {
        Response response = new Response();
        Set<Id> scheduleIds = request == null || request.scheduleIds == null
            ? new Set<Id>()
            : new Set<Id>(request.scheduleIds);
        scheduleIds.remove(null);
        if (scheduleIds.isEmpty()) {
            response.isSuccess = true;
            return response;
        }

        Savepoint savepoint = Database.setSavepoint();
        try {
            List<GiftTransaction> transactions = [
                SELECT Id FROM GiftTransaction
                WHERE GiftCommitmentScheduleId IN :scheduleIds
            ];
            if (!transactions.isEmpty()) delete transactions;

            List<GiftCommitmentSchedule> schedules = [
                SELECT Id FROM GiftCommitmentSchedule WHERE Id IN :scheduleIds
            ];
            if (!schedules.isEmpty()) delete schedules;

            response.isSuccess = true;
            response.deletedTransactionCount = transactions.size();
            response.deletedScheduleCount = schedules.size();
            return response;
        } catch (Exception error) {
            Database.rollback(savepoint);
            throw new DeleteSchedulesException('Unable to delete the selected custom recurring schedules: ' + error.getMessage());
        }
    }

    public class Request {
        @InvocableVariable(label='Gift Commitment Schedule IDs' required=true)
        public List<Id> scheduleIds;
    }

    public class Response {
        @InvocableVariable(label='Succeeded') public Boolean isSuccess;
        @InvocableVariable(label='Deleted Gift Transactions') public Integer deletedTransactionCount;
        @InvocableVariable(label='Deleted Gift Commitment Schedules') public Integer deletedScheduleCount;
    }

    public class DeleteSchedulesException extends Exception {}
}