/** Selects an existing environment-compatible configuration without modifying its values. */
// Organization identity and custom metadata are system configuration, not donor records.
@SuppressWarnings('PMD.ApexCRUDViolation')
public with sharing class StripeRecurringSyncConfig {
    @TestVisible private static Stripe_Recurring_Sync_Config__mdt cached;
    @TestVisible private static Boolean loaded = false;
    public static Stripe_Recurring_Sync_Config__mdt resolve() {
        if (!loaded) {
            Boolean sandbox = [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
            cached = selectExisting(sandbox,[SELECT DeveloperName,Enabled__c,Max_Attempts__c,
                Require_Test_Mode__c,Trial_Bridge_Enabled__c FROM Stripe_Recurring_Sync_Config__mdt]);
            loaded = true;
        }
        return cached;
    }
    @TestVisible private static Stripe_Recurring_Sync_Config__mdt selectExisting(
        Boolean sandbox,List<Stripe_Recurring_Sync_Config__mdt> records) {
        List<Stripe_Recurring_Sync_Config__mdt> eligible=new List<Stripe_Recurring_Sync_Config__mdt>();
        for(Stripe_Recurring_Sync_Config__mdt record:records) {
            if(record.Require_Test_Mode__c==sandbox) eligible.add(record);
        }
        // Retain the established staging record when it is explicitly test-mode.
        if(sandbox) for(Stripe_Recurring_Sync_Config__mdt record:eligible)
            if(record.DeveloperName=='Sandbox_Default') return record;
        // Production requires an unambiguous existing live configuration.
        return eligible.size()==1 ? eligible[0] : null;
    }
}