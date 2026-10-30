public with sharing class emailToReportsController {
    
    @AuraEnabled(cacheable=true)
    public static List<ReportSummary> getReportsFromFolder(String folderName) {
        List<ReportSummary> reports = new List<ReportSummary>();
        for (Report r : [
           SELECT Id, Name, DeveloperName, NamespacePrefix, FolderName
            FROM Report Where FolderName =:folderName Order By FolderName DESC
        ]) {
            reports.add(new ReportSummary(r.Id, r.Name));
        }
        return reports;
    }

    @AuraEnabled(cacheable=true)
public static List<EmailTemplateSummary> getEmailTemplatesFromFolder(String folderName) {
    List<EmailTemplateSummary> templates = new List<EmailTemplateSummary>();
    //sandbox email template folder id = 00lQz000004U7eTIAS
    
    for (EmailTemplate t : [
        SELECT Id, Name, DeveloperName, Subject, Body
        FROM EmailTemplate
        WHERE FolderId = '00lVZ000001E2e5YAC'
    ]) {
        templates.add(new EmailTemplateSummary(t.Id, t.Name));
    }
    return templates;
}


@AuraEnabled(cacheable=true)
public static List<String> getReportEmailColumns(Id reportId) {
    Reports.ReportResults reportResults = Reports.ReportManager.runReport(reportId, false);
    Reports.ReportExtendedMetadata meta = reportResults.getReportExtendedMetadata();

    List<String> emailColumns = new List<String>();

    for (Reports.DetailColumn col : meta.getDetailColumnInfo().values()) {
        String label = col.getLabel();
        // Convert enum to string safely
        String dataType = String.valueOf(col.getDataType());

        // Include columns that contain 'Email' in label or are of email type
        if ((label != null && label.toLowerCase().contains('email')) || 
            (dataType != null && dataType.toLowerCase().contains('email'))) {
            emailColumns.add(label);
        }
    }

    return emailColumns;
}





public class EmailTemplateSummary {
    @AuraEnabled public String id;
    @AuraEnabled public String name;
    public EmailTemplateSummary(String i, String n) {
        id = i;
        name = n;
    }
}


    public class ReportSummary {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        public ReportSummary(String i, String n) {
            id = i;
            name = n;
        }
    }

}