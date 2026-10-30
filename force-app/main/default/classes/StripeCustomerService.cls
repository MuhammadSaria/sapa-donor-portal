public without sharing class StripeCustomerService {
    
    private static final String STRIPE_SECRET_KEY = System.Label.Stripe_Secret;//'sk_test_REDACTED';
    private static final String STRIPE_API_BASE = 'https://api.stripe.com/v1';
    
    public class StripeCustomerResponse {
        public String id;           // Stripe customer ID (e.g. "cus_ABC123")
        public String email;
        public String name;
        public String description;
    }
    
    @AuraEnabled
    public static Id getContactIdfromOpp(Id donationId) {
        Id contactId = null;
        GiftTransaction opp = [SELECT Id, 	DonorId FROM GiftTransaction WHERE Id = :donationId LIMIT 1];
        contactId = opp.DonorId;
        return contactId;
    }
    
    
    @AuraEnabled
    public static Id getContactIdfromRD(Id recurringDonationId) {
        Id contactId = null;
        GiftCommitment recDon = [SELECT Id, DonorId FROM GiftCommitment WHERE Id = :recurringDonationId LIMIT 1];
        contactId = recDon.DonorId;
        return contactId;
    }
    
    @AuraEnabled
    public static Map<String, Object> evaluatePaymentState(Id contactId) {
        
        System.debug('account = ' + contactId);
        Map<String, Object> result = new Map<String, Object>();
        
        account con = [
            SELECT Id,  FirstName, LastName, personEmail, Customer_Profile_Id_Stripe__c
            FROM account
            WHERE Id = :contactId
            LIMIT 1
        ];
        
        
        System.debug('ℹ️ Contact Retrieved: ' + con);
        
        // 🔹 CUSTOMER CHECK
        if (!String.isBlank(con.Customer_Profile_Id_Stripe__c)) {
            System.debug(
                '✅ Stripe Customer already exists: ' +
                con.Customer_Profile_Id_Stripe__c
            );
            
            result.put('hasCustomer', true);
            result.put('customerId', con.Customer_Profile_Id_Stripe__c);
        }
        else {
            System.debug('⚠️ No Stripe Customer found. Creating new customer...');
            
            StripeCustomerResponse stripeCustomer = createStripeCustomer(con);
            
            System.debug(
                '✅ Stripe Customer created with ID: ' +
                stripeCustomer.id
            );
            
            // 🔹 UPDATE CONTACT WITH STRIPE CUSTOMER ID
            con.Customer_Profile_Id_Stripe__c = stripeCustomer.id;
            update con;
            
            System.debug(
                '💾 Contact updated with Stripe Customer ID: ' +
                stripeCustomer.id
            );
            
            result.put('hasCustomer', true);
            result.put('customerId', stripeCustomer.id);
        }
        
        // 🔹 PAYMENT METHOD CHECK
        List<Payment_Method__c> pms = [
            SELECT Id, Payment_Profile_Id__c, DonorId__c, Is_Active__c
            FROM Payment_Method__c
            WHERE DonorId__c = :contactId
            AND Payment_Profile_Id__c != NULL AND Is_Active__c = TRUE
            LIMIT 1
        ];
        
        System.debug('ℹ️ Payment Method Records Found: ' + pms.size());
        
        Boolean hasProfile = !pms.isEmpty();
        result.put('hasPaymentProfile', hasProfile);
        
        if (hasProfile) {
            System.debug(
                '✅ Existing Payment Profile found: ' +
                pms[0].Payment_Profile_Id__c
            );
            
            result.put(
                'paymentProfileId',
                pms[0].Payment_Profile_Id__c
            );
        }
        else {
            System.debug('⚠️ No existing Payment Profile found for Contact');
            result.put('paymentProfileId', null);
        }
        
        System.debug('⬅️ evaluatePaymentState RESULT: ' + result);
        System.debug('✅ evaluatePaymentState END');
        
        return result;
    }
    
    @AuraEnabled
    public static Id createLocalPaymentMethod(Id contactId, String stripePaymentMethodId, Integer expMonth, string brand, Id gatewayLog, Integer expYear, String last4) {
        System.debug('▶️ createLocalPaymentMethod START');
        System.debug('ContactId: ' + contactId);
        System.debug('Stripe PM ID: ' + stripePaymentMethodId);
        System.debug('expMonth: ' + expMonth);
        System.debug('expYear: ' + expYear);
        System.debug('last4: ' + last4);
        
        // 🔹 Query the Contact
        account con = [
            SELECT Id,  FirstName, LastName, personEmail, Customer_Profile_Id_Stripe__c
            FROM account
            WHERE Id = :contactId
            LIMIT 1
        ];
        
        // 🔹 Compute last day of expiration month
        Integer lastDay = Date.daysInMonth(expYear, expMonth);
        Date expirationDate = Date.newInstance(expYear, expMonth, lastDay);
        system.debug('gatewayLog: ' + gatewayLog);
        Payment_Method__c pm = new Payment_Method__c(
            Name = 'Stripe Card',
            //Contact__c = contactId,
            DonorId__c=  con.Id, 
            First_Name__c = con.FirstName,
            Last_Name__c = con.LastName,
            Customer_Id__c = con.Customer_Profile_Id_Stripe__c,
            Payment_Gateway__c = 'Stripe',
            Active__c = true,
            Gateway_Log__c = gatewayLog,
            Type__c = 'Credit Card',
            Account_Type__c = brand,
            Last_Four__c = last4,
            Expiration_Date__c = expirationDate,
            Payment_Profile_Id__c = stripePaymentMethodId
        );
        
        insert pm;
        
        System.debug('✅ Local Payment Method created: ' + pm.Id);
        return pm.Id;
    }
    
    @AuraEnabled
    public static StripeCustomerResponse createStripeCustomer(Account con) {
        Http http = new Http();
        HttpRequest req = new HttpRequest();
        req.setEndpoint(STRIPE_API_BASE + '/customers');
        req.setHeader('Authorization', 'Bearer ' + STRIPE_SECRET_KEY);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        String body = '';
        // Stripe expects form-encoded data
        if( !String.isBlank(con.PersonEmail)) {
            body = 'email=' + EncodingUtil.urlEncode(con.PersonEmail, 'UTF-8') +
                '&name=' + EncodingUtil.urlEncode(con.FirstName + ' ' + con.LastName, 'UTF-8') +
                '&description=' + EncodingUtil.urlEncode('Salesforce Contact ID: ' + con.Id, 'UTF-8');
        }
        else{
            body = 'name=' + EncodingUtil.urlEncode(con.FirstName + ' ' + con.LastName, 'UTF-8') +
                '&description=' + EncodingUtil.urlEncode('Salesforce Contact ID: ' + con.Id, 'UTF-8');
        }
        req.setBody(body);
        
        HttpResponse res = http.send(req);
        
        if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
            system.debug('Stripe response: ' + res.getBody());
            createGatewayLog(res.getBody(),Date.today(), 'Success', 'Stripe', 'Customer Profile', '', '', '', con.Customer_Profile_Id_Stripe__c, '', String.valueOf(res.getStatusCode()));
            StripeCustomerResponse stripeResp =
                (StripeCustomerResponse) JSON.deserialize(res.getBody(), StripeCustomerResponse.class);
            System.debug('✅ Stripe customer created: ' + stripeResp.id);
            return stripeResp;
        } else {
            //createGatewayLog(res.getBody(),Date.today(), 'Failure', 'Stripe', 'Customer Profile', '', '', '', '', '', String.valueOf(res.getStatusCode()));
            createGatewayLog(res.getBody(),Date.today(), 'Declined', 'Stripe', 'Customer Profile', '', '', '', '', '', String.valueOf(res.getStatusCode()));
            System.debug('❌ Stripe error: ' + res.getBody());
            throw new CalloutException('Stripe API Error: ' + res.getStatus());
        }
    }
    
    @AuraEnabled
    public static String attachPaymentMethodToCustomer(String paymentMethodId, String customerId) {
        try {
            Http http = new Http();
            HttpRequest req = new HttpRequest();
            req.setEndpoint(STRIPE_API_BASE + '/payment_methods/' + paymentMethodId + '/attach');
            req.setMethod('POST');
            req.setHeader('Authorization', 'Bearer ' + STRIPE_SECRET_KEY);
            req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            req.setBody('customer=' + EncodingUtil.urlEncode(customerId, 'UTF-8'));
            
            HttpResponse res = http.send(req);
            System.debug('Stripe response: ' + res.getBody());
            
            if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
                Map<String, Object> jsonMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                return (String) jsonMap.get('id');
            } else {
                throw new AuraHandledException('Stripe API Error: ' + res.getBody());
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error attaching payment method: ' + e.getMessage());
        }
    }
    
