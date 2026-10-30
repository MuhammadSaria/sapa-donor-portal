Summary — SAPA Donor Portal build status (updated 2026-10-26)

What it is: a donor self-service portal. SAPA gives a donor a private tokenized link; the donor fills in only the phone/address that is missing; Donor Care reviews and Accepts/Rejects before anything touches the real donor record.

What's built and live in the SAPA_STAGGING sandbox (published):
- Data model, labels, token service (S0–S2), guest site + profile (S3), guest controller + validator (S4), donor page LWCs (S5), staff review screen + permission set (S6–S7), backend end-to-end (S8).
- Donor page: SAPA logo and kids photo background (form and thank-you/error screens), read-only list of what is on file with a tick per item, inputs only for what is missing.
- Phone: pick a country code first (US, Canada, UK, Sudan pinned, then all countries), then the number. Stored as "+249 912345678".
- Address: all 237 countries the org accepts; a state dropdown only for the 10 countries that have states (US, Canada, ...), nothing for the rest.
- Staff review: its own "SAPA Portal Review" tab; reject reason is saved; accurate submitted date.
- Tests: 54 Apex tests, all passing (coverage 88–98% on the portal classes).

What the full review found and fixed (each reproduced live first):
- Accept failed for every US address (form sent "IL"; the org's restricted picklist needs "Illinois") — fixed with a normalizer that validates against the org's picklists at submit and again at Accept.
- A donor missing both phone and address could not submit only a phone (default country counted as an address).
- Server-side field errors were never shown on the page, so failed submits looked like "nothing happens".
- Guest profile was over-permissioned; now it has one Apex class and nothing else (verified with an anonymous guest).
- Phone dropdown could not be changed: every option had a disabled attribute (framework quirk). Fixed and re-verified with real key presses.
- Also: cached donor data removed, re-sent links reset old status, email no longer cross-copied between fields, reviewer double-click handled, Campaign "Responded" step no longer able to fail an Accept.
- The earlier "stale bundle" diagnosis was wrong: the live site was already serving the new code.

How to test: scripts/apex/generate-portal-link.apex (give it an Account Id, it prints the link), or copy the Portal Link field from a SAPA PortalTest... donor. Publish the site after any LWC change.

Still open (needs you):
- Activate the site to Live (still UnderConstruction).
- Add "SAPA Portal Review" to an app's navigation.
- Before production: change the Portal_Base_Url label (hard-codes the sandbox URL) and replace the personal email on site admin/owner/sender.
- Decide: keep the token after review (so reviewed links say "already sent"), mask phone/email on the page, make the token read-only for Donor Care.
- Optional: add Iran/Syria/Cuba/North Korea/US territories to the org's country picklist if needed.
- Accepted gaps: no Jest tests for the LWCs; Campaign "Responded" untested with real data (no campaigns in the sandbox); photo is only 640px wide.
- Later phase per the brief: S9 (the email-sending batch) and S10 (rollout prep) — not started.

Full detail with root causes, org facts, permissions and the file map is in sapa_portal_project.md.
