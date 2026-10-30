@isTest
private class DonorUpdatePortalControllerTest {

    private static Id personAccountRecordTypeId() {
        return [SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
    }

    private static Account makeAccount(String lastName) {
        return new Account(
            RecordTypeId = personAccountRecordTypeId(),
            FirstName = 'Test',
            LastName = lastName,
            PersonEmail = lastName.toLowerCase() + '@example.com',
            Portal_Token__c = PortalLinkService.newToken(),
            Portal_Token_Expiry__c = System.now().addDays(30)
        );
    }

    // doc section 10, test 1: everything on file
    @isTest
    static void completeDataIsAllReadOnly() {
        Account acc = makeAccount('CompleteData');
        // The org's preferred-contact flow derives PersonEmail from Personal_Email__c, so set that for the email to stick.
        acc.Personal_Email__c = 'completedata@example.com';
        acc.PersonMobilePhone = '5551230001';
        acc.PersonMailingStreet = '100 Main St';
        acc.PersonMailingCity = 'Springfield';
        acc.PersonMailingState = 'Illinois';
        acc.PersonMailingPostalCode = '62704';
        acc.PersonMailingCountry = 'United States';
        insert acc;
        acc = [SELECT Portal_Token__c FROM Account WHERE Id = :acc.Id];

        Test.startTest();
        DonorUpdatePortalController.PortalData data = DonorUpdatePortalController.getPortalData(acc.Portal_Token__c);
        Test.stopTest();

        System.assertEquals('READY', data.portalState);
        System.assertEquals(false, data.phoneEditable);
        System.assertEquals(false, data.addressEditable);
        System.assertEquals('5551230001', data.phone);
        // Everything on file is returned so the page can show it (read-only) back to the donor.
        System.assertEquals('Test', data.firstName);
        System.assertEquals('CompleteData', data.lastName);
        System.assertEquals('completedata@example.com', data.email);
        System.assertEquals('100 Main St', data.street);
        System.assertEquals('Springfield', data.city);
        System.assertEquals('Illinois', data.state);
        System.assertEquals('62704', data.postalCode);
        System.assertEquals('United States', data.country);
    }

    // doc section 10, test 2: phone missing, address complete -> only phone editable
    @isTest
    static void phoneMissingOnlyPhoneEditable() {
        Account acc = makeAccount('PhoneMissing');
        acc.PersonMailingStreet = '200 Oak Ave';
        acc.PersonMailingCity = 'Springfield';
        acc.PersonMailingState = 'Illinois';
        acc.PersonMailingPostalCode = '62704';
        acc.PersonMailingCountry = 'United States';
        insert acc;
        acc = [SELECT Portal_Token__c FROM Account WHERE Id = :acc.Id];

        DonorUpdatePortalController.PortalData data = DonorUpdatePortalController.getPortalData(acc.Portal_Token__c);
        System.assertEquals(true, data.phoneEditable);
        System.assertEquals(false, data.addressEditable);

        DonorUpdatePortalController.PortalSubmitResult result = DonorUpdatePortalController.submitUpdate(
            acc.Portal_Token__c, '5551230099', null, null, null, null, null
        );
        System.assertEquals(true, result.ok);

        Account after = [SELECT New_Phone__c, Portal_Status__c, New_Street__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals('5551230099', after.New_Phone__c);
        System.assertEquals('Submitted', after.Portal_Status__c);
        System.assertEquals(null, after.New_Street__c);
    }

    // doc section 10, test 3: address partly filled -> whole block editable, pre-filled with parts we have
    @isTest
    static void addressPartiallyFilledIsFullyEditableAndPrefilled() {
        Account acc = makeAccount('AddressPartial');
        acc.PersonMobilePhone = '5551230003';
        acc.PersonMailingStreet = '300 Elm St';
        acc.PersonMailingCity = 'Springfield';
        insert acc;
        acc = [SELECT Portal_Token__c FROM Account WHERE Id = :acc.Id];

        DonorUpdatePortalController.PortalData data = DonorUpdatePortalController.getPortalData(acc.Portal_Token__c);
        System.assertEquals(true, data.addressEditable);
        System.assertEquals('300 Elm St', data.street);
        System.assertEquals('Springfield', data.city);

        DonorUpdatePortalController.PortalSubmitResult result = DonorUpdatePortalController.submitUpdate(
            acc.Portal_Token__c, null, '300 Elm St', 'Springfield', 'Illinois', '62704', 'United States'
        );
        System.assertEquals(true, result.ok);

        Account after = [SELECT New_Street__c, New_State__c, New_Postal_Code__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals('Illinois', after.New_State__c);
        System.assertEquals('62704', after.New_Postal_Code__c);
    }

    // doc section 10, test 4: bad ZIP, short phone, half-filled address -> field-level errors, nothing written
    @isTest
    static void invalidSubmissionReturnsFieldErrorsAndWritesNothing() {
        Account acc = makeAccount('BadInput');
        insert acc;
        acc = [SELECT Portal_Token__c FROM Account WHERE Id = :acc.Id];

        DonorUpdatePortalController.PortalSubmitResult result = DonorUpdatePortalController.submitUpdate(
            acc.Portal_Token__c, '123', '300 Elm St', 'Springfield', null, 'bad-zip', 'United States'
        );

        System.assertEquals(false, result.ok);
        System.assert(result.errors.size() >= 2);

        Account after = [SELECT Portal_Status__c, New_Phone__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(null, after.Portal_Status__c);
        System.assertEquals(null, after.New_Phone__c);
    }

    // doc section 10, test 5: expired link
    @isTest
    static void expiredLinkReturnsExpiredState() {
        Account acc = makeAccount('ExpiredLink');
        acc.Portal_Token_Expiry__c = System.now().addDays(-1);
        insert acc;
        acc = [SELECT Portal_Token__c FROM Account WHERE Id = :acc.Id];

        DonorUpdatePortalController.PortalData data = DonorUpdatePortalController.getPortalData(acc.Portal_Token__c);
        System.assertEquals('EXPIRED', data.portalState);
        System.assertEquals(null, data.email);
    }

    // doc section 10, test 6: used link (status Submitted)
    @isTest
    static void usedLinkReturnsUsedState() {
        Account acc = makeAccount('UsedLink');
        acc.Portal_Status__c = 'Submitted';
        insert acc;
        acc = [SELECT Portal_Token__c FROM Account WHERE Id = :acc.Id];

        DonorUpdatePortalController.PortalData data = DonorUpdatePortalController.getPortalData(acc.Portal_Token__c);
        System.assertEquals('USED', data.portalState);
    }

    // doc section 10, test 7: edited or random token -> invalid, same wording as other bad tokens
    @isTest
    static void randomTokenReturnsInvalidState() {
        DonorUpdatePortalController.PortalData data = DonorUpdatePortalController.getPortalData('not-a-real-token');
        System.assertEquals('INVALID', data.portalState);
        System.assertEquals(System.Label.Portal_Invalid_Link_Message, data.reasonText);

        DonorUpdatePortalController.PortalData missing = DonorUpdatePortalController.getPortalData(null);
        System.assertEquals('INVALID', missing.portalState);
        System.assertEquals(data.reasonText, missing.reasonText);
    }

    // doc section 10, test 8: submit twice quickly -> only one submission stored
    @isTest
    static void secondSubmitOnSameTokenIsRejected() {
        Account acc = makeAccount('DoubleSubmit');
        insert acc;
        acc = [SELECT Portal_Token__c FROM Account WHERE Id = :acc.Id];

        DonorUpdatePortalController.PortalSubmitResult first = DonorUpdatePortalController.submitUpdate(
            acc.Portal_Token__c, '5551230088', null, null, null, null, null
        );
        System.assertEquals(true, first.ok);

        DonorUpdatePortalController.PortalSubmitResult second = DonorUpdatePortalController.submitUpdate(
            acc.Portal_Token__c, '5551230088', null, null, null, null, null
        );
        System.assertEquals(false, second.ok);

        Account after = [SELECT New_Phone__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals('5551230088', after.New_Phone__c);
    }

    // Regression: a donor missing BOTH phone and address who only gives a phone. The real form always sends a
    // country (defaulting to "United States") with the other address parts blank; that must not count as an
    // address the donor started.
    @isTest
    static void phoneOnlyWhenBothSectionsEditableIgnoresDefaultCountry() {
        Account acc = makeAccount('BothMissingPhoneOnly');
        insert acc;
        acc = [SELECT Portal_Token__c FROM Account WHERE Id = :acc.Id];

        DonorUpdatePortalController.PortalData data = DonorUpdatePortalController.getPortalData(acc.Portal_Token__c);
        System.assertEquals(true, data.phoneEditable);
        System.assertEquals(true, data.addressEditable);

        DonorUpdatePortalController.PortalSubmitResult result = DonorUpdatePortalController.submitUpdate(
            acc.Portal_Token__c, '5551230077', '', '', '', '', 'United States'
        );
        System.assertEquals(true, result.ok, 'Phone alone must be enough: ' + JSON.serialize(result.errors));

        Account after = [
            SELECT New_Phone__c, New_Street__c, New_Country__c, Portal_Status__c, Portal_Submitted_Date__c FROM Account WHERE Id = :acc.Id
        ];
        System.assertEquals('5551230077', after.New_Phone__c);
        System.assertEquals(null, after.New_Street__c);
        System.assertEquals(null, after.New_Country__c, 'No address was started, so none is held');
        System.assertEquals('Submitted', after.Portal_Status__c);
        System.assertNotEquals(null, after.Portal_Submitted_Date__c);
    }

    // Regression: the form used to send 2-letter state codes, which the restricted State picklist rejects at Accept.
    @isTest
    static void stateCodeAndCountryAliasAreStoredAsPicklistValues() {
        Account acc = makeAccount('StateCode');
        insert acc;
        acc = [SELECT Portal_Token__c FROM Account WHERE Id = :acc.Id];

        DonorUpdatePortalController.PortalSubmitResult result = DonorUpdatePortalController.submitUpdate(
            acc.Portal_Token__c, null, ' 12 Lake Dr ', 'Chicago', 'IL', '60601', 'USA'
        );
        System.assertEquals(true, result.ok, JSON.serialize(result.errors));

        Account after = [SELECT New_Street__c, New_State__c, New_Country__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals('12 Lake Dr', after.New_Street__c);
        System.assertEquals('Illinois', after.New_State__c);
        System.assertEquals('United States', after.New_Country__c);
    }

    @isTest
    static void unrecognisedCountryOrStateIsReportedPerField() {
        Account acc = makeAccount('BadPicklists');
        insert acc;
        acc = [SELECT Portal_Token__c FROM Account WHERE Id = :acc.Id];

        DonorUpdatePortalController.PortalSubmitResult badCountry = DonorUpdatePortalController.submitUpdate(
            acc.Portal_Token__c, null, '1 Main St', 'Nowhere', null, null, 'Narnia'
        );
        System.assertEquals(false, badCountry.ok);
        System.assertEquals('country', badCountry.errors[0].field);
        System.assertEquals(1, badCountry.errors.size(), 'An unknown country should not also demand a US state/ZIP');

        DonorUpdatePortalController.PortalSubmitResult badState = DonorUpdatePortalController.submitUpdate(
            acc.Portal_Token__c, null, '1 Main St', 'Springfield', 'Narnia', '62704', 'United States'
        );
        System.assertEquals(false, badState.ok);
        System.assertEquals('state', badState.errors[0].field);

        Account after = [SELECT Portal_Status__c, New_Street__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(null, after.Portal_Status__c, 'Nothing is stored when validation fails');
        System.assertEquals(null, after.New_Street__c);
    }

    @isTest
    static void addressOptionsAreAvailableWithoutAToken() {
        List<PortalAddressNormalizer.CountryOption> options = DonorUpdatePortalController.getAddressOptions();
        System.assert(options.size() > 200);
    }

    @isTest
    static void phoneWithCountryCodeIsStoredAndWrongLengthIsRejected() {
        Account acc = makeAccount('CountryCodePhone');
        insert acc;
        acc = [SELECT Portal_Token__c FROM Account WHERE Id = :acc.Id];

        DonorUpdatePortalController.PortalSubmitResult tooShort = DonorUpdatePortalController.submitUpdate(
            acc.Portal_Token__c, '+1 555123000', null, null, null, null, null
        );
        System.assertEquals(false, tooShort.ok);
        System.assertEquals('phone', tooShort.errors[0].field);

        DonorUpdatePortalController.PortalSubmitResult sudan = DonorUpdatePortalController.submitUpdate(
            acc.Portal_Token__c, '+249 912345678', null, null, null, null, null
        );
        System.assertEquals(true, sudan.ok, JSON.serialize(sudan.errors));
        System.assertEquals('+249 912345678', [SELECT New_Phone__c FROM Account WHERE Id = :acc.Id].New_Phone__c);
    }

    @isTest
    static void overlongAndNonPhoneTextIsRejected() {
        Account acc = makeAccount('BadText');
        insert acc;
        acc = [SELECT Portal_Token__c FROM Account WHERE Id = :acc.Id];

        DonorUpdatePortalController.PortalSubmitResult result = DonorUpdatePortalController.submitUpdate(
            acc.Portal_Token__c, 'call me any time after 5', '1 Main St'.rightPad(300, 'x'), 'Springfield', 'Illinois', '62704', 'United States'
        );
        System.assertEquals(false, result.ok);
        Set<String> fields = new Set<String>();
        for (PortalValidator.ValidationError e : result.errors) {
            fields.add(e.field);
        }
        System.assert(fields.contains('phone'));
        System.assert(fields.contains('street'));
    }
}