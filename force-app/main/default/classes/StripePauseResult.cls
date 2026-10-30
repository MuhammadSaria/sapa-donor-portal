/** Top-level Aura DTO for the pause/resume quick action. */
public class StripePauseResult {
    @AuraEnabled public Boolean stripeConfirmed { get; set; }
    @AuraEnabled public String salesforceState { get; set; }
    @AuraEnabled public Date resumeDate { get; set; }
    @AuraEnabled public String message { get; set; }
    @AuraEnabled public Date pauseStartDate { get; set; }
    @AuraEnabled public Date nextPaymentDate { get; set; }
    @AuraEnabled public String errorCode { get; set; }

    public StripePauseResult(Boolean confirmed, String state, Date resumeOn, String detail) {
        stripeConfirmed = confirmed;
        salesforceState = state;
        resumeDate = resumeOn;
        message = detail;
    }
}