public with sharing class RuntimeCampaignGiftHierarchyController {
    private static final Integer MAX_DEPTH = 20;

    @AuraEnabled(cacheable=true)
    public static List<CampaignNode> getHierarchy(
        Id campaignId,
        String giftStatusesCsv,
        String startDateText,
        String endDateText,
        Boolean includeSourceCodeAttribution
    ) {
        if (campaignId == null) {
            return new List<CampaignNode>();
        }

        Set<String> giftStatuses = parseStatuses(giftStatusesCsv);
        Date startDate = parseDate(startDateText);
        Date endDate = parseDate(endDateText);

        Map<Id, Campaign> campaignById = new Map<Id, Campaign>();
        Map<Id, List<Id>> childrenByParentId = new Map<Id, List<Id>>();

        Campaign root = [
            SELECT Id, Name, ParentId, Type, Status, IsActive, StartDate, EndDate
            FROM Campaign
            WHERE Id = :campaignId
            LIMIT 1
        ];

        campaignById.put(root.Id, root);

        Set<Id> frontier = new Set<Id>{ campaignId };
        Integer depth = 0;

        while (!frontier.isEmpty() && depth < MAX_DEPTH) {
            List<Campaign> children = [
                SELECT Id, Name, ParentId, Type, Status, IsActive, StartDate, EndDate
                FROM Campaign
                WHERE ParentId IN :frontier
                ORDER BY ParentId, Name
            ];

            frontier.clear();

            for (Campaign child : children) {
                campaignById.put(child.Id, child);
                frontier.add(child.Id);

                if (!childrenByParentId.containsKey(child.ParentId)) {
                    childrenByParentId.put(child.ParentId, new List<Id>());
                }

                childrenByParentId.get(child.ParentId).add(child.Id);
            }

            depth++;
        }

        Set<Id> campaignIds = campaignById.keySet();

        Map<Id, Metric> directMetricsByCampaignId =
            initializeMetricMap(campaignIds);

        addCampaignMemberMetrics(campaignIds, directMetricsByCampaignId);
        addGiftTransactionMetrics(
            campaignIds,
            giftStatuses,
            startDate,
            endDate,
            includeSourceCodeAttribution == true,
            directMetricsByCampaignId
        );

        CampaignNode rootNode = buildNode(
            campaignId,
            campaignById,
            childrenByParentId,
            directMetricsByCampaignId
        );

        return new List<CampaignNode>{ rootNode };
    }

    private static CampaignNode buildNode(
        Id campaignId,
        Map<Id, Campaign> campaignById,
        Map<Id, List<Id>> childrenByParentId,
        Map<Id, Metric> directMetricsByCampaignId
    ) {
        Campaign campaign = campaignById.get(campaignId);
        Metric directMetric = getMetric(campaignId, directMetricsByCampaignId);

        CampaignNode node = new CampaignNode();

        node.id = String.valueOf(campaign.Id);
        node.campaignName = campaign.Name;
        node.campaignUrl = '/' + campaign.Id;
        node.type = campaign.Type;
        node.status = campaign.Status;
        node.isActive = campaign.IsActive;
        node.startDate = campaign.StartDate;
        node.endDate = campaign.EndDate;

        node.membersInCampaign = directMetric.members;
        node.responsesInCampaign = directMetric.responses;
     node.giftsInCampaign = directMetric.gifts;
node.donorsInCampaign = directMetric.donors;

// Existing filtered value, usually Paid only
node.giftValueInCampaign = directMetric.amount;

// New all-status donation value
node.allGiftValueInCampaign = directMetric.allAmount;

node.membersInHierarchy = node.membersInCampaign;
node.responsesInHierarchy = node.responsesInCampaign;
node.giftsInHierarchy = node.giftsInCampaign;
node.donorsInHierarchy = node.donorsInCampaign;

node.giftValueInHierarchy = node.giftValueInCampaign;
node.allGiftValueInHierarchy = node.allGiftValueInCampaign;

        node.children = new List<CampaignNode>();

        if (childrenByParentId.containsKey(campaignId)) {
            for (Id childId : childrenByParentId.get(campaignId)) {
                CampaignNode childNode = buildNode(
                    childId,
                    campaignById,
                    childrenByParentId,
                    directMetricsByCampaignId
                );

                node.children.add(childNode);

                    node.membersInHierarchy += childNode.membersInHierarchy;
                    node.responsesInHierarchy += childNode.responsesInHierarchy;
                    node.giftsInHierarchy += childNode.giftsInHierarchy;
                    node.donorsInHierarchy += childNode.donorsInHierarchy;

                    node.giftValueInHierarchy += childNode.giftValueInHierarchy;
                    node.allGiftValueInHierarchy += childNode.allGiftValueInHierarchy;
            }
        }

        return node;
    }

    private static Map<Id, Metric> initializeMetricMap(Set<Id> campaignIds) {
        Map<Id, Metric> result = new Map<Id, Metric>();

        for (Id campaignId : campaignIds) {
            result.put(campaignId, new Metric());
        }

        return result;
    }

    private static void addCampaignMemberMetrics(
        Set<Id> campaignIds,
        Map<Id, Metric> metricsByCampaignId
    ) {
        if (campaignIds == null || campaignIds.isEmpty()) {
            return;
        }

        for (AggregateResult ar : [
            SELECT CampaignId campaignId, COUNT(Id) memberCount
            FROM CampaignMember
            WHERE CampaignId IN :campaignIds
            GROUP BY CampaignId
        ]) {
            Id campaignId = (Id) ar.get('campaignId');
            getMetric(campaignId, metricsByCampaignId).members =
                toInteger(ar.get('memberCount'));
        }

        for (AggregateResult ar : [
            SELECT CampaignId campaignId, COUNT(Id) responseCount
            FROM CampaignMember
            WHERE CampaignId IN :campaignIds
            AND HasResponded = true
            GROUP BY CampaignId
        ]) {
            Id campaignId = (Id) ar.get('campaignId');
            getMetric(campaignId, metricsByCampaignId).responses =
                toInteger(ar.get('responseCount'));
        }
    }

    private static void addGiftTransactionMetrics(
        Set<Id> campaignIds,
        Set<String> giftStatuses,
        Date startDate,
        Date endDate,
        Boolean includeSourceCodeAttribution,
        Map<Id, Metric> metricsByCampaignId
    ) {
        if (campaignIds == null || campaignIds.isEmpty()) {
            return;
        }

        Schema.SObjectType giftType =
            Schema.getGlobalDescribe().get('GiftTransaction');

        if (giftType == null) {
            return;
        }

        Map<String, Schema.SObjectField> giftFields =
            giftType.getDescribe().fields.getMap();

        if (!giftFields.containsKey('CampaignId')) {
            return;
        }

            String amountField = giftFields.containsKey('CurrentAmount')
            ? 'CurrentAmount'
            : 'OriginalAmount';

            if (!giftFields.containsKey(amountField)) {
            return;
            }

            // For audit total, OriginalAmount is usually better because it represents
            // the submitted / original donation value, regardless of payment status.
            // Change this to CurrentAmount if you want net/current value instead.
            String allDonationAmountField = giftFields.containsKey('OriginalAmount')
            ? 'OriginalAmount'
    : amountField;

        Boolean hasDonorId = giftFields.containsKey('DonorId');
        Boolean hasStatus = giftFields.containsKey('Status');
        Boolean hasTransactionDate = giftFields.containsKey('TransactionDate');

        String directSoql =
            'SELECT CampaignId campaignId, COUNT(Id) giftCount';

        if (hasDonorId) {
            directSoql += ', COUNT_DISTINCT(DonorId) donorCount';
        }

        directSoql +=
            ', SUM(' + amountField + ') amountTotal' +
            ' FROM GiftTransaction' +
            ' WHERE CampaignId IN :campaignIds';

        if (hasStatus && !giftStatuses.isEmpty()) {
            directSoql += ' AND Status IN :giftStatuses';
        }

        if (hasTransactionDate && startDate != null) {
            directSoql += ' AND TransactionDate >= :startDate';
        }

        if (hasTransactionDate && endDate != null) {
            directSoql += ' AND TransactionDate <= :endDate';
        }

        directSoql += ' GROUP BY CampaignId';

        List<AggregateResult> directResults = Database.query(directSoql);

        for (AggregateResult ar : directResults) {
            Id campaignId = (Id) ar.get('campaignId');

            Metric metric = getMetric(campaignId, metricsByCampaignId);

            metric.gifts += toInteger(ar.get('giftCount'));

            if (hasDonorId) {
                metric.donors += toInteger(ar.get('donorCount'));
            }

            metric.amount += toDecimal(ar.get('amountTotal'));
        }

        if (includeSourceCodeAttribution) {
            addSourceCodeGiftMetrics(
                campaignIds,
                giftStatuses,
                startDate,
                endDate,
                amountField,
                hasDonorId,
                hasStatus,
                hasTransactionDate,
                giftFields,
                metricsByCampaignId
            );
        }

        addAllGiftValueMetrics(
    campaignIds,
    startDate,
    endDate,
    includeSourceCodeAttribution,
    allDonationAmountField,
    hasTransactionDate,
    giftFields,
    metricsByCampaignId
);
    }

    private static void addSourceCodeGiftMetrics(
        Set<Id> campaignIds,
        Set<String> giftStatuses,
        Date startDate,
        Date endDate,
        String amountField,
        Boolean hasDonorId,
        Boolean hasStatus,
        Boolean hasTransactionDate,
        Map<String, Schema.SObjectField> giftFields,
        Map<Id, Metric> metricsByCampaignId
    ) {
        if (!giftFields.containsKey('OutreachSourceCodeId')) {
            return;
        }

        if (!Schema.getGlobalDescribe().containsKey('OutreachSourceCode')) {
            return;
        }

        Map<Id, Id> sourceCodeToCampaignId = new Map<Id, Id>();

        List<SObject> sourceCodes = Database.query(
            'SELECT Id, CampaignId ' +
            'FROM OutreachSourceCode ' +
            'WHERE CampaignId IN :campaignIds'
        );

        for (SObject sourceCode : sourceCodes) {
            Id sourceCodeId = (Id) sourceCode.get('Id');
            Id campaignId = (Id) sourceCode.get('CampaignId');

            if (sourceCodeId != null && campaignId != null) {
                sourceCodeToCampaignId.put(sourceCodeId, campaignId);
            }
        }

        if (sourceCodeToCampaignId.isEmpty()) {
            return;
        }

        Set<Id> sourceCodeIds = sourceCodeToCampaignId.keySet();

        String soql =
            'SELECT OutreachSourceCodeId sourceCodeId, COUNT(Id) giftCount';

        if (hasDonorId) {
            soql += ', COUNT_DISTINCT(DonorId) donorCount';
        }

        soql +=
            ', SUM(' + amountField + ') amountTotal' +
            ' FROM GiftTransaction' +
            ' WHERE CampaignId = null' +
            ' AND OutreachSourceCodeId IN :sourceCodeIds';

        if (hasStatus && !giftStatuses.isEmpty()) {
            soql += ' AND Status IN :giftStatuses';
        }

        if (hasTransactionDate && startDate != null) {
            soql += ' AND TransactionDate >= :startDate';
        }

        if (hasTransactionDate && endDate != null) {
            soql += ' AND TransactionDate <= :endDate';
        }

        soql += ' GROUP BY OutreachSourceCodeId';

        List<AggregateResult> results = Database.query(soql);

        for (AggregateResult ar : results) {
            Id sourceCodeId = (Id) ar.get('sourceCodeId');
            Id campaignId = sourceCodeToCampaignId.get(sourceCodeId);

            if (campaignId == null) {
                continue;
            }

            Metric metric = getMetric(campaignId, metricsByCampaignId);

            metric.gifts += toInteger(ar.get('giftCount'));

            if (hasDonorId) {
                metric.donors += toInteger(ar.get('donorCount'));
            }

            metric.amount += toDecimal(ar.get('amountTotal'));
        }
    }

    private static Metric getMetric(
        Id campaignId,
        Map<Id, Metric> metricsByCampaignId
    ) {
        if (!metricsByCampaignId.containsKey(campaignId)) {
            metricsByCampaignId.put(campaignId, new Metric());
        }

        return metricsByCampaignId.get(campaignId);
    }

    private static Set<String> parseStatuses(String giftStatusesCsv) {
        Set<String> statuses = new Set<String>();

        if (String.isBlank(giftStatusesCsv)) {
            statuses.add('Paid');
            return statuses;
        }

        for (String rawStatus : giftStatusesCsv.split(',')) {
            String cleaned = rawStatus == null ? null : rawStatus.trim();

            if (!String.isBlank(cleaned)) {
                statuses.add(cleaned);
            }
        }

        if (statuses.isEmpty()) {
            statuses.add('Paid');
        }

        return statuses;
    }

    private static Date parseDate(String value) {
        if (String.isBlank(value)) {
            return null;
        }

        try {
            return Date.valueOf(value.trim());
        } catch (Exception e) {
            return null;
        }
    }

    private static Integer toInteger(Object value) {
        if (value == null) {
            return 0;
        }

        return Integer.valueOf(String.valueOf(value));
    }

    private static Decimal toDecimal(Object value) {
        if (value == null) {
            return 0;
        }

        return (Decimal) value;
    }

private static void addAllGiftValueMetrics(
    Set<Id> campaignIds,
    Date startDate,
    Date endDate,
    Boolean includeSourceCodeAttribution,
    String allDonationAmountField,
    Boolean hasTransactionDate,
    Map<String, Schema.SObjectField> giftFields,
    Map<Id, Metric> metricsByCampaignId
) {
    if (campaignIds == null || campaignIds.isEmpty()) {
        return;
    }

    String soql =
        'SELECT CampaignId campaignId, SUM(' + allDonationAmountField + ') allAmountTotal' +
        ' FROM GiftTransaction' +
        ' WHERE CampaignId IN :campaignIds';

    // Date filters still apply to the audit total.
    // Status filter intentionally does NOT apply.
    if (hasTransactionDate && startDate != null) {
        soql += ' AND TransactionDate >= :startDate';
    }

    if (hasTransactionDate && endDate != null) {
        soql += ' AND TransactionDate <= :endDate';
    }

    soql += ' GROUP BY CampaignId';

    List<AggregateResult> results = Database.query(soql);

    for (AggregateResult ar : results) {
        Id campaignId = (Id) ar.get('campaignId');

        Metric metric = getMetric(campaignId, metricsByCampaignId);
        metric.allAmount += toDecimal(ar.get('allAmountTotal'));
    }

    if (includeSourceCodeAttribution == true) {
        addSourceCodeAllGiftValueMetrics(
            campaignIds,
            startDate,
            endDate,
            allDonationAmountField,
            hasTransactionDate,
            giftFields,
            metricsByCampaignId
        );
    }
}

private static void addSourceCodeAllGiftValueMetrics(
    Set<Id> campaignIds,
    Date startDate,
    Date endDate,
    String allDonationAmountField,
    Boolean hasTransactionDate,
    Map<String, Schema.SObjectField> giftFields,
    Map<Id, Metric> metricsByCampaignId
) {
    if (!giftFields.containsKey('OutreachSourceCodeId')) {
        return;
    }

    if (!Schema.getGlobalDescribe().containsKey('OutreachSourceCode')) {
        return;
    }

    Map<Id, Id> sourceCodeToCampaignId = new Map<Id, Id>();

    List<SObject> sourceCodes = Database.query(
        'SELECT Id, CampaignId ' +
        'FROM OutreachSourceCode ' +
        'WHERE CampaignId IN :campaignIds'
    );

    for (SObject sourceCode : sourceCodes) {
        Id sourceCodeId = (Id) sourceCode.get('Id');
        Id campaignId = (Id) sourceCode.get('CampaignId');

        if (sourceCodeId != null && campaignId != null) {
            sourceCodeToCampaignId.put(sourceCodeId, campaignId);
        }
    }

    if (sourceCodeToCampaignId.isEmpty()) {
        return;
    }

    Set<Id> sourceCodeIds = sourceCodeToCampaignId.keySet();

    String soql =
        'SELECT OutreachSourceCodeId sourceCodeId, SUM(' + allDonationAmountField + ') allAmountTotal' +
        ' FROM GiftTransaction' +
        ' WHERE CampaignId = null' +
        ' AND OutreachSourceCodeId IN :sourceCodeIds';

    // Date filters still apply.
    // Status filter intentionally does NOT apply.
    if (hasTransactionDate && startDate != null) {
        soql += ' AND TransactionDate >= :startDate';
    }

    if (hasTransactionDate && endDate != null) {
        soql += ' AND TransactionDate <= :endDate';
    }

    soql += ' GROUP BY OutreachSourceCodeId';

    List<AggregateResult> results = Database.query(soql);

    for (AggregateResult ar : results) {
        Id sourceCodeId = (Id) ar.get('sourceCodeId');
        Id campaignId = sourceCodeToCampaignId.get(sourceCodeId);

        if (campaignId == null) {
            continue;
        }

        Metric metric = getMetric(campaignId, metricsByCampaignId);
        metric.allAmount += toDecimal(ar.get('allAmountTotal'));
    }
}





   private class Metric {
    public Integer members = 0;
    public Integer responses = 0;
    public Integer gifts = 0;
    public Integer donors = 0;

    // Existing filtered amount, for example only Paid gifts
    public Decimal amount = 0;

    // New amount: all gifts regardless of Status
    public Decimal allAmount = 0;
}

    public class CampaignNode {
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public String campaignName { get; set; }
        @AuraEnabled public String campaignUrl { get; set; }

        @AuraEnabled public String type { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Boolean isActive { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }

        @AuraEnabled public Integer membersInCampaign { get; set; }
        @AuraEnabled public Integer membersInHierarchy { get; set; }

        @AuraEnabled public Integer responsesInCampaign { get; set; }
        @AuraEnabled public Integer responsesInHierarchy { get; set; }

        @AuraEnabled public Integer giftsInCampaign { get; set; }
        @AuraEnabled public Integer giftsInHierarchy { get; set; }

        @AuraEnabled public Integer donorsInCampaign { get; set; }
        @AuraEnabled public Integer donorsInHierarchy { get; set; }


        @AuraEnabled public Decimal giftValueInCampaign { get; set; }
        @AuraEnabled public Decimal giftValueInHierarchy { get; set; }

        @AuraEnabled public Decimal allGiftValueInCampaign { get; set; }
        @AuraEnabled public Decimal allGiftValueInHierarchy { get; set; }



        @AuraEnabled public List<CampaignNode> children { get; set; }
    }
}