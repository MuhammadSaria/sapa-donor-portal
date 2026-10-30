public class URLExtractorUtility {
    @InvocableMethod(label='Extract URL from Rich Text' description='Extracts the first URL from a rich text field')
    public static List<ExtractedURL> extractURLFromRichText(List<RequestWrapper> requests) {
        List<ExtractedURL> results = new List<ExtractedURL>();
        
        for (RequestWrapper request : requests) {
            String extractedUrl = null;

            if (String.isNotBlank(request.richTextField)) {
                Pattern anchorTagPattern = Pattern.compile('<a\\s+[^>]*href="([^"]*)"[^>]*>');
                Matcher matcher = anchorTagPattern.matcher(request.richTextField);
                if (matcher.find()) {
                    extractedUrl = matcher.group(1).replace('&amp;', '&');
                }else{
                    extractedUrl = request.richTextField;
                }
            }

            // Add the result to the list
            results.add(new ExtractedURL(extractedUrl));
        }
        
        return results;
    }

    // Wrapper class for the request
    public class RequestWrapper {
        @InvocableVariable(label='Rich Text Field' description='The rich text field content' required=true)
        public String richTextField;
    }

    // Wrapper class for the response
    public class ExtractedURL {
        @InvocableVariable(label='Extracted URL' description='The extracted URL from the rich text field')
        public String url;

        public ExtractedURL(String url) {
            this.url = url;
        }
    }
}