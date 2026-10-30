trigger StripeFailureEventTrigger on Stripe_Failure__e (after insert) {
    StripeFailureEventHandler.handle(Trigger.new);
}