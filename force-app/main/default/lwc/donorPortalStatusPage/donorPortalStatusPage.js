import { LightningElement, api } from 'lwc';

const COPY = {
    THANK_YOU: {
        icon: '✓',
        heading: 'Thank you',
        body: 'Our Donor Care team checks every update before it is saved to your record. You do not need to do anything else.',
        showHomeLink: true
    },
    EXPIRED: {
        icon: '!',
        heading: 'This link has expired',
        body: 'Please contact SAPA Donor Care for a new link.',
        showHomeLink: false
    },
    USED: {
        icon: '✓',
        heading: "You've already sent your details",
        body: 'Thank you.',
        showHomeLink: false
    },
    INVALID: {
        icon: '?',
        heading: "We couldn't open this page",
        body: '',
        showHomeLink: false
    },
    ERROR: {
        icon: '!',
        heading: 'Something went wrong',
        body: 'We could not load this page. Please check your connection and try opening your link again in a moment.',
        showHomeLink: false
    }
};

export default class DonorPortalStatusPage extends LightningElement {
    @api status; // 'THANK_YOU', 'EXPIRED', 'USED', 'INVALID', 'ERROR'
    @api firstName;

    get copy() {
        return COPY[this.status] || COPY.INVALID;
    }

    get iconClass() {
        const good = this.status === 'THANK_YOU' || this.status === 'USED';
        return 'status-page__icon ' + (good ? 'status-page__icon--good' : 'status-page__icon--attention');
    }

    get heading() {
        if (this.status === 'THANK_YOU' && this.firstName) {
            return `Thank you, ${this.firstName}`;
        }
        return this.copy.heading;
    }
}