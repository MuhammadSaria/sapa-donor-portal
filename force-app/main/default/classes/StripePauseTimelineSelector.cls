/** Loads the minimal pause timeline without altering recurring terms or financial history. */
public inherited sharing class StripePauseTimelineSelector {
    public static List<GiftCommitmentSchedule> schedules(Id commitmentId) {
        return [SELECT Id,GiftCommitmentId,Type,StartDate,EndDate,TransactionAmount,
            TransactionPeriod,TransactionInterval,TransactionDay,PaymentMethod,
            Final_Payment_Date__c FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId=:commitmentId WITH USER_MODE ORDER BY StartDate,Id LIMIT 201];
    }
    public static List<GiftTransaction> transactions(Id commitmentId) {
        return [SELECT Id,GiftCommitmentScheduleId,Status,OriginalAmount,TransactionDate,TransactionDueDate
            FROM GiftTransaction WHERE GiftCommitmentId=:commitmentId
            AND (Status='Paid' OR Status='Unpaid' OR Status='Pledged')
            WITH USER_MODE ORDER BY TransactionDueDate,Id LIMIT 5001];
    }
    public static GiftCommitment commitment(Id commitmentId) {
        return [SELECT Id,Status,Subscription_Id__c,Recurring_Type__c,Pause_Reason__c,
            Pause_Start_Date__c,Pause_Resume_Date__c,Stripe_Pause_State__c,
            Stripe_Pause_Attempt_Count__c,Stripe_Pause_Plan__c,Stripe_Pause_Last_Error__c,NextTransactionDate
            FROM GiftCommitment WHERE Id=:commitmentId WITH USER_MODE LIMIT 1];
    }
}