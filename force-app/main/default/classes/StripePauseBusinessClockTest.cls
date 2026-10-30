@IsTest
private class StripePauseBusinessClockTest {
    @IsTest static void midnightAndDstAreIndependentOfCallerTimezone() {
        Assert.areEqual(Date.newInstance(2026,10,1),StripePauseBusinessClock.businessDate(DateTime.newInstanceGmt(2026,10,2,6,30,0)));
        Assert.areEqual(Date.newInstance(2026,10,2),StripePauseBusinessClock.businessDate(DateTime.newInstanceGmt(2026,10,2,7,0,0)));
        Assert.areEqual(DateTime.newInstanceGmt(2026,3,8,8,0,0),StripePauseBusinessClock.resumeAt(Date.newInstance(2026,3,8)));
        Assert.areEqual(DateTime.newInstanceGmt(2026,3,9,7,0,0),StripePauseBusinessClock.resumeAt(Date.newInstance(2026,3,9)));
        Assert.areEqual(DateTime.newInstanceGmt(2026,11,1,7,0,0),StripePauseBusinessClock.resumeAt(Date.newInstance(2026,11,1)));
        Assert.areEqual(DateTime.newInstanceGmt(2026,11,2,8,0,0),StripePauseBusinessClock.resumeAt(Date.newInstance(2026,11,2)));
        User caller=[SELECT Id,TimeZoneSidKey FROM User WHERE Id=:UserInfo.getUserId()];
        caller.TimeZoneSidKey='Asia/Tokyo';update caller;
        System.runAs(caller) {
            Assert.areEqual(DateTime.newInstanceGmt(2026,10,2,7,0,0).getTime()/1000,
                StripePauseBusinessClock.resumeEpoch(Date.newInstance(2026,10,2)));
        }
    }
}