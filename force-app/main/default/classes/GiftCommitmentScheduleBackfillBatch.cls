public with sharing class GiftCommitmentScheduleBackfillBatch
        implements Database.Batchable<SObject> {

    private final GiftCommitmentScheduleTriggerHandler.DmlPhase phase;

    // Default entry: start with the parent phase.
    public GiftCommitmentScheduleBackfillBatch() {
        this(GiftCommitmentScheduleTriggerHandler.DmlPhase.PARENT_ONLY);
    }

    public GiftCommitmentScheduleBackfillBatch(
        GiftCommitmentScheduleTriggerHandler.DmlPhase phase
    ) {
        this.phase = phase;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, GiftCommitmentId, EndDate, OutreachSourceCodeId, CampaignId
            FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId != null
        ]);
    }

    public void execute(Database.BatchableContext bc, List<GiftCommitmentSchedule> scope) {
        // oldMap == null => backfill recompute; phase limits which DML runs.
        GiftCommitmentScheduleTriggerHandler.processSchedules(scope, null, phase);
    }

    public void finish(Database.BatchableContext bc) {
        // After all parent updates finish, launch the schedule-mapping phase.
        if (phase == GiftCommitmentScheduleTriggerHandler.DmlPhase.PARENT_ONLY) {
            Database.executeBatch(
                new GiftCommitmentScheduleBackfillBatch(
                    GiftCommitmentScheduleTriggerHandler.DmlPhase.SCHEDULE_ONLY
                ),
                200
            );
        }
    }
}