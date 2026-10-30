/** Updates the parent recurring type before a managed Gift Commitment Schedule action runs. */
public with sharing class RecurringDonationParentTypeAction {
    @InvocableMethod(
        label='Update Parent Recurring Donation Type'
        description='Updates only GiftCommitment.Recurring_Type__c so Open or Fixed remains parent-owned.'
        category='Recurring Donations'
    )
    public static List<Response> execute(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null) return responses;
        Map<Id, String> requestedTypes = new Map<Id, String>();
        for (Request request : requests) {
            Response response = new Response();
            responses.add(response);
            if (request == null || request.giftCommitmentId == null ||
                (request.recurringType != 'Open' && request.recurringType != 'Fixed')) {
                response.success = false;
                response.errorMessage = 'Gift Commitment ID and an Open or Fixed recurring type are required.';
                continue;
            }
            requestedTypes.put(request.giftCommitmentId, request.recurringType);
        }
        if (requestedTypes.isEmpty()) return responses;

        Map<Id, GiftCommitment> currentById = new Map<Id, GiftCommitment>([
            SELECT Id, Recurring_Type__c FROM GiftCommitment WHERE Id IN :requestedTypes.keySet()
        ]);
        List<GiftCommitment> updates = new List<GiftCommitment>();
        for (Id commitmentId : requestedTypes.keySet()) {
            GiftCommitment current = currentById.get(commitmentId);
            if (current != null && current.Recurring_Type__c != requestedTypes.get(commitmentId)) {
                updates.add(new GiftCommitment(
                    Id = commitmentId,
                    Recurring_Type__c = requestedTypes.get(commitmentId)
                ));
            }
        }
        if (!updates.isEmpty()) update updates;
        for (Integer index = 0; index < requests.size(); index++) {
            if (responses[index].success == false) continue;
            Request request = requests[index];
            responses[index].success = request != null && currentById.containsKey(request.giftCommitmentId);
            if (!responses[index].success) responses[index].errorMessage = 'The Gift Commitment could not be found.';
        }
        return responses;
    }

    public class Request {
        @InvocableVariable(label='Gift Commitment ID' required=true) public Id giftCommitmentId;
        @InvocableVariable(label='Recurring Type' required=true) public String recurringType;
    }

    public class Response {
        @InvocableVariable(label='Success') public Boolean success;
        @InvocableVariable(label='Error Message') public String errorMessage;
    }
}