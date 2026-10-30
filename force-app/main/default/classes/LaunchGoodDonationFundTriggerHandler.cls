/**
 * Enforces LaunchGood Donation Fund route-key population and duplicate prevention.
 */
public with sharing class LaunchGoodDonationFundTriggerHandler {
    private static final String DUPLICATE_ERROR =
        'A LaunchGood Donation Fund already exists for this Project URL and Special Request. ' +
        'Use a different Special Request or update the existing mapping.';

    /**
     * Populates route keys and blocks duplicate Project URL plus Special Request mappings.
     * @param newRecords Records from Trigger.new.
     */
    public static void beforeSave(List<LaunchGood_Donation_Fund__c> newRecords) {
        if (newRecords == null || newRecords.isEmpty()) {
            return;
        }

        Map<String, LaunchGood_Donation_Fund__c> firstRecordByRouteKey =
            new Map<String, LaunchGood_Donation_Fund__c>();
        Set<String> routeKeys = new Set<String>();
        Set<Id> recordIds = new Set<Id>();

        for (LaunchGood_Donation_Fund__c record : newRecords) {
            if (record.Id != null) {
                recordIds.add(record.Id);
            }

            record.Route_Key__c = LaunchGoodDonationFundRouteKeyService.generateRouteKey(
                record.Project_URL__c,
                record.Special_Request__c
            );

            if (String.isBlank(record.Route_Key__c)) {
                continue;
            }

            routeKeys.add(record.Route_Key__c);
            if (firstRecordByRouteKey.containsKey(record.Route_Key__c)) {
                firstRecordByRouteKey.get(record.Route_Key__c).Project_URL__c.addError(DUPLICATE_ERROR);
                record.Project_URL__c.addError(DUPLICATE_ERROR);
            } else {
                firstRecordByRouteKey.put(record.Route_Key__c, record);
            }
        }

        if (routeKeys.isEmpty()) {
            return;
        }

        for (LaunchGood_Donation_Fund__c existingRecord : [
            SELECT Id, Route_Key__c
            FROM LaunchGood_Donation_Fund__c
            WHERE Route_Key__c IN :routeKeys AND Id NOT IN :recordIds
        ]) {
            LaunchGood_Donation_Fund__c incomingRecord = firstRecordByRouteKey.get(existingRecord.Route_Key__c);
            if (incomingRecord != null) {
                incomingRecord.Project_URL__c.addError(DUPLICATE_ERROR);
            }
        }
    }
}