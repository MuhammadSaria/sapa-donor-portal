@IsTest
private class StripeRecurringScheduleGatewayTest {
    private static List<String> methods = new List<String>();
    private static List<String> endpoints = new List<String>();
    private static List<String> bodies = new List<String>();
    private static List<String> idempotencyKeys = new List<String>();

    private class StripeMock implements HttpCalloutMock {
        private Long periodStart;
        private Long periodEnd;
        private String scheduleId;
        private Boolean sapaOwned;
        private Boolean pendingUpdate;
        private String currentInterval;
        private Integer currentIntervalCount;
        private Long currentUnitAmount;
        private String activePriceId = 'price_old';
        private Long cancelAt;
        private Boolean cancelAtPeriodEnd = false;
        private String configuredScheduleId;
        private Long configuredPhaseStart;
        private String configuredTargetPriceId;
        private Long configuredRestoreStart;
        private String configuredRestorePriceId;
        private String futurePriceId;
        private Long futureUnitAmount;
        private String futureInterval;
        private Integer futureIntervalCount;

        StripeMock(Date nextBillingDate, String scheduleId, Boolean sapaOwned, Boolean pendingUpdate) {
            this(nextBillingDate, scheduleId, sapaOwned, pendingUpdate, 'month', 1, 3000);
        }

        StripeMock(
            Date nextBillingDate,
            String scheduleId,
            Boolean sapaOwned,
            Boolean pendingUpdate,
            String currentInterval,
            Integer currentIntervalCount,
            Long currentUnitAmount
        ) {
            this.periodEnd = Datetime.newInstanceGmt(nextBillingDate, Time.newInstance(12, 0, 0, 0)).getTime() / 1000;
            this.periodStart = this.periodEnd - 2592000;
            this.scheduleId = scheduleId;
            this.sapaOwned = sapaOwned;
            this.pendingUpdate = pendingUpdate;
            this.currentInterval = currentInterval;
            this.currentIntervalCount = currentIntervalCount;
            this.currentUnitAmount = currentUnitAmount;
        }

        void configureExistingFuturePrice(
            String priceId,
            Long unitAmount,
            String intervalName,
            Integer intervalCount
        ) {
            this.futurePriceId = priceId;
            this.futureUnitAmount = unitAmount;
            this.futureInterval = intervalName;
            this.futureIntervalCount = intervalCount;
        }

        void setCurrentPeriodStart(Date dateValue) {
            this.periodStart = Datetime.newInstanceGmt(
                dateValue,
                Time.newInstance(12, 0, 0, 0)
            ).getTime() / 1000;
        }

        public HttpResponse respond(HttpRequest request) {
            methods.add(request.getMethod());
            endpoints.add(request.getEndpoint());
            bodies.add(request.getBody());
            idempotencyKeys.add(request.getHeader('Idempotency-Key'));

            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            if (request.getMethod() == 'GET' && request.getEndpoint().contains('/subscriptions/sub_1')) {
                String scheduleJson = scheduleId == null ? 'null' : '\"' + scheduleId + '\"';
                response.setBody('{\"id\":\"sub_1\",\"status\":\"active\",\"collection_method\":\"charge_automatically\",' +
                    '\"current_period_start\":' + periodStart + ',\"current_period_end\":' + periodEnd + ',' +
                    '\"billing_cycle_anchor\":' + periodStart + ',\"schedule\":' + scheduleJson + ',' +
                    '\"cancel_at\":' + (cancelAt == null ? 'null' : String.valueOf(cancelAt)) + ',' +
                    '\"cancel_at_period_end\":' + String.valueOf(cancelAtPeriodEnd) + ',' +
                    '\"items\":{\"data\":[{\"id\":\"si_1\",\"quantity\":3,\"price\":{\"id\":\"' + activePriceId + '\",' +
                    '\"unit_amount\":' + currentUnitAmount + ',\"product\":\"prod_1\",\"currency\":\"usd\",' +
                    '\"recurring\":{\"interval\":\"' + currentInterval + '\",\"interval_count\":' + currentIntervalCount + '}}}]}}');
            } else if (request.getMethod() == 'GET' && request.getEndpoint().contains('/subscription_schedules/')) {
                String requestedScheduleId = request.getEndpoint().substring(request.getEndpoint().lastIndexOf('/') + 1);
                Boolean configured = configuredScheduleId == requestedScheduleId;
                String owner = (configured || sapaOwned)
                    ? '\"sapa_owner\":\"salesforce\",\"salesforce_id\":\"6gc000000000001AAA\"'
                    : '\"external_owner\":\"other\"';
                String phases = configured
                    ? ',\"phases\":[{\"start_date\":' + periodStart + ',\"end_date\":' + configuredPhaseStart +
                        ',\"items\":[{\"price\":\"price_old\",\"quantity\":3}]},{\"start_date\":' + configuredPhaseStart +
                        ',\"items\":[{\"price\":\"' + configuredTargetPriceId + '\",\"quantity\":3}],' +
                        '\"metadata\":{\"salesforce_change_id\":\"a01000000000001AAA\",\"sapa_phase_role\":\"target\"}}' +
                        (configuredRestoreStart == null ? '' : ',{\"start_date\":' + configuredRestoreStart +
                            ',\"items\":[{\"price\":\"' + configuredRestorePriceId + '\",\"quantity\":3}],' +
                            '\"metadata\":{\"salesforce_change_id\":\"a01000000000001AAA\",\"sapa_phase_role\":\"restored\"}}') + ']'
                    : futurePriceId == null
                        ? ''
                        : ',\"phases\":[{\"start_date\":' + periodStart + ',\"end_date\":' + periodEnd +
                            ',\"items\":[{\"price\":\"price_old\",\"quantity\":3}]},{\"start_date\":' + periodEnd +
                            ',\"items\":[{\"price\":\"' + futurePriceId + '\",\"quantity\":3}]}]';
                response.setBody('{\"id\":\"' + requestedScheduleId + '\",\"status\":\"active\",\"subscription\":\"sub_1\",' +
                    '\"metadata\":{' + owner + '},\"current_phase\":{\"start_date\":' + periodStart +
                    ',\"end_date\":' + periodEnd + '}' + phases + '}');
            } else if (request.getMethod() == 'GET' && request.getEndpoint().contains('/prices/')) {
                String requestedPriceId = request.getEndpoint().substring(request.getEndpoint().lastIndexOf('/') + 1);
                Long requestedUnitAmount = requestedPriceId == futurePriceId
                    ? futureUnitAmount
                    : futureUnitAmount + 1;
                response.setBody('{\"id\":\"' + requestedPriceId + '\",\"unit_amount\":' + requestedUnitAmount +
                    ',\"product\":\"prod_1\",\"currency\":\"usd\",\"recurring\":{\"interval\":\"' +
                    futureInterval + '\",\"interval_count\":' + futureIntervalCount + '}}');
            } else if (request.getEndpoint().endsWith('/prices')) {
                response.setBody('{\"id\":\"price_new\"}');
            } else if (request.getEndpoint().endsWith('/release')) {
                response.setBody('{\"id\":\"' + scheduleId + '\",\"released_subscription\":\"sub_1\"}');
            } else if (request.getEndpoint().contains('/subscriptions/sub_1')) {
                Map<String, String> form = parseForm(request.getBody());
                if (!pendingUpdate && form.containsKey('items[0][price]')) {
                    activePriceId = form.get('items[0][price]');
                }
                if (form.containsKey('cancel_at_period_end')) {
                    cancelAtPeriodEnd = form.get('cancel_at_period_end') == 'true';
                }
                if (form.containsKey('cancel_at')) {
                    cancelAt = String.isBlank(form.get('cancel_at')) ? null : Long.valueOf(form.get('cancel_at'));
                }
                if (pendingUpdate) {
                    response.setBody('{\"id\":\"sub_1\",\"pending_update\":{\"expires_at\":' + (periodEnd + 3600) +
                        ',\"subscription_items\":[{}]},\"latest_invoice\":{\"id\":\"in_pending\"},' +
                        '\"items\":{\"data\":[{\"id\":\"si_1\",\"quantity\":3,\"price\":{\"id\":\"price_old\"}}]}}');
                } else {
                    response.setBody('{\"id\":\"sub_1\",\"pending_update\":null,\"latest_invoice\":{\"id\":\"in_paid\"},' +
                        '\"items\":{\"data\":[{\"id\":\"si_1\",\"quantity\":3,\"price\":{\"id\":\"price_new\"}}]}}');
                }
            } else if (request.getEndpoint().endsWith('/subscription_schedules')) {
                response.setBody('{\"id\":\"sub_sched_new\",\"subscription\":\"sub_1\",\"metadata\":{\"sapa_owner\":\"salesforce\"}}');
            } else {
                Map<String, String> form = parseForm(request.getBody());
                configuredScheduleId = request.getEndpoint().substring(request.getEndpoint().lastIndexOf('/') + 1);
                configuredPhaseStart = Long.valueOf(form.get('phases[1][start_date]'));
                configuredTargetPriceId = form.get('phases[1][items][0][price]');
                if (form.containsKey('phases[2][start_date]')) {
                    configuredRestoreStart = Long.valueOf(form.get('phases[2][start_date]'));
                    configuredRestorePriceId = form.get('phases[2][items][0][price]');
                }
                response.setBody('{\"id\":\"' + configuredScheduleId + '\",' +
                    '\"metadata\":{\"sapa_owner\":\"salesforce\"},\"phases\":[{\"start_date\":' + periodStart +
                    ',\"items\":[{\"price\":\"price_old\",\"quantity\":3}]},{\"start_date\":' + periodEnd +
                    ',\"items\":[{\"price\":\"price_new\",\"quantity\":3}]}]}');
            }
            return response;
        }
    }

