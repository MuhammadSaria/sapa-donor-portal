/**
 * Routes LaunchGood imported designations to GiftDesignation funds using URL defaults
 * and optional Special Request overrides.
 */
public with sharing class LaunchGoodRoutingService {

    private static final String STATUS_MATCHED = 'Matched';
    private static final String STATUS_MISSING_MAPPING = 'Missing Mapping';
    private static final String STATUS_SKIPPED = 'Skipped';
    private static final String ROUTING_KEY_SEPARATOR = '|';

    /**
     * Routes Gift Transaction Designations in memory before DML.
     *
     * @param allocations Gift Transaction Designations to route.
     */
    public static void route(List<GiftTransactionDesignation> allocations) {
        processRouting((List<SObject>) allocations);
    }

    /**
     * Routes Gift Default Designations in memory before DML.
     *
     * @param allocations Gift Default Designations to route.
     */
    public static void route(List<GiftDefaultDesignation> allocations) {
        processRouting((List<SObject>) allocations);
    }

    private static void processRouting(List<SObject> allocations) {
        if (allocations == null || allocations.isEmpty()) {
            return;
        }

        Set<String> projectUrls = collectProjectUrls(allocations);

        if (projectUrls.isEmpty()) {
            return;
        }

        RoutingIndex routingIndex = buildRoutingIndex(projectUrls);
        List<LaunchGood_Donation_Fund__c> mappingsToCreate = new List<LaunchGood_Donation_Fund__c>();
        Set<String> createdUrls = new Set<String>();

        for (SObject allocation : allocations) {
            if (allocation == null) {
                continue;
            }

            Boolean isOmaticImport = (Boolean) allocation.get('Omatic_Import__c');
            String url = normaliseUrl((String) allocation.get('LaunchGood_Project_URL__c'));

            if (isOmaticImport != true || url == null) {
                allocation.put('Fund_Match_Status__c', STATUS_SKIPPED);
                continue;
            }

            String specialRequest = normaliseText((String) allocation.get('Special_Request__c'));
            String selectedKey = selectRoutingKey(routingIndex, url, specialRequest);

            if (selectedKey == null) {
                allocation.put('Fund_Match_Status__c', STATUS_MISSING_MAPPING);

                String defaultKey = buildRouteKey(url, null);
                if (!routingIndex.knownRouteKeys.contains(defaultKey) && !createdUrls.contains(url)) {
                    mappingsToCreate.add(new LaunchGood_Donation_Fund__c(
                        Project_URL__c = url,
                        Active__c = false
                    ));
                    createdUrls.add(url);
                }

                continue;
            }

            if (routingIndex.duplicateActiveRouteKeys.contains(selectedKey)) {
                allocation.put('Fund_Match_Status__c', STATUS_MISSING_MAPPING);
                continue;
            }

            LaunchGood_Donation_Fund__c mapping = routingIndex.activeRouteByKey.get(selectedKey);

            if (mapping == null || mapping.Funds__c == null) {
                allocation.put('Fund_Match_Status__c', STATUS_MISSING_MAPPING);
                continue;
            }

            allocation.put('GiftDesignationId', mapping.Funds__c);
            allocation.put('Locations__c', mapping.Location__c);
            allocation.put('Fund_Match_Status__c', STATUS_MATCHED);
        }

        if (!mappingsToCreate.isEmpty()) {
            Database.insert(mappingsToCreate, false);
        }
    }

    private static Set<String> collectProjectUrls(List<SObject> allocations) {
        Set<String> projectUrls = new Set<String>();

        for (SObject allocation : allocations) {
            if (allocation == null) {
                continue;
            }

            String projectUrl = normaliseUrl((String) allocation.get('LaunchGood_Project_URL__c'));

            if (projectUrl == null) {
                allocation.put('Fund_Match_Status__c', STATUS_SKIPPED);
                continue;
            }

            projectUrls.add(projectUrl);
        }

        return projectUrls;
    }

    private static RoutingIndex buildRoutingIndex(Set<String> projectUrls) {
        RoutingIndex routingIndex = new RoutingIndex();

        for (LaunchGood_Donation_Fund__c route : [
            SELECT Id,
                   Project_URL__c,
                   Special_Request__c,
                   Funds__c,
                   Location__c,
                   Active__c
            FROM LaunchGood_Donation_Fund__c
            WHERE Project_URL__c IN :projectUrls
        ]) {
            String url = normaliseUrl(route.Project_URL__c);

            if (url == null) {
                continue;
            }

            String requestKey = normaliseText(route.Special_Request__c);
            String routeKey = buildRouteKey(url, requestKey);
            routingIndex.knownRouteKeys.add(routeKey);

            if (route.Active__c != true) {
                continue;
            }

            if (routingIndex.activeRouteByKey.containsKey(routeKey)) {
                routingIndex.duplicateActiveRouteKeys.add(routeKey);
                continue;
            }

            routingIndex.activeRouteByKey.put(routeKey, route);
        }

        return routingIndex;
    }

    private static String selectRoutingKey(
        RoutingIndex routingIndex,
        String url,
        String specialRequest
    ) {
        String defaultKey = buildRouteKey(url, null);

        if (String.isBlank(specialRequest)) {
            return routingIndex.knownRouteKeys.contains(defaultKey) ? defaultKey : null;
        }

        String exactKey = buildRouteKey(url, specialRequest);

        if (routingIndex.knownRouteKeys.contains(exactKey)) {
            return exactKey;
        }

        return routingIndex.knownRouteKeys.contains(defaultKey) ? defaultKey : null;
    }

    private static String buildRouteKey(String url, String specialRequest) {
        return url + ROUTING_KEY_SEPARATOR + (specialRequest == null ? '' : specialRequest);
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

    private class RoutingIndex {
        private Map<String, LaunchGood_Donation_Fund__c> activeRouteByKey =
            new Map<String, LaunchGood_Donation_Fund__c>();
        private Set<String> duplicateActiveRouteKeys = new Set<String>();
        private Set<String> knownRouteKeys = new Set<String>();
    }
}