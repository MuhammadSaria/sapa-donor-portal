# SAPA Donor Contact Details Portal — Build Log

Jira: SAPA-295. Org: `SAPA_STAGGING` sandbox (`sudaneseamericanphysiciansassociat--stripestag`, CLI alias `SAPA-STAGGING`). Source of truth for scope/rules: `docs/SAPA_PORTAL_PROJECT.md` (not in this folder). This file is a chronological record of what was built, what was found and fixed, how to test it, and what is still open — written for a handoff, not as the spec itself.

**Last updated:** 2026-10-26.

---

## 0. Where things stand (read this first)

| Area | Status |
|---|---|
| Donor-facing portal (S0–S8) | Built, deployed, **published** to the sandbox site, verified in a real anonymous browser |
| Staff review screen | Built, has its own **tab** (`SAPA Portal Review`) and permission set; **not yet added to an app's navigation** |
| Apex tests | **54 passing (100%)**. Coverage: DonorUpdatePortalController 98%, PortalValidator 96%, PortalLinkService 95%, PortalAddressNormalizer 93%, DonorUpdateReviewController 88% |
| Guest security | Guest profile has **one Apex class and nothing else** (no object, field or flow access) |
| Site status | Still **`UnderConstruction`** — not activated Live (deliberately left for a go-ahead) |
| S9 (email-sending batch), S10 (rollout prep) | **Not started** — marked "later phase" in the brief |

What the donor sees today: a SAPA-branded page (logo, kids photo background) with a read-only list of what is on file (✓ per item) and inputs for only what is missing — phone with a country-code selector, and/or an address with all 237 countries and a state dropdown where the org has states.

---

## 1. How this started

The brief defines a donor self-service portal: SAPA emails a donor a private tokenized link, the donor fills in missing phone/address, Donor Care reviews and Accepts/Rejects before anything touches the real donor record. Build order is S0 through S10, with S9/S10 explicitly "later phase".

Two open questions from the brief were resolved against the live org (not assumed):

- **Standard Person Account fields or Contact Point records?** → Standard Person Account fields (`PersonMailingStreet` etc., `Phone`, `PersonMobilePhone`). `ContactPointAddress`/`ContactPointPhone` are empty org-wide and unused by any Apex/Flow/LWC.
- **`Missing_Address__c` vs `Missing_Mailing_Address__c`:** the org already had `Missing_Mailing_Address__c` (and `Missing_Phone__c`) from an earlier attempt. The live formulas were reused as-is (see §4).

---

## 2. How the portal works (the rules)

1. A donor gets a private link: `Portal_Base_Url` label + `?token=` + a random 64-character token (`Portal_Link__c` formula). Valid 30 days (`Portal_Link_Validity_Days` label).
2. The page asks only for what is missing: phone if every phone field is blank; address if street, city or country is missing (US also needs state + ZIP).
3. On submit, values are held in `New_*` fields and `Portal_Status__c` becomes `Submitted`. **Nothing touches the real donor fields yet.**
4. Donor Care opens the review screen and clicks **Accept** (writes phone → `PersonMobilePhone`, address → `PersonMailingXxx`, stamps verified date, clears held values and token) or **Reject** (clears held values and token, stores the reason).

**What a donor sees when opening a link:**

| Link state | Page |
|---|---|
| Valid, not yet submitted | The form |
| Submitted, awaiting review | "You've already sent your details. Thank you." |
| After Accept or Reject | "We couldn't open this page" (the token is cleared, so the page cannot recognise the donor). Keeping the token until expiry would make this say "already sent" — a small change if wanted |
| Expired | "This link has expired" |
| Unknown / edited token | "We couldn't open this page" (same wording as any bad link, so nobody can probe which donors exist) |
| Request failed (network) | "Something went wrong" (deliberately different from a bad link) |

---

## 3. What was built, story by story (original build)

