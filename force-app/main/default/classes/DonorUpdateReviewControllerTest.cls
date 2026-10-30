@isTest
private class DonorUpdateReviewControllerTest {

    private static User reviewerUser;
    private static User plainUser;

    @testSetup
    static void setup() {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Portal_Donor_Care_Review' LIMIT 1];

        User reviewer = new User(
            FirstName = 'Reviewer', LastName = 'Test', Email = 'sapa.reviewer@example.com',
            Username = 'sapa.reviewer@example.com.sapatest', Alias = 'sreview',
            TimeZoneSidKey = 'America/Los_Angeles', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = adminProfile.Id
        );
        User plain = new User(
            FirstName = 'Plain', LastName = 'Reviewer', Email = 'plain.reviewer@example.com',
            Username = 'plain.reviewer@example.com.sapatest', Alias = 'plainr',
            TimeZoneSidKey = 'America/Los_Angeles', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = standardProfile.Id
        );
        insert new List<User>{ reviewer, plain };
        insert new PermissionSetAssignment(AssigneeId = reviewer.Id, PermissionSetId = ps.Id);
    }

    private static Id personAccountRecordTypeId() {
        return [SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
    }

    private static Account makeSubmittedAccount(String lastName) {
        Account acc = new Account(
            RecordTypeId = personAccountRecordTypeId(),
            FirstName = 'Test',
            LastName = lastName,
            PersonEmail = lastName.toLowerCase() + '@example.com',
            Portal_Status__c = 'Submitted',
            Portal_Token__c = PortalLinkService.newToken(),
            Portal_Token_Expiry__c = System.now().addDays(30)
        );
        insert acc;
        return [SELECT Id, PersonEmail FROM Account WHERE Id = :acc.Id];
    }

    private static User reviewer() {
        if (reviewerUser == null) {
            reviewerUser = [SELECT Id FROM User WHERE Username = 'sapa.reviewer@example.com.sapatest' LIMIT 1];
        }
        return reviewerUser;
    }

    private static User plain() {
        if (plainUser == null) {
            plainUser = [SELECT Id FROM User WHERE Username = 'plain.reviewer@example.com.sapatest' LIMIT 1];
        }
        return plainUser;
    }

    @isTest
    static void pendingSubmissionsReturnsCurrentAndNewValues() {
        Account acc = makeSubmittedAccount('ReviewPending');
        update new Account(
            Id = acc.Id,
            New_Phone__c = '5559990001',
            New_Street__c = '400 Birch St',
            New_City__c = 'Springfield'
        );

        List<DonorUpdateReviewController.SubmissionRow> rows;
        Test.startTest();
        System.runAs(reviewer()) {
            rows = DonorUpdateReviewController.getPendingSubmissions();
        }
        Test.stopTest();

        DonorUpdateReviewController.SubmissionRow match;
        for (DonorUpdateReviewController.SubmissionRow row : rows) {
            if (row.accountId == acc.Id) {
                match = row;
            }
        }
        System.assertNotEquals(null, match, 'The submitted account should appear in the pending list');
        System.assertEquals(true, match.phoneChanged);
        System.assertEquals(true, match.addressChanged);
        System.assertEquals('5559990001', match.newPhone);
    }

    // doc section 10, test 9: Accept applies only the editable sections, sets verified date,
    // clears held values and token -- and, critically, must not blank PersonEmail (resolved design decision).
    @isTest
    static void acceptAppliesPhoneAndPreservesEmail() {
        Account acc = makeSubmittedAccount('AcceptPhone');
        update new Account(Id = acc.Id, New_Phone__c = '5559990002');

        Test.startTest();
        System.runAs(reviewer()) {
            DonorUpdateReviewController.accept(acc.Id);
        }
        Test.stopTest();

        Account after = [
            SELECT PersonMobilePhone, PersonEmail, PersonMailingStreet, New_Phone__c, Portal_Token__c,
                   Portal_Status__c, Contact_Info_Verified_Date__c, Portal_Reviewed_By__c, Portal_Reviewed_Date__c
            FROM Account WHERE Id = :acc.Id
        ];
        System.assertEquals('5559990002', after.PersonMobilePhone);
        System.assertEquals(acc.PersonEmail, after.PersonEmail, 'Email must survive the phone-triggered resync flow');
        System.assertEquals(null, after.PersonMailingStreet, 'Address was not part of this submission');
        System.assertEquals(null, after.New_Phone__c);
        System.assertEquals(null, after.Portal_Token__c);
        System.assertEquals('Accepted', after.Portal_Status__c);
        System.assertEquals(Date.today(), after.Contact_Info_Verified_Date__c);
        System.assertEquals(reviewer().Id, after.Portal_Reviewed_By__c);
        System.assertNotEquals(null, after.Portal_Reviewed_Date__c);
    }

    @isTest
    static void acceptAppliesAddressOnly() {
        Account acc = makeSubmittedAccount('AcceptAddress');
        update new Account(
            Id = acc.Id,
            New_Street__c = '500 Maple Ave',
            New_City__c = 'Springfield',
            New_State__c = 'Illinois',
            New_Postal_Code__c = '62704',
            New_Country__c = 'United States'
        );

        Test.startTest();
        System.runAs(reviewer()) {
            DonorUpdateReviewController.accept(acc.Id);
        }
        Test.stopTest();

        Account after = [SELECT PersonMailingStreet, PersonMobilePhone, New_Street__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals('500 Maple Ave', after.PersonMailingStreet);
        System.assertEquals(null, after.PersonMobilePhone, 'Phone was not part of this submission');
        System.assertEquals(null, after.New_Street__c);
    }

    // doc section 10, test 10: Reject changes nothing on the donor details
    @isTest
    static void rejectChangesNothingOnDonorDetails() {
        Account acc = makeSubmittedAccount('RejectMe');
        update new Account(Id = acc.Id, New_Phone__c = '5559990004', New_Street__c = '600 Pine St');

        Test.startTest();
        System.runAs(reviewer()) {
            DonorUpdateReviewController.reject(acc.Id, 'Phone number looks invalid');
        }
        Test.stopTest();

        Account after = [
            SELECT PersonMobilePhone, PersonMailingStreet, New_Phone__c, New_Street__c, Portal_Token__c,
                   Portal_Status__c, Portal_Reviewed_By__c, Portal_Reviewed_Date__c
            FROM Account WHERE Id = :acc.Id
        ];
        System.assertEquals(null, after.PersonMobilePhone);
        System.assertEquals(null, after.PersonMailingStreet);
        System.assertEquals(null, after.New_Phone__c);
        System.assertEquals(null, after.New_Street__c);
        System.assertEquals(null, after.Portal_Token__c);
        System.assertEquals('Rejected', after.Portal_Status__c);
        System.assertEquals(reviewer().Id, after.Portal_Reviewed_By__c);
    }

    // Regression: rows held before submit-time normalization existed carry a 2-letter state ("IL") and a country alias
    // ("USA"), which the restricted State/Country picklists reject. Accept must repair them rather than fail.
    @isTest
    static void acceptRepairsLegacyStateCodeAndCountryAlias() {
        Account acc = makeSubmittedAccount('AcceptLegacy');
        update new Account(
            Id = acc.Id,
            New_Street__c = '700 Lake Dr', New_City__c = 'Chicago', New_State__c = 'IL',
            New_Postal_Code__c = '60601', New_Country__c = 'USA'
        );

        Test.startTest();
        System.runAs(reviewer()) {
            DonorUpdateReviewController.accept(acc.Id);
        }
        Test.stopTest();

        Account after = [
            SELECT PersonMailingState, PersonMailingStateCode, PersonMailingCountry, PersonMailingCountryCode, Portal_Status__c
            FROM Account WHERE Id = :acc.Id
        ];
        System.assertEquals('Illinois', after.PersonMailingState);
        System.assertEquals('IL', after.PersonMailingStateCode);
        System.assertEquals('United States', after.PersonMailingCountry);
        System.assertEquals('Accepted', after.Portal_Status__c);
    }

    // An address the org cannot store fails with a readable message, and leaves the submission waiting for review.
    @isTest
    static void acceptWithUnstorableAddressGivesReadableErrorAndChangesNothing() {
        Account acc = makeSubmittedAccount('AcceptBadCountry');
        update new Account(Id = acc.Id, New_Street__c = '1 Main St', New_City__c = 'Nowhere', New_Country__c = 'Narnia');

        Test.startTest();
        System.runAs(reviewer()) {
            try {
                DonorUpdateReviewController.accept(acc.Id);
                System.assert(false, 'Expected the address to be refused');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('cannot be saved'), e.getMessage());
            }
        }
        Test.stopTest();

        Account after = [SELECT Portal_Status__c, New_Street__c, PersonMailingStreet FROM Account WHERE Id = :acc.Id];
        System.assertEquals('Submitted', after.Portal_Status__c);
        System.assertEquals('1 Main St', after.New_Street__c);
        System.assertEquals(null, after.PersonMailingStreet);
    }

    @isTest
    static void secondReviewOfTheSameSubmissionGivesFriendlyMessage() {
        Account acc = makeSubmittedAccount('ReviewTwice');
        update new Account(Id = acc.Id, New_Phone__c = '5559990010');

        Test.startTest();
        System.runAs(reviewer()) {
            DonorUpdateReviewController.accept(acc.Id);
            try {
                DonorUpdateReviewController.accept(acc.Id);
                System.assert(false, 'Expected an already-reviewed message');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('already been reviewed'), e.getMessage());
            }
            try {
                DonorUpdateReviewController.reject(acc.Id, 'late');
                System.assert(false, 'Expected an already-reviewed message');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('already been reviewed'), e.getMessage());
            }
        }
        Test.stopTest();
    }

    // A donor whose preferred email is Work must keep their Work email and must NOT get it copied into the
    // Personal field (the earlier version always wrote PersonEmail into Personal_Email__c).
    @isTest
    static void acceptDoesNotCrossFillPersonalEmailForWorkPreferredDonor() {
        Account acc = makeSubmittedAccount('WorkPreferred');
        update new Account(Id = acc.Id, Preferred_Email__c = 'Work', Work_Email__c = 'work.preferred@example.com');
        update new Account(Id = acc.Id, New_Phone__c = '5559990011');

        Test.startTest();
        System.runAs(reviewer()) {
            DonorUpdateReviewController.accept(acc.Id);
        }
        Test.stopTest();

        Account after = [SELECT PersonEmail, Personal_Email__c, Work_Email__c, PersonMobilePhone FROM Account WHERE Id = :acc.Id];
        System.assertEquals('work.preferred@example.com', after.PersonEmail);
        System.assertEquals('work.preferred@example.com', after.Work_Email__c);
        System.assertEquals(null, after.Personal_Email__c, 'Work email must not be copied into the personal field');
        System.assertEquals('5559990011', after.PersonMobilePhone);
    }

    // The case the email workaround exists for: preferred = Personal but the personal field is empty, so the
    // post-save flow would blank PersonEmail on any phone change.
    @isTest
    static void acceptKeepsPersonEmailWhenPreferredPersonalFieldIsEmpty() {
        Account acc = makeSubmittedAccount('PersonalEmpty');
        update new Account(Id = acc.Id, Preferred_Email__c = 'Personal');
        update new Account(Id = acc.Id, PersonEmail = 'keep.me@example.com'); // does not trigger the sync flow
        update new Account(Id = acc.Id, New_Phone__c = '5559990012');

        Test.startTest();
        System.runAs(reviewer()) {
            DonorUpdateReviewController.accept(acc.Id);
        }
        Test.stopTest();

        Account after = [SELECT PersonEmail, Personal_Email__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals('keep.me@example.com', after.PersonEmail);
        System.assertEquals('keep.me@example.com', after.Personal_Email__c);
    }

    @isTest
    static void rejectStoresReasonAndPendingListUsesSubmittedDate() {
        Account acc = makeSubmittedAccount('RejectReason');
        Datetime submitted = System.now().addDays(-3);
        update new Account(Id = acc.Id, New_Phone__c = '5559990013', Portal_Submitted_Date__c = submitted);

        List<DonorUpdateReviewController.SubmissionRow> rows;
        Test.startTest();
        System.runAs(reviewer()) {
            rows = DonorUpdateReviewController.getPendingSubmissions();
            DonorUpdateReviewController.reject(acc.Id, '  Number looks wrong  ');
        }
        Test.stopTest();

        for (DonorUpdateReviewController.SubmissionRow row : rows) {
            if (row.accountId == acc.Id) {
                System.assertEquals(submitted, row.submittedDate);
            }
        }
        Account after = [SELECT Portal_Reject_Reason__c, Portal_Status__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals('Number looks wrong', after.Portal_Reject_Reason__c);
        System.assertEquals('Rejected', after.Portal_Status__c);
    }

    @isTest
    static void reviewAcceptsPhoneAndRejectsAddress() {
        Account acc = makeSubmittedAccount('PartialPhone');
        update new Account(
            Id = acc.Id, New_Phone__c = '5559990020',
            New_Street__c = '800 Oak St', New_City__c = 'Springfield'
        );

        Test.startTest();
        System.runAs(reviewer()) {
            DonorUpdateReviewController.review(acc.Id, true, false, 'Street not recognised');
        }
        Test.stopTest();

        Account after = [
            SELECT PersonMobilePhone, PersonMailingStreet, New_Phone__c, New_Street__c, Portal_Token__c,
                   Portal_Status__c, Portal_Reject_Reason__c, Contact_Info_Verified_Date__c
            FROM Account WHERE Id = :acc.Id
        ];
        System.assertEquals('5559990020', after.PersonMobilePhone);
        System.assertEquals(null, after.PersonMailingStreet, 'Rejected address must not be applied');
        System.assertEquals(null, after.New_Phone__c);
        System.assertEquals(null, after.New_Street__c);
        System.assertEquals(null, after.Portal_Token__c);
        System.assertEquals('Accepted', after.Portal_Status__c);
        System.assertEquals('Address rejected: Street not recognised', after.Portal_Reject_Reason__c);
        System.assertEquals(Date.today(), after.Contact_Info_Verified_Date__c);
    }

    @isTest
    static void reviewAcceptsAddressAndRejectsPhone() {
        Account acc = makeSubmittedAccount('PartialAddress');
        update new Account(
            Id = acc.Id, New_Phone__c = '5559990021',
            New_Street__c = '900 Elm St', New_City__c = 'Springfield',
            New_State__c = 'Illinois', New_Postal_Code__c = '62704', New_Country__c = 'United States'
        );

        Test.startTest();
        System.runAs(reviewer()) {
            DonorUpdateReviewController.review(acc.Id, false, true, null);
        }
        Test.stopTest();

        Account after = [
            SELECT PersonMobilePhone, PersonMailingStreet, Portal_Status__c, Portal_Reject_Reason__c
            FROM Account WHERE Id = :acc.Id
        ];
        System.assertEquals(null, after.PersonMobilePhone, 'Rejected phone must not be applied');
        System.assertEquals('900 Elm St', after.PersonMailingStreet);
        System.assertEquals('Accepted', after.Portal_Status__c);
        System.assertEquals('Phone rejected', after.Portal_Reject_Reason__c);
    }

    @isTest
    static void reviewRejectingEverythingSubmittedMarksRejected() {
        Account acc = makeSubmittedAccount('RejectBoth');
        update new Account(Id = acc.Id, New_Phone__c = '5559990022', New_Street__c = '1 Pine St');

        Test.startTest();
        System.runAs(reviewer()) {
            DonorUpdateReviewController.review(acc.Id, false, false, 'Both look wrong');
        }
        Test.stopTest();

        Account after = [
            SELECT PersonMobilePhone, PersonMailingStreet, Portal_Status__c, Portal_Reject_Reason__c,
                   Contact_Info_Verified_Date__c
            FROM Account WHERE Id = :acc.Id
        ];
        System.assertEquals(null, after.PersonMobilePhone);
        System.assertEquals(null, after.PersonMailingStreet);
        System.assertEquals('Rejected', after.Portal_Status__c);
        System.assertEquals('Both look wrong', after.Portal_Reject_Reason__c);
        System.assertEquals(null, after.Contact_Info_Verified_Date__c);
    }

    // A decision for a part the donor never submitted is ignored: rejecting an absent address leaves a phone-only
    // submission fully accepted.
    @isTest
    static void reviewIgnoresDecisionForPartNotSubmitted() {
        Account acc = makeSubmittedAccount('PhoneOnlySubmission');
        update new Account(Id = acc.Id, New_Phone__c = '5559990023');

        Test.startTest();
        System.runAs(reviewer()) {
            DonorUpdateReviewController.review(acc.Id, true, false, null);
        }
        Test.stopTest();

        Account after = [SELECT PersonMobilePhone, Portal_Status__c, Portal_Reject_Reason__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals('5559990023', after.PersonMobilePhone);
        System.assertEquals('Accepted', after.Portal_Status__c);
        System.assertEquals(null, after.Portal_Reject_Reason__c);
    }

    // doc section 10, test 12 (partial): without the custom permission, the review actions are refused
    @isTest
    static void withoutPermissionAccessIsRefused() {
        Test.startTest();
        System.runAs(plain()) {
            try {
                DonorUpdateReviewController.getPendingSubmissions();
                System.assert(false, 'Expected an AuraHandledException for a user without the custom permission');
            } catch (AuraHandledException e) {
                System.assert(true);
            }
        }
        Test.stopTest();
    }
}