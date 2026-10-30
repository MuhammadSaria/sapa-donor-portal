@isTest
public class StripeRefundServiceMock implements HttpCalloutMock {
    protected Integer code;
    protected String body;

    public StripeRefundServiceMock(Integer code, String body) {
        this.code = code;
        this.body = body;
    }

    public HTTPResponse respond(HTTPRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');
        res.setBody(this.body);
        res.setStatusCode(this.code);
        return res;
    }
}