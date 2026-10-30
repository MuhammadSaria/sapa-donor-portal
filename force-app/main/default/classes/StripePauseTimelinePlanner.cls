/** Pure timeline classification and original-calendar planning for native pause/resume. */
public with sharing class StripePauseTimelinePlanner {
    private static final Integer MAX_SOURCES=4;
    public class Plan {
        public Integer version=1;
        public Long resumeAtEpoch;
        public String compensationStatus;
        public Id commitmentId;
        public Date pauseStartDate;
        public Date resumeDate;
        public Date nextPaymentDate;
        public String operationKey;
        public String snapshotSignature;
        public String beforeFingerprint;
        public String afterFingerprint;
        public Boolean applied=false;
        public Boolean resuming=false;
        public String compensationPauseJson;
        public List<GiftCommitmentSchedule> originalSegments=new List<GiftCommitmentSchedule>();
        public List<GiftTransaction> protectedPayments=new List<GiftTransaction>();
        public List<Operation> operations=new List<Operation>();
    }
    public class Operation {
        public Id sourceId;
        public Id pauseId;
        public Id restoredId;
        public Date pauseFrom;
        public Date restoreOn;
        public Date calendarAnchor;
        public Date restoredEndDate;
    }
    /** Classify consecutive segments, reject ambiguous ranges, and derive real restoration dates. */
    public static Plan plan(Id commitmentId,Date pauseStart,Date resumeDate,
        List<GiftCommitmentSchedule> segments,List<GiftTransaction> transactions) {
        if(commitmentId==null || pauseStart==null || resumeDate==null || resumeDate<=pauseStart)
            throw new TimelineException('Resume date must be after the Salesforce pause start date.');
        validate(segments,transactions);
        Plan result=new Plan();
        result.commitmentId=commitmentId;
        result.pauseStartDate=pauseStart;
        result.resumeDate=resumeDate;
        result.originalSegments=segments;
        result.beforeFingerprint=fingerprint(segments);
        for(GiftTransaction transactionRecord:transactions) {
            if(transactionRecord.Status=='Paid') result.protectedPayments.add(transactionRecord);
            Date paidOn=transactionRecord.TransactionDate??transactionRecord.TransactionDueDate;
            if(transactionRecord.Status=='Paid' && paidOn!=null && paidOn>=pauseStart && paidOn<resumeDate)
                throw new TimelineException('A paid transaction falls inside the proposed pause period. No changes were made.');
        }
        for(GiftCommitmentSchedule segment:segments) {
            if(segment.Type!='CreateTransactions' || (segment.EndDate!=null && segment.EndDate<pauseStart)) continue;
            Date anchor=calendarAnchor(segment,transactions);
            Date restored=paymentOnOrAfter(segment,anchor,resumeDate);
            if(restored!=null && (result.nextPaymentDate==null || restored<result.nextPaymentDate)) result.nextPaymentDate=restored;
            if(segment.StartDate>=resumeDate) continue;
            Operation operation=new Operation();
            operation.sourceId=segment.Id;
            operation.pauseFrom=segment.StartDate>pauseStart?segment.StartDate:pauseStart;
            operation.calendarAnchor=anchor;
            operation.restoreOn=restored;
            operation.restoredEndDate=segment.EndDate;
            for(GiftTransaction transactionRecord:transactions) {
                Date paidOn=transactionRecord.TransactionDate??transactionRecord.TransactionDueDate;
                if(transactionRecord.Status=='Paid' && transactionRecord.GiftCommitmentScheduleId==segment.Id
                    && paidOn!=null && paidOn>=operation.pauseFrom)
                    throw new TimelineException('A paid transaction is protected in an affected schedule. No changes were made.');
            }
            result.operations.add(operation);
        }
        if(result.operations.size()>MAX_SOURCES)
            throw new TimelineException('This pause spans more than four future billing segments. Shorten the pause period or ask an administrator to review it.');
        if(result.nextPaymentDate==null)
            throw new TimelineException('No valid payment remains after this pause. Select an earlier resume date.');
        return result;
    }
    public static void validate(List<GiftCommitmentSchedule> segments,List<GiftTransaction> transactions) {
        if(segments.isEmpty() || segments.size()>200 || transactions.size()>5000)
            throw new TimelineException('The schedule timeline is unavailable or exceeds the safe review limit.');
        GiftCommitmentSchedule previous;
        for(GiftCommitmentSchedule segment:segments) {
            if(segment.StartDate==null || (segment.EndDate!=null && segment.EndDate<segment.StartDate))
                throw new TimelineException('A schedule has invalid dates. Administrator review is required.');
            if(previous!=null && (previous.EndDate==null || previous.EndDate>=segment.StartDate))
                throw new TimelineException('Salesforce schedules actually overlap. Administrator review is required before pausing.');
            previous=segment;
        }
    }
    public static String fingerprint(List<GiftCommitmentSchedule> segments) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256',Blob.valueOf(JSON.serialize(segments))));
    }
    /** Explicit values avoid JSON property-order changes after durable snapshot deserialization. */
    public static Boolean sameSegment(GiftCommitmentSchedule first,GiftCommitmentSchedule second) {
        return first!=null && second!=null && first.Id==second.Id && first.GiftCommitmentId==second.GiftCommitmentId
            && first.Type==second.Type && first.StartDate==second.StartDate && first.EndDate==second.EndDate
            && first.TransactionAmount==second.TransactionAmount && first.TransactionPeriod==second.TransactionPeriod
            && first.TransactionInterval==second.TransactionInterval && first.TransactionDay==second.TransactionDay
            && first.PaymentMethod==second.PaymentMethod && first.Final_Payment_Date__c==second.Final_Payment_Date__c;
    }
    public static Boolean samePaid(GiftTransaction first,GiftTransaction second) {
        return first!=null && second!=null && first.Id==second.Id && first.Status==second.Status
            && first.GiftCommitmentScheduleId==second.GiftCommitmentScheduleId && first.OriginalAmount==second.OriginalAmount
            && first.TransactionDate==second.TransactionDate && first.TransactionDueDate==second.TransactionDueDate;
    }
    public static Date calendarAnchor(GiftCommitmentSchedule segment,List<GiftTransaction> transactions) {
        Date anchor;
        for(GiftTransaction transactionRecord:transactions) {
            if(transactionRecord.GiftCommitmentScheduleId==segment.Id && transactionRecord.TransactionDueDate!=null
                && transactionRecord.TransactionDueDate>=segment.StartDate
                && (anchor==null || transactionRecord.TransactionDueDate<anchor)) anchor=transactionRecord.TransactionDueDate;
        }
        return anchor??segment.StartDate;
    }
    /** First original-calendar occurrence on/after the date, limited by the source's final boundary. */
    public static Date paymentOnOrAfter(GiftCommitmentSchedule segment,Date anchor,Date boundary) {
        Set<String> supportedPeriods=new Set<String>{'Daily','Weekly','Monthly','Yearly'};
        if(!supportedPeriods.contains(segment.TransactionPeriod))
            throw new TimelineException('This schedule uses an unsupported recurring period.');
        if(segment.TransactionInterval==null || segment.TransactionInterval<1)
            throw new TimelineException('The recurring interval must be positive.');
        Date cursor=anchor;
        if(segment.TransactionPeriod=='Monthly') cursor=monthlyDay(cursor,segment.TransactionDay);
        Integer guard=0;
        while(cursor<boundary || cursor<segment.StartDate) {
            if(++guard>5000) throw new TimelineException('The billing calendar exceeds the safe calculation limit.');
            Integer intervalCount=segment.TransactionInterval;
            if(segment.TransactionPeriod=='Daily') cursor=cursor.addDays(intervalCount);
            else if(segment.TransactionPeriod=='Weekly') cursor=cursor.addDays(7*intervalCount);
            else if(segment.TransactionPeriod=='Monthly') cursor=monthlyDay(cursor.addMonths(intervalCount),segment.TransactionDay);
            else if(segment.TransactionPeriod=='Yearly') cursor=anchor.addYears(guard*intervalCount);
            else throw new TimelineException('This schedule uses an unsupported recurring period.');
        }
        return segment.EndDate!=null && cursor>segment.EndDate?null:cursor;
    }
    private static Date monthlyDay(Date dateValue,String day) {
        if(String.isBlank(day)) throw new TimelineException('A valid monthly Transaction Day is required.');
        Integer lastDay=Date.daysInMonth(dateValue.year(),dateValue.month());
        Integer selected;
        try { selected=day=='LastDay'?lastDay:Integer.valueOf(day); }
        catch(TypeException invalidDay) { throw new TimelineException('A valid monthly Transaction Day is required.'); }
        if(selected<1 || selected>31) throw new TimelineException('A valid monthly Transaction Day is required.');
        return Date.newInstance(dateValue.year(),dateValue.month(),Math.min(selected,lastDay));
    }
    public static GiftCommitmentSchedule current(List<GiftCommitmentSchedule> segments,Date onDate) {
        for(GiftCommitmentSchedule segment:segments)
            if(segment.StartDate<=onDate && (segment.EndDate==null || segment.EndDate>=onDate)) return segment;
        return null;
    }
    public class TimelineException extends Exception { }
}