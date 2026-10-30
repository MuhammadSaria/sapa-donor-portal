/** Explicit in-memory configuration for mocked integration tests; never creates metadata records. */
@IsTest
public class StripeRecurringSyncConfigTestData {
    public static void useMockConfiguration() {
        StripeRecurringSyncConfig.cached=new Stripe_Recurring_Sync_Config__mdt(
            DeveloperName='Unit_Test_Only',Enabled__c=true,Max_Attempts__c=3,
            Require_Test_Mode__c=true,Trial_Bridge_Enabled__c=true);
        StripeRecurringSyncConfig.loaded=true;
    }
}