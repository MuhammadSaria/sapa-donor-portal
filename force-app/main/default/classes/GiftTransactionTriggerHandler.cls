public class GiftTransactionTriggerHandler {
    
    private static Boolean isRunning = false;
    
    public static void sync(Set<Id> giftTransactionIds) {
        if (isRunning) return;
        isRunning = true;
        
        try {
            if (giftTransactionIds == null || giftTransactionIds.isEmpty()) return;
            
            // Only process when Donation Id is present
            Map<Id, GiftTransaction> gtById = new Map<Id, GiftTransaction>([
                SELECT Id,
                       FUp_Donation_ID__c,
                       FUp_Campaign_Name__c,
                       FUp_Intention_Designation__c,
                       FUp_Donation_Amount__c,
                       Receipt_Allocations__c,
                       GiftCommitmentId,
                       Channel__c,
                       FUp_Payment_Processor__c,
                       Team__c,
                       Anonymous__c,
                       CurrencyIsoCode,
                       Fundraiser__c,
                       Notification_Recipient_Email__c,
                       CampaignId,
                       OutreachSourceCodeId,
                       No_Postal_Receipt__c,
                	   FUp_Tributee_s_name__c,
                	FUp_Currency_ISO_Code__c,
                	FUp_Campaign_Code__c,
                
                Donor.BillingStreet,
                Donor.BillingCity,
                Donor.BillingState,
                Donor.BillingPostalCode,
                Donor.BillingCountryCode,
                Donor.BillingStateCode
                
                FROM GiftTransaction
                WHERE Id IN :giftTransactionIds
                  AND FUp_Donation_ID__c != null
            ]);
            if (gtById.isEmpty()) return;
            
            // 1) Sync OutreachSourceCode
            syncOutreachSourceCodes(gtById);
            
            // 2) Update GiftTransactionDesignation children
            List<GiftTransactionDesignation> gtds = [
                SELECT Id, GiftTransactionId, GiftDesignationId, Intention__c, Tribute_or_Plaque__c, GiftTransaction.Donor.BillingStateCode
                FROM GiftTransactionDesignation
                WHERE GiftTransactionId IN :gtById.keySet()
            ];
            
            List<GiftTransactionDesignation> gtdToUpdate = new List<GiftTransactionDesignation>();
            for (GiftTransactionDesignation gtd : gtds) {
                GiftTransaction gt = gtById.get(gtd.GiftTransactionId);
                if (gt == null) continue;
                
                Boolean changed = false;
                String normalizedIntention = normalizeIntention(gt.FUp_Intention_Designation__c);
                
                if (gtd.Intention__c != normalizedIntention) {
                    gtd.Intention__c = normalizedIntention;
                    changed = true;
                }
                
                system.debug('Intention:'+gtd.Intention__c );
                
               
            
                        
                if (String.isNotBlank(gt.FUp_Tributee_s_name__c) &&
                    gtd.Tribute_or_Plaque__c != gt.FUp_Tributee_s_name__c) {
                        
                        gtd.Tribute_or_Plaque__c = gt.FUp_Tributee_s_name__c;
                        changed = true;
                    }
                
                   
                   
                
                
                if (changed) gtdToUpdate.add(gtd);
            }
            
            if (!gtdToUpdate.isEmpty()) {
                system.debug('Update gtd::: ');
                update gtdToUpdate;
            }
            
            // Re-query GTDs so recurring/default designation uses the latest values
            gtds = [
                SELECT Id,
                       GiftTransactionId,
                       GiftDesignationId,
                       GiftDesignation.Name,
                       Intention__c,
                       Amount,
                       Locations__c,
                	Tribute_or_Plaque__c
                FROM GiftTransactionDesignation
                WHERE GiftTransactionId IN :gtById.keySet()
            ];
            
            // Map GT Id -> GiftDesignation Name (use first available)
            Map<Id, String> gtToDesignationName = new Map<Id, String>();
            
            for (GiftTransactionDesignation gtd : gtds) {
                if (gtd.GiftTransactionId != null
                    && gtd.GiftDesignationId != null
                    && !gtToDesignationName.containsKey(gtd.GiftTransactionId)) {
                    gtToDesignationName.put(
                        gtd.GiftTransactionId,
                        gtd.GiftDesignation.Name
                    );
                }
            }
            
            // 3) Receipt_Allocations__c on GiftTransaction + GiftCommitment
            List<GiftTransaction> gtUpdates = new List<GiftTransaction>();
            Set<Id> commitmentIds = new Set<Id>();
            Map<Id, String> commitmentToReceipt = new Map<Id, String>();
            Id fundraiserUserId = getFundraiserUserId();

            
            for (GiftTransaction gt : gtById.values()) {
                String designationName = gtToDesignationName.get(gt.Id);
                String receipt = buildReceipt(
                    designationName,
                    gt.FUp_Intention_Designation__c,
                    gt.FUp_Donation_Amount__c,
                    gt.CurrencyIsoCode
                );
                
                Boolean changed = false;
                GiftTransaction gtUpdate = new GiftTransaction(Id = gt.Id);
                
                if (gt.Receipt_Allocations__c != receipt) {
                    gtUpdate.Receipt_Allocations__c = receipt;
                    changed = true;
                }
                
                if(gt.FUp_Currency_ISO_Code__c !=NULL)
                {
                        gtUpdate.Address__Street__s = gt.Donor.BillingStreet;
                        gtUpdate.Address__City__s = gt.Donor.BillingCity;
                    
                        gtUpdate.Address__StateCode__s = gt.Donor.BillingStateCode;
                        gtUpdate.Address__PostalCode__s = gt.Donor.BillingPostalCode;
                        gtUpdate.Address__CountryCode__s = gt.Donor.BillingCountryCode;
                    	changed = true;
                    system.debug('Billing Country?? '+gt.Donor.BillingCountryCode);
                }
                

                
                if (gt.No_Postal_Receipt__c != true) {
                    gtUpdate.No_Postal_Receipt__c = true;
                    changed = true;
                }
                
                if (fundraiserUserId != null && gt.Fundraiser__c != fundraiserUserId) {
                    gtUpdate.Fundraiser__c = fundraiserUserId;
                    changed = true;
                }
                
                if (changed) {
                    gtUpdates.add(gtUpdate);
                }
                
                if (gt.GiftCommitmentId != null) {
                    commitmentIds.add(gt.GiftCommitmentId);
                    commitmentToReceipt.put(gt.GiftCommitmentId, receipt); // last wins
                }
                
                
            }
            
            if (!gtUpdates.isEmpty()) update gtUpdates;
            
            if (!commitmentIds.isEmpty()) {
                
                // Map GiftCommitmentId -> GiftTransaction (last wins if multiple)
                Map<Id, GiftTransaction> commitmentToGT = new Map<Id, GiftTransaction>();
                for (GiftTransaction gt : gtById.values()) {
                    if (gt.GiftCommitmentId != null) {
                        commitmentToGT.put(gt.GiftCommitmentId, gt);
                    }
                }
                
                List<GiftCommitment> gcUpdates = new List<GiftCommitment>();
                
                for (GiftCommitment gc : [
                    SELECT Id,
                           Receipt_Allocations__c,
                           No_Postal_Receipt__c,
                           Channel__c,
                           Payment_Processor__c,
                           Team__c,
                           Anonymous__c,
                           Notification_Recepient_Email__c,
                           Fundraiser__c
                    FROM GiftCommitment
                    WHERE Id IN :commitmentIds
                ]) {
                    GiftTransaction src = commitmentToGT.get(gc.Id);
                    if (src == null) continue;
                    
                    Boolean changed = false;
                    
                    // Existing receipt sync
                    String desired = commitmentToReceipt.get(gc.Id);
                    if (desired != null && gc.Receipt_Allocations__c != desired) {
                        gc.Receipt_Allocations__c = desired;
                        changed = true;
                    }
                    if (gc.No_Postal_Receipt__c != true) {
                        gc.No_Postal_Receipt__c = true;
                        changed = true;
                    }
                    
                    // field mappings from GiftTransaction -> GiftCommitment
                    if (gc.Channel__c != src.Channel__c) {
                        gc.Channel__c = src.Channel__c;
                        changed = true;
                    }
                    if (gc.Payment_Processor__c != src.FUp_Payment_Processor__c) {
                        gc.Payment_Processor__c = src.FUp_Payment_Processor__c;
                        changed = true;
                    }
                    if (gc.Team__c != src.Team__c) {
                        gc.Team__c = src.Team__c;
                        changed = true;
                    }
                    if (gc.Anonymous__c != src.Anonymous__c) {
                        gc.Anonymous__c = src.Anonymous__c;
                        changed = true;
                    }
                    if (gc.Notification_Recepient_Email__c != src.Notification_Recipient_Email__c) {
                        gc.Notification_Recepient_Email__c = src.Notification_Recipient_Email__c;
                        changed = true;
                    }
                    if (fundraiserUserId != null && gc.Fundraiser__c != fundraiserUserId) {
                        gc.Fundraiser__c = fundraiserUserId;
                        changed = true;
                    }
                    
                    if (changed) gcUpdates.add(gc);
                }
                
                if (!gcUpdates.isEmpty()) update gcUpdates;
            }
            
            // 4) Recurring donation: create/update GiftDefaultDesignation
            // ParentRecordId = GiftCommitmentId, copy from GiftTransactionDesignation
            if (!commitmentIds.isEmpty()) {
                Map<String, GiftDefaultDesignation> desiredByKey = new Map<String, GiftDefaultDesignation>();
                
                for (GiftTransactionDesignation gtd : gtds) {
                    GiftTransaction gt = gtById.get(gtd.GiftTransactionId);
                    if (gt == null || gt.GiftCommitmentId == null) continue;
                    
                    // Skip if nothing to set
                    if (gtd.GiftDesignationId == null && String.isBlank(gtd.Intention__c)) continue;
                    
                    String key = String.valueOf(gt.GiftCommitmentId) + '|' + String.valueOf(gtd.GiftDesignationId);
                    
                    GiftDefaultDesignation gdd = new GiftDefaultDesignation();
                    gdd.ParentRecordId = gt.GiftCommitmentId;
                    gdd.GiftDesignationId = gtd.GiftDesignationId;
                    
                    system.debug('gdd intention'+gtd.Intention__c);
                    
                    
                  
                    
                        gdd.Intention__c = normalizeIntention(gtd.Intention__c);
                    
                    
                    gdd.Tribute_or_Plaque__c = gtd.Tribute_or_Plaque__c;
                    gdd.Amount__c = gtd.Amount;
                    gdd.Locations__c = gtd.Locations__c;
                    gdd.AllocatedPercentage = 100;
                     
                    desiredByKey.put(key, gdd); // last wins
                }
                
                if (!desiredByKey.isEmpty()) {
                    Map<String, GiftDefaultDesignation> existingByKey = new Map<String, GiftDefaultDesignation>();
                    for (GiftDefaultDesignation existing : [
                        SELECT Id,
                               ParentRecordId,
                               GiftDesignationId,
                               Intention__c,
                               Amount__c,
                               Locations__c,
                               AllocatedPercentage
                        FROM GiftDefaultDesignation
                        WHERE ParentRecordId IN :commitmentIds
                    ]) {
                        String key = String.valueOf(existing.ParentRecordId) + '|' + String.valueOf(existing.GiftDesignationId);
                        existingByKey.put(key, existing);
                    }
                    
                    List<GiftDefaultDesignation> gddToInsert = new List<GiftDefaultDesignation>();
                    List<GiftDefaultDesignation> gddToUpdate = new List<GiftDefaultDesignation>();
                    
                    for (String key : desiredByKey.keySet()) {
                        GiftDefaultDesignation desired = desiredByKey.get(key);
                        GiftDefaultDesignation existing = existingByKey.get(key);
                        
                        if (existing == null) {
                            gddToInsert.add(desired);
                        } else {
                            Boolean upd = false;
                            
                            if (existing.Intention__c != desired.Intention__c) {
                                existing.Intention__c = desired.Intention__c;
                                upd = true;
                            }
                            if (existing.Amount__c != desired.Amount__c) {
                                existing.Amount__c = desired.Amount__c;
                                upd = true;
                            }
                            if (existing.Locations__c != desired.Locations__c) {
                                existing.Locations__c = desired.Locations__c;
                                upd = true;
                            }
                            if (existing.AllocatedPercentage != desired.AllocatedPercentage) {
                                existing.AllocatedPercentage = desired.AllocatedPercentage;
                                upd = true;
                            }
                            
                            if (upd) gddToUpdate.add(existing);
                        }
                    }
                    
                    if (!gddToInsert.isEmpty()) insert gddToInsert;
                    if (!gddToUpdate.isEmpty()) update gddToUpdate;
                }
            }
            
        } finally {
            isRunning = false;
        }
    }
    
    private static void syncOutreachSourceCodes(Map<Id, GiftTransaction> gtById) {
        Set<String> sourceNames = new Set<String>();
        Set<Id> campaignIds = new Set<Id>();
        
        for (GiftTransaction gt : gtById.values()) {
            if (String.isNotBlank(gt.FUp_Campaign_Name__c) && gt.CampaignId != null) {
                sourceNames.add(gt.FUp_Campaign_Name__c.trim());
                campaignIds.add(gt.CampaignId);
            }
        }
        
        if (sourceNames.isEmpty() || campaignIds.isEmpty()) {
            return;
        }
        
        // Find existing OutreachSourceCode by BOTH Name and CampaignId
        Map<String, OutreachSourceCode> oscByKey = new Map<String, OutreachSourceCode>();
        
        for (OutreachSourceCode osc : [
            SELECT Id, Name, CampaignId, SourceCode
            FROM OutreachSourceCode
            WHERE Name IN :sourceNames
              AND CampaignId IN :campaignIds
        ]) {
            String key = buildOscKey(osc.Name, osc.CampaignId);
            oscByKey.put(key, osc);
        }
        
        // Create missing OutreachSourceCode records
        List<OutreachSourceCode> oscToInsert = new List<OutreachSourceCode>();
        Set<String> pendingInsertKeys = new Set<String>();
        
        for (GiftTransaction gt : gtById.values()) {
            if (String.isBlank(gt.FUp_Campaign_Name__c) || gt.CampaignId == null) {
                continue;
            }
            
            String key = buildOscKey(gt.FUp_Campaign_Name__c, gt.CampaignId);
            
            if (!oscByKey.containsKey(key) && !pendingInsertKeys.contains(key)) {
                OutreachSourceCode osc = new OutreachSourceCode();
                osc.Name = gt.FUp_Campaign_Name__c.trim();
                osc.SourceCode = generateUniqueSourceCode();
                osc.CampaignId = gt.CampaignId;
                osc.FUp_Campaign_Code__c = gt.FUp_Campaign_Code__c;
                system.debug('gt.FUp_Campaign_Code__c>> '+gt.FUp_Campaign_Code__c);
                
                oscToInsert.add(osc);
                pendingInsertKeys.add(key);
            }
        }
        
        if (!oscToInsert.isEmpty()) {
            insert oscToInsert;
            
            for (OutreachSourceCode osc : oscToInsert) {
                String key = buildOscKey(osc.Name, osc.CampaignId);
                oscByKey.put(key, osc);
            }
        }
        
        // Map GiftTransaction.OutreachSourceCodeId
        List<GiftTransaction> gtToUpdate = new List<GiftTransaction>();
        
        for (GiftTransaction gt : gtById.values()) {
            if (String.isBlank(gt.FUp_Campaign_Name__c) || gt.CampaignId == null) {
                continue;
            }
            
            String key = buildOscKey(gt.FUp_Campaign_Name__c, gt.CampaignId);
            OutreachSourceCode osc = oscByKey.get(key);
            
            if (osc != null && gt.OutreachSourceCodeId != osc.Id) {
                gtToUpdate.add(new GiftTransaction(
                    Id = gt.Id,
                    OutreachSourceCodeId = osc.Id
                ));
            }
        }
        
        if (!gtToUpdate.isEmpty()) {
            update gtToUpdate;
        }
    }
    
    private static String buildOscKey(String name, Id campaignId) {
        return name.trim().toLowerCase() + '|' + String.valueOf(campaignId);
    }
    
    private static String generateUniqueSourceCode() {
        Long timePart = DateTime.now().getTime();
        Integer randomPart = Math.abs(Crypto.getRandomInteger());
        String randomText = String.valueOf(randomPart);
        
        if (randomText.length() > 6) {
            randomText = randomText.substring(0, 6);
        }
        
        return String.valueOf(timePart) + randomText;
    }
    
   private static String buildReceipt(String designationName, String intention, Decimal amount, String currencyIsoCode) {
    List<String> parts = new List<String>();

    // 1. Always add "Where Most Needed"
    parts.add('Where Most Needed');

    // 2. Handle designationName transformation
    if (String.isNotBlank(designationName)) {
        
            parts.add(designationName.trim());
        }
    
     system.debug('designationName++'+designationName);
       system.debug('intention++'+intention);
    // 3. Add intention
       if (intention == 'Where most needed') {
           parts.add('General Donation');
       } else if (String.isNotBlank(intention)) {
           parts.add(intention.trim());
       }

    // 4. Add currency + amount
    if (amount != null) {
        String formattedAmount;

        if (String.isNotBlank(currencyIsoCode)) {
            formattedAmount = currencyIsoCode + ' ' + amount.setScale(2).format();
        } else {
            formattedAmount = amount.setScale(2).format();
        }

        parts.add(formattedAmount);
    }

    return String.join(parts, ' - ');
}
    
    private static String normalizeIntention(String intention) {
    if (String.isBlank(intention)) {
        return null;
    }

    String cleanValue = intention.trim();

    if (cleanValue.toLowerCase() == 'where most needed') {
        return 'General Donation';
    }

    return cleanValue;
}

    private static Id getFundraiserUserId() {
        // wajahat@sapadev.providus.io
        // salesforce@sapa-usa.org
        List<User> users = [
            SELECT Id 
            FROM User 
            WHERE Username = 'salesforce@sapa-usa.org'
            LIMIT 1
        ];
        
        if (!users.isEmpty()) {
            return users[0].Id;
        }
        
        return null; // or throw exception if required
    }


}