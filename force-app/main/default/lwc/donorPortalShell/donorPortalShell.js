import { LightningElement } from 'lwc';
import sapaLogo from '@salesforce/resourceUrl/sapaLogo';
import sapaHeroKids from '@salesforce/resourceUrl/sapaHeroKids';

const FONTS_HREF = 'https://fonts.googleapis.com/css2?family=Roboto:wght@400;500;700&family=Roboto+Condensed:wght@400;600&display=swap';
let fontsLoaded = false;

export default class DonorPortalShell extends LightningElement {
    logoUrl = sapaLogo;

    // The photo is applied through a CSS variable (a static resource URL can't be written in the stylesheet itself);
    // the stylesheet layers the readability gradient over it.
    get contentStyle() {
        return `--sapa-hero: url("${sapaHeroKids}");`;
    }

    renderedCallback() {
        if (fontsLoaded) {
            return;
        }
        fontsLoaded = true;
        const link = document.createElement('link');
        link.setAttribute('rel', 'stylesheet');
        link.setAttribute('href', FONTS_HREF);
        document.head.appendChild(link);
    }
}
