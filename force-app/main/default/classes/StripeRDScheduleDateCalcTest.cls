@IsTest
private class StripeRDScheduleDateCalcTest {
    @IsTest
    static void monthlyStartTodayRollsToNextOccurrence() {
        Date today = Date.newInstance(2026, 8, 20);

        StripeRDScheduleDateCalc.Result result =
            StripeRDScheduleDateCalc.calculate(
                today,
                Date.newInstance(2026, 11, 20),
                today,
                'Monthly',
                1,
                'Fixed'
            );

        Assert.isNull(result.error, 'The monthly date should be valid.');
        Assert.areEqual(Date.newInstance(2026, 8, 20), result.effectiveDate);
        Assert.areEqual(Date.newInstance(2026, 9, 20), result.firstPaymentDate,
            'A schedule starting today must first bill on the next monthly occurrence.');
        Assert.areEqual(Date.newInstance(2026, 11, 20), result.finalPaymentDate);
        Assert.areEqual(3, result.installments);
    }

    @IsTest
    static void weeklyStartTodayRollsToNextOccurrence() {
        Date today = Date.newInstance(2026, 8, 20);

        StripeRDScheduleDateCalc.Result result =
            StripeRDScheduleDateCalc.calculate(
                today,
                null,
                today,
                'Weekly',
                1,
                'Open'
            );

        Assert.isNull(result.error);
        Assert.areEqual(Date.newInstance(2026, 8, 27), result.firstPaymentDate);
        Assert.isNull(result.finalPaymentDate);
        Assert.isNull(result.installments);
    }

    @IsTest
    static void misalignedFixedEndUsesLastOccurrenceAndWarning() {
        Date today = Date.newInstance(2026, 8, 20);

        StripeRDScheduleDateCalc.Result result =
            StripeRDScheduleDateCalc.calculate(
                Date.newInstance(2026, 8, 27),
                Date.newInstance(2026, 9, 25),
                today,
                'Weekly',
                1,
                'Fixed'
            );

        Assert.isNull(result.error);
        Assert.areEqual(Date.newInstance(2026, 9, 24), result.finalPaymentDate);
        Assert.areEqual(5, result.installments);
        Assert.isTrue(result.warning.contains('last scheduled payment'),
            'The normalized final date must explain the boundary.');
    }

    @IsTest
    static void fixedEndBeforeFirstPaymentIsBlocked() {
        StripeRDScheduleDateCalc.Result result =
            StripeRDScheduleDateCalc.calculate(
                Date.newInstance(2026, 8, 27),
                Date.newInstance(2026, 8, 20),
                Date.newInstance(2026, 8, 20),
                'Weekly',
                1,
                'Fixed'
            );

        Assert.isNotNull(result.error);
        Assert.isTrue(result.error.contains('after the first payment'));
    }

    @IsTest
    static void pastStartRollsForwardStrictlyAfterToday() {
        StripeRDScheduleDateCalc.Result result =
            StripeRDScheduleDateCalc.calculate(
                Date.newInstance(2026, 8, 6),
                null,
                Date.newInstance(2026, 8, 20),
                'Weekly',
                1,
                'Open'
            );

        Assert.isNull(result.error);
        Assert.areEqual(Date.newInstance(2026, 8, 20), result.effectiveDate);
        Assert.areEqual(Date.newInstance(2026, 8, 27), result.firstPaymentDate,
            'A past date is advanced to the next cadence occurrence strictly after today.');
    }

    @IsTest
    static void cadenceBoundaryUsesLatestPaidPlusRequestedInterval() {
        Date paid = Date.newInstance(2026, 8, 24);
        Map<String, Date> expectedByPeriod = new Map<String, Date>{
            'Daily' => Date.newInstance(2026, 8, 25),
            'Weekly' => Date.newInstance(2026, 8, 31),
            'Monthly' => Date.newInstance(2026, 9, 24),
            'Yearly' => Date.newInstance(2027, 8, 24)
        };

        for (String period : expectedByPeriod.keySet()) {
            StripeRDScheduleDateCalc.Result result =
                StripeRDScheduleDateCalc.calculateTermsBoundary(
                    paid, Date.newInstance(2026, 9, 24), paid,
                    period, 1, true
                );
            Assert.isNull(result.error);
            Assert.areEqual(expectedByPeriod.get(period), result.firstPaymentDate, period);
            Assert.areEqual(paid.addDays(1), result.managedEffectiveFromDate, period);
            Assert.areEqual(expectedByPeriod.get(period), result.effectiveDate, period);
        }
    }

    @IsTest
    static void amountBoundaryRetainsExistingFutureUnpaidDate() {
        Date today = Date.newInstance(2026, 8, 24);
        Date renewal = Date.newInstance(2026, 9, 24);

        StripeRDScheduleDateCalc.Result result =
            StripeRDScheduleDateCalc.calculateTermsBoundary(
                today, renewal, today, 'Monthly', 1, false
            );

        Assert.areEqual(renewal, result.firstPaymentDate);
        Assert.areEqual(renewal, result.managedEffectiveFromDate);
        Assert.areEqual(today, result.effectiveDate,
            'Stripe applies the amount now while retaining the renewal anchor.');
    }

