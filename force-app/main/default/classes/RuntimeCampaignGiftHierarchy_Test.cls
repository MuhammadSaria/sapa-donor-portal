@IsTest
private class RuntimeCampaignGiftHierarchy_Test {

    @IsTest
    static void getHierarchy_nullCampaignId_returnsEmptyList() {
        Test.startTest();

        List<RuntimeCampaignGiftHierarchyController.CampaignNode> nodes =
            RuntimeCampaignGiftHierarchyController.getHierarchy(
                null,
                'Paid',
                null,
                null,
                false
            );

        Test.stopTest();

        System.assertEquals(
            0,
            nodes.size(),
            'Null Campaign Id should return an empty hierarchy.'
        );
    }

    @IsTest
    static void getHierarchy_rollsUpMembersResponsesPaidValueAndAllValue() {
        Campaign parentCampaign = new Campaign(
            Name = 'Runtime Parent Campaign',
            IsActive = true
        );
        insert parentCampaign;

        Campaign childCampaignOne = new Campaign(
            Name = 'Runtime Child Campaign One',
            ParentId = parentCampaign.Id,
            IsActive = true
        );

        Campaign childCampaignTwo = new Campaign(
            Name = 'Runtime Child Campaign Two',
            ParentId = parentCampaign.Id,
            IsActive = true
        );

        insert new List<Campaign>{
            childCampaignOne,
            childCampaignTwo
        };

        ensureRespondedCampaignMemberStatus(childCampaignOne.Id);
        ensureRespondedCampaignMemberStatus(childCampaignTwo.Id);

        
        //Sandbox  RecordTypeId = '012VZ00000H7fKnYAJ'
        Account donorAccountOne = new Account(
            Name = 'Runtime Donor Account One',
            RecordTypeId = businessAccountType()
        );

        //Sandbox  RecordTypeId = '012VZ00000H7fKnYAJ'
        Account donorAccountTwo = new Account(
            Name = 'Runtime Donor Account Two',
            RecordTypeId = businessAccountType()
        );

        insert new List<Account>{
            donorAccountOne,
            donorAccountTwo
        };

        Contact donorContactOne = new Contact(
            LastName = 'Runtime Donor One',
            AccountId = donorAccountOne.Id
        );

        Contact donorContactTwo = new Contact(
            LastName = 'Runtime Donor Two',
            AccountId = donorAccountTwo.Id
        );

        insert new List<Contact>{
            donorContactOne,
            donorContactTwo
        };

        CampaignMember respondedMember = new CampaignMember(
            CampaignId = childCampaignOne.Id,
            ContactId = donorContactOne.Id,
            Status = 'Responded'
        );

        CampaignMember normalMember = new CampaignMember(
            CampaignId = childCampaignTwo.Id,
            ContactId = donorContactTwo.Id
        );

        insert new List<CampaignMember>{
            respondedMember,
            normalMember
        };

        String paidStatus = getPreferredPicklistValue(
            'GiftTransaction',
            'Status',
            new List<String>{ 'Paid' }
        );

        String nonPaidStatus = getDifferentPicklistValue(
            'GiftTransaction',
            'Status',
            paidStatus,
            new List<String>{
                'Pending',
                'Failed',
                'Canceled',
                'Cancelled',
                'Unpaid',
                'Pledged',
                'Processing'
            }
        );

        Date giftDate = Date.today();

        insertGiftTransaction(
            donorAccountOne.Id,
            childCampaignOne.Id,
            paidStatus,
            Decimal.valueOf('100.00'),
            giftDate
        );

        insertGiftTransaction(
            donorAccountOne.Id,
            childCampaignOne.Id,
            nonPaidStatus,
            Decimal.valueOf('40.00'),
            giftDate
        );

        insertGiftTransaction(
            donorAccountTwo.Id,
            childCampaignTwo.Id,
            paidStatus,
            Decimal.valueOf('25.00'),
            giftDate
        );

        String startDateText = String.valueOf(Date.today().addDays(-1));
        String endDateText = String.valueOf(Date.today().addDays(1));

        Test.startTest();

        List<RuntimeCampaignGiftHierarchyController.CampaignNode> nodes =
            RuntimeCampaignGiftHierarchyController.getHierarchy(
                parentCampaign.Id,
                paidStatus,
                startDateText,
                endDateText,
                true
            );

        Test.stopTest();

        System.assertEquals(
            1,
            nodes.size(),
            'The controller should return one root hierarchy node.'
        );

        RuntimeCampaignGiftHierarchyController.CampaignNode rootNode = nodes[0];

        System.assertEquals(
            String.valueOf(parentCampaign.Id),
            rootNode.id,
            'Root node should be the parent campaign.'
        );

        System.assertEquals(
            2,
            rootNode.children.size(),
            'Parent campaign should have two child campaign nodes.'
        );

        System.assertEquals(
            2,
            rootNode.membersInHierarchy,
            'Hierarchy member count should include child campaign members.'
        );

        System.assertEquals(
            1,
            rootNode.responsesInHierarchy,
            'Hierarchy response count should include the Responded campaign member.'
        );

        Integer expectedPaidGiftCount = nonPaidStatus == paidStatus ? 3 : 2;

        System.assertEquals(
            expectedPaidGiftCount,
            rootNode.giftsInHierarchy,
            'Paid/filtered gift count should only include GiftTransactions matching the supplied status.'
        );

        System.assertEquals(
            Decimal.valueOf('165.00'),
            rootNode.allGiftValueInHierarchy,
            'All-status audit value should include paid and non-paid GiftTransactions.'
        );

        System.assert(
            rootNode.allGiftValueInHierarchy >= rootNode.giftValueInHierarchy,
            'All-status hierarchy value should be greater than or equal to the paid/filtered hierarchy value.'
        );

        RuntimeCampaignGiftHierarchyController.CampaignNode childOneNode =
            findNodeById(rootNode, childCampaignOne.Id);

        System.assertNotEquals(
            null,
            childOneNode,
            'Child campaign one should exist in the hierarchy.'
        );

        System.assertEquals(
            1,
            childOneNode.membersInCampaign,
            'Child campaign one should have one direct campaign member.'
        );

        System.assertEquals(
            1,
            childOneNode.responsesInCampaign,
            'Child campaign one should have one direct response.'
        );

        System.assertEquals(
            Decimal.valueOf('140.00'),
            childOneNode.allGiftValueInCampaign,
            'Child campaign one all-status value should include both paid and non-paid gifts.'
        );
    }

