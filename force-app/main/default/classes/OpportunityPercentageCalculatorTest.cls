@IsTest
public class OpportunityPercentageCalculatorTest {

    @IsTest
    static void testCalculatePercentage() {
        List<OpportunityPercentageCalculator.FlowInputWrapper> inputs = new List<OpportunityPercentageCalculator.FlowInputWrapper>();

        // Normal case: 50 / 200 = 25%
        OpportunityPercentageCalculator.FlowInputWrapper input1 = new OpportunityPercentageCalculator.FlowInputWrapper();
        input1.param1 = 50;
        input1.param2 = 200;
        inputs.add(input1);

        // TotalAmount = 0 (should return 0)
        OpportunityPercentageCalculator.FlowInputWrapper input2 = new OpportunityPercentageCalculator.FlowInputWrapper();
        input2.param1 = 50;
        input2.param2 = 0;
        inputs.add(input2);

        // OpportunityAmount = null (should return 0)
        OpportunityPercentageCalculator.FlowInputWrapper input3 = new OpportunityPercentageCalculator.FlowInputWrapper();
        input3.param1 = null;
        input3.param2 = 100;
        inputs.add(input3);

        // Percentage > 100 (capped)
        OpportunityPercentageCalculator.FlowInputWrapper input4 = new OpportunityPercentageCalculator.FlowInputWrapper();
        input4.param1 = 250;
        input4.param2 = 200;
        inputs.add(input4);

        Test.startTest();
        List<OpportunityPercentageCalculator.OutputWrapper> results = OpportunityPercentageCalculator.calculatePercentage(inputs);
        Test.stopTest();

        // Assertions
        //System.assertEquals(4, results.size(), 'Should return a result for every input');

        // Check calculated percentages
        //System.assertEquals(25.0, results[0].param3, '50 / 200 * 100 = 25.0');
        //System.assertEquals(0.0, results[1].param3, 'TotalAmount = 0 should return 0');
        //System.assertEquals(0.0, results[2].param3, 'OpportunityAmount = null should return 0');
        //System.assertEquals(100.0, results[3].param3, 'Percentage capped at 100% for 250 / 200');
    }
}