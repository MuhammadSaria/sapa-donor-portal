# SAPA Donor Contact Details Portal — README

**Jira:** SAPA-295 · **Org:** `SAPA_STAGGING` sandbox (`sudaneseamericanphysiciansassociat--stripestag`, CLI alias `SAPA-STAGGING`) · **Last updated:** 2026-10-26

This document explains **what was built, how it works, why each decision was made, how it is configured, and how to find the cause when something breaks.** It is written so that someone who did not build it (or you, a year from now) can understand every moving part.

Companion files: `sapa_portal_project.md` (chronological build log and open items) and `summary.md` (one-page status). This README is the *explanation*; those are the *record*.

## Contents

1. [What the portal is, in plain words](#1-what-the-portal-is-in-plain-words)
2. [The whole flow end to end](#2-the-whole-flow-end-to-end)
3. [Architecture map](#3-architecture-map)
4. [Data model — every field and what touches it](#4-data-model--every-field-and-what-touches-it)
5. [How it was built, step by step (and why)](#5-how-it-was-built-step-by-step-and-why)
6. [Component deep dives (the logic)](#6-component-deep-dives-the-logic)
7. [Configuration (site, permissions, labels, styling)](#7-configuration-site-permissions-labels-styling)
8. [Security model — why it is built this way](#8-security-model--why-it-is-built-this-way)
9. [Org-specific behaviours that will surprise you](#9-org-specific-behaviours-that-will-surprise-you)
10. [Testing — automated, manual, and the traps](#10-testing--automated-manual-and-the-traps)
11. [Deploying and publishing](#11-deploying-and-publishing)
12. [Troubleshooting playbook](#12-troubleshooting-playbook)
13. ["If you change X, also change Y" (hidden couplings)](#13-if-you-change-x-also-change-y-hidden-couplings)
14. [Known limitations, open items, go-live checklist](#14-known-limitations-open-items-go-live-checklist)
15. [Appendix: file map, handy commands, Salesforce DX basics](#15-appendix)

---

## 1. What the portal is, in plain words

Many SAPA donors have a missing phone number or an incomplete mailing address. The portal lets SAPA ask the donor to fix that themselves:

1. SAPA gives the donor a **private link** (it contains a long random secret, the *token*).
2. The donor opens it on a public SAPA page. **No login.** The page shows what SAPA already has (read-only) and asks **only for what is missing**.
3. The donor's answer is **held on the side** — it is *not* written to the real donor fields.
4. A **Donor Care** staff member sees a "before → after" list and clicks **Accept** (the real record is updated) or **Reject** (nothing changes).

Two ideas drive almost every design decision:

- **The donor is anonymous.** The only thing proving who they are is the secret in the link. So the server must re-check everything and must never reveal whether a donor exists.
- **A human approves before the real record changes.** So there are two sets of fields: the donor's real fields, and `New_*` "held" fields.

---

## 2. The whole flow end to end

```
 SAPA                         DONOR (anonymous browser)                DONOR CARE (logged in)
  │                                    │                                      │
  │ 1. issue link                      │                                      │
  │  PortalLinkService.assignTokens    │                                      │
  │  → token + 30-day expiry           │                                      │
  │  → Portal_Status__c = "Sent"       │                                      │
  │  → Portal_Link__c shows the URL    │                                      │
  │ ──── link (emailed by hand today; S9 not built) ──▶│                      │
  │                                    │ 2. opens /update?token=...           │
  │                                    │  LWC donorUpdatePortal               │
  │                                    │   ├ getPortalData(token)  ──▶ Apex   │
  │                                    │   └ getAddressOptions()   ──▶ Apex   │
  │                                    │ 3. sees what's on file + form for    │
  │                                    │    what's missing                    │
  │                                    │ 4. submitUpdate(token, phone, ...)   │
  │                                    │  Apex checks token/expiry/status,    │
  │                                    │  normalises country/state, validates,│
  │                                    │  writes New_* fields,                │
  │                                    │  Portal_Status__c = "Submitted"      │
  │                                    │ 5. "Thank you" screen                │
  │                                                                           │
  │                                                      6. opens "SAPA Portal Review" tab
  │                                                         getPendingSubmissions()
  │                                                      7. Accept → real fields updated,
  │                                                         token cleared, status "Accepted"
  │                                                         (or Reject → status "Rejected")
```

**Status lifecycle (`Portal_Status__c`):**

| Value | Set by | Meaning | What the link shows |
|---|---|---|---|
| *(blank)* | — | no link issued yet | n/a |
| `Sent` | `PortalLinkService.assignTokens` | link issued, donor has not answered | the form |
| `Submitted` | `submitUpdate` | donor answered, waiting for review | "You've already sent your details" |
| `Accepted` | `accept` | Donor Care applied it | link is spent (token cleared) → "We couldn't open this page" |
| `Rejected` | `reject` | Donor Care declined it | same as Accepted |

---

## 3. Architecture map

```
force-app/main/default/
├─ classes/
│   ├─ DonorUpdatePortalController   ← THE ONLY class the anonymous guest can call
│   ├─ PortalValidator               ← pure validation rules (phone, ZIP, address completeness)
│   ├─ PortalAddressNormalizer       ← turns "IL"/"USA" into the picklist labels the org accepts; lists countries/states
│   ├─ PortalLinkService             ← makes tokens, issues links
│   ├─ DonorUpdateReviewController   ← staff: list / Accept / Reject (permission-gated)
│   └─ *Test classes (5)
├─ lwc/
│   ├─ donorUpdatePortal      ← orchestrator: loads data, owns the form state, calls Apex
│   ├─ donorPortalAddressForm ← the address block (country → state dropdowns)
│   ├─ donorPortalStatusPage  ← thank-you / expired / used / invalid / error cards
│   ├─ donorPortalShell       ← page frame: header logo, photo background, footer, fonts
│   ├─ portalCountryData      ← dial-code table for the phone country-code selector
│   └─ donorUpdateReview      ← staff review table (standard Salesforce look)
├─ staticresources/  sapaLogo (PNG), sapaHeroKids (JPG)
├─ labels/           Portal_Base_Url, Portal_Link_Validity_Days, Portal_Reason_Text, Portal_Invalid_Link_Message
├─ customPermissions/ permissionsets/ tabs/   ← staff access to the review screen
├─ profiles/SAPA Update Portal Profile        ← the anonymous guest's permissions
├─ sites/ networks/ digitalExperiences/       ← the Experience Cloud site "SAPA Update Portal"
├─ cspTrustedSites/                           ← lets the page load Google Fonts
└─ objects/Account/fields/                    ← only the two newest fields live locally (see §4)
scripts/apex/generate-portal-link.apex        ← issue a link for one donor
```

**Who calls whom**

- Browser → `donorUpdatePortal` (LWC) → `DonorUpdatePortalController` (Apex) → `PortalValidator`, `PortalAddressNormalizer`.
- Browser (staff) → `donorUpdateReview` (LWC) → `DonorUpdateReviewController` → `PortalAddressNormalizer`.
- `PortalLinkService` is called by whatever issues links (today: the script; later: the S9 batch).

---

## 4. Data model — every field and what touches it

All on **Account** (the donors are **Person Accounts**).

| Field | Type | Purpose | Written by | Read by |
|---|---|---|---|---|
| `Portal_Token__c` | Text(64), **unique** | the secret in the link | `assignTokens`; cleared by Accept/Reject | `findByToken*` (guest), `Portal_Link__c` |
| `Portal_Token_Expiry__c` | DateTime | link valid until | `assignTokens`; cleared by Accept/Reject | `determineState` |
| `Portal_Status__c` | Picklist: Sent, Submitted, Accepted, Rejected | lifecycle (see §2) | `assignTokens`, `submitUpdate`, Accept, Reject | everything |
| `Portal_Link__c` | Formula (text) | the full URL: `$Label.Portal_Base_Url & "?token=" & Portal_Token__c` (blank if no token) | — | humans / future email |
| `Portal_Sent_Date__c` | Date | when the link was issued | the link script (S9 later) | reporting |
| `Portal_Campaign__c` | Lookup(Campaign) | campaign to mark "Responded" on Accept | S9 / manual | `accept` |
| `New_Phone__c` | Text(40) | **held** phone, `+<code> <number>` | `submitUpdate` | review screen, `accept` |
| `New_Street__c`, `New_City__c` | Text(255) | held address | `submitUpdate` | review, `accept` |
| `New_State__c`, `New_Country__c` | Text(80) | held state/country, **already normalised to picklist labels** | `submitUpdate` | review, `accept` |
| `New_Postal_Code__c` | Text(20) | held ZIP/postal code | `submitUpdate` | review, `accept` |
| `Contact_Info_Verified_Date__c` | Date | stamped on Accept | `accept` | reporting |
| `Portal_Reviewed_By__c` / `Portal_Reviewed_Date__c` | Lookup(User) / DateTime | who/when reviewed | Accept, Reject | reporting |
| `Portal_Submitted_Date__c` | DateTime | when the donor submitted (orders the review queue) | `submitUpdate` | review screen. **Added 2026-10-26** |
| `Portal_Reject_Reason__c` | LongText(1000) | reviewer's reason for rejecting | `reject` | humans. **Added 2026-10-26** |

**Existing org fields the portal depends on (pre-existing, not created here):**

| Field | Why it matters |
|---|---|
| `Missing_Phone__c` (formula, boolean) | `AND(ISBLANK(Phone), ISBLANK(PersonMobilePhone), ISBLANK(PersonHomePhone), ISBLANK(WorkPhone__c))`. **This decides whether the phone section is shown.** |
| `Missing_Mailing_Address__c` (formula, boolean) | `OR(street blank, city blank, country code blank, AND(country = US, OR(state code blank, ZIP blank)))`. **Decides whether the address section is shown.** |
| `WorkPhone__c`, `Preferred_Phone__c`, `Preferred_Email__c`, `Personal_Email__c`, `Work_Email__c`, `Alternate_Email__c` | used by the org's own sync flow (see §9) |
| `PersonMailingState/Country` (text) and `...StateCode/CountryCode` (restricted picklists) | where Accept writes the address (see §9) |

> **Note:** the local folder is a *retrieve* and has no `objects/Account` metadata except the two newest fields. The other portal fields exist in the org. Treat the org as the source of truth.

**Custom Labels** (Setup → Custom Labels):

| Label | Value / use |
|---|---|
| `Portal_Base_Url` | `https://sudaneseamericanphysiciansassociat--stripestag.sandbox.my.site.com/update` — the front of every link. **Hard-codes the sandbox; change for production.** |
| `Portal_Link_Validity_Days` | `30` — days a link stays valid. Blank, non-numeric or `0` falls back to 30. |
| `Portal_Reason_Text` | the intro sentence under the greeting |
| `Portal_Invalid_Link_Message` | `We couldn't open this page.` — the one message for *every* bad link (so a prober learns nothing) |

---

## 5. How it was built, step by step (and why)

### Step 0 — Resolve the open questions against the live org
Before writing code, two questions from the brief were answered by querying the org instead of assuming:
- *Standard fields or Contact Point records?* `ContactPointAddress`/`ContactPointPhone` are empty org-wide and nothing references them → use **standard Person Account fields**.
- *`Missing_Address__c` or `Missing_Mailing_Address__c`?* The org already had the latter (and `Missing_Phone__c`) → **reuse them**, don't duplicate. Their formulas are the rules for "what's missing".

### Step 1 (S0) — Prepare the sandbox
Created `sfdx-project.json` and `.forceignore` (the folder was a raw metadata dump, not a DX project), the first two fields (`Portal_Token__c` unique Text(64), `Portal_Token_Expiry__c`), five **test donors** (one per scenario: complete, phone missing, address partial, both missing, non-US) with a re-runnable script, and a status query.

### Step 2 (S1) — Data fields and labels
Created the rest of the fields in §4 and the four labels. **Explicit FLS** was granted to the `Admin` and `Donor Care` profiles, because this org does not auto-grant field access to System Administrator on new fields (a new field is invisible to even an admin's queries until granted).

### Step 3 (S2) — Token service (`PortalLinkService`)
`newToken()` = `EncodingUtil.convertToHex(Crypto.generateAesKey(256))` → 64 hex characters of cryptographic randomness (256 bits; guessing is infeasible). `assignTokens` sets token + expiry on a list of accounts and **does no DML** (the caller updates) so it can be used by a script, a batch, or a flow.

### Step 4 (S3) — The public site
Created the Experience Cloud site **SAPA Update Portal** (template *Build Your Own (LWR)*) at path `/update`. The org rejected the `UNAUTHENTICATED` auth type, so `AUTHENTICATED_WITH_PUBLIC_ACCESS_ENABLED` is used (no login UI is exposed). A dedicated guest profile `SAPA Update Portal Profile` was created, born with no access to anything. CSP Trusted Sites were added so the page can load Google Fonts.

### Step 5 (S4) — The guest-facing controller and validator
`DonorUpdatePortalController` is the single door for the anonymous visitor. `PortalValidator` holds pure validation functions (no SOQL/DML) so the *same rules* can be mirrored in JavaScript for instant feedback while the server remains the authority.

### Step 6 (S5) — The donor page (LWCs)
`donorPortalShell` (frame/theme), `donorPortalStatusPage` (thank-you/expired/used/invalid), `donorPortalAddressForm`, and `donorUpdatePortal` (orchestrator, placed on the site's Home page). Two platform limits were met: LWC CSS cannot `@import url(...)`, and templates cannot contain `<link>`; Google Fonts is therefore loaded by creating a `<link>` element in JavaScript (`renderedCallback`).

### Step 7 (S6) — The staff review screen
`DonorUpdateReviewController` (`with sharing`) + `donorUpdateReview` LWC in plain SLDS (intentionally *not* SAPA-themed — it is inside Salesforce). Access is enforced **on the server** via a custom permission, not just by hiding the screen.

### Step 8 (S7) — Permission set
`Portal_Donor_Care_Review` bundles the custom permission and class access; assigned to the Donor Care user and the sandbox admin.

### Step 9 (S8) — Backend end-to-end
The whole chain was exercised in Apex. **This gave false confidence** — see step 10.

### Step 10 — First real-browser pass: five guest-only bugs
Apex tests and anonymous Apex run as an admin-equivalent user, never as a true guest. Real browser testing as an anonymous visitor exposed:

1. **Guests could not query Account** → fixed (originally by granting object access; later found unnecessary — see step 12).
2. **Guests cannot see existing records without a sharing rule** → controller uses `WITH SYSTEM_MODE` queries and `AccessLevel.SYSTEM_MODE` DML. One narrow, token-gated gateway with full backend access is cleaner than changing org-wide sharing.
3. **`FOR UPDATE` + `WITH SYSTEM_MODE` in one query broke formula fields for guests** → split into a lock query then a separate read query.
4. **A nested Apex wrapper type did not deserialize as a method *parameter* for guests** (every field arrived null, though the same type works as a *return* value) → `submitUpdate` takes **seven plain String parameters**.
5. **"Stale LWR bundle"** → later re-diagnosed: the live site was already serving the new code (see step 11).

### Step 11 — Full review (2026-10-26): reproduce-then-fix
Every suspected defect was **reproduced against the live org** (in rolled-back savepoints) before fixing:

| Defect | Cause | Fix |
|---|---|---|
| Accept failed for every US address | The form sent `IL`; the org's State picklist is **restricted** and accepts only labels (`Illinois`) | Form sends names; `PortalAddressNormalizer` resolves codes/aliases at submit **and** again at Accept |
| Phone-only submit failed for donors missing both | Form always sent a default country; server counted country as "address started" | Country alone no longer counts; form sends the address only if the donor edited it |
| "Nothing happens" on a failed submit | Field errors from the server were never displayed | Errors shown on fields + summary banner |
| Accept could fail and roll back | Setting CampaignMember "Responded" throws if the campaign lacks that status | Check the status exists first; never fail the Accept |
| Email copied into the wrong field | Old workaround always wrote `PersonEmail` into `Personal_Email__c` | Write only to the *preferred* email field, only if empty |
| Over-permissioned guest | leftover from step 10 | Stripped to one Apex class (verified) |
| `getPortalData` cacheable | PII keyed by a secret token, and the network serves Apex through a CDN | `cacheable=true` removed |
| Re-sent link said "already sent" | `assignTokens` didn't reset status | resets to `Sent`, clears old held values |
| Reject reason not saved; queue date inaccurate; unbounded queue | — | new fields; `LIMIT 200` |

### Step 12 — Look and feel
Real SAPA logo, kids photo background (also behind the thank-you/error cards) with a dark fade for legibility, edge-to-edge layout, form cards, focus rings, "Sending…" button state, mobile keyboard/autofill hints, status icons coloured by outcome. Page title and `noindex` set in the site head markup.

### Step 13 — Show what is on file; all countries; dependent states; phone codes
- A read-only list (✓ green when on file, orange **!** when missing) of name, email, phone, address.
- `getAddressOptions()` returns all 237 org countries with their states; the form shows a state dropdown only where states exist (10 countries).
- Phone: choose country code first, then number; stored as `+<code> <number>`.
- **Bug found and fixed here:** the phone dropdown could not be changed because every `<option>` rendered with a `disabled` attribute (`disabled={false}` still produces the attribute on `<option>`). My scripted test set the value from code, which bypasses `disabled`; only real key presses revealed it. See §10 and §12.

---

## 6. Component deep dives (the logic)

### 6.1 `PortalLinkService`
- `newToken()` — 64 lowercase hex chars from 256 random bits.
- `assignTokens(List<Account>)` — for each account: new token, `Portal_Token_Expiry__c = now + validityDays`, `Portal_Status__c = 'Sent'`, and **clears** `New_*`, `Portal_Submitted_Date__c`, `Portal_Reject_Reason__c`. No DML.
- `validityDays()` reads the label; blank, non-numeric or `< 1` → 30.
- *Why reset on re-issue:* otherwise a donor from an earlier round would receive a brand-new link that immediately reads "already sent".

### 6.2 `PortalValidator` (pure functions)
- `isValidUsZip` — `12345` or `12345-6789`.
- `hasOnlyPhoneCharacters` — digits, spaces, `( ) . + -`, optional extension (`x45`, `#45`). Rejects text like "call me".
- `isValidPhone` — **with a leading `+`**: 8–15 total digits (E.164 maximum); if the number starts with `1` (North America) it must be exactly 11 digits (`1` + 10). **Without `+`** (older data): ≥ 10 digits.
- `isAddressStarted(street, city, state, zip, country)` — true if any of street/city/state/zip is non-blank. **Country is deliberately ignored** (the form always has one selected).
- `isAddressComplete` — street, city, country required; if the country is the United States, state and a valid ZIP too.
- `isUnitedStates(country)` — blank counts as US; also accepts US/USA/United States/United States of America.
- `validateSubmission(...)` — returns a list of `ValidationError(field, message)`: phone validity, field lengths (Account field limits), half-filled address, and "at least one section must be filled" (`field = null` → a form-level message).

The JS (`isValidPhone` in `donorUpdatePortal.js`, ZIP/completeness in `donorPortalAddressForm.js`) **mirrors** these for instant feedback. The server's answer always wins.

### 6.3 `PortalAddressNormalizer`
**Problem:** `PersonMailingState`/`PersonMailingCountry` are *restricted picklists* (see §9); writing `IL`, `USA`, or a free-text state throws `FIELD_INTEGRITY_EXCEPTION`.
**Solution:** read the org's own picklists once per transaction and map whatever the donor typed to the exact label.
- `load()` — describes `PersonMailingCountryCode` and `PersonMailingStateCode` via the **dynamic** `Schema` API (so the class still compiles if the feature were off; it then passes values through unchanged).
- **Dependency bitmap:** states are a *dependent* picklist. Each state's JSON form has a `validFor` base64 bitmap; bit *n* set means "valid for the *n*-th country in the controlling list". `PicklistEntry` has no getter for it, so the class serialises each entry to JSON and reads `validFor`. `toBytes` decodes base64 → hex → integers; `isBitSet(bytes, i)` tests `bytes[i/8] & (128 >> (i%8))`.
- `normalize(country, state)` → `Result{country, state, errors}`:
  - blank country → pass-through (the validator reports it missing);
  - country matched by label or ISO code, plus aliases (`USA`, `U.S.`, `United States of America`, `UK`, `Great Britain`); not found → error on `country`;
  - state: if the country has **no state list** → state dropped (nothing valid to store); else matched by label or code *within that country* (so `ON` works for Canada, not the US); not found → error on `state`.
- `getOptions()` → `List<CountryOption{label, code, states[]}>` for the dropdowns; `states` is empty when the org has none for that country.
- **A test asserts every offered country and state passes `normalize`** — so the form can never offer something the server then rejects.

### 6.4 `DonorUpdatePortalController` (the only guest-callable class; `without sharing`)

`getPortalData(token)` — **not** cacheable:
1. `findByToken` (query `WITH SYSTEM_MODE`, `LIMIT 1`).
2. `determineState`: no match → `INVALID`; no/past expiry → `EXPIRED`; status in {Submitted, Accepted, Rejected} → `USED`; else `READY`.
3. If not `READY` → return only the generic message (never any donor data).
4. If `READY` → name, email, phone (first non-blank of Phone/Mobile/Home/Work), address parts, `phoneEditable = Missing_Phone__c`, `addressEditable = Missing_Mailing_Address__c`, intro text.

`getAddressOptions()` — `cacheable=true` (it is reference data: no donor data, no token). Delegates to the normalizer.

`submitUpdate(token, phone, street, city, state, postalCode, country)`:
1. **Lock the row** (`findByTokenForUpdate`: `SELECT Id ... FOR UPDATE` then a *separate* plain query for fields). Two simultaneous submits on one token cannot both pass the status check.
2. Re-run `determineState`; anything but `READY` → generic failure (same wording as a bad link).
3. Recompute `phoneEditable`/`addressEditable` **from the record**, never from the client.
4. `addressStarted = addressEditable && isAddressStarted(...)`.
5. If started → `PortalAddressNormalizer.normalize` → clean country/state + errors.
6. `PortalValidator.validateSubmission` with the cleaned values. If the country was unrecognised, drop the validator's state/ZIP complaints (they would be noise). `mergeErrors` keeps the first error per field (the normalizer's wording is better).
7. Any error → `ok=false` + error list; **nothing written**.
8. Otherwise write `New_*` (trimmed; only the sections that were editable and provided), `Portal_Status__c = 'Submitted'`, `Portal_Submitted_Date__c = now`, via `Database.update(..., AccessLevel.SYSTEM_MODE)`.

Why `SYSTEM_MODE` and why seven String parameters: see steps 10.2 and 10.4.

### 6.5 `DonorUpdateReviewController` (`with sharing`)
- `requirePermission()` — `FeatureManagement.checkPermission('Portal_Donor_Care_Review')`; throws a readable `AuraHandledException`. **This is the real gate**; hiding the tab is only convenience.
- `getPendingSubmissions()` — accounts with status `Submitted`, ordered by `Portal_Submitted_Date__c` (nulls last, then `LastModifiedDate`), `LIMIT 200`. Returns current vs new values and `phoneChanged`/`addressChanged` flags.
- `accept(accountId)`:
  1. Query the row **`FOR UPDATE`**, only if still `Submitted`; empty → "already been reviewed" message (two reviewers, double click).
  2. Phone changed → `PersonMobilePhone = New_Phone__c` + `protectPersonEmail` (below).
  3. Address changed → **re-normalise** `New_Country__c`/`New_State__c` (this also repairs rows held before normalisation existed); errors → friendly message telling the reviewer to Reject; else write `PersonMailingStreet/City/State/PostalCode/Country`.
  4. Clear all `New_*`, token and expiry (the link is now spent); clear reject reason; stamp verified date, reviewer, reviewed date; status `Accepted`.
  5. `update` in try/catch → a `DmlException` becomes a readable message.
  6. Campaign: if `Portal_Campaign__c` and a person contact exist **and** the campaign has a "Responded" member status → set the member to Responded with `Database.update(..., false)` so it can never fail the Accept.
- `reject(accountId, reason)` — same locking; clears held values and token; stores the reason (trimmed, ≤1000); status `Rejected`.
- `protectPersonEmail` — see §9 (the flow). It copies `PersonEmail` into the donor's **preferred** email field only when that field is empty, so the flow re-derives the same address instead of blanking it.

### 6.6 LWCs

**`donorUpdatePortal`** (orchestrator)
- Reads `?token=` from `window.location.search`; calls `getPortalData` and `getAddressOptions` **in parallel**. If only the country list fails it is swallowed (`.catch(() => [])`) — the form still loads and the address block explains the problem. If `getPortalData` throws → status `ERROR` ("Something went wrong"), **not** `INVALID`, so a network blip never tells a donor their link is bad.
- Shows the "What we have" card from data it already has (no extra call).
- **Phone:** `dialIso` (selected country, default `US`) + `phone` (typed). `fullPhone` = `+<code> <number>`; outside North America a leading `0` is removed; if the donor typed a `+` themselves it is used as typed. `dialGroups` builds two `<optgroup>`s: **Common** (US, Canada, UK, Sudan) and **All countries** A–Z — only countries present in the org's list *and* in `DIAL_CODES`.
- **`canSubmit`:** something valid to send *and* nothing half-finished. `phoneOk = phoneProvided && isValidPhone(fullPhone)`; `addressOk = addressStarted && address.isComplete`; allowed when `(phoneOk || addressOk)` and `(!phoneProvided || phoneOk)` and `(!addressStarted || addressOk)`.
- **`addressStarted`** = the address section is shown **and** the address form reports `isDirty`.
- On submit it sends the phone only if provided, and the address fields only if `addressStarted` (else `null`). Server errors are split into per-field errors and a form-level message.

**`donorPortalAddressForm`**
- Owns its state. The parent passes **starting** values once (`street`, `city`, `state`, `postalCode`, `country`), the country list (`countries`) and `serverErrors`; it never pushes values back in (pushing back was what made the old "Other" dropdown snap to blank).
- Prefill: the donor's country is matched to the org list (aliases handled) — if none matches it defaults to United States and records `startedWithoutCountry`; the state is matched within that country's list.
- **`isDirty`** — street/city/state/ZIP differ from where they started, **or** (donor had no country on file, *and* picked one, *and* a street and city exist). Merely browsing the country list on an empty address does **not** count.
- `isComplete` — street, city, country; for the US also a state and valid ZIP.
- State dropdown appears only when the selected country has states; changing country clears the state.
- Emits `addresschange` `{street, city, state, postalCode, country, isComplete, isDirty}` on every change and once at load.

**`donorPortalStatusPage`** — one card for `THANK_YOU`, `EXPIRED`, `USED`, `INVALID`, `ERROR` with copy and an icon (green for THANK_YOU/USED, orange otherwise).

**`donorPortalShell`** — page frame. Sets `--sapa-hero` (the photo URL) as a CSS variable via an inline style (a static-resource URL can't be written into a stylesheet), and the stylesheet layers a dark gradient over it. Pulls itself out `-16px` over the padding the Experience Builder section adds. Forces footer/link colours with `!important` because the site theme colours links blue. Loads Google Fonts by creating a `<link>` in `renderedCallback` (once).

**`portalCountryData`** — `DIAL_CODES` (ISO-2 → dial code; all North American countries share `1`) and `PINNED_ISO_CODES`. The org has no dial-code data, so this table is hand-written. Country *names* come from the org so both lists agree.

**`donorUpdateReview`** — staff table (current → new phone/address), Accept, Reject-with-reason, a notice if the queue hit 200. Errors are shown as toasts using the server's message.

---

## 7. Configuration (site, permissions, labels, styling)

**Experience Cloud site** — name `SAPA Update Portal`, template *Build Your Own (LWR)*, URL path `/update`, auth `AUTHENTICATED_WITH_PUBLIC_ACCESS_ENABLED`, self-registration off, guest file access off, guest Chatter off, status **`UnderConstruction`** (not yet Live). The Home page holds a single `c:donorUpdatePortal` component. **Site admin / guest record owner / email sender are one person's address — replace with a shared user before go-live.**

**Head markup** (`sfdc_cms__appPage/mainAppPage/content.json`, key `headMarkup`): `<title>SAPA - Update Your Contact Details</title>`, `noindex, nofollow`, referrer policy.

**Guest profile `SAPA Update Portal Profile`** (Guest User License):
- Apex class access: **`DonorUpdatePortalController` only.**
- Object permissions: **none.** Custom field grants: **none.** Flow access: none.
- About 972 default boilerplate field-permission rows exist on every fresh guest profile; they are inert with zero object permissions (documented, accepted).

**`Portal_Donor_Care_Review` permission set** — class access to `DonorUpdateReviewController`; the custom permission of the same name; read on `Portal_Submitted_Date__c`, read/edit on `Portal_Reject_Reason__c`; visibility of the `Donor_Update_Review` tab. **Donor Care also needs Account access and FLS on the portal fields through their profile** (granted in step 2). The tab is **not yet in any app's navigation** (App Launcher search finds it).

**CSP Trusted Sites** — `fonts.googleapis.com` (styles) and `fonts.gstatic.com` (font files).

**Static resources** — `sapaLogo` (`image/png`), `sapaHeroKids` (`image/jpeg`). Referenced in LWC with `@salesforce/resourceUrl/<name>`; renaming one breaks the import.

---

## 8. Security model — why it is built this way

- **The token is the only credential.** 256 random bits; infeasible to guess. It is stored in plaintext (so Donor Care and anyone who can read the donor can see the link — see §14 for the option to restrict).
- **Same answer for every bad link** (`We couldn't open this page.`): unknown, expired, spent and edited tokens are indistinguishable except the explicit "expired"/"already sent" states that only a real token-holder can reach. No donor data is ever returned for a non-`READY` link.
- **The server never trusts the client.** It recomputes which sections are editable from the record, re-validates everything, and normalises values itself.
- **Row lock** (`FOR UPDATE`) prevents a double submit passing the status check twice.
- **No object access for the guest.** The controller runs in `SYSTEM_MODE`; the guest profile therefore needs only class access. Anything extra widens the blast radius if a guest sharing rule is ever added. (Verified by calling the controller as an anonymous visitor with all object access removed.)
- **The staff gate is on the server** (`FeatureManagement.checkPermission`), not only in the UI.
- **Held values, not live values:** the donor cannot change the real record; a human must Accept.
- **Not cached:** `getPortalData` is non-cacheable (the network serves Apex via CDN). `getAddressOptions` *is* cacheable because it contains no donor data.
- **The page shows the donor their own full phone/address** to anyone holding the link. Masking is a small change if wanted (§14).

---

## 9. Org-specific behaviours that will surprise you

1. **State and Country are restricted picklists.** `PersonMailingState`/`PersonMailingCountry` accept only the picklist *label*. `IL`, `USA`, `US`, `ON`, free-text states and unknown countries all fail with `FIELD_INTEGRITY_EXCEPTION`. This is the single biggest source of "Accept fails" bugs; the normalizer exists because of it. Verified examples: `Illinois`✔ `illinois`✔ `IL`✘ `Ontario`✔ `ON`✘ `United States`✔ `USA`✘.
2. **Only 10 countries have states** (Australia, Brazil, Canada, China, India, Ireland, Italy, Japan, Mexico, United States). For all others the org accepts no state at all, so the form hides the state field and the server drops one if sent.
3. **The country list excludes** Iran, Syria, Cuba, North Korea and US territories such as Guam. Donors there cannot select their country until the org's picklist is extended (a Setup change).
4. **`To_update_contact_Records`** (after-save flow on Account) *derives* `PersonEmail` from the donor's preferred email field (`Preferred_Email__c`: Personal/Work/Alternate) and `Phone` from the preferred phone. It runs whenever a phone field, `Personal_Email__c`, or the preferred-* fields change, **and on insert**. If the preferred email field is blank it **blanks `PersonEmail`**. Consequences: (a) writing `PersonMobilePhone` on Accept can wipe the email — hence `protectPersonEmail`; (b) test donors need `Personal_Email__c` set or their `PersonEmail` becomes null.
5. **No FLS auto-grant** to System Administrator on new custom fields. A new field is invisible (even to an admin's SOQL) until granted through a profile or permission set.
6. **LWR sites serve the *published* bundle.** `sf project deploy` updates the draft; guests see the change only after `sf community publish`. (Then hard-refresh: Ctrl+Shift+R.)
7. **Guests and Apex:** Apex tests never run as a guest. A guest can fail in ways no unit test shows (sharing, object access, parameter deserialization).
8. **Nested Apex types as `@AuraEnabled` *parameters* arrive empty for guests** (return values are fine). Keep guest-callable method parameters primitive.
9. **`FOR UPDATE` + `WITH SYSTEM_MODE` in one query breaks formula evaluation for guests.** Lock first, read second.
10. **`<option disabled={false}>` in LWC renders a real `disabled` attribute.** Never bind `disabled` on `<option>`.
11. **Headless-browser limits:** Edge headless enforces a minimum window width; use device-metrics emulation when screenshotting mobile widths.

---

## 10. Testing — automated, manual, and the traps

### 10.1 Automated (54 Apex tests, all passing)
Run: `sf apex run test --tests DonorUpdatePortalControllerTest --tests DonorUpdateReviewControllerTest --tests PortalLinkServiceTest --tests PortalValidatorTest --tests PortalAddressNormalizerTest -o SAPA-STAGGING --result-format human --code-coverage --wait 15`

| Test class | What it protects |
|---|---|
| `DonorUpdatePortalControllerTest` | each portal scenario (complete / phone missing / partial address / bad input / expired / used / random token / double submit), **phone-only when both sections are editable**, state-code & country-alias storage, per-field errors, length & phone-text rejection, `getAddressOptions` availability, country-code phone storage, everything-on-file is returned |
| `DonorUpdateReviewControllerTest` | list, Accept (phone, address, legacy `IL`/`USA` repair), unstorable address → readable error + nothing changed, double review message, Work-preferred donor not cross-filled, Personal-empty email kept, Reject + reason + submitted-date ordering, permission refusal |
| `PortalValidatorTest` | ZIP, phone (including per-country `+` rules), address started/complete, validation outcomes, "country alone is not an address" |
| `PortalAddressNormalizerTest` | state by name/code/case, country aliases, state-per-country, unknown country, blanks, options list, **every offered option accepted**, normalised values can be saved to a real Person Account |
| `PortalLinkServiceTest` | token format/randomness, no DML, status reset on re-issue |

Tests that depend on the org's data (flagged because they can break if it changes): they assume the picklists contain `Illinois`, `Ontario`, `United States`, `Sudan`, `Pakistan`, and that Sudan/Pakistan have no states; and the email tests depend on the sync flow (§9.4).

### 10.2 Manual test donors
Full names are `SAPA PortalTest...`:

| Donor | Page shows |
|---|---|
| `...PhoneMissing` | phone only |
| `...AddressPartial` | address only (street/city prefilled) |
| `...BothMissing` | phone and address |
| `...Complete` | read-only, nothing to fill in |
| `...NonUS` | read-only, UK address |

A link is **single-use**: after Submit it reads "already sent"; after Accept/Reject it is spent. Issue a fresh one to test again.

### 10.3 Issuing a link — `scripts/apex/generate-portal-link.apex`
Edit `accountId` (from the record URL) and `save`, then:
```
sf apex run -f scripts/apex/generate-portal-link.apex -o SAPA-STAGGING
```
or paste it into Developer Console → Debug → Open Execute Anonymous Window. It validates the Id (must be an existing Person Account), calls `assignTokens`, stamps `Portal_Sent_Date__c`, and prints `PORTAL LINK https://...`. With `save = false` it rolls back (the printed link will not work). **No email is sent.**

### 10.4 Browser testing — the traps (learned the hard way)
- Test as a **truly anonymous** visitor (incognito, or HTTP with no session). A logged-in admin hides guest-only failures.
- **Use real input**, not scripted values. Setting `select.value` from code bypasses `disabled`; the phone dropdown was broken for exactly that reason. Use key presses/clicks that produce trusted events.
- **Test with the form's real values.** The original unit tests used `Illinois` while the form sent `IL`.
- Always **publish and hard-refresh** after an LWC change.
- Checking "what does the live site serve": fetch the page and the `...scopedHeaderAndFooter_view` / `home_view` bundle and search for a string you just added.

---

## 11. Deploying and publishing

```bash
# Apex + tests
sf project deploy start -o SAPA-STAGGING -d force-app/main/default/classes/<Name>.cls

# One LWC (donor page) — then publish
sf project deploy start -o SAPA-STAGGING -d force-app/main/default/lwc/donorUpdatePortal
sf community publish --name "SAPA Update Portal" -o SAPA-STAGGING

# Static resource
sf project deploy start -o SAPA-STAGGING -d force-app/main/default/staticresources/sapaLogo.png -d force-app/main/default/staticresources/sapaLogo.resource-meta.xml
```
- **Order matters:** fields before classes that reference them; classes/fields/tab before the permission set that grants them.
- **Deploying the whole `digitalExperiences` folder replaces the site's Builder content with your local copy.** Do it only when you mean to (it was done once to change the page title); retrieve first if anyone has edited in Builder.
- **Profiles deploy additively**: omitted permissions are *not* revoked. To revoke, list them with `false` (that is how the guest profile was stripped, with a minimal partial file).
- `sf community publish` may print an error-looking exit code on Windows even when it succeeded ("We're publishing your changes now…" is the success message).
- After publishing, allow ~1 minute before testing.

**Retrieving a profile alone returns a partial file** — do not overwrite the large local profile with it.

---

## 12. Troubleshooting playbook

First, identify **which side** is failing. Open the failing link in incognito and note the exact screen.

| What you see | Most likely cause | How to check / fix |
|---|---|---|
| **"We couldn't open this page"** (the big "?" screen) | Any of: (a) the link is **spent** — Accept or Reject cleared the token; (b) the URL has **no `?token=`** or the token was edited/truncated (this is what you see inside Experience Builder, which has no token); (c) a **newer link was issued** for the same donor, so the old token no longer exists; (d) the link was never issued. (An *expired* link shows "This link has expired" instead.) | Query the donor: `SELECT Portal_Status__c, Portal_Token__c, Portal_Token_Expiry__c FROM Account WHERE Id='001…'`. Blank token ⇒ spent or never issued ⇒ issue a new link (§10.3). In Builder, preview with `?token=…` added to the URL. |
| **"This link has expired"** | `Portal_Token_Expiry__c` is in the past | Issue a new link (resets the 30 days). Change `Portal_Link_Validity_Days` for a different window. |
| **"You've already sent your details"** | status is `Submitted` (awaiting review) | Expected. Review it in the **SAPA Portal Review** tab, or issue a new link to start over. |
| **"Something went wrong"** (not "couldn't open") | `getPortalData` threw or the request failed. Guest probably lost class access, or an Apex exception occurred | Check the guest profile still has `DonorUpdatePortalController` enabled; call the controller anonymously (§12.1); check Debug Logs for the site guest user. |
| **Address section shows "We couldn't load the list of countries"** | `getAddressOptions` failed (class access removed, picklists disabled, Apex error). The rest of the form still works | Run `PortalAddressNormalizerTest`; confirm Setup → State and Country/Territory Picklists are enabled; confirm class access. |
| **Submit button stays grey** | client rules say nothing valid to send, or something is half-finished (e.g. you started an address but left it incomplete, or the phone is the wrong length for the chosen code) | Read the red messages; for US phones exactly 10 digits; a US address needs state + 5-digit ZIP. Remember the address only counts once street/city/state/ZIP changed. |
| **Submit does nothing / red banner "Please fix the highlighted fields"** | the server rejected it; per-field messages are displayed | Read the field messages. Reproduce with the Apex call in §12.1. |
| **Accept toast: "The submitted address cannot be saved…"** | the held country/state is not in the org picklists (old row, or a country the org lacks) | Reject the submission (the message says so) and issue a new link; or add the country to the org's picklist. |
| **Accept toast: "…could not be updated: <DML message>"** | a validation rule, duplicate rule, required field or lock on that Account | The message is the real Salesforce error — fix the cause on the record. Duplicate rules on Account are active in this org. |
| **Accept toast: "…already been reviewed"** | another reviewer got there first, or double-click | Refresh the list. |
| **Review tab missing / "You do not have access"** | permission set `Portal_Donor_Care_Review` not assigned, or the tab not visible | Setup → Permission Sets → Manage Assignments. Also check the user's profile has Account read + FLS on portal fields. |
| **Review list empty but donors submitted** | status isn't `Submitted` (e.g. already Accepted), the user can't see those Accounts (sharing), or the list is capped at 200 | Query `Portal_Status__c = 'Submitted'`. |
| **Donor's email disappeared after Accept** | the sync flow blanked `PersonEmail` because the preferred email field is empty and `protectPersonEmail` didn't cover the case (e.g. `Preferred_Email__c` blank/other) | Check `Preferred_Email__c`, `Personal_Email__c`, `Work_Email__c`, `Alternate_Email__c` on the donor; see §9.4. |
| **Phone dropdown won't change** | an `<option>` got a `disabled` attribute again | Search templates for `disabled={` on `<option>`; remove it. Confirm with a real key press, not a script. |
| **Dial code missing for a country** | the org list has it but `DIAL_CODES` lacks its ISO code | Add it to `portalCountryData.js`. |
| **Old look/behaviour after deploying** | not published, or browser cache | `sf community publish …`, wait a minute, Ctrl+Shift+R. |
| **Photo or logo missing** | static resource renamed/deleted or wrong content type; or the site is serving cached HTML | Check Setup → Static Resources: `sapaLogo` (`image/png`), `sapaHeroKids` (`image/jpeg`); republish. |
| **Page has a pale border / blue footer link again** | the site theme CSS changed or a CSS rule was edited | See `donorPortalShell.css` (`margin:-16px`, `!important` link colours). |
| **New field "not found" / invisible in queries** | no FLS | Grant via profile or the permission set (§9.5). |
| **Link field blank** | `Portal_Token__c` is blank | Issue a link (§10.3). |
| **No email arrives** | S9 (email sending) is not built | Expected — copy the link manually for now. |
| **Apex tests fail after an org change** | the tests assume specific picklist labels / the sync flow (§10.1) | Read the failing assertion; adjust the test data or the picklists. |
| **Deploy fails on the profile or digital experience** | profile references something missing, or the bundle is out of sync | Deploy only what you need; see §11. |

### 12.1 Reproduce a guest call from the command line
This calls the same controller, anonymously, the way the site does:
```powershell
$base = 'https://sudaneseamericanphysiciansassociat--stripestag.sandbox.my.site.com'
$body = @{ namespace=''; classname='@udd/<ApexClassId of DonorUpdatePortalController>'; method='getPortalData';
           isContinuation=$false; params=@{ token='<token>' }; cacheable=$false } | ConvertTo-Json -Depth 5
Invoke-WebRequest -Uri "$base/update/webruntime/api/apex/execute" -Method POST -Body $body -ContentType 'application/json' -UseBasicParsing
```
Find the class Id with `SELECT Id FROM ApexClass WHERE Name='DonorUpdatePortalController'` (the `01p…` value). Swap `method` and `params` to test `submitUpdate` (send all seven parameters; `phone`, `street`, … may be `null`). **A guest-only bug will reproduce here but not in anonymous Apex or unit tests.**

### 12.2 Useful queries
```bash
# a donor's portal state
sf data query -o SAPA-STAGGING -q "SELECT Name, Portal_Status__c, Portal_Token_Expiry__c, Missing_Phone__c, Missing_Mailing_Address__c, New_Phone__c, New_Street__c, New_State__c, New_Country__c, Portal_Link__c FROM Account WHERE Id='001…'"

# what the guest profile can do (should be: one Apex class, no object/field access)
sf data query -o SAPA-STAGGING -q "SELECT Id FROM PermissionSet WHERE Profile.Name='SAPA Update Portal Profile'"
sf data query -o SAPA-STAGGING -q "SELECT SobjectType, PermissionsRead, PermissionsEdit FROM ObjectPermissions WHERE ParentId='<id from above>' AND (PermissionsRead=true OR PermissionsEdit=true)"
sf data query -o SAPA-STAGGING -q "SELECT Field FROM FieldPermissions WHERE ParentId='<id>' AND SobjectType='Account' AND (PermissionsRead=true OR PermissionsEdit=true) AND (Field LIKE 'Account.New_%' OR Field LIKE 'Account.Portal_%')"

# the review queue
sf data query -o SAPA-STAGGING -q "SELECT Name, Portal_Submitted_Date__c, New_Phone__c, New_Street__c FROM Account WHERE Portal_Status__c='Submitted' ORDER BY Portal_Submitted_Date__c"
```
For failures that only occur for the anonymous visitor, add a **trace flag / debug log** (Setup → Debug Logs) for the site's guest user and reproduce.

---

## 13. "If you change X, also change Y" (hidden couplings)

| If you change… | …also check |
|---|---|
| **Phone rules** in `PortalValidator.isValidPhone` | the JS mirror `isValidPhone` in `donorUpdatePortal.js`, the error wording, the tests |
| **ZIP/address-complete rules** | `PortalValidator` **and** `donorPortalAddressForm.js` (`isValidUsZip`, `isComplete`) — and the live formula `Missing_Mailing_Address__c` (it decides whether the section appears at all) |
| **What counts as "missing"** | the `Missing_*` formulas on Account (they are the single source of truth); the UI follows them automatically |
| **Status values** (`Sent/Submitted/Accepted/Rejected`) | the picklist, `USED_STATUSES` and `determineState`, `assignTokens`, `submitUpdate`, review queries, tests |
| **The custom permission name** `Portal_Donor_Care_Review` | `DonorUpdateReviewController.REQUIRED_PERMISSION`, the permission set, tests |
| **Review queue size** | `QUEUE_LIMIT` in `DonorUpdateReviewController` **and** `QUEUE_LIMIT` in `donorUpdateReview.js` |
| **Country/state wording or the org's picklists** | `PortalAddressNormalizer` is automatic, but tests reference `Illinois`, `Ontario`, `Sudan`, `Pakistan`; the form's `COUNTRY_ALIASES` and the default country `United States` |
| **Adding a country the org allows** | add its ISO code to `DIAL_CODES` or it will be missing from the phone list |
| **A guest-callable method signature** | keep parameters primitive (§9.8); re-test anonymously; update the LWC call |
| **Anything the guest can call** | `DonorUpdatePortalController` is the **only** class in the guest profile — a new guest-callable class must be added there |
| **Static resource names** | `donorPortalShell.js` imports `sapaLogo` and `sapaHeroKids` by name |
| **`Portal_Base_Url` / site path** | every future link; the Experience site URL path prefix `update` |
| **New field on Account used by the guest** | the controller runs `SYSTEM_MODE`, so no guest FLS is needed — but staff need FLS (via profile/permission set) |
| **Sync flow `To_update_contact_Records`** | `protectPersonEmail` and the email tests |

---

## 14. Known limitations, open items, go-live checklist

**Go-live checklist (needs a person)**
- [ ] Activate the site (Setup → Digital Experiences → All Sites → SAPA Update Portal → Workspaces → Administration → Settings). Currently `UnderConstruction`.
- [ ] Change the **`Portal_Base_Url`** label to the production site URL (it hard-codes the sandbox).
- [ ] Replace the personal email on **site admin, guest record owner and email sender** with a shared SAPA user.
- [ ] Add **SAPA Portal Review** to an app's navigation (App Manager → SAPA → Edit → Navigation Items).
- [ ] Deploy the portal to production (classes, LWCs, fields + FLS, labels, tab, permission set, static resources, site/guest profile) and **assign** the permission set to Donor Care.
- [ ] Re-run the full test suite in production and a real anonymous-browser pass.

**Decisions still open**
- Keep the token after Accept/Reject so a reviewed link says "already sent" instead of "couldn't open this page" (small change).
- Mask phone/email on the page (currently shown in full to the link holder).
- Make `Portal_Token__c` read-only for Donor Care (they can read and edit it; `Portal_Link__c` also exposes the URL).
- Add Iran/Syria/Cuba/North Korea/US territories to the org's country picklist if those donors are expected.

**Accepted gaps**
- No Jest tests for the LWCs (no test infrastructure) — UI bugs like the disabled-option one are only caught by browser testing.
- The Campaign "Responded" step is untested with real data (the sandbox has no campaigns).
- Google Fonts load from Google (donor IP visible to Google); self-hosting would remove that.
- The country dropdown is a native select (type to jump), not a search box.
- The photo is 640 px wide; a clean original would look better.
- The one-time whole-site redeploy may have overwritten Builder edits made after the last retrieve — check the Home page.

**Later phase (per the brief)**
- **S9** — `InvitationSendJob`: a batch that selects donors, calls `PortalLinkService.assignTokens`, saves, and emails the links (and sets `Portal_Sent_Date__c`/`Portal_Campaign__c`). Needs a decision on which donors it targets.
- **S10** — rollout prep: dedupe, SPF/DKIM, per-tier config, dashboard.

---

## 15. Appendix

### 15.1 File map
| Path | What it is |
|---|---|
| `classes/DonorUpdatePortalController.cls` | guest entry point (`getPortalData`, `getAddressOptions`, `submitUpdate`) |
| `classes/DonorUpdateReviewController.cls` | staff list / Accept / Reject |
| `classes/PortalValidator.cls` | validation rules |
| `classes/PortalAddressNormalizer.cls` | picklist resolution + country/state options |
| `classes/PortalLinkService.cls` | tokens |
| `lwc/donorUpdatePortal`, `donorPortalAddressForm`, `donorPortalStatusPage`, `donorPortalShell`, `portalCountryData`, `donorUpdateReview` | UI |
| `staticresources/sapaLogo.png`, `sapaHeroKids.jpg` | branding |
| `permissionsets/Portal_Donor_Care_Review`, `customPermissions/Portal_Donor_Care_Review`, `tabs/Donor_Update_Review` | staff access |
| `profiles/SAPA Update Portal Profile` | guest permissions |
| `digitalExperiences/site/SAPA_Update_Portal1`, `sites/`, `networks/` | the site |
| `scripts/apex/generate-portal-link.apex` | issue a link |
| `sapa_portal_project.md`, `summary.md`, this `README.md` | documentation |

`scripts/apex/create-test-donor.apex` (creates/resets the five test donors) is referenced by the original build but is not in this local folder.

### 15.2 Salesforce DX basics (from the original template README)
- `force-app/main/default/` — metadata source; `config/` — scratch-org definitions; `scripts/` — helper scripts; `sfdx-project.json` — project manifest (`sourceApiVersion` 67.0; components use API 68.0).
- Prerequisites: Salesforce CLI, VS Code with the Salesforce Extension Pack, a development org.
- Common commands:
  - `sf org login web` — authorise an org · `sf org open` — open it · `sf org display` — show the connected org
  - `sf project deploy start` — deploy metadata · `sf project retrieve start` — retrieve metadata
  - `sf apex run -f <file>` — run anonymous Apex · `sf apex run test` — run tests
  - `sf data query -q "<SOQL>"` — query data · `sf community publish --name "<site>"` — publish an Experience Cloud site
- Docs: [Salesforce DX Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/) · [CLI Command Reference](https://developer.salesforce.com/docs/atlas.en-us.sfdx_cli_reference.meta/sfdx_cli_reference/)
