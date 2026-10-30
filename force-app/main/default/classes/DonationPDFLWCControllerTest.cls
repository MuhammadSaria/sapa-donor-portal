@IsTest
private class DonationPDFLWCControllerTest {
    private class CapturingSender implements DonationPDFLWCController.EmailSender {
        List<Messaging.SingleEmailMessage> messages=new List<Messaging.SingleEmailMessage>();
        public void send(Messaging.SingleEmailMessage message) { messages.add(message); }
    }
    @IsTest static void testSendEmailWithPdf() {
        CapturingSender capture=new CapturingSender(); DonationPDFLWCController.sender=capture;
        Account donor=new Account(LastName='Receipt test',Preferred_Email__c='Work',Work_Email__c='work@example.com');
        Blob pdf=Blob.valueOf('Synthetic PDF');
        Test.startTest(); DonationPDFLWCController.sendEmailWithPdf(donor,pdf,'2025-01-01','2026-01-01'); Test.stopTest();
        System.assertEquals(1,capture.messages.size());
        Messaging.SingleEmailMessage message=capture.messages[0];
        System.assertEquals(new List<String>{'work@example.com'},message.getToAddresses());
        System.assertEquals('SAPA Donation Summary',message.getSubject());
        System.assertEquals('Please find attached your donation statement for the following period: 2025-01-01-2026-01-01',message.getPlainTextBody());
        System.assertNotEquals(null,message.getOrgWideEmailAddressId());
        System.assertEquals(true,message.getSaveAsActivity());
        System.assertEquals(1,message.getFileAttachments().size());
        System.assertEquals('SAPA Donation Summary.pdf',message.getFileAttachments()[0].getFileName());
        System.assertEquals(pdf,message.getFileAttachments()[0].getBody());
        System.assertEquals(0,Limits.getEmailInvocations(),'Injected transport must not send a real email.');
    }
    @IsTest static void testPreferredAddressAndMissingAddress() {
        CapturingSender capture=new CapturingSender(); DonationPDFLWCController.sender=capture;
        Blob pdf=Blob.valueOf('Synthetic PDF');
        DonationPDFLWCController.sendEmailWithPdf(new Account(Preferred_Email__c='Personal',PersonEmail='personal@example.com'),pdf,'a','b');
        DonationPDFLWCController.sendEmailWithPdf(new Account(Preferred_Email__c='Alternate',Alternate_Email__c='alternate@example.com'),pdf,'a','b');
        DonationPDFLWCController.sendEmailWithPdf(new Account(Preferred_Email__c='Work'),pdf,'a','b');
        System.assertEquals(2,capture.messages.size());
        System.assertEquals('personal@example.com',capture.messages[0].getToAddresses()[0]);
        System.assertEquals('alternate@example.com',capture.messages[1].getToAddresses()[0]);
    }
    @IsTest static void testSendEmail() {
        CapturingSender capture=new CapturingSender(); DonationPDFLWCController.sender=capture;
        Account donor=new Account(LastName='PDF fixture',PersonEmail='pdf@example.com',Preferred_Email__c='Personal'); insert donor;
        DonationPDFLWCController.sendEmail(donor.Id,Date.today().addYears(-1),Date.today());
        System.assertEquals(0,capture.messages.size(),'PDF callout is unavailable in an Apex test.');
    }
    @IsTest static void testGeneratePDF() {
        System.assertEquals(null,DonationPDFLWCController.generatePDF(null,Date.today(),Date.today()));
    }
}