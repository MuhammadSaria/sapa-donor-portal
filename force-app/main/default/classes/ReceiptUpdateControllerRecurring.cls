public with sharing class ReceiptUpdateControllerRecurring {

    @AuraEnabled
    public static void markRecurringReceiptsAsSent() {

        // Get all recurring donations that have receipt requested and first payment posted
        List<GiftCommitment> rds = [
            SELECT Id, Paper_Receipt__c
            FROM GiftCommitment
            WHERE Paper_Receipt__c = 'Receipt Requested'
              AND Status = 'Active'
              AND Id IN (
                    SELECT GiftCommitmentId
                    FROM GiftTransaction
                    WHERE Status = 'Paid'
              )
        ];

        // Update status
        for (GiftCommitment rd : rds) {
            rd.Paper_Receipt__c = 'Receipt Sent';
        }

        update rds;

        System.debug('Updated ' + rds.size() + ' Recurring Donation records.');
    }
}