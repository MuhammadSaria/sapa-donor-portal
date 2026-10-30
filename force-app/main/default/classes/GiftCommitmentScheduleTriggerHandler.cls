public with sharing class GiftCommitmentScheduleTriggerHandler {

    // Recursion guard: the GiftCommitmentSchedule update below re-fires this trigger.
    public static Boolean bypassTrigger = false;

    // Controls which DML runs. The trigger uses BOTH (sync context, safe).
    // The backfill batch runs one phase per execute() to stay under the
    // async queueable limit of 1.
    public enum DmlPhase { BOTH, PARENT_ONLY, SCHEDULE_ONLY }

    // Trigger entry point.
    public static void handleAfterUpdate(
        List<GiftCommitmentSchedule> newList,
        Map<Id, GiftCommitmentSchedule> oldMap
    ) {
        processSchedules(newList, oldMap);
    }

    // Two-arg overload -> runs BOTH phases (used by the trigger).
    public static void processSchedules(
        List<GiftCommitmentSchedule> schedules,
        Map<Id, GiftCommitmentSchedule> oldMap
    ) {
        processSchedules(schedules, oldMap, DmlPhase.BOTH);
    }

    // Main logic.
    //   oldMap == null => insert or backfill mode (recompute Recurring_Type__c regardless of change).
    //   phase          => limits which trigger-firing DML runs (see DmlPhase).
    public static void processSchedules(
        List<GiftCommitmentSchedule> schedules,
        Map<Id, GiftCommitmentSchedule> oldMap,
        DmlPhase phase
    ) {
        Set<Id> giftCommitmentIds = new Set<Id>();
        Map<Id, Date> endDateByGc = new Map<Id, Date>();                 // parent -> new EndDate
        List<GiftCommitmentSchedule> fupCandidates = new List<GiftCommitmentSchedule>();

        for (GiftCommitmentSchedule sch : schedules) {
            if (sch.GiftCommitmentId == null) continue;
            giftCommitmentIds.add(sch.GiftCommitmentId);

            // Requirement 1: End Date change (insert/backfill always recomputes)
            Boolean endDateChanged =
                (oldMap == null) || (sch.EndDate != oldMap.get(sch.Id).EndDate);
            if (endDateChanged) {
                endDateByGc.put(sch.GiftCommitmentId, sch.EndDate);
            }

            // Requirement 2 guard: only schedules not already mapped
            if (sch.OutreachSourceCodeId == null) {
                fupCandidates.add(sch);
            }
        }

        if (giftCommitmentIds.isEmpty()) return;

        // SOQL 1: parent GiftCommitments (FUp fields)
        Map<Id, GiftCommitment> parents = new Map<Id, GiftCommitment>([
            SELECT Id, FundraiseUpId__c, FUp_Campaign_Name__c
            FROM GiftCommitment
            WHERE Id IN :giftCommitmentIds
        ]);

        // Collect qualifying campaign names
        Set<String> campaignNames = new Set<String>();
        for (GiftCommitment gc : parents.values()) {
            if (gc.FundraiseUpId__c != null && String.isNotBlank(gc.FUp_Campaign_Name__c)) {
                campaignNames.add(gc.FUp_Campaign_Name__c);
            }
        }

        // Collect CampaignIds from candidate schedules (skip nulls — they can't match)
        Set<Id> campaignIds = new Set<Id>();
        for (GiftCommitmentSchedule sch : fupCandidates) {
            if (sch.CampaignId != null) campaignIds.add(sch.CampaignId);
        }

        // SOQL 2: resolve (name + campaign) -> OutreachSourceCode Id (first match per key)
        Map<String, Id> sourceCodeByKey = new Map<String, Id>();
        if (!campaignNames.isEmpty() && !campaignIds.isEmpty()) {
            for (OutreachSourceCode osc : [
                SELECT Id, Name, CampaignId
                FROM OutreachSourceCode
                WHERE Name IN :campaignNames AND CampaignId IN :campaignIds
            ]) {
                String key = osc.Name.toLowerCase() + '|' + osc.CampaignId;
                if (!sourceCodeByKey.containsKey(key)) {
                    sourceCodeByKey.put(key, osc.Id);
                }
            }
        }

        // --- Parent updates: End Date -> Recurring_Type__c (deduped per parent) ---
        Map<Id, GiftCommitment> parentUpdates = new Map<Id, GiftCommitment>();
        for (Id gcId : endDateByGc.keySet()) {
            GiftCommitment gc = new GiftCommitment(Id = gcId);
            gc.Recurring_Type__c = (endDateByGc.get(gcId) != null) ? 'Fixed' : 'Open';
            parentUpdates.put(gcId, gc);
        }

        // --- Schedule updates: Requirements 2-4 (map source code onto the SCHEDULE) ---
        List<GiftCommitmentSchedule> scheduleUpdates = new List<GiftCommitmentSchedule>();
        for (GiftCommitmentSchedule sch : fupCandidates) {
            GiftCommitment parent = parents.get(sch.GiftCommitmentId);
            if (parent == null || parent.FundraiseUpId__c == null
                || String.isBlank(parent.FUp_Campaign_Name__c)
                || sch.CampaignId == null) {          // no campaign -> can't match the filter
                continue;
            }
            String key = parent.FUp_Campaign_Name__c.toLowerCase() + '|' + sch.CampaignId;
            Id matchedId = sourceCodeByKey.get(key);
            if (matchedId != null) {
                scheduleUpdates.add(new GiftCommitmentSchedule(
                    Id = sch.Id,
                    OutreachSourceCodeId = matchedId
                ));
            }
        }

        // --- DML (phase-aware so the batch does one trigger-firing DML per execute) ---
        if (phase != DmlPhase.SCHEDULE_ONLY && !parentUpdates.isEmpty()) {
            update parentUpdates.values();                 // fires GiftCommitment automation, not ours
        }
        if (phase != DmlPhase.PARENT_ONLY && !scheduleUpdates.isEmpty()) {
            bypassTrigger = true;                          // stop re-entry from the line below
            try {
                update scheduleUpdates;                    // fires GiftCommitmentSchedule automation
            } finally {
                bypassTrigger = false;
            }
        }
    }
}