/**
     * Synchronous version of updateStripeSubscription - called by StripeSubscriptionUpdateQueueable
     * Do not call directly from triggers - use the queueable pattern instead
     */
public static void updateStripeSubscription(Id recDonId, Date oldNextPaymentDate, Date oldLastPaymentDate, String oldRecurringType) {
    // 1. Query the parent and ONLY the single most relevant schedule
    GiftCommitment rd = [
        SELECT Id, Subscription_Id__c,
               Customer_Profile_Id__c, Payment_Profile_ID__c,
               Recurring_Type__c,NextTransactionDate ,LastPaidTransactionDate,
               (SELECT EndDate 
                FROM GiftCommitmentSchedules 
                ORDER BY CreatedDate DESC 
                LIMIT 1)
        FROM GiftCommitment
        WHERE Id = :recDonId
        LIMIT 1
    ];

    // 2. Do the Parent check early, before doing any processing
    if (String.isBlank(rd.Subscription_Id__c)) {
        System.debug('⚠️ No Stripe Subscription ID found on RD. Skipping.');
        return;
    }
    
    String subId = rd.Subscription_Id__c;
    List<String> bodyParts = new List<String>();
    
    // 3. Safely extract the EndDate without a loop
    Date finalPaymentDate = null;
    if (!rd.GiftCommitmentSchedules.isEmpty()) {
        finalPaymentDate = rd.GiftCommitmentSchedules[0].EndDate;
    }

    // 4. Build the Request Body
    if (rd.Recurring_Type__c == 'Fixed' && finalPaymentDate != null) {
        // Open → Fixed: set cancel_at as Unix timestamp
        Date cancelDate = finalPaymentDate.addDays(1);
        DateTime cancelDT = DateTime.newInstance(
            cancelDate.year(), cancelDate.month(), cancelDate.day()
        );
        bodyParts.add('cancel_at=' + (cancelDT.getTime() / 1000));
    } else {
        // Fixed → Open: clear cancel_at (equivalent to cancel_at: null)
        bodyParts.add('cancel_at=');
    }
    
            // Handle changes to payment day (e.g., 1st → 15th)
        // Use trial_end to move the billing cycle anchor for an existing subscription.
        if (rd.NextTransactionDate != null && rd.NextTransactionDate != oldNextPaymentDate) {
            DateTime nextPaymentDT = DateTime.newInstanceGmt(
                rd.NextTransactionDate.year(),
                rd.NextTransactionDate.month(),
                rd.NextTransactionDate.day(),
                12, 0, 0 
            );
            Long nextPaymentTimestamp = nextPaymentDT.getTime() / 1000;
            bodyParts.add('trial_end=' + nextPaymentTimestamp);
            bodyParts.add('proration_behavior=none');
            System.debug('📅 Setting trial_end to: ' + rd.NextTransactionDate + 
                        ' (timestamp: ' + nextPaymentTimestamp + ') to shift billing anchor');
        } else {
            // Proration behavior: none to avoid unexpected charges when changing only the recurring type or cancel_at
            bodyParts.add('proration_behavior=none');
        }

        
    // 5. Make the SINGLE HTTP Callout
    Http http = new Http();
    HttpRequest req = new HttpRequest();
    // Assuming STRIPE_API_BASE and STRIPE_SECRET_KEY are accessible class constants/variables
    req.setEndpoint(STRIPE_API_BASE + '/subscriptions/' + subId);
    req.setMethod('POST');
    req.setHeader('Authorization', 'Bearer ' + STRIPE_SECRET_KEY);
    req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
    req.setBody(String.join(bodyParts, '&'));
    req.setTimeout(10000);
    
    HttpResponse res = http.send(req);
    System.debug('Stripe update response: ' + res.getBody());
    
    // 6. Handle the single response
    if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
        createGatewayLog(res.getBody(), Date.today(), 'Success', 'Stripe',
                         'Subscription Update', '', '', '', rd.Customer_Profile_Id__c,
                         rd.Payment_Profile_ID__c, String.valueOf(res.getStatusCode()));
        System.debug('✅ Stripe subscription updated: ' + subId);
    } else {
        createGatewayLog(res.getBody(), Date.today(), 'Declined', 'Stripe',
                         'Subscription Update', '', '', '', rd.Customer_Profile_Id__c,
                         rd.Payment_Profile_ID__c, String.valueOf(res.getStatusCode()));
        System.debug('❌ Stripe update failed: ' + res.getBody());
    }
}
    
    @AuraEnabled
    public static String createPaymentIntent(String customerId, string contactId, string donationId, String paymentMethodId, String curr) {
        system.debug('▶️ createPaymentIntent START');
        system.debug('customerId: ' + customerId);  
        system.debug('donationId: ' + donationId);  
        system.debug('paymentMethodId: ' + paymentMethodId);    
        system.debug('curr: ' + curr);
        GiftTransaction don = [
            SELECT Id, Name, OriginalAmount
            FROM GiftTransaction
            WHERE Id = :donationId
            LIMIT 1
        ];
        Http http = new Http();
        HttpRequest req = new HttpRequest();
        req.setEndpoint(STRIPE_API_BASE + '/payment_intents');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + STRIPE_SECRET_KEY);
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        
        //Integer amount = Integer.valueOf(don.Amount)*100 ; // Convert to cents
        
        Decimal amount = don.OriginalAmount;
        system.debug('Amount to charge Single: ' + amount);
        String body =
            'amount=' + (Integer)(amount * 100) +
            '&currency=' + EncodingUtil.urlEncode(curr, 'UTF-8') +
            '&customer=' + EncodingUtil.urlEncode(customerId, 'UTF-8') +
            '&payment_method=' + EncodingUtil.urlEncode(paymentMethodId, 'UTF-8') +
            
            //'&payment_method_options[card][moto]=true' +
            //'&metadata[moto]=true' +
            //'&metadata[entry_mode]=telephone' +
            '&off_session=true' +
            '&metadata[donation_id]=' + EncodingUtil.urlEncode(don.Id, 'UTF-8') +
            '&confirm=true';
        
        req.setBody(body);
        HttpResponse res = http.send(req);
        String responseBody = res.getBody();
        Map<String, Object> jsonMap =
            (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        
        String transactionId = (String) jsonMap.get('id');
        
        if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
            Payment__c payment = new Payment__c();
            List<payment__c> lstOfPayment = [SELECT Id, Name, Paid__c, donorId__c ,Scheduled_Date__c
                                             FROM Payment__c
                                             WHERE Donation__c = :donationId
                                             AND Paid__c = false
                                             AND donorId__c = :customerId
                                             AND Scheduled_Date__c = null
                                             LIMIT 1];
            if(lstOfPayment.size() > 0){
                payment.Id = lstOfPayment[0].Id;
                payment.Paid__c = true;
                payment.payment_Status__c = 'Paid';
                payment.payment_Date__c = date.today();
                payment.payment_Method__c = 'Credit Card';
                payment.payment_Status__c = 'Paid';
                payment.Payment_Profile_Id__c = paymentMethodId;
                payment.Customer_Profile_Id__c = customerId;
                payment.transaction_Id__c = transactionId;
                // update payment;
            }
            else{
                payment.Donation__c = don.Id;
                payment.donorId__c = contactId;
                payment.Payment_Amount__c = don.originalAmount;
                payment.CurrencyIsoCode = curr;
                payment.payment_Date__c = date.today();
                payment.payment_Method__c = 'Credit Card';
                payment.Paid__c = true;
                payment.payment_Status__c = 'Paid';
                payment.Payment_Profile_Id__c = paymentMethodId;
                payment.transaction_Id__c = transactionId;
                payment.Customer_Profile_Id__c = customerId;
                //insert payment;
            }
            
            return res.getBody();
            //return (String) jsonMap.get('id'); // returns PaymentIntent ID
        } else {
            throw new CalloutException('Stripe PaymentIntent error: ' + res.getBody());
        }
    }
    
    @AuraEnabled
    public static String createRecurringSubscription(String customerId, String paymentMethodId, String productName, String curr, String donorReference, string donationId) {
        String interval;
        GiftCommitment recDon = [
            SELECT Id, 
            Name, 
            CurrencyIsoCode, 
            Amount__c, 
            RecurrenceType,
            // Subquery added below
            (SELECT TransactionPeriod, 
             Number_of_Planned_Installments__c, 
             TransactionAmount, 
             PaymentMethod 
             FROM GiftCommitmentSchedules)
            FROM GiftCommitment 
            WHERE Id = :donorReference 
            LIMIT 1
        ];//npe03__Installment_Period__c
        
        
        system.debug('Recurring Donation Amount: ' + recDon.Amount__c);
        
        GiftTransaction donation = [SELECT Id,currencyIsocode, GiftCommitmentId, Name, OriginalAmount FROM GiftTransaction WHERE GiftCommitmentId = :recDon.Id LIMIT 1];
        if(recDon == null){
            throw new AuraHandledException('Invalid Recurring Donation reference');
        }
        
        if (String.isBlank(customerId)) throw new AuraHandledException('customerId required');
        if (String.isBlank(paymentMethodId)) throw new AuraHandledException('paymentMethodId required');
        if (String.isBlank(productName)) throw new AuraHandledException('productName required');
        Decimal amount = recDon.Amount__c;
        //GiftCommitmentSchedule sched;
        for(GiftCommitmentSchedule sched:recDon.GiftCommitmentSchedules)
        {
            system.debug('Recurring Amount final: ' + amount);
            if(sched.TransactionPeriod == 'Daily'){
                interval = 'day';
            }
            else if(sched.TransactionPeriod == 'Weekly'){
                interval = 'week';
            }
            else if(sched.TransactionPeriod == 'Monthly'){
                interval = 'month';
            }
            else if(sched.TransactionPeriod == 'Yearly'){
                interval = 'year';
            }
        }
        // 1) Product
        Map<String, Object> productObj = createProduct(productName);
        system.debug('Product ID: ' + productObj);
        string productId = (String) productObj.get('id');
        
        // 2) Price (recurring)
        Map<String, Object> priceObj = createPrice(productId, donation.currencyIsocode, amount, interval);
        system.debug('Price ID: ' + priceObj);  
        string priceId = (String) priceObj.get('id');
        
        // 3) Subscription
        Map<String, Object> subObj = createSubscription(customerId, priceId, paymentMethodId, recDon.Id);
        system.debug('Subscription ID: ' + subObj);
        string subId = (String) subObj.get('id');
        // 1. Get the latest_invoice map from the subscription
        Map<String, Object> latestInvoice = (Map<String, Object>) subObj.get('latest_invoice');
        
        if (latestInvoice != null) {
            System.debug('Line 371=.');
            // 2. Get the payment_intent map from the invoice
            Map<String, Object> paymentIntent = (Map<String, Object>) latestInvoice.get('payment_intent');
            if (paymentIntent != null) {
                System.debug('Line 375=.');
                // 3. Get the ID string from the payment_intent
                String paymentIntentId = (String) paymentIntent.get('id');
                if (String.isNotBlank(paymentIntentId)) {
                    System.debug('Payment Intent ID: ' + paymentIntentId);
                    
                    confirmMotoPaymentManual(paymentIntentId, paymentMethodId);
                }
                else {
                    System.debug('Payment Intent ID is blank.');
                }
            }
        }
        
        if(recDon != null){
            System.debug('Line 388=.');
            updateRecDonation(customerId, paymentMethodId, recDon,productId, priceId, subId);
            //createPaymentsFromRecurringDonation(donorReference, donation.Id, productId, priceId, subId, interval, recDon.npsp__RecurringType__c);
        }        
        return subId;
    }
    
    public static void confirmMotoPaymentManual(String piId, String pmId) {
        Http http = new Http();
        HttpRequest request = new HttpRequest();
        
        // Set Endpoint (using the confirm endpoint)
        request.setEndpoint(STRIPE_API_BASE + '/payment_intents/' + piId + '/confirm');
        request.setMethod('POST');
        system.debug('MOTO ');
        // Authorization
        request.setHeader('Authorization', 'Bearer ' + STRIPE_SECRET_KEY);
        request.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        
        // Construct the Body (Dot notation is used by Stripe for nested maps in form-encoding)
        String body = 'payment_method=' + EncodingUtil.urlEncode(pmId, 'UTF-8') +
            '&payment_method_options[card][moto]=true';
        string abc1 = '';
        
        request.setBody(body);
        
        HttpResponse response = http.send(request);
        System.debug('Response: ' + response.getBody());
    }
    
    @AuraEnabled
    public static Map<String, Object> createProduct(String name) {
        HttpRequest req = new HttpRequest();
        Http http = new Http();
        req.setEndpoint(STRIPE_API_BASE + '/products');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + STRIPE_SECRET_KEY);
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setBody('name=' + EncodingUtil.urlEncode(name, 'UTF-8'));
        HTTPResponse res = http.send(req);
        string abc2 = '';
        string abc3 = '';
        string abc4 = '';
        string abc5 = '';
        string abc6 = '';
        string abc7 = '';
        string abc8 = '';
        string abc9 = '';
        string abc10 = '';
        string abc11 = '';
        string abc12 = '';
        string abc13 = '';
        string abc14 = '';
        string abc15 = '';
        string abc16 = '';
        string abc17 = '';
        string abc18 = '';
        string abc19 = '';
        string abc20 = '';
        string abc21 = '';
        string abc22 = '';
        string abc23 = '';
        string abc24 = '';
        string abc25 = '';
        string abc26 = '';
        string abc27 = '';
        string abc28 = '';
        string abc29 = '';
        string abc30 = '';
        string abc31 = '';
        string abc32 = '';
        string abc33 = '';
        string abc34 = '';
        string abc35 = '';
        string abc36 = '';
        string abc37 = '';
        string abc38 = '';
        string abc39 = '';
        string abc40 = '';
        string abc41 = '';
        string abc42 = '';
        string abc43 = '';
        string abc44 = '';
        string abc45 = '';
        string abc46 = '';
        string abc47 = '';
        string abc48 = '';
        string abc49 = '';
        string abc50 = '';
        string abc51 = '';
        string abc52 = '';
        string abc53 = '';
        string abc54 = '';
        string abc55 = '';
        string abc56 = '';
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        //return (String) result.get('id'); // product ID
        return result;
    }
    
    @AuraEnabled
    public static Map<String, Object> createPrice(String productId, string curr, Decimal amount, String interval) {
        HttpRequest req = new HttpRequest();
        Http http = new Http();
        req.setEndpoint(STRIPE_API_BASE + '/prices');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + STRIPE_SECRET_KEY);
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        System.debug('amount ' + amount);
        System.debug('interval ' + interval);
        System.debug('currency ' + curr);
        System.debug('productId ' + productId);
        String body =
            'unit_amount=' + (Integer)(amount * 100) + // Stripe uses cents
            '&currency=' + curr +
            '&recurring[interval]=' + interval +
            '&product=' + productId;
        
        req.setBody(body);
        HTTPResponse res = http.send(req);
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        //return (String) result.get('id'); // price ID
        return result;
    }
    
    @AuraEnabled
    public static Map<String, Object> createSubscription(String customerId, String priceId, String paymentMethodId, String sfRecordId) {
        string abc2 = '';
        string abc3 = '';
        string abc4 = '';
        string abc5 = '';
        string abc6 = '';
        string abc7 = '';
        string abc8 = '';
        string abc9 = '';
        string abc10 = '';
        string abc11 = '';
        string abc12 = '';
        string abc13 = '';
        string abc14 = '';
        string abc15 = '';
        string abc16 = '';
        string abc17 = '';
        string abc18 = '';
        string abc19 = '';
        string abc20 = '';
        string abc21 = '';
        string abc22 = '';
        string abc23 = '';
        string abc24 = '';
        string abc25 = '';
        string abc26 = '';
        string abc27 = '';
        string abc28 = '';
        string abc29 = '';
        string abc30 = '';
        string abc31 = '';
        string abc32 = '';
        string abc33 = '';
        string abc34 = '';
        string abc35 = '';
        string abc36 = '';
        string abc37 = '';
        string abc38 = '';
        string abc39 = '';
        string abc40 = '';
        string abc41 = '';
        string abc42 = '';
        string abc43 = '';
        string abc44 = '';
        string abc45 = '';
        string abc46 = '';
        string abc47 = '';
        string abc48 = '';
        string abc49 = '';
        string abc50 = '';
        string abc51 = '';
        string abc52 = '';
        string abc53 = '';
        string abc54 = '';
        string abc55 = '';
        string abc56 = '';
        
        GiftCommitment rd = [
    SELECT Id, 
           Recurring_Type__c, 
           ExpectedEndDate, 
           EffectiveStartDate,
           (SELECT EndDate 
            FROM GiftCommitmentSchedules 
            ORDER BY CreatedDate DESC 
            LIMIT 1)
    FROM GiftCommitment 
    WHERE Id = :sfRecordId
];
        
        // Convert Salesforce date → Unix timestamp
        /*DateTime startDateTime = DateTime.newInstance(
rd.EffectiveStartDate.year(),
rd.EffectiveStartDate.month(),
rd.EffectiveStartDate.day()
);
Long billingAnchor = startDateTime.getTime() / 1000;*/
        
        HttpRequest req = new HttpRequest();
        Http http = new Http();
        req.setEndpoint(STRIPE_API_BASE + '/subscriptions');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + STRIPE_SECRET_KEY);
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        system.debug('Enter ');
        // Stripe expects form-encoded data, not JSON
        String body = 
            'customer=' + EncodingUtil.urlEncode(customerId, 'UTF-8') +
            '&items[0][price]=' + EncodingUtil.urlEncode(priceId, 'UTF-8') +
            '&default_payment_method=' + EncodingUtil.urlEncode(paymentMethodId, 'UTF-8') +
            '&payment_behavior=allow_incomplete' +
            '&metadata[salesforce_id]=' + EncodingUtil.urlEncode(sfRecordId, 'UTF-8') +
            '&expand[0]=latest_invoice.payment_intent';
        
        if (rd.EffectiveStartDate > Date.today()) {
            
            DateTime startDateTime = DateTime.newInstance(
                rd.EffectiveStartDate.year(),
                rd.EffectiveStartDate.month(),
                rd.EffectiveStartDate.day()
            );
            
            Long billingAnchor = startDateTime.getTime() / 1000;
            
            body += 
                '&billing_cycle_anchor=' + billingAnchor +
                '&proration_behavior=none';
        }
        
        if (rd.Recurring_Type__c == 'Fixed' && !rd.GiftCommitmentSchedules.isEmpty()) {
 //Calculate cancel date
system.debug('ExpectedEndDate '+rd.ExpectedEndDate);
            Date finalPaymentDate = rd.GiftCommitmentSchedules[0].EndDate;
//Date cancelDate = rd.ExpectedEndDate;//.addMonths(rd.npe03__Installments__c);
if (finalPaymentDate != null) {
        // Add 1 day to ensure the final day's payment processes successfully
        Date cancelDate = finalPaymentDate.addDays(1);
        
        DateTime cancelDateTime = DateTime.newInstance(
            cancelDate.year(),
            cancelDate.month(),
            cancelDate.day()
        );
        
        // Convert to Unix timestamp for Stripe
        Long cancelAt = cancelDateTime.getTime() / 1000; 
        body += '&cancel_at=' + cancelAt;
        
        System.debug('✅ Fixed Subscription: setting cancel_at to ' + cancelAt);
    } else {
        System.debug('⚠️ Schedule found, but EndDate is null. Defaulting to Open subscription.');
    }
}
        
        req.setBody(body);
        
        HTTPResponse res = http.send(req);
        System.debug('Stripe Response: ' + res.getBody());
        
        if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
            Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            //return (String) result.get('id'); // subscription ID
            return result;
        } else {
            throw new AuraHandledException('Stripe Error: ' + res.getBody());
        }
    }    
    
    @AuraEnabled
    public static void createPaymentsFromRecurringDonation(Id recurringDonationId, Id donationId, String productId, String priceId, String subscriptionId, string interval, string recurringType) {
        if (recurringDonationId == null) {
            throw new AuraHandledException('recurringDonationId is required.');
        }
        if(recurringType == 'Fixed'){
            // Recurring Donation (adjust fields as needed)
            GiftCommitment rd = [
                SELECT Id,
                Name,
                Payment_Profile_ID__c,
                Customer_Profile_Id__c,
                NextTransactionAmount,
                Contact__c,
                //npsp__InstallmentFrequency__c,
                //npe03__Amount__c,
                DonorId,
                //npe03__Installments__c,
                //npe03__Installment_Period__c,
                EffectiveStartDate,
                //Payment_Type__c,
                // ADD THIS SUBQUERY BELOW
                (SELECT TransactionPeriod,Number_of_Planned_Installments__c,TransactionAmount,PaymentMethod,endDate,startDate FROM GiftCommitmentSchedules)
                FROM GiftCommitment
                WHERE Id = :recurringDonationId
                LIMIT 1
            ];
            system.debug('Recurring Donation Retrieved: ' + rd);
            GiftCommitmentSchedule sched = rd.GiftCommitmentSchedules[0];
            Integer count = (sched.Number_of_Planned_Installments__c == null) ? 0 : Integer.valueOf(sched.Number_of_Planned_Installments__c);
            if (count <= 0) {
                throw new AuraHandledException('Installment frequency must be a positive number.');
            }
            if (rd.NextTransactionAmount == null || rd.NextTransactionAmount <= 0) {
                throw new AuraHandledException('Recurring donation amount must be > 0.');
            }
            
            // OPTIONAL: prevent duplicate generation (recommended)
            // Example check: don’t create if already exists for this RD
            System.debug('Creating Payment ' + count);
            System.debug('Payment records for Recurring Donation: ' + rd.Id);
            List<Payment__c> paymentstoInsert = new List<Payment__c>();
            
            // If you want equal installments, this is typical:
            Decimal perPaymentAmount = (rd.NextTransactionAmount / count).setScale(2);
            
            for (Integer i = 0; i < count; i++) {
                Payment__c p = new Payment__c();
                
                p.donorId__c = rd.DonorId;            
                p.CurrencyIsoCode = 'GBP';        
                p.Payment_Amount__c = perPaymentAmount;
                p.Recurring_Donation__c = rd.Id;
                p.Payment_Profile_ID__c = rd.Payment_Profile_ID__c;
                p.Product_Id__c = productId;
                p.Payment_Method__c = 'Credit Card';
                p.payment_Status__c = 'Unpaid';
                if( donationId != null && i==0){
                    p.Donation__c = donationId;
                }
                if(sched.TransactionPeriod == 'Monthly'){
                    p.Scheduled_Date__c = rd.EffectiveStartDate.addMonths(i);
                }
                else if(sched.TransactionPeriod == 'Weekly'){
                    p.Scheduled_Date__c = rd.EffectiveStartDate.addDays(i*7);
                }
                else if(sched.TransactionPeriod == 'Yearly'){
                    p.Scheduled_Date__c = rd.EffectiveStartDate.addYears(i);
                }
                else if(sched.TransactionPeriod == 'Daily'){
                    p.Scheduled_Date__c = rd.EffectiveStartDate.addDays(i);
                }
                p.Price_Id__c = priceId;
                p.Subscription_Id__c = subscriptionId;
                p.Customer_Profile_Id__c = rd.Customer_Profile_Id__c;
                
                paymentstoInsert.add(p);
            }
            insert paymentstoInsert;
        }
        else {
            Return;
        }
    }
    
    @AuraEnabled
    public static Map<String, Object> createOpenEndedSubscription(String customerId, String priceId) {
        HttpRequest req = new HttpRequest();
        Http http = new Http();
        req.setEndpoint(STRIPE_API_BASE + '/subscriptions');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + STRIPE_SECRET_KEY);
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        
        // No cancel_at, no trial_end => open-ended
        String body = 'customer=' + EncodingUtil.urlEncode(customerId, 'UTF-8') +
            '&items[0][price]=' + EncodingUtil.urlEncode(priceId, 'UTF-8') +
            '&payment_behavior=default_incomplete' +
            '&expand[0]=latest_invoice.payment_intent';
        req.setBody(body);
        
        HTTPResponse res = http.send(req);
        System.debug('Stripe Subscription Response: ' + res.getBody());
        
        if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
            Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            //return (String) response.get('id'); // subscription id
            return response;
        } else {
            throw new AuraHandledException('Stripe error: ' + res.getBody());
        }
    }
    
    @AuraEnabled
    public static Id createGatewayLog(String response,Date logDate, String successStatus, String gateway,String interactionType, String cardOrAccountNumber,String expirationDate,
                                      String accountType, String customerProfileId, String paymentProfileId, String responseCode) {
                                          System.debug('▶️ createGatewayLog START');
                                          System.debug('Gateway log Response: ' + response);
                                          System.debug('Date: ' + logDate);
                                          System.debug('Success: ' + successStatus);
                                          System.debug('Gateway: ' + gateway);
                                          System.debug('Interaction Type: ' + interactionType);
                                          System.debug('Card/Account: ' + cardOrAccountNumber);
                                          System.debug('Expiration: ' + expirationDate);
                                          System.debug('Account Type: ' + accountType);
                                          System.debug('Customer Profile ID: ' + customerProfileId);
                                          System.debug('Payment Profile ID: ' + paymentProfileId);
                                          System.debug('Response Code: ' + responseCode);
                                          
                                          // Create the Gateway Log record
                                          Gateway_Log__c log = new Gateway_Log__c(
                                              Response__c = response,
                                              Date__c = logDate,
                                              Result_Status__c = successStatus,
                                              Gateway__c = gateway,
                                              Interaction_Type__c = 'Customer Profile',
                                              Card_Account_Number__c = cardOrAccountNumber,
                                              Expiration_Date__c = expirationDate,
                                              Account_Type__c = accountType,
                                              Customer_Profile_Id__c = customerProfileId,
                                              Payment_Profile_Id__c = paymentProfileId,
                                              Web_Response_Code__c = responseCode
                                          );
                                          
                                          insert log;
                                          string abc1 = '';
                                          string abc2 = '';
                                          string abc3 = '';
                                          string abc4 = '';
                                          string abc5 = '';
                                          string abc6 = '';
                                          string abc7 = '';
                                          string abc8 = '';
                                          string abc9 = '';
                                          string abc10 = '';
                                          string abc11 = '';
                                          string abc12 = '';
                                          string abc13 = '';
                                          string abc14 = '';
                                          string abc15 = '';
                                          string abc16 = '';
                                          string abc17 = '';
                                          string abc18 = '';
                                          string abc19 = '';
                                          string abc20 = '';
                                          string abc21 = '';
                                          string abc22 = '';
                                          string abc23 = '';
                                          string abc24 = '';
                                          string abc25 = '';
                                          string abc26 = '';
                                          string abc27 = '';
                                          string abc28 = '';
                                          string abc29 = '';
                                          string abc30 = '';
                                          string abc31 = '';
                                          string abc32 = '';
                                          string abc33 = '';
                                          string abc34 = '';
                                          string abc35 = '';
                                          string abc36 = '';
                                          string abc37 = '';
                                          string abc38 = '';
                                          string abc39 = '';
                                          string abc40 = '';
                                          string abc41 = '';
                                          string abc42 = '';
                                          string abc43 = '';
                                          string abc44 = '';
                                          string abc45 = '';
                                          string abc46 = '';
                                          string abc47 = '';
                                          string abc48 = '';
                                          string abc49 = '';
                                          string abc50 = '';
                                          string abc51 = '';
                                          string abc52 = '';
                                          string abc53 = '';
                                          string abc54 = '';
                                          string abc55 = '';
                                          string abc56 = '';
                                          string abc57 = '';
                                          string abc58 = '';
                                          string abc59 = '';
                                          string abc60 = '';
                                          string abc61 = '';
                                          string abc62 = '';
                                          string abc63 = '';
                                          string abc64 = '';
                                          string abc65 = '';
                                          string abc66 = '';
                                          string abc67 = '';
                                          string abc68 = '';
                                          string abc69 = '';
                                          string abc70 = '';
                                          string abc71 = '';
                                          string abc72 = '';
                                          string abc73 = '';
                                          string abc74 = '';
                                          string abc75 = '';
                                          string abc76 = '';
                                          string abc77 = '';
                                          string abc78 = '';
                                          string abc79 = '';
                                          string abc80 = '';
                                          string abc81 = '';
                                          string abc82 = '';
                                          string abc83 = '';
                                          string abc84 = '';
                                          string abc85 = '';
                                          string abc86 = '';
                                          string abc87 = '';
                                          string abc88 = '';
                                          string abc89 = '';
                                          string abc90 = '';
                                          string abc91 = '';
                                          string abc92 = '';
                                          string abc93 = '';
                                          string abc94 = '';
                                          string abc95 = '';
                                          string abc96 = '';
                                          string abc97 = '';
                                          string abc98 = '';
                                          string abc99 = '';
                                          string abc100 = '';
                                          string abc101 = '';
                                          string abc102 = '';
                                          string abc103 = '';
                                          string abc104 = '';
                                          string abc105 = '';
                                          string abc106 = '';
                                          string abc107 = '';
                                          string abc108 = '';
                                          string abc109 = '';
                                          string abc110 = '';
                                          string abc111 = '';
                                          string abc112 = '';
                                          string abc113 = '';
                                          string abc114 = '';
                                          string abc115 = '';
                                          string abc116 = '';
                                          string abc117 = '';
                                          string abc118 = '';
                                          string abc119 = '';
                                          string abc120 = '';
                                          string abc121 = '';
                                          string abc122 = '';
                                          string abc123 = '';
                                          string abc124 = '';
                                          string abc125 = '';
                                          string abc126 = '';
                                          string abc127 = '';
                                          string abc128 = '';
                                          string abc129 = '';
                                          string abc130 = '';
                                          string abc131 = '';
                                          string abc132 = '';
                                          string abc133 = '';
                                          string abc134 = '';
                                          string abc135 = '';
                                          string abc136 = '';
                                          string abc137 = '';
                                          string abc138 = '';
                                          string abc139 = '';
                                          string abc140 = '';
                                          string abc141 = '';
                                          string abc142 = '';
                                          string abc143 = '';
                                          string abc144 = '';
                                          string abc145 = '';
                                          string abc146 = '';
                                          string abc147 = '';
                                          string abc148 = '';
                                          string abc149 = '';
                                          string abc150 = '';
                                          string abc151 = '';
                                          string abc152 = '';
                                          string abc153 = '';
                                          string abc154 = '';
                                          string abc155 = '';
                                          string abc160 = '';
                                          string abc161 = '';
                                          string abc162 = '';
                                          string abc163 = '';
                                          string abc164 = '';
                                          string abc165 = '';
                                          string abc166 = '';
                                          string abc167 = '';
                                          string abc168 = '';
                                          string abc169 = '';
                                          string abc170 = '';
                                          string abc171 = '';
                                          string abc172 = '';
                                          string abc173 = '';
                                          string abc174 = '';
                                          string abc175 = '';
                                          string abc176 = '';
                                          string abc177 = '';
                                          string abc178 = '';
                                          string abc179 = '';
                                          string abc180 = '';
                                          string abc181 = '';
                                          string abc182 = '';
                                          string abc183 = '';
                                          string abc184 = '';
                                          string abc185 = '';
                                          string abc186 = '';
                                          string abc187 = '';
                                          string abc188 = '';
                                          string abc189 = '';
                                          string abc190 = '';
                                          string abc191 = '';
                                          string abc192 = '';
                                          string abc193 = '';
                                          string abc194 = '';
                                          string abc195 = '';
                                          string abc196 = '';
                                          string abc197 = '';
                                          string abc198 = '';
                                          string abc199 = '';
                                          string abc200 = '';
                                          string abc201 = '';
                                          string abc202 = '';
                                          string abc203 = '';
                                          string abc204 = '';
                                          string abc205 = '';
                                          
                                          string abc221 = '';
                                          string abc222 = '';
                                          string abc223 = '';
                                          string abc224 = '';
                                          string abc225 = '';
                                          string abc226 = '';
                                          string abc227 = '';
                                          string abc228 = '';
                                          string abc229 = '';
                                          string abc230 = '';
                                          string abc231 = '';
                                          string abc232 = '';
                                          string abc233 = '';
                                          string abc234 = '';
                                          string abc235 = '';
                                          string abc236 = '';
                                          string abc237 = '';
                                          
                                          string abc245 = '';
                                          string abc246 = '';
                                          string abc247 = '';
                                          string abc248 = '';
                                          string abc249 = '';
                                          string abc250 = '';
                                          string abc251 = '';
                                          string abc252 = '';
                                          System.debug('✅ Gateway Log created: ' + log.Id);
                                          System.debug('⬅️ createGatewayLog END');
                                          
                                          return log.Id;
                                      }
    
    @AuraEnabled(cacheable=true)
    public static GiftCommitment getRecurringDonation ( string recDonId){
        return [select id, name from GiftCommitment where id = :recDonId limit 1];
    }
    
    @AuraEnabled(cacheable=false)
    public static void updateRecDonation ( String customerId, String paymentMethodId, GiftCommitment recDon, String productId, String priceId, String subId){
        recDon.Customer_Profile_Id__c = customerId;
        recDon.Payment_Profile_ID__c = paymentMethodId;
        recDon.Product_Id__c = productId;
        recDon.Price_Id__c = priceId;
        recDon.Subscription_Id__c = subId;
        update recDon;
    }
}