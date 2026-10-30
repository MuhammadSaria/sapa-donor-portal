/**
 * Invocable action that generates LaunchGood Donation Fund route keys for Flow.
 */
public with sharing class LaunchGoodDonationFundRouteKeyAction {
    /**
     * Generates route keys for LaunchGood Donation Fund mapping records.
     * @param requests Flow input rows containing Project URL and Special Request values.
     * @return Flow output rows containing the generated route key.
     */
    @InvocableMethod(
        label='Generate LaunchGood Donation Fund Route Key'
        description='Generates the duplicate-prevention key for a LaunchGood Donation Fund mapping.'
        category='LaunchGood'
    )
    public static List<Response> generate(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null) {
            return responses;
        }

        for (Request request : requests) {
            Response response = new Response();
            response.routeKey = LaunchGoodDonationFundRouteKeyService.generateRouteKey(
                request == null ? null : request.projectUrl,
                request == null ? null : request.specialRequest
            );
            responses.add(response);
        }

        return responses;
    }

    /**
     * Input values supplied by Flow.
     */
    public class Request {
        @InvocableVariable(label='Project URL' description='LaunchGood Project URL to normalize.' required=false)
        public String projectUrl;

        @InvocableVariable(label='Special Request' description='LaunchGood Special Request to normalize.' required=false)
        public String specialRequest;
    }

    /**
     * Generated route key returned to Flow.
     */
    public class Response {
        @InvocableVariable(label='Route Key' description='Generated duplicate-prevention route key.')
        public String routeKey;
    }
}