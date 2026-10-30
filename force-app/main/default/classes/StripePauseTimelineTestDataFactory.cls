/** Synthetic timeline fixtures; no org donor data or external Stripe interaction. */
@IsTest
public class StripePauseTimelineTestDataFactory {
    public static GiftCommitment createDailyTimeline() {
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;
        StripePauseService.suppressSubscriptionUpdate=true;
        try {
            GiftCommitment gift=StripeRecurringScheduleTestDataFactory.createCommitment('sub_multi_pause','Open');
            update new GiftCommitment(Id=gift.Id,ScheduleType='Recurring');
            List<GiftCommitmentSchedule> schedules=new List<GiftCommitmentSchedule>{
                new GiftCommitmentSchedule(GiftCommitmentId=gift.Id,Type='CreateTransactions',StartDate=Date.today().addDays(-2),
                    EndDate=Date.today().addDays(-2),TransactionAmount=5,TransactionPeriod='Daily',TransactionInterval=1,PaymentMethod='Credit Card'),
                new GiftCommitmentSchedule(GiftCommitmentId=gift.Id,Type='PauseTransactions',StartDate=Date.today().addDays(-1),
                    EndDate=Date.today().addDays(-1),TransactionAmount=5,TransactionPeriod='Daily',TransactionInterval=1,PaymentMethod='Credit Card'),
                new GiftCommitmentSchedule(GiftCommitmentId=gift.Id,Type='CreateTransactions',StartDate=Date.today(),
                    TransactionAmount=5,TransactionPeriod='Daily',TransactionInterval=1,PaymentMethod='Credit Card')
            };
            insert schedules;
            insert new List<GiftTransaction>{
                new GiftTransaction(Name='Protected daily installment',DonorId=gift.DonorId,GiftCommitmentId=gift.Id,
                    GiftCommitmentScheduleId=schedules[0].Id,Status='Paid',OriginalAmount=5,TransactionDate=Date.today().addDays(-2),
                    TransactionDueDate=Date.today().addDays(-2),PaymentMethod='Credit Card'),
                new GiftTransaction(Name='Daily installment to be voided',DonorId=gift.DonorId,GiftCommitmentId=gift.Id,
                    GiftCommitmentScheduleId=schedules[2].Id,Status='Unpaid',OriginalAmount=5,TransactionDueDate=Date.today(),PaymentMethod='Credit Card')
            };
            return gift;
        } finally { StripePauseService.suppressSubscriptionUpdate=previous; }
    }
    public static GiftCommitment createTimeline(Boolean paidToday) {
        return createTimeline(paidToday,Date.today());
    }
    public static GiftCommitment createTimeline(Boolean paidToday,Date anchorDate) {
        Boolean previous=StripePauseService.suppressSubscriptionUpdate;
        StripePauseService.suppressSubscriptionUpdate=true;
        try {
            GiftCommitment gift=StripeRecurringScheduleTestDataFactory.createCommitment('sub_multi_pause','Open');
            update new GiftCommitment(Id=gift.Id,ScheduleType='Recurring');
            Date today=anchorDate;
            String day=today.day()>30?'LastDay':String.valueOf(today.day());
            List<GiftCommitmentSchedule> schedules=new List<GiftCommitmentSchedule>{
                new GiftCommitmentSchedule(GiftCommitmentId=gift.Id,Type='CreateTransactions',
                    StartDate=today.addDays(-1),EndDate=today,TransactionAmount=70,TransactionPeriod='Monthly',
                    TransactionInterval=1,TransactionDay=day,PaymentMethod='Credit Card'),
                new GiftCommitmentSchedule(GiftCommitmentId=gift.Id,Type='PauseTransactions',
                    StartDate=today.addDays(1),EndDate=today.addDays(6),TransactionAmount=70,
                    TransactionPeriod='Monthly',TransactionInterval=1,TransactionDay=day,PaymentMethod='Credit Card'),
                new GiftCommitmentSchedule(GiftCommitmentId=gift.Id,Type='PauseTransactions',
                    StartDate=today.addDays(7),EndDate=today.addDays(13),TransactionAmount=43,
                    TransactionPeriod='Weekly',TransactionInterval=2,PaymentMethod='Credit Card'),
                new GiftCommitmentSchedule(GiftCommitmentId=gift.Id,Type='CreateTransactions',
                    StartDate=today.addDays(14),TransactionAmount=43,TransactionPeriod='Weekly',
                    TransactionInterval=2,PaymentMethod='Credit Card')
            };
            insert schedules;
            List<GiftTransaction> transactions=new List<GiftTransaction>{
                new GiftTransaction(Name='Protected timeline installment',DonorId=gift.DonorId,
                    GiftCommitmentId=gift.Id,GiftCommitmentScheduleId=schedules[0].Id,Status='Paid',
                    OriginalAmount=70,TransactionDate=paidToday?today:today.addDays(-1),
                    TransactionDueDate=paidToday?today:today.addDays(-1),PaymentMethod='Credit Card'),
                new GiftTransaction(Name='Future timeline installment',DonorId=gift.DonorId,
                    GiftCommitmentId=gift.Id,GiftCommitmentScheduleId=schedules[3].Id,Status='Unpaid',
                    OriginalAmount=43,TransactionDueDate=today.addDays(14),PaymentMethod='Credit Card')
            };
            insert transactions;
            update new GiftCommitment(Id=gift.Id,NextTransactionDate=today.addDays(14),NextTransactionAmount=43);
            return gift;
        } finally { StripePauseService.suppressSubscriptionUpdate=previous; }
    }
}