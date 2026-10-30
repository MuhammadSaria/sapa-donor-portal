public without sharing class OutreachSourceCodeRollupHandler {
    @TestVisible private static Boolean enabledOverride;
    public static Boolean isEnabled() {
        if (enabledOverride != null) return enabledOverride;
        Apex_Triggers__mdt settings = Apex_Triggers__mdt.getInstance('Apex_Trigger');
        return settings != null && settings.TriggerOnOSC__c == true;
    }


    public static void rollupToCampaign(
        List<OutreachSourceCode> newRecords,
        List<OutreachSourceCode> oldRecords
    ) {
        Set<Id> campaignIds = getAffectedCampaignIds(newRecords, oldRecords);

        if (campaignIds.isEmpty()) {
            return;
        }

        Map<Id, Campaign> campaignsToUpdate = new Map<Id, Campaign>();

        // Initialize every affected Campaign to zero.
        // This handles the case where all child records are deleted or moved away.
        for (Id campaignId : campaignIds) {
            campaignsToUpdate.put(
                campaignId,
                new Campaign(
                    Id = campaignId,
                    Total_Actual_Cost_in_OSC__c = 0,
                    Total_Budgeted_Cost_in_OSC__c = 0,
                    Total_Expected_Revenue_in_OSC__c = 0
                )
            );
        }

        for (AggregateResult ar : [
            SELECT
                CampaignId campaignId,
                SUM(Actual_Cost_in_OSC__c) totalActualCost,
                SUM(Budgeted_Cost_in_OSC__c) totalBudgetedCost,
                SUM(Expected_Revenue_in_OSC__c) totalExpectedRevenue
            FROM OutreachSourceCode
            WHERE CampaignId IN :campaignIds
            GROUP BY CampaignId
        ]) {
            Id campaignId = (Id) ar.get('campaignId');

            Campaign campaignRecord = campaignsToUpdate.get(campaignId);

            campaignRecord.Total_Actual_Cost_in_OSC__c =
                toDecimal(ar.get('totalActualCost'));

            campaignRecord.Total_Budgeted_Cost_in_OSC__c =
                toDecimal(ar.get('totalBudgetedCost'));

            campaignRecord.Total_Expected_Revenue_in_OSC__c =
                toDecimal(ar.get('totalExpectedRevenue'));
        }

        update campaignsToUpdate.values();
    }

    private static Set<Id> getAffectedCampaignIds(
        List<OutreachSourceCode> newRecords,
        List<OutreachSourceCode> oldRecords
    ) {
        Set<Id> campaignIds = new Set<Id>();

        Map<Id, OutreachSourceCode> oldRecordById = new Map<Id, OutreachSourceCode>();

        if (oldRecords != null) {
            for (OutreachSourceCode oldRecord : oldRecords) {
                oldRecordById.put(oldRecord.Id, oldRecord);
            }
        }

        // Insert, update, undelete
        if (newRecords != null) {
            for (OutreachSourceCode newRecord : newRecords) {
                OutreachSourceCode oldRecord = oldRecordById.get(newRecord.Id);

                // Insert or undelete
                if (oldRecord == null) {
                    if (newRecord.CampaignId != null) {
                        campaignIds.add(newRecord.CampaignId);
                    }
                }
                // Update
                else if (isRollupRelevantChange(oldRecord, newRecord)) {
                    if (oldRecord.CampaignId != null) {
                        campaignIds.add(oldRecord.CampaignId);
                    }

                    if (newRecord.CampaignId != null) {
                        campaignIds.add(newRecord.CampaignId);
                    }
                }
            }
        }

        // Delete
        if (newRecords == null && oldRecords != null) {
            for (OutreachSourceCode oldRecord : oldRecords) {
                if (oldRecord.CampaignId != null) {
                    campaignIds.add(oldRecord.CampaignId);
                }
            }
        }

        return campaignIds;
    }

    private static Boolean isRollupRelevantChange(
        OutreachSourceCode oldRecord,
        OutreachSourceCode newRecord
    ) {
        return oldRecord.CampaignId != newRecord.CampaignId
            || oldRecord.Actual_Cost_in_OSC__c != newRecord.Actual_Cost_in_OSC__c
            || oldRecord.Budgeted_Cost_in_OSC__c != newRecord.Budgeted_Cost_in_OSC__c
            || oldRecord.Expected_Revenue_in_OSC__c != newRecord.Expected_Revenue_in_OSC__c;
    }

    private static Decimal toDecimal(Object aggregateValue) {
        return aggregateValue == null ? 0 : (Decimal) aggregateValue;
    }
}