public with sharing class OpportunityPercentageCalculator {
    
    public class FlowInputWrapper {
        @InvocableVariable
        public decimal param1; // First parameter
        
        @InvocableVariable
        public decimal param2; // Second parameter
    }
    
    public class OutputWrapper {
        @InvocableVariable
        public decimal param3; // Third parameter
    }
    /**
* Calculates percentage of opportunity amount against total amount
* Formula: (opportunityAmount / totalAmount) * 100
*/
    @InvocableMethod(label='Get opportunity percentage')
    public static List<OutputWrapper> calculatePercentage(
        List<FlowInputWrapper> request
    )
    {
        /* String totalAmount = input.param1;
String opportunityAmount = input.param2;
// Prevent divide by zero
if (totalAmount == null || totalAmount == 0 || opportunityAmount == null) {
return 0;
}

Decimal percentage = (opportunityAmount / totalAmount) * 100;
return percentage.setScale(2); // optional: round to 2 decimal places*/
        List<OutputWrapper> results = new List<OutputWrapper>();
        for (FlowInputWrapper input : request) {
            
            decimal opportunityAmount = input.param1;
            decimal totalAmount = input.param2;
            
            if (totalAmount == null || totalAmount == 0 || opportunityAmount == null) {
                return results;
            }
            
            Decimal percentage = (opportunityAmount / totalAmount) * 100;
            percentage = Math.min(percentage, 100);
            OutputWrapper output = new OutputWrapper();
            output.param3 = percentage.setScale(3);
            system.debug('param3 '+output.param3);
            results.add(output);
        }
        return results;
    }
}