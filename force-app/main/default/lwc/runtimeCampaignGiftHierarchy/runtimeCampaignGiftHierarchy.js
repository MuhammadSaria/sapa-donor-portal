import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getHierarchy from '@salesforce/apex/RuntimeCampaignGiftHierarchyController.getHierarchy';

const COLUMNS = [
    {
        label: 'Campaign Name',
        fieldName: 'campaignUrl',
        type: 'url',
        initialWidth: 320,
        typeAttributes: {
            label: { fieldName: 'campaignName' },
            target: '_blank'
        }
    },
   /* {
        label: 'Members in Campaign',
        fieldName: 'membersInCampaign',
        type: 'number',
        initialWidth: 180
    },*/
    {
        label: 'Members in Hierarchy',
        fieldName: 'membersInHierarchy',
        type: 'number',
        initialWidth: 190
    },
    {
        label: 'Gifts in Campaign',
        fieldName: 'giftsInCampaign',
        type: 'number',
        initialWidth: 160
    },
    {
        label: 'Gifts in Hierarchy',
        fieldName: 'giftsInHierarchy',
        type: 'number',
        initialWidth: 170
    },
   /* {
        label: 'Donors in Campaign',
        fieldName: 'donorsInCampaign',
        type: 'number',
        initialWidth: 170
    },*/
    {
        label: 'Donors in Hierarchy',
        fieldName: 'donorsInHierarchy',
        type: 'number',
        initialWidth: 180
    },
   {
    label: 'Paid Value in Campaign',
    fieldName: 'giftValueInCampaign',
    type: 'currency',
    initialWidth: 190
},
{
    label: 'Total Value in Hierarchy',
    fieldName: 'allGiftValueInHierarchy',
    type: 'currency',
    initialWidth: 220
},
{
    label: 'Paid Value in Hierarchy',
    fieldName: 'giftValueInHierarchy',
    type: 'currency',
    initialWidth: 210
},
   /* {
        label: 'Responses in Campaign',
        fieldName: 'responsesInCampaign',
        type: 'number',
        initialWidth: 200
    },
    {
        label: 'Responses in Hierarchy',
        fieldName: 'responsesInHierarchy',
        type: 'number',
        initialWidth: 210
    },
    {
        label: 'Type',
        fieldName: 'type',
        type: 'text',
        initialWidth: 150
    },
    {
        label: 'Status',
        fieldName: 'status',
        type: 'text',
        initialWidth: 150
    }*/
];

export default class RuntimeCampaignGiftHierarchy extends LightningElement {
    @api recordId;

    @api title = 'Gift Campaign Hierarchy';
    @api giftStatusesCsv = 'Paid';
    @api startDateText;
    @api endDateText;
    @api includeSourceCodeAttribution = false;
    @api autoExpand = false;

    columns = COLUMNS;
    data = [];
    errorMessage;
    isLoading = true;
    wiredResult;

    @wire(getHierarchy, {
        campaignId: '$recordId',
        giftStatusesCsv: '$giftStatusesCsv',
        startDateText: '$startDateText',
        endDateText: '$endDateText',
        includeSourceCodeAttribution: '$includeSourceCodeAttribution'
    })
    wiredHierarchy(result) {
        this.wiredResult = result;
        this.isLoading = false;

        if (result.data) {
            this.errorMessage = undefined;
            this.data = result.data.map((node) => this.normalizeNode(node));

            if (this.autoExpand) {
                window.setTimeout(() => {
                    this.handleExpandAll();
                }, 0);
            }
        } else if (result.error) {
            this.data = [];
            this.errorMessage = this.reduceError(result.error);
        }
    }

    get hasData() {
        return this.data && this.data.length > 0;
    }

    handleRefresh() {
        this.isLoading = true;

        refreshApex(this.wiredResult)
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleExpandAll() {
        const grid = this.template.querySelector('lightning-tree-grid');

        if (grid) {
            grid.expandAll();
        }
    }

    handleCollapseAll() {
        const grid = this.template.querySelector('lightning-tree-grid');

        if (grid) {
            grid.collapseAll();
        }
    }

    normalizeNode(node) {
        const row = {
            ...node,
            campaignUrl: node.campaignUrl || `/${node.id}`
        };

        if (node.children && node.children.length > 0) {
            row._children = node.children.map((child) =>
                this.normalizeNode(child)
            );
        }

        delete row.children;

        return row;
    }

    reduceError(error) {
        if (!error) {
            return 'Unknown error';
        }

        if (Array.isArray(error.body)) {
            return error.body.map((e) => e.message).join(', ');
        }

        if (error.body && typeof error.body.message === 'string') {
            return error.body.message;
        }

        if (typeof error.message === 'string') {
            return error.message;
        }

        return JSON.stringify(error);
    }
}