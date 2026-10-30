/**
 * Server-side classifier for guided recurring donation changes.
 * The Flow may provide a hint, but this class compares the persisted schedule
 * with the proposed values and is the authoritative source for the mode.
 */
public with sharing class StripeRecurringChangeMode {
    public static final String END_DATE_ONLY = 'EndDateOnly';
    public static final String TERMS = 'Terms';
    public static final String TEMPORARY_TERMS = 'TemporaryTerms';
    public static final String START_DATE_CHANGE = 'StartDateChange';

    public class Result {
        public String mode;
        public Date proposedStartDate;
        public Date proposedEndDate;
        public String proposedRecurringType;
        public Boolean startDateChanged;
        public Boolean endDateChanged;
        public Boolean cadenceChanged;
        public Boolean amountChanged;
        public Boolean recurringTypeChanged;
    }

    /**
     * Compares the selected persisted schedule to the candidate values.
     * A null proposed amount/period/interval means keep the stored value;
     * proposedEndDate is intentionally nullable because null means Open.
     */
    public static Result classify(
        GiftCommitmentSchedule currentSchedule,
        String currentRecurringType,
        Decimal proposedAmount,
        String proposedPeriod,
        Integer proposedInterval,
        Date proposedStartDate,
        Date proposedEndDate,
        String proposedRecurringType,
        String modeHint
    ) {
        Result result = new Result();
        if (currentSchedule == null) {
            result.mode = String.isBlank(modeHint) ? TERMS : modeHint;
            result.proposedStartDate = proposedStartDate;
            result.proposedEndDate = proposedEndDate;
            result.proposedRecurringType = proposedRecurringType;
            return result;
        }

        result.proposedStartDate = proposedStartDate == null
            ? currentSchedule.StartDate
            : proposedStartDate;
        result.proposedEndDate = proposedEndDate;
        Decimal amount = proposedAmount == null ? currentSchedule.TransactionAmount : proposedAmount;
        String period = String.isBlank(proposedPeriod) ? currentSchedule.TransactionPeriod : proposedPeriod;
        Integer interval = proposedInterval == null
            ? (currentSchedule.TransactionInterval == null ? 1 : Integer.valueOf(currentSchedule.TransactionInterval))
            : proposedInterval;
        String derivedType = String.isBlank(proposedRecurringType)
            ? (proposedEndDate == null ? 'Open' : 'Fixed')
            : proposedRecurringType;
        result.proposedRecurringType = derivedType;
        result.startDateChanged = currentSchedule.StartDate != result.proposedStartDate;
        result.endDateChanged = currentSchedule.EndDate != result.proposedEndDate;
        result.amountChanged = currentSchedule.TransactionAmount != amount;
        Integer currentInterval = currentSchedule.TransactionInterval == null
            ? 1
            : Integer.valueOf(currentSchedule.TransactionInterval);
        result.cadenceChanged = currentSchedule.TransactionPeriod != period || currentInterval != interval;
        result.recurringTypeChanged = !String.isBlank(currentRecurringType) &&
            currentRecurringType != derivedType;

        if (result.startDateChanged == true) {
            result.mode = START_DATE_CHANGE;
        } else if (result.endDateChanged == true &&
            result.amountChanged != true && result.cadenceChanged != true) {
            // Adding or clearing End Date is the Open/Fixed cancellation-only
            // transition.  The parent type change is a consequence of EndDate.
            result.mode = END_DATE_ONLY;
        } else {
            result.mode = TERMS;
        }
        return result;
    }
}