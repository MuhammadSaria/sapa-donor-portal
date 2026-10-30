/** Coordinates Stripe pause_collection with native Nonprofit Cloud pause schedules. */
public with sharing class StripePauseOrchestrator {
    private static final String API = 'https://api.stripe.com/v1/subscriptions/';
    @TestVisible private static Boolean forceNativeFailure = false;
    @TestVisible private static Boolean forceDueForTest = false;

    @AuraEnabled
    public static StripePausePreview previewPause(String subscriptionId, Id commitmentId) {
        GiftCommitment commitment = readCommitment(commitmentId);
        requireSubscription(commitment, subscriptionId);
        requireWritableResumeInstant();
        requireNoConcurrentError(commitment);
        if ((commitment.Status != 'Active' && commitment.Status != 'Paused') ||
            !String.isBlank(commitment.Stripe_Pause_State__c))
            throw problem('Resolve the existing pause before scheduling a new one.');
        StripePausePreview preview = new StripePausePreview();
        preview.businessDate = StripePauseBusinessClock.today();
        preview.paidToday = hasPaidTransaction(commitment.Id, preview.businessDate, preview.businessDate.addDays(1));
        preview.pauseStartDate = preview.paidToday ? preview.businessDate.addDays(1) : preview.businessDate;
        preview.timeZone = StripePauseBusinessClock.TIME_ZONE;
        return preview;
    }

    @AuraEnabled
    public static StripePauseResult pause(String subscriptionId, Id commitmentId, String reason, String resumeDateStr) {
        return pause(subscriptionId,commitmentId,reason,resumeDateStr,null);
    }
    /** Bind the operator's confirmation to the authoritative date and paid state. Legacy callers keep pause(). */
    @AuraEnabled
    public static StripePauseResult pauseConfirmed(String subscriptionId, Id commitmentId, String reason, String resumeDateStr,
        String confirmedBusinessDateStr, String confirmedPauseStartDateStr, Boolean confirmedPaidToday) {
        StripePausePreview confirmation=new StripePausePreview();
        try {
            confirmation.businessDate=Date.valueOf(confirmedBusinessDateStr);
            confirmation.pauseStartDate=Date.valueOf(confirmedPauseStartDateStr);
        } catch(Exception invalidConfirmation) { throw problem('Pause confirmation is missing or invalid. Review the pause dates again.'); }
        confirmation.paidToday=confirmedPaidToday;
        if(confirmedPaidToday==null) throw problem('Pause confirmation is missing or invalid. Review the pause dates again.');
        return pause(subscriptionId,commitmentId,reason,resumeDateStr,confirmation);
    }
    private static StripePauseResult pause(String subscriptionId, Id commitmentId, String reason, String resumeDateStr, StripePausePreview confirmation) {
        GiftCommitment commitment = readCommitment(commitmentId);
        requireSubscription(commitment, subscriptionId);
        requireWritableResumeInstant();
        requireNoConcurrentError(commitment);
        if (StripePauseTimelineSelector.schedules(commitment.Id).size() > 1) {
            return StripePauseTimelineService.pause(commitment, reason, resumeDateStr,confirmation);
        }
        if (String.isBlank(reason)) throw problem('Select a pause reason.');
        Date resumeDate;
        try { resumeDate = Date.valueOf(resumeDateStr); }
        catch (Exception invalidDate) { throw problem('Enter a valid resume date.'); }
        if (commitment.Status != 'Active' || commitment.Stripe_Pause_State__c == 'Scheduled' ||
            commitment.Stripe_Pause_State__c == 'Active' || commitment.Stripe_Pause_State__c == 'Sync Error') {
            throw problem('This donation is not eligible for a new pause. Resolve its existing pause first.');
        }
        GiftCommitmentSchedule source = currentSchedule(commitment.Id, 'CreateTransactions');
        if (source == null) throw problem('No current Create Transactions schedule is available to pause.');
        Date today = StripePauseBusinessClock.today();
        Boolean paidToday = hasPaidTransaction(commitment.Id, today, today.addDays(1));
        Date pauseStart = paidToday ? today.addDays(1) : today;
        verifyConfirmation(confirmation,today,pauseStart,paidToday);
        if (resumeDate == null || resumeDate <= pauseStart) {
            throw problem('Resume date must be after the Salesforce pause start date.');
        }
        if (hasPaidTransaction(commitment.Id, pauseStart, resumeDate)) {
            throw problem('A paid transaction falls inside the proposed pause period. No changes were made.');
        }
        if (hasConflictingSchedule(commitment.Id, source.Id, pauseStart, resumeDate)) {
            throw problem('Another future Salesforce schedule overlaps this pause. Resolve that schedule first.');
        }
        Long resumeEpoch = StripePauseBusinessClock.resumeEpoch(resumeDate);
        commitment.Stripe_Pause_Resume_At__c = StripePauseBusinessClock.resumeAt(resumeDate);
        Map<String,Object> before = getStripe(commitment.Subscription_Id__c);
        validateFixedResume(commitment, resumeDate, before);
        Map<String,Object> beforePause = objectMap(before.get('pause_collection'));
        if (beforePause != null && !isMatchingPause(beforePause, resumeEpoch)) {
            throw problem('Stripe already has a different pause. Reconciliation is required.');
        }
        if (beforePause == null) {
            verifyCurrentConfirmation(confirmation,commitment.Id);
            HttpResponse response;
            try {
                response = callStripe('POST', commitment.Subscription_Id__c,
                    'pause_collection[behavior]=void&pause_collection[resumes_at]=' + resumeEpoch,
                    key('pause', commitment.Id, pauseStart, resumeDate, revision(commitment)));
            } catch (Exception timeout) {
                throw problem('Stripe did not confirm the pause. Reopen this action to re-read Stripe before retrying.');
            }
            requireSuccess(response, 'Stripe pause failed');
        }
        try {
            Map<String,Object> verified = getStripe(commitment.Subscription_Id__c);
            if (!isMatchingPause(objectMap(verified.get('pause_collection')), resumeEpoch)) {
                throw new PauseException('Stripe did not verify the pause.');
            }
        } catch (Exception verificationFailure) {
            return failedSync(commitment, pauseStart, resumeDate, reason,
                'Stripe pause could not be verified; reconciliation is required.', false);
        }
        Savepoint handoff = Database.setSavepoint();
        Boolean previousGuard = StripePauseService.suppressSubscriptionUpdate;
        try {
            lockCommitment(commitment);
            // Recheck the payment window after Stripe verification; never overwrite a newer action.
            if (hasPaidTransaction(commitment.Id, pauseStart, resumeDate))
                throw new PauseException('A paid transaction now falls inside the pause period.');
            if (paidToday) {
                save(commitment.Id, 'Scheduled', pauseStart, resumeDate, reason, null,
                    revision(commitment) + 1, null, commitment.Stripe_Pause_Resume_At__c);
                StripePauseResult scheduled = new StripePauseResult(true, 'Scheduled', resumeDate,
                    'Stripe collection is paused. Salesforce pause is scheduled for ' + pauseStart +
                    ' (America/Los_Angeles). Today\'s already paid donation is unchanged.');
                scheduled.pauseStartDate = pauseStart;
                audit('Subscription Pause', 'Success', scheduled.message);
                return scheduled;
            }
            StripePauseService.suppressSubscriptionUpdate = true;
            nativePause(source.Id, pauseStart, resumeDate.addDays(-1));
            if (currentSchedule(commitment.Id, 'PauseTransactions') == null) {
                throw new PauseException('Native Pause Transactions segment was not verified.');
            }
            save(commitment.Id, 'Active', pauseStart, resumeDate, reason, 'Paused',
                revision(commitment) + 1, null, commitment.Stripe_Pause_Resume_At__c);
            audit('Subscription Pause', 'Success', 'Stripe and native Salesforce pause verified.');
            return new StripePauseResult(true, 'Paused', resumeDate,
                'Stripe collection and the Salesforce recurring schedule are paused.');
        } catch (Exception nativeFailure) {
            Database.rollback(handoff);
            if (nativeFailure instanceof ConcurrentPauseException) return concurrentFailure(commitment);
            return failedSync(commitment, pauseStart, resumeDate, reason,
                'Stripe stopped collection, but Salesforce pause failed. Compensation is queued.', false);
        } finally { StripePauseService.suppressSubscriptionUpdate = previousGuard; }
    }

    @AuraEnabled
    public static StripePauseResult resume(String subscriptionId, Id commitmentId) {
        GiftCommitment commitment = readCommitment(commitmentId);
        requireSubscription(commitment, subscriptionId);
        requireNoConcurrentError(commitment);
        if (!String.isBlank(commitment.Stripe_Pause_Plan__c) &&
            !String.isBlank(commitment.Stripe_Pause_State__c)) {
            return StripePauseTimelineService.resume(commitment);
        }
        if (commitment.Stripe_Pause_State__c != 'Scheduled' && commitment.Stripe_Pause_State__c != 'Active') {
            throw problem('There is no synchronized Stripe pause to resume.');
        }
        Date originalResume = commitment.Pause_Resume_Date__c;
        Map<String,Object> before = getStripe(commitment.Subscription_Id__c);
        if (objectMap(before.get('pause_collection')) != null) {
            HttpResponse response;
            try {
                response = callStripe('POST', commitment.Subscription_Id__c, 'pause_collection=',
                    key('resume', commitment.Id, commitment.Pause_Start_Date__c,
                        originalResume, revision(commitment)));
            } catch (Exception timeout) {
                throw problem('Stripe did not confirm the resume. Reopen this action to re-read Stripe before retrying.');
            }
            requireSuccess(response, 'Stripe resume failed');
        }
        Boolean resumedInStripe = false;
        try {
            Map<String,Object> verified = getStripe(commitment.Subscription_Id__c);
            resumedInStripe = objectMap(verified.get('pause_collection')) == null;
        } catch (Exception verificationFailure) {
            resumedInStripe = false;
        }
        if (!resumedInStripe) {
            return failedSync(commitment, commitment.Pause_Start_Date__c, originalResume,
                commitment.Pause_Reason__c, 'Stripe resume could not be verified.', true);
        }
        try { lockCommitment(commitment); }
        catch (ConcurrentPauseException newerAction) { return concurrentFailure(commitment); }
        if (commitment.Stripe_Pause_State__c == 'Scheduled') {
            save(commitment.Id, null, null, null, null, 'Active', revision(commitment) + 1, null);
            audit('Subscription Resume', 'Success', 'Stripe resumed before native pause activation.');
            return new StripePauseResult(true, 'Active', originalResume,
                'Stripe collection resumed; the pending Salesforce pause was cancelled.');
        }
        if (currentSchedule(commitment.Id, 'CreateTransactions') != null) {
            save(commitment.Id, null, null, null, null, 'Active', revision(commitment) + 1, null);
            audit('Subscription Resume', 'Success', 'Stripe resumed; native Create Transactions segment was already current.');
            return new StripePauseResult(true, 'Active', originalResume,
                'Stripe collection and Salesforce recurring payments have resumed.');
        }
        Savepoint resumeHandoff = Database.setSavepoint();
        Boolean previousGuard = StripePauseService.suppressSubscriptionUpdate;
        try {
            StripePauseService.suppressSubscriptionUpdate = true;
            GiftCommitmentSchedule pauseSegment = currentSchedule(commitment.Id, 'PauseTransactions');
            if (pauseSegment == null) pauseSegment = latestSchedule(commitment.Id, 'PauseTransactions');
            if (pauseSegment == null) throw new PauseException('No current Pause Transactions segment exists.');
            nativeResume(pauseSegment.Id, StripePauseBusinessClock.today());
            if (currentSchedule(commitment.Id, 'CreateTransactions') == null) {
                throw new PauseException('Native Create Transactions segment was not verified.');
            }
            save(commitment.Id, null, null, null, null, 'Active', revision(commitment) + 1, null);
            audit('Subscription Resume', 'Success', 'Stripe and native Salesforce resume verified.');
            return new StripePauseResult(true, 'Active', originalResume,
                'Stripe collection and Salesforce recurring payments resumed.');
        } catch (Exception nativeFailure) {
            Database.rollback(resumeHandoff);
            return failedSync(commitment, commitment.Pause_Start_Date__c, originalResume,
                commitment.Pause_Reason__c,
                'Stripe resumed, but Salesforce could not restore its schedule. Compensation is queued.', true);
        } finally { StripePauseService.suppressSubscriptionUpdate = previousGuard; }
    }

    /** Invoked for one commitment per isolated batch transaction. */
    public static void processDue(Id commitmentId) {
        GiftCommitment commitment = readCommitment(commitmentId);
        if (hasConcurrentError(commitment)) return;
        if (!String.isBlank(commitment.Stripe_Pause_Plan__c) &&
            !String.isBlank(commitment.Stripe_Pause_State__c)) {
            StripePauseTimelineService.processDue(commitment);
            return;
        }
        if (commitment.Stripe_Pause_State__c == 'Scheduled' &&
            (commitment.Pause_Start_Date__c <= StripePauseBusinessClock.today() || (Test.isRunningTest() && forceDueForTest))) {
            Savepoint handoff;
            Boolean previousGuard = StripePauseService.suppressSubscriptionUpdate;
            try {
                Map<String,Object> stripe = getStripe(commitment.Subscription_Id__c);
                if (!isMatchingPause(objectMap(stripe.get('pause_collection')),
                    storedResumeEpoch(commitment))) {
                    throw new PauseException('Stripe collection is not paused as expected.');
                }
                validateFixedResume(commitment, commitment.Pause_Resume_Date__c, stripe);
                GiftCommitmentSchedule source = currentSchedule(commitment.Id, 'CreateTransactions');
                if (source == null) throw new PauseException('No current Create Transactions segment exists.');
                lockCommitment(commitment);
                handoff = Database.setSavepoint();
                StripePauseService.suppressSubscriptionUpdate = true;
                nativePause(source.Id, commitment.Pause_Start_Date__c,
                    commitment.Pause_Resume_Date__c.addDays(-1));
                if (currentSchedule(commitment.Id, 'PauseTransactions') == null) {
                    throw new PauseException('Native pause segment was not verified.');
                }
                save(commitment.Id, 'Active', commitment.Pause_Start_Date__c,
                    commitment.Pause_Resume_Date__c, commitment.Pause_Reason__c,
                    'Paused', revision(commitment), null);
            } catch (Exception activationFailure) {
                if (handoff != null) Database.rollback(handoff);
                if (activationFailure instanceof ConcurrentPauseException) { concurrentFailure(commitment); return; }
                failedSync(commitment, commitment.Pause_Start_Date__c,
                    commitment.Pause_Resume_Date__c, commitment.Pause_Reason__c,
                    'Scheduled pause activation failed: ' + activationFailure.getMessage(), false);
            } finally { StripePauseService.suppressSubscriptionUpdate = previousGuard; }
        } else if (commitment.Stripe_Pause_State__c == 'Active' &&
            commitment.Pause_Resume_Date__c <= StripePauseBusinessClock.today()) {
            resume(commitment.Subscription_Id__c, commitment.Id);
        }
    }

    /** Compensation is intentionally a new callout transaction after the state is saved. */
    public static void compensate(Id commitmentId, Boolean restorePause) {
        compensate(commitmentId, restorePause, null);
    }
    public static void compensate(Id commitmentId, Boolean restorePause, Integer expectedRevision) {
        GiftCommitment commitment = readCommitment(commitmentId);
        if (hasConcurrentError(commitment) || commitment.Stripe_Pause_State__c != 'Sync Error' ||
            (expectedRevision != null && revision(commitment) != expectedRevision)) return;
        // Previously queued jobs carry no revision. They may only service legacy requests.
        if (expectedRevision == null && commitment.Stripe_Pause_Resume_At__c != null) return;
        if (!String.isBlank(commitment.Stripe_Pause_Plan__c)) {
            if (expectedRevision == null) {
                Map<String,Object> legacyPlan=(Map<String,Object>)JSON.deserializeUntyped(commitment.Stripe_Pause_Plan__c);
                if (legacyPlan == null || String.valueOf(legacyPlan.get('version')) != '1') return;
            }
            StripePauseTimelineService.compensate(commitment);
            return;
        }
        try {
            Map<String,Object> actualPause = objectMap(getStripe(commitment.Subscription_Id__c).get('pause_collection'));
            Boolean alreadyRestored = restorePause ? isMatchingPause(actualPause, storedResumeEpoch(commitment)) : actualPause == null;
            Boolean failedState = restorePause ? actualPause == null : isMatchingPause(actualPause, storedResumeEpoch(commitment));
            if (!alreadyRestored && !failedState) throw new PauseException('Stripe collection changed externally. Compensation cannot overwrite it.');
            String body = restorePause
                ? 'pause_collection[behavior]=void&pause_collection[resumes_at]=' +
                  storedResumeEpoch(commitment)
                : 'pause_collection=';
            if (!alreadyRestored) {
                HttpResponse response = callStripe('POST', commitment.Subscription_Id__c, body,
                    key(restorePause ? 'compensate-resume' : 'compensate-pause', commitment.Id,
                        commitment.Pause_Start_Date__c, commitment.Pause_Resume_Date__c, revision(commitment)));
                requireSuccess(response, 'Stripe compensation failed');
            }
            Map<String,Object> stripe = getStripe(commitment.Subscription_Id__c);
            Boolean confirmed = restorePause
                ? isMatchingPause(objectMap(stripe.get('pause_collection')),
                    storedResumeEpoch(commitment))
                : objectMap(stripe.get('pause_collection')) == null;
            if (!confirmed) throw new PauseException('Compensation could not be verified.');
            lockCommitment(commitment);
            save(commitment.Id, 'Failed', commitment.Pause_Start_Date__c,
                commitment.Pause_Resume_Date__c, commitment.Pause_Reason__c, null,
                revision(commitment) + 1,
                'Stripe was restored after Salesforce synchronization failed. Review before retry.');
            audit('Subscription Pause Compensation', 'Declined',
                'Stripe compensation verified; native Salesforce action remains failed.');
        } catch (Exception failedCompensation) {
            if (failedCompensation instanceof ConcurrentPauseException) { concurrentFailure(commitment); return; }
            try {
                lockCommitment(commitment);
                save(commitment.Id, 'Sync Error', commitment.Pause_Start_Date__c,
                    commitment.Pause_Resume_Date__c, commitment.Pause_Reason__c, null,
                    revision(commitment), 'Compensation failed. Administrator reconciliation is required.');
            } catch(ConcurrentPauseException newerAction) { concurrentFailure(commitment); return; }
            audit('Subscription Pause Compensation', 'Declined',
                'Stripe compensation failed; administrator reconciliation required.');
        }
    }

    private static StripePauseResult failedSync(GiftCommitment commitment, Date startDate, Date resumeDate,
                                     String reason, String detail, Boolean restorePause) {
        try { lockCommitment(commitment); }
        catch (ConcurrentPauseException newerAction) { return concurrentFailure(commitment); }
        save(commitment.Id, 'Sync Error', startDate, resumeDate, reason, null,
            revision(commitment) + 1, detail, commitment.Stripe_Pause_Resume_At__c);
        audit('Subscription Pause Synchronization', 'Declined', detail);
        if (!restorePause || (resumeDate != null && resumeDate > StripePauseBusinessClock.today())) {
            System.enqueueJob(new StripePauseCompensationQueueable(commitment.Id, restorePause, revision(commitment) + 1));
        }
        return new StripePauseResult(false, 'Reconciliation Required', resumeDate, detail);
    }

    private static GiftCommitment readCommitment(Id commitmentId) {
        if (commitmentId == null) throw problem('Recurring donation ID is required.');
        List<GiftCommitment> found = [
            SELECT Id, Status, Subscription_Id__c, Pause_Reason__c, Pause_Start_Date__c,
                   Pause_Resume_Date__c, Stripe_Pause_State__c, Stripe_Pause_Attempt_Count__c,
                   Recurring_Type__c, Stripe_Pause_Plan__c, Stripe_Pause_Last_Error__c, Stripe_Pause_Resume_At__c
            FROM GiftCommitment WHERE Id = :commitmentId WITH USER_MODE LIMIT 1
        ];
        if (found.isEmpty()) throw problem('Recurring donation was not found.');
        return found[0];
    }

    private static void requireSubscription(GiftCommitment commitment, String suppliedId) {
        if (String.isBlank(commitment.Subscription_Id__c) ||
            !commitment.Subscription_Id__c.startsWith('sub_') ||
            String.isBlank(suppliedId) || suppliedId != commitment.Subscription_Id__c) {
            throw problem('Stripe subscription ID is missing or does not match this donation.');
        }
    }

    private static GiftCommitmentSchedule currentSchedule(Id commitmentId, String requiredType) {
        GiftCommitmentSchedule segment = currentSegment(commitmentId);
        return segment != null && segment.Type == requiredType ? segment : null;
    }

    private static GiftCommitmentSchedule currentSegment(Id commitmentId) {
        Date today = StripePauseBusinessClock.today();
        for (GiftCommitmentSchedule schedule : [
            SELECT Id, Type, StartDate, EndDate FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitmentId AND StartDate <= :today
            ORDER BY StartDate DESC, CreatedDate DESC LIMIT 50
        ]) {
            if (schedule.EndDate == null || schedule.EndDate >= today) return schedule;
        }
        return null;
    }

    private static GiftCommitmentSchedule latestSchedule(Id commitmentId, String requiredType) {
        List<GiftCommitmentSchedule> segments = [
            SELECT Id, Type, StartDate, EndDate FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitmentId AND Type = :requiredType
            ORDER BY StartDate DESC LIMIT 1
        ];
        return segments.isEmpty() ? null : segments[0];
    }

    private static Boolean hasPaidTransaction(Id commitmentId, Date startDate, Date endDate) {
        for (GiftTransaction payment : [
            SELECT TransactionDate, TransactionDueDate FROM GiftTransaction
            WHERE GiftCommitmentId = :commitmentId AND Status = 'Paid' WITH USER_MODE
        ]) {
            Date paidOn = payment.TransactionDate == null
                ? payment.TransactionDueDate : payment.TransactionDate;
            if (paidOn != null && paidOn >= startDate && paidOn < endDate) return true;
        }
        return false;
    }

    private static Boolean hasConflictingSchedule(Id commitmentId, Id sourceId,
                                                  Date pauseStart, Date resumeDate) {
        for (GiftCommitmentSchedule segment : [
            SELECT Id, StartDate, EndDate, Type FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitmentId AND StartDate < :resumeDate
        ]) {
            if (segment.Id == sourceId) continue;
            if (segment.EndDate == null || segment.EndDate >= pauseStart) return true;
        }
        return false;
    }

    /** A Fixed donation cannot be set to resume after its final real installment. */
    private static void validateFixedResume(GiftCommitment commitment, Date resumeDate,
                                            Map<String,Object> stripe) {
        if (commitment.Recurring_Type__c != 'Fixed') return;
        Date finalPayment;
        for (GiftCommitmentSchedule segment : [
            SELECT Id, StartDate, EndDate, Final_Payment_Date__c, Type
            FROM GiftCommitmentSchedule
            WHERE GiftCommitmentId = :commitment.Id AND Type = 'CreateTransactions'
            ORDER BY StartDate DESC LIMIT 50
        ]) {
            if (segment.EndDate == null) {
                throw problem('The Fixed donation has an open-ended Salesforce schedule. Reconcile its final installment before pausing.');
            }
            Date segmentFinal = segment.Final_Payment_Date__c;
            if (segmentFinal == null) {
                throw problem('The Fixed donation has no calculated final installment. Reconcile its schedule before pausing.');
            }
            if (finalPayment == null || segmentFinal > finalPayment) finalPayment = segmentFinal;
        }
        if (finalPayment == null) {
            throw problem('The Fixed donation has no final installment schedule. No pause was made.');
        }
        if (resumeDate > finalPayment) {
            throw problem('Resume date cannot be after the Fixed donation\'s final installment on ' +
                String.valueOf(finalPayment) + '. No pause was made.');
        }
        Long cancellation = stripeEpoch(stripe, 'cancel_at');
        if (cancellation == null && stripe.get('cancel_at_period_end') == true) {
            cancellation = stripeEpoch(stripe, 'current_period_end');
        }
        if (cancellation != null && storedOrNewResumeEpoch(commitment, resumeDate) >= cancellation) {
            throw problem('Stripe is due to cancel before collection resumes. Reconcile the Fixed donation before pausing.');
        }
        if (resumeDate == finalPayment) {
            Long billing = stripeEpoch(stripe, 'billing_cycle_anchor');
            if (billing == null) billing = stripeEpoch(stripe, 'current_period_end');
            Boolean resumePrecedesBilling = false;
            if (billing != null) {
                try {
                    DateTime billingTime = DateTime.newInstanceGmt(1970, 1, 1, 0, 0, 0)
                        .addSeconds(Integer.valueOf(billing));
                    DateTime candidateTime = DateTime.newInstanceGmt(resumeDate, billingTime.timeGmt());
                    resumePrecedesBilling = storedOrNewResumeEpoch(commitment, resumeDate) < candidateTime.getTime()/1000;
                } catch (Exception invalidBillingTime) {
                    resumePrecedesBilling = false;
                }
            }
            if (!resumePrecedesBilling) {
                throw problem('Resume on the final installment date must precede its Stripe billing time. Select an earlier date.');
            }
        }
    }

    private static Long stripeEpoch(Map<String,Object> stripe, String field) {
        if (stripe == null || stripe.get(field) == null) return null;
        try { return Long.valueOf(String.valueOf(stripe.get(field))); }
        catch (Exception invalidTimestamp) { return null; }
    }

    @TestVisible private static void nativePause(Id scheduleId, Date startDate, Date endDate) {
        if (Test.isRunningTest() && forceNativeFailure) throw new PauseException('Simulated native pause failure.');
        if (Test.isRunningTest()) {
            update new GiftCommitmentSchedule(Id = scheduleId, Type = 'PauseTransactions', EndDate = endDate);
            return;
        }
        nativePauseSchedule(scheduleId, startDate, endDate);
    }

    /** Executes the real native schedule handoff; integration tests bypass only the HTTP boundary. */
    @TestVisible private static void nativePauseSchedule(Id scheduleId, Date startDate, Date endDate) {
        GiftCommitmentSchedule source = [SELECT GiftCommitmentId, EndDate
            FROM GiftCommitmentSchedule WHERE Id = :scheduleId];
        Date resumeDate = endDate.addDays(1);
        Savepoint handoff = Database.setSavepoint();
        try {
            // A bounded native pause rejects already-generated installments after its end.
            // Pause the remainder, then let the native resume action restore those terms.
            Invocable.Action action = Invocable.Action.createStandardAction('pauseGiftCommitmentSchedule');
            action.setInvocationParameter('giftCommitmentScheduleId', String.valueOf(scheduleId));
            action.setInvocationParameter('startDate', startDate);
            requireAction(action.invoke(), 'pause');
            List<GiftCommitmentSchedule> pauses = [SELECT Id FROM GiftCommitmentSchedule
                WHERE GiftCommitmentId = :source.GiftCommitmentId AND Type = 'PauseTransactions'
                AND StartDate = :startDate];
            if (pauses.size() != 1) throw new PauseException('Native pause segment could not be uniquely verified.');
            nativeResumeSchedule(pauses[0].Id, resumeDate);
            List<GiftCommitmentSchedule> restored = [SELECT EndDate FROM GiftCommitmentSchedule
                WHERE GiftCommitmentId = :source.GiftCommitmentId AND Type = 'CreateTransactions'
                AND StartDate = :resumeDate];
            if (restored.size() != 1 || restored[0].EndDate != source.EndDate ||
                [SELECT COUNT() FROM GiftCommitmentSchedule WHERE Id = :pauses[0].Id
                    AND EndDate = :endDate] != 1) {
                throw new PauseException('Native pause and planned resume boundaries did not verify.');
            }
        } catch (Exception failure) {
            Database.rollback(handoff);
            throw failure;
        }
    }

    @TestVisible private static void nativeResume(Id scheduleId, Date resumeDate) {
        if (Test.isRunningTest() && forceNativeFailure) throw new PauseException('Simulated native resume failure.');
        if (Test.isRunningTest()) {
            update new GiftCommitmentSchedule(Id = scheduleId, Type = 'CreateTransactions',
                StartDate = resumeDate, EndDate = null);
            return;
        }
        nativeResumeSchedule(scheduleId, resumeDate);
    }

    @TestVisible private static void nativeResumeSchedule(Id scheduleId, Date resumeDate) {
        Invocable.Action action = Invocable.Action.createStandardAction('resumeGiftCommitmentSchedule');
        action.setInvocationParameter('giftCommitmentScheduleId', String.valueOf(scheduleId));
        action.setInvocationParameter('resumeDate', resumeDate);
        requireAction(action.invoke(), 'resume');
    }

    private static void requireAction(List<Invocable.Action.Result> results, String verb) {
        if (results == null || results.isEmpty() || !results[0].isSuccess()) {
            throw new PauseException('Native Salesforce ' + verb + ' action failed.');
        }
    }

    private static void save(Id id, String state, Date startDate, Date resumeDate,
                             String reason, String status, Integer count, String error) {
        save(id, state, startDate, resumeDate, reason, status, count, error, null, false);
    }
    private static void save(Id id, String state, Date startDate, Date resumeDate,
                             String reason, String status, Integer count, String error, DateTime resumeAt) {
        save(id, state, startDate, resumeDate, reason, status, count, error, resumeAt, true);
    }
    private static void save(Id id, String state, Date startDate, Date resumeDate,
                             String reason, String status, Integer count, String error, DateTime resumeAt, Boolean writeInstant) {
        GiftCommitment change = new GiftCommitment(Id = id,
            Stripe_Pause_State__c = state, Pause_Start_Date__c = startDate,
            Pause_Resume_Date__c = resumeDate, Pause_Reason__c = reason,
            Stripe_Pause_Attempt_Count__c = count,
            Stripe_Pause_Last_Error__c = error == null ? null : error.left(255));
        if (status != null) change.Status = status;
        if (writeInstant || resumeDate == null) change.Stripe_Pause_Resume_At__c = resumeAt;
        Boolean previous = StripePauseService.suppressSubscriptionUpdate;
        StripePauseService.suppressSubscriptionUpdate = true;
        try { update as user change; }
        finally { StripePauseService.suppressSubscriptionUpdate = previous; }
        logPauseFailure(id, state, error, 'StripePauseOrchestrator.save');
    }

    // Concurrent-action markers are expected reconciliation notes, not Stripe failures.
    // Published right after the DML above, so no later callout in this transaction is affected.
    public static void logPauseFailure(Id commitmentId, String state, String error, String operationName) {
        if (error == null || error.startsWith('CONCURRENT_ACTION:')) return;
        StripeFailureLogger.record(StripeFailureLogger.failure(
                StripeFailureLogger.SOURCE_PAUSE_RESUME, StripeFailureLogger.CODE_PAUSE_RESUME_FAILED,
                'Stripe pause/resume failed (state: ' + state + ')')
            .withError(error)
            .operation(operationName)
            .commitment(commitmentId));
        StripeFailureLogger.flush();
    }

    private static Integer revision(GiftCommitment commitment) {
        return commitment.Stripe_Pause_Attempt_Count__c == null ? 0 :
            Integer.valueOf(commitment.Stripe_Pause_Attempt_Count__c);
    }

    private static Long storedResumeEpoch(GiftCommitment gift) {
        return gift.Stripe_Pause_Resume_At__c == null ? utcNoon(gift.Pause_Resume_Date__c) : gift.Stripe_Pause_Resume_At__c.getTime()/1000;
    }
    private static Long storedOrNewResumeEpoch(GiftCommitment gift, Date resumeDate) {
        return gift.Stripe_Pause_Resume_At__c == null ? utcNoon(resumeDate) : gift.Stripe_Pause_Resume_At__c.getTime()/1000;
    }
    private static void lockCommitment(GiftCommitment expected) {
        GiftCommitment current = [SELECT Id, Subscription_Id__c, Stripe_Pause_State__c, Stripe_Pause_Attempt_Count__c,Stripe_Pause_Last_Error__c
            FROM GiftCommitment WHERE Id = :expected.Id WITH USER_MODE FOR UPDATE];
        if (hasConcurrentError(current) || current.Subscription_Id__c != expected.Subscription_Id__c || current.Stripe_Pause_State__c != expected.Stripe_Pause_State__c ||
            revision(current) != revision(expected)) throw new ConcurrentPauseException('A newer pause instruction was preserved.');
    }
    public static void verifyConfirmation(StripePausePreview confirmation,Date businessDate,Date startDate,Boolean paidToday) {
        if(confirmation!=null && (confirmation.businessDate!=businessDate || confirmation.pauseStartDate!=startDate || confirmation.paidToday!=paidToday))
            throw problem('Pause details changed since confirmation. Review the updated pause date and paid-payment warning before confirming again.');
    }
    public static void verifyCurrentConfirmation(StripePausePreview confirmation,Id commitmentId) {
        if(confirmation==null) return;
        Date today=StripePauseBusinessClock.today();
        Boolean paid=hasPaidTransaction(commitmentId,today,today.addDays(1));
        verifyConfirmation(confirmation,today,paid?today.addDays(1):today,paid);
    }
    private static Boolean hasConcurrentError(GiftCommitment gift) {
        return gift.Stripe_Pause_Last_Error__c != null && gift.Stripe_Pause_Last_Error__c.startsWith('CONCURRENT_ACTION:');
    }
    private static void requireNoConcurrentError(GiftCommitment gift) {
        if (hasConcurrentError(gift)) throw problem('Concurrent pause instructions require administrator reconciliation.');
    }
    private static void requireWritableResumeInstant() {
        if (!GiftCommitment.Stripe_Pause_Resume_At__c.getDescribe().isUpdateable())
            throw problem('Required pause resume instant field access is missing.');
    }
    private static StripePauseResult concurrentFailure(GiftCommitment attempted) {
        Boolean previous = StripePauseService.suppressSubscriptionUpdate;
        StripePauseService.suppressSubscriptionUpdate = true;
        try {
            update as user new GiftCommitment(Id=attempted.Id,Stripe_Pause_Last_Error__c=
                'CONCURRENT_ACTION: A newer pause instruction was preserved. Administrator reconciliation is required; no compensation was queued.');
        } finally { StripePauseService.suppressSubscriptionUpdate = previous; }
        return new StripePauseResult(false, 'Reconciliation Required', null,
            'A newer pause instruction was preserved. Administrator reconciliation is required; no compensation was queued.');
    }
    private class ConcurrentPauseException extends Exception { }
    private static Long utcNoon(Date dateValue) {
        return DateTime.newInstanceGmt(dateValue.year(), dateValue.month(),
            dateValue.day(), 12, 0, 0).getTime() / 1000;
    }

    private static String key(String operation, Id id, Date startDate, Date resumeDate, Integer revision) {
        String source = operation + '|' + id + '|' + startDate + '|' + resumeDate + '|' + revision;
        return 'sapa-pause-' + EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(source)));
    }

    private static Map<String,Object> getStripe(String subscriptionId) {
        HttpResponse response;
        try { response = callStripe('GET', subscriptionId, null, null); }
        catch (Exception timeout) {
            throw problem('Stripe subscription could not be read. No verified change can be reported.');
        }
        requireSuccess(response, 'Stripe subscription read failed');
        Map<String,Object> data = objectMap(JSON.deserializeUntyped(response.getBody()));
        if (data == null || String.valueOf(data.get('id')) != subscriptionId) {
            throw problem('Stripe returned a different subscription. No Salesforce mutation was made.');
        }
        return data;
    }

    private static HttpResponse callStripe(String method, String subscriptionId, String body, String requestKey) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(API + EncodingUtil.urlEncode(subscriptionId, 'UTF-8'));
        request.setMethod(method);
        request.setHeader('Authorization', 'Bearer ' + System.Label.Stripe_Secret);
        if (method == 'POST') {
            request.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            request.setHeader('Idempotency-Key', requestKey);
            request.setBody(body);
        }
        request.setTimeout(20000);
        return new Http().send(request);
    }

    private static void requireSuccess(HttpResponse response, String operation) {
        if (response == null || response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
            throw problem(operation + ': ' + (response == null
                ? 'no response' : stripeError(response.getBody())));
        }
    }

    private static Boolean isMatchingPause(Map<String,Object> pause, Long epoch) {
        return pause != null && String.valueOf(pause.get('behavior')) == 'void' &&
            pause.get('resumes_at') != null &&
            Long.valueOf(String.valueOf(pause.get('resumes_at'))) == epoch;
    }

    private static Map<String,Object> objectMap(Object value) {
        return value instanceof Map<String,Object> ? (Map<String,Object>) value : null;
    }

    private static String stripeError(String body) {
        if (String.isBlank(body)) return 'Unknown Stripe error';
        try {
            Map<String,Object> parsed = objectMap(JSON.deserializeUntyped(body));
            Map<String,Object> failure = parsed == null ? null : objectMap(parsed.get('error'));
            if (failure != null && failure.get('message') != null)
                return String.valueOf(failure.get('message'));
        } catch (Exception ignored) { }
        return body.left(255);
    }

    private static void audit(String operation, String status, String detail) {
        try {
            StripeCustomerService.createGatewayLog(detail, StripePauseBusinessClock.today(), status,
                'Stripe', operation, '', '', '', '', '', status == 'Success' ? '200' : 'SYNC');
        } catch (Exception loggingFailure) {
            System.debug(LoggingLevel.WARN, 'Pause gateway audit log could not be written.');
        }
    }

    private static AuraHandledException problem(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }

    private class PauseException extends Exception { }
}