({
    go : function(cmp, evt, helper) {
        var recordId = cmp.get("v.recordId");

        // If v.recordId is null, try to get it from URL
        if (!recordId) {
            var url = window.location.href;
            // Lightning URL format: /lightning/r/GiftCommitment/006KE000002k05vYAA/view
            var matches = url.match(/\/lightning\/r\/GiftCommitment\/([a-zA-Z0-9]{15,18})\/view/);
            if (matches && matches[1]) {
                recordId = matches[1];
            }
        }

        if (!recordId) {
            alert('Unable to detect GiftCommitment Id. Make sure you are on an GiftCommitment record page.');
            return;
        }

        // Build VF page URL with Id
        var vfUrl = '/apex/Recurring_Receipt_PDF?id=' + recordId;

        // Open VF page in new tab
        window.open(vfUrl, '_blank');
    }
})