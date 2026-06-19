# The 1-Hour Daily Routine

The automation hunts overnight. Your job is to be the judge, the writer, and the queue manager.
Do not try to hunt manually — the automation outpaces you on volume. Your edge is judgment.

---

## The 60-Minute Breakdown

### 00:00 – 05:00 | Check what came in (5 min)

```bash
python3 morning-review.py --dir output/ --platform intigriti
```

Read the ranked list. Look for:
- Severity HIGH or CRITICAL
- PoC: YES
- Category IDOR, auth, sqli, ssrf, logic — these pay the most

**Decision rule:** If top finding is HIGH/CRITICAL + PoC confirmed → submit it today.
If top finding is MEDIUM → decide based on your current platform standing. Early on, submit anyway.
If everything is LOW or info → skip submission today, adjust scope (bigger targets), queue a re-run.

---

### 05:00 – 25:00 | Polish the #1 finding (20 min)

```bash
python3 polish-report.py --dir output/ --rank 1 --platform intigriti
```

Claude Opus rewrites the automation draft into a platform-ready report. While it runs (~2 min),
open the draft in `output/reports/` yourself and read it.

When the polished version prints:
1. Read every line. Claude may miss context you noticed during the run.
2. Add any manual observations: "I noticed the endpoint also accepts `admin_id` parameter..."
3. Verify the CVSS vector (Intigriti) or VRT path (Bugcrowd) looks right.
4. Save it: add `--out ~/Desktop/submit-today.md` to the command.

---

### 25:00 – 45:00 | Submit (20 min)

Open the platform. Paste the report. Fill in the form fields:
- **Intigriti:** Title, CVSS v3.1 score + vector, asset (pick from their list), steps, attachments
- **Bugcrowd:** Title, VRT category (drill down the tree), target, description, PoC attachment

Attach screenshots from `output/screenshots/` if relevant.

**Submit.** Do not second-guess after submitting — move on.

If you have a second strong finding (rank 2, also HIGH + PoC), polish and submit it too.
Two reports in one session is the target on good nights.

---

### 45:00 – 55:00 | Queue tonight's run (10 min)

Pick tomorrow's target. Rotation rules:
- Never run the same program two nights in a row (duplicates catch up to you)
- Prefer programs you haven't run in 7+ days
- Mix: 2 nights per week on your main program, 3 nights rotating others

```bash
# Edit scope.yaml for tonight's target
$EDITOR scope.yaml

# Launch and detach
bash nightly-launch.sh scope.yaml
```

Then check that it started:
```bash
tail -f nightly.log
# Ctrl+C after you see "Phase 1: recon started"
```

---

### 55:00 – 60:00 | Log what you submitted (5 min)

Keep a simple submission log. A plain text file is fine:

```
2026-06-18  IDOR /api/v2/invoices/{id}  HIGH   Intigriti / ExampleCorp   PENDING
2026-06-17  CORS misconfiguration       MEDIUM  Bugcrowd / OtherCo        ACCEPTED $300
```

This lets you track:
- Open rate (accepted vs. not applicable vs. duplicate)
- Which programs are worth re-running
- Patterns in what you're finding (→ adjust nuclei templates or browser modes)

---

## Weekly Rhythm (5 programs active)

| Night | Program | Notes |
|---|---|---|
| Mon | Program A | Main program, wide scope |
| Tue | Program B | Newer launch, less competition |
| Wed | Program A | Re-run after 2 days — different paths |
| Thu | Program C | Different vertical, keeps skills varied |
| Fri | Program D | End of week — submit anything pending |
| Sat | Program E | Weekend = slower triage, don't waste your best findings |
| Sun | No run | Review the week, update programs list |

---

## What to Do When the Queue Is Empty

Some nights the automation finds nothing worth submitting. Don't force it. Instead:

**Option 1: Widen the scope.** Add more subdomains to `in_scope.domains`, increase `max_hosts`
in browser config.

**Option 2: Add a new program.** Browse Intigriti/Bugcrowd for programs with:
- Wide scope (wildcard domains preferred)
- Launched in the last 90 days
- "Active" badge (rapid triage response)
- No mention of "heavily tested" in program notes

**Option 3: Deepen on an existing finding.** Sometimes a finding needs one more manual step
to go from MEDIUM to HIGH. Spend the 60 minutes in the browser manually chaining it.

---

## When You Get a Finding Closed as Duplicate

Duplicates are information. They tell you:
- That endpoint is actively tested — move on
- What *kind* of bug other researchers find there — pivot to adjacent areas

Do not resubmit. Do not argue. Note the endpoint as seen and move to a different attack surface.

---

## When a Triager Asks for Clarification

Reply within 24 hours. Keep it short:
- "Here is the additional HTTP request you asked for: [request]"
- "Reproduced on account [username]. The resource ID format is [format]."

A slow or absent response on a clarification request is one of the top reasons valid bugs get
closed. Set a calendar reminder when you submit.

---

## Pacing to 3–5 Reports Per Week

| Week | Target | How |
|---|---|---|
| 1–2 | 1 report/week | Get pipeline working, first accepted report |
| 3–4 | 2 reports/week | Polish speed improves, second program active |
| 5–8 | 3 reports/week | Rhythm established, pattern recognition |
| 8–12 | 4–5 reports/week | Multiple programs, private invites starting |

The bottleneck shifts over time:
- Weeks 1–4: **pipeline setup** (automation config, scope files, test accounts)
- Weeks 5–8: **report quality** (getting accepted rate up)
- Weeks 8+: **program selection** (private programs have less competition)

---

## Signs You Should Adjust

| Signal | Adjustment |
|---|---|
| >50% of findings are duplicates | Switch to newer/less-popular programs |
| <10% acceptance rate | Report quality issue — re-read polished output more carefully |
| Only finding LOW/info | Scope too narrow, or target too hardened — rotate programs |
| Browser agent times out on every host | Scope too many hosts — reduce `max_hosts` to 5 |
| Missing obvious bugs manually | Add those test patterns to browser system prompt |

---

## The Only Rule

**Review every polished report yourself before submitting.** The automation finds the bug.
Claude polishes the prose. But *you* own the submission. A false PoC or wrong CVSS score
damages your platform reputation, which is harder to rebuild than it is to protect.

One strong accepted report beats five hasty duplicates. Always.
