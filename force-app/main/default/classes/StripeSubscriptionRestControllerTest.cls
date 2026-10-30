@isTest
private class StripeSubscriptionRestControllerTest {

    private class PendingFinalizationStripeMock implements HttpCalloutMock {
        private Long periodStart;
        private Long periodEnd;
        private Long cancelAt;

        PendingFinalizationStripeMock() {
            periodEnd = Datetime.now().addDays(30).getTime() / 1000;
            periodStart = Datetime.now().getTime() / 1000;
            cancelAt = Datetime.now().addMonths(2).getTime() / 1000;
        }

        public HttpResponse respond(HttpRequest request) {
            if (request.getMethod() == 'POST' && request.getBody() != null &&
                request.getBody().contains('cancel_at=')) {
                cancelAt = null;
            }
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setHeader('Content-Type', 'application/json');
            response.setBody(JSON.serialize(new Map<String, Object>{
                'id' => 'sub_pending_applied',
                'status' => 'active',
                'collection_method' => 'charge_automatically',
                'current_period_start' => periodStart,
                'current_period_end' => periodEnd,
                'schedule' => null,
                'cancel_at' => cancelAt,
                'cancel_at_period_end' => false,
                'items' => new Map<String, Object>{
                    'data' => new List<Object>{
                        new Map<String, Object>{
                            'id' => 'si_pending_applied',
                            'quantity' => 1,
                            'price' => new Map<String, Object>{
                                'id' => 'price_pending_applied',
                                'unit_amount' => 5000,
                                'product' => 'prod_pending_applied',
                                'currency' => 'usd',
                                'recurring' => new Map<String, Object>{
                                    'interval' => 'month',
                                    'interval_count' => 1
                                }
                            }
                        }
                    }
                }
            }));
            return response;
        }
    }

