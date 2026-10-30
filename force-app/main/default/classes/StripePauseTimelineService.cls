/** Coordinates a versioned multi-schedule pause without mutating Stripe prices or billing anchors. */
public with sharing class StripePauseTimelineService {
    /** Capture original terms and stop collection; defer native DML when payment was taken today. */
    public static StripePauseResult pause(GiftCommitment gift,String reason,String resumeDateStr) {
        return pause(gift,reason,resumeDateStr,null);
    }
    public static StripePauseResult pause(GiftCommitment gift,String reason,String resumeDateStr,StripePausePreview confirmation) {
        requireAccess();
        requireNoConcurrentError(gift);
        if(String.isBlank(reason)) throw problem('Select a pause reason.');
        Date resumeDate;
        try { resumeDate=Date.valueOf(resumeDateStr); }
        catch(Exception invalidDate) { throw problem('Enter a valid resume date.'); }
        if((gift.Status!='Active' && gift.Status!='Paused') || !String.isBlank(gift.Stripe_Pause_State__c))
            throw problem('This donation is not eligible for a new pause. Resolve its existing pause first.');
        List<GiftCommitmentSchedule> segments=StripePauseTimelineSelector.schedules(gift.Id);
        List<GiftTransaction> transactions=StripePauseTimelineSelector.transactions(gift.Id);
        Boolean paidToday=paidToday(transactions);
        Date startDate=paidToday?StripePauseBusinessClock.today().addDays(1):StripePauseBusinessClock.today();
        StripePauseOrchestrator.verifyConfirmation(confirmation,StripePauseBusinessClock.today(),startDate,paidToday);
        StripePauseTimelinePlanner.Plan plan=StripePauseTimelinePlanner.plan(gift.Id,startDate,resumeDate,segments,transactions);
        plan.version=2;
        plan.resumeAtEpoch=StripePauseBusinessClock.resumeEpoch(resumeDate);
        plan.compensationStatus=gift.Status;
        plan.operationKey='sapa-pause-timeline-'+EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256',
            Blob.valueOf(gift.Id+'|'+startDate+'|'+resumeDate+'|'+plan.beforeFingerprint+'|'+revision(gift))));
        validateFixed(gift,plan,null);
        assertFits(plan);
        Map<String,Object> before=StripePauseCollectionGateway.read(gift.Subscription_Id__c);
        validateFixed(gift,plan,before);
        Map<String,Object> previousPause=StripePauseCollectionGateway.collection(before);
        plan.compensationPauseJson=JSON.serialize(previousPause);
        Map<String,Object> requested=new Map<String,Object>{'behavior'=>'void',
            'resumes_at'=>resumeEpoch(plan)};
        if(previousPause!=null && !StripePauseCollectionGateway.matches(previousPause,requested))
            throw problem('Stripe already has a different pause. Reconciliation is required.');
        if(previousPause!=null) {
            Map<String,Object> metadata=before.get('metadata')==null?new Map<String,Object>():(Map<String,Object>)before.get('metadata');
            if(metadata.get('salesforce_pause_request')!=plan.operationKey+'-pause')
                throw problem('Stripe has a pause without this action\'s retry marker. Administrator reconciliation is required.');
            plan.compensationPauseJson='null';
        }
        if(previousPause==null) {
            StripePauseOrchestrator.verifyCurrentConfirmation(confirmation,gift.Id);
            try { StripePauseCollectionGateway.write(gift.Subscription_Id__c,requested,plan.operationKey+'-pause'); }
            catch(CalloutException timeout) { throw problem('Stripe did not confirm the pause. Reopen the action to re-read Stripe before retrying.'); }
        }
        Savepoint handoff;
        String originalPlan=JSON.serialize(plan);
        try {
            if(!StripePauseCollectionGateway.matches(StripePauseCollectionGateway.collection(
                StripePauseCollectionGateway.read(gift.Subscription_Id__c)),requested))
                throw new TimelineSyncException('Stripe did not verify the collection pause.');
            lockGift(gift);
            recheck(plan,false);
            handoff=Database.setSavepoint();
            if(!paidToday) StripePauseTimelineNativeService.pause(plan);
            return finishPause(gift,plan,reason);
        } catch(Exception failure) {
            if(handoff!=null) Database.rollback(handoff);
            if(failure instanceof ConcurrentActionException) return concurrentResult(gift,plan,false);
            return failed(gift,decode(originalPlan),reason,failure,false);
        }
    }
    /** Resume collection now while retaining the next original-calendar payment. */
    public static StripePauseResult resume(GiftCommitment gift) {
        return resume(gift,false);
    }
    private static StripePauseResult resume(GiftCommitment gift,Boolean automatic) {
        requireAccess();
        requireNoConcurrentError(gift);
        StripePauseTimelinePlanner.Plan plan=storedPlan(gift);
        if(gift.Stripe_Pause_State__c=='Resume Scheduled') {
            recheck(plan,plan.applied);
            if(StripePauseCollectionGateway.collection(StripePauseCollectionGateway.read(gift.Subscription_Id__c))!=null)
                throw problem('Stripe collection is no longer resumed. Administrator reconciliation is required.');
            lockGift(gift);
            GiftCommitmentSchedule current=StripePauseTimelinePlanner.current(StripePauseTimelineSelector.schedules(gift.Id),StripePauseBusinessClock.today());
            if(current!=null && current.Type=='CreateTransactions') return finishResume(gift,plan);
            return result(true,'Resume Scheduled',plan,'Stripe collection resumed; Salesforce resumption scheduled for '+plan.nextPaymentDate+'.',null);
        }
        if(gift.Stripe_Pause_State__c!='Scheduled' && gift.Stripe_Pause_State__c!='Active')
            throw problem('There is no synchronized Stripe pause to resume.');
        recheck(plan,plan.applied);
        Map<String,Object> before=StripePauseCollectionGateway.read(gift.Subscription_Id__c);
        Map<String,Object> previousPause=StripePauseCollectionGateway.collection(before);
        plan.compensationPauseJson=JSON.serialize(previousPause);
        if(plan.version==2) plan.compensationStatus=gift.Status;
        if(previousPause!=null && !StripePauseCollectionGateway.matches(previousPause,
            new Map<String,Object>{'behavior'=>'void','resumes_at'=>resumeEpoch(plan)}))
            throw problem('Stripe pause state changed. Reconciliation is required before resume.');
        if(previousPause!=null)
            StripePauseCollectionGateway.write(gift.Subscription_Id__c,null,plan.operationKey+'-resume');
        Savepoint handoff;
        String originalPlan=JSON.serialize(plan);
        try {
            if(StripePauseCollectionGateway.collection(StripePauseCollectionGateway.read(gift.Subscription_Id__c))!=null)
                throw new TimelineSyncException('Stripe did not verify resumed collection.');
            lockGift(gift);
            recheck(plan,plan.applied);
            handoff=Database.setSavepoint();
            if(!plan.applied) {
                plan.resuming=true;
                plan.nextPaymentDate=nextOriginalPayment(plan,StripePauseBusinessClock.today().addDays(1));
                return finishResume(gift,plan);
            }
            // A manual resume cannot resurrect an invoice voided earlier today. Automatic resumption
            // retains its preplanned boundary, where Stripe enables collection before billing begins.
            Date resumeOn=automatic && !paidToday(StripePauseTimelineSelector.transactions(gift.Id))?StripePauseBusinessClock.today():StripePauseBusinessClock.today().addDays(1);
            plan.nextPaymentDate=nextOriginalPayment(plan,resumeOn);
            if(plan.nextPaymentDate==null) throw new TimelineSyncException('No valid original-calendar payment remains.');
            plan.resuming=true;
            StripePauseTimelineNativeService.resume(plan,resumeOn);
            return finishResume(gift,plan);
        } catch(Exception failure) {
            if(handoff!=null) Database.rollback(handoff);
            if(failure instanceof ConcurrentActionException) return concurrentResult(gift,plan,true);
            return failed(gift,decode(originalPlan),gift.Pause_Reason__c,failure,true);
        }
    }
    /** Worker entry point shared with manual routing; no custom transaction generation. */
    public static void processDue(GiftCommitment gift) {
        if(hasConcurrentError(gift)) return; // Preserve the newer winner until audited reconciliation.
        StripePauseTimelinePlanner.Plan plan=storedPlan(gift);
        if(gift.Stripe_Pause_State__c=='Resume Scheduled') {
            if(plan.nextPaymentDate<=StripePauseBusinessClock.today()) {
                try {
                    recheck(plan,plan.applied);
                    if(StripePauseCollectionGateway.collection(StripePauseCollectionGateway.read(gift.Subscription_Id__c))!=null)
                        throw new TimelineSyncException('Stripe collection unexpectedly paused before scheduled resumption.');
                    lockGift(gift);
                    finishResume(gift,plan);
                } catch(Exception failure) {
                    if(failure instanceof ConcurrentActionException) concurrentResult(gift,plan,true);
                    else {
                        try {
                            lockGift(gift);
                            save(gift,'Sync Error',plan.pauseStartDate,plan.resumeDate,null,plan,failure.getMessage());
                        } catch(ConcurrentActionException newerAction) { concurrentResult(gift,plan,true); }
                    }
                }
            }
            return;
        }
        if(gift.Stripe_Pause_State__c=='Active' && gift.Pause_Resume_Date__c<=StripePauseBusinessClock.today()) {
            resume(gift,true);
            return;
        }
        if(gift.Stripe_Pause_State__c!='Scheduled' || plan.pauseStartDate>StripePauseBusinessClock.today()) return;
        Savepoint handoff;
        String originalPlan=JSON.serialize(plan);
        try {
            recheck(plan,plan.applied);
            Map<String,Object> stripe=StripePauseCollectionGateway.read(gift.Subscription_Id__c);
            validateFixed(gift,plan,stripe);
            if(!StripePauseCollectionGateway.matches(StripePauseCollectionGateway.collection(stripe),
                new Map<String,Object>{'behavior'=>'void','resumes_at'=>resumeEpoch(plan)}))
                throw new TimelineSyncException('Stripe is not paused as expected.');
            lockGift(gift);
            recheck(plan,plan.applied);
            handoff=Database.setSavepoint();
            if(!plan.applied) StripePauseTimelineNativeService.pause(plan);
            finishPause(gift,plan,gift.Pause_Reason__c);
        } catch(Exception failure) {
            if(handoff!=null) Database.rollback(handoff);
            if(failure instanceof ConcurrentActionException) { concurrentResult(gift,plan,false); return; }
            failed(gift,decode(originalPlan),gift.Pause_Reason__c,failure,false);
        }
    }
    /** Restore the exact collection state captured before the failed cross-system action. */
    public static void compensate(GiftCommitment gift) {
        if(hasConcurrentError(gift) || gift.Stripe_Pause_State__c!='Sync Error') return;
        StripePauseTimelinePlanner.Plan plan=storedPlan(gift);
        if(gift.Status=='Closed' || (plan.version==2 && gift.Status!=plan.compensationStatus)) {
            concurrentResult(gift,plan,plan.resuming);
            return;
        }
        try {
            Map<String,Object> current=StripePauseCollectionGateway.collection(StripePauseCollectionGateway.read(gift.Subscription_Id__c));
            Map<String,Object> previousPause=(Map<String,Object>)JSON.deserializeUntyped(plan.compensationPauseJson);
            Map<String,Object> failedState=plan.resuming?null:new Map<String,Object>{'behavior'=>'void',
                'resumes_at'=>resumeEpoch(plan)};
            if(!StripePauseCollectionGateway.matches(current,previousPause) && !StripePauseCollectionGateway.matches(current,failedState))
                throw new TimelineSyncException('Stripe pause was changed externally. Compensation cannot overwrite it.');
            if(!StripePauseCollectionGateway.matches(current,previousPause)) {
                lockGift(gift);
                StripePauseCollectionGateway.write(gift.Subscription_Id__c,previousPause,plan.operationKey+'-compensate-'+String.valueOf(plan.resuming));
            }
            if(!StripePauseCollectionGateway.matches(StripePauseCollectionGateway.collection(
                StripePauseCollectionGateway.read(gift.Subscription_Id__c)),previousPause))
                throw new TimelineSyncException('Compensation could not be verified.');
            lockGift(gift);
            save(gift,'Failed',plan.pauseStartDate,plan.resumeDate,plan.version==2?plan.compensationStatus:null,plan,'Stripe state restored. Review the failed native action before retrying.');
        } catch(Exception failure) {
            if(failure instanceof ConcurrentActionException) concurrentResult(gift,plan,plan.resuming);
            else {
                try {
                    lockGift(gift);
                    save(gift,'Sync Error',plan.pauseStartDate,plan.resumeDate,null,plan,'Compensation failed. Administrator reconciliation is required.');
                } catch(ConcurrentActionException newerAction) { concurrentResult(gift,plan,plan.resuming); }
            }
        }
    }
    private static StripePauseResult finishPause(GiftCommitment gift,StripePauseTimelinePlanner.Plan plan,String reason) {
        GiftCommitmentSchedule current=StripePauseTimelinePlanner.current(StripePauseTimelineSelector.schedules(gift.Id),StripePauseBusinessClock.today());
        Boolean active=plan.applied && current!=null && current.Type=='PauseTransactions';
        save(gift,active?'Active':'Scheduled',plan.pauseStartDate,plan.resumeDate,active?'Paused':null,plan,null,reason);
        return result(true,active?'Paused':'Scheduled',plan,active
            ?'Stripe collection and the Salesforce pause timeline are verified.'
            :'Stripe billing stopped; Salesforce pause scheduled for '+plan.pauseStartDate+' (America/Los_Angeles). Today\'s already paid donation is unchanged.',null);
    }
    private static StripePauseResult finishResume(GiftCommitment gift,StripePauseTimelinePlanner.Plan plan) {
        GiftCommitmentSchedule current=StripePauseTimelinePlanner.current(StripePauseTimelineSelector.schedules(gift.Id),StripePauseBusinessClock.today());
        Boolean active=current!=null && current.Type=='CreateTransactions';
        if(active) plan.nextPaymentDate=StripePauseTimelineSelector.commitment(gift.Id).NextTransactionDate;
        save(gift,active?null:'Resume Scheduled',active?null:plan.pauseStartDate,active?null:plan.resumeDate,
            active?'Active':null,plan,null);
        return result(true,active?'Active':'Resume Scheduled',plan,active
            ?'Stripe collection and the native Salesforce billing segment are active.'
            :'Stripe collection resumed; Salesforce resumption scheduled for '+plan.nextPaymentDate+'. No catch-up payment will be collected.',null);
    }
    private static StripePauseResult failed(GiftCommitment gift,StripePauseTimelinePlanner.Plan plan,String reason,Exception failure,Boolean resuming) {
        try { lockGift(gift); }
        catch(ConcurrentActionException newerAction) { return concurrentResult(gift,plan,resuming); }
        plan.resuming=resuming;
        save(gift,'Sync Error',plan.pauseStartDate,plan.resumeDate,null,plan,failure.getMessage(),reason);
        System.enqueueJob(new StripePauseCompensationQueueable(gift.Id,resuming,revision(gift)+1));
        return result(false,'Reconciliation Required',plan,'Stripe and Salesforce could not be verified together. Compensation is queued. '+failure.getMessage(),'PAUSE_SYNC_ERROR');
    }
    private static void recheck(StripePauseTimelinePlanner.Plan plan,Boolean applied) {
        List<GiftCommitmentSchedule> current=StripePauseTimelineSelector.schedules(plan.commitmentId);
        String expected=applied?plan.afterFingerprint:plan.beforeFingerprint;
        if(StripePauseTimelinePlanner.fingerprint(current)!=expected)
            throw new TimelineSyncException('The donation timeline changed. Restart the action; no newer plan will be overwritten.');
        if(!applied) StripePauseTimelinePlanner.plan(plan.commitmentId,plan.pauseStartDate,plan.resumeDate,
            current,StripePauseTimelineSelector.transactions(plan.commitmentId));
        else {
            Map<Id,GiftTransaction> currentPayments=new Map<Id,GiftTransaction>(StripePauseTimelineSelector.transactions(plan.commitmentId));
            for(GiftTransaction paid:plan.protectedPayments)
                if(!StripePauseTimelinePlanner.samePaid(paid,currentPayments.get(paid.Id)))
                    throw new TimelineSyncException('A protected paid installment changed. Administrator review is required.');
            for(GiftTransaction payment:currentPayments.values()) {
                Date paidOn=payment.TransactionDate??payment.TransactionDueDate;
                Boolean protectedRange=paidOn!=null && paidOn>=plan.pauseStartDate && paidOn<plan.resumeDate;
                if(plan.resuming) {
                    protectedRange=false;
                    // A shortened pause must not label a legitimate restored payment as a conflict.
                    for(StripePauseTimelinePlanner.Operation operation:plan.operations) {
                        if(paidOn!=null && paidOn>=operation.pauseFrom && (operation.restoreOn==null || paidOn<operation.restoreOn)) {
                            GiftCommitmentSchedule original;
                            for(GiftCommitmentSchedule segment:plan.originalSegments)
                                if(segment.Id==operation.sourceId) original=segment;
                            if(original!=null && (original.EndDate==null || paidOn<=original.EndDate)) protectedRange=true;
                        }
                    }
                }
                if(payment.Status=='Paid' && protectedRange)
                    throw new TimelineSyncException('A paid transaction now falls in the pause period. Administrator review is required.');
            }
        }
    }
    /** Serialize same-donation handoffs after callouts and reject a newer operator action. */
    private static void lockGift(GiftCommitment expected) {
        GiftCommitment locked=[SELECT Id,Status,Subscription_Id__c,Stripe_Pause_State__c,Stripe_Pause_Attempt_Count__c,Stripe_Pause_Last_Error__c
            FROM GiftCommitment WHERE Id=:expected.Id FOR UPDATE];
        if(hasConcurrentError(locked) || locked.Status!=expected.Status || locked.Subscription_Id__c!=expected.Subscription_Id__c || locked.Stripe_Pause_State__c!=expected.Stripe_Pause_State__c
            || revision(locked)!=revision(expected))
            throw new ConcurrentActionException('A newer pause action was saved. No newer action will be overwritten.');
    }
    /** Never compensate a stale request over a newer winner. Identical duplicates converge read-only. */
    private static StripePauseResult concurrentResult(GiftCommitment expected,StripePauseTimelinePlanner.Plan attempted,Boolean resuming) {
        GiftCommitment winner=StripePauseTimelineSelector.commitment(expected.Id);
        if(winner.Subscription_Id__c==expected.Subscription_Id__c && !String.isBlank(winner.Stripe_Pause_Plan__c)) {
            StripePauseTimelinePlanner.Plan saved=storedPlan(winner);
            Boolean verifiedState=resuming?(winner.Stripe_Pause_State__c==null || winner.Stripe_Pause_State__c=='Resume Scheduled')
                :(winner.Stripe_Pause_State__c=='Scheduled' || winner.Stripe_Pause_State__c=='Active');
            if(saved.operationKey==attempted.operationKey && saved.resuming==resuming && verifiedState && !hasConcurrentError(winner)) {
                recheck(saved,saved.applied);
                String state=resuming?(winner.Stripe_Pause_State__c==null?'Active':'Resume Scheduled')
                    :(winner.Stripe_Pause_State__c=='Active'?'Paused':'Scheduled');
                return result(true,state,saved,'This identical action was already verified. No duplicate processing was performed.',null);
            }
        }
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;
        StripePauseService.suppressSubscriptionUpdate=true;
        try {
            update as user new GiftCommitment(Id=expected.Id,Stripe_Pause_Last_Error__c=
                'CONCURRENT_ACTION: A newer action was preserved. Stripe collection requires administrator reconciliation; no automatic compensation was run.');
        } finally { StripePauseService.suppressSubscriptionUpdate=previous; }
        return result(false,'Reconciliation Required',attempted,
            'A newer pause action was preserved. Administrator reconciliation is required before further pause/resume processing.','CONCURRENT_ACTION');
    }
    private static Boolean hasConcurrentError(GiftCommitment gift) {
        return gift.Stripe_Pause_Last_Error__c!=null && gift.Stripe_Pause_Last_Error__c.startsWith('CONCURRENT_ACTION:');
    }
    private static void requireNoConcurrentError(GiftCommitment gift) {
        if(hasConcurrentError(gift)) throw problem('Concurrent pause actions require administrator reconciliation before another action.');
    }
    private static Date nextOriginalPayment(StripePauseTimelinePlanner.Plan plan,Date onDate) {
        Date earliest;
        for(GiftCommitmentSchedule segment:plan.originalSegments) {
            if(segment.Type!='CreateTransactions') continue;
            Date anchor=segment.StartDate;
            for(StripePauseTimelinePlanner.Operation operation:plan.operations)
                if(operation.sourceId==segment.Id) anchor=operation.calendarAnchor;
            Date next=StripePauseTimelinePlanner.paymentOnOrAfter(segment,anchor,onDate);
            if(next!=null && (earliest==null || next<earliest)) earliest=next;
        }
        return earliest;
    }
    private static void validateFixed(GiftCommitment gift,StripePauseTimelinePlanner.Plan plan,Map<String,Object> stripe) {
        if(gift.Recurring_Type__c!='Fixed') return;
        Date finalDate;
        for(GiftCommitmentSchedule segment:plan.originalSegments)
            if(segment.Type=='CreateTransactions' && (segment.EndDate==null || segment.EndDate>=plan.pauseStartDate)) {
                if(segment.EndDate==null || segment.Final_Payment_Date__c==null)
                    throw problem('The Fixed donation has no verified final installment. Reconcile it before pausing.');
                if(finalDate==null || segment.Final_Payment_Date__c>finalDate) finalDate=segment.Final_Payment_Date__c;
            }
        if(finalDate==null || plan.resumeDate>finalDate || plan.nextPaymentDate>finalDate)
            throw problem('Resume date cannot be after the Fixed donation\'s final installment.');
        if(stripe!=null && plan.resumeDate==finalDate) {
            Object anchor=stripe.get('billing_cycle_anchor');
            if(anchor==null) throw problem('The final installment billing time cannot be verified. Select an earlier resume date.');
            Time billingTime=DateTime.newInstance(Long.valueOf(String.valueOf(anchor))*1000).timeGmt();
            Long finalEpoch=DateTime.newInstanceGmt(finalDate,billingTime).getTime()/1000;
            if(resumeEpoch(plan)>=finalEpoch)
                throw problem('Resume must occur before the final installment billing time. Select an earlier resume date.');
        }
        if(stripe!=null && stripe.get('cancel_at')!=null
            && resumeEpoch(plan)>=Long.valueOf(String.valueOf(stripe.get('cancel_at'))))
            throw problem('Stripe will cancel before the donation can resume. Select an earlier resume date.');
        if(stripe!=null && stripe.get('cancel_at_period_end')==true && stripe.get('current_period_end')!=null
            && resumeEpoch(plan)>=Long.valueOf(String.valueOf(stripe.get('current_period_end'))))
            throw problem('Stripe will cancel before the donation can resume. Select an earlier resume date.');
    }
    private static StripePauseTimelinePlanner.Plan decode(String payload) {
        StripePauseTimelinePlanner.Plan plan;
        try { plan=(StripePauseTimelinePlanner.Plan)JSON.deserialize(payload,StripePauseTimelinePlanner.Plan.class); }
        catch(JSONException invalidSnapshot) { throw problem('The pause snapshot is invalid. Administrator reconciliation is required.'); }
        if(plan==null || (plan.version!=1 && plan.version!=2) || (plan.version==2 && (plan.resumeAtEpoch==null || plan.compensationStatus==null)) || plan.commitmentId==null || plan.originalSegments==null || plan.operations==null || plan.protectedPayments==null)
            throw problem('The pause snapshot is invalid. Administrator reconciliation is required.');
        return plan;
    }
    /** Reject altered snapshot fields even when the operator has field-level edit access. */
    private static StripePauseTimelinePlanner.Plan storedPlan(GiftCommitment gift) {
        StripePauseTimelinePlanner.Plan plan=decode(gift.Stripe_Pause_Plan__c);
        if(plan.commitmentId!=gift.Id || plan.snapshotSignature!=signature(plan))
            throw problem('The pause snapshot changed outside the action. Administrator reconciliation is required.');
        return plan;
    }
    @TestVisible private static String signature(StripePauseTimelinePlanner.Plan plan) {
        List<String> values=new List<String>{String.valueOf(plan.version),String.valueOf(plan.commitmentId),
            plan.operationKey,String.valueOf(plan.pauseStartDate),String.valueOf(plan.resumeDate),String.valueOf(plan.nextPaymentDate),
            plan.beforeFingerprint,plan.afterFingerprint,String.valueOf(plan.applied),String.valueOf(plan.resuming),plan.compensationPauseJson};
        if(plan.version==2) values.addAll(new List<String>{String.valueOf(plan.resumeAtEpoch),plan.compensationStatus});
        for(GiftCommitmentSchedule segment:plan.originalSegments) values.add(JSON.serialize(new List<String>{
            String.valueOf(segment.Id),String.valueOf(segment.GiftCommitmentId),segment.Type,String.valueOf(segment.StartDate),
            String.valueOf(segment.EndDate),String.valueOf(segment.TransactionAmount==null?null:segment.TransactionAmount.setScale(2)),
            segment.TransactionPeriod,String.valueOf(segment.TransactionInterval),segment.TransactionDay,segment.PaymentMethod,
            String.valueOf(segment.Final_Payment_Date__c)}));
        for(GiftTransaction paid:plan.protectedPayments) values.add(JSON.serialize(new List<String>{
            String.valueOf(paid.Id),String.valueOf(paid.GiftCommitmentScheduleId),paid.Status,
            String.valueOf(paid.OriginalAmount==null?null:paid.OriginalAmount.setScale(2)),
            String.valueOf(paid.TransactionDate),String.valueOf(paid.TransactionDueDate)}));
        for(StripePauseTimelinePlanner.Operation operation:plan.operations) values.add(JSON.serialize(new List<String>{
            String.valueOf(operation.sourceId),String.valueOf(operation.pauseId),String.valueOf(operation.restoredId),
            String.valueOf(operation.pauseFrom),String.valueOf(operation.restoreOn),String.valueOf(operation.calendarAnchor),
            String.valueOf(operation.restoredEndDate)}));
        return EncodingUtil.convertToHex(Crypto.generateMac('HmacSHA256',Blob.valueOf(JSON.serialize(values)),Blob.valueOf(System.Label.Stripe_Secret)));
    }
    private static Long resumeEpoch(StripePauseTimelinePlanner.Plan plan) {
        return plan.version==2?plan.resumeAtEpoch:StripePauseCollectionGateway.resumeEpoch(plan.resumeDate);
    }
    private static Boolean paidToday(List<GiftTransaction> transactions) {
        for(GiftTransaction transactionRecord:transactions)
            if(transactionRecord.Status=='Paid' && (transactionRecord.TransactionDate??transactionRecord.TransactionDueDate)==StripePauseBusinessClock.today()) return true;
        return false;
    }
    private static Integer revision(GiftCommitment gift) { return gift.Stripe_Pause_Attempt_Count__c==null?0:Integer.valueOf(gift.Stripe_Pause_Attempt_Count__c); }
    private static void assertFits(StripePauseTimelinePlanner.Plan plan) {
        if(JSON.serialize(plan).length()>30000) throw problem('The pause snapshot exceeds the safe size limit. Administrator review is required.');
    }
    private static void requireAccess() {
        if(!GiftCommitment.SObjectType.getDescribe().isUpdateable() || !GiftCommitment.Stripe_Pause_Plan__c.getDescribe().isUpdateable())
            throw problem('You do not have permission to manage the Stripe pause timeline.');
        for(Schema.SObjectField field:new List<Schema.SObjectField>{GiftCommitment.Stripe_Pause_State__c,
            GiftCommitment.Pause_Start_Date__c,GiftCommitment.Pause_Resume_Date__c,GiftCommitment.Pause_Reason__c,
            GiftCommitment.Stripe_Pause_Attempt_Count__c,GiftCommitment.Stripe_Pause_Last_Error__c,GiftCommitment.Status})
            if(!field.getDescribe().isUpdateable()) throw problem('Required pause-state field access is missing.');
    }
    private static void save(GiftCommitment gift,String state,Date start,Date resume,String status,
        StripePauseTimelinePlanner.Plan plan,String error) { save(gift,state,start,resume,status,plan,error,gift.Pause_Reason__c); }
    private static void save(GiftCommitment gift,String state,Date start,Date resume,String status,
        StripePauseTimelinePlanner.Plan plan,String error,String reason) {
        plan.snapshotSignature=signature(plan);
        assertFits(plan);
        GiftCommitment change=new GiftCommitment(Id=gift.Id,Stripe_Pause_State__c=state,
            Pause_Start_Date__c=start,Pause_Resume_Date__c=resume,Pause_Reason__c=state==null?null:reason,
            Stripe_Pause_Plan__c=JSON.serialize(plan),Stripe_Pause_Attempt_Count__c=revision(gift)+1,
            Stripe_Pause_Last_Error__c=error==null?null:error.left(255));
        if(status!=null) change.Status=status;
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;
        StripePauseService.suppressSubscriptionUpdate=true;
        try { update as user change; }
        finally { StripePauseService.suppressSubscriptionUpdate=previous; }
        StripePauseOrchestrator.logPauseFailure(gift.Id,state,error,'StripePauseTimelineService.save');
    }
    private static StripePauseResult result(Boolean confirmed,String state,StripePauseTimelinePlanner.Plan plan,String message,String errorCode) {
        StripePauseResult value=new StripePauseResult(confirmed,state,plan.resumeDate,message);
        value.pauseStartDate=plan.pauseStartDate;
        value.nextPaymentDate=plan.nextPaymentDate;
        value.errorCode=errorCode;
        return value;
    }
    private static AuraHandledException problem(String message) {
        AuraHandledException error=new AuraHandledException(message);error.setMessage(message);return error;
    }
    public class TimelineSyncException extends Exception { }
    public class ConcurrentActionException extends Exception { }
}