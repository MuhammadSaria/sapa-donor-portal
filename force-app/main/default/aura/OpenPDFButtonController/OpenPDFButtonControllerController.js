({
    go : function(cmp, evt, helper) {
        // Define the URL for your Visualforce page
        var url = "/apex/AllDonationReceiptsPDFSingle";
        
        // Use standard JavaScript to open it in a new tab/window
        window.open(url, '_blank');
    }
})