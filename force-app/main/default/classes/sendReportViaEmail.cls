public with sharing class sendReportViaEmail {


@AuraEnabled(cacheable=true)
public static List<Map<String, String>> getFromEmailOptions(String defaultOrgWideEmail) {
    // We return as [{label:'', value:''}, ...] to match lightning-combobox
    List<Map<String, String>> opts = new List<Map<String, String>>();

    // Option 1: default Org-Wide (if exists)
    OrgWideEmailAddress defaultOwea = null;
    if (!String.isBlank(defaultOrgWideEmail)) {
        List<OrgWideEmailAddress> found = [
            SELECT Id, Address, DisplayName
            FROM OrgWideEmailAddress
            WHERE Address = :defaultOrgWideEmail
            LIMIT 1
        ];
        if (!found.isEmpty()) defaultOwea = found[0];
    }

    if (defaultOwea != null) {
        opts.add(new Map<String, String>{
            'label' => (String.isBlank(defaultOwea.DisplayName) ? defaultOwea.Address : defaultOwea.DisplayName + ' <' + defaultOwea.Address + '>'),
            'value' => 'OWEA:' + defaultOwea.Id
        });
    }

    // Option 2: current user
    User u = [SELECT Email, Name FROM User WHERE Id = :UserInfo.getUserId()];
    opts.add(new Map<String, String>{
        'label' => 'My Email (' + u.Name + ' - ' + u.Email + ')',
        'value' => 'USER'
    });

    // Optionally: add other OWEAs too (commented out for now)
    // for (OrgWideEmailAddress o : [SELECT Id, Address, DisplayName FROM OrgWideEmailAddress ORDER BY Address]) {
    //     opts.add(new Map<String, String>{
    //         'label' => (String.isBlank(o.DisplayName) ? o.Address : o.DisplayName + ' <' + o.Address + '>'),
    //         'value' => 'OWEA:' + o.Id
    //     });
    // }

    return opts;
}


    @AuraEnabled
    public static void sendReportEmailsWithTable(Id reportId, Id templateId, String selectedEmailColumn, String fromOption) {
        // Run the report
        Reports.ReportResults reportInfo = Reports.ReportManager.runReport(reportId, true);
        Reports.ReportExtendedMetadata meta = reportInfo.getReportExtendedMetadata();
        Map<String, Reports.DetailColumn> colMap = meta.getDetailColumnInfo();
        Map<String, Reports.ReportFact> factMap = reportInfo.getFactMap();

        Reports.ReportFactWithDetails factDetails;
        if (factMap.containsKey('T!T')) {
            factDetails = (Reports.ReportFactWithDetails) factMap.get('T!T');
        } else {
            for (Reports.ReportFact rf : factMap.values()) {
                if (rf instanceof Reports.ReportFactWithDetails) {
                    factDetails = (Reports.ReportFactWithDetails) rf;
                    break;
                }
            }
        }

        if (factDetails == null) {
            throw new AuraHandledException('No detail rows found in report.');
        }

        // Fetch Email Template
        EmailTemplate template = [
            SELECT Id, Subject, HtmlValue, Body 
            FROM EmailTemplate 
            WHERE Id = :templateId
        ];

        String subject = template.Subject;
        String htmlTemplate = template.HtmlValue != null ? template.HtmlValue : template.Body;

        // Get column order
        List<String> columnOrder = new List<String>();
        for (String key : colMap.keySet()) {
            columnOrder.add(key);
        }

        // Prepare email messages
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();

        // Loop through each report row
        for (Reports.ReportDetailRow row : factDetails.getRows()) {
            List<String> cellValues = new List<String>();
            String email = null;

            Integer index = 0;
            for (Reports.ReportDataCell cell : row.getDataCells()) {
                String value = cell.getLabel() != null ? cell.getLabel() : '';
                cellValues.add(value);

                // Identify email from selected column
                Reports.DetailColumn col = colMap.get(columnOrder[index]);
                if (col.getLabel() == selectedEmailColumn) {
                    email = value;
                }
                index++;
            }

            if (email == null || !email.contains('@')) continue;

            // Replace merge placeholders {{column1}}, {{column2}}, etc.
            String personalizedBody = htmlTemplate;
            for (Integer i = 0; i < cellValues.size(); i++) {
                String placeholder = '{{column' + (i + 1) + '}}';
                personalizedBody = personalizedBody.replace(placeholder, cellValues[i]);
            }

            // Create email message
            Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
            msg.setToAddresses(new String[] { email });
            msg.setSubject(subject);
            msg.setHtmlBody(personalizedBody);

            // Apply From selection
            if (!String.isBlank(fromOption) && fromOption.startsWith('OWEA:')) {
            Id oweaId = (Id) fromOption.substring(5);
            msg.setOrgWideEmailAddressId(oweaId);
            }
            // else 'USER' => do nothing; Salesforce sends from current user
            emails.add(msg);
        }

        // Send all emails
        if (!emails.isEmpty()) {
            Messaging.sendEmail(emails);
        }
    }

    //preview
    @AuraEnabled(cacheable=false)
public static Map<String, Object> getEmailTemplatePreviewWithReport(Id reportId, Id templateId) {
   Reports.ReportResults reportInfo = Reports.ReportManager.runReport(reportId, true);
    Reports.ReportExtendedMetadata meta = reportInfo.getReportExtendedMetadata();
    Map<String, Reports.DetailColumn> colMap = meta.getDetailColumnInfo();
    Map<String, Reports.ReportFact> factMap = reportInfo.getFactMap();

    Reports.ReportFactWithDetails factDetails;
    if (factMap.containsKey('T!T')) {
        factDetails = (Reports.ReportFactWithDetails) factMap.get('T!T');
    } else {
        for (Reports.ReportFact rf : factMap.values()) {
            if (rf instanceof Reports.ReportFactWithDetails) {
                factDetails = (Reports.ReportFactWithDetails) rf;
                break;
            }
        }
    }

    EmailTemplate template = [
        SELECT Id, Subject, HtmlValue, Body
        FROM EmailTemplate
        WHERE Id = :templateId
    ];

    String subject = template.Subject;
    String htmlTemplate = template.HtmlValue != null ? template.HtmlValue : template.Body;

    List<String> columnOrder = new List<String>(colMap.keySet());

    List<List<String>> allRows = new List<List<String>>();

    if (factDetails != null) {
        for (Reports.ReportDetailRow row : factDetails.getRows()) {
            List<String> rowValues = new List<String>();
            for (Reports.ReportDataCell cell : row.getDataCells()) {
                rowValues.add(cell.getLabel() != null ? cell.getLabel() : '');
            }
            allRows.add(rowValues);
        }
    }

    Map<String, Object> result = new Map<String, Object>();
    result.put('subject', subject);
    result.put('template', htmlTemplate);
    result.put('rows', allRows);
    result.put('columnCount', columnOrder.size());

    return result;
}

}