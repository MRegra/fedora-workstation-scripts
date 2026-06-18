# Ethical Bug Bounty Process

A reference for running responsible automated testing on Intigriti and Bugcrowd programs.

---

## Before You Start — Non-Negotiables

**1. Read the program policy in full, every time.**
Each program has its own rules. What's in-scope on one is out-of-scope on another.
Look for: scope, exclusions, prohibited tests, rate limit expectations, safe harbor clause.

**2. Verify the safe harbor clause exists.**
A safe harbor clause means the company promises not to pursue legal action for
good-faith testing within scope. If a program has no safe harbor, be very cautious.
Both Intigriti and Bugcrowd have platform-level protections, but program-specific
clauses give you extra coverage.

**3. Set scope.yaml before touching the orchestrator.**
The script enforces scope at the code level, but you are responsible for reading the
policy and configuring it correctly. A misconfigured wildcard can fire requests at
infrastructure that belongs to a third-party — not the program.

**4. When in doubt, ask.**
Both Intigriti and Bugcrowd have program-specific Q&A. If you're unsure whether an
asset or test type is allowed, ask before running. A 24h wait is worth avoiding a ban.

---

## Scope Discipline

| Rule | Why |
|---|---|
| Only test assets listed as in-scope | Testing out-of-scope can be illegal regardless of intent |
| Exclude explicitly excluded assets even if under a wildcard | Programs mean it |
| Never test third-party SaaS integrations | Even if reachable from the target, it's a different company |
| Don't follow redirects to out-of-scope domains | A redirect doesn't grant scope |
| Wildcards (`*.example.com`) cover subdomains, NOT the root | `*.example.com` ≠ `example.com` unless listed separately |

The orchestrator validates every target with `is_in_scope()` before any request.
If you add a domain manually to a command, apply the same check yourself.

---

## What You Can Test (Detection Only)

These are always appropriate within scope:

- **Subdomain enumeration** — passive DNS, certificate transparency logs, archive APIs
- **HTTP fingerprinting** — status codes, headers, tech stack, server versions
- **Nuclei template scanning** — pattern-based detection, no actual exploitation
- **Port scanning** — nmap at T3 or below, common ports only
- **URL discovery** — gau, waybackurls, web archiving lookups
- **CORS misconfiguration detection** — checking headers, not actually bypassing auth
- **Open redirect detection** — confirming the redirect exists, not chaining it for phishing
- **Information disclosure** — exposed `.git`, `.env`, backup files, error messages

---

## What You Must Never Do

- **DoS or load testing** — even "checking" if a server is vulnerable to DoS can cause DoS.
  Nuclei has DoS templates; they are NOT included in the default template set here.
- **Accessing real user data** — if you find an IDOR or auth bypass, confirm it exists
  with a minimal proof (your own test account), don't enumerate or dump actual user records.
- **Destructive actions** — no deleting, modifying, or corrupting data.
- **Social engineering** — bug bounty is technical only.
- **Testing from a botnet or shared IP** — if your IP gets flagged as malicious, it
  contaminates findings and may cause collateral to legitimate users sharing that IP.
- **Automated scanning during business hours** — respect the program notes. Run overnight
  (off-peak in the company's timezone). The `scope.yaml` has a notes field for this.
- **Reporting without verification** — automated tools produce false positives.
  Claude validates findings before a report is generated. Never submit nuclei output raw.

---

## Rate Limiting — Be a Good Citizen

Default settings in `scope.yaml` are conservative. Reduce further if:
- The program explicitly mentions rate limits in their policy
- The target is a small company (limited infrastructure)
- You're scanning a production service with real users

Recommended maximums if not specified:
- HTTP requests: 5–10 req/sec
- Nuclei: 20 concurrent (already the default)
- nmap: T3, never T4/T5 against bug bounty targets
- Always add 2s delay between switching hosts

If you accidentally cause an outage or trigger alerts, stop immediately and
notify the program through the platform before they have to find you.

---

## Data Handling

- Don't store screenshots of real user data, PII, or credentials you discover.
- If nuclei or a manual check surfaces real credentials or PII (e.g. an exposed `.env`),
  note the endpoint, close the response, and report it. Don't save the data.
- Delete `output/` after submitting reports — it may contain sensitive paths and endpoints.
- Don't share findings publicly or in Discord/Twitter before the program has fixed it and
  granted permission to disclose.

---

## Reporting Quality — What Gets Accepted vs Triaged Out

### Intigriti

Intigriti uses **CVSS v3.1** for severity and requires:

| Field | Notes |
|---|---|
| Title | Specific, descriptive. Bad: "XSS found". Good: "Reflected XSS in search parameter allows session theft" |
| Severity | Use CVSS calculator honestly. Don't round up. |
| CVSS vector | Include the full string, e.g. `CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:H/I:H/A:N` |
| Description | What is the vulnerability, not just the tool output |
| Steps to reproduce | Numbered, exact, reproducible by a stranger |
| Impact | Realistic. What can an attacker *actually* do? |
| Affected URL | Exact endpoint |
| Remediation | Concrete fix, not "add input validation" |

Common rejection reasons on Intigriti:
- Not reproducible (your steps don't work)
- Duplicate (search first)
- Out of scope
- No security impact (informational only)
- CVSS overstated (inflated severity)

### Bugcrowd

Bugcrowd uses a **P1–P5 priority system** (not CVSS directly, though CVSS informs it):

| Priority | Equivalent | Examples |
|---|---|---|
| P1 | Critical | RCE, auth bypass to admin, SQLi with data dump |
| P2 | High | Stored XSS, IDOR to other users' PII, SSRF to internal network |
| P3 | Medium | Reflected XSS, open redirect + phishing, CORS with auth |
| P4 | Low | Self-XSS, rate limit absent (no real impact), missing headers |
| P5 | Informational | Version disclosure, internal paths (no exploitability) |

Bugcrowd also requires a VRT (Vulnerability Rating Taxonomy) classification.
The Claude-generated reports include a severity recommendation — map it to P1–P5 yourself
before submitting, as only you know the full program context.

---

## Duplicate Avoidance

Before submitting, search the platform for similar reports:
- Intigriti: "Activity" tab on the program page shows your own, not others' — check the
  Hall of Fame for publicly disclosed issues
- Bugcrowd: Same — check disclosed reports
- Google the CVE or vulnerability pattern on the domain: `site:hackerone.com "example.com" XSS`

Duplicate submissions are not penalized on most programs but waste your time and theirs.

---

## Responsible Disclosure Timeline

1. Submit via the platform immediately after verifying the finding.
2. Give the program their stated SLA (usually 30–90 days) to fix before any public disclosure.
3. If they don't respond within the SLA, follow the platform's escalation path — don't go public unilaterally.
4. When the fix is confirmed, you can request permission to disclose (write-up, Hall of Fame).

---

## Reputation Building

Your track record on Intigriti and Bugcrowd is your currency:

- High signal-to-noise ratio (few duplicates/invalids) → programs invite you to private programs
- Private programs → newer, less-picked-over scope → higher chance of unique findings
- Quality reports → faster triage → faster payouts
- Good communication → long-term relationships with security teams

The orchestrator is a starting point for finding leads. Manual verification and
a well-written report are what get you paid. Automated tools find the surface;
you find the impact.
