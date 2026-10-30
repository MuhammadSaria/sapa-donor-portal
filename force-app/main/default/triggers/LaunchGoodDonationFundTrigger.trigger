trigger LaunchGoodDonationFundTrigger on LaunchGood_Donation_Fund__c(before insert, before update) {
    LaunchGoodDonationFundTriggerHandler.beforeSave(Trigger.new);
}