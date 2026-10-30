/**
 * Turns Stripe_Failure__e events into Stripe_Failure_Log__c records, one per dedupe key.
 * Repeats increment Occurrence_Count__c; a repeat of a Resolved failure reopens it so the
 * notification flow alerts again. Notify__c comes from Stripe_Failure_Setting__mdt, and a burst
 * of failures alerts once per reason code per event batch (the other logs are still created).
 *
 * Without sharing on purpose: it runs as the platform event subscriber (Automated Process user)
 * and must find and update existing logs by key even after support staff take ownership of them.
 */
public without sharing class StripeFailureEventHandler {

    private static final String STATUS_NEW = 'New';
    private static final String STATUS_RESOLVED = 'Resolved';

    // Tests cannot insert custom metadata, so they can override a code's Notify setting here.
    @TestVisible
    private static Map<String, Boolean> notifyOverrides = new Map<String, Boolean>();

    public static void handle(List<Stripe_Failure__e> events) {
        if (events == null || events.isEmpty()) return;

        // Collapse repeats inside this batch first: the latest event wins, counts add up.
        Map<String, Stripe_Failure__e> latestByKey = new Map<String, Stripe_Failure__e>();
        Map<String, Integer> countByKey = new Map<String, Integer>();
        for (Stripe_Failure__e event : events) {
            String key = String.isNotBlank(event.Dedupe_Key__c) ? event.Dedupe_Key__c : event.EventUuid;
            latestByKey.put(key, event);
            countByKey.put(key, (countByKey.containsKey(key) ? countByKey.get(key) : 0) + 1);
        }

        Map<String, Stripe_Failure_Log__c> existingByKey = new Map<String, Stripe_Failure_Log__c>();
        for (Stripe_Failure_Log__c log : [
            SELECT Id, Dedupe_Key__c, Occurrence_Count__c, Status__c
            FROM Stripe_Failure_Log__c
            WHERE Dedupe_Key__c IN :latestByKey.keySet()
        ]) {
            existingByKey.put(log.Dedupe_Key__c, log);
        }

        Set<String> alertedCodes = new Set<String>();
        List<Stripe_Failure_Log__c> logs = new List<Stripe_Failure_Log__c>();
        for (String key : latestByKey.keySet()) {
            Stripe_Failure__e event = latestByKey.get(key);
            Stripe_Failure_Log__c existing = existingByKey.get(key);
            Stripe_Failure_Log__c log = existing == null ? newLog(event, key) : new Stripe_Failure_Log__c(Id = existing.Id);
            log.Failure_Reason__c = event.Failure_Reason__c;
            log.Error_Message__c = event.Error_Message__c;
            log.Stack_Trace__c = event.Stack_Trace__c;
            log.HTTP_Status_Code__c = event.HTTP_Status_Code__c;
            log.Last_Occurred_At__c = event.Occurred_At__c;
            Boolean alerts = false;
            if (existing == null) {
                log.Occurrence_Count__c = countByKey.get(key);
                alerts = true;
            } else {
                Decimal previous = existing.Occurrence_Count__c == null ? 0 : existing.Occurrence_Count__c;
                log.Occurrence_Count__c = previous + countByKey.get(key);
                if (existing.Status__c == STATUS_RESOLVED) {
                    log.Status__c = STATUS_NEW;
                    alerts = true;
                }
            }
            if (alerts) {
                // add() is false when this code already alerted in this batch.
                log.Notify__c = shouldNotify(event.Reason_Code__c) && alertedCodes.add(String.valueOf(event.Reason_Code__c));
            }
            logs.add(log);
        }

        // A linked record may have been deleted since the failure: save new logs without their
        // links rather than lose them. Existing logs keep their links.
        List<Stripe_Failure_Log__c> retry = new List<Stripe_Failure_Log__c>();
        for (Stripe_Failure_Log__c log : save(logs)) {
            if (log.Id == null) {
                log.Gift_Commitment__c = null;
                log.Gift_Transaction__c = null;
                log.Payment__c = null;
                log.Stripe_Subscription_Change__c = null;
                retry.add(log);
            }
        }
        for (Stripe_Failure_Log__c log : save(retry)) {
            System.debug(LoggingLevel.ERROR, 'StripeFailureEventHandler could not save log ' + log.Dedupe_Key__c);
        }
    }

    // Returns the logs that failed to save.
    private static List<Stripe_Failure_Log__c> save(List<Stripe_Failure_Log__c> logs) {
        List<Stripe_Failure_Log__c> failed = new List<Stripe_Failure_Log__c>();
        if (logs.isEmpty()) return failed;
        List<Database.UpsertResult> results = Database.upsert(logs, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                System.debug(LoggingLevel.WARN, 'StripeFailureEventHandler save failed for ' + logs[i].Dedupe_Key__c
                    + ': ' + results[i].getErrors());
                failed.add(logs[i]);
            }
        }
        return failed;
    }

    private static Stripe_Failure_Log__c newLog(Stripe_Failure__e event, String key) {
        return new Stripe_Failure_Log__c(
            Dedupe_Key__c = key,
            Status__c = STATUS_NEW,
            Failure_Source__c = event.Failure_Source__c,
            Reason_Code__c = event.Reason_Code__c,
            Operation__c = event.Operation__c,
            Stripe_Event_Id__c = event.Stripe_Event_Id__c,
            Stripe_Event_Type__c = event.Stripe_Event_Type__c,
            Stripe_Object_Id__c = event.Stripe_Object_Id__c,
            Stripe_Subscription_Id__c = event.Stripe_Subscription_Id__c,
            Stripe_Customer_Id__c = event.Stripe_Customer_Id__c,
            Amount__c = event.Amount__c,
            Gift_Commitment__c = idOf(event.Gift_Commitment_Id__c, GiftCommitment.SObjectType),
            Gift_Transaction__c = idOf(event.Gift_Transaction_Id__c, GiftTransaction.SObjectType),
            Payment__c = idOf(event.Payment_Id__c, Payment__c.SObjectType),
            Stripe_Subscription_Change__c = idOf(event.Subscription_Change_Id__c, Stripe_Subscription_Change__c.SObjectType)
        );
    }

    // Unknown codes notify by default; a setting record with Notify unticked mutes its code.
    private static Boolean shouldNotify(String reasonCode) {
        if (String.isBlank(reasonCode)) return true;
        if (notifyOverrides.containsKey(reasonCode)) return notifyOverrides.get(reasonCode);
        Stripe_Failure_Setting__mdt setting = Stripe_Failure_Setting__mdt.getInstance(reasonCode);
        return setting == null || setting.Notify__c;
    }

    private static Id idOf(String value, Schema.SObjectType expectedType) {
        if (String.isBlank(value)) return null;
        try {
            Id recordId = Id.valueOf(value);
            return recordId.getSObjectType() == expectedType ? recordId : null;
        } catch (StringException invalidId) {
            return null;
        }
    }
}