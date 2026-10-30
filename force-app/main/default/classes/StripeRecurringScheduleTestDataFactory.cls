@IsTest
public class StripeRecurringScheduleTestDataFactory {
    public static GiftCommitment createCommitment(String subscriptionId, String recurringType) {
        Account donor = new Account(LastName = 'Stripe Effective Date Donor');
        insert donor;
        GiftCommitment commitment = new GiftCommitment(
            Name = 'Stripe Effective Date Commitment',
            DonorId = donor.Id,
            Status = 'Active',
            Recurring_Type__c = recurringType,
            Subscription_Id__c = subscriptionId,
            Payment_Processor__c = 'Stripe',
            Payment_type__c = 'Credit Card',
            Product_Id__c = 'prod_effective',
            Price_Id__c = 'price_original',
            CurrencyIsoCode = 'USD'
        );
        insert commitment;
        return commitment;
    }

    public static GiftCommitmentSchedule createSchedule(
        GiftCommitment commitment,
        Decimal amount,
        String period,
        Integer intervalCount,
        Date firstPaymentDate,
        Date effectiveDate,
        Integer installments
    ) {
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = true;
        GiftCommitmentSchedule schedule = new GiftCommitmentSchedule(
            GiftCommitmentId = commitment.Id,
            TransactionAmount = amount,
            TransactionPeriod = period,
            TransactionInterval = intervalCount,
            StartDate = firstPaymentDate,
            PaymentMethod = 'Credit Card',
            Stripe_Change_Effective_Date__c = effectiveDate,
            Number_of_Planned_Installments__c = installments
        );
        insert schedule;
        StripeRecurringScheduleCaptureQueueable.captureDisabledForTest = false;
        return schedule;
    }

    public static GiftTransaction createUnpaidTransaction(
        GiftCommitment commitment,
        GiftCommitmentSchedule schedule,
        Decimal amount,
        Date dueDate
    ) {
        GiftTransaction transactionRecord = new GiftTransaction(
            Name = 'Stripe Effective Date Unpaid Transaction',
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            GiftCommitmentScheduleId = schedule.Id,
            Status = 'Pledged',
            OriginalAmount = amount,
            TransactionDueDate = dueDate,
            PaymentMethod = 'Credit Card'
        );
        insert transactionRecord;
        return transactionRecord;
    }
}