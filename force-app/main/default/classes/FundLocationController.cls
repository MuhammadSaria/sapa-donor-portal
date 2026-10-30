public with sharing class FundLocationController {
    
    public class FundResult {
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public String mainField { get; set; } 
        @AuraEnabled public String subField { get; set; }  
        @AuraEnabled public String locations { get; set; } 
    }
    
    public class SearchRequest {
        @AuraEnabled public String objectApiName { get; set; }
        @AuraEnabled public String fieldApiName { get; set; }
        @AuraEnabled public String searchString { get; set; }
        @AuraEnabled public List<String> excludedIds { get; set; } // NEW
    }

    @AuraEnabled(cacheable=true)
    public static List<FundResult> getFunds(SearchRequest inputWrapper) {
        List<FundResult> results = new List<FundResult>();
        
        try {
            String objName = String.escapeSingleQuotes(inputWrapper.objectApiName);
            String query =
    'SELECT Id, Name, Location__c ' +
    'FROM ' + objName +
    ' WHERE IsActive = true';
            
            // Build the WHERE clause dynamically
            String whereClause = '';
            
            if (String.isNotBlank(inputWrapper.searchString)) {
                String searchTerm = '\'%' + String.escapeSingleQuotes(inputWrapper.searchString.trim()) + '%\'';
                whereClause += 'Name LIKE ' + searchTerm;
            }
            
            // Bring the list into local scope so dynamic SOQL can bind to it
            List<String> excludedIdsList = new List<String>();
            if (inputWrapper.excludedIds != null && !inputWrapper.excludedIds.isEmpty()) {
                excludedIdsList = inputWrapper.excludedIds;
                
                if (String.isNotBlank(whereClause)) {
                    whereClause += ' AND ';
                }
                // Bind variable :excludedIdsList works here because it's in scope
                whereClause += 'Id NOT IN :excludedIdsList';
            }
            
            if (String.isNotBlank(whereClause)) {
               query += ' AND ' + whereClause;
            }
            
            query += ' WITH SECURITY_ENFORCED LIMIT 5';
            System.debug('Executing Query: ' + query);
            
            for(SObject s : Database.query(query)) {
                FundResult wrapper = new FundResult();
                wrapper.id = (String)s.get('Id');
                wrapper.mainField = (String)s.get('Name');
                wrapper.subField = ''; 
                
                try {
                    wrapper.locations = (String)s.get('Location__c');
                } catch (Exception ex) {
                    wrapper.locations = '';
                }
                
                results.add(wrapper);
            }
            
        } catch (Exception e) {
            System.debug('Error in FundLocationController: ' + e.getMessage());
        }
        
        return results;
    }
}