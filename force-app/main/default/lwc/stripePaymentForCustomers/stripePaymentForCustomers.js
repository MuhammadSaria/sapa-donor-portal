import { LightningElement , api,wire} from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import STRIPE_JS from '@salesforce/resourceUrl/StripeJS';
import attachPaymentMethodToCustomer from '@salesforce/apex/StripeCustomerService.attachPaymentMethodToCustomer';
import evaluatePaymentState from '@salesforce/apex/StripeCustomerService.evaluatePaymentState';
import createPaymentIntent from '@salesforce/apex/StripeCustomerService.createPaymentIntent';
import createLocalPaymentMethod from '@salesforce/apex/StripeCustomerService.createLocalPaymentMethod';
import createGatewayLog from '@salesforce/apex/StripeCustomerService.createGatewayLog';
import createRecurringSubscription from '@salesforce/apex/StripeCustomerService.createRecurringSubscription';
import getContactIdfromOpp from '@salesforce/apex/StripeCustomerService.getContactIdfromOpp';
import getContactIdfromRD from '@salesforce/apex/StripeCustomerService.getContactIdfromRD';
import { FlowNavigationNextEvent } from 'lightning/flowSupport';
import { FlowNavigationFinishEvent } from 'lightning/flowSupport';
import { CurrentPageReference } from 'lightning/navigation';
import StripeKey from '@salesforce/label/c.StripeKey';
import isGuest from '@salesforce/user/isGuest'; 
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class StripePaymentForCustomers extends LightningElement {
    stripe;
    isLoading = false;
    isGuestUser = isGuest;
    cardElement;
    isStripeInitialized = false;
    @api recordId;
    @api donationId;
    @api recurringDonationId;
    @api donationType;
    siteParam;
    hasNavigated = false;

    renderedCallback() {
        if (this.isStripeInitialized) return;
        this.isStripeInitialized = true;

        loadScript(this, 'https://js.stripe.com/v3/')
        //loadScript(this, STRIPE_JS)
            .then(() => {
                if (window.Stripe) {
                    this.stripe = window.Stripe(StripeKey);
                    console.log('Stripe Key:', this.stripe);
                    
                    // ✅ Check if DOM element exists before mounting
                    const cardElementContainer = this.template.querySelector('.card-element');
                    if (!cardElementContainer) {
                        throw new Error('Card element container (.card-element) not found in template');
                    }
                    
                    const elements = this.stripe.elements();
                    this.cardElement = elements.create('card');
                    this.cardElement.mount(cardElementContainer);
                    console.log('✅ Stripe.js loaded and card element mounted successfully');
                } else {
                    throw new Error('Stripe global not found');
                }
            })
            .catch(error => console.error('❌ Stripe.js failed to load:', error));
    }

     @wire(CurrentPageReference, { source: '$siteParam' } )
            getStateParameters(currentPageReference) {
                console.log('donationId Site:', this.donationId);
                console.log('recurringDonationId Site:', this.recurringDonationId);
                console.log('donationType Site:', this.donationType);
                if (currentPageReference) {
                    const state = currentPageReference.state;
                    if(this.donationId== null){
                        this.donationId = state.Id;
                    }
                    if(this.recurringDonationId== null){
                        this.recurringDonationId = state.RecId;
                    }
                   
                }
            }

    connectedCallback() {
        console.log('Record ID on init:', this.recordId);  
        console.log('donationId on init:', this.donationId);  
        console.log('Recurring Donation ID on init:', this.recurringDonationId);  
        if(this.recordId == null){
            this.fetchContactId();
        }
        //Checking if the user is guest or logged in user
        if (this.isGuestUser) {
            this.siteParam = 'SITE';
        }
        else{
            this.siteParam = 'FLOW';
        }
         console.log('isGuestUser:', this.siteParam);
    }

    fetchContactId(){
        //Query the contact from salesforce using this.donationId or this.recurringDonationId
        //and set this.recordId
        console.log('Fetching recordId based on donationId or recurringDonationId');    
        if(this.donationId != null && this.donationId != ''){
            //Query the contact from salesforce using this.donationId
            getContactIdfromOpp({donationId: this.donationId})
            .then(result => {
                this.recordId = result; 
                console.log('Fetched recordId:', this.recordId);  
            })
            .catch(error => {
                console.error('Error fetching recordId from donationId:', error);
            });

        }
        else if(this.recurringDonationId != null && this.recurringDonationId != ''  ){
            //Query the contact from salesforce using this.recurringDonationId
            getContactIdfromRD({recurringDonationId: this.recurringDonationId})
            .then(result => {
                this.recordId = result; 
                console.log('Fetched recordId:', this.recordId);  
            })
            .catch(error => {
                console.error('Error fetching recordId from recurringDonationId:', error);
            });  
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant, // 'success', 'error', 'warning', 'info'
                mode: 'dismissable' // or 'sticky'
            })
        );
    }

    async handleSubmit() {
        // ✅ Validate Stripe and card element are ready
        if (!this.stripe) {
            console.error('❌ Stripe not initialized. Please wait for page to fully load.');
            return;
        }
        if (!this.cardElement) {
            console.error('❌ Card element not initialized.');
            return;
        }
        
        this.isLoading = true; // 🔄 START spinner
        console.log('▶️ handleSubmit START');
        console.log('Record ID:', this.recordId);  
        console.log('donationId:', this.donationId);  
        console.log('Recurring Donation ID:', this.recurringDonationId);  
        let paymentMethodId;
        let expMonth, expYear, brand, last4;
        let gatewayId;

        // 1️⃣ Evaluate Payment State
        let state;
        try {
            //console.log('this.cardElement '+this.cardElement);
            //console.log('this.cardElement '+JSON.stringify(this.cardElement));
            state = await evaluatePaymentState({ contactId: this.recordId});
            //paymentMethodId = state.paymentProfileId;
        } catch (err) {
            console.error('❌ Failed to evaluate payment state:', err);
            this.isLoading = false; // ✅ STOP spinner
            //await this.logGateway(null, 'Failure', 'Evaluate Payment State', err, null, null);
            return;
        }

        // 2️⃣ Create PaymentMethod if not exists
        if (state.customerId) {
            let paymentMethod;
            try {
                console.log('Creating payment method with Stripe...');
                const result = await this.stripe.createPaymentMethod({
                    type: 'card',
                    card: this.cardElement
                });

                // ✅ Check for errors BEFORE accessing result.paymentMethod
                if (result.error) {
                    console.error('❌ Stripe createPaymentMethod error:', JSON.stringify(result.error.message));
                    throw result.error;
                }
                
                paymentMethod = result.paymentMethod;
                if (!paymentMethod || !paymentMethod.id) {
                    throw new Error('No payment method ID returned from Stripe');
                }

                // Extract card info
                expMonth = paymentMethod.card.exp_month;
                expYear = paymentMethod.card.exp_year;
                brand = paymentMethod.card.brand;
                last4 = paymentMethod.card.last4;
                //await this.logGateway(paymentMethod, 'Success', 'Payment Profile', '', null, null, null, null, null);
                //paymentMethodId = paymentMethod.id;
                console.log(`✅ PaymentMethod created: ${paymentMethod.id} - ${brand} ending in ${last4}`);
                paymentMethodId = paymentMethod.id;
            } catch (err) {
                console.error('❌ Stripe createPaymentMethod failed:', err);
                 this.isLoading = false; // ✅ STOP spinner
                // 🔥 Show Error Toast
                    // 🔥 Extract message safely
                const errorMessage =
                    err?.message ||               // Stripe-style errors
                    err?.body?.message ||         // Apex errors
                    'Something went wrong.';

                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Payment Error',
                        message: errorMessage,
                        variant: 'error',
                        mode: 'dismissable'
                    })
                );
                return;
            }

            // 3️⃣ Create Local Salesforce Payment Method
            try {
                gatewayId = await createGatewayLog({
                    response: JSON.stringify(paymentMethod),
                    logDate: new Date(),
                    successStatus: 'Success',
                    gateway: 'Stripe',
                    interactionType: 'Payment Profile',
                    cardOrAccountNumber: last4,
                    expirationDate: `${expMonth}/${expYear}`,
                    accountType: 'Card',
                    customerProfileId: state.customerId,
                    paymentProfileId: paymentMethod.id,
                    responseCode: '200'
                });
                console.log('✅ Gateway log created with ID:', gatewayId);

                await createLocalPaymentMethod({
                    contactId: this.recordId,
                    stripePaymentMethodId: paymentMethod.id,
                    expMonth,
                    brand,
                    gatewayId,
                    expYear,                    
                    last4
                });

                
            } 
            catch (err) {
                console.error('❌ Failed to create local payment method:', err);
                this.isLoading = false; // ✅ STOP spinner
                // 🔥 Show Error Toast
                    // 🔥 Extract message safely
                const errorMessage =
                    err?.message ||               // Stripe-style errors
                    err?.body?.message ||         // Apex errors
                    'Something went wrong.';

                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Error',
                        message: errorMessage,
                        variant: 'error',
                        mode: 'dismissable'
                    })
                );
                return;
            }

            // 4️⃣ Attach PaymentMethod to Customer
            try {
                await attachPaymentMethodToCustomer({
                    paymentMethodId,
                    customerId: state.customerId
                });
            } catch (err) {
                console.error('❌ Failed to attach payment method to customer:', err);
                // 🔥 Show Error Toast
                // 🔥 Extract message safely
                const errorMessage =
                    err?.message ||               // Stripe-style errors
                    err?.body?.message ;

                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Error Attaching Payment Method',
                        message: errorMessage,
                        variant: 'error',
                        mode: 'dismissable'
                    })
                );
                this.isLoading = false; // ✅ STOP spinner
                //await this.logGateway(null, 'Failure', 'Attach PaymentMethod', err, last4, `${expMonth}/${expYear}`);
                return;
            }
        }

        if(this.donationId != null && this.donationId != ''){
            // 5️⃣ Charge Customer
            try {
                const paymentIntentId = await createPaymentIntent({
                    customerId: state.customerId,
                    contactId : this.recordId,
                    donationId : this.donationId,
                    paymentMethodId,
                    curr: 'USD'
                });

                console.log('✅ Payment successful:', paymentIntentId);
                if (this.recurringDonationId == null || this.recurringDonationId == '') { 
                    this.navigateNext();
                    return;
                }
                await createGatewayLog({
                    response: `PaymentIntent ${paymentIntentId} created successfully`,
                    logDate: new Date(),
                    successStatus: 'Success',
                    gateway: 'Stripe',
                    interactionType: 'Sale',
                    cardOrAccountNumber: last4,
                    expirationDate: `${expMonth}/${expYear}`,
                    accountType: 'Card',
                    customerProfileId: state.customerId,
                    paymentProfileId: paymentMethodId,
                    responseCode: '200'
                });
            } 
            catch (err) {
                console.error('❌ Payment failed:', err);
                await createGatewayLog({
                    response: JSON.stringify(err),
                    logDate: new Date(),
                    successStatus: 'System Error',
                    gateway: 'Stripe',
                    interactionType: 'Sale',
                    cardOrAccountNumber: last4 || null,
                    expirationDate: expMonth && expYear ? `${expMonth}/${expYear}` : null,
                    accountType: 'Card',
                    customerProfileId: state.customerId,
                    paymentProfileId: paymentMethodId || null,
                    responseCode: 'N/A'
                });
                // 🔥 Show Error Toast
                    // 🔥 Extract message safely
                const errorMessage =
                    err?.message ||               // Stripe-style errors
                    err?.body?.message ||         // Apex errors
                    'Something went wrong.';

                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Donation setup failed',
                        message: errorMessage,
                        variant: 'error',
                        mode: 'dismissable'
                    })
                );
            }
        }
      if (this.recurringDonationId != null && this.recurringDonationId != '') {
        try {
        // You’ll likely have these values on the Recurring Donation record.
        // For now, plug them in from your UI / record fields.
        const productName = 'Recurring Donation'; 
        const currency = 'USD';
            console.log('test '+this.recurringDonationId);
        const subscriptionId = await createRecurringSubscription({
            customerId: state.customerId,
            paymentMethodId,
            productName,
            currency,
            donorReference: this.recurringDonationId,
            donationId: this.donationId
        });

        console.log('✅ Subscription created:', subscriptionId);
        this.navigateNext();
        return;


        await createGatewayLog({
            response: `Subscription ${subscriptionId} created successfully`,
            logDate: new Date(),
            successStatus: 'Success',
            gateway: 'Stripe',
            interactionType: 'Recurring Setup',
            cardOrAccountNumber: last4,
            expirationDate: expMonth && expYear ? `${expMonth}/${expYear}` : null,
            accountType: 'Card',
            customerProfileId: state.customerId,
            paymentProfileId: paymentMethodId,
            responseCode: '200'
        });

        // OPTIONAL: call another Apex method to save subscriptionId onto the Recurring Donation record

    } 
    catch (err) {
        console.error('❌ Recurring setup failed:', JSON.stringify(err));

        await createGatewayLog({
            response: JSON.stringify(err),
            logDate: new Date(),
            successStatus: 'System Error',
            gateway: 'Stripe',
            interactionType: 'Recurring Setup',
            cardOrAccountNumber: last4 || null,
            expirationDate: expMonth && expYear ? `${expMonth}/${expYear}` : null,
            accountType: 'Card',
            customerProfileId: state.customerId,
            paymentProfileId: paymentMethodId || null,
            responseCode: 'N/A'
        });
        // 🔥 Show Error Toast
                // 🔥 Extract message safely
                const errorMessage =
                    err?.message ||               // Stripe-style errors
                    err?.body?.message ||         // Apex errors
                    'Something went wrong.';

                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Recurring setup failed',
                        message: errorMessage,
                        variant: 'error',
                        mode: 'dismissable'
                    })
                );
        }
    } 
        this.isLoading = false; // ✅ STOP spinner
    }

    // 🔹 Helper method for logging failures before PaymentMethod creation
    async logGateway(response, status, interactionType, err, cardNumber, expirationDate, accountType = 'Card', customerProfileId = null, paymentProfileId = null) {
        try {
            await createGatewayLog({
                response: response || JSON.stringify(err),
                logDate: new Date(),
                successStatus: status,
                gateway: 'Stripe',
                interactionType: interactionType,
                cardOrAccountNumber: cardNumber,
                expirationDate: expirationDate,
                accountType,
                customerProfileId,
                paymentProfileId,
                responseCode: 'N/A'
            });
        } catch (logErr) {
            console.error('❌ Failed to log gateway:', logErr);
        }
    }

   navigateNext() {
    if (this.hasNavigated) return; // ✅ prevent double NEXT
    this.hasNavigated = true; 

    try {
        if (this.siteParam === 'FLOW') {
            this.dispatchEvent(new FlowNavigationNextEvent());
        } else {
            window.location.assign("./donation-success");
            //window.location.assign('hci.providus.io/donation/?payment=success');
           // window.location.assign(`${window.location.origin}/donation/?payment=success`);
        }
    } catch (err) {
        // If NEXT isn't available, don't keep trying
        console.error('❌ Navigation failed:', err);
    }
}


}