    /**
     * Stateful Stripe contract double that rejects request combinations rejected by Stripe.
     */
    private class StrictStripeContractMock implements HttpCalloutMock {
        private Long periodStart;
        private Long periodEnd;
        private String currentPriceId = 'price_old';
        private String currentInterval = 'month';
        private Integer currentIntervalCount = 1;
        private Long currentUnitAmount = 3000;
        private String targetInterval = 'month';
        private Integer targetIntervalCount = 1;
        private Long targetUnitAmount = 4000;
        private String scheduleId;
        private Boolean scheduleConfigured = false;
        private Long targetPhaseStart;
        private Long cancelAt;
        private Boolean cancelAtPeriodEnd;
        private Boolean pendingUpdate;

        StrictStripeContractMock(
            Date nextBillingDate,
            Long cancelAt,
            Boolean cancelAtPeriodEnd,
            Boolean pendingUpdate
        ) {
            this.periodEnd = Datetime.newInstanceGmt(nextBillingDate, Time.newInstance(12, 0, 0, 0)).getTime() / 1000;
            this.periodStart = this.periodEnd - 2592000;
            this.cancelAt = cancelAt;
            this.cancelAtPeriodEnd = cancelAtPeriodEnd;
            this.pendingUpdate = pendingUpdate;
        }

        public HttpResponse respond(HttpRequest request) {
            methods.add(request.getMethod());
            endpoints.add(request.getEndpoint());
            bodies.add(request.getBody());
            idempotencyKeys.add(request.getHeader('Idempotency-Key'));

            Map<String, String> form = parseForm(request.getBody());
            if (request.getMethod() == 'GET' && request.getEndpoint().contains('/subscriptions/sub_1')) {
                return jsonResponse(200, subscriptionPayload(null));
            }
            if (request.getMethod() == 'GET' && request.getEndpoint().contains('/subscription_schedules/')) {
                return jsonResponse(200, schedulePayload());
            }
            if (request.getMethod() == 'POST' && request.getEndpoint().endsWith('/prices')) {
                targetInterval = form.get('recurring[interval]');
                targetIntervalCount = Integer.valueOf(form.get('recurring[interval_count]'));
                targetUnitAmount = Long.valueOf(form.get('unit_amount'));
                return jsonResponse(200, new Map<String, Object>{ 'id' => 'price_new' });
            }
            if (request.getMethod() == 'POST' && request.getEndpoint().endsWith('/subscription_schedules')) {
                if (form.size() != 1 || form.get('from_subscription') != 'sub_1') {
                    return stripeError('You cannot set metadata or phases if from_subscription is set.');
                }
                scheduleId = 'sub_sched_contract';
                return jsonResponse(200, new Map<String, Object>{
                    'id' => scheduleId,
                    'subscription' => 'sub_1',
                    'metadata' => new Map<String, Object>()
                });
            }
            if (request.getMethod() == 'POST' &&
                request.getEndpoint().contains('/subscription_schedules/sub_sched_contract')) {
                if (form.containsKey('phases[1][cancel_at_period_end]')) {
                    return stripeError('Received unknown parameter: phases[1][cancel_at_period_end]');
                }
                scheduleConfigured = true;
                targetPhaseStart = Long.valueOf(form.get('phases[1][start_date]'));
                return jsonResponse(200, schedulePayload());
            }
            if (request.getMethod() == 'POST' && request.getEndpoint().contains('/subscriptions/sub_1')) {
                Boolean hasCancelAt = form.containsKey('cancel_at');
                Boolean hasCancelAtPeriodEnd = form.containsKey('cancel_at_period_end');
                if (form.containsKey('payment_behavior') && (hasCancelAt || hasCancelAtPeriodEnd)) {
                    return stripeError('Cancellation fields are not supported with pending_if_incomplete.');
                }
                if (hasCancelAt && hasCancelAtPeriodEnd) {
                    return stripeError('Received both cancel_at_period_end and cancel_at parameters.');
                }
                if (form.containsKey('payment_behavior')) {
                    if (!pendingUpdate && form.containsKey('items[0][price]')) {
                        currentPriceId = form.get('items[0][price]');
                        currentInterval = targetInterval;
                        currentIntervalCount = targetIntervalCount;
                        currentUnitAmount = targetUnitAmount;
                    }
                    Map<String, Object> pending = pendingUpdate
                        ? new Map<String, Object>{
                            'expires_at' => periodEnd + 3600,
                            'subscription_items' => new List<Object>{ new Map<String, Object>() }
                        }
                        : null;
                    return jsonResponse(200, subscriptionPayload(pending));
                }
                if (hasCancelAtPeriodEnd) {
                    cancelAtPeriodEnd = form.get('cancel_at_period_end') == 'true';
                }
                if (hasCancelAt) {
                    cancelAt = String.isBlank(form.get('cancel_at')) ? null : Long.valueOf(form.get('cancel_at'));
                }
                return jsonResponse(200, subscriptionPayload(null));
            }
            return stripeError('Unexpected Stripe test request.');
        }

