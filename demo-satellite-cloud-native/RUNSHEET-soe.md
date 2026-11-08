# Run Sheet — Satellite as the Basis of a Standard Operating Environment

**Audience:** network architecture team at a telco
**Length:** 25 minutes
**Profile:** `.env.soe` on this workstation (libvirt, no Capsule, no IdM)

The customer asked for two things in their own words: Satellite as a tool for
content versioning across RHEL *and* non-RHEL, and what content promotion looks
like from a user's point of view. They have a stated ambition to build an SOE
and run it with Ansible Automation Platform. This run sheet is built around
those three sentences and nothing else.

---

## 1. What is actually demonstrated

| # | Claim | How it is shown | Where |
|---|---|---|---|
| 1 | Dev → QA → Prod is a real pipeline, not a diagram | A promotion the audience watches complete | UI, then CLI |
| 2 | A host's content is determined by its environment | `dnf` on lc-dev, lc-qa, lc-prod — three answers, one content view | CLI on the hosts |
| 3 | A non-RHEL host is a second-class citizen | Same REX job: runs on RHEL, undeliverable to CentOS Stream | UI + CLI |

### What is *not* demonstrated, and must be said rather than shown

- **Image mode / bootc.** This is the modern direction for exactly this
  problem and the honest framing for an SOE conversation in 2026. There is
  nothing usable for it in this lab. **Speak it, do not attempt it.** Suggested
  wording is in §6.
- **Red Hat base content.** This Satellite has no subscription manifest, so it
  carries no RHEL BaseOS/AppStream repositories. The lifecycle pipeline runs on
  a custom product (`Demo-App`) instead. The mechanism — content view, version,
  environment, activation key — is identical; only the payload differs. If
  asked: *"the same screens, pointed at the Red Hat CDN instead of our own RPM;
  syncing BaseOS and AppStream is about 40 GB and a few hours, so this lab uses
  a package we build in front of you."* Do not claim RHEL errata are being
  promoted. They are not.
- **AAP integration.** Spoken only. Section 6 has the bridge.

---

## 2. Before the meeting

### The day before — everything slow lives here

All of this is re-runnable and none of it is needed live.

```bash
cd ~/git/rh-demos/demo-satellite-cloud-native
cp .env.soe.sample .env.soe && $EDITOR .env.soe   # RHSM org + activation key
./scripts/deploy-soe.sh --check                   # ~10 seconds, changes nothing
./scripts/deploy-soe.sh                           # the long one
```

| Phase | What it does | Honest duration |
|---|---|---|
| 0 | Pre-flight | < 1 min |
| 1 | libvirt host setup, CentOS image download | 2–10 min |
| 2 | Satellite VM install | **70–150 min** |
| 3 | `c1`: pipeline + lc-dev/lc-qa/lc-prod | 25–40 min |
| 4 | `e1`: CentOS client registers, installs `soe-agent` | 10–15 min |

**Total 2–3.5 hours.** Start it in the morning or over lunch, not an hour
before. Phase 2 dominates and is mostly `dnf install satellite` plus
`satellite-installer` on 12 GB with `--tuning development`.

The entitlement is checked about 10 minutes in, at the repository checkpoint —
a key that does not entitle `satellite-6.19-for-rhel-9-x86_64-rpms` fails there
with the installer log, not at the 80-minute timeout.

If you run out of evening, `--infra-only` stops after the Satellite and
`--clients-only` picks up the next morning (phases 3–4, ~40 min).

### Dry run, the day before

Run the whole thing once end to end. It is idempotent; every step either
already exists or re-publishes harmlessly.

```bash
source .env.soe && export DEMO_ENV_FILE=.env.soe
./scripts/demo-scenarios.sh c2     # ~6 min — the act you actually present
./scripts/demo-scenarios.sh e2     # ~4 min
```

