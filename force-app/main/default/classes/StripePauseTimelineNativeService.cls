/** Supported single-source native actions, kept inside one atomic Salesforce handoff. */
public with sharing class StripePauseTimelineNativeService {
    @TestVisible private static Integer failBeforeOperation;
    public static void pause(StripePauseTimelinePlanner.Plan plan) {
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;
        StripePauseService.suppressSubscriptionUpdate=true;
        Savepoint handoff=Database.setSavepoint();
        try {
            applyNextPause(plan,0);
            verify(plan);
            plan.applied=true;
            plan.afterFingerprint=StripePauseTimelinePlanner.fingerprint(StripePauseTimelineSelector.schedules(plan.commitmentId));
        } catch(Exception failure) {
            Database.rollback(handoff);
            throw failure;
        } finally { StripePauseService.suppressSubscriptionUpdate=previous; }
    }
    // Native action only supports one source. Bounded recursion avoids SOQL/DML in collection loops.
    private static void applyNextPause(StripePauseTimelinePlanner.Plan plan,Integer index) {
        if(index>=plan.operations.size()) return;
        if(Test.isRunningTest() && failBeforeOperation==index)
            throw new NativeException('Synthetic native failure before the next segment.');
        StripePauseTimelinePlanner.Operation operation=plan.operations[index];
        invoke('pauseGiftCommitmentSchedule',operation.sourceId,'startDate',operation.pauseFrom);
        operation.pauseId=unique(plan.commitmentId,'PauseTransactions',operation.pauseFrom).Id;
        if(operation.restoreOn!=null) {
            invoke('resumeGiftCommitmentSchedule',operation.pauseId,'resumeDate',operation.restoreOn);
            operation.restoredId=unique(plan.commitmentId,'CreateTransactions',operation.restoreOn).Id;
        }
        applyNextPause(plan,index+1);
    }
    /** Move only owned pauses to an earlier original-calendar date for Resume Now. */
    public static void resume(StripePauseTimelinePlanner.Plan plan,Date onDate) {
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;
        StripePauseService.suppressSubscriptionUpdate=true;
        Savepoint handoff=Database.setSavepoint();
        try {
            applyNextResume(plan,onDate,0);
            verify(plan);
            plan.afterFingerprint=StripePauseTimelinePlanner.fingerprint(StripePauseTimelineSelector.schedules(plan.commitmentId));
        } catch(Exception failure) {
            Database.rollback(handoff);
            throw failure;
        } finally { StripePauseService.suppressSubscriptionUpdate=previous; }
    }
    private static void applyNextResume(StripePauseTimelinePlanner.Plan plan,Date onDate,Integer index) {
        if(index>=plan.operations.size()) return;
        StripePauseTimelinePlanner.Operation operation=plan.operations[index];
        GiftCommitmentSchedule original=original(plan,operation.sourceId);
        Date target=StripePauseTimelinePlanner.paymentOnOrAfter(original,operation.calendarAnchor,onDate);
        if(target!=null && (operation.restoreOn==null || target<operation.restoreOn)) {
            operation.restoredEndDate=operation.restoreOn==null?original.EndDate:operation.restoreOn.addDays(-1);
            invoke('resumeGiftCommitmentSchedule',operation.pauseId,'resumeDate',target);
            operation.restoredId=unique(plan.commitmentId,'CreateTransactions',target).Id;
            operation.restoreOn=target;
        }
        applyNextResume(plan,onDate,index+1);
    }
    public static void verify(StripePauseTimelinePlanner.Plan plan) {
        List<GiftCommitmentSchedule> actual=StripePauseTimelineSelector.schedules(plan.commitmentId);
        List<GiftTransaction> transactions=StripePauseTimelineSelector.transactions(plan.commitmentId);
        StripePauseTimelinePlanner.validate(actual,transactions);
        Map<Id,GiftCommitmentSchedule> byId=new Map<Id,GiftCommitmentSchedule>(actual);
        Set<Id> changedSources=new Set<Id>();
        for(StripePauseTimelinePlanner.Operation operation:plan.operations) {
            changedSources.add(operation.sourceId);
            GiftCommitmentSchedule source=original(plan,operation.sourceId);
            if(operation.restoreOn!=null) {
                GiftCommitmentSchedule restored=byId.get(operation.restoredId);
                if(restored==null || restored.Type!='CreateTransactions' || restored.StartDate!=operation.restoreOn
                    || restored.EndDate!=operation.restoredEndDate || restored.TransactionAmount!=source.TransactionAmount
                    || restored.TransactionPeriod!=source.TransactionPeriod || restored.TransactionInterval!=source.TransactionInterval
                    || (source.TransactionPeriod=='Monthly' && restored.TransactionDay!=source.TransactionDay))
                    throw new NativeException('The native restoration terms did not verify. No Salesforce changes were retained.');
            }
            for(GiftTransaction transactionRecord:transactions) {
                Date pauseTo=operation.restoreOn==null?source.EndDate:operation.restoreOn.addDays(-1);
                if((transactionRecord.Status=='Unpaid' || transactionRecord.Status=='Pledged')
                    && transactionRecord.TransactionDueDate>=operation.pauseFrom
                    && (pauseTo==null || transactionRecord.TransactionDueDate<=pauseTo))
                    throw new NativeException('An unpaid installment remains inside the native pause coverage.');
            }
        }
        for(GiftCommitmentSchedule source:plan.originalSegments) {
            if(!changedSources.contains(source.Id) && !StripePauseTimelinePlanner.sameSegment(source,byId.get(source.Id)))
                throw new NativeException('An unrelated historical or future segment changed during pause.');
        }
        Map<Id,GiftTransaction> transactionsById=new Map<Id,GiftTransaction>(transactions);
        for(GiftTransaction paid:plan.protectedPayments)
            if(!StripePauseTimelinePlanner.samePaid(paid,transactionsById.get(paid.Id)))
                throw new NativeException('A protected paid installment changed during native processing.');
        Date first;
        for(GiftTransaction transactionRecord:transactions)
            if((transactionRecord.Status=='Unpaid' || transactionRecord.Status=='Pledged')
                && transactionRecord.TransactionDueDate>=StripePauseBusinessClock.today()
                && (first==null || transactionRecord.TransactionDueDate<first)) first=transactionRecord.TransactionDueDate;
        GiftCommitment gift=StripePauseTimelineSelector.commitment(plan.commitmentId);
        if(first!=plan.nextPaymentDate || gift.NextTransactionDate!=plan.nextPaymentDate)
            throw new NativeException('Salesforce next-payment dates disagree with the preserved billing calendar.');
    }
    private static GiftCommitmentSchedule original(StripePauseTimelinePlanner.Plan plan,Id sourceId) {
        for(GiftCommitmentSchedule segment:plan.originalSegments) if(segment.Id==sourceId) return segment;
        throw new NativeException('The original source snapshot is missing.');
    }
    private static GiftCommitmentSchedule unique(Id commitmentId,String type,Date startDate) {
        List<GiftCommitmentSchedule> found=[SELECT Id,Type,StartDate,EndDate FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId=:commitmentId AND Type=:type AND StartDate=:startDate WITH USER_MODE LIMIT 2];
        if(found.size()!=1) throw new NativeException('The native schedule could not be uniquely resolved.');
        return found[0];
    }
    private static void invoke(String name,Id scheduleId,String dateParameter,Date onDate) {
        Invocable.Action action=Invocable.Action.createStandardAction(name);
        action.setInvocationParameter('giftCommitmentScheduleId',String.valueOf(scheduleId));
        action.setInvocationParameter(dateParameter,onDate);
        List<Invocable.Action.Result> results=action.invoke();
        if(results.isEmpty() || !results[0].isSuccess())
            throw new NativeException('The native Salesforce schedule action failed. '+
                (results.isEmpty()?'No result was returned.':JSON.serialize(results[0].getErrors())));
    }
    public class NativeException extends Exception { }
}