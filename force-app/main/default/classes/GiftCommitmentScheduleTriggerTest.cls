@isTest
public class GiftCommitmentScheduleTriggerTest {

    /**
     * Test Setup creates parent records needed for all test methods.
     * This avoids repeating DML limits and keeps code clean.
     */
    @testSetup
    static void setupTestData() {
        // 1. Create a dummy Account (Donor) to satisfy required fields
        Account testDonor = new Account(LastName = 'Test Donor Account');
        insert testDonor;

        // 2. Create the Parent GiftCommitment
        GiftCommitment gc = new GiftCommitment(
            Name = 'Test Parent Commitment',
            DonorId = testDonor.Id,
            Recurring_Type__c = 'Open' // Initial state
        );
        insert gc;

        // 3. Create the GiftCommitmentSchedule linked to the parent
        // Note: If your org requires other fields (e.g., StartDate, TransactionInterval), add them here.
        GiftCommitmentSchedule gcs = new GiftCommitmentSchedule(
            //Name = 'Test Schedule',
            GiftCommitmentId = gc.Id,
            TransactionAmount = 100.00,
            StartDate = Date.today(),
            EndDate = null // Starts open-ended
        );
        insert gcs;
    }

    @isTest
    static void testEndDateChangedToNotNull() {
        // Scenario: EndDate is updated from null to a specific date.
        // Expected Result: Parent GiftCommitment Recurring_Type__c becomes 'Fixed'.
        
        GiftCommitmentSchedule gcs = [SELECT Id, EndDate, GiftCommitmentId FROM GiftCommitmentSchedule LIMIT 1];
        
        Test.startTest();
        gcs.EndDate = Date.today().addYears(1);
        update gcs;
        Test.stopTest();

        // Verify the parent record was updated
        GiftCommitment updatedGc = [SELECT Recurring_Type__c FROM GiftCommitment WHERE Id = :gcs.GiftCommitmentId LIMIT 1];
        System.assertEquals('Fixed', updatedGc.Recurring_Type__c, 'Parent Recurring Type should change to Fixed when EndDate is populated.');
    }

    @isTest
    static void testEndDateChangedToNull() {
        // Scenario: EndDate is updated from a specific date back to null.
        // Expected Result: Parent GiftCommitment Recurring_Type__c becomes 'Open'.
        
        // Setup: First give it an EndDate so we have something to remove
        GiftCommitmentSchedule gcs = [SELECT Id, EndDate, GiftCommitmentId FROM GiftCommitmentSchedule LIMIT 1];
        gcs.EndDate = Date.today().addYears(1);
        update gcs; 

        Test.startTest();
        // Clear the EndDate to trigger the "else" block in your code
        gcs.EndDate = null;
        update gcs;
        Test.stopTest();

        // Verify the parent record was updated
        GiftCommitment updatedGc = [SELECT Recurring_Type__c FROM GiftCommitment WHERE Id = :gcs.GiftCommitmentId LIMIT 1];
        System.assertEquals('Open', updatedGc.Recurring_Type__c, 'Parent Recurring Type should change to Open when EndDate is cleared.');
    }

    @isTest
    static void testNoChangeToEndDate() {
        // Scenario: A different field is updated, EndDate remains the same.
        // Expected Result: Parent GiftCommitment Recurring_Type__c remains unchanged.
        
        GiftCommitmentSchedule gcs = [SELECT Id, Name, GiftCommitmentId FROM GiftCommitmentSchedule LIMIT 1];
        
        Test.startTest();
        // Update a field OTHER than EndDate
        //gcs.Name = 'Updated Test Schedule';
        update gcs;
        Test.stopTest();

        // Verify the parent record was NOT modified by the trigger
        GiftCommitment updatedGc = [SELECT Recurring_Type__c FROM GiftCommitment WHERE Id = :gcs.GiftCommitmentId LIMIT 1];
        System.assertEquals('Open', updatedGc.Recurring_Type__c, 'Parent Recurring Type should remain Open if EndDate is not changed.');
    }
}