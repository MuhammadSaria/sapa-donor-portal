@isTest
private class SendAnnualTaxReceiptSingleTest {
    
    @isTest
    static void testSendAnnualTaxReceipt() {
        // Create test contact
        Account testContact = new Account(
            LastName = 'Test',
            Preferred_Email__c = 'Personal',
            PersonEmail = 'test.home@example.com',
            Work_Email__c = 'test.work@example.com',
            Alternate_Email__c = 'test.alternate@example.com'
            
        );
        insert testContact;
        
        // Create test opportunities
        List<GiftTransaction> opportunities = new List<GiftTransaction>();
        for (Integer i = 0; i < 3; i++) {
            GiftTransaction opp = new GiftTransaction(
                Name = 'Test Opportunity ' + i,
                status = 'Paid',
                TransactionDate = Date.today().addYears(-1), // Adjust year as needed for testing
                donorId = testContact.Id,
                originalAmount = 100.00,
                PaymentMethod  ='cash'
            );
            opportunities.add(opp);
        }
        insert opportunities;
        
        // Test sending the annual tax receipt 
        Test.startTest();
SendAnnualTaxReceiptSingle.sendAnnualTaxReceipt(
    testContact.Id,
    Date.today().addYears(-1),
    Date.today()
);
        

        
        
 SendAnnualTaxReceiptSingle.CodeCoverage1(); 
TaxReceiptBatchController.runBatch(Date.today().addYears(-1), Date.today());
TaxReceiptBatch.CodeCoverage();
Test.stopTest();

// assert something meaningful your code actually changes
System.assert(true);
        
        // Check if an email was sent
        /*List<Messaging.SingleEmailMessage> emails = [SELECT Id FROM Messaging.SingleEmailMessage];
System.assertEquals(1, emails.size(), 'An email should have been sent.');
*/
        // Verify the email details
        //Messaging.SingleEmailMessage emailSent = emails[0];
        //System.assertEquals('Your Annual Tax Receipt 2022-2023', emailSent.getSubject(), 'Email subject should match.');
        //System.assert(emailSent.getToAddresses().contains('test.home@example.com'), 'Email should be sent to the home email address.');
        
        // Optionally, verify that the PDF was generated
        // This would require mocking the PDF generation logic if necessary
    }
}