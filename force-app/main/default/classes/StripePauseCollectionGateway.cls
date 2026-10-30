/** Narrow collection-only transport; retains the staging credential reference unchanged. */
public with sharing class StripePauseCollectionGateway {
    public static Map<String,Object> read(String subscriptionId) {
        Stripe_Recurring_Sync_Config__mdt config=StripeRecurringSyncConfig.resolve();
        if(config==null) throw new CollectionException('Stripe pause configuration is missing or ambiguous. Administrator review required.');
        HttpResponse response=send('GET',subscriptionId,null,null);
        Map<String,Object> result=(Map<String,Object>)JSON.deserializeUntyped(response.getBody());
        if(String.valueOf(result.get('id'))!=subscriptionId)
            throw new CollectionException('Stripe returned a different subscription.');
        if(config!=null && config.Require_Test_Mode__c && result.get('livemode')!=false)
            throw new CollectionException('This sandbox requires a Stripe test-mode subscription.');
        return result;
    }
    public static void write(String subscriptionId,Map<String,Object> pause,String requestKey) {
        String body='pause_collection=';
        if(pause!=null) body='pause_collection[behavior]='+EncodingUtil.urlEncode(String.valueOf(pause.get('behavior')),'UTF-8')+
            (pause.get('resumes_at')==null?'':'&pause_collection[resumes_at]='+String.valueOf(pause.get('resumes_at')));
        body+='&metadata[salesforce_pause_request]='+EncodingUtil.urlEncode(requestKey,'UTF-8');
        send('POST',subscriptionId,body,requestKey);
    }
    public static Map<String,Object> collection(Map<String,Object> stripe) {
        return stripe.get('pause_collection')==null?null:(Map<String,Object>)stripe.get('pause_collection');
    }
    public static Long resumeEpoch(Date onDate) {
        // Resume date is exclusive of the pause; enable collection before that day's normal invoice.
        return DateTime.newInstanceGmt(onDate.year(),onDate.month(),onDate.day(),0,0,0).getTime()/1000;
    }
    public static Boolean matches(Map<String,Object> first,Map<String,Object> second) {
        if(first==null || second==null) return first==null && second==null;
        return String.valueOf(first.get('behavior'))==String.valueOf(second.get('behavior'))
            && String.valueOf(first.get('resumes_at'))==String.valueOf(second.get('resumes_at'));
    }
    private static HttpResponse send(String method,String subscriptionId,String body,String requestKey) {
        HttpRequest request=new HttpRequest();
        request.setEndpoint('https://api.stripe.com/v1/subscriptions/'+EncodingUtil.urlEncode(subscriptionId,'UTF-8'));
        request.setMethod(method);
        request.setHeader('Authorization','Bearer '+System.Label.Stripe_Secret);
        request.setTimeout(20000);
        if(method=='POST') {
            request.setHeader('Content-Type','application/x-www-form-urlencoded');
            request.setHeader('Idempotency-Key',requestKey);
            request.setBody(body);
        }
        HttpResponse response=new Http().send(request);
        if(response.getStatusCode()<200 || response.getStatusCode()>=300)
            throw new CollectionException('Stripe did not accept the collection change. Review the gateway log before retrying.');
        return response;
    }
    public class CollectionException extends Exception { }
}