/** Shared scheduled worker; batch scope one isolates each subscription callout and DML. */
public with sharing class StripePauseWorker implements Schedulable, Database.Batchable<SObject>, Database.AllowsCallouts {
    public void execute(SchedulableContext context) { Database.executeBatch(new StripePauseWorker(), 1); }
    public Database.QueryLocator start(Database.BatchableContext context) {
        Date today = StripePauseBusinessClock.today();
        return Database.getQueryLocator([
            SELECT Id FROM GiftCommitment WHERE
            (Stripe_Pause_State__c = 'Scheduled' AND Pause_Start_Date__c <= :today)
            OR (Stripe_Pause_State__c = 'Active' AND Pause_Resume_Date__c <= :today)
            OR (Stripe_Pause_State__c = 'Resume Scheduled' AND NextTransactionDate <= :today)
        ]);
    }
    public void execute(Database.BatchableContext context, List<SObject> scope) {
        for (SObject record : scope) StripePauseOrchestrator.processDue(record.Id);
    }
    public void finish(Database.BatchableContext context) { }
}