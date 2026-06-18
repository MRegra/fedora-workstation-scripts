# Getting Private Program Invites on Intigriti and Bugcrowd

Private programs pay 2–5× more than public programs for equivalent bugs, have fewer duplicate
submissions, and often have less-hardened targets. Getting invited is the single highest-leverage
thing you can do to increase earnings.

---

## How Invites Work

Private programs are invitation-only. The platform algorithm (and sometimes program owners
directly) selects researchers based on reputation signals. You do not apply — you get selected.

Both platforms share the same underlying logic: **valid, high-quality, timely reports build
reputation. Everything else is noise.**

---

## Intigriti

### Reputation System

Intigriti uses a public reputation score visible on your profile. Points are awarded per report:

| Outcome | Points |
|---|---|
| P1 (Critical) accepted | ~150 pts |
| P2 (High) accepted | ~100 pts |
| P3 (Medium) accepted | ~50 pts |
| P4 (Low) accepted | ~20 pts |
| Report accepted with bonus | Extra pts |
| Report closed as duplicate | 0 pts |
| Report closed as not applicable / informational | 0 pts |
| Report retracted by you | 0 pts |

Reputation decays slowly over time, so you need to keep submitting.

### What Triggers Invites

- **Reputation score above ~500** is where most private invite traffic starts.
- **Activity in the last 30 days** — inactive researchers stop receiving invites even with high scores.
- **Reports on the specific program's industry vertical** — if you find bugs in SaaS, programs
  targeting SaaS companies prefer researchers with a track record there.
- **Hall of Fame placement** — some programs use HoF performance as an invite criterion.
- **Direct outreach from program owners** — rare, but happens when a researcher's public reports
  demonstrate relevant expertise.

### Fastest Path on Intigriti

1. **Start on high-volume public programs with wide scope.** Wide scope = more attack surface =
   more chances to find something. Avoid tiny programs with 2 domains.

2. **Target P3 bugs first for volume.** You need a track record. Medium-severity findings
   (exposed config files, CORS misconfiguration, subdomain takeover candidates) are faster to
   find and build your number of accepted reports.

3. **Once you have 5+ accepted reports, focus on P1/P2.** Logic bugs and IDOR — the automation
   in this repo helps here. Each accepted P1 jumps your score significantly.

4. **Submit to programs that recently launched.** New programs on Intigriti often have lower
   duplicate rates and more surface to find. Watch the "New Programs" section.

5. **Leaderboards matter.** Top-10 on a program's leaderboard almost always triggers a private
   invite when that company launches a private program or opens one to the next tier.

6. **Engage in the community.** Intigriti runs events (live hacking events, webinars). Attending
   and placing in events is a fast track to direct researcher relationships with program managers.

### Intigriti Live Hacking Events

Intigriti runs periodic live hacking events (LHEs) — typically 2-3 days, in-person or virtual,
with 30–150 researchers on a single target. These are invitation-only but the bar is lower than
private programs: a handful of accepted reports qualifies you. LHE findings pay above-market
bounties and program owners are present to answer questions.

Getting into an LHE is often the fastest route to a private program invite afterward.

---

## Bugcrowd

### Reputation System (Bugcrowd Points / Star Rating)

Bugcrowd uses a point system tied to a researcher "star level" (1–7 stars). Star level is the
primary invite filter.

| Payout tier | Points awarded |
|---|---|
| P1 (Critical) | ~20 pts |
| P2 (High) | ~10 pts |
| P3 (Medium) | ~5 pts |
| P4 (Low) | ~1 pt |
| P5 (Informational) | 0 pts |

Points decay: the system weights recency. Older submissions count for less.

### Star Levels and What They Unlock

| Stars | Approximate points | What unlocks |
|---|---|---|
| 1 | 0–49 | Public programs only |
| 2 | 50–299 | Some lower-tier private programs |
| 3 | 300–999 | Most private programs in your vertical |
| 4 | 1,000–4,999 | Elite private programs, early access |
| 5 | 5,000–19,999 | Priority invite list for all programs |
| 6–7 | 20,000+ | Ambassador status, direct partnership |

Most researchers report that **3 stars** is where private invite flow becomes consistent.

### What Triggers Invites on Bugcrowd

- **Signal score (accuracy rate)** matters as much as total points. A researcher with 80%
  acceptance rate at 3 stars gets more invites than one at 3 stars with 40% acceptance.
  Submit fewer, better reports.