    @IsTest
    static void getHierarchy_futureDateFilter_excludesGiftAmountsButKeepsMembers() {
        Campaign parentCampaign = new Campaign(
            Name = 'Runtime Date Parent Campaign',
            IsActive = true
        );
        insert parentCampaign;

        Campaign childCampaign = new Campaign(
            Name = 'Runtime Date Child Campaign',
            ParentId = parentCampaign.Id,
            IsActive = true
        );
        insert childCampaign;

        Account donorAccount = new Account(
            Name = 'Runtime Date Donor Account',
            RecordTypeId = businessAccountType()
        );
        insert donorAccount;

        Contact donorContact = new Contact(
            LastName = 'Runtime Date Donor',
            AccountId = donorAccount.Id
        );
        insert donorContact;

        CampaignMember memberRecord = new CampaignMember(
            CampaignId = childCampaign.Id,
            ContactId = donorContact.Id
        );
        insert memberRecord;

        String paidStatus = getPreferredPicklistValue(
            'GiftTransaction',
            'Status',
            new List<String>{ 'Paid' }
        );

        insertGiftTransaction(
            donorAccount.Id,
            childCampaign.Id,
            paidStatus,
            Decimal.valueOf('75.00'),
            Date.today()
        );

        Test.startTest();

        List<RuntimeCampaignGiftHierarchyController.CampaignNode> nodes =
            RuntimeCampaignGiftHierarchyController.getHierarchy(
                parentCampaign.Id,
                paidStatus,
                String.valueOf(Date.today().addDays(10)),
                null,
                false
            );

        Test.stopTest();

        System.assertEquals(
            1,
            nodes.size(),
            'Hierarchy should still return the parent campaign.'
        );

        RuntimeCampaignGiftHierarchyController.CampaignNode rootNode = nodes[0];

        System.assertEquals(
            1,
            rootNode.membersInHierarchy,
            'Date filter should not affect Campaign Member rollups.'
        );

        System.assertEquals(
            0,
            rootNode.giftsInHierarchy,
            'Future start date should exclude current GiftTransactions from paid/filtered gift count.'
        );

        System.assertEquals(
            Decimal.valueOf('0.00'),
            rootNode.allGiftValueInHierarchy,
            'Future start date should exclude current GiftTransactions from all-status audit value.'
        );
    }

