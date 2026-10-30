/**
 * Generates normalized LaunchGood Donation Fund route keys for duplicate prevention.
 */
public with sharing class LaunchGoodDonationFundRouteKeyService {
    private static final String ROUTE_KEY_SEPARATOR = '|';
    private static final String HASH_ALGORITHM = 'SHA-256';

    /**
     * Generates a SHA-256 route key from Project URL and Special Request.
     * @param projectUrl LaunchGood Project URL.
     * @param specialRequest LaunchGood Special Request value.
     * @return Lowercase 64-character SHA-256 hex key, or blank when Project URL is blank.
     */
    public static String generateRouteKey(String projectUrl, String specialRequest) {
        String normalizedUrl = normalizeUrl(projectUrl);
        if (normalizedUrl == null) {
            return '';
        }

        String normalizedSpecialRequest = normalizeSpecialRequest(specialRequest);
        Blob keyBlob = Blob.valueOf(
            normalizedUrl +
            ROUTE_KEY_SEPARATOR +
            (normalizedSpecialRequest == null ? '' : normalizedSpecialRequest)
        );

        return EncodingUtil.convertToHex(Crypto.generateDigest(HASH_ALGORITHM, keyBlob)).toLowerCase();
    }

    /**
     * Normalizes LaunchGood Project URLs consistently with routing.
     * @param value Project URL value.
     * @return Trimmed lowercase URL without one trailing slash, or null when blank.
     */
    public static String normalizeUrl(String value) {
        if (String.isBlank(value)) {
            return null;
        }

        String cleaned = value.trim().toLowerCase();
        if (cleaned.endsWith('/')) {
            cleaned = cleaned.substring(0, cleaned.length() - 1);
        }

        return cleaned;
    }

    /**
     * Normalizes LaunchGood Special Request values consistently with routing.
     * @param value Special Request value.
     * @return Trimmed lowercase value, or null when blank.
     */
    public static String normalizeSpecialRequest(String value) {
        if (String.isBlank(value)) {
            return null;
        }

        return value.trim().toLowerCase();
    }
}