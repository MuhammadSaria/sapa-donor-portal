@IsTest
public class ContactControllerTest {

    @TestSetup
    static void setupTestData() {
        // Create a Person Account (Contact)
        RecordType personRt = [
            SELECT Id
            FROM RecordType
            WHERE SObjectType = 'Account'
            AND IsPersonType = true
            LIMIT 1
        ];

        Account acc = new Account(
            RecordTypeId = personRt.Id,
            LastName = 'Test Contact',
            PersonEmail = 'test@example.com',
            PersonMailingCity = 'Old City'
        );
        insert acc;
    }

    @IsTest
    static void testUpdateContact() {
        // Retrieve test Account
        Account acc = [SELECT Id, PersonMailingCity FROM Account LIMIT 1];

        // Modify field
        acc.PersonMailingCity = 'New City';

        Test.startTest();
        // Call AuraEnabled method
        ContactController.updateContact(acc);
        Test.stopTest();

        // Verify update
        Account updatedAcc = [SELECT PersonMailingCity FROM Account WHERE Id = :acc.Id];
        System.assertEquals('New City', updatedAcc.PersonMailingCity, 'City should be updated');
    }

    @IsTest
    static void testUpdateContact_noChanges() {
        // Verify method runs even with no changes
        Account acc = [SELECT Id, PersonMailingCity FROM Account LIMIT 1];

        Test.startTest();
        ContactController.updateContact(acc);
        Test.stopTest();

        // Nothing should fail
        Account updatedAcc = [SELECT PersonMailingCity FROM Account WHERE Id = :acc.Id];
        System.assertNotEquals(null, updatedAcc);
    }
}