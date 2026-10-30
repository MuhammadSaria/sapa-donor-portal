/** Performs one isolated Stripe compensation after native pause/resume failure. */
public with sharing class StripePauseCompensationQueueable implements Queueable, Database.AllowsCallouts {
    private Id commitmentId;
    private Boolean restorePause;
    private Integer expectedRevision;
    public StripePauseCompensationQueueable(Id commitmentId, Boolean restorePause) {
        this.commitmentId = commitmentId;
        this.restorePause = restorePause;
    }
    public StripePauseCompensationQueueable(Id commitmentId, Boolean restorePause, Integer expectedRevision) {
        this(commitmentId, restorePause);
        this.expectedRevision = expectedRevision;
    }
    public void execute(QueueableContext context) {
        StripePauseOrchestrator.compensate(commitmentId, restorePause, expectedRevision);
    }
}