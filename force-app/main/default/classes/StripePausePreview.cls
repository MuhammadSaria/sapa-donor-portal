/** Read-only confirmation context; the pause action independently revalidates it. */
public with sharing class StripePausePreview {
    @AuraEnabled public Boolean paidToday { get; set; }
    @AuraEnabled public Date businessDate { get; set; }
    @AuraEnabled public Date pauseStartDate { get; set; }
    @AuraEnabled public String timeZone { get; set; }
}