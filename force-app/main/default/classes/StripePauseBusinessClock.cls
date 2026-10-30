/** Explicit business date and midnight conversion, independent of the caller's timezone. */
public with sharing class StripePauseBusinessClock {
    public static final String TIME_ZONE = 'America/Los_Angeles';
    public static Date today() { return businessDate(System.now()); }
    public static Date businessDate(DateTime instant) {
        return Date.valueOf(instant.format('yyyy-MM-dd', TIME_ZONE));
    }
    public static DateTime resumeAt(Date dateValue) {
        DateTime localMidnight = DateTime.newInstanceGmt(dateValue, Time.newInstance(0,0,0,0));
        TimeZone zone = TimeZone.getTimeZone(TIME_ZONE);
        DateTime instant = localMidnight.addSeconds(-zone.getOffset(localMidnight)/1000);
        // Re-evaluate at the resulting instant for dates on a daylight-saving boundary.
        return localMidnight.addSeconds(-zone.getOffset(instant)/1000);
    }
    public static Long resumeEpoch(Date dateValue) { return resumeAt(dateValue).getTime()/1000; }
}