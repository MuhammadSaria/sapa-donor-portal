@IsTest
public class URLExtractorUtilityTest {

    @IsTest
    static void testExtractURLFromRichText_withAnchorTag() {
        // Prepare input with a standard <a href="..."> tag
        URLExtractorUtility.RequestWrapper req = new URLExtractorUtility.RequestWrapper();
        req.richTextField = '<p>Click here: <a href="https://example.com/page1">link</a></p>';

        List<URLExtractorUtility.ExtractedURL> results =
            URLExtractorUtility.extractURLFromRichText(new List<URLExtractorUtility.RequestWrapper>{req});

        System.assertEquals(1, results.size(), 'Should return one result');
        System.assertEquals('https://example.com/page1', results[0].url, 'Should extract URL correctly');
    }

    @IsTest
    static void testExtractURLFromRichText_withoutAnchorTag() {
        // Prepare input with plain text (no <a> tag)
        URLExtractorUtility.RequestWrapper req = new URLExtractorUtility.RequestWrapper();
        req.richTextField = 'https://example.com/page2';

        List<URLExtractorUtility.ExtractedURL> results =
            URLExtractorUtility.extractURLFromRichText(new List<URLExtractorUtility.RequestWrapper>{req});

        System.assertEquals(1, results.size(), 'Should return one result');
        System.assertEquals('https://example.com/page2', results[0].url, 'Should return the original text if no <a> tag');
    }

    @IsTest
    static void testExtractURLFromRichText_blankInput() {
        // Prepare input with blank/null rich text
        URLExtractorUtility.RequestWrapper req1 = new URLExtractorUtility.RequestWrapper();
        req1.richTextField = null;

        URLExtractorUtility.RequestWrapper req2 = new URLExtractorUtility.RequestWrapper();
        req2.richTextField = '';

        List<URLExtractorUtility.ExtractedURL> results =
            URLExtractorUtility.extractURLFromRichText(new List<URLExtractorUtility.RequestWrapper>{req1, req2});

        System.assertEquals(2, results.size(), 'Should return two results');
        System.assertEquals(null, results[0].url, 'Null input should return null');
        System.assertEquals(null, results[1].url, 'Empty string input should return null');
    }

    @IsTest
    static void testExtractURLFromRichText_htmlWithMultipleAnchors() {
        // Input with multiple <a> tags
        URLExtractorUtility.RequestWrapper req = new URLExtractorUtility.RequestWrapper();
        req.richTextField = '<p><a href="https://first.com">first</a> <a href="https://second.com">second</a></p>';

        List<URLExtractorUtility.ExtractedURL> results =
            URLExtractorUtility.extractURLFromRichText(new List<URLExtractorUtility.RequestWrapper>{req});

        System.assertEquals('https://first.com', results[0].url, 'Should extract only the first <a> href');
    }

    @IsTest
    static void testExtractURLFromRichText_withEncodedAmp() {
        // Input with &amp; in URL
        URLExtractorUtility.RequestWrapper req = new URLExtractorUtility.RequestWrapper();
        req.richTextField = '<a href="https://example.com/page?param=1&amp;param2=2">link</a>';

        List<URLExtractorUtility.ExtractedURL> results =
            URLExtractorUtility.extractURLFromRichText(new List<URLExtractorUtility.RequestWrapper>{req});

        System.assertEquals('https://example.com/page?param=1&param2=2', results[0].url, 'Should decode &amp; to &');
    }
}