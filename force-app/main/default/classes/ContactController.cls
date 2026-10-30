public with sharing class ContactController {


    @AuraEnabled
    public static void updateContact(Account newContact) {
        system.debug('Contat '  + newContact);
        update newContact;
    }
}