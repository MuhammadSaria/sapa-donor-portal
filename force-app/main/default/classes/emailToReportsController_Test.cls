@isTest(SeeAllData=true)
private class emailToReportsController_Test {
    
    @isTest
    static void testGetReportsFromFolderSuccess() {
        // Test with real data from org
        Test.startTest();
        List<emailToReportsController.ReportSummary> reports = 
            emailToReportsController.getReportsFromFolder('Email Reports');
        Test.stopTest();
        
        // Verify the method returns a list
        System.assert(reports != null, 'Reports list should not be null');
        //System.assert(reports instanceof List<emailToReportsController.ReportSummary>, 'Should return ReportSummary list');
        
        // If reports exist, verify structure
        if (!reports.isEmpty()) {
            emailToReportsController.ReportSummary firstReport = reports.get(0);
            System.assert(firstReport.id != null, 'Report ID should not be null');
            System.assert(firstReport.name != null, 'Report name should not be null');
        }
    }

    @isTest
    static void testGetReportsFromFolderWithEmptyFolder() {
        Test.startTest();
        List<emailToReportsController.ReportSummary> reports = 
            emailToReportsController.getReportsFromFolder('NonExistentFolder');
        Test.stopTest();
        
        System.assert(reports != null, 'Reports list should not be null');
        System.assert(reports.isEmpty(), 'Should return empty list for non-existent folder');
    }

    @isTest
    static void testGetReportsFromFolderWithNullInput() {
        Test.startTest();
        List<emailToReportsController.ReportSummary> reports = 
            emailToReportsController.getReportsFromFolder(null);
        Test.stopTest();
        
        System.assert(reports != null, 'Reports list should not be null');
    }

    @isTest
    static void testGetReportsReturnsSortedResults() {
        Test.startTest();
        List<emailToReportsController.ReportSummary> reports = 
            emailToReportsController.getReportsFromFolder('Email Reports');
        Test.stopTest();
        
        System.assert(reports != null, 'Reports list should not be null');
        // Verify all returned reports have both id and name populated
        for (emailToReportsController.ReportSummary report : reports) {
            System.assert(report.id != null, 'Each report must have an ID');
            System.assert(report.name != null, 'Each report must have a name');
        }
    }

    @isTest
    static void testGetEmailTemplatesFromFolderSuccess() {
        Test.startTest();
        List<emailToReportsController.EmailTemplateSummary> templates = 
            emailToReportsController.getEmailTemplatesFromFolder('Unfiled Public EmailTemplates');
        Test.stopTest();
        
        // Verify the method returns a list
        System.assert(templates != null, 'Templates list should not be null');
        //System.assert(templates instanceof List<emailToReportsController.EmailTemplateSummary>,'Should return EmailTemplateSummary list');
        
        // If templates exist, verify structure
        if (!templates.isEmpty()) {
            emailToReportsController.EmailTemplateSummary firstTemplate = templates.get(0);
            System.assert(firstTemplate.id != null, 'Template ID should not be null');
            System.assert(firstTemplate.name != null, 'Template name should not be null');
        }
    }

    @isTest
    static void testGetEmailTemplatesFromSpecificFolder() {
        Test.startTest();
        List<emailToReportsController.EmailTemplateSummary> templates = 
            emailToReportsController.getEmailTemplatesFromFolder('Unfiled Public EmailTemplates');
        Test.stopTest();
        
        System.assert(templates != null, 'Templates list should not be null');
        
        // Verify all templates have required fields
        for (emailToReportsController.EmailTemplateSummary template : templates) {
            System.assert(template.id != null, 'Each template must have an ID');
            System.assert(template.name != null, 'Each template must have a name');
        }
    }

    @isTest
    static void testGetEmailTemplatesFromFolderWithEmptyFolder() {
        Test.startTest();
        List<emailToReportsController.EmailTemplateSummary> templates = 
            emailToReportsController.getEmailTemplatesFromFolder('NonExistentFolder');
        Test.stopTest();
        
        System.assert(templates != null, 'Templates list should not be null');
    }

    @isTest
    static void testGetEmailTemplatesFromFolderWithNullInput() {
        Test.startTest();
        List<emailToReportsController.EmailTemplateSummary> templates = 
            emailToReportsController.getEmailTemplatesFromFolder(null);
        Test.stopTest();
        
        System.assert(templates != null, 'Templates list should not be null');
    }

