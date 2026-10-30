public with sharing class StripeVoidService {
    private static final String STRIPE_SECRET_KEY=System.Label.Stripe_Secret;
    private static final String STRIPE_API_BASE='https://api.stripe.com/v1';
    @TestVisible private static Boolean failSalesforceSave=false;

    @AuraEnabled
    public static Boolean deleteSubscription(String subscriptionId,Id recurringDonationId,String closedReason) {
        if(String.isBlank(subscriptionId)||recurringDonationId==null||String.isBlank(closedReason))
            throw failure('Subscription, recurring donation and closed reason are required.');
        if(!Schema.sObjectType.GiftCommitment.isAccessible()||!Schema.sObjectType.GiftCommitment.isUpdateable()||
            !GiftCommitment.Subscription_Id__c.getDescribe().isAccessible()||
            !GiftCommitment.Status.getDescribe().isUpdateable()||
            !GiftCommitment.Cancelled_Subscription__c.getDescribe().isUpdateable()||
            !GiftCommitment.ClosedReason__c.getDescribe().isUpdateable())
            throw failure('You need recurring donation read and cancellation update permissions.');
        List<GiftCommitment> records=[SELECT Id,Subscription_Id__c FROM GiftCommitment WHERE Id=:recurringDonationId LIMIT 1];
        if(records.isEmpty()||records[0].Subscription_Id__c!=subscriptionId)
            throw failure('The Stripe subscription does not match this recurring donation.');
        Boolean validReason=false;
        for(Schema.PicklistEntry entry:GiftCommitment.ClosedReason__c.getDescribe().getPicklistValues())
            if(entry.isActive()&&entry.getValue()==closedReason) validReason=true;
        if(!validReason) throw failure('Select a valid closed reason before cancelling.');

        HttpRequest request=new HttpRequest();
        request.setEndpoint(STRIPE_API_BASE+'/subscriptions/'+EncodingUtil.urlEncode(subscriptionId,'UTF-8'));
        request.setMethod('DELETE');request.setTimeout(20000);
        request.setHeader('Authorization','Bearer '+STRIPE_SECRET_KEY);
        request.setHeader('Content-Type','application/x-www-form-urlencoded');
        HttpResponse response;
        try { response=new Http().send(request); }
        catch(Exception transportError) {
            logVoidFailure(subscriptionId,recurringDonationId,null,'Stripe cancellation request could not be completed',transportError.getMessage());
            throw failure('Stripe cancellation could not be confirmed. Review the subscription before retrying.');
        }
        if(response.getStatusCode()!=200) {
            logVoidFailure(subscriptionId,recurringDonationId,response.getStatusCode(),'Stripe rejected the subscription cancellation',null);
            return false;
        }
        Map<String,Object> canceled;
        try { canceled=(Map<String,Object>)JSON.deserializeUntyped(response.getBody()); }
        catch(Exception invalidResponse) {
            logVoidFailure(subscriptionId,recurringDonationId,200,'Stripe cancellation response could not be read',invalidResponse.getMessage());
            throw failure('Stripe cancellation could not be verified. Review the subscription before retrying.');
        }
        if(canceled==null||canceled.get('id')!=subscriptionId||canceled.get('status')!='canceled') {
            logVoidFailure(subscriptionId,recurringDonationId,200,'Stripe did not confirm the subscription as canceled',null);
            throw failure('Stripe cancellation could not be verified. Review the subscription before retrying.');
        }

        Savepoint savePoint=Database.setSavepoint();
        try {
            if(failSalesforceSave) throw new CancellationSaveException('Forced rollback test.');
            update new GiftCommitment(Id=recurringDonationId,Cancelled_Subscription__c=true,Status='Closed',ClosedReason__c=closedReason);
            return true;
        } catch(Exception saveError) {
            Database.rollback(savePoint);
            logVoidFailure(subscriptionId,recurringDonationId,200,
                'Stripe subscription was canceled, but closing the recurring donation in Salesforce failed. Reconciliation required',
                saveError.getMessage());
            throw failure('Stripe subscription was canceled, but Salesforce closure failed. Reconciliation required; do not cancel again.');
        }
    }
    // Published before the AuraHandledException is thrown, so it survives the rollback.
    private static void logVoidFailure(String subscriptionId,Id recurringDonationId,Integer httpStatus,String reason,String message) {
        StripeFailureLogger.record(StripeFailureLogger.failure(
                StripeFailureLogger.SOURCE_REFUND_VOID,StripeFailureLogger.CODE_VOID_FAILED,reason)
            .withError(message).operation('StripeVoidService.deleteSubscription')
            .subscription(subscriptionId).commitment(recurringDonationId).httpStatus(httpStatus));
        StripeFailureLogger.flush();
    }
    private static AuraHandledException failure(String message) {
        AuraHandledException error=new AuraHandledException(message);error.setMessage(message);return error;
    }
    private class CancellationSaveException extends Exception {}
}