    @IsTest
    static void getHierarchy_blankStatusAndInvalidDates_doNotFail() {
        Campaign campaignRecord = new Campaign(
            Name = 'Runtime Invalid Date Campaign',
            IsActive = true
        );
        insert campaignRecord;

        Test.startTest();

        List<RuntimeCampaignGiftHierarchyController.CampaignNode> nodes =
            RuntimeCampaignGiftHierarchyController.getHierarchy(
                campaignRecord.Id,
                ' , ',
                'not-a-date',
                'also-not-a-date',
                true
            );

        Test.stopTest();

        System.assertEquals(
            1,
            nodes.size(),
            'Blank status CSV and invalid dates should not break the controller.'
        );

        System.assertEquals(
            String.valueOf(campaignRecord.Id),
            nodes[0].id,
            'The returned node should still be the requested campaign.'
        );
    }

    private static Id businessAccountType() {
        return [SELECT Id FROM RecordType WHERE SObjectType='Account' AND IsPersonType=false AND IsActive=true LIMIT 1].Id;
    }

    private static void ensureRespondedCampaignMemberStatus(Id campaignId) {
        List<CampaignMemberStatus> existingStatuses = [
            SELECT Id, Label, HasResponded
            FROM CampaignMemberStatus
            WHERE CampaignId = :campaignId
            AND Label = 'Responded'
            LIMIT 1
        ];

       /* if (existingStatuses.isEmpty()) {
            CampaignMemberStatus respondedStatus = new CampaignMemberStatus(
                CampaignId = campaignId,
                Label = 'Responded',
                HasResponded = true,
                SortOrder = 2
            );

            insert respondedStatus;
        } else if (existingStatuses[0].HasResponded == false) {
            existingStatuses[0].HasResponded = true;
            update existingStatuses[0];
        } */
    }

