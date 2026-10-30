@IsTest private class StripeRecurringSyncConfigTest {
    private static Stripe_Recurring_Sync_Config__mdt config(String name,Boolean testMode,Boolean enabled) {
        return new Stripe_Recurring_Sync_Config__mdt(DeveloperName=name,Require_Test_Mode__c=testMode,
            Enabled__c=enabled,Max_Attempts__c=7,Trial_Bridge_Enabled__c=true);
    }
    @IsTest static void selectsExistingProductionNameAndValues() {
        Stripe_Recurring_Sync_Config__mdt live=config('Existing_Live',false,true);
        Stripe_Recurring_Sync_Config__mdt selected=StripeRecurringSyncConfig.selectExisting(false,
            new List<Stripe_Recurring_Sync_Config__mdt>{config('Sandbox_Default',true,true),live});
        System.assertEquals('Existing_Live',selected.DeveloperName);
        System.assertEquals(7,selected.Max_Attempts__c);
        System.assertEquals(true,selected.Trial_Bridge_Enabled__c);
    }
    @IsTest static void failsClosedForMissingOrAmbiguousLiveConfiguration() {
        System.assertEquals(null,StripeRecurringSyncConfig.selectExisting(false,
            new List<Stripe_Recurring_Sync_Config__mdt>{config('Sandbox_Default',true,true)}));
        System.assertEquals(null,StripeRecurringSyncConfig.selectExisting(false,
            new List<Stripe_Recurring_Sync_Config__mdt>{config('Live_One',false,true),config('Live_Two',false,true)}));
    }
    @IsTest static void retainsDisabledLiveSetting() {
        System.assertEquals(false,StripeRecurringSyncConfig.selectExisting(false,
            new List<Stripe_Recurring_Sync_Config__mdt>{config('Live',false,false)}).Enabled__c);
    }
    @IsTest static void preservesStagingDefaultAndRejectsLiveInSandbox() {
        System.assertEquals('Sandbox_Default',StripeRecurringSyncConfig.selectExisting(true,
            new List<Stripe_Recurring_Sync_Config__mdt>{config('Other_Test',true,true),config('Sandbox_Default',true,true)}).DeveloperName);
        System.assertEquals(null,StripeRecurringSyncConfig.selectExisting(true,
            new List<Stripe_Recurring_Sync_Config__mdt>{config('Sandbox_Default',false,true)}));
    }
    @IsTest static void acceptsUniqueTestConfigurationAndRejectsAmbiguity() {
        System.assertEquals('Existing_Test',StripeRecurringSyncConfig.selectExisting(true,
            new List<Stripe_Recurring_Sync_Config__mdt>{config('Existing_Test',true,true)}).DeveloperName);
        System.assertEquals(null,StripeRecurringSyncConfig.selectExisting(true,
            new List<Stripe_Recurring_Sync_Config__mdt>{config('One',true,true),config('Two',true,true)}));
    }
    @IsTest static void readsCurrentEnvironmentWithoutMutatingMetadata() {
        Stripe_Recurring_Sync_Config__mdt first=StripeRecurringSyncConfig.resolve();
        System.assertEquals(true,StripeRecurringSyncConfig.loaded);
        System.assertEquals(first,StripeRecurringSyncConfig.resolve());
    }
}