        private Map<String, Object> subscriptionPayload(Map<String, Object> pending) {
            return new Map<String, Object>{
                'id' => 'sub_1',
                'status' => 'active',
                'collection_method' => 'charge_automatically',
                'current_period_start' => periodStart,
                'current_period_end' => periodEnd,
                'billing_cycle_anchor' => periodStart,
                'schedule' => scheduleId,
                'cancel_at' => cancelAt,
                'cancel_at_period_end' => cancelAtPeriodEnd,
                'pending_update' => pending,
                'latest_invoice' => new Map<String, Object>{ 'id' => pending == null ? 'in_paid' : 'in_pending' },
                'items' => new Map<String, Object>{
                    'data' => new List<Object>{
                        new Map<String, Object>{
                            'id' => 'si_1',
                            'quantity' => 3,
                            'price' => new Map<String, Object>{
                                'id' => currentPriceId,
                                'unit_amount' => currentUnitAmount,
                                'product' => 'prod_1',
                                'currency' => 'usd',
                                'recurring' => new Map<String, Object>{
                                    'interval' => currentInterval,
                                    'interval_count' => currentIntervalCount
                                }
                            }
                        }
                    }
                }
            };
        }

        private Map<String, Object> schedulePayload() {
            Map<String, Object> payload = new Map<String, Object>{
                'id' => scheduleId,
                'status' => 'active',
                'subscription' => 'sub_1',
                'metadata' => scheduleConfigured
                    ? new Map<String, Object>{ 'sapa_owner' => 'salesforce', 'salesforce_id' => '6gc000000000001AAA' }
                    : new Map<String, Object>(),
                'current_phase' => new Map<String, Object>{
                    'start_date' => periodStart,
                    'end_date' => targetPhaseStart
                }
            };
            if (scheduleConfigured) {
                payload.put('phases', new List<Object>{
                    new Map<String, Object>{
                        'start_date' => periodStart,
                        'end_date' => targetPhaseStart,
                        'items' => new List<Object>{
                            new Map<String, Object>{ 'price' => 'price_old', 'quantity' => 3 }
                        }
                    },
                    new Map<String, Object>{
                        'start_date' => targetPhaseStart,
                        'items' => new List<Object>{
                            new Map<String, Object>{ 'price' => 'price_new', 'quantity' => 3 }
                        },
                        'metadata' => new Map<String, Object>{
                            'sapa_owner' => 'salesforce',
                            'salesforce_id' => '6gc000000000001AAA',
                            'salesforce_change_id' => 'a01000000000001AAA'
                        }
                    }
                });
            }
            return payload;
        }

        private HttpResponse stripeError(String message) {
            return jsonResponse(400, new Map<String, Object>{
                'error' => new Map<String, Object>{ 'message' => message }
            });
        }
    }

    @IsTest
    static void previewAmountOnlyTodayRetainsRenewalAndDoesNotInvoice() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date nextBilling = Date.today().addDays(10);
        Test.setMock(HttpCalloutMock.class, new StripeMock(nextBilling, null, false, false));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(Date.today(), 'Monthly', 1);

        Test.startTest();
        StripeRecurringScheduleGateway.PreviewResult preview = StripeRecurringScheduleGateway.previewChange(change);
        Test.stopTest();

