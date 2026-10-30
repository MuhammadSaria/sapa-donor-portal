@IsTest
private class TriggerOnOSC_Test {
    @IsTest static void testExplicitCodesSurviveInsert() {
        OutreachSourceCodeRollupHandler.enabledOverride = false;
        Campaign campaign = new Campaign(Name='OSC code test'); insert campaign;
        OutreachSourceCode first = new OutreachSourceCode(Name='First',CampaignId=campaign.Id,SourceCode='001');
        OutreachSourceCode second = new OutreachSourceCode(Name='Second',CampaignId=campaign.Id,SourceCode='002');
        insert first; insert second;
        Map<Id,OutreachSourceCode> actual = new Map<Id,OutreachSourceCode>([
            SELECT Id,SourceCode FROM OutreachSourceCode WHERE Id IN :new Set<Id>{first.Id,second.Id}]);
        System.assertEquals('001',actual.get(first.Id).SourceCode);
        System.assertEquals('002',actual.get(second.Id).SourceCode);
        System.assertEquals(null,[SELECT Total_Actual_Cost_in_OSC__c FROM Campaign WHERE Id=:campaign.Id].Total_Actual_Cost_in_OSC__c,
            'Disabled trigger must preserve the current configuration behavior.');
    }
    @IsTest static void testBulkCodesPreservedWithRollupEnabled() {
        OutreachSourceCodeRollupHandler.enabledOverride = true;
        Campaign campaign = new Campaign(Name='Bulk OSC code test'); insert campaign;
        List<OutreachSourceCode> records = new List<OutreachSourceCode>();
        for (Integer i=1;i<=3;i++) records.add(new OutreachSourceCode(Name='Bulk '+i,CampaignId=campaign.Id,
            SourceCode=String.valueOf(i).leftPad(3,'0'),Actual_Cost_in_OSC__c=i));
        insert records;
        Map<Id,OutreachSourceCode> actual = new Map<Id,OutreachSourceCode>([
            SELECT Id,SourceCode FROM OutreachSourceCode WHERE Id IN :records]);
        System.assertEquals(3,actual.size());
        for(Integer i=0;i<3;i++) System.assertEquals(records[i].SourceCode,actual.get(records[i].Id).SourceCode);
        System.assertEquals(6,[SELECT Total_Actual_Cost_in_OSC__c FROM Campaign WHERE Id=:campaign.Id].Total_Actual_Cost_in_OSC__c);
    }
}