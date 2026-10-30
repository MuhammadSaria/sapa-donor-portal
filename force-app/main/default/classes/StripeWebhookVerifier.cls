public without sharing class StripeWebhookVerifier {

    public static Boolean isValid(String payload, String signatureHeader, String webhookSecret) {
        if (String.isBlank(payload) || String.isBlank(signatureHeader) || String.isBlank(webhookSecret)) {
            return false;
        }

        // Extract timestamp and signatures from header
        Map<String, String> components = parseSignatureHeader(signatureHeader);
        String timestamp = components.get('t');
        List<String> signatures = components.get('v1') != null ? 
                                  components.get('v1').split(',') : new List<String>();

        if (timestamp == null || signatures.isEmpty()) {
            return false;
        }

        // Reconstruct the signed payload
        String signedPayload = timestamp + '.' + payload;

        // Compute expected signature
        String expectedSignature = generateHmacSHA256(webhookSecret, signedPayload);

        // Securely compare signatures (use timing-safe comparison)
        for (String sig : signatures) {
            if (secureCompare(sig, expectedSignature)) {
                // Optional: Check for replay attacks (e.g., timestamp not too old)
                Long requestTime = Long.valueOf(timestamp);
                Long currentTime = DateTime.now().getTime() / 1000;
                if (Math.abs(currentTime - requestTime) < 300) { // 5-minute window
                    return true;
                }
            }
        }
        return false;
    }

    private static Map<String, String> parseSignatureHeader(String header) {
        Map<String, String> result = new Map<String, String>();
        for (String part : header.split(',')) {
            List<String> keyValue = part.split('=', 2);
            if (keyValue.size() == 2) {
                result.put(keyValue[0].trim(), keyValue[1].trim());
            }
        }
        return result;
    }

    private static String generateHmacSHA256(String key, String data) {
        Blob keyBlob = Blob.valueOf(key);
        Blob dataBlob = Blob.valueOf(data);
        Blob hmacBlob = Crypto.generateMac('HMACSHA256', dataBlob, keyBlob);
        return EncodingUtil.convertToHex(hmacBlob);
    }

    // Timing-safe string comparison to prevent side-channel attacks
    private static Boolean secureCompare(String a, String b) {
        if (a == null || b == null || a.length() != b.length()) {
            return false;
        }
        Integer diff = 0;
        for (Integer i = 0; i < a.length(); i++) {
            diff |= Math.abs(a.charAt(i) - b.charAt(i));
        }
        return diff == 0;
    }
}