        Assert.isTrue(preview.canProceed, 'A valid same-cadence change should be allowed.');
        Assert.areEqual('Immediate', preview.actionMode, 'Today must use immediate mode.');
        Assert.areEqual(nextBilling, preview.firstPaymentDate, 'Amount-only updates must retain the existing renewal.');
        Assert.isFalse(preview.willGenerateFullInvoice, 'Amount-only changes must not invoice immediately.');
        Assert.areEqual(30, preview.currentAmount, 'Preview must expose the current Stripe amount.');
        Assert.areEqual(1, endpoints.size(), 'Preview must be read-only and retrieve Stripe once.');
        Assert.areEqual('GET', methods[0], 'Preview must not mutate Stripe.');
    }

    @IsTest
    static void previewCadenceChangeTodayShowsFullInvoiceAndNewAnchor() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date nextBilling = Date.today().addDays(10);
        Test.setMock(HttpCalloutMock.class, new StripeMock(nextBilling, null, false, false));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(Date.today(), 'Weekly', 1);

        StripeRecurringScheduleGateway.PreviewResult preview = StripeRecurringScheduleGateway.previewChange(change);

        Assert.areEqual(nextBilling, preview.firstPaymentDate,
            'Cadence changes must not bill when staff saves; the future phase starts on the calculated payment date.');
        Assert.isTrue(preview.willGenerateFullInvoice,
            'Cadence changes generate one full invoice only when the future phase activates.');
        Assert.isTrue(preview.businessWarning.contains('no charge today'),
            'The preview must explain that saving the change does not charge immediately.');
    }

    @IsTest
    static void previewRejectsPastEffectiveDateBeforeCallout() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(Date.today().addDays(-1), 'Monthly', 1);

        StripeRecurringScheduleGateway.PreviewResult preview = StripeRecurringScheduleGateway.previewChange(change);

        Assert.isFalse(preview.canProceed, 'Past effective dates must be blocked.');
        Assert.isTrue(preview.blockingError.contains('past'), 'The blocking error must explain the date rule.');
        Assert.areEqual(0, endpoints.size(), 'A locally invalid request must not call Stripe.');
    }

    @IsTest
    static void appliesImmediateAmountChangeWithoutProrationOrAnchorReset() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Test.setMock(HttpCalloutMock.class, new StripeMock(Date.today().addDays(10), null, false, false));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(Date.today(), 'Monthly', 1);

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result = StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        Assert.areEqual('Immediate', result.actionMode, 'Today must update the subscription directly.');
        Assert.areEqual('price_new', result.priceId, 'The active reusable Price must be returned.');
        Assert.isFalse(result.hasPendingUpdate, 'A successful payment-free update is applied immediately.');
        String updateBody = lastRequestBody('POST', '/subscriptions/sub_1');
        Assert.isTrue(updateBody.contains('items%5B0%5D%5Bid%5D=si_1'), 'The existing subscription item must be replaced.');
        Assert.isTrue(updateBody.contains('items%5B0%5D%5Bquantity%5D=3'), 'The existing quantity must be preserved.');
        Assert.isTrue(updateBody.contains('proration_behavior=none'), 'Proration must always be disabled.');
        Assert.isTrue(updateBody.contains('payment_behavior=pending_if_incomplete'), 'Immediate invoices must be payment-safe.');
        Assert.isFalse(updateBody.contains('billing_cycle_anchor=now'), 'Same cadence must retain the renewal anchor.');
    }

    @IsTest
    static void dateOnlyChangeReusesCurrentPriceAndNeverCreatesAnotherPrice() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date futureFirstPayment = Date.today().addDays(20);
        Test.setMock(HttpCalloutMock.class,
            new StripeMock(Date.today().addDays(10), null, false, false, 'month', 1, 4000));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(futureFirstPayment, 'Monthly', 1);
        change.firstPaymentDate = futureFirstPayment;

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result = StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        Assert.areEqual('price_old', result.priceId,
            'A date-only change must reuse the active Stripe Price.');
        Integer priceCreates = 0;
        for (Integer index = 0; index < endpoints.size(); index++) {
            if (methods[index] == 'POST' && endpoints[index].endsWith('/prices')) priceCreates++;
        }
        Assert.areEqual(0, priceCreates,
            'A date-only change must not create another reusable Price.');
    }

    @IsTest
    static void endDateOnlyFixedUsesCancellationWithoutPriceOrInvoice() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Test.setMock(HttpCalloutMock.class,
            new StrictStripeContractMock(Date.today().addDays(10), null, false, false));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(Date.today(), 'Monthly', 1);
        change.changeMode = StripeRecurringChangeMode.END_DATE_ONLY;
        change.recurringType = 'Fixed';
        change.firstPaymentDate = Date.today();
        change.finalPaymentDate = Date.today();
        change.plannedInstallments = 1;

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result =
            StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        Assert.areEqual('Immediate', result.actionMode);
        Assert.areEqual('price_old', result.priceId,
            'End Date only must retain the active Price.');
        Assert.areEqual(0, countRequests('POST', '/prices'),
            'End Date only must not create a Price.');
        Assert.areEqual(0, countRequests('POST', '/subscription_schedules'),
            'End Date only must not create a Subscription Schedule.');
        Boolean sawCancellation = false;
        for (Integer index = 0; index < endpoints.size(); index++) {
            if (methods[index] != 'POST' || !endpoints[index].endsWith('/subscriptions/sub_1')) continue;
            Map<String, String> form = parseForm(bodies[index]);
            if (form.containsKey('cancel_at')) {
                sawCancellation = true;
                Assert.isFalse(form.containsKey('cancel_at_period_end'),
                    'Cancellation-only updates must not send a second cancellation parameter.');
                Assert.areEqual(
                    String.valueOf(Datetime.newInstanceGmt(Date.today().addDays(1), Time.newInstance(12, 0, 0, 0)).getTime() / 1000),
                    form.get('cancel_at')
                );
                Assert.isFalse(form.containsKey('payment_behavior'));
            }
        }
        Assert.isTrue(sawCancellation, 'Fixed End Date only must set a custom Stripe cancellation.');
    }

    @IsTest
    static void endDateOnlyOpenClearsCancellationWithoutPriceOrInvoice() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Long existingCancelAt = Datetime.newInstanceGmt(
            Date.today().addDays(30), Time.newInstance(12, 0, 0, 0)
        ).getTime() / 1000;
        Test.setMock(HttpCalloutMock.class,
            new StrictStripeContractMock(Date.today().addDays(10), existingCancelAt, false, false));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(Date.today(), 'Monthly', 1);
        change.changeMode = StripeRecurringChangeMode.END_DATE_ONLY;
        change.recurringType = 'Open';

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result =
            StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        Assert.areEqual('price_old', result.priceId);
        Assert.areEqual(0, countRequests('POST', '/prices'));
        Assert.areEqual(0, countRequests('POST', '/subscription_schedules'));
        Assert.isTrue(
            lastRequestBody('POST', '/subscriptions/sub_1').contains('cancel_at='),
            'Fixed to Open must clear the custom cancellation in a separate request.'
        );
        Assert.isFalse(
            lastRequestBody('POST', '/subscriptions/sub_1').contains('payment_behavior'),
            'Cancellation-only Open changes must not be payment-gated.'
        );
    }

    @IsTest
    static void openToFixedReusesMatchingFutureAnnualPrice() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date effectiveDate = Date.today().addDays(4);
        StripeMock mock = new StripeMock(
            Date.today().addDays(10), 'sub_sched_sapa', true, false, 'month', 1, 3000
        );
        mock.configureExistingFuturePrice('price_annual_existing', 4000, 'year', 1);
        Test.setMock(HttpCalloutMock.class, mock);
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(
            effectiveDate, 'Yearly', 1
        );
        change.recurringType = 'Fixed';
        change.plannedInstallments = 3;

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result =
            StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        Assert.areEqual('price_annual_existing', result.priceId,
            'Open to Fixed must reuse the matching annual Price already in the SAPA future phase.');
        Assert.areEqual(0, countRequests('POST', '/prices'),
            'A recurring-type-only future edit must not create an equivalent annual Price.');
        Map<String, String> scheduleForm = parseForm(
            lastRequestBody('POST', '/subscription_schedules/sub_sched_sapa')
        );
        Assert.areEqual('price_annual_existing', scheduleForm.get('phases[1][items][0][price]'),
            'The Fixed target phase must use the existing annual Price.');
        Assert.areEqual('3', scheduleForm.get('phases[1][items][0][quantity]'),
            'The existing subscription item quantity must be preserved.');
        Assert.areEqual('cancel', scheduleForm.get('end_behavior'),
            'The Fixed schedule must cancel only after its target phase completes.');
        Assert.areEqual('none', scheduleForm.get('phases[1][proration_behavior]'),
            'The Fixed target phase must not create proration adjustments.');
        Long expectedEnd = Datetime.newInstanceGmt(
            effectiveDate.addYears(2).addDays(1), Time.newInstance(12, 0, 0, 0)
        ).getTime() / 1000;
        Assert.areEqual(String.valueOf(expectedEnd), scheduleForm.get('phases[1][end_date]'),
            'The Fixed phase must end one day after the final payment on 2028-08-19.');
    }

    @IsTest
    static void fixedToOpenReusesAnnualPriceAndReleasesSchedule() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date effectiveDate = Date.today().addDays(4);
        StripeMock mock = new StripeMock(
            Date.today().addDays(10), 'sub_sched_sapa', true, false, 'month', 1, 3000
        );
        mock.configureExistingFuturePrice('price_annual_existing', 4000, 'year', 1);
        Test.setMock(HttpCalloutMock.class, mock);
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(
            effectiveDate, 'Yearly', 1
        );
        change.recurringType = 'Open';

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result =
            StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        Assert.areEqual('price_annual_existing', result.priceId,
            'Fixed to Open must retain the matching annual future Price.');
        Assert.areEqual(0, countRequests('POST', '/prices'),
            'Fixed to Open must not create another equivalent annual Price.');
        Map<String, String> scheduleForm = parseForm(
            lastRequestBody('POST', '/subscription_schedules/sub_sched_sapa')
        );
        Assert.areEqual('release', scheduleForm.get('end_behavior'),
            'The Open schedule must release the subscription to continue indefinitely.');
        Assert.isFalse(scheduleForm.containsKey('phases[1][end_date]'),
            'The Open target phase must not retain the Fixed final date.');
        Assert.isFalse(scheduleForm.containsKey('phases[1][items][1][price]'),
            'The Open target phase must contain exactly one subscription item.');
    }

    @IsTest
    static void treatsEffectiveDateAtCurrentStripePhaseStartAsImmediate() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date effectiveDate = Date.today().addDays(1);
        StripeMock mock = new StripeMock(Date.today().addDays(10), null, false, false);
        mock.setCurrentPeriodStart(effectiveDate);
        Test.setMock(HttpCalloutMock.class, mock);
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(
            effectiveDate,
            'Yearly',
            1
        );
        change.recurringType = 'Open';

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result =
            StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        Assert.areEqual('Immediate', result.actionMode,
            'A date that has already become the active Stripe phase must not be scheduled again.');
        Assert.areEqual(0, countRequests('POST', '/subscription_schedules'),
            'The boundary case must not create a phase at the current phase start.');
        String updateBody = lastRequestBody('POST', '/subscriptions/sub_1');
        Assert.isTrue(updateBody.contains('billing_cycle_anchor=now'),
            'The cadence change must use the immediate subscription path.');
    }

    @IsTest
    static void retryReusesStoredMatchingTargetPrice() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date effectiveDate = Date.today().addDays(4);
        StripeMock mock = new StripeMock(
            Date.today().addDays(10), 'sub_sched_sapa', true, false, 'month', 1, 3000
        );
        mock.configureExistingFuturePrice('price_annual_existing', 4000, 'year', 1);
        Test.setMock(HttpCalloutMock.class, mock);
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(
            effectiveDate, 'Yearly', 1
        );
        change.targetPriceId = 'price_annual_existing';

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result =
            StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        Assert.areEqual('price_annual_existing', result.priceId,
            'Retry must validate and reuse the stored target Price.');
        Assert.areEqual(0, countRequests('POST', '/prices'),
            'Retry must not create a new Price after the original target Price was stored.');
        Assert.areEqual(1, countRequests('GET', '/prices/price_annual_existing'),
            'Retry must re-read the stored target Price before mutating the schedule.');
    }

    @IsTest
    static void retryRejectsStoredMismatchedTargetPriceBeforeMutation() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        StripeMock mock = new StripeMock(
            Date.today().addDays(10), 'sub_sched_sapa', true, false, 'month', 1, 3000
        );
        mock.configureExistingFuturePrice('price_annual_existing', 4000, 'year', 1);
        Test.setMock(HttpCalloutMock.class, mock);
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(
            Date.today().addDays(4), 'Yearly', 1
        );
        change.targetPriceId = 'price_wrong_amount';

        Test.startTest();
        try {
            StripeRecurringScheduleGateway.applyChange(change);
            Assert.fail('A retry must reject a stored Price with mismatched immutable attributes.');
        } catch (StripeRecurringScheduleGateway.StripeRecurringScheduleException expected) {
            Assert.isTrue(expected.getMessage().contains('does not match'),
                'The retry error must identify the stored Price mismatch.');
        }
        Test.stopTest();

        Assert.areEqual(0, countRequests('POST', '/prices'),
            'A mismatched stored Price must not cause another Price creation.');
        Assert.areEqual(0, countRequests('POST', '/subscription_schedules/sub_sched_sapa'),
            'A mismatched stored Price must fail before schedule mutation.');
    }

    @IsTest
    static void appliesImmediateCadenceChangeWithFullInvoiceAndPendingUpdateCapture() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Test.setMock(HttpCalloutMock.class, new StripeMock(Date.today().addDays(10), null, false, true));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(Date.today(), 'Yearly', 1);

        StripeRecurringScheduleGateway.ChangeResult result = StripeRecurringScheduleGateway.applyChange(change);

        Assert.isTrue(result.hasPendingUpdate, 'A failed immediate invoice must remain a Stripe pending update.');
        Assert.areEqual('in_pending', result.invoiceId, 'The pending invoice must be retained for support and retry.');
        Assert.isNotNull(result.pendingUpdateExpiresAt, 'The pending update expiration must be retained.');
        String updateBody = bodies[bodies.size() - 1];
        Assert.isTrue(updateBody.contains('billing_cycle_anchor=now'), 'Cadence changes must reset the cycle.');
        Assert.isTrue(updateBody.contains('proration_behavior=none'), 'Cycle reset must not create prorations.');
    }

    @IsTest
    static void createsVisibleFutureScheduleAtExactEffectiveDate() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date nextBilling = Date.today().addDays(10);
        Date effectiveDate = Date.today().addDays(4);
        Date firstPaymentDate = Date.today().addDays(7);
        Test.setMock(HttpCalloutMock.class, new StripeMock(nextBilling, null, false, false));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(effectiveDate, 'Weekly', 1);
        change.firstPaymentDate = firstPaymentDate;

        StripeRecurringScheduleGateway.ChangeResult result = StripeRecurringScheduleGateway.applyChange(change);

        Long expectedTimestamp = Datetime.newInstanceGmt(firstPaymentDate, Time.newInstance(12, 0, 0, 0)).getTime() / 1000;
        Assert.areEqual('Scheduled', result.actionMode, 'A future date must create a visible Stripe schedule.');
        Assert.areEqual('sub_sched_new', result.subscriptionScheduleId, 'The new schedule id must be retained.');
        Assert.areEqual(expectedTimestamp, result.effectiveTimestamp,
            'The target phase timestamp must use the verified first Salesforce payment date.');
        Map<String, String> scheduleForm = parseForm(lastRequestBody('POST', '/subscription_schedules/'));
        Assert.areEqual(String.valueOf(expectedTimestamp), scheduleForm.get('phases[1][start_date]'),
            'The target phase must start on the verified first Salesforce payment date.');
        Assert.areEqual('phase_start', scheduleForm.get('phases[1][billing_cycle_anchor]'),
            'A cadence change must anchor Stripe billing to the target phase start.');
        Assert.areEqual('none', scheduleForm.get('phases[1][proration_behavior]'),
            'The target phase must not prorate.');
    }

    @IsTest
    static void usesCompliantTwoStepScheduleBootstrapAndVerifiesTargetPhase() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date effectiveDate = Date.today().addDays(4);
        Test.setMock(
            HttpCalloutMock.class,
            new StrictStripeContractMock(Date.today().addDays(10), null, false, false)
        );
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result = StripeRecurringScheduleGateway.applyChange(
            validRequest(effectiveDate, 'Weekly', 1)
        );
        Test.stopTest();

        Assert.areEqual('Scheduled', result.actionMode,
            'A compliant two-step schedule request should be accepted.');
        Integer createIndex = findRequestIndex('POST', '/subscription_schedules');
        Assert.isTrue(createIndex >= 0, 'The schedule bootstrap request must be sent.');
        Map<String, String> createForm = parseForm(bodies[createIndex]);
        Assert.areEqual(1, createForm.size(),
            'The from_subscription bootstrap request must contain no other parameters.');
        Assert.areEqual('sub_1', createForm.get('from_subscription'),
            'The existing subscription must be migrated in the bootstrap request.');
        Assert.areEqual(1, countIdempotencyKey(validRequest(effectiveDate, 'Weekly', 1).idempotencyKey + '-schedule-bootstrap-v2'),
            'Schedule bootstrap must use its stable versioned idempotency key.');
        Assert.areEqual(1, countIdempotencyKey(validRequest(effectiveDate, 'Weekly', 1).idempotencyKey + '-schedule-configure-v4'),
            'Schedule configuration must use a separate stable idempotency key.');
        Assert.isTrue(countRequests('GET', '/subscription_schedules/sub_sched_contract') >= 1,
            'Stripe must be re-read to verify the target phase before returning Scheduled.');
    }

    @IsTest
    static void separatesFixedCancellationFromPaymentGatedPriceUpdate() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date nextBilling = Date.today().addDays(10);
        Test.setMock(
            HttpCalloutMock.class,
            new StrictStripeContractMock(nextBilling, null, true, false)
        );
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(Date.today(), 'Monthly', 1);
        change.recurringType = 'Fixed';
        change.plannedInstallments = 3;

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result = StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        Assert.isFalse(result.hasPendingUpdate, 'A successful immediate update must complete synchronously.');
        Long expectedCancelAt = Datetime.newInstanceGmt(
            nextBilling.addMonths(2).addDays(1),
            Time.newInstance(12, 0, 0, 0)
        ).getTime() / 1000;
        assertSeparatedSubscriptionRequests(expectedCancelAt, true);
    }

    @IsTest
    static void clearsOpenCancellationWithoutCombiningCancellationParameters() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Long existingCancelAt = Datetime.newInstanceGmt(
            Date.today().addMonths(2),
            Time.newInstance(12, 0, 0, 0)
        ).getTime() / 1000;
        Test.setMock(
            HttpCalloutMock.class,
            new StrictStripeContractMock(Date.today().addDays(10), existingCancelAt, false, false)
        );
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result = StripeRecurringScheduleGateway.applyChange(
            validRequest(Date.today(), 'Monthly', 1)
        );
        Test.stopTest();

        Assert.isFalse(result.hasPendingUpdate, 'A successful Open update must complete synchronously.');
        assertSeparatedSubscriptionRequests(null, false);
    }

    @IsTest
    static void schedulesAmountOnlyFutureChangeWithoutMutatingCurrentSubscription() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date effectiveDate = Date.today().addDays(4);
        Test.setMock(HttpCalloutMock.class,
            new StripeMock(Date.today().addDays(10), null, false, false, 'month', 1, 3000));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(effectiveDate, 'Monthly', 1);

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result = StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        Assert.areEqual('Scheduled', result.actionMode,
            'A future same-cadence amount change must be represented by a visible Stripe schedule.');
        Boolean directSubscriptionMutation = false;
        for (Integer index = 0; index < endpoints.size(); index++) {
            if (methods[index] == 'POST' && endpoints[index].endsWith('/subscriptions/sub_1')) {
                directSubscriptionMutation = true;
            }
        }
        Assert.isFalse(directSubscriptionMutation,
            'A future amount-only change must leave the current subscription item active until the effective date.');
        String scheduleBody = lastRequestBody('POST', '/subscription_schedules/');
        Assert.isTrue(scheduleBody.contains('phases%5B0%5D%5Bitems%5D%5B0%5D%5Bprice%5D=price_old'),
            'The current phase must retain the active Price.');
        Assert.isTrue(scheduleBody.contains('phases%5B1%5D%5Bitems%5D%5B0%5D%5Bprice%5D=price_new'),
            'The target phase must use the requested new Price.');
        Assert.isTrue(scheduleBody.contains('phases%5B1%5D%5Bproration_behavior%5D=none'),
            'The future amount-only phase must not create proration adjustments.');
    }

    @IsTest
    static void schedulesMonthlyDayChangeAtSelectedBillingAnchor() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date currentRenewal = Date.today().addMonths(1);
        Date selectedBillingDate = Date.today().addDays(14);
        Test.setMock(HttpCalloutMock.class,
            new StripeMock(currentRenewal, null, false, false, 'month', 1, 5000));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(
            selectedBillingDate, 'Monthly', 1
        );
        change.amount = 60;
        change.changeMode = StripeRecurringChangeMode.TERMS;
        change.transactionDay = String.valueOf(selectedBillingDate.day());
        change.firstPaymentDate = selectedBillingDate;

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result =
            StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        Assert.areEqual('Scheduled', result.actionMode,
            'A changed Monthly Transaction Day must be scheduled, not applied at save time.');
        Assert.areEqual(0, countRequests('POST', '/subscriptions/sub_1'),
            'Changing the Monthly day must not create an invoice when the Flow is saved.');
        Map<String, String> scheduleForm = parseForm(
            lastRequestBody('POST', '/subscription_schedules/')
        );
        Long expectedTimestamp = Datetime.newInstanceGmt(
            selectedBillingDate, Time.newInstance(12, 0, 0, 0)
        ).getTime() / 1000;
        Assert.areEqual(String.valueOf(expectedTimestamp), scheduleForm.get('phases[1][start_date]'));
        Assert.areEqual('phase_start', scheduleForm.get('phases[1][billing_cycle_anchor]'),
            'The selected Monthly day must become the Stripe billing anchor.');
        Assert.areEqual('none', scheduleForm.get('phases[1][proration_behavior]'));
    }

    @IsTest
    static void schedulesTemporaryAmountWindowAndRestoresOriginalPrice() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date nextBilling = Date.today().addDays(10);
        Date effectiveStart = nextBilling;
        Date effectiveEnd = nextBilling.addMonths(1);
        Date restorationDate = nextBilling.addMonths(2);
        Test.setMock(HttpCalloutMock.class,
            new StripeMock(nextBilling, null, false, false, 'month', 1, 500));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(effectiveStart, 'Monthly', 1);
        change.amount = 25;
        change.changeMode = 'TemporaryTerms';
        change.effectiveEndDate = effectiveEnd;
        change.originalAmount = 5;
        change.originalPeriod = 'Monthly';
        change.originalInterval = 1;
        change.originalPriceId = 'price_old';
        change.restorationFirstPaymentDate = restorationDate;

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result =
            StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        Assert.areEqual('Scheduled', result.actionMode,
            'A future temporary window must be visible immediately as a Stripe schedule.');
        String scheduleBody = lastRequestBody('POST', '/subscription_schedules/');
        Long restorationConfigurationTimestamp = Datetime.newInstanceGmt(
            effectiveEnd.addDays(1), Time.newInstance(12, 0, 0, 0)
        ).getTime() / 1000;
        Assert.isTrue(scheduleBody.contains('phases%5B1%5D%5Bitems%5D%5B0%5D%5Bprice%5D=price_new'),
            'The temporary phase must use the requested Price.');
        Assert.isTrue(scheduleBody.contains('phases%5B2%5D%5Bstart_date%5D=' + restorationConfigurationTimestamp),
            'The original amount must be restored on the day after the inclusive window ends.');
        Assert.isTrue(scheduleBody.contains('phases%5B2%5D%5Bitems%5D%5B0%5D%5Bprice%5D=price_old'),
            'The restored phase must reuse the original Price.');
        Assert.areEqual(1, countRequests('POST', '/prices'),
            'Only the temporary target Price may be created.');
        Assert.areEqual(0, countRequests('POST', '/subscriptions/sub_1'),
            'A future temporary window must not directly replace the live subscription item.');
    }

    @IsTest
    static void replacesExistingSapaFutureScheduleWithoutCreatingAnotherSchedule() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Test.setMock(HttpCalloutMock.class,
            new StripeMock(Date.today().addDays(10), 'sub_sched_sapa', true, false));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';

        Test.startTest();
        StripeRecurringScheduleGateway.ChangeResult result = StripeRecurringScheduleGateway.applyChange(
            validRequest(Date.today().addDays(4), 'Weekly', 1)
        );
        Test.stopTest();

        Assert.areEqual('sub_sched_sapa', result.subscriptionScheduleId,
            'A repeated future edit must reuse the existing SAPA-owned schedule.');
        Integer scheduleCreateCalls = 0;
        Integer existingScheduleUpdateCalls = 0;
        for (Integer index = 0; index < endpoints.size(); index++) {
            if (methods[index] != 'POST') continue;
            if (endpoints[index].endsWith('/subscription_schedules')) scheduleCreateCalls++;
            if (endpoints[index].endsWith('/subscription_schedules/sub_sched_sapa')) existingScheduleUpdateCalls++;
        }
        Assert.areEqual(0, scheduleCreateCalls,
            'Replacing a SAPA future phase must not create another Subscription Schedule.');
        Assert.areEqual(1, existingScheduleUpdateCalls,
            'The latest request must replace the phases on the existing SAPA-owned schedule exactly once.');
    }

    @IsTest
    static void reusesStableIdempotencyKeysAfterLostResponse() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Test.setMock(HttpCalloutMock.class, new StripeMock(Date.today().addDays(10), null, false, false));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(Date.today().addDays(4), 'Weekly', 1);

        Test.startTest();
        StripeRecurringScheduleGateway.applyChange(change);
        StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        Assert.areEqual(2, countIdempotencyKey(change.idempotencyKey + '-price'),
            'A retry after a lost response must reuse the same Price idempotency key.');
        Assert.areEqual(2, countIdempotencyKey(change.idempotencyKey + '-schedule-bootstrap-v2'),
            'A retry after a lost response must reuse the same versioned schedule-bootstrap idempotency key.');
        Assert.areEqual(2, countIdempotencyKey(change.idempotencyKey + '-schedule-configure-v4'),
            'A retry after a lost response must reuse the same versioned schedule-configuration idempotency key.');
    }

    @IsTest
    static void schedulesFutureOpenToFixedCancellationAfterFinalPayment() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date effectiveDate = Date.today().addDays(4);
        Test.setMock(HttpCalloutMock.class, new StripeMock(Date.today().addDays(10), null, false, false));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(effectiveDate, 'Weekly', 1);
        change.recurringType = 'Fixed';
        change.plannedInstallments = 3;

        Test.startTest();
        StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        Long expectedEndTimestamp = Datetime.newInstanceGmt(
            effectiveDate.addDays(15), Time.newInstance(12, 0, 0, 0)
        ).getTime() / 1000;
        String scheduleBody = lastRequestBody('POST', '/subscription_schedules/');
        Assert.isTrue(scheduleBody.contains('end_behavior=cancel'),
            'A future Open-to-Fixed change must cancel after its target phase completes.');
        Assert.isTrue(scheduleBody.contains('phases%5B1%5D%5Bend_date%5D=' + expectedEndTimestamp),
            'The fixed phase must end one day after installment three can complete.');
    }

    @IsTest
    static void schedulesFutureFixedToOpenWithReleaseBehavior() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Test.setMock(HttpCalloutMock.class, new StripeMock(Date.today().addDays(10), null, false, false));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change =
            validRequest(Date.today().addDays(4), 'Monthly', 1);
        change.recurringType = 'Open';

        Test.startTest();
        StripeRecurringScheduleGateway.applyChange(change);
        Test.stopTest();

        String scheduleBody = lastRequestBody('POST', '/subscription_schedules/');
        Assert.isTrue(scheduleBody.contains('end_behavior=release'),
            'A future Fixed-to-Open change must release the subscription when the SAPA schedule ends.');
        Assert.isFalse(scheduleBody.contains('phases%5B1%5D%5Bcancel_at_period_end%5D='),
            'Subscription Schedule phases do not accept cancel_at_period_end. Open behavior is controlled by end_behavior=release.');
        Assert.isFalse(scheduleBody.contains('phases%5B1%5D%5Bend_date%5D='),
            'An Open target phase must continue without a fixed final date.');
    }

    @IsTest
    static void refusesExternallyOwnedScheduleBeforeMutation() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Test.setMock(HttpCalloutMock.class, new StripeMock(Date.today().addDays(10), 'sub_sched_external', false, false));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';

        try {
            StripeRecurringScheduleGateway.applyChange(validRequest(Date.today().addDays(2), 'Weekly', 1));
            Assert.fail('An external schedule must never be overwritten.');
        } catch (StripeRecurringScheduleGateway.StripeRecurringScheduleException expected) {
            Assert.isTrue(expected.getMessage().contains('externally managed'), 'The error must identify ownership as the blocker.');
        }
        Assert.areEqual(2, endpoints.size(), 'Only the subscription and external schedule may be read.');
        Assert.areEqual('GET', methods[1], 'No mutation may follow the ownership check.');
    }

    @IsTest
    static void releasesSapaScheduleBeforeImmediateUpdate() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Test.setMock(HttpCalloutMock.class, new StripeMock(Date.today().addDays(10), 'sub_sched_sapa', true, false));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';

        StripeRecurringScheduleGateway.applyChange(validRequest(Date.today(), 'Monthly', 1));

        Boolean released = false;
        for (String endpoint : endpoints) {
            if (endpoint.endsWith('/subscription_schedules/sub_sched_sapa/release')) released = true;
        }
        Assert.isTrue(released, 'SAPA must release its owned future schedule before a direct update.');
    }

    @IsTest
    static void calculatesFixedFinalPaymentFromFirstRealInvoice() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Date nextBilling = Date.today().addDays(10);
        Test.setMock(HttpCalloutMock.class, new StripeMock(nextBilling, null, false, false));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest change = validRequest(Date.today(), 'Monthly', 1);
        change.recurringType = 'Fixed';
        change.plannedInstallments = 3;

        StripeRecurringScheduleGateway.PreviewResult preview = StripeRecurringScheduleGateway.previewChange(change);

        Assert.areEqual(nextBilling, preview.firstPaymentDate, 'Installment one is the first real invoice.');
        Assert.areEqual(nextBilling.addMonths(2), preview.finalPaymentDate, 'The final date must count the requested installments.');
    }

    @IsTest
    static void supportsEveryRequiredCadenceConversion() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        assertCadenceChange('day', 'Weekly');
        assertCadenceChange('week', 'Monthly');
        assertCadenceChange('month', 'Weekly');
        assertCadenceChange('month', 'Yearly');
    }

    @IsTest
    static void supportsAnnualCompositeAmountAndCadenceChangesBothWays() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        resetCapture();
        Test.setMock(HttpCalloutMock.class,
            new StripeMock(Date.today().addDays(10), null, false, false, 'month', 1, 3000));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.ChangeRequest annual = validRequest(Date.today(), 'Yearly', 1);
        annual.amount = 360;
        StripeRecurringScheduleGateway.PreviewResult annualPreview =
            StripeRecurringScheduleGateway.previewChange(annual);
        Assert.areEqual(30, annualPreview.currentAmount);
        Assert.areEqual(360, annualPreview.requestedAmount);
        Assert.isTrue(annualPreview.willGenerateFullInvoice);

        resetCapture();
        Test.setMock(HttpCalloutMock.class,
            new StripeMock(Date.today().addDays(10), null, false, false, 'year', 1, 36000));
        StripeRecurringScheduleGateway.ChangeRequest monthly = validRequest(Date.today(), 'Monthly', 1);
        monthly.amount = 30;
        StripeRecurringScheduleGateway.PreviewResult monthlyPreview =
            StripeRecurringScheduleGateway.previewChange(monthly);
        Assert.areEqual(360, monthlyPreview.currentAmount);
        Assert.areEqual(30, monthlyPreview.requestedAmount);
        Assert.isTrue(monthlyPreview.willGenerateFullInvoice);
    }

    private static void assertCadenceChange(String currentStripeInterval, String requestedPeriod) {
        resetCapture();
        Date nextBilling = Date.today().addDays(10);
        Test.setMock(HttpCalloutMock.class,
            new StripeMock(nextBilling, null, false, false, currentStripeInterval, 1, 3000));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        StripeRecurringScheduleGateway.PreviewResult preview = StripeRecurringScheduleGateway.previewChange(
            validRequest(Date.today(), requestedPeriod, 1)
        );
        Assert.isTrue(preview.canProceed, currentStripeInterval + ' to ' + requestedPeriod + ' must be supported.');
        Assert.isTrue(preview.willGenerateFullInvoice,
            currentStripeInterval + ' to ' + requestedPeriod + ' must invoice when its future phase starts.');
        Assert.areEqual(nextBilling, preview.firstPaymentDate,
            currentStripeInterval + ' to ' + requestedPeriod + ' must not bill when staff saves.');
    }

    private static StripeRecurringScheduleGateway.ChangeRequest validRequest(Date effectiveDate, String period, Integer intervalCount) {
        StripeRecurringScheduleGateway.ChangeRequest change = new StripeRecurringScheduleGateway.ChangeRequest();
        change.subscriptionId = 'sub_1';
        change.productId = 'prod_1';
        change.currencyIsoCode = 'USD';
        change.amount = 40;
        change.transactionPeriod = period;
        change.transactionInterval = intervalCount;
        change.effectiveDate = effectiveDate;
        change.recurringType = 'Open';
        change.plannedInstallments = null;
        change.salesforceGiftCommitmentId = '6gc000000000001AAA';
        change.salesforceChangeId = 'a01000000000001AAA';
        change.idempotencyKey = 'sapa-rd-a01000000000001AAA';
        return change;
    }

    private static Integer countIdempotencyKey(String expectedKey) {
        Integer matches = 0;
        for (String actualKey : idempotencyKeys) {
            if (actualKey == expectedKey) matches++;
        }
        return matches;
    }

    private static void assertSeparatedSubscriptionRequests(Long expectedCancelAt, Boolean expectedPeriodEndClear) {
        Boolean sawPaymentGatedUpdate = false;
        Boolean sawPeriodEndClear = false;
        Boolean sawCustomCancellation = false;
        for (Integer index = 0; index < endpoints.size(); index++) {
            if (methods[index] != 'POST' || !endpoints[index].endsWith('/subscriptions/sub_1')) continue;
            Map<String, String> form = parseForm(bodies[index]);
            if (form.containsKey('payment_behavior')) {
                sawPaymentGatedUpdate = true;
                Assert.isFalse(form.containsKey('cancel_at'),
                    'The payment-gated update must not contain cancel_at.');
                Assert.isFalse(form.containsKey('cancel_at_period_end'),
                    'The payment-gated update must not contain cancel_at_period_end.');
            } else if (form.containsKey('cancel_at_period_end')) {
                sawPeriodEndClear = true;
                Assert.areEqual('false', form.get('cancel_at_period_end'),
                    'The period-end cancellation must be cleared explicitly.');
                Assert.isFalse(form.containsKey('cancel_at'),
                    'The period-end update must not also contain cancel_at.');
            } else if (form.containsKey('cancel_at')) {
                sawCustomCancellation = true;
                Assert.isFalse(form.containsKey('cancel_at_period_end'),
                    'The custom cancellation update must not also contain cancel_at_period_end.');
                Assert.areEqual(expectedCancelAt == null ? '' : String.valueOf(expectedCancelAt), form.get('cancel_at'),
                    'The custom cancellation value must match the requested Open or Fixed state.');
            }
        }
        Assert.isTrue(sawPaymentGatedUpdate, 'The Price update must be payment-gated.');
        Assert.areEqual(expectedPeriodEndClear, sawPeriodEndClear,
            'The period-end cancellation update must run only when Stripe currently has that flag set.');
        Assert.isTrue(sawCustomCancellation,
            'The custom cancellation must be finalized in its own Stripe request.');
    }

    private static Integer findRequestIndex(String methodName, String endpointSuffix) {
        for (Integer index = 0; index < endpoints.size(); index++) {
            if (methods[index] == methodName && endpoints[index].endsWith(endpointSuffix)) return index;
        }
        return -1;
    }

    private static Integer countRequests(String methodName, String endpointFragment) {
        Integer count = 0;
        for (Integer index = 0; index < endpoints.size(); index++) {
            if (methods[index] == methodName && endpoints[index].contains(endpointFragment)) count++;
        }
        return count;
    }

    private static String lastRequestBody(String methodName, String endpointFragment) {
        for (Integer index = endpoints.size() - 1; index >= 0; index--) {
            if (methods[index] == methodName && endpoints[index].contains(endpointFragment)) return bodies[index];
        }
        return null;
    }

    private static Map<String, String> parseForm(String body) {
        Map<String, String> values = new Map<String, String>();
        if (body == null) return values;
        for (String pair : body.split('&')) {
            Integer separator = pair.indexOf('=');
            String encodedKey = separator < 0 ? pair : pair.substring(0, separator);
            String encodedValue = separator < 0 ? '' : pair.substring(separator + 1);
            values.put(
                EncodingUtil.urlDecode(encodedKey, 'UTF-8'),
                EncodingUtil.urlDecode(encodedValue, 'UTF-8')
            );
        }
        return values;
    }

    private static HttpResponse jsonResponse(Integer statusCode, Map<String, Object> payload) {
        HttpResponse response = new HttpResponse();
        response.setStatusCode(statusCode);
        response.setHeader('Content-Type', 'application/json');
        response.setBody(JSON.serialize(payload));
        return response;
    }

    private static void resetCapture() {
        methods.clear();
        endpoints.clear();
        bodies.clear();
        idempotencyKeys.clear();
    }
}