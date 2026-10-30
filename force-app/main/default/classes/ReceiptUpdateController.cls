public with sharing class ReceiptUpdateController {

    @AuraEnabled
    public static void markReceiptsAsSent() {
        List<GiftTransaction> opps = [
            SELECT Id, Paper_Receipt_Requested__c
            FROM GiftTransaction
            WHERE Paper_Receipt_Requested__c = 'Receipt Requested'
            And Status = 'Paid'
            And GiftCommitmentId = null
        ];
        
        for (GiftTransaction o : opps) {
            o.Paper_Receipt_Requested__c = 'Receipt Sent';
        }
        
        update opps;
        
        System.debug('Updated ' + opps.size() + ' Opportunity records.');
        
            }
        }