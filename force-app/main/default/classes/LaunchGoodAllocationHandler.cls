/**
 * Filters LaunchGood imported designation records before delegating fund routing.
 */
public with sharing class LaunchGoodAllocationHandler {

    private static final String LAUNCHGOOD_VALUE = 'launchgood';
    private static final String PLACEHOLDER_FUND_NAME = 'Launchgood Import';
    private static final String MATCHED_STATUS = 'Matched';
    private static Id placeholderFundId;
    private static Boolean placeholderFundLoaded = false;
    private static Boolean hasRun = false;

    /**
     * Handles GiftTransactionDesignation and GiftDefaultDesignation records from triggers.
     *
     * @param newRecords Trigger records to evaluate.
     * @param oldMap Trigger old map for update comparisons.
     * @param isInsert True when called from insert context.
     * @param isUpdate True when called from update context.
     */
    public static void handle(
        List<SObject> newRecords,
        Map<Id, SObject> oldMap,
        Boolean isInsert,
        Boolean isUpdate
    ) {
        if (hasRun) {
            return;
        }

        if (newRecords == null || newRecords.isEmpty()) {
            return;
        }

        Schema.SObjectType sObjectType = newRecords[0].getSObjectType();

        if (sObjectType != GiftTransactionDesignation.sObjectType
            && sObjectType != GiftDefaultDesignation.sObjectType) {
            return;
        }

        Map<Id, Boolean> launchGoodParentById = getLaunchGoodParentFlags(newRecords, sObjectType);
        List<SObject> recordsToProcess = new List<SObject>();

        for (SObject record : newRecords) {
            if (shouldRoute(record, oldMap, isInsert, isUpdate, sObjectType, launchGoodParentById)) {
                recordsToProcess.add(record);
            }
        }

        if (recordsToProcess.isEmpty()) {
            return;
        }

        hasRun = true;

        if (sObjectType == GiftTransactionDesignation.sObjectType) {
            LaunchGoodRoutingService.route((List<GiftTransactionDesignation>) recordsToProcess);
        } else {
            LaunchGoodRoutingService.route((List<GiftDefaultDesignation>) recordsToProcess);
        }
    }

    private static Boolean shouldRoute(
        SObject record,
        Map<Id, SObject> oldMap,
        Boolean isInsert,
        Boolean isUpdate,
        Schema.SObjectType sObjectType,
        Map<Id, Boolean> launchGoodParentById
    ) {
        if (record == null) {
            return false;
        }

        Boolean isOmaticImport = (Boolean) record.get('Omatic_Import__c');
        String projectUrl = (String) record.get('LaunchGood_Project_URL__c');

        if (isOmaticImport != true || String.isBlank(projectUrl)) {
            return false;
        }

        Id parentId = getParentId(record, sObjectType);

        if (parentId == null || launchGoodParentById.get(parentId) != true) {
            return false;
        }

        String fundMatchStatus = (String) record.get('Fund_Match_Status__c');

        if (fundMatchStatus != MATCHED_STATUS) {
            return isPlaceholderFund(record) || (isUpdate == true && routingInputsChanged(record, oldMap));
        }

        return isUpdate == true && routingInputsChanged(record, oldMap);
    }

    private static Boolean isPlaceholderFund(SObject record) {
        Id fundId = (Id) record.get('GiftDesignationId');
        Id launchGoodImportFundId = getPlaceholderFundId();

        return fundId != null && launchGoodImportFundId != null && fundId == launchGoodImportFundId;
    }

    private static Id getPlaceholderFundId() {
        if (!placeholderFundLoaded) {
            placeholderFundLoaded = true;

            List<GiftDesignation> funds = [
                SELECT Id
                FROM GiftDesignation
                WHERE Name = :PLACEHOLDER_FUND_NAME
                LIMIT 1
            ];

            if (!funds.isEmpty()) {
                placeholderFundId = funds[0].Id;
            }
        }

        return placeholderFundId;
    }

    private static Boolean routingInputsChanged(SObject record, Map<Id, SObject> oldMap) {
        if (record == null || record.Id == null || oldMap == null || !oldMap.containsKey(record.Id)) {
            return false;
        }

        SObject oldRecord = oldMap.get(record.Id);

        return normaliseUrl((String) record.get('LaunchGood_Project_URL__c'))
                != normaliseUrl((String) oldRecord.get('LaunchGood_Project_URL__c'))
            || normaliseText((String) record.get('Special_Request__c'))
                != normaliseText((String) oldRecord.get('Special_Request__c'));
    }

    private static Map<Id, Boolean> getLaunchGoodParentFlags(
        List<SObject> records,
        Schema.SObjectType sObjectType
    ) {
        Set<Id> parentIds = new Set<Id>();

        for (SObject record : records) {
            Id parentId = getParentId(record, sObjectType);

            if (parentId != null) {
                parentIds.add(parentId);
            }
        }

        Map<Id, Boolean> launchGoodParentById = new Map<Id, Boolean>();

        if (parentIds.isEmpty()) {
            return launchGoodParentById;
        }

        if (sObjectType == GiftTransactionDesignation.sObjectType) {
            for (GiftTransaction transactionRecord : [
                SELECT Id, Channel__c
                FROM GiftTransaction
                WHERE Id IN :parentIds
            ]) {
                launchGoodParentById.put(
                    transactionRecord.Id,
                    isLaunchGoodValue(transactionRecord.Channel__c)
                );
            }
        } else {
            for (GiftCommitment commitment : [
                SELECT Id, Channel__c
                FROM GiftCommitment
                WHERE Id IN :parentIds
            ]) {
                launchGoodParentById.put(
                    commitment.Id,
                    isLaunchGoodValue(commitment.Channel__c)
                );
            }
        }

        return launchGoodParentById;
    }

    private static Id getParentId(SObject record, Schema.SObjectType sObjectType) {
        if (record == null) {
            return null;
        }

        if (sObjectType == GiftTransactionDesignation.sObjectType) {
            return (Id) record.get('GiftTransactionId');
        }

        return (Id) record.get('ParentRecordId');
    }

    private static Boolean isLaunchGoodValue(String value) {
        return normaliseText(value) == LAUNCHGOOD_VALUE;
    }

    private static String normaliseUrl(String value) {
        if (String.isBlank(value)) {
            return null;
        }

        String cleaned = value.trim().toLowerCase();

        if (cleaned.endsWith('/')) {
            cleaned = cleaned.substring(0, cleaned.length() - 1);
        }

        return cleaned;
    }

    private static String normaliseText(String value) {
        if (String.isBlank(value)) {
            return null;
        }

        return value.trim().toLowerCase();
    }
}