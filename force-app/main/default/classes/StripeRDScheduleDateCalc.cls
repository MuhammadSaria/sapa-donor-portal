/**
 * Calculates the configuration date and real Stripe billing dates for a recurring schedule.
 * The service is deliberately side-effect free so the same rules can be used by previews,
 * schedule stamping, durable request capture, and Stripe gateway validation.
 */
public with sharing class StripeRDScheduleDateCalc {
    private static final Integer MAX_OCCURRENCES = 10000;

    /** Result of normalizing a requested recurring schedule. */
    public class Result {
        public Date effectiveDate;
        public Date managedEffectiveFromDate;
        /**
         * The start date supplied to Salesforce's managed schedule action.
         * This is deliberately distinct from managedEffectiveFromDate, which
         * identifies the current source segment that owns the change boundary.
         */
        public Date salesforceSuccessorStartDate;
        public Date firstPaymentDate;
        public Date finalPaymentDate;
        public Integer installments;
        public String requestedTransactionDay;
        public Boolean billingAnchorChanged;
        public String warning;
        public String error;
    }

    /** Result of calculating an inclusive temporary terms window. */
    public class TemporaryWindowResult {
        public Date effectiveStartDate;
        public Date effectiveEndDate;
        public Date firstTemporaryPaymentDate;
        public Date lastTemporaryPaymentDate;
        public Date restorationFirstPaymentDate;
        public Integer temporaryInstallments;
        public String warning;
        public String error;
    }

    /**
     * Calculates the real payments inside a temporary amount/cadence window and
     * the first payment on the original calendar after the window.
     * @param originalBillingAnchor a known occurrence on the original billing calendar
     * @param effectiveStart inclusive configuration boundary
     * @param effectiveEnd inclusive configuration boundary
     * @param originalPeriod original Daily, Weekly, Monthly, or Yearly period
     * @param originalInterval positive original interval
     * @param targetPeriod requested temporary period
     * @param targetInterval positive requested interval
     * @param cadenceChanged true when the requested cadence differs from the original cadence
     * @return calculated temporary and restoration dates, or a blocking error
     */
    public static TemporaryWindowResult calculateTemporaryWindow(
        Date originalBillingAnchor,
        Date effectiveStart,
        Date effectiveEnd,
        String originalPeriod,
        Integer originalInterval,
        String targetPeriod,
        Integer targetInterval,
        Boolean cadenceChanged
    ) {
        TemporaryWindowResult result = new TemporaryWindowResult();
        result.effectiveStartDate = effectiveStart;
        result.effectiveEndDate = effectiveEnd;
        if (originalBillingAnchor == null || effectiveStart == null || effectiveEnd == null) {
            result.error = 'The original billing date and both temporary window dates are required.';
            return result;
        }
        if (effectiveEnd < effectiveStart) {
            result.error = 'Effective End Date must be on or after Effective Start Date.';
            return result;
        }
        if (originalInterval == null || originalInterval < 1 || targetInterval == null || targetInterval < 1 ||
            !isSupportedPeriod(originalPeriod) || !isSupportedPeriod(targetPeriod)) {
            result.error = 'The original and requested billing cadences must be valid.';
            return result;
        }

        Date targetAnchor = cadenceChanged == true
            ? addPeriod(originalBillingAnchor, targetPeriod, targetInterval)
            : originalBillingAnchor;
        Date firstTargetPayment = occurrenceOnOrAfter(
            targetAnchor,
            effectiveStart,
            targetPeriod,
            targetInterval
        );
        if (firstTargetPayment == null || firstTargetPayment > effectiveEnd) {
            result.error = cadenceChanged == true
                ? 'The temporary cadence window does not contain a calculated payment.'
                : 'The temporary amount window does not contain a scheduled payment.';
            return result;
        }

        Date current = firstTargetPayment;
        Date lastTargetPayment = current;
        Integer installmentCount = 1;
        while (installmentCount < MAX_OCCURRENCES) {
            Date nextPayment = addPeriod(current, targetPeriod, targetInterval);
            if (nextPayment > effectiveEnd) break;
            current = nextPayment;
            lastTargetPayment = nextPayment;
            installmentCount++;
        }
        if (installmentCount >= MAX_OCCURRENCES &&
            addPeriod(current, targetPeriod, targetInterval) <= effectiveEnd) {
            result.error = 'The temporary window is too long to calculate safely.';
            return result;
        }

        result.firstTemporaryPaymentDate = firstTargetPayment;
        result.lastTemporaryPaymentDate = lastTargetPayment;
        result.temporaryInstallments = installmentCount;
        result.restorationFirstPaymentDate = occurrenceOnOrAfter(
            originalBillingAnchor,
            effectiveEnd.addDays(1),
            originalPeriod,
            originalInterval
        );
        if (result.restorationFirstPaymentDate == null) {
            result.error = 'Unable to calculate the first restored payment date.';
        }
        return result;
    }

    /**
     * Calculates the future boundary for an amount or cadence change without
     * changing the historical schedule StartDate.
     */
    public static Result calculateTermsBoundary(
        Date latestPaidDate,
        Date earliestFutureUnpaidDate,
        Date today,
        String requestedPeriod,
        Integer requestedInterval,
        Boolean cadenceChanged
    ) {
        Result result = new Result();
        Date calculationDate = today == null ? Date.today() : today;
        if (requestedInterval == null || requestedInterval < 1) {
            result.error = 'The recurring interval must be at least one.';
            return result;
        }
        if (!isSupportedPeriod(requestedPeriod)) {
            result.error = 'Unsupported recurring period.';
            return result;
        }

        if (cadenceChanged == true) {
            Date firstPayment = latestPaidDate == null
                ? earliestFutureUnpaidDate
                : addPeriod(latestPaidDate, requestedPeriod, requestedInterval);
            Integer guard = 0;
            while (firstPayment != null && firstPayment <= calculationDate && guard < MAX_OCCURRENCES) {
                firstPayment = addPeriod(firstPayment, requestedPeriod, requestedInterval);
                guard++;
            }
            if (guard >= MAX_OCCURRENCES) {
                result.error = 'Unable to calculate the first payment for the requested cadence.';
                return result;
            }
            result.firstPaymentDate = firstPayment;
            result.effectiveDate = firstPayment == null ? calculationDate : firstPayment;
            Date paidBoundary = latestPaidDate == null ? null : latestPaidDate.addDays(1);
            result.managedEffectiveFromDate = paidBoundary == null || paidBoundary < calculationDate
                ? calculationDate
                : paidBoundary;
            if (latestPaidDate == null && earliestFutureUnpaidDate != null) {
                result.managedEffectiveFromDate = earliestFutureUnpaidDate;
            }
        } else {
            result.firstPaymentDate = earliestFutureUnpaidDate;
            result.effectiveDate = calculationDate;
            result.managedEffectiveFromDate = earliestFutureUnpaidDate == null
                ? calculationDate
                : earliestFutureUnpaidDate;
        }
        result.salesforceSuccessorStartDate = result.firstPaymentDate;
        return result;
    }

    /**
     * Calculates a terms boundary while preserving a staff-selected Monthly
     * Transaction Day.  The original overload remains for non-Flow callers
     * whose existing behavior must not change.
     */
    public static Result calculateTermsBoundary(
        Date latestPaidDate,
        Date earliestFutureUnpaidDate,
        Date today,
        String requestedPeriod,
        Integer requestedInterval,
        Boolean cadenceChanged,
        String currentTransactionDay,
        String requestedTransactionDay
    ) {
        if (!'Monthly'.equalsIgnoreCase(requestedPeriod)) {
            Result nonMonthly = calculateTermsBoundary(
                latestPaidDate,
                earliestFutureUnpaidDate,
                today,
                requestedPeriod,
                requestedInterval,
                cadenceChanged
            );
            nonMonthly.requestedTransactionDay = null;
            nonMonthly.billingAnchorChanged = false;
            return nonMonthly;
        }

        Result result = new Result();
        Date calculationDate = today == null ? Date.today() : today;
        if (requestedInterval == null || requestedInterval < 1) {
            result.error = 'The recurring interval must be at least one.';
            return result;
        }
        String normalizedRequestedDay = normalizeTransactionDay(requestedTransactionDay);
        if (normalizedRequestedDay == null) {
            result.error = 'Transaction Day is required for Monthly and must be a permitted day.';
            return result;
        }
        String normalizedCurrentDay = normalizeTransactionDay(currentTransactionDay);
        result.requestedTransactionDay = normalizedRequestedDay;
        result.billingAnchorChanged = normalizedCurrentDay != normalizedRequestedDay;

        Date comparisonBoundary = calculationDate;
        if (latestPaidDate != null && latestPaidDate > comparisonBoundary) {
            comparisonBoundary = latestPaidDate;
        }
        Boolean mustCalculateSelectedDay = cadenceChanged == true ||
            result.billingAnchorChanged == true || earliestFutureUnpaidDate == null;
        result.firstPaymentDate = mustCalculateSelectedDay
            ? nextMonthlyTransactionDate(comparisonBoundary, normalizedRequestedDay)
            : earliestFutureUnpaidDate;
        if (result.firstPaymentDate == null) {
            result.error = 'Unable to calculate the first payment for the selected Monthly Transaction Day.';
            return result;
        }

        Date paidBoundary = latestPaidDate == null ? null : latestPaidDate.addDays(1);
        if (cadenceChanged == true || result.billingAnchorChanged == true || earliestFutureUnpaidDate == null) {
            result.managedEffectiveFromDate = paidBoundary == null || paidBoundary < calculationDate
                ? calculationDate
                : paidBoundary;
        } else {
            result.managedEffectiveFromDate = earliestFutureUnpaidDate;
        }
        result.effectiveDate = cadenceChanged == true || result.billingAnchorChanged == true
            ? result.firstPaymentDate
            : calculationDate;
        result.salesforceSuccessorStartDate = result.firstPaymentDate;
        return result;
    }

    /** Returns the canonical value accepted by GiftCommitmentSchedule.TransactionDay. */
    public static String normalizeTransactionDay(String transactionDay) {
        if (String.isBlank(transactionDay)) return null;
        String trimmedDay = transactionDay.trim();
        if ('LastDay'.equalsIgnoreCase(trimmedDay)) return 'LastDay';
        try {
            Integer numericDay = Integer.valueOf(trimmedDay);
            return numericDay >= 1 && numericDay <= 30 ? String.valueOf(numericDay) : null;
        } catch (Exception ignored) {
            return null;
        }
    }

    /** Returns the next selected monthly billing day strictly after the boundary. */
    public static Date nextMonthlyTransactionDate(Date boundary, String transactionDay) {
        String normalizedDay = normalizeTransactionDay(transactionDay);
        if (boundary == null || normalizedDay == null) return null;
        Date monthStart = boundary.toStartOfMonth();
        Date candidate = monthlyDate(monthStart, normalizedDay);
        if (candidate > boundary) return candidate;
        return monthlyDate(monthStart.addMonths(1), normalizedDay);
    }

    private static Date monthlyDate(Date monthStart, String transactionDay) {
        Integer lastDay = Date.daysInMonth(monthStart.year(), monthStart.month());
        Integer requestedDay = 'LastDay'.equalsIgnoreCase(transactionDay)
            ? lastDay
            : Integer.valueOf(transactionDay);
        return Date.newInstance(
            monthStart.year(),
            monthStart.month(),
            Math.min(requestedDay, lastDay)
        );
    }

    /**
     * Calculates a normalized first and final payment date.
     * @param requestedStart staff-selected configuration start date
     * @param requestedEnd staff-selected fixed final date, or null for Open
     * @param today business date used for deterministic tests
     * @param period Daily, Weekly, Monthly, or Yearly
     * @param interval positive cadence interval
     * @param recurringType Open or Fixed
     * @return normalized dates, installment count, warning, or blocking error
     */
    public static Result calculate(
        Date requestedStart,
        Date requestedEnd,
        Date today,
        String period,
        Integer interval,
        String recurringType
    ) {
        Result result = new Result();
        Date calculationDate = today == null ? Date.today() : today;
        if (requestedStart == null) {
            result.error = 'A schedule start date is required.';
            return result;
        }
        if (interval == null || interval < 1) {
            result.error = 'The recurring interval must be at least one.';
            return result;
        }
        if (!isSupportedPeriod(period)) {
            result.error = 'Unsupported recurring period.';
            return result;
        }
        if (recurringType != 'Open' && recurringType != 'Fixed') {
            result.error = 'Recurring type must be Open or Fixed.';
            return result;
        }
        result.effectiveDate = requestedStart > calculationDate ? requestedStart : calculationDate;
        result.firstPaymentDate = requestedStart > calculationDate
            ? requestedStart
            : nextOccurrenceAfter(requestedStart, calculationDate, period, interval);
        if (result.firstPaymentDate == null) {
            result.error = 'Unable to calculate the first recurring payment date.';
            return result;
        }
        if (recurringType == 'Open') return result;
        if (requestedEnd == null) {
            result.error = 'A Fixed recurring donation requires an end date.';
            return result;
        }
        if (requestedEnd < result.firstPaymentDate) {
            result.error = 'The final payment date must be on or after the first payment date.';
            return result;
        }

        Date current = result.firstPaymentDate;
        Integer count = 1;
        Date lastScheduledDate = current;
        while (count < MAX_OCCURRENCES) {
            Date next = addPeriod(current, period, interval);
            if (next > requestedEnd) break;
            lastScheduledDate = next;
            current = next;
            count++;
        }
        if (count >= MAX_OCCURRENCES && addPeriod(current, period, interval) <= requestedEnd) {
            result.error = 'The selected fixed date range is too long to calculate safely.';
            return result;
        }
        result.finalPaymentDate = lastScheduledDate;
        result.installments = count;
        if (lastScheduledDate != requestedEnd) {
            result.warning = 'The entered end date is not a billing date. The last scheduled payment on or before that date is ' +
                String.valueOf(lastScheduledDate) + '.';
        }
        return result;
    }

    /** Returns the next cadence occurrence strictly after the business date. */
    public static Date nextOccurrenceAfter(Date startDate, Date today, String period, Integer interval) {
        Date occurrence = startDate;
        Integer guard = 0;
        while (occurrence <= today && guard < MAX_OCCURRENCES) {
            occurrence = addPeriod(occurrence, period, interval);
            guard++;
        }
        return guard >= MAX_OCCURRENCES ? null : occurrence;
    }

    private static Date occurrenceOnOrAfter(Date anchor, Date boundary, String period, Integer interval) {
        Date occurrence = anchor;
        Integer guard = 0;
        while (occurrence < boundary && guard < MAX_OCCURRENCES) {
            occurrence = addPeriod(occurrence, period, interval);
            guard++;
        }
        return guard >= MAX_OCCURRENCES ? null : occurrence;
    }

    /** Adds one or more cadence periods while preserving the existing Stripe date semantics. */
    public static Date addPeriod(Date startDate, String period, Integer interval) {
        if (startDate == null || interval == null || interval < 1) return null;
        if ('Daily'.equalsIgnoreCase(period)) return startDate.addDays(interval);
        if ('Weekly'.equalsIgnoreCase(period)) return startDate.addDays(interval * 7);
        if ('Monthly'.equalsIgnoreCase(period)) return startDate.addMonths(interval);
        if ('Yearly'.equalsIgnoreCase(period)) return startDate.addYears(interval);
        throw new StripeRecurringScheduleDateException('Unsupported recurring period.');
    }

    private static Boolean isSupportedPeriod(String period) {
        return 'Daily'.equalsIgnoreCase(period) || 'Weekly'.equalsIgnoreCase(period) ||
            'Monthly'.equalsIgnoreCase(period) || 'Yearly'.equalsIgnoreCase(period);
    }

    /** Domain exception for invalid date-calculation inputs. */
    public class StripeRecurringScheduleDateException extends Exception {}
}