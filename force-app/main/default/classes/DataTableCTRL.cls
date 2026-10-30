public without sharing class DataTableCTRL {
    @AuraEnabled(cacheable=true)
    public static wrapperCls getData()
    {
        wrapperCls wrapperObj = new wrapperCls();
        wrapperObj.LocationValues = getPicklistValues('GiftTransactionDesignation','Locations__c');
        wrapperObj.IntentionValues = getPicklistValues('GiftTransactionDesignation','Intention__c');
        wrapperObj.FundLocationValuesByName = getFundLocationValuesByName();
        system.debug('wrapperObj'+wrapperObj);
        return wrapperObj;

    }

    private static Map<String, List<String>> getFundLocationValuesByName() {
        Map<String, List<String>> fundLocations = new Map<String, List<String>>();

        for (GiftDesignation fund : [
            SELECT Name, Location__c
            FROM GiftDesignation
            WHERE Location__c != null
        ]) {
            List<String> locations = new List<String>();
            for (String location : fund.Location__c.split(';')) {
                String normalizedLocation = location.trim();
                if (String.isNotBlank(normalizedLocation)) {
                    locations.add(normalizedLocation);
                }
            }
            fundLocations.put(fund.Name, locations);
        }

        return fundLocations;
    }

    @AuraEnabled(cacheable=true)
    public static DatatableCtrl.Obj getPicklistValues(String objectApiName, String fieldApiName) {
        DatatableCtrl.Obj objWrap = new DatatableCtrl.Obj();

        
        try {
            // Get the SObject Type for the given object API name
            Schema.SObjectType sObjectType = Schema.getGlobalDescribe().get(objectApiName);
            system.debug(sObjectType);
            if (sObjectType != null) {
                // Get the field describe for the given field API name
                Schema.DescribeFieldResult fieldDescribe = sObjectType.getDescribe().fields.getMap().get(fieldApiName).getDescribe();
                
                    // If the field is a picklist, get its picklist values
                    List<Schema.PicklistEntry> picklistEntries = fieldDescribe.getPicklistValues();

                    for (Schema.PicklistEntry entry : picklistEntries) {
                        objWrap.label.add(entry.getlabel());
                        objWrap.values.add(entry.getValue());
                    }

                
            }
        } catch (Exception e) {
            // Handle any exceptions here
        }
        return objWrap;
    }
    public class wrapperCls
    {
        @AuraEnabled public DatatableCtrl.Obj LocationValues;
        @AuraEnabled public DatatableCtrl.Obj IntentionValues;
        @AuraEnabled public Map<String, List<String>> FundLocationValuesByName;

    }
    Public class Obj{
        @AuraEnabled publiC List<String>label{get;set;}
       @AuraEnabled publiC List<String> values{get;set;}

        public Obj()
        {
            label = new List<String>();
            values = new List<String>();
        }
    }
}