- **VRT alignment** — Bugcrowd's Vulnerability Rating Taxonomy is the taxonomy programs use
  to classify. Learning the VRT categories and matching your report to the correct one speeds
  triage and increases your acceptance rate.
- **Program-specific performance** — some programs hand-select researchers from public reports.
  Finding a critical on a public Bugcrowd program often results in a direct invite to their
  private program.
- **Bugcrowd University completion** — free training, signals commitment to the platform.

### Fastest Path on Bugcrowd

1. **Complete Bugcrowd University.** It's free, short, and signals seriousness.
2. **Pick programs with "Well-scoped" and "Active" badges.** These have faster triage and
   better acceptance rates.
3. **Learn the VRT cold.** Mislabeled reports get downgraded. The automation in this repo
   generates Bugcrowd-format reports but you should review the VRT category before submitting.
4. **Target programs with recent activity** (last triaged < 7 days). Stale programs have
   slow triage — bad for morale and accuracy feedback.

---

## Platform-Agnostic Strategies

### Choose Programs Strategically

Not all programs are equal. Before picking a target:

- **Check duplicate rate.** Programs with hundreds of public reports on their Hall of Fame
  have been hammered. Newer or niche programs have more open surface.
- **Check average payout vs. declared range.** Some programs declare $10,000 for P1 but
  habitually pay $500. Check researcher forum posts.
- **Prefer programs with large scope.** More domains = more chance of something being missed.
- **Avoid programs that list "out of scope" longer than "in scope."** The scope restrictions
  often reflect "we've been hammered here" — there's less left.

### Build a Specialization

Private programs prefer specialists. Pick one or two of these and go deep:

- **Web/API security** — IDOR, auth bypass, business logic (highest payout/effort ratio)
- **Mobile** — iOS and Android binary analysis, deep links, certificate pinning bypass
- **Cloud misconfigurations** — AWS S3, Azure blobs, GCP buckets, IAM misconfigurations
- **Code review** — source code disclosed in public repos, dependency confusion

This repo's automation is optimized for **Web/API security** — the highest-paying specialization
for automation-assisted hunting.

### Report Quality is Your Moat

Automation gets you to the finding. Report quality is what separates $500 from $5,000 payouts
and what builds platform reputation.

Every report you submit should include:
- **Title:** Clear, impact-first. "Unauthenticated user can read any customer's invoices via
  IDOR in /api/v2/invoices/{id}"
- **Impact:** One paragraph, business-level. What can an attacker do? What data is exposed?
- **Steps to reproduce:** Numbered, copy-pasteable. Triager should be able to repro in under
  5 minutes.
- **PoC:** Screenshot, HTTP request, or curl command showing the actual impact.
- **Suggested CVSS** (Intigriti) or **VRT category** (Bugcrowd).
- **Suggested remediation:** Optional but appreciated and signals seniority.

### Avoid Reputation Damage

These behaviors get researchers deranked or banned:

- Submitting duplicates you know are duplicates
- Submitting informational/borderline findings at P1 severity
- Testing out-of-scope assets even once
- Social engineering or phishing during testing
- Disclosing findings before disclosure window closes
- Aggressive/rude communication with triagers

One banned account can mean years of reputation gone. Not worth it.

---

## Timeline: Public → Private

Realistic timeline assuming 15–20 hours/week active hunting + overnight automation runs:

| Week | Milestone |
|---|---|
| 1–2 | First 2–3 P4/P3 reports submitted |
| 3–4 | First accepted P3, reputation starts building |
| 5–8 | 5–10 accepted reports, first P2 candidate |
| 8–12 | ~500 Intigriti pts or Bugcrowd 2 stars |
| 10–16 | First private program invite |
| 16–24 | Multiple private programs, consistent P2 income |

Private programs are worth waiting for. Patience on the public grind pays back 3–5× when
you get access.

---

## Resources

- Intigriti Blog: researcher stories and technique write-ups
- Bugcrowd Researcher Hub: platform guides and VRT reference
- HackerOne Hacktivity: public disclosed reports (even if you hunt elsewhere, this is the
  best source of technique patterns)
- PortSwigger Web Security Academy: free labs covering every vulnerability type in this repo
- NahamCon, DEF CON CTF: events that build reputation and skills simultaneously
