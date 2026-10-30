/**
 * Keeps a recurring donation (GiftCommitment) consistent after its schedule amount is amended:
 * re-splits the amended amount across the RD's default designations (Amount__c).
 *
 * What NPC already does, so this class does not:
 *  - CurrentGiftCmtScheduleId is maintained by NPC as the schedule active today. NPC resets it
 *    during the amendment and on every processing run, and switches to the amended schedule on
 *    its effective date.
 *  - NPC generates new unpaid donations from the amended schedule and keeps every donation
 *    designation at Percent x donation amount, so paid donations keep their amounts and new
 *    unpaid ones carry the amended split.
 *
 * Runs with sharing: an amendment only syncs RDs the running user can see. Only the designation
 * amount update is elevated (see ElevatedDml).
 */
public with sharing class RecurringDonationAmendmentService {

    private static final String CREATE_TRANSACTIONS = 'CreateTransactions';

    // Ids already synced in this transaction, so re-entry from downstream automation or later
    // trigger chunks never processes the same schedule twice.
    private static final Set<Id> processedScheduleIds = new Set<Id>();

    // Lets tests switch the feature without depending on the org's Apex_Triggers__mdt record.
    @TestVisible
    private static Boolean enabledOverride;

    @TestVisible
    private static Boolean failDesignationSave = false;

    public static void handle(List<GiftCommitmentSchedule> schedules, Map<Id, GiftCommitmentSchedule> oldMap) {
        if (!isEnabled() || schedules == null || schedules.isEmpty()) return;

        Map<Id, GiftCommitmentSchedule> candidateByCommitment = collectCandidates(schedules, oldMap);
        if (candidateByCommitment.isEmpty()) return;

        Map<Id, GiftCommitment> commitments = new Map<Id, GiftCommitment>([
            SELECT Id, CurrentGiftCmtScheduleId, CurrentGiftCmtSchedule.TransactionAmount,
                   (SELECT Id, TransactionAmount, StartDate
                    FROM GiftCommitmentSchedules
                    WHERE Type = :CREATE_TRANSACTIONS
                    ORDER BY StartDate DESC, CreatedDate DESC)
            FROM GiftCommitment
            WHERE Id IN :candidateByCommitment.keySet()
        ]);

        // The amended amount is taken from the database, not from the caller's records.
        Map<Id, Decimal> amendedAmountByCommitment = new Map<Id, Decimal>();
        List<GiftCommitmentSchedule> amendedSchedules = new List<GiftCommitmentSchedule>();
        for (GiftCommitmentSchedule schedule : candidateByCommitment.values()) {
            GiftCommitment commitment = commitments.get(schedule.GiftCommitmentId);
            if (commitment != null && isAmendment(schedule, commitment, oldMap == null)) {
                amendedAmountByCommitment.put(commitment.Id, commitment.GiftCommitmentSchedules[0].TransactionAmount);
                amendedSchedules.add(schedule);
                processedScheduleIds.add(schedule.Id);
            }
        }
        if (amendedAmountByCommitment.isEmpty()) return;

        try {
            updateDefaultDesignations(amendedAmountByCommitment);
        } catch (DmlException saveError) {
            // Block the amendment with a clear message rather than leave designations out of step.
            for (GiftCommitmentSchedule schedule : amendedSchedules) {
                schedule.addError('The amendment could not update the recurring donation default designation amounts: '
                    + saveError.getDmlMessage(0));
            }
        }
    }

    // One candidate per RD: CreateTransactions schedules whose amount is new (insert) or changed (update).
    private static Map<Id, GiftCommitmentSchedule> collectCandidates(
        List<GiftCommitmentSchedule> schedules,
        Map<Id, GiftCommitmentSchedule> oldMap
    ) {
        Map<Id, GiftCommitmentSchedule> candidateByCommitment = new Map<Id, GiftCommitmentSchedule>();
        for (GiftCommitmentSchedule schedule : schedules) {
            if (schedule.GiftCommitmentId == null
                || schedule.Type != CREATE_TRANSACTIONS
                || schedule.TransactionAmount == null
                || processedScheduleIds.contains(schedule.Id)) {
                continue;
            }
            if (oldMap != null && schedule.TransactionAmount == oldMap.get(schedule.Id).TransactionAmount) {
                continue;
            }
            GiftCommitmentSchedule existing = candidateByCommitment.get(schedule.GiftCommitmentId);
            if (existing == null || startsLater(schedule, existing)) {
                candidateByCommitment.put(schedule.GiftCommitmentId, schedule);
            }
        }
        return candidateByCommitment;
    }

    private static Boolean startsLater(GiftCommitmentSchedule a, GiftCommitmentSchedule b) {
        return b.StartDate == null || (a.StartDate != null && a.StartDate > b.StartDate);
    }

    private static Boolean isAmendment(GiftCommitmentSchedule schedule, GiftCommitment commitment, Boolean isInsert) {
        // Only the RD's latest CreateTransactions schedule drives its amounts.
        List<GiftCommitmentSchedule> siblings = commitment.GiftCommitmentSchedules;
        if (siblings.isEmpty() || siblings[0].Id != schedule.Id) return false;

        // Update path: the amount already changed in place on the latest schedule.
        if (!isInsert) return true;

        // Insert path: compare with the schedule it replaces; a brand-new RD has none.
        Decimal previousAmount;
        if (commitment.CurrentGiftCmtScheduleId != null && commitment.CurrentGiftCmtScheduleId != schedule.Id) {
            previousAmount = commitment.CurrentGiftCmtSchedule.TransactionAmount;
        } else if (siblings.size() > 1) {
            previousAmount = siblings[1].TransactionAmount;
        }
        return previousAmount != null && previousAmount != siblings[0].TransactionAmount;
    }

    private static void updateDefaultDesignations(Map<Id, Decimal> amendedAmountByCommitment) {
        Map<Id, List<GiftDefaultDesignation>> designationsByCommitment = new Map<Id, List<GiftDefaultDesignation>>();
        for (GiftDefaultDesignation designation : [
            SELECT Id, ParentRecordId, AllocatedPercentage, Amount__c
            FROM GiftDefaultDesignation
            WHERE ParentRecordId IN :amendedAmountByCommitment.keySet()
              AND AllocatedPercentage != null
            ORDER BY CreatedDate, Id
        ]) {
            if (!designationsByCommitment.containsKey(designation.ParentRecordId)) {
                designationsByCommitment.put(designation.ParentRecordId, new List<GiftDefaultDesignation>());
            }
            designationsByCommitment.get(designation.ParentRecordId).add(designation);
        }

        List<GiftDefaultDesignation> updates = new List<GiftDefaultDesignation>();
        for (Id commitmentId : designationsByCommitment.keySet()) {
            List<GiftDefaultDesignation> designations = designationsByCommitment.get(commitmentId);
            List<Decimal> percents = new List<Decimal>();
            for (GiftDefaultDesignation designation : designations) {
                percents.add(designation.AllocatedPercentage);
            }
            List<Decimal> amounts = split(percents, amendedAmountByCommitment.get(commitmentId));
            for (Integer i = 0; i < designations.size(); i++) {
                if (designations[i].Amount__c != amounts[i]) {
                    updates.add(new GiftDefaultDesignation(Id = designations[i].Id, Amount__c = amounts[i]));
                }
            }
        }
        if (!updates.isEmpty()) {
            new ElevatedDml().updateAmounts(updates);
        }
    }

    // Splits total by percent, rounded to cents. When the percents make up 100, the rounding
    // remainder goes to the largest allocation so the split adds up exactly to the total.
    @TestVisible
    private static List<Decimal> split(List<Decimal> percents, Decimal total) {
        List<Decimal> amounts = new List<Decimal>();
        Decimal allocated = 0;
        Decimal percentTotal = 0;
        Integer largest = 0;
        for (Integer i = 0; i < percents.size(); i++) {
            Decimal amount = (total * percents[i] / 100).setScale(2, RoundingMode.HALF_UP);
            amounts.add(amount);
            allocated += amount;
            percentTotal += percents[i];
            if (percents[i] > percents[largest]) largest = i;
        }
        if (!amounts.isEmpty() && percentTotal == 100) {
            amounts[largest] += total.setScale(2, RoundingMode.HALF_UP) - allocated;
        }
        return amounts;
    }

    private static Boolean isEnabled() {
        if (enabledOverride != null) return enabledOverride;
        Apex_Triggers__mdt settings = Apex_Triggers__mdt.getInstance('Apex_Trigger');
        return settings != null && settings.RD_Amendment_Sync__c;
    }

    // GiftDefaultDesignation is Public Read Only, so the user amending an RD usually cannot edit
    // its designations, and SYSTEM_MODE alone still honours the class's sharing. Only this
    // write of the derived Amount__c runs without sharing; which designations it touches, and
    // the amounts, are decided by the with-sharing code above from database values.
    private without sharing class ElevatedDml {
        void updateAmounts(List<GiftDefaultDesignation> designations) {
            // Test seam: an update without an Id fails like a real save error would.
            if (failDesignationSave) designations = new List<GiftDefaultDesignation>{ new GiftDefaultDesignation() };
            Database.update(designations, true, AccessLevel.SYSTEM_MODE);
        }
    }
}