    // 1. Setup Test Data (NPC Specific)
    @TestSetup
    static void setupTestData() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        // Fetch the first active Record Type ID for the Account object
        Id accRecordTypeId = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND IsActive = true LIMIT 1].Id;

        // Create Donor Account
        Account donor = new Account(
            Name = 'Test Webhook Donor',
            RecordTypeId = accRecordTypeId
        );
        insert donor;

        // --- Data for Recurring Payment (Invoice) ---
        GiftCommitment gc = new GiftCommitment(
            Name = 'Test Recurring Donation',
            DonorId = donor.Id
        );
        insert gc;

        GiftCommitmentSchedule gcs = new GiftCommitmentSchedule(
            //Name = 'Test Schedule',
            GiftCommitmentId = gc.Id,
            PaymentMethod = 'Credit Card',
            TransactionAmount = 50.00, 
            StartDate = Date.today()   
        );
        insert gcs;

        // GiftTransaction for the Invoice
        GiftTransaction recurringGt = new GiftTransaction(
            Name = 'Test Recurring Trx',      // ✅ Added required field
            PaymentMethod = 'Credit Card',    // ✅ Added required field
            DonorId = donor.Id,
            GiftCommitmentId = gc.Id,
            Status = 'Pledged',
            OriginalAmount = 50.00 ,
            TransactionDueDate = Date.today()
        );
        insert recurringGt;

        // --- Data for Single Payment (Payment Intent) ---
        GiftTransaction singleGt = new GiftTransaction(
            Name = 'Test Single Trx',         // ✅ Added required field
            PaymentMethod = 'Credit Card',    // ✅ Added required field
            DonorId = donor.Id,
            Status = 'Pledged',
            OriginalAmount = 100.00
        );
        insert singleGt;
    }

    // Helper Method to generate a valid Stripe Signature for the test payload
    private static String generateValidSignature(String payload) {
        String secret = System.Label.StripeWebsecret;
        if (String.isBlank(secret)) {
            secret = 'REDACTED_CREDENTIAL'; 
        }
        String timestamp = String.valueOf(DateTime.now().getTime() / 1000);
        String signedPayload = timestamp + '.' + payload;
        Blob mac = Crypto.generateMac('HmacSHA256', Blob.valueOf(signedPayload), Blob.valueOf(secret));
        String signature = EncodingUtil.convertToHex(mac);
        return 't=' + timestamp + ',v1=' + signature;
    }

    // Helper Method to setup the RestContext
    private static void setupRestContext(String payload, String signature) {
        setupRestContext(payload, signature, 'Stripe-Signature');
    }

    private static void setupRestContext(String payload, String signature, String signatureHeaderName) {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/stripe/subscription';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(payload);
        req.headers.put(signatureHeaderName, signature);
        RestContext.request = req;
        RestContext.response = res;
    }

    private static String buildInvoicePayload(String invoiceId, Id recurringDonationId, Integer amountPaidCents) {
        Map<String, Object> invoiceData = new Map<String, Object>{
            'id' => invoiceId,
            'customer' => 'cus_123',
            'amount_paid' => amountPaidCents,
            'customer_email' => 'test@example.com',
            'lines' => new Map<String, Object>{
                'data' => new List<Object>{
                    new Map<String, Object>{
                        'metadata' => new Map<String, Object>{
                            'salesforce_id' => recurringDonationId
                        }
                    }
                }
            }
        };
        Map<String, Object> payloadMap = new Map<String, Object>{
            'type' => 'invoice.payment_succeeded',
            'data' => new Map<String, Object>{ 'object' => invoiceData }
        };
        return JSON.serialize(payloadMap);
    }

    @IsTest
    static void zeroValueSapaBillingGapInvoiceCreatesNoPayment() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gc = [SELECT Id FROM GiftCommitment WHERE Name = 'Test Recurring Donation' LIMIT 1];
        Map<String, Object> invoice = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(
            buildInvoicePayload('in_sapa_gap_zero', gc.Id, 0)
        )).get('data');
        Map<String, Object> invoiceObject = (Map<String, Object>) invoice.get('object');
        invoiceObject.put('parent', new Map<String, Object>{
            'type' => 'subscription_details',
            'subscription_details' => new Map<String, Object>{
                'subscription' => 'sub_gap',
                'metadata' => new Map<String, Object>{
                    'salesforce_id' => String.valueOf(gc.Id),
                    'sapa_billing_gap' => 'true'
                }
            }
        });
        Map<String, Object> payloadMap = new Map<String, Object>{
            'type' => 'invoice.payment_succeeded',
            'data' => new Map<String, Object>{ 'object' => invoiceObject }
        };
        String payload = JSON.serialize(payloadMap);
        setupRestContext(payload, generateValidSignature(payload));

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);
        Assert.areEqual(0, [SELECT COUNT() FROM Payment__c WHERE Transaction_ID__c = 'in_sapa_gap_zero']);
        GiftTransaction transactionRecord = [
            SELECT Status FROM GiftTransaction WHERE GiftCommitmentId = :gc.Id ORDER BY CreatedDate LIMIT 1
        ];
        Assert.areEqual('Pledged', transactionRecord.Status, 'The bridge invoice must not mark a Gift Transaction paid.');
    }

    private static GiftCommitment createRecurringDonation(Boolean createSchedule, Boolean createGiftTransaction) {
        Account donor = [SELECT Id FROM Account WHERE Name = 'Test Webhook Donor' LIMIT 1];
        GiftCommitment gc = new GiftCommitment(
            Name = 'Edge Case Recurring Donation',
            DonorId = donor.Id
        );
        insert gc;

        if (createSchedule) {
            insert new GiftCommitmentSchedule(
                GiftCommitmentId = gc.Id,
                PaymentMethod = 'Credit Card',
                TransactionAmount = 50.00,
                StartDate = Date.today()
            );
        }

        if (createGiftTransaction) {
            insert new GiftTransaction(
                Name = 'Edge Case Recurring Trx',
                PaymentMethod = 'Credit Card',
                DonorId = donor.Id,
                GiftCommitmentId = gc.Id,
                Status = 'Pledged',
                OriginalAmount = 50.00,
                TransactionDueDate = Date.today()
            );
        }

        return gc;
    }

    // 2. Test Scenario: Successful Invoice Payment (Recurring)
    @isTest
    static void testInvoicePaymentSucceeded() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gc = [SELECT Id FROM GiftCommitment LIMIT 1];
        
        // Build mock Stripe Invoice JSON
        Map<String, Object> invoiceData = new Map<String, Object>{
            'id' => 'in_123',
            'customer' => 'cus_123',
            'amount_paid' => 5000, // Equates to $50.00
            'customer_email' => 'test@example.com',
            'lines' => new Map<String, Object>{
                'data' => new List<Object>{
                    new Map<String, Object>{
                        'metadata' => new Map<String, Object>{
                            'salesforce_id' => gc.Id
                        }
                    }
                }
            }
        };
        Map<String, Object> payloadMap = new Map<String, Object>{
            'type' => 'invoice.payment_succeeded',
            'data' => new Map<String, Object>{ 'object' => invoiceData }
        };
        String payload = JSON.serialize(payloadMap);
        
        setupRestContext(payload, generateValidSignature(payload));

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        // Assert HTTP 200 OK
        System.assertEquals(200, RestContext.response.statusCode, 'Expected successful response status');
        
        // Assert Payment__c was created
        List<Payment__c> payments = [SELECT Id, Payment_Status__c, payment_amount__c FROM Payment__c WHERE Transaction_ID__c = 'in_123'];
        System.assertEquals(1, payments.size(), 'One payment record should have been inserted');
        System.assertEquals('Paid', payments[0].Payment_Status__c, 'Payment status should be Paid');
        System.assertEquals(50.00, payments[0].payment_amount__c, 'Payment amount should be converted correctly');
        Assert.areEqual(0, [SELECT COUNT() FROM Stripe_Failure_Log__c], 'A successful payment must not raise a failure log');
    }

    // 3. Test Scenario: Failed Invoice Payment using Fallback Metadata Parsing
    @isTest
    static void testInvoicePaymentFailed_FallbackMetadata() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gc = [SELECT Id FROM GiftCommitment LIMIT 1];
        
        // Build mock Stripe JSON using the 'parent' metadata routing
        Map<String, Object> invoiceData = new Map<String, Object>{
            'id' => 'in_456',
            'customer' => 'cus_456',
            'amount_paid' => 5000,
            'parent' => new Map<String, Object>{
                'type' => 'subscription_details',
                'subscription_details' => new Map<String, Object>{
                    'metadata' => new Map<String, Object>{
                        'salesforce_id' => gc.Id
                    }
                }
            }
        };
        Map<String, Object> payloadMap = new Map<String, Object>{
            'type' => 'invoice.payment_failed',
            'data' => new Map<String, Object>{ 'object' => invoiceData }
        };
        String payload = JSON.serialize(payloadMap);
        
        setupRestContext(payload, generateValidSignature(payload));

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        List<Payment__c> payments = [SELECT Id, Payment_Status__c FROM Payment__c WHERE Transaction_ID__c = 'in_456'];
        System.assertEquals(0, payments.size(), 'Failed invoice events should not create paid payment records');
    }

    @isTest
    static void testDuplicateInvoiceRetry_IsIdempotent() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gc = [SELECT Id FROM GiftCommitment LIMIT 1];
        String payload = buildInvoicePayload('in_duplicate_123', gc.Id, 5000);

        setupRestContext(payload, generateValidSignature(payload));
        StripeSubscriptionRestController.handleWebhook();

        setupRestContext(payload, generateValidSignature(payload));
        StripeSubscriptionRestController.handleWebhook();

        System.assertEquals(200, RestContext.response.statusCode, 'Duplicate retry should still return success');
        List<Payment__c> payments = [SELECT Id FROM Payment__c WHERE Transaction_ID__c = 'in_duplicate_123'];
        System.assertEquals(1, payments.size(), 'Duplicate webhook retries should not insert duplicate payments');
    }

    @isTest
    static void testInvoiceWithNoMatchingGiftTransaction_DoesNotInsertBlankPayment() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gc = createRecurringDonation(true, false);
        String payload = buildInvoicePayload('in_no_matching_gt', gc.Id, 5000);

        setupRestContext(payload, generateValidSignature(payload));

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'Missing matching donation should be safely acknowledged');
        List<Payment__c> payments = [
            SELECT Id, Transaction_ID__c, Payment_Status__c, Donation__c, Recurring_Donation__c
            FROM Payment__c
            WHERE Transaction_ID__c = 'in_no_matching_gt'
        ];
        System.assertEquals(0, payments.size(), 'No blank payment should be inserted when no matching GiftTransaction exists');
        List<Stripe_Failure_Log__c> logs = [
            SELECT Reason_Code__c, Failure_Source__c, Gift_Commitment__c, Stripe_Object_Id__c, Amount__c
            FROM Stripe_Failure_Log__c
        ];
        Assert.areEqual(1, logs.size(), 'A paid invoice that cannot be recorded should raise one failure log');
        Assert.areEqual('PAID_NOT_RECORDED', logs[0].Reason_Code__c, 'Paid-but-not-recorded reason expected');
        Assert.areEqual('Stripe Webhook', logs[0].Failure_Source__c, 'The webhook is the failure source');
        Assert.areEqual(gc.Id, logs[0].Gift_Commitment__c, 'The log should link the affected recurring donation');
        Assert.areEqual('in_no_matching_gt', logs[0].Stripe_Object_Id__c, 'The log should name the Stripe invoice');
        Assert.areEqual(50, logs[0].Amount__c, 'The log should carry the paid amount');
    }

    @isTest
    static void testInvoiceWithMissingSalesforceId_IsAcknowledgedWithoutPayment() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        Map<String, Object> invoiceData = new Map<String, Object>{
            'id' => 'in_missing_salesforce_id',
            'customer' => 'cus_123',
            'amount_paid' => 5000,
            'customer_email' => 'test@example.com'
        };
        Map<String, Object> payloadMap = new Map<String, Object>{
            'type' => 'invoice.payment_succeeded',
            'data' => new Map<String, Object>{ 'object' => invoiceData }
        };
        String payload = JSON.serialize(payloadMap);

        setupRestContext(payload, generateValidSignature(payload));

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'Missing Salesforce id should not make Stripe retry');
        System.assertEquals(0, [SELECT COUNT() FROM Payment__c WHERE Transaction_ID__c = 'in_missing_salesforce_id']);
        Assert.areEqual(0, [SELECT COUNT() FROM Stripe_Failure_Log__c],
            'Invoices without a salesforce_id belong to other integrations such as FundraiseUp and are not failures');
    }

    @isTest
    static void testInvoiceWithMissingSchedule_StillCreatesPayment() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment gc = createRecurringDonation(false, true);
        String payload = buildInvoicePayload('in_no_schedule', gc.Id, 5000);

        setupRestContext(payload, generateValidSignature(payload));

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'Missing schedule should not make Stripe retry');
        List<Payment__c> payments = [
            SELECT Id, Payment_Status__c, Payment_Method__c, Transaction_ID__c
            FROM Payment__c
            WHERE Transaction_ID__c = 'in_no_schedule'
        ];
        System.assertEquals(1, payments.size(), 'Payment should still be recorded without a schedule');
        System.assertEquals('Paid', payments[0].Payment_Status__c, 'Payment status should be Paid');
        System.assertEquals(null, payments[0].Payment_Method__c, 'Payment method should be blank when no schedule exists');
    }

    @isTest
    static void invoicePeriodSelectsTheCorrectUnpaidTransactionWhenAmountsMatch() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [SELECT Id, Subscription_Id__c, DonorId FROM GiftCommitment WHERE Name = 'Test Recurring Donation' LIMIT 1];
        commitment.Subscription_Id__c = 'sub_period_match';
        update commitment;
        Date expectedDueDate = Date.today().addDays(1);
        GiftTransaction expectedTransaction = new GiftTransaction(
            Name = 'Correct Invoice Period Transaction',
            PaymentMethod = 'Credit Card',
            DonorId = commitment.DonorId,
            GiftCommitmentId = commitment.Id,
            Status = 'Pledged',
            OriginalAmount = 50,
            TransactionDueDate = expectedDueDate
        );
        insert expectedTransaction;
        Long periodStart = Datetime.newInstanceGmt(expectedDueDate, Time.newInstance(12, 0, 0, 0)).getTime() / 1000;
        Map<String, Object> invoiceData = new Map<String, Object>{
            'id' => 'in_period_match',
            'subscription' => 'sub_period_match',
            'amount_paid' => 5000,
            'lines' => new Map<String, Object>{
                'data' => new List<Object>{
                    new Map<String, Object>{
                        'metadata' => new Map<String, Object>{ 'salesforce_id' => commitment.Id },
                        'period' => new Map<String, Object>{ 'start' => periodStart }
                    }
                }
            }
        };
        String payload = JSON.serialize(new Map<String, Object>{
            'type' => 'invoice.payment_succeeded',
            'data' => new Map<String, Object>{ 'object' => invoiceData }
        });
        setupRestContext(payload, generateValidSignature(payload));

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        Payment__c payment = [SELECT Donation__c FROM Payment__c WHERE Transaction_ID__c = 'in_period_match' LIMIT 1];
        System.assertEquals(expectedTransaction.Id, payment.Donation__c,
            'Invoice line period must select the due transaction, not another transaction with the same amount.');
    }

    @isTest
    static void subscriptionScheduleLifecycleEventReconcilesSyncStatusOnlyWhenTargetPhaseIsCurrent() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [SELECT Id, Price_Id__c FROM GiftCommitment WHERE Name = 'Test Recurring Donation' LIMIT 1];
        Date effectiveDate = Date.today().addDays(1);
        Long effectiveTimestamp = Datetime.newInstanceGmt(effectiveDate, Time.newInstance(8, 0, 0, 0)).getTime() / 1000;
        Stripe_Subscription_Change__c requestRecord = new Stripe_Subscription_Change__c(
            Gift_Commitment__c = commitment.Id,
            Requested_Effective_Date__c = effectiveDate,
            Requested_Amount__c = 50,
            Requested_Period__c = 'Monthly',
            Requested_Interval__c = 1,
            Requested_Recurring_Type__c = 'Open',
            Stripe_Action_Mode__c = 'Scheduled',
            Status__c = 'Scheduled',
            Attempt_Count__c = 0,
            Idempotency_Key__c = 'webhook-schedule-lifecycle-test',
            Stripe_Subscription_Id__c = 'sub_lifecycle',
            Stripe_Schedule_Id__c = 'sub_sched_lifecycle',
            Stripe_Price_Id__c = 'price_target'
        );
        insert requestRecord;
        String payload = JSON.serialize(new Map<String, Object>{
            'type' => 'subscription_schedule.updated',
            'data' => new Map<String, Object>{
                'object' => new Map<String, Object>{
                    'id' => 'sub_sched_lifecycle',
                    'current_phase' => new Map<String, Object>{
                        'start_date' => effectiveTimestamp,
                        'end_date' => effectiveTimestamp + 2592000
                    },
                    'phases' => new List<Object>{
                        new Map<String, Object>{
                            'start_date' => effectiveTimestamp,
                            'items' => new List<Object>{
                                new Map<String, Object>{ 'price' => 'price_target' }
                            },
                            'metadata' => new Map<String, Object>{ 'salesforce_change_id' => requestRecord.Id }
                        }
                    }
                }
            }
        });
        setupRestContext(payload, generateValidSignature(payload));

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        requestRecord = [SELECT Status__c, Synced_At__c FROM Stripe_Subscription_Change__c WHERE Id = :requestRecord.Id];
        Assert.areEqual('Synced', requestRecord.Status__c, 'The target phase activation must reconcile the request.');
        Assert.isNotNull(requestRecord.Synced_At__c, 'Activation time must be retained.');
        GiftCommitment updated = [SELECT Price_Id__c, Stripe_Schedule_Sync_Status__c FROM GiftCommitment WHERE Id = :commitment.Id];
        Assert.areEqual('Synced', updated.Stripe_Schedule_Sync_Status__c, 'The parent must show the active target phase.');
        Assert.areEqual('price_target', updated.Price_Id__c, 'Price Id changes only when the target phase is active.');
    }

    @isTest
    static void subscriptionScheduleUpdateBeforeTargetPhaseRemainsScheduled() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [SELECT Id, Price_Id__c FROM GiftCommitment WHERE Name = 'Test Recurring Donation' LIMIT 1];
        Stripe_Subscription_Change__c requestRecord = new Stripe_Subscription_Change__c(
            Gift_Commitment__c = commitment.Id,
            Requested_Effective_Date__c = Date.today().addDays(5),
            Requested_Amount__c = 50,
            Requested_Period__c = 'Weekly',
            Requested_Interval__c = 1,
            Requested_Recurring_Type__c = 'Open',
            Stripe_Action_Mode__c = 'Scheduled',
            Status__c = 'Scheduled',
            Attempt_Count__c = 0,
            Idempotency_Key__c = 'webhook-schedule-not-active-test',
            Stripe_Subscription_Id__c = 'sub_lifecycle_pending',
            Stripe_Schedule_Id__c = 'sub_sched_lifecycle_pending',
            Stripe_Price_Id__c = 'price_future'
        );
        insert requestRecord;
        Long currentTimestamp = Datetime.newInstanceGmt(Date.today(), Time.newInstance(8, 0, 0, 0)).getTime() / 1000;
        String payload = JSON.serialize(new Map<String, Object>{
            'type' => 'subscription_schedule.updated',
            'data' => new Map<String, Object>{
                'object' => new Map<String, Object>{
                    'id' => 'sub_sched_lifecycle_pending',
                    'current_phase' => new Map<String, Object>{ 'start_date' => currentTimestamp }
                }
            }
        });
        setupRestContext(payload, generateValidSignature(payload));

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        requestRecord = [SELECT Status__c, Synced_At__c FROM Stripe_Subscription_Change__c WHERE Id = :requestRecord.Id];
        Assert.areEqual('Scheduled', requestRecord.Status__c, 'A schedule edit is not proof that the future phase is active.');
        Assert.isNull(requestRecord.Synced_At__c, 'Future changes must not be marked active early.');
        GiftCommitment updated = [SELECT Price_Id__c FROM GiftCommitment WHERE Id = :commitment.Id];
        Assert.areEqual(commitment.Price_Id__c, updated.Price_Id__c, 'The future Price must not become active early.');
    }

    @IsTest static void subscriptionUpdateActivatesExactScheduledTarget() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        verifySubscriptionActivation(false,false,false,false,true);
    }
    @IsTest static void subscriptionUpdateIgnoresBillingBridge() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        verifySubscriptionActivation(true,false,false,false,false);
    }
    @IsTest static void subscriptionUpdateIgnoresWrongPrice() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        verifySubscriptionActivation(false,true,false,false,false);
    }
    @IsTest static void subscriptionUpdateIgnoresWrongSchedule() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        verifySubscriptionActivation(false,false,true,false,false);
    }
    @IsTest static void subscriptionUpdateIgnoresPendingPayment() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        verifySubscriptionActivation(false,false,false,true,false);
    }

    private static void verifySubscriptionActivation(Boolean bridge,Boolean wrongPrice,
        Boolean wrongSchedule,Boolean pending,Boolean expectedSynced) {
        GiftCommitment gift=[SELECT Id,Price_Id__c FROM GiftCommitment WHERE Name='Test Recurring Donation' LIMIT 1];
        update new GiftCommitment(Id=gift.Id,Subscription_Id__c='sub_activation');
        Long first=Datetime.now().addDays(1).getTime()/1000;
        Stripe_Subscription_Change__c change=new Stripe_Subscription_Change__c(
            Gift_Commitment__c=gift.Id,Requested_Effective_Date__c=Date.today().addDays(1),
            Requested_Amount__c=50,Requested_Period__c='Monthly',Requested_Interval__c=1,
            Requested_Recurring_Type__c='Open',Requested_Change_Mode__c='Terms',
            Stripe_Action_Mode__c='Scheduled',Status__c='Scheduled',Attempt_Count__c=0,
            Idempotency_Key__c='subscription-activation-test',Stripe_Subscription_Id__c='sub_activation',
            Stripe_Schedule_Id__c='sub_sched_activation',Stripe_Price_Id__c='price_active_target',
            Stripe_Effective_Timestamp__c=first);
        insert change;
        Map<String,Object> subscription=new Map<String,Object>{
            'id'=>'sub_activation','status'=>'active',
            'schedule'=>wrongSchedule?'sub_sched_other':'sub_sched_activation',
            'pending_update'=>pending?new Map<String,Object>{'expires_at'=>first+3600}:null,
            'metadata'=>new Map<String,Object>{'salesforce_change_id'=>change.Id,
                'salesforce_id'=>gift.Id,'sapa_owner'=>'salesforce','sapa_billing_gap'=>bridge?'true':'false'},
            'items'=>new Map<String,Object>{'data'=>new List<Object>{new Map<String,Object>{
                'id'=>'si_activation','current_period_start'=>first,'quantity'=>1,
                'price'=>new Map<String,Object>{'id'=>wrongPrice?'price_bridge':'price_active_target'}}}}
        };
        String payload=JSON.serialize(new Map<String,Object>{'type'=>'customer.subscription.updated',
            'data'=>new Map<String,Object>{'object'=>subscription}});
        setupRestContext(payload,generateValidSignature(payload));
        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        if(expectedSynced) StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();
        Assert.areEqual(200,RestContext.response.statusCode,'Verified events must be acknowledged.');
        Assert.areEqual(expectedSynced?'Synced':'Scheduled',
            [SELECT Status__c FROM Stripe_Subscription_Change__c WHERE Id=:change.Id].Status__c,
            'Only the exact active paid target may complete the scheduled request.');
        Assert.areEqual(expectedSynced?'price_active_target':gift.Price_Id__c,
            [SELECT Price_Id__c FROM GiftCommitment WHERE Id=:gift.Id].Price_Id__c,
            'A bridge or mismatched update must not update the parent Price.');
        Assert.areEqual(0,[SELECT COUNT() FROM Payment__c],'Activation/duplicate events must not create financial records.');
    }

    @isTest
    static void temporaryScheduleLifecycleMarksActiveThenRestoresOriginalPrice() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [
            SELECT Id, Price_Id__c FROM GiftCommitment
            WHERE Name = 'Test Recurring Donation' LIMIT 1
        ];
        Stripe_Subscription_Change__c requestRecord = new Stripe_Subscription_Change__c(
            Gift_Commitment__c = commitment.Id,
            Requested_Effective_Date__c = Date.today().addDays(1),
            Requested_Amount__c = 50,
            Requested_Period__c = 'Weekly',
            Requested_Interval__c = 1,
            Requested_Recurring_Type__c = 'Open',
            Requested_Change_Mode__c = 'TemporaryTerms',
            Temporary_Window_End_Date__c = Date.today().addDays(15),
            Original_Amount__c = 10,
            Original_Period__c = 'Monthly',
            Original_Interval__c = 1,
            Original_Stripe_Price_Id__c = 'price_original_window',
            Stripe_Action_Mode__c = 'Scheduled',
            Status__c = 'Scheduled',
            Attempt_Count__c = 0,
            Idempotency_Key__c = 'webhook-temporary-lifecycle-test',
            Stripe_Subscription_Id__c = 'sub_temporary_lifecycle',
            Stripe_Schedule_Id__c = 'sub_sched_temporary_lifecycle',
            Stripe_Price_Id__c = 'price_temporary_target'
        );
        insert requestRecord;
        Long targetStart = Datetime.newInstanceGmt(
            Date.today().addDays(1), Time.newInstance(8, 0, 0, 0)
        ).getTime() / 1000;
        Long restoredStart = Datetime.newInstanceGmt(
            Date.today().addDays(16), Time.newInstance(8, 0, 0, 0)
        ).getTime() / 1000;
        List<Object> phases = new List<Object>{
            new Map<String, Object>{
                'start_date' => targetStart,
                'items' => new List<Object>{ new Map<String, Object>{ 'price' => 'price_temporary_target' } },
                'metadata' => new Map<String, Object>{
                    'salesforce_change_id' => requestRecord.Id,
                    'sapa_phase_role' => 'target'
                }
            },
            new Map<String, Object>{
                'start_date' => restoredStart,
                'items' => new List<Object>{ new Map<String, Object>{ 'price' => 'price_original_window' } },
                'metadata' => new Map<String, Object>{
                    'salesforce_change_id' => requestRecord.Id,
                    'sapa_phase_role' => 'restored'
                }
            }
        };
        String activePayload = JSON.serialize(new Map<String, Object>{
            'type' => 'subscription_schedule.updated',
            'data' => new Map<String, Object>{ 'object' => new Map<String, Object>{
                'id' => 'sub_sched_temporary_lifecycle',
                'current_phase' => new Map<String, Object>{ 'start_date' => targetStart },
                'phases' => phases
            } }
        });
        setupRestContext(activePayload, generateValidSignature(activePayload));

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        requestRecord = [SELECT Status__c FROM Stripe_Subscription_Change__c WHERE Id = :requestRecord.Id];
        Assert.areEqual('Active', requestRecord.Status__c);
        GiftCommitment activeCommitment = [SELECT Price_Id__c FROM GiftCommitment WHERE Id = :commitment.Id];
        Assert.areEqual('price_temporary_target', activeCommitment.Price_Id__c);

        String restoredPayload = JSON.serialize(new Map<String, Object>{
            'type' => 'subscription_schedule.updated',
            'data' => new Map<String, Object>{ 'object' => new Map<String, Object>{
                'id' => 'sub_sched_temporary_lifecycle',
                'current_phase' => new Map<String, Object>{ 'start_date' => restoredStart },
                'phases' => phases
            } }
        });
        setupRestContext(restoredPayload, generateValidSignature(restoredPayload));
        StripeSubscriptionRestController.handleWebhook();

        requestRecord = [SELECT Status__c, Synced_At__c FROM Stripe_Subscription_Change__c WHERE Id = :requestRecord.Id];
        Assert.areEqual('Synced', requestRecord.Status__c);
        Assert.isNotNull(requestRecord.Synced_At__c);
        GiftCommitment restoredCommitment = [SELECT Price_Id__c FROM GiftCommitment WHERE Id = :commitment.Id];
        Assert.areEqual('price_original_window', restoredCommitment.Price_Id__c);
    }

    // 4. Test Scenario: Successful Payment Intent (Single Donation)
    @isTest
    static void testPaymentIntentSucceeded() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftTransaction singleGt = [SELECT Id FROM GiftTransaction WHERE GiftCommitmentId = null LIMIT 1];
        
        // Build mock Stripe PaymentIntent JSON
        Map<String, Object> piData = new Map<String, Object>{
            'id' => 'pi_789',
            'amount' => 10000, // Equates to $100.00
            'currency' => 'usd',
            'status' => 'succeeded',
            'metadata' => new Map<String, Object>{
                'donation_id' => singleGt.Id
            }
        };
        Map<String, Object> payloadMap = new Map<String, Object>{
            'type' => 'payment_intent.succeeded',
            'data' => new Map<String, Object>{ 'object' => piData }
        };
        String payload = JSON.serialize(payloadMap);
        
        setupRestContext(payload, generateValidSignature(payload));

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'Expected successful response status');
        List<Payment__c> payments = [SELECT Id, Payment_Status__c, Payment_Type__c FROM Payment__c WHERE Transaction_ID__c = 'pi_789'];
        System.assertEquals(1, payments.size(), 'One payment record should have been inserted for the single donation');
        System.assertEquals('Single Payment', payments[0].Payment_Type__c, 'Payment Type should be Single Payment');
    }

    @isTest
    static void testPaymentIntentSucceeded_LowercaseSignatureHeader() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftTransaction singleGt = [SELECT Id FROM GiftTransaction WHERE GiftCommitmentId = null LIMIT 1];

        Map<String, Object> piData = new Map<String, Object>{
            'id' => 'pi_lowercase_header',
            'amount' => 10000,
            'currency' => 'usd',
            'status' => 'succeeded',
            'metadata' => new Map<String, Object>{
                'donation_id' => singleGt.Id
            }
        };
        Map<String, Object> payloadMap = new Map<String, Object>{
            'type' => 'payment_intent.succeeded',
            'data' => new Map<String, Object>{ 'object' => piData }
        };
        String payload = JSON.serialize(payloadMap);

        setupRestContext(payload, generateValidSignature(payload), 'stripe-signature');

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'Lowercase signature header should be accepted');
        List<Payment__c> payments = [SELECT Id, Payment_Type__c FROM Payment__c WHERE Transaction_ID__c = 'pi_lowercase_header'];
        System.assertEquals(1, payments.size(), 'Lowercase signature header should allow single payment processing');
        System.assertEquals('Single Payment', payments[0].Payment_Type__c, 'Payment Type should be Single Payment');
    }

    // 5. Test Scenario: Unauthorized (Invalid Signature)
    @isTest
    static void testInvalidSignature() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        String payload = '{"type": "invoice.payment_succeeded"}';
        
        // Pass a completely invalid signature to trigger the 401
        setupRestContext(payload, 't=123,v1=bad_signature_hash');

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        System.assertEquals(401, RestContext.response.statusCode, 'Should return 401 Unauthorized for bad signatures');
        List<Stripe_Failure_Log__c> logs = [SELECT Reason_Code__c, HTTP_Status_Code__c, Stripe_Event_Type__c FROM Stripe_Failure_Log__c];
        Assert.areEqual(1, logs.size(), 'A bad signature should raise one failure log');
        Assert.areEqual('WEBHOOK_SIGNATURE_INVALID', logs[0].Reason_Code__c, 'Signature reason expected');
        Assert.areEqual(401, logs[0].HTTP_Status_Code__c, 'The response code should be recorded');
        Assert.isNull(logs[0].Stripe_Event_Type__c, 'Nothing from an unverified payload may be stored');
    }

    // 6. Test Scenario: Server Error (Malformed JSON)
    @isTest
    static void testExceptionHandling() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        // Send a broken JSON string to trigger the catch block
        String payload = '{ "type": "invoice.payment_succeeded", "data": BROKEN_JSON';
        
        setupRestContext(payload, generateValidSignature(payload));

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        System.assertEquals(500, RestContext.response.statusCode, 'Should return 500 Internal Server Error when an exception occurs');
        List<Stripe_Failure_Log__c> logs = [SELECT Reason_Code__c, HTTP_Status_Code__c, Error_Message__c FROM Stripe_Failure_Log__c];
        Assert.areEqual(1, logs.size(), 'An unhandled webhook error should raise one failure log');
        Assert.areEqual('WEBHOOK_UNHANDLED_EXCEPTION', logs[0].Reason_Code__c, 'Unhandled-exception reason expected');
        Assert.areEqual(500, logs[0].HTTP_Status_Code__c, 'The response code should be recorded');
        Assert.isNotNull(logs[0].Error_Message__c, 'The error message should be captured for investigation');
    }

    @isTest
    static void pendingUpdateAppliedFinalizesExactRequestBeforeMarkingSynced() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [SELECT Id FROM GiftCommitment WHERE Name = 'Test Recurring Donation' LIMIT 1];
        Stripe_Subscription_Change__c targetRequest = new Stripe_Subscription_Change__c(
            Gift_Commitment__c = commitment.Id,
            Requested_Effective_Date__c = Date.today(),
            Requested_First_Payment_Date__c = Date.today(),
            Requested_Amount__c = 50,
            Requested_Period__c = 'Monthly',
            Requested_Interval__c = 1,
            Requested_Recurring_Type__c = 'Open',
            Stripe_Action_Mode__c = 'Immediate',
            Status__c = 'Failed',
            Attempt_Count__c = 1,
            Idempotency_Key__c = 'webhook-pending-applied-test',
            Stripe_Subscription_Id__c = 'sub_pending_applied',
            Stripe_Price_Id__c = 'price_pending_applied',
            Last_Error__c = 'Invoice payment required.'
        );
        insert targetRequest;
        Test.setCreatedDate(targetRequest.Id, System.now().addMinutes(-2));
        Stripe_Subscription_Change__c newerRequest = targetRequest.clone(false, false, false, false);
        newerRequest.Idempotency_Key__c = 'webhook-pending-newer-test';
        newerRequest.Stripe_Price_Id__c = 'price_newer_request';
        insert newerRequest;
        Test.setCreatedDate(newerRequest.Id, System.now());
        String payload = JSON.serialize(new Map<String, Object>{
            'type' => 'customer.subscription.pending_update_applied',
            'data' => new Map<String, Object>{
                'object' => new Map<String, Object>{
                    'id' => 'sub_pending_applied',
                    'metadata' => new Map<String, Object>{
                        'salesforce_change_id' => String.valueOf(targetRequest.Id)
                    }
                }
            }
        });
        setupRestContext(payload, generateValidSignature(payload));
        StripeRecurringScheduleGateway.secretKeyOverride = 'REDACTED_CREDENTIAL';
        Test.setMock(HttpCalloutMock.class, new PendingFinalizationStripeMock());

        Test.startTest();
        StripeSubscriptionRestController.handleWebhook();
        Test.stopTest();

        Stripe_Subscription_Change__c synced = [
            SELECT Status__c, Last_Error__c FROM Stripe_Subscription_Change__c
            WHERE Idempotency_Key__c = 'webhook-pending-applied-test'
        ];
        Assert.areEqual('Synced', synced.Status__c);
        Assert.isNull(synced.Last_Error__c);
        Stripe_Subscription_Change__c untouchedNewer = [
            SELECT Status__c FROM Stripe_Subscription_Change__c WHERE Id = :newerRequest.Id
        ];
        Assert.areEqual('Failed', untouchedNewer.Status__c,
            'The webhook must finalize the request named in Stripe metadata, not the latest failed request.');
        GiftCommitment updated = [SELECT Price_Id__c, Stripe_Schedule_Sync_Status__c FROM GiftCommitment WHERE Id = :commitment.Id];
        Assert.areEqual('price_pending_applied', updated.Price_Id__c);
        Assert.areEqual('Synced', updated.Stripe_Schedule_Sync_Status__c);
    }

    @isTest
    static void pendingUpdateExpiredKeepsImmediateRequestFailed() {
        StripeRecurringSyncConfigTestData.useMockConfiguration();
        GiftCommitment commitment = [SELECT Id FROM GiftCommitment WHERE Name = 'Test Recurring Donation' LIMIT 1];
        insert new Stripe_Subscription_Change__c(
            Gift_Commitment__c = commitment.Id,
            Requested_Effective_Date__c = Date.today(),
            Requested_First_Payment_Date__c = Date.today(),
            Requested_Amount__c = 50,
            Requested_Period__c = 'Monthly',
            Requested_Interval__c = 1,
            Requested_Recurring_Type__c = 'Open',
            Stripe_Action_Mode__c = 'Immediate',
            Status__c = 'Failed',
            Attempt_Count__c = 1,
            Idempotency_Key__c = 'webhook-pending-expired-test',
            Stripe_Subscription_Id__c = 'sub_pending_expired'
        );
        String payload = JSON.serialize(new Map<String, Object>{
            'type' => 'customer.subscription.pending_update_expired',
            'data' => new Map<String, Object>{
                'object' => new Map<String, Object>{ 'id' => 'sub_pending_expired' }
            }
        });
        setupRestContext(payload, generateValidSignature(payload));

        StripeSubscriptionRestController.handleWebhook();

        Stripe_Subscription_Change__c failed = [
            SELECT Status__c, Last_Error__c FROM Stripe_Subscription_Change__c
            WHERE Idempotency_Key__c = 'webhook-pending-expired-test'
        ];
        Assert.areEqual('Failed', failed.Status__c);
        Assert.isTrue(failed.Last_Error__c.contains('expired'));
    }

    // --- First-invoice race / wizard pre-posted installment / charge resolution ---

    private class ChargeLookupStripeMock implements HttpCalloutMock {
        public List<String> endpoints = new List<String>();
        public HttpResponse respond(HttpRequest request) {
            endpoints.add(request.getEndpoint());
            Map<String, Object> body;
            if (request.getEndpoint().contains('/invoice_payments')) {
                body = new Map<String, Object>{ 'data' => new List<Object>{
                    new Map<String, Object>{ 'payment' => new Map<String, Object>{
                        'type' => 'payment_intent', 'payment_intent' => 'pi_lookup'
                    } }
                } };
            } else if (request.getEndpoint().contains('/invoices/')) {
                body = new Map<String, Object>{ 'id' => 'in_lookup' };
            } else {
                body = new Map<String, Object>{ 'id' => 'pi_lookup', 'latest_charge' => 'ch_lookup' };
            }
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(body));
            return response;
        }
    }

    private static Long gmtSeconds(Date day) {
        return Datetime.newInstanceGmt(day, Time.newInstance(12, 0, 0, 0)).getTime() / 1000;
    }

    private static Map<String, Object> firstInvoice(String invoiceId, Id commitmentId, String subscriptionId) {
        return new Map<String, Object>{
            'id' => invoiceId,
            'customer' => 'cus_race',
            'amount_paid' => 5000,
            'subscription' => subscriptionId,
            'lines' => new Map<String, Object>{
                'data' => new List<Object>{
                    new Map<String, Object>{
                        'metadata' => new Map<String, Object>{ 'salesforce_id' => String.valueOf(commitmentId) },
                        'period' => new Map<String, Object>{ 'start' => gmtSeconds(Date.today()) }
                    }
                }
            }
        };
    }

    private static void deliver(Map<String, Object> invoice) {
        String payload = JSON.serialize(new Map<String, Object>{
            'type' => 'invoice.payment_succeeded',
            'data' => new Map<String, Object>{ 'object' => invoice }
        });
        setupRestContext(payload, generateValidSignature(payload));
        StripeSubscriptionRestController.handleWebhook();
        Assert.areEqual(200, RestContext.response.statusCode);
    }

    @IsTest
    static void firstInvoiceBeforeSubscriptionIdCommitIsAcceptedBySalesforceId() {
        GiftCommitment gc = [SELECT Id, Subscription_Id__c FROM GiftCommitment WHERE Name = 'Test Recurring Donation' LIMIT 1];
        Assert.isNull(gc.Subscription_Id__c, 'Precondition: createRecurringSubscription has not committed yet.');
        GiftTransaction pledged = [SELECT Id FROM GiftTransaction WHERE GiftCommitmentId = :gc.Id LIMIT 1];
        Map<String, Object> invoice = firstInvoice('in_race', gc.Id, 'sub_race');
        invoice.put('charge', 'ch_race');

        Test.startTest();
        deliver(invoice);
        Test.stopTest();

        Payment__c payment = [
            SELECT Charge_ID__c, Donation__c, Subscription_Id__c, Recurring_Donation__c
            FROM Payment__c WHERE Transaction_ID__c = 'in_race'
        ];
        Assert.areEqual('ch_race', payment.Charge_ID__c);
        Assert.areEqual(pledged.Id, payment.Donation__c);
        Assert.areEqual(gc.Id, payment.Recurring_Donation__c);
        Assert.areEqual('sub_race', payment.Subscription_Id__c);
        Assert.isNull([SELECT Subscription_Id__c FROM GiftCommitment WHERE Id = :gc.Id].Subscription_Id__c,
            'The webhook must not write Subscription_Id__c; createRecurringSubscription owns it.');
    }

    @IsTest
    static void eveningPacificInvoiceMatchesLosAngelesDueDateNotNextGmtDay() {
        GiftCommitment gc = [SELECT Id, DonorId FROM GiftCommitment WHERE Name = 'Test Recurring Donation' LIMIT 1];
        GiftTransaction dueToday = [SELECT Id FROM GiftTransaction WHERE GiftCommitmentId = :gc.Id LIMIT 1];
        GiftTransaction dueTomorrow = new GiftTransaction(
            Name = 'Next Daily Trx', PaymentMethod = 'Credit Card', DonorId = gc.DonorId,
            GiftCommitmentId = gc.Id, Status = 'Pledged', OriginalAmount = 50,
            TransactionDueDate = Date.today().addDays(1)
        );
        insert dueTomorrow;
        // 02:00 GMT on the next day is 18:00/19:00 Pacific on the installment's due date.
        Map<String, Object> invoice = firstInvoice('in_evening', gc.Id, 'sub_evening');
        invoice.put('charge', 'ch_evening');
        Map<String, Object> line = (Map<String, Object>) ((List<Object>) ((Map<String, Object>) invoice.get('lines')).get('data'))[0];
        line.put('period', new Map<String, Object>{
            'start' => Datetime.newInstanceGmt(Date.today().addDays(1), Time.newInstance(2, 0, 0, 0)).getTime() / 1000
        });

        Test.startTest();
        deliver(invoice);
        Test.stopTest();

        Assert.areEqual(dueToday.Id, [SELECT Donation__c FROM Payment__c WHERE Transaction_ID__c = 'in_evening'].Donation__c,
            'An evening Pacific first invoice must settle the installment due that Los Angeles day.');
    }

    @IsTest
    static void invoiceForDifferentKnownSubscriptionIsSkipped() {
        GiftCommitment gc = [SELECT Id FROM GiftCommitment WHERE Name = 'Test Recurring Donation' LIMIT 1];
        gc.Subscription_Id__c = 'sub_existing';
        update gc;
        Map<String, Object> invoice = firstInvoice('in_other_sub', gc.Id, 'sub_other');
        invoice.put('charge', 'ch_other');

        Test.startTest();
        deliver(invoice);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Payment__c WHERE Transaction_ID__c = 'in_other_sub']);
    }

    @IsTest
    static void wizardPrePostedPaidInstallmentReceivesPaymentAndCharge() {
        GiftCommitment gc = createRecurringDonation(true, false);
        Account donor = [SELECT Id FROM Account WHERE Name = 'Test Webhook Donor' LIMIT 1];
        GiftTransaction alreadySettled = new GiftTransaction(
            Name = 'Settled Paid Trx', PaymentMethod = 'Credit Card', DonorId = donor.Id,
            GiftCommitmentId = gc.Id, Status = 'Paid', OriginalAmount = 50,
            TransactionDueDate = Date.today(), TransactionDate = Date.today(),
            Transaction_Id__c = 'in_previous'
        );
        insert alreadySettled;
        GiftTransaction prePosted = new GiftTransaction(
            Name = 'Wizard Pre-posted Trx', PaymentMethod = 'Credit Card', DonorId = donor.Id,
            GiftCommitmentId = gc.Id, Status = 'Paid', OriginalAmount = 50,
            TransactionDueDate = Date.today(), TransactionDate = Date.today()
        );
        insert prePosted;
        // 2025-03-31.basil shape: no top-level subscription/charge, ids under parent and payments.
        Map<String, Object> invoice = firstInvoice('in_wizard', gc.Id, null);
        invoice.remove('subscription');
        invoice.put('parent', new Map<String, Object>{
            'type' => 'subscription_details',
            'subscription_details' => new Map<String, Object>{ 'subscription' => 'sub_wizard' }
        });
        invoice.put('payments', new Map<String, Object>{ 'data' => new List<Object>{
            new Map<String, Object>{ 'payment' => new Map<String, Object>{
                'type' => 'payment_intent', 'payment_intent' => 'pi_wizard', 'charge' => 'ch_wizard'
            } }
        } });

        Test.startTest();
        deliver(invoice);
        Test.stopTest();

        Payment__c payment = [SELECT Charge_ID__c, Donation__c FROM Payment__c WHERE Transaction_ID__c = 'in_wizard'];
        Assert.areEqual(prePosted.Id, payment.Donation__c, 'The pre-posted installment without Stripe ids must be linked.');
        Assert.areEqual('ch_wizard', payment.Charge_ID__c);
        Assert.areEqual(0, [SELECT COUNT() FROM Payment__c WHERE Donation__c = :alreadySettled.Id],
            'An installment that already has a Transaction_Id__c must never receive a payment.');
    }

    @IsTest
    static void sameFirstInvoiceDeliveredTwiceCreatesOnePayment() {
        GiftCommitment gc = [SELECT Id FROM GiftCommitment WHERE Name = 'Test Recurring Donation' LIMIT 1];
        Map<String, Object> invoice = firstInvoice('in_retry', gc.Id, 'sub_retry');
        invoice.put('charge', 'ch_retry');

        Test.startTest();
        deliver(invoice);
        deliver(invoice);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Payment__c WHERE Transaction_ID__c = 'in_retry']);
        Assert.areEqual(1, [SELECT COUNT() FROM Payment__c WHERE Recurring_Donation__c = :gc.Id],
            'A retried event must not attach a second payment to any installment.');
    }

    @IsTest
    static void invoiceWithoutChargeResolvesChargeThroughStripe() {
        GiftCommitment gc = [SELECT Id FROM GiftCommitment WHERE Name = 'Test Recurring Donation' LIMIT 1];
        Map<String, Object> invoice = firstInvoice('in_lookup', gc.Id, null);
        invoice.remove('subscription');
        ChargeLookupStripeMock mock = new ChargeLookupStripeMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        deliver(invoice);
        Test.stopTest();

        Assert.areEqual('ch_lookup', [SELECT Charge_ID__c FROM Payment__c WHERE Transaction_ID__c = 'in_lookup'].Charge_ID__c);
        Assert.areEqual(3, mock.endpoints.size(), 'Invoice, invoice payments, then PaymentIntent lookups: ' + mock.endpoints);
        Assert.isTrue(mock.endpoints[2].endsWith('/payment_intents/pi_lookup'));
    }

    @IsTest
    static void chargeResolutionUsesPayloadBeforeCallouts() {
        ChargeLookupStripeMock mock = new ChargeLookupStripeMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        Assert.areEqual('ch_expanded', StripeSubscriptionRestController.resolveInvoiceChargeId(new Map<String, Object>{
            'id' => 'in_x', 'payment_intent' => new Map<String, Object>{ 'id' => 'pi_x', 'latest_charge' => 'ch_expanded' }
        }));
        Assert.areEqual('ch_expanded_payment', StripeSubscriptionRestController.resolveInvoiceChargeId(new Map<String, Object>{
            'id' => 'in_y', 'payments' => new Map<String, Object>{ 'data' => new List<Object>{
                new Map<String, Object>{ 'payment' => new Map<String, Object>{
                    'payment_intent' => new Map<String, Object>{ 'id' => 'pi_y', 'latest_charge' => 'ch_expanded_payment' }
                } }
            } }
        }));
        Assert.areEqual(0, mock.endpoints.size(), 'Charges present in the payload must not trigger callouts.');
        Assert.areEqual('ch_lookup', StripeSubscriptionRestController.resolveInvoiceChargeId(new Map<String, Object>{
            'id' => 'in_z', 'payment_intent' => 'pi_lookup'
        }));
        Assert.areEqual(1, mock.endpoints.size(), 'A known PaymentIntent id needs only the PaymentIntent lookup.');
        Test.stopTest();
    }
}