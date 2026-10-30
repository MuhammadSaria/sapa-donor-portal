@isTest
public class DataTableRecurringCTRLTest {
    @isTest
    public static void TestMethod1()
    {
        DataTableRecurringCTRL.getData();
        DataTableRecurringCTRL.getPicklistValues('GiftDefaultDesignation','Locations__c');
        DataTableRecurringCTRL.getPicklistValues('GiftDefaultDesignation','Intention__c');
    }
}