    private static Id insertGiftTransaction(
        Id donorAccountId,
        Id campaignId,
        String status,
        Decimal amount,
        Date transactionDate
    ) {
        Schema.SObjectType giftTransactionType =
            Schema.getGlobalDescribe().get('GiftTransaction');

        System.assertNotEquals(
            null,
            giftTransactionType,
            'GiftTransaction object was not found. This test is intended for Nonprofit Cloud orgs.'
        );

        SObject giftTransaction = giftTransactionType.newSObject();

        Map<String, Schema.SObjectField> fieldsByName =
            giftTransactionType.getDescribe().fields.getMap();

        putIfCreateable(
            giftTransaction,
            fieldsByName,
            'Name',
            'Runtime Test Gift ' + String.valueOf(Math.abs(Crypto.getRandomInteger()))
        );

        putIfCreateable(
            giftTransaction,
            fieldsByName,
            'DonorId',
            donorAccountId
        );

        putIfCreateable(
            giftTransaction,
            fieldsByName,
            'CampaignId',
            campaignId
        );

        putIfCreateable(
            giftTransaction,
            fieldsByName,
            'Status',
            status
        );

        putIfCreateable(
            giftTransaction,
            fieldsByName,
            'OriginalAmount',
            amount
        );

        putIfCreateable(
            giftTransaction,
            fieldsByName,
            'CurrentAmount',
            amount
        );

        putIfCreateable(
            giftTransaction,
            fieldsByName,
            'TransactionDate',
            transactionDate
        );

        putPicklistIfCreateable(
            giftTransaction,
            fieldsByName,
            'PaymentMethod',
            new List<String>{
                'Cash',
                'Credit Card',
                'Check',
                'Cheque',
                'Other'
            }
        );

        putPicklistIfCreateable(
            giftTransaction,
            fieldsByName,
            'GiftType',
            new List<String>{
                'Individual',
                'Individual Gift',
                'One-Time',
                'Donation'
            }
        );

        putPicklistIfCreateable(
            giftTransaction,
            fieldsByName,
            'TransactionType',
            new List<String>{
                'Donation',
                'Gift',
                'Payment'
            }
        );

        populateRequiredPrimitiveFields(giftTransaction, fieldsByName);

        insert giftTransaction;
        System.assertNotEquals(null,giftTransaction.get('Id'),'Fixture must be created successfully.');

        return (Id) giftTransaction.get('Id');
    }

    private static void putIfCreateable(
        SObject record,
        Map<String, Schema.SObjectField> fieldsByName,
        String fieldApiName,
        Object value
    ) {
        if (value == null || !fieldsByName.containsKey(fieldApiName)) {
            return;
        }

        Schema.DescribeFieldResult fieldDescribe =
            fieldsByName.get(fieldApiName).getDescribe();

        if (fieldDescribe.isCreateable()) {
            record.put(fieldApiName, value);
        }
    }

    private static void putPicklistIfCreateable(
        SObject record,
        Map<String, Schema.SObjectField> fieldsByName,
        String fieldApiName,
        List<String> preferredValues
    ) {
        if (!fieldsByName.containsKey(fieldApiName)) {
            return;
        }

        Schema.DescribeFieldResult fieldDescribe =
            fieldsByName.get(fieldApiName).getDescribe();

        if (!fieldDescribe.isCreateable()) {
            return;
        }

        String selectedValue = getPreferredPicklistValueFromField(
            fieldDescribe,
            preferredValues
        );

        if (!String.isBlank(selectedValue)) {
            record.put(fieldApiName, selectedValue);
        }
    }

    private static void populateRequiredPrimitiveFields(
        SObject record,
        Map<String, Schema.SObjectField> fieldsByName
    ) {
        for (String fieldApiName : fieldsByName.keySet()) {
            if (record.get(fieldApiName) != null) {
                continue;
            }

            Schema.DescribeFieldResult fieldDescribe =
                fieldsByName.get(fieldApiName).getDescribe();

            if (!fieldDescribe.isCreateable()) {
                continue;
            }

            if (fieldDescribe.isNillable()) {
                continue;
            }

            if (fieldDescribe.isDefaultedOnCreate()) {
                continue;
            }

            Schema.DisplayType fieldType = fieldDescribe.getType();

            if (fieldType == Schema.DisplayType.String ||
                fieldType == Schema.DisplayType.TextArea ||
                fieldType == Schema.DisplayType.Phone ||
                fieldType == Schema.DisplayType.Email ||
                fieldType == Schema.DisplayType.Url) {

                record.put(fieldApiName, 'Test');

            } else if (fieldType == Schema.DisplayType.Boolean) {

                record.put(fieldApiName, false);

            } else if (fieldType == Schema.DisplayType.Currency ||
                       fieldType == Schema.DisplayType.Double ||
                       fieldType == Schema.DisplayType.Percent) {

                record.put(fieldApiName, Decimal.valueOf('1.00'));

            } else if (fieldType == Schema.DisplayType.Integer) {

                record.put(fieldApiName, 1);

            } else if (fieldType == Schema.DisplayType.Date) {

                record.put(fieldApiName, Date.today());

            } else if (fieldType == Schema.DisplayType.DateTime) {

                record.put(fieldApiName, System.now());

            } else if (fieldType == Schema.DisplayType.Time) {

                record.put(fieldApiName, Time.newInstance(0, 0, 0, 0));

            } else if (fieldType == Schema.DisplayType.Picklist) {

                String value = getPreferredPicklistValueFromField(
                    fieldDescribe,
                    new List<String>()
                );

                if (!String.isBlank(value)) {
                    record.put(fieldApiName, value);
                }
            }
        }
    }