### S0 — Prepare sandbox
- `sfdx-project.json`, `.forceignore`; fields `Portal_Token__c` (Text(64), unique), `Portal_Token_Expiry__c`.
- `scripts/apex/create-test-donor.apex` creates/resets 5 test Person Accounts (`PortalTestComplete`, `PortalTestPhoneMissing`, `PortalTestAddressPartial`, `PortalTestBothMissing`, `PortalTestNonUS`). Their full names are `SAPA PortalTest...`.

### S1 — Data fields and labels
- `Portal_Status__c` (picklist: Sent, Submitted, Accepted, Rejected), `Portal_Link__c` (formula), `Portal_Sent_Date__c`, `Portal_Campaign__c`, `New_Street__c`/`New_City__c`/`New_State__c`/`New_Postal_Code__c`/`New_Country__c`, `New_Phone__c`, `Contact_Info_Verified_Date__c`, `Portal_Reviewed_By__c`, `Portal_Reviewed_Date__c`.
- Custom Labels: `Portal_Base_Url`, `Portal_Link_Validity_Days` (30), `Portal_Reason_Text`, `Portal_Invalid_Link_Message`.
- FLS granted explicitly to `Admin` and `Donor Care` profiles (the org does not auto-grant FLS on new fields).

### S2 — Token service
- `PortalLinkService` (+ test): `newToken()` = 256-bit random hex; `assignTokens(accounts)` (no DML — caller updates).

### S3 — Guest site and profile
- Experience Cloud site **"SAPA Update Portal"** (Build Your Own LWR), path `/update`. `UNAUTHENTICATED` auth is not supported in this org, so `AUTHENTICATED_WITH_PUBLIC_ACCESS_ENABLED` is used.
- Guest profile `SAPA Update Portal Profile`; CSP Trusted Sites for Google Fonts.

### S4 — Portal controller
- `PortalValidator` (pure validation), `DonorUpdatePortalController` (the **only guest-callable class**): `getPortalData(token)`, `submitUpdate(token, phone, street, city, state, postalCode, country)`.

