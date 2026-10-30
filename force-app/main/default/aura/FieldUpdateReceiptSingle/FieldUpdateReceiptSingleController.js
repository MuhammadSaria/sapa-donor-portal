({
    markSent : function(cmp, evt, helper) {
        var action = cmp.get("c.markReceiptsAsSent");

        action.setCallback(this, function(response) {
            var state = response.getState();
            if (state === "SUCCESS") {
                cmp.set("v.message", "All receipts have been marked as Sent.");
            } else if (state === "ERROR") {
                var errors = response.getError();
                console.error(errors);
                cmp.set("v.message", "Something went wrong while updating receipts.");
            }
        });

        $A.enqueueAction(action);
    }
})