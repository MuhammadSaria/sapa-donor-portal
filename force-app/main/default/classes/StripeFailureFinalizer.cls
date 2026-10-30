/**
 * Attach to a Stripe queueable so an unhandled exception, including an uncatchable limit error,
 * still produces a Stripe failure log for the support team.
 */
public with sharing class StripeFailureFinalizer implements Finalizer {
    private final String operationName;
    private final Id commitmentId;

    public StripeFailureFinalizer(String operationName, Id commitmentId) {
        this.operationName = operationName;
        this.commitmentId = commitmentId;
    }

    public void execute(FinalizerContext context) {
        if (context == null || context.getResult() != ParentJobResult.UNHANDLED_EXCEPTION) return;
        StripeFailureLogger.record(StripeFailureLogger.failure(
                StripeFailureLogger.SOURCE_ASYNC_JOB, StripeFailureLogger.CODE_ASYNC_JOB_FAILED,
                'Stripe background job failed with an unhandled error')
            .withException(context.getException())
            .operation(operationName)
            .commitment(commitmentId));
        StripeFailureLogger.flush();
    }
}