@isTest
public class DataTableCTRLTest {
    @isTest
    public static void TestMethod1()
    {
        DatatableCtrl.getData();
        DatatableCtrl.getPicklistValues('GiftTransactionDesignation','Locations__c');
        DatatableCtrl.getPicklistValues('GiftTransactionDesignation','Intention__c');
    }
}