    @IsTest
    static void temporaryAmountWindowIsBlocked_WhenNoOriginalRenewalOccurs() {
        StripeRDScheduleDateCalc.TemporaryWindowResult result =
            StripeRDScheduleDateCalc.calculateTemporaryWindow(
                Date.newInstance(2026, 8, 25),
                Date.newInstance(2026, 9, 1),
                Date.newInstance(2026, 9, 15),
                'Monthly',
                1,
                'Monthly',
                1,
                false
            );

        Assert.areEqual(
            'The temporary amount window does not contain a scheduled payment.',
            result.error,
            'An amount-only window must not be saved when the original renewal falls outside it.'
        );
    }

    @IsTest
    static void temporaryCadenceWindowCalculatesTargetAndRestorationDates() {
        StripeRDScheduleDateCalc.TemporaryWindowResult result =
            StripeRDScheduleDateCalc.calculateTemporaryWindow(
                Date.newInstance(2026, 8, 25),
                Date.newInstance(2026, 9, 1),
                Date.newInstance(2026, 9, 15),
                'Monthly',
                1,
                'Weekly',
                1,
                true
            );

        Assert.isNull(result.error, 'The cadence window should contain three weekly payments.');
        Assert.areEqual(Date.newInstance(2026, 9, 1), result.firstTemporaryPaymentDate,
            'The first weekly payment starts on the effective boundary.');
        Assert.areEqual(Date.newInstance(2026, 9, 15), result.lastTemporaryPaymentDate,
            'The inclusive window includes the 15 September weekly payment.');
        Assert.areEqual(3, result.temporaryInstallments,
            'The window should contain exactly three weekly payments.');
        Assert.areEqual(Date.newInstance(2026, 9, 25), result.restorationFirstPaymentDate,
            'The original monthly billing calendar resumes on the original day of month.');
    }

    @IsTest
    static void monthlyDayChangeUsesSelectedDayAfterLatestPaidDate() {
        StripeRDScheduleDateCalc.Result result = StripeRDScheduleDateCalc.calculateTermsBoundary(
            Date.newInstance(2026, 9, 1),
            null,
            Date.newInstance(2026, 9, 1),
            'Monthly',
            1,
            false,
            '1',
            '15'
        );

        Assert.isNull(result.error);
        Assert.areEqual('15', result.requestedTransactionDay);
        Assert.isTrue(result.billingAnchorChanged);
        Assert.areEqual(Date.newInstance(2026, 9, 15), result.firstPaymentDate);
        Assert.areEqual(Date.newInstance(2026, 9, 15), result.effectiveDate,
            'Amount and day changes activate together on the selected payment date.');
        Assert.areEqual(Date.newInstance(2026, 9, 2), result.managedEffectiveFromDate,
            'The Salesforce successor boundary must remain strictly after the paid date.');
    }

    @IsTest
    static void sameMonthlyDayAfterPaymentRollsToFollowingMonth() {
        StripeRDScheduleDateCalc.Result result = StripeRDScheduleDateCalc.calculateTermsBoundary(
            Date.newInstance(2026, 9, 15),
            null,
            Date.newInstance(2026, 9, 15),
            'Monthly',
            1,
            false,
            '15',
            '15'
        );

        Assert.isNull(result.error);
        Assert.isFalse(result.billingAnchorChanged);
        Assert.areEqual(Date.newInstance(2026, 10, 15), result.firstPaymentDate,
            'A day already paid must not be charged a second time.');
    }

    @IsTest
    static void lastDayUsesSalesforceLateMonthBehavior() {
        Assert.areEqual(
            Date.newInstance(2027, 2, 28),
            StripeRDScheduleDateCalc.nextMonthlyTransactionDate(
                Date.newInstance(2027, 2, 1), 'LastDay'
            )
        );
        Assert.areEqual(
            Date.newInstance(2027, 2, 28),
            StripeRDScheduleDateCalc.nextMonthlyTransactionDate(
                Date.newInstance(2027, 1, 30), '30'
            ),
            'Day 30 must clamp to the final day in February.'
        );
    }

    @IsTest
    static void invalidMonthlyTransactionDayIsRejected() {
        StripeRDScheduleDateCalc.Result result = StripeRDScheduleDateCalc.calculateTermsBoundary(
            Date.newInstance(2026, 9, 1),
            null,
            Date.newInstance(2026, 9, 1),
            'Monthly',
            1,
            false,
            '1',
            '31'
        );

        Assert.areEqual(
            'Transaction Day is required for Monthly and must be a permitted day.',
            result.error
        );
    }
}