/**
 * Read-only adapter for legacy fundraising Flow Get Records elements that can no longer
 * be compiled into new custom Flow versions.
 */
public with sharing class FundraisingFlowReadAction {
    /** Returns the same records and ordering used by the two guided schedule Flows. */
    @InvocableMethod(
        label='Read Fundraising Schedule Records'
        description='Reads Gift Commitments, Gift Commitment Schedules, or Payment Instruments without mutation.'
        category='Recurring Donations'
    )
    public static List<Response> execute(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null) return responses;
        for (Request request : requests) responses.add(readOne(request));
        return responses;
    }

    private static Response readOne(Request request) {
        Response response = new Response();
        if (request == null || String.isBlank(request.operation)) return response;
        if (request.operation == 'GiftCommitmentById') {
            List<GiftCommitment> rows = request.recordId == null ? new List<GiftCommitment>() : [
                SELECT Id, Name, Status, ScheduleType, CampaignId, ExpectedEndDate,
                       ExpectedTotalCmtAmount, CreatedDate, DonorId, Recurring_Type__c,
                       Payment_Processor__c, Payment_type__c, Subscription_Id__c
                FROM GiftCommitment
                WHERE Id = :request.recordId AND Status IN ('Active', 'Draft', 'Paused')
                ORDER BY CreatedDate ASC LIMIT 1
            ];
            response.giftCommitment = rows.isEmpty() ? null : rows[0];
            populateStripeEligibility(response, response.giftCommitment);
        } else if (request.operation == 'GiftCommitmentsByDonor') {
            response.giftCommitments = request.recordId == null ? new List<GiftCommitment>() : [
                SELECT Id, Name, Status, ScheduleType, CampaignId, ExpectedEndDate,
                       ExpectedTotalCmtAmount, CreatedDate, DonorId, Recurring_Type__c,
                       Payment_Processor__c, Payment_type__c, Subscription_Id__c
                FROM GiftCommitment
                WHERE DonorId = :request.recordId
                  AND Status IN ('Active', 'Draft', 'Paused')
                  AND ScheduleType != null
            ];
        } else if (request.operation == 'GiftCommitmentIdsByInput') {
            resolveGiftCommitmentIds(request.recordId, response);
        } else if (request.operation == 'ActiveSchedulesByCommitment') {
            response.giftCommitmentSchedules = readSchedules(
                request.recordId == null ? new Set<Id>() : new Set<Id>{ request.recordId },
                'CreateTransactions'
            );
        } else if (request.operation == 'PausedSchedulesByCommitment') {
            response.giftCommitmentSchedules = readSchedules(
                request.recordId == null ? new Set<Id>() : new Set<Id>{ request.recordId },
                'PauseTransactions'
            );
        } else if (request.operation == 'ActiveSchedulesByCommitments') {
            response.giftCommitmentSchedules = readSchedules(
                request.recordIds == null ? new Set<Id>() : new Set<Id>(request.recordIds),
                'CreateTransactions'
            );
        } else if (request.operation == 'PaymentInstrumentById') {
            List<PaymentInstrument> rows = request.recordId == null ? new List<PaymentInstrument>() : [
                SELECT Id, Type, Last4, ExpiryMonth, ExpiryYear
                FROM PaymentInstrument WHERE Id = :request.recordId LIMIT 1
            ];
            response.paymentInstrument = rows.isEmpty() ? null : rows[0];
        }
        return response;
    }

    private static void resolveGiftCommitmentIds(Id inputRecordId, Response response) {
        response.giftCommitmentIds = new List<Id>();
        response.isError = false;
        if (inputRecordId == null) {
            setInputResolutionError(response, 'INVALID_RECORD_ID', 'A donor or recurring donation record ID is required.');
            return;
        }
        List<GiftCommitment> rows;
        if (inputRecordId.getSObjectType() == Account.SObjectType) {
            rows = [
                SELECT Id FROM GiftCommitment
                WHERE DonorId = :inputRecordId
                  AND Status IN ('Active', 'Draft', 'Paused')
                  AND ScheduleType = 'Recurring'
                ORDER BY CreatedDate ASC
            ];
        } else if (inputRecordId.getSObjectType() == GiftCommitment.SObjectType) {
            rows = [
                SELECT Id FROM GiftCommitment
                WHERE Id = :inputRecordId
                  AND Status IN ('Active', 'Draft', 'Paused')
                  AND ScheduleType = 'Recurring'
                LIMIT 1
            ];
        } else {
            setInputResolutionError(response, 'INVALID_RECORD_ID', 'Use a donor or recurring donation record ID.');
            return;
        }
        for (GiftCommitment row : rows) response.giftCommitmentIds.add(row.Id);
        if (response.giftCommitmentIds.isEmpty()) {
            setInputResolutionError(
                response,
                'NO_RECURRING_DONATION',
                'No active, draft, or paused recurring donation was found for this record.'
            );
        }
    }

    private static void setInputResolutionError(Response response, String code, String message) {
        response.isError = true;
        response.errorCode = code;
        response.errorMessage = message;
    }

    private static void populateStripeEligibility(Response response, GiftCommitment commitment) {
        if (commitment == null) return;
        response.isStripeClassified =
            'Stripe'.equalsIgnoreCase(commitment.Payment_Processor__c) ||
            'Credit Card'.equalsIgnoreCase(commitment.Payment_type__c);
        response.isVerifiedStripe = response.isStripeClassified &&
            String.isNotBlank(commitment.Subscription_Id__c);
        if (response.isStripeClassified && String.isBlank(commitment.Subscription_Id__c)) {
            response.stripeEligibilityWarning =
                'This donation is marked as Stripe or Credit Card, but it has no Stripe subscription ID. ' +
                'The Salesforce schedule can still be saved, but Stripe will not be changed.';
        } else if (!response.isStripeClassified && String.isNotBlank(commitment.Subscription_Id__c)) {
            response.stripeEligibilityWarning =
                'A Stripe subscription ID exists, but the donation is not classified as Stripe or Credit Card. ' +
                'The Salesforce schedule can still be saved, but Stripe will not be changed.';
        }
    }

    private static List<GiftCommitmentSchedule> readSchedules(Set<Id> commitmentIds, String scheduleType) {
        if (commitmentIds.isEmpty()) return new List<GiftCommitmentSchedule>();
        return [
            SELECT Id, GiftCommitmentId, GiftCommitmentName, GiftCommitmentStatus,
                   StartDate, EndDate, TransactionPeriod, TransactionAmount,
                   CampaignName, CampaignId, OutreachSourceCodeId, PaymentInstrumentId,
                   PaymentMethod, TransactionDay, TransactionInterval, Type
            FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId IN :commitmentIds
              AND Type = :scheduleType
              AND (EndDate >= TODAY OR EndDate = null)
            ORDER BY StartDate ASC
        ];
    }

    public class Request {
        @InvocableVariable(label='Read Operation' required=true) public String operation;
        @InvocableVariable(label='Record ID') public Id recordId;
        @InvocableVariable(label='Gift Commitment IDs') public List<Id> recordIds;
    }

    public class Response {
        @InvocableVariable(label='Gift Commitment') public GiftCommitment giftCommitment;
        @InvocableVariable(label='Gift Commitments') public List<GiftCommitment> giftCommitments;
        @InvocableVariable(label='Gift Commitment Schedules') public List<GiftCommitmentSchedule> giftCommitmentSchedules;
        @InvocableVariable(label='Payment Instrument') public PaymentInstrument paymentInstrument;
        @InvocableVariable(label='Stripe or Card Classified') public Boolean isStripeClassified;
        @InvocableVariable(label='Verified Stripe Subscription') public Boolean isVerifiedStripe;
        @InvocableVariable(label='Stripe Eligibility Warning') public String stripeEligibilityWarning;
        @InvocableVariable(label='Gift Commitment IDs') public List<Id> giftCommitmentIds;
        @InvocableVariable(label='Input Resolution Failed') public Boolean isError;
        @InvocableVariable(label='Input Resolution Error Code') public String errorCode;
        @InvocableVariable(label='Input Resolution Error Message') public String errorMessage;
    }
}