After the dry run every host is on v2.0. Do not reset that with `c1`.
`c1` republishes content; it does not downgrade an installed package, and
`dnf update` will not go backwards. The next showing is the same script
with a higher version. See [Running the rollout again](#running-the-rollout-again).

### Running the rollout again

`c2` publishes whatever version you give it and walks that version
Dev → QA → Prod. The default is `2.0`, which is only right the first time.

```bash
./scripts/demo-scenarios.sh c2 3.0
```

`3.1`, `4.0`, or plain `3` all work. The number has to be an RPM version
**higher than the one already installed** on the lifecycle hosts. `dnf`
will not move a host from 3.0 back to 2.0, and publishing a version the
hosts already have makes Dev and Prod both report "Nothing to do".

The first line of output must be:

```text
Profile: .env.soe  platform: libvirt  host: localhost  satellite: satellite.demo.lab
```

If it names `loki.veverak.net`, the local Satellite VM is not running and
the script has refused to use the remote profile in `.env`. Start the VMs
(below) and run it again. No `source .env.soe` is required while that VM
is up.

Press `a` at each step. Dev moves to the new version. Prod stays on the
old one until you promote, which is the point of the act. Then QA, then
Prod.

If Dev says "Nothing to do", that version is already installed. Pick a
higher number and run the command again. Publishing twice is harmless; it
just adds another content view version.

### 30 minutes before

```bash
# 1. Free the RAM. This is the single biggest live risk.
#    18.4 GB of guests on a 30 GB machine leaves ~11 GB for everything else.
#    Close Slack, Teams, every IDE, and all browser windows except one.

# 2. Bring the lab up (if it was shut down)
for V in satellite lc-dev lc-qa lc-prod centos; do
  virsh -c qemu:///system start $V 2>/dev/null
done
sleep 180   # the Satellite needs ~3 min of service start-up after a boot

# 3. Prove it is alive
source .env.soe && export DEMO_ENV_FILE=.env.soe
./scripts/verify-registration.sh
run_on_vm satellite "sudo satellite-maintain service status --brief" 2>/dev/null | tail -20
```

**Checklist — do not walk into the room until all five are true:**

- [ ] `virsh -c qemu:///system list` shows 5 running VMs
- [ ] `https://satellite.demo.lab` loads in the browser and you are logged in
- [ ] `free -g` shows at least 2 GB available. On this 30 GB machine the five guests leave about 1 GB free and fill the swap while Chrome, Slack and an IDE are open. Close those before you start, or the OOM killer will pick a qemu process.
- [ ] `hammer host list` shows lc-dev, lc-qa, lc-prod and centos
- [ ] Screen sharing is already running and the font is large

### Screen layout

Two windows, pre-arranged, no alt-tabbing to find things:

- **Browser**, full screen, already on
  `https://satellite.demo.lab/content_views` and **already logged in**.
  Have a second tab open on **Hosts → All Hosts**.
- **Terminal**, large font (18pt+), `cd`'d into the demo directory with
  `source .env.soe && export DEMO_ENV_FILE=.env.soe` already done.

  `DEMO_ENV_FILE` matters: `demo-scenarios.sh` only reads an env file when
  `DEMO_PASSWORD` is unset, and its default is `.env` — the *remote KVM*
  profile. Exporting it makes the target unambiguous whatever the shell state.

---

## 3. The 25 minutes

Times are cumulative. The script is `./scripts/demo-scenarios.sh`, which pauses
before each step and offers `[a] auto-run / [m] I'll do it in the GUI / [s]
skip`. **You drive the pacing with that prompt** — it is designed for exactly
this.

### 0:00 – 2:00 · Framing (no screen, or one static screen)

> "You want a standard operating environment, and you want to run it with
> Ansible Automation Platform. Those are two different problems. AAP decides
> *what should be true* on a machine. Something else has to decide *what
> software that machine is even allowed to see*. That second thing is what I
> want to show you for the next twenty minutes.
>
> Three things: how content moves from Dev to Prod, what a host actually
> receives in each of those, and where it stops working when the host isn't
> RHEL."

Do not open a slide. Go to the browser.

### 2:00 – 7:00 · Act 1 — The pipeline is real

**Show in the UI.** This act is visual; the CLI adds nothing here.

1. **Content → Lifecycle Environments.** The Library → Dev → QA → Prod chain.
   > "An environment is not a label on a server. It's a gate that content has
   > to be promoted through."

2. **Content → Content Views → `RHEL9-FullStack`.** Open it, go to **Versions**.
   > "This is a composite — a RHEL baseline plus our own application content,
   > versioned together as one thing. That versioned thing is the SOE."

3. **Promote, and let them watch it.** Versions tab → the latest version →
   **Promote** → tick **QA** → Promote.
   Stay on the task progress page until it goes green. Say nothing for the
   five seconds it takes. Letting a progress bar finish in silence is the
   whole point of this act.

> "Nothing was installed anywhere. I moved a pointer. Every host in QA will
> see different packages the next time it asks."

**Timing valve:** if the promote task is slow, narrate the **Content →
Activation Keys** list while it runs — `rhel9-lc-dev` / `-qa` / `-prod`, each
pinned to one environment and one content view. That is 60 seconds of real
content, not filler.

### 7:00 – 15:00 · Act 2 — What a host actually gets

**Switch to the terminal.** This is the act they asked for — "how content
promotion looks from a user's point of view" — so it has to happen on the hosts,
not in the UI.

```bash
./scripts/demo-scenarios.sh c2 3.0
```

`3.0` is the second showing, when the hosts are already on 2.0. The first
showing, with the hosts still on 1.0, is `./scripts/demo-scenarios.sh c2`.
Any higher RPM version works the same way. Press `a` at each step.

| Step | What the audience sees | Say |
|---|---|---|
| Build and upload `demo-app` at the version you passed | An RPM built on the Satellite | "A new version of our application arrives." |
| Publish + promote to **Dev only** | One `hammer` command | "I've promoted it to Dev. Only Dev." |
| `dnf check-update` + `update` on **lc-dev** | old → new | "Dev picks it up. No agent was pushed; the host asked." |
| Same commands on **lc-prod** | *"Nothing to do"*, still the old version | **Pause here.** |
| Promote to QA, update **lc-qa** | the new version | |
| Promote to Prod, update **lc-prod** | the new version | |
| Final three-way comparison | dev/qa/prod versions side by side | |

**The money moment is lc-prod reporting "nothing to do".** Stop talking and
let them read it.

> "Same content view. Same package name. Same `dnf update` command. Production
> is on the old version and there is no way for it to get the new one until
> someone promotes it. That's the control you're asking for — and notice it is
> enforced on the content side, not by hoping nobody runs the wrong playbook."

Then connect it to their actual question:

> "From the user's point of view, promotion is invisible. They run `dnf update`
> like always. What changed is what that command is allowed to return."

**Timing valve:** this act is the one that can overrun. If you are past 15:00
and still mid-sequence, press `s` to skip the QA and Prod promotions — the
Dev-yes/Prod-no contrast has already landed and the rest is repetition. Say
*"and the remaining two gates are the same operation again"* and move on.

### 15:00 – 22:00 · Act 3 — Where the non-RHEL host stops

```bash
./scripts/demo-scenarios.sh e2
```

| Step | What the audience sees | Say |
|---|---|---|
| `rpm -q foreman_ygg_worker` on lc-prod vs centos | Present / not installed, and *not available* | "Both hosts asked for the same thing at registration." |
| Host details for both | Both are registered, both take content | "The CentOS box is not excluded. It's in the inventory and it gets RPMs." |
| Show the job template | Satellite's stock *Run Command - Script Default* | "One job, and it's the stock template. I'm not writing a special case for either host." |
| Run it on **lc-prod** | Output comes back | |
| Run the same job on **centos** | No delivery | **Pause here.** |

> "The CentOS host is a perfectly good content consumer. What it cannot be is a
> managed host. `satellite-client-6` is a Red Hat repository — there is no
> CentOS Stream build of it, so there is no worker subscribed to the broker,
> so the job has nowhere to go.
>
> This is what 'prefer RHEL over the rebuilds' actually costs. It isn't a
> licensing argument. Every automation path you'd want AAP to drive —
> remote execution, errata, compliance reporting — terminates at this line."

Note the registration command for that host **asked for** the pull provider
(`--setup-remote-execution-pull true`). The limit was demonstrated, not
configured.

**Timing valve:** if short, skip the job-template creation step (`s`) and run
only the two invocations. The contrast is the payload.

### 22:00 – 25:00 · Close — the two things not on screen

**Close the terminal. Speak these; do not try to show them.**

**Ansible Automation Platform:**
> "You said you want to run this with AAP. The division is clean: Satellite
> decides what a host can see, AAP decides what state it's in. The REX job you
> just watched is the seam — Satellite's inventory becomes an AAP inventory
> source, so playbooks target 'everything in Prod' rather than a hand-kept host
> list. The thing that makes that work is that Prod means something, which is
> what Act 1 was about."

**Image mode — say it plainly, do not demo it:**
> "I should be straight with you about direction. Everything you just saw is
> package mode — a host that mutates in place, and a system that controls which
> mutations are allowed. Red Hat's direction for standard operating
> environments is image mode: the OS ships as a container image, you promote
> *images* through those same lifecycle environments instead of RPMs, and a
> host either is the image or it isn't. The promotion model you just watched is
> the same. The unit changes. I don't have image mode running in this lab, so
> I'm telling you rather than showing you — but if you're designing an SOE now,
> it's the thing to design toward."

Then stop and take questions.

---

## 4. When something is slower than expected

| Symptom | Likely cause | Do this, live |
|---|---|---|
| UI page takes >10 s | 12 GB Satellite, dev tuning | Keep talking. Never reload — it queues a second render. |
| Promote task stalls at 0% | Pulp worker busy | Switch to **Monitor → Tasks**, narrate the task list. It is a real screen, not a stall. |
| `dnf` on a client hangs | Satellite still publishing | `Ctrl-C`, `s` to skip, move to the next step. Come back if time allows. |
| A client is unreachable | OOM killed it | `virsh -c qemu:///system start lc-qa`. Present the other two; the dev-vs-prod contrast only needs two hosts. |
| Satellite UI returns 502 | A service died under memory pressure | Do **not** restart it live. Fall back to CLI: everything in Acts 2 and 3 is `hammer` and `dnf` and does not need the UI. |
| Everything is slow | Browser is eating RAM | Close every tab except the Satellite. |

**The general rule:** the script's `[s]` skip is your friend. Every act lands
with roughly half its steps. Running out of time mid-act is worse than skipping
two steps.

**If the lab is unrecoverable:** Acts 1–3 are a coherent story told on a
whiteboard in four minutes. Draw Library → Dev → QA → Prod, put a version
number on each, and move it. Do not spend demo time debugging in front of them.

---

## 5. After the meeting

```bash
# Keep the lab for a follow-up (uses no CPU when shut down):
for V in centos lc-prod lc-qa lc-dev satellite; do
  virsh -c qemu:///system shutdown $V
done

# Or return the workstation to how it was:
./scripts/teardown-soe.sh              # the 5 VMs and their disks
./scripts/teardown-soe.sh --orphans    # + anything left behind
./scripts/teardown-soe.sh --all        # + network, /etc/hosts, KSM, CentOS image
./scripts/teardown-soe.sh --all --dry-run   # see it first
```

`--all` is the full undo. The manually downloaded RHEL base image is always
kept — re-downloading it from access.redhat.com is a login and 1.4 GB.

---

## 6. One-page cue card

Print this; leave the rest closed.

```
0:00  Framing. "AAP decides what's true. Something decides what's visible."
2:00  UI  Lifecycle Environments → the chain
      UI  Content Views → RHEL9-FullStack → Versions
      UI  Promote to QA. WATCH IT FINISH. SAY NOTHING.
7:00  CLI ./scripts/demo-scenarios.sh c2 3.0
      (plain c2 only if the hosts are still on 1.0)
      → new version to Dev only
      → lc-dev updates. lc-prod: "nothing to do."   ← PAUSE
      → promote through QA, Prod
15:00 CLI ./scripts/demo-scenarios.sh e2
      → foreman_ygg_worker: RHEL yes, CentOS not available
      → same REX job: lc-prod OK, centos undeliverable  ← PAUSE
22:00 Close, no screen:
      AAP  = Satellite controls visibility, AAP controls state
      Image mode = the direction; SPOKEN, not shown
25:00 Questions.

PANIC: [s] skips a step. Two hosts is enough for Act 2.
       502 on the UI → stay in the terminal, nothing needs the browser.
```
