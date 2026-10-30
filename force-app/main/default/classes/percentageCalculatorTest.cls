@IsTest
public class percentageCalculatorTest {

    @IsTest
    static void testCalculatePercentage() {
        // Prepare input for the invocable method
        List<OpportunityPercentageCalculator.FlowInputWrapper> inputList = new List<OpportunityPercentageCalculator.FlowInputWrapper>();
        
        OpportunityPercentageCalculator.FlowInputWrapper input1 = new OpportunityPercentageCalculator.FlowInputWrapper();
        input1.param1 = 50; // opportunityAmount
        input1.param2 = 200; // totalAmount
        inputList.add(input1);
        
        OpportunityPercentageCalculator.FlowInputWrapper input2 = new OpportunityPercentageCalculator.FlowInputWrapper();
        input2.param1 = 0; // opportunityAmount
        input2.param2 = 100; // totalAmount
        inputList.add(input2);
        
        OpportunityPercentageCalculator.FlowInputWrapper input3 = new OpportunityPercentageCalculator.FlowInputWrapper();
        input3.param1 = 30; 
        input3.param2 = 0; // totalAmount = 0, should handle divide by zero
        inputList.add(input3);
        
        // Call the invocable method
        Test.startTest();
        List<OpportunityPercentageCalculator.OutputWrapper> results = OpportunityPercentageCalculator.calculatePercentage(inputList);
        Test.stopTest();
        
        // Verify results
        System.assertEquals(2, results.size(), 'Results list should contain 2 valid percentages'); 
        System.assertEquals(25.00, results[0].param3, 'Percentage for first input should be 25%');
        System.assertEquals(0.00, results[1].param3, 'Percentage for second input should be 0%');
        
        // Third input should not be added because totalAmount = 0
    }

    @IsTest
    static void testNullValues() {
        List<OpportunityPercentageCalculator.FlowInputWrapper> inputList = new List<OpportunityPercentageCalculator.FlowInputWrapper>();
        
        OpportunityPercentageCalculator.FlowInputWrapper input = new OpportunityPercentageCalculator.FlowInputWrapper();
        input.param1 = null; 
        input.param2 = 100; 
        inputList.add(input);
        
        List<OpportunityPercentageCalculator.OutputWrapper> results = OpportunityPercentageCalculator.calculatePercentage(inputList);
        
        // No results should be returned
        System.assertEquals(0, results.size(), 'No results should be returned for null opportunityAmount');
    }
}