    private static String getPreferredPicklistValue(
        String objectApiName,
        String fieldApiName,
        List<String> preferredValues
    ) {
        Schema.SObjectType objectType =
            Schema.getGlobalDescribe().get(objectApiName);

        System.assertNotEquals(
            null,
            objectType,
            objectApiName + ' object was not found.'
        );

        Map<String, Schema.SObjectField> fieldsByName =
            objectType.getDescribe().fields.getMap();

        System.assert(
            fieldsByName.containsKey(fieldApiName),
            objectApiName + '.' + fieldApiName + ' field was not found.'
        );

        return getPreferredPicklistValueFromField(
            fieldsByName.get(fieldApiName).getDescribe(),
            preferredValues
        );
    }

    private static String getDifferentPicklistValue(
        String objectApiName,
        String fieldApiName,
        String valueToAvoid,
        List<String> preferredValues
    ) {
        Schema.SObjectType objectType =
            Schema.getGlobalDescribe().get(objectApiName);

        System.assertNotEquals(
            null,
            objectType,
            objectApiName + ' object was not found.'
        );

        Map<String, Schema.SObjectField> fieldsByName =
            objectType.getDescribe().fields.getMap();

        System.assert(
            fieldsByName.containsKey(fieldApiName),
            objectApiName + '.' + fieldApiName + ' field was not found.'
        );

        Schema.DescribeFieldResult fieldDescribe =
            fieldsByName.get(fieldApiName).getDescribe();

        for (String preferredValue : preferredValues) {
            for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
                if (entry.isActive() &&
                    entry.getValue() == preferredValue &&
                    entry.getValue() != valueToAvoid) {

                    return entry.getValue();
                }
            }
        }

        for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
            if (entry.isActive() && entry.getValue() != valueToAvoid) {
                return entry.getValue();
            }
        }

        return valueToAvoid;
    }

    private static String getPreferredPicklistValueFromField(
        Schema.DescribeFieldResult fieldDescribe,
        List<String> preferredValues
    ) {
        List<Schema.PicklistEntry> entries =
            fieldDescribe.getPicklistValues();

        for (String preferredValue : preferredValues) {
            for (Schema.PicklistEntry entry : entries) {
                if (entry.isActive() && entry.getValue() == preferredValue) {
                    return entry.getValue();
                }
            }
        }

        for (Schema.PicklistEntry entry : entries) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }

        return null;
    }

    private static RuntimeCampaignGiftHierarchyController.CampaignNode findNodeById(
        RuntimeCampaignGiftHierarchyController.CampaignNode currentNode,
        Id campaignId
    ) {
        if (currentNode == null) {
            return null;
        }

        if (currentNode.id == String.valueOf(campaignId)) {
            return currentNode;
        }

        if (currentNode.children == null) {
            return null;
        }

        for (RuntimeCampaignGiftHierarchyController.CampaignNode childNode :
            currentNode.children) {

            RuntimeCampaignGiftHierarchyController.CampaignNode foundNode =
                findNodeById(childNode, campaignId);

            if (foundNode != null) {
                return foundNode;
            }
        }

        return null;
    }
}