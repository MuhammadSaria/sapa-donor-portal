public with sharing class DonationPDFLWCController {
    public interface EmailSender { void send(Messaging.SingleEmailMessage message); }
    private class PlatformEmailSender implements EmailSender {
        public void send(Messaging.SingleEmailMessage message) {
            Messaging.sendEmail(new Messaging.SingleEmailMessage[]{message});
        }
    }
    @TestVisible private static EmailSender sender = new PlatformEmailSender();


    @AuraEnabled
    public static void sendEmail(Id accountId, Date fromDate, Date toDate) {
        
        String formattedFromDate = fromDate.format();
        String formattedToDate = toDate.format();
        
        Account account = [
            SELECT Id, Name, Preferred_Email__c, PersonEmail, Work_Email__c, Alternate_Email__c
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];

        // Generate PDF
        Blob pdfBlob = generatePDF(accountId, fromDate, toDate);
        if(pdfBlob != null){
            sendEmailWithPdf(account, pdfBlob, formattedFromDate, formattedToDate);

        }

        
           }

    public static Blob generatePDF(Id accountId, Date fromDate, Date toDate){
        PageReference pdfPage = Page.DonationSummaryPDF;
        pdfPage.getParameters().put('RecordId', accountId);
        pdfPage.getParameters().put('fromDate', String.valueOf(fromDate));
        pdfPage.getParameters().put('toDate', String.valueOf(toDate));
        
        system.debug('RecordId>>'+accountId);
        system.debug('fromDate>>'+fromDate);
        system.debug('toDate>>'+toDate);

        if(!Test.isRunningTest()){
            return pdfPage.getContentAsPDF();
        }
        return null;
    }

    public static void sendEmailWithPdf(Account account, Blob pdfBlob, String fromYear, String toYear) {
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        
        List<OrgWideEmailAddress> lstEmailAddress=[select Id from OrgWideEmailAddress WHERE Address='donorcare@sapa-usa.org'];
       
        
        String toAddress;
        if(account.Preferred_Email__c == 'Personal' && account.PersonEmail != null){
            toAddress = account.PersonEmail;
        } else if(account.Preferred_Email__c == 'Work' && account.Work_Email__c != null){
            toAddress = account.Work_Email__c;
        } else if(account.Preferred_Email__c == 'Alternate' && account.Alternate_Email__c != null){
            toAddress = account.Alternate_Email__c;
        }
        
        if(toAddress == null){
            return; // No valid email
        }

        email.setToAddresses(new String[] { toAddress });
        email.setOrgWideEmailAddressId(lstEmailAddress[0].Id); 
        email.setSubject('SAPA Donation Summary'); 
        email.setPlainTextBody('Please find attached your donation statement for the following period: '+fromYear+'-'+toYear);
        email.setSaveAsActivity(true);
        
        Messaging.EmailFileAttachment attachment = new Messaging.EmailFileAttachment();
        attachment.setFileName('SAPA Donation Summary.pdf');
        attachment.setBody(pdfBlob);
        email.setFileAttachments(new Messaging.EmailFileAttachment[] { attachment });
        
        sender.send(email);
    }
}