### S5 — Donor page UI
- LWCs `donorPortalShell`, `donorPortalStatusPage`, `donorPortalAddressForm`, `donorUpdatePortal` (placed on the site's Home page).

### S6 — Review screen
- `DonorUpdateReviewController` (`with sharing`, gated by the `Portal_Donor_Care_Review` custom permission, checked server-side) and the `donorUpdateReview` LWC (standard SLDS — intentionally not SAPA-themed).

### S7 — Permission set
- `Portal_Donor_Care_Review` (custom permission + class access), assigned to `donorcare@sapa-usa.org.stripestag` and the sandbox admin.

### S8 — Backend end-to-end
- Full chain verified via Apex. (This was backend-only; it did not exercise a real guest.)

---

## 4. Org facts discovered (not obvious from the brief)

- **`Missing_Phone__c`** = Phone, PersonMobilePhone, PersonHomePhone **and** WorkPhone__c all blank.
- **`Missing_Mailing_Address__c`** = street, city or country code blank; if country is US, also state code or ZIP blank.
- **State and Country picklists are enabled and RESTRICTED** (237 active countries, 383 states). `PersonMailingState`/`PersonMailingCountry` accept only the picklist **label** (e.g. `Illinois`, `United States`). **`IL`, `USA`, `US`, free-text states and unknown countries are rejected** with `FIELD_INTEGRITY_EXCEPTION`.
- **Only 10 countries have a state list:** Australia, Brazil, Canada, China, India, Ireland, Italy, Japan, Mexico, United States. Every other country (including Sudan and Pakistan) has none.
- **The org's country list has no** Iran, Syria, Cuba, North Korea or US territories such as Guam. Adding them is a Setup change (State and Country picklists), not code.
- **`To_update_contact_Records`** (after-save flow on Account) derives `PersonEmail` from the donor's *preferred* email field (`Preferred_Email__c`: Personal/Work/Alternate) and `Phone` from the preferred phone. If that preferred field is blank, **any phone change blanks `PersonEmail`**. It also blanks `PersonEmail` on insert unless `Personal_Email__c` is set (matters for test data).
- **No FLS auto-grant** to System Administrator on new custom fields — every new field needs an explicit grant.
- **Two Person Account record types** exist; the sandbox has 27 person accounts and 0 campaigns.

---

## 5. Guest-context bugs found in the first real-browser pass

Apex tests and anonymous Apex run as an admin-equivalent user, so none of these showed up there.

| # | Symptom / cause | Fix |
|---|---|---|
| 1 | Guests could not query Account at all | Initially granted object/field access to the guest profile. **Later found unnecessary** because the controller uses `SYSTEM_MODE` — see §7 |
| 2 | Guests cannot see existing records without a sharing rule | `WITH SYSTEM_MODE` queries and `AccessLevel.SYSTEM_MODE` DML in the controller instead of a sharing rule |
| 3 | `FOR UPDATE` + `WITH SYSTEM_MODE` on one query broke formula fields for guests | Split into a lock query and a separate read query |
| 4 | A nested Apex wrapper type did not deserialize as a method **parameter** for guests | `submitUpdate` takes seven plain String parameters |
| 5 | "Stale LWR bundle" (original diagnosis) | **Re-diagnosed:** the live site was already serving the new code. The "nothing happens on submit" symptom was most likely the bugs in §6 (server-side address errors were never shown, and phone-only submits were rejected) |

---

## 6. Full review and fixes (2026-10-26)

A full review of code, permissions and the live org found these defects. **Each was reproduced against the live sandbox** (inside rolled-back savepoints) before being fixed.

**Bugs that stopped real donors**
- **Accept failed for every US address.** The form sent `IL`; the restricted picklist rejects codes. Fixed with full state names in the form and a new `PortalAddressNormalizer` that resolves codes/aliases (`IL`→`Illinois`, `USA`→`United States`) against the org's real picklists, at submit **and** again at Accept (so older rows are repaired). Unrecognised values give field errors instead of leaving a row stuck.
- **A donor missing both phone and address could not submit just a phone.** The form always sent a default country, which the server counted as "address started". Country alone no longer counts, and the form only sends the address if the donor edited it.
- **Server field errors were never displayed** (only phone and a form-level message were). Errors now show on the fields with a summary banner.
- Smaller form bugs: "Other" country snapped back to blank; prefilled countries/states not matched; first click on Submit swallowed (`onchange` → `oninput`); a failed load showed "invalid link".

**Review screen**
- Accept: readable errors, "already reviewed" message when two staff click the same row (`FOR UPDATE`), no rollback when a campaign lacks a "Responded" status, `PersonEmail` protection now writes only to the donor's *preferred* email field and only when empty (it used to copy the email into `Personal_Email__c` for everyone).
- New fields `Portal_Submitted_Date__c` (accurate submitted date) and `Portal_Reject_Reason__c` (the reason is now stored). Queue capped at 200 with a notice.

**Security and housekeeping**
- Guest profile stripped (§7). `getPortalData` no longer `cacheable=true` (PII keyed by a secret token, served via CDN-enabled network).
- `assignTokens` now resets status to `Sent` and clears earlier-round values, so a re-sent link works.
- Server-side phone character and field-length validation. Page title changed from "Welcome to LWC Communities!" to "SAPA - Update Your Contact Details", with `noindex`.

---

## 7. Permissions (current, verified live)

**`SAPA Update Portal Profile` (Guest User License):**
- Apex class access: **`DonorUpdatePortalController` only.**
- Object permissions: **none** (Account/Contact Read was removed). Custom portal field grants: **none** (all 12 revoked).
- Flows: none. The controller works for an anonymous guest with no object access because it runs in `SYSTEM_MODE`.
- Not changed: ~972 default boilerplate `FieldPermissions` rows Salesforce creates on a fresh guest profile. They are inert with zero object permissions; the decision to accept and document them stands.
- Site settings: guest file access off, guest Chatter off, self-registration off.
- Local file `force-app/.../profiles/SAPA Update Portal Profile.profile-meta.xml` mirrors the 12 revoked fields but never carried object permissions; the live org is the source of truth.

**`Portal_Donor_Care_Review` permission set:** custom permission, class access to `DonorUpdateReviewController`, field access to the two new fields, and visibility of the `Donor_Update_Review` tab.

---

## 8. UI/UX work (2026-10-26)

- **Branding:** real SAPA logo (`sapaLogo` static resource, PNG, replaced the placeholder SVG); kids photo background (`sapaHeroKids` static resource) on the form **and** on the thank-you / error screens, with a dark fade so text stays readable; footer with the organisation name; responsive down to phone width.
- **Photo source:** cropped from the SAPA website hero screenshot (the original had baked-in headline text, a "Donate Now" button and a scrollbar). The crop is only 640px wide — fine in this layout, soft if used full-screen. A clean original would look better.
- **Form:** card layout with soft shadows; larger inputs with focus rings; submit button shows "Sending…"; mobile keyboard and browser-autofill hints; reduced-motion respected; status icons are green for good outcomes and orange for ones needing action.
- **Page edge-to-edge:** the shell pulls out over the 16px padding that the Experience Builder section adds, and forces white link colours that the site theme otherwise turns blue.

---

## 9. Details on file, countries, and phone codes (latest work)

- **Read-only "What we have" card:** every item has a ✓ (green) when on file, or an orange **!** with "Not on file yet" / "Incomplete" when missing, next to its real value (name, email, phone, address). A line says "To change anything shown here, please contact SAPA Donor Care." *Privacy note:* anyone with the link sees the full phone and address; masking (`••• ••• 0001`, `s***@example.com`) is a small change if wanted.
- **All countries, dependent states:** new guest-safe `getAddressOptions()` (reference data only, cacheable) returns every active country with its states, read from the org's own picklists, so the form always offers exactly what the donor record accepts. The state field appears only for the 10 countries that have states; postal code is required only for US. The old free-text "Other country" box is gone. A test confirms every offered country/state passes the normalizer.
- **Phone with country code:** the donor picks the code first (list: United States, Canada, United Kingdom, Sudan under "Common", then "All countries" A–Z), then types the number. Stored as `+<code> <number>` (e.g. `+249 912345678`); a leading trunk zero is dropped outside North America. Rules: `+1` needs exactly 10 digits after the 1; other countries 8–15 digits in total; numbers without a `+` (older submissions) keep the 10-digit rule. Dial codes live in the `portalCountryData` LWC (the org has no dial-code data); country names come from the org so the phone and address lists agree.
- **Bug found and fixed in this feature:** the phone dropdown could not be changed from US because **all 238 options had a `disabled` attribute** (`disabled={opt.disabled}` with `false` still renders the attribute on `<option>`). Fixed by removing the binding and using `<optgroup>` headings. The earlier verification set the value from script, which bypasses `disabled`; the fix was confirmed with real key presses (trusted `change` events) and a full Sudan submit.

---

## 10. How to test

**Generate a link for one donor** — `scripts/apex/generate-portal-link.apex` takes an **Account Id** (from the record URL), validates it (must be an existing Person Account), issues a fresh token (status `Sent`, clears an earlier submission), and prints `PORTAL LINK https://...`. Set `save = false` to rehearse without changing anything.
```
sf apex run -f scripts/apex/generate-portal-link.apex -o SAPA-STAGGING
```
(or paste into Developer Console → Debug → Open Execute Anonymous Window).

**Or copy `Portal_Link__c`** from an existing test donor:

| Test donor (`SAPA PortalTest...`) | Page shows |
|---|---|
| PhoneMissing | phone only |
| AddressPartial | address only (prefilled with street/city) |
| BothMissing | phone and address |
| Complete | read-only, nothing to fill in |
| NonUS | read-only, UK address |

A link works once; after Accept/Reject (or Submit) it is spent — run the script again for the same donor. No emails are sent (S9 is not built).

**Automated:** `sf apex run test --tests DonorUpdatePortalControllerTest --tests DonorUpdateReviewControllerTest --tests PortalLinkServiceTest --tests PortalValidatorTest --tests PortalAddressNormalizerTest -o SAPA-STAGGING` (54 tests).

**After changing LWCs, always publish** (`sf community publish --name "SAPA Update Portal" -o SAPA-STAGGING`) — LWR sites serve the published bundle, not the draft a deploy updates — then hard-refresh.

---

## 11. Lessons learned

1. **Apex tests do not exercise guest behaviour.** They run as an admin-equivalent user. Guest-facing work needs a separate real anonymous-browser (or anonymous HTTP) check.
2. **Scripted values are not user input.** Setting a `<select>`'s value from code skips `disabled` and focus rules; test interactive controls with real key/mouse events.
3. **Test with the real form's values** (state codes, default country), not convenient ones — the original tests used `'Illinois'` and passed while the form sent `'IL'`.
4. **Passing tests ≠ working donor flow.** Server-side errors that the UI never shows look like "nothing happens".
5. **Restricted picklists reject plausible values** (`IL`, `USA`). Anything stored for later write-back must be validated against the picklist when it is *stored*, not when it is applied.
6. In LWC templates, `disabled={false}` on `<option>` renders a real `disabled` attribute; use a different structure instead.

---

## 12. What's open

**Needs you, not code**
1. **Activate the site to Live** (still `UnderConstruction`).
2. **Add "SAPA Portal Review" to an app's navigation** (App Manager → SAPA → Edit → Navigation Items); until then Donor Care finds it via App Launcher search.
3. **Production-facing settings:** `Portal_Base_Url` label hard-codes the sandbox URL (change before production); `siteAdmin`, guest record owner and email sender are one person's address — use a shared user.
4. **Decisions pending:** keep the token after review so the link keeps saying "already sent"; mask phone/email on the page; make `Portal_Token__c` read-only for Donor Care (they can currently read and edit it; `Portal_Link__c` also exposes the full URL to anyone who can read the donor).
5. **Optional org change:** add missing countries (Iran, Syria, Cuba, North Korea, US territories) to the State and Country picklists if donors there are expected.
6. **Sensitive data on the page:** confirm you are comfortable that the full phone and address are shown to the link holder.

**Known, accepted gaps**
7. **No Jest tests** for the LWCs (no test infrastructure exists), so UI regressions like §9's `disabled` bug are only caught by browser testing.
8. **CampaignMember → "Responded" on Accept** has no real-data test (the sandbox has no campaigns). The code now checks the status exists first and never fails the Accept.
9. Google Fonts are loaded from Google (donor IP visible to Google); self-hosting would remove that.
10. The country list is a native dropdown (type the first letters to jump), not a search box.
11. Photo is 640px wide (see §8).
12. The whole Experience Builder site bundle was redeployed from the local copy once (to change the page title); if Builder edits were made after the last retrieve they could have been overwritten — worth a quick look at the Home page.

**Later phase (per the brief)**
13. **S9** — `InvitationSendJob`, the batch that issues tokens and emails donors (the helper `PortalLinkService.assignTokens` and the status reset it does are ready for it). Needs a decision on which donors it targets (all with missing data, or a Campaign).
14. **S10** — rollout prep: dedupe, SPF/DKIM, per-tier config, dashboard.

---

## 13. File map (key files)

- Apex: `DonorUpdatePortalController`, `DonorUpdateReviewController`, `PortalLinkService`, `PortalValidator`, `PortalAddressNormalizer` (+ `...Test` classes).
- LWC: `donorPortalShell`, `donorPortalStatusPage`, `donorPortalAddressForm`, `donorUpdatePortal`, `portalCountryData` (dial codes), `donorUpdateReview` (staff).
- Static resources: `sapaLogo` (PNG), `sapaHeroKids` (JPG).
- Metadata: tab `Donor_Update_Review`, permission set `Portal_Donor_Care_Review`, custom permission of the same name, fields on `Account` (see §3 and §6), custom labels (S1), site `SAPA_Update_Portal1`.
- Scripts: `scripts/apex/generate-portal-link.apex`, `scripts/apex/create-test-donor.apex` (the latter is referenced by the original build but is not present in this local folder).
- Note: this local folder is a metadata retrieve; it has no `docs/` folder and no Account object metadata (the portal's Account fields exist in the org and in the two field files added this session).
