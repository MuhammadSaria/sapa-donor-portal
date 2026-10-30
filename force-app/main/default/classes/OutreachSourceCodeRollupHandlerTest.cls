@IsTest
private class OutreachSourceCodeRollupHandlerTest {

    @IsTest
    static void testCampaignRollups() {
        OutreachSourceCodeRollupHandler.enabledOverride = true;
        Campaign campaignOne = new Campaign(
            Name = 'Test Campaign One'
        );

        Campaign campaignTwo = new Campaign(
            Name = 'Test Campaign Two'
        );

        insert new List<Campaign>{ campaignOne, campaignTwo };

        OutreachSourceCode oscOne = new OutreachSourceCode(
            Name = 'OSC One',
            SourceCode = 'OSC-TEST-001',
            CampaignId = campaignOne.Id,
            Actual_Cost_in_OSC__c = 100,
            Budgeted_Cost_in_OSC__c = 200,
            Expected_Revenue_in_OSC__c = 300
        );

        OutreachSourceCode oscTwo = new OutreachSourceCode(
            Name = 'OSC Two',
            SourceCode = 'OSC-TEST-002',
            CampaignId = campaignOne.Id,
            Actual_Cost_in_OSC__c = 50,
            Budgeted_Cost_in_OSC__c = 75,
            Expected_Revenue_in_OSC__c = 125
        );

        insert new List<OutreachSourceCode>{ oscOne, oscTwo };

        Campaign campaignOneAfterInsert = [
            SELECT
                Total_Actual_Cost_in_OSC__c,
                Total_Budgeted_Cost_in_OSC__c,
                Total_Expected_Revenue_in_OSC__c
            FROM Campaign
            WHERE Id = :campaignOne.Id
        ];

        System.assertEquals(
            150,
            campaignOneAfterInsert.Total_Actual_Cost_in_OSC__c
        );
        System.assertEquals(
            275,
            campaignOneAfterInsert.Total_Budgeted_Cost_in_OSC__c
        );
        System.assertEquals(
            425,
            campaignOneAfterInsert.Total_Expected_Revenue_in_OSC__c
        );

        // Update one child amount.
        oscOne.Actual_Cost_in_OSC__c = 125;
        update oscOne;

        Campaign campaignOneAfterUpdate = [
            SELECT Total_Actual_Cost_in_OSC__c
            FROM Campaign
            WHERE Id = :campaignOne.Id
        ];

        System.assertEquals(
            175,
            campaignOneAfterUpdate.Total_Actual_Cost_in_OSC__c
        );

        // Move one child from Campaign One to Campaign Two.
        oscTwo.CampaignId = campaignTwo.Id;
        update oscTwo;

        Campaign campaignOneAfterMove = [
            SELECT
                Total_Actual_Cost_in_OSC__c,
                Total_Budgeted_Cost_in_OSC__c,
                Total_Expected_Revenue_in_OSC__c
            FROM Campaign
            WHERE Id = :campaignOne.Id
        ];

        Campaign campaignTwoAfterMove = [
            SELECT
                Total_Actual_Cost_in_OSC__c,
                Total_Budgeted_Cost_in_OSC__c,
                Total_Expected_Revenue_in_OSC__c
            FROM Campaign
            WHERE Id = :campaignTwo.Id
        ];

        System.assertEquals(
            125,
            campaignOneAfterMove.Total_Actual_Cost_in_OSC__c
        );
        System.assertEquals(
            200,
            campaignOneAfterMove.Total_Budgeted_Cost_in_OSC__c
        );
        System.assertEquals(
            300,
            campaignOneAfterMove.Total_Expected_Revenue_in_OSC__c
        );

        System.assertEquals(
            50,
            campaignTwoAfterMove.Total_Actual_Cost_in_OSC__c
        );
        System.assertEquals(
            75,
            campaignTwoAfterMove.Total_Budgeted_Cost_in_OSC__c
        );
        System.assertEquals(
            125,
            campaignTwoAfterMove.Total_Expected_Revenue_in_OSC__c
        );

        // Delete one child.
        delete oscOne;

        Campaign campaignOneAfterDelete = [
            SELECT
                Total_Actual_Cost_in_OSC__c,
                Total_Budgeted_Cost_in_OSC__c,
                Total_Expected_Revenue_in_OSC__c
            FROM Campaign
            WHERE Id = :campaignOne.Id
        ];

        System.assertEquals(
            0,
            campaignOneAfterDelete.Total_Actual_Cost_in_OSC__c
        );
        System.assertEquals(
            0,
            campaignOneAfterDelete.Total_Budgeted_Cost_in_OSC__c
        );
        System.assertEquals(
            0,
            campaignOneAfterDelete.Total_Expected_Revenue_in_OSC__c
        );

        // Undelete one child.
        undelete oscOne;

        Campaign campaignOneAfterUndelete = [
            SELECT
                Total_Actual_Cost_in_OSC__c,
                Total_Budgeted_Cost_in_OSC__c,
                Total_Expected_Revenue_in_OSC__c
            FROM Campaign
            WHERE Id = :campaignOne.Id
        ];

        System.assertEquals(
            125,
            campaignOneAfterUndelete.Total_Actual_Cost_in_OSC__c
        );
        System.assertEquals(
            200,
            campaignOneAfterUndelete.Total_Budgeted_Cost_in_OSC__c
        );
        System.assertEquals(
            300,
            campaignOneAfterUndelete.Total_Expected_Revenue_in_OSC__c
        );
    }
}