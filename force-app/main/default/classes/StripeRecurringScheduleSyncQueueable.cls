public without sharing class StripeRecurringScheduleSyncQueueable implements Queueable, Database.AllowsCallouts {
    private List<Id> requestIds;
    public StripeRecurringScheduleSyncQueueable(List<Id> requestIds) {
        this.requestIds = requestIds;
    }
    public void execute(QueueableContext context) {
        if (requestIds == null || requestIds.isEmpty()) return;
        for (Id requestId : requestIds) {
            StripeRecurringScheduleChangeService.processRequest(requestId);
        }
    }
}