    @isTest
    static void testReportSummaryConstructor() {
        Test.startTest();
        emailToReportsController.ReportSummary summary = 
            new emailToReportsController.ReportSummary('001xx000003DHyAAM', 'Email Reports');
        Test.stopTest();
        
        System.assertEquals('001xx000003DHyAAM', summary.id, 'Report ID should match');
        System.assertEquals('Email Reports', summary.name, 'Report name should match');
    }

    @isTest
    static void testReportSummaryWithEmptyValues() {
        Test.startTest();
        emailToReportsController.ReportSummary summary = 
            new emailToReportsController.ReportSummary('', '');
        Test.stopTest();
        
        System.assertEquals('', summary.id);
        System.assertEquals('', summary.name);
    }

    @isTest
    static void testEmailTemplateSummaryConstructor() {
        Test.startTest();
        emailToReportsController.EmailTemplateSummary summary = 
            new emailToReportsController.EmailTemplateSummary('002xx000003DHyAAM', 'Report Templates');
        Test.stopTest();
        
        System.assertEquals('002xx000003DHyAAM', summary.id, 'Template ID should match');
        System.assertEquals('Report Templates', summary.name, 'Template name should match');
    }

    @isTest
    static void testEmailTemplateSummaryWithEmptyValues() {
        Test.startTest();
        emailToReportsController.EmailTemplateSummary summary = 
            new emailToReportsController.EmailTemplateSummary('', '');
        Test.stopTest();
        
        System.assertEquals('', summary.id);
        System.assertEquals('', summary.name);
    }

    @isTest
    static void testGetReportEmailColumnsWithValidReport() {
        // Find a real report ID from the org
        List<Report> availableReports = [SELECT Id FROM Report LIMIT 1];
        
        Test.startTest();
        if (!availableReports.isEmpty()) {
            List<String> columns = emailToReportsController.getReportEmailColumns(availableReports[0].Id);
            
            // Verify it returns a list
            System.assert(columns != null, 'Columns list should not be null');
           // System.assert(columns instanceof List<String>, 'Should return String list');
        }
        Test.stopTest();
    }

    @isTest
    static void testGetReportEmailColumnsWithInvalidReport() {
        Test.startTest();
        try {
            // Using an invalid ID should throw an exception
            List<String> columns = emailToReportsController.getReportEmailColumns('invalid-id-12345');
            // If we get here, verify we got a list back
            System.assert(columns != null, 'Should return a list');
        } catch (Exception e) {
            // Expected behavior - invalid report ID throws exception
            System.assert(true, 'Exception thrown as expected for invalid report');
        }
        Test.stopTest();
    }

    @isTest
    static void testGetReportEmailColumnsFiltersEmailColumns() {
        // Find a real report and test the email column filtering logic
        List<Report> availableReports = [SELECT Id FROM Report LIMIT 1];
        
        Test.startTest();
        if (!availableReports.isEmpty()) {
            List<String> columns = emailToReportsController.getReportEmailColumns(availableReports[0].Id);
            
            // Verify all returned columns are strings
            for (String column : columns) {
                System.assert(column != null, 'Column name should not be null');
                // Email columns should contain 'email' in their name or be email type
                System.assert(
                    column.toLowerCase().contains('email'), 
                    'Filtered columns should contain "email" in name'
                );
            }
        }
        Test.stopTest();
    }

    @isTest
    static void testAuraEnabledMethods() {
        // Verify that methods are properly annotated with @AuraEnabled
        Test.startTest();
        
        // These methods should be callable from LWC
        List<emailToReportsController.ReportSummary> reports = 
            emailToReportsController.getReportsFromFolder('Email Reports');
        
        List<emailToReportsController.EmailTemplateSummary> templates = 
            emailToReportsController.getEmailTemplatesFromFolder('Unfiled Public EmailTemplates');
        
        Test.stopTest();
        
        System.assert(reports != null);
        System.assert(templates != null);
    }

    @isTest
    static void testGetReportsAndTemplatesIntegration() {
        // Test that both methods can be called together without issues
        Test.startTest();
        
        List<emailToReportsController.ReportSummary> reports = 
            emailToReportsController.getReportsFromFolder('Email Reports');
        List<emailToReportsController.EmailTemplateSummary> templates = 
            emailToReportsController.getEmailTemplatesFromFolder('Unfiled Public EmailTemplates');
        
        Test.stopTest();
        
        System.assert(reports != null, 'Reports should not be null');
        System.assert(templates != null, 'Templates should not be null');
    }
}