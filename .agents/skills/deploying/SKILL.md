---
name: deploying
description: >-
  Agent-only procedure for changing what a live host runs and then proving what it runs, from readings rather than from exit statuses.
  Use before any deploy, redeploy, migration, recompute, or rollback against a running host, before re-running a deploy to confirm an earlier one worked, and before reporting to anyone that a change is live.
  Owns the rule that every mutating step proves its target from the artefact, the three-fact readback behind `bin/fm-deploy-verify.sh`, the route back, the counterfactual that turns a green page into evidence, and the duty to say out loud what could not be established.
user-invocable: false
metadata:
  internal: true
---

# deploying

A deploy is not finished when a command exits 0.
It is finished when you have READ, off the running thing, that what you intended is what is running, and have said out loud what you could not read.

Everything below was derived from real deploys against real production hosts, including two that went wrong.
`bin/fm-deploy-verify.sh` takes several of the readings this procedure needs.
It is not the procedure, and it does not take all of them: see "What the tool does not do".

## 1. Prove the target before anything else

**Any deploy or migration step must prove the TARGET it resolves, from the artefact, never inferred from the invocation or the directory it is run in.**
A step that cannot say what it will act on does not ship.

This is not caution.
A deploy script that opens

```
REPO="${DEPLOY_REPO:-/opt/app}"
cd "$REPO"
```

acts on `/opt/app` no matter where you launch it, so `cd /opt/app-staging && scripts/pull-prod.sh` deploys **production**.
The near-miss that produced this rule was exactly that: a staging directory, the project's own sanctioned script, and a production target.

The class, stated the way it must be carried: **a sanctioned path is a property of a (command, TARGET) pair, never of the command alone.**
"Use the project's own deploy script" is not an instruction until the target that script resolves has been read.

How to prove it:

1. Read the artefact that will actually run - the script, the unit file, the compose file, the Makefile target - and find the line where it resolves its target.
2. Read the environment that will apply **at the moment it runs**, on the account it will run as, not the one in your own shell.
3. Say the resolved target out loud, in words, before running anything.
4. Confirm it against the running system: the directory the running container names as its compose working directory, and the paths it actually reads from.

Step 4 is a distinct reading and it catches what steps 1 to 3 cannot.
On one host a container names a frozen build tree with no repository in it as its compose working directory, while the live checkout has moved on; both directories exist and their compose files are identical today.
Nothing in the invocation distinguishes them.
Only the artefact does.

## 2. Establish the route back before changing anything, and read it back

Create the way back first, then **read it back** and compare it against what is running right now.
A rollback tag you created but never read back is a plan, not a route.

The shape that works: tag the images currently running, then read the tag's digest and the running container's digest separately and compare them - not `tag && echo ok`.
Confirm the route still exists at the end of the run, not only at the start.

Then state the **cost** of taking it.
A route back is rarely free: on one deploy, rolling back re-opened a startup race the deploy had closed; on another, it restored a page that silently understated a rigging weight by 780 kg.
Write that cost down beside the route, so nobody takes it to chase an unrelated problem.

## 3. Read the before state, and know which readings are measurements

Three facts, and they are not interchangeable:

| fact | what it is | class |
| --- | --- | --- |
| source | the commit a ref resolves to in the source repository | FROM THE RECORD |
| checkout | the HEAD of the directory the deploy path operates on | MEASURED |
| running | what the thing that is actually serving reports | MEASURED |

A record says what SHOULD be there.
Only a measurement says what IS.
Never let the two blend in a sentence: "merged to main" is a record, and a checkout with no credentials for its remote can sit years behind it while `git pull` reports nothing wrong.

"Running" itself has two meanings and they can disagree:

- the image or revision label a container was created from, and
- the bytes the service actually returns.

Take both when both are available.
On a host that serves an application by directory mount, the second is the only one that moves at all.

## 4. Deploy through the project's own sanctioned path

Use the path the project owns, whole.
Do not hand-run the steps it performs, do not skip its gates, and do not set the variables it exists to default.
If the path refuses, that refusal is a **result**, not an obstacle: read what it refused and why before doing anything else.

If the path's ordering forces a cost - a long gate that runs twice, a window in which one page is broken - measure that window rather than assuming it, disclose it, and say which alternative you rejected and why.

## 5. Read the deployed commit from the RUNNING thing

Never from build output.
Never from an exit status.
Never from "the build reported it built X".

In order of strength:

1. The bytes served, hashed and compared against the repository blob at each candidate commit.
2. The revision label read off the **running container**, not off the image you just built.
3. The checkout HEAD, which tells you what the deploy path had available, not what is serving.

A build that succeeds and a container that is serving the previous image are indistinguishable from the build log alone.

## 6. A refusal must be SEEN refusing

"The guard did not fire" is weak evidence, and on a clean run it is no evidence at all.
When a deploy is supposed to be protected by a refusal, prove the refusal refuses, by **executing the real guard**, extracted verbatim from the deployed artefact, against the inputs it must reject and one it must admit.
A text match on the source is not that.

Do this without routing the live deploy through a rejected input, and without editing anything: extract, execute standalone, show the exit status and the message for each case.

## 7. The counterfactual is what turns a green page into evidence

A page that renders is not proof that a fix works, because it also renders when nothing happened.
Produce the same condition twice - old build and new - and show they differ.

The strongest form seen so far: intercept the failing dependency inside your own session only, run it against the new build, then serve the OLD file body into the same session and run it again.
Server state, files, mounts and containers are never touched, and the two results are the whole argument.

If a counterfactual would require breaking production, do not run it.
Say so, name the evidence you have instead, and mark the gap.

## 8. Re-running a deploy to confirm it worked is not free

**An unreadable state is not a stale state.**

That sentence is the whole lesson of a real incident, and it is worth carrying verbatim.
A deploy that is idempotent *once its revision label reads back* was re-run to capture a proof line.
The second run could not read the revision the first had just deployed, treated the unreadable value as out of date, rebuilt, recreated the container, killed the first run's in-flight synchronisation, and raced a schema apply against a fresh one.
**The run performed to CONFIRM the deploy destroyed the thing it was confirming.**

Two rules follow:

- Before re-running any deploy for confirmation, check by hand that the readback the script performs now returns a value, and that nothing it would interrupt is in flight.
- A deploy step that cannot read the current state must treat that as unknown and stop, never as stale and rebuild.

Prefer a read-only verifier over a second deploy run for confirmation.
That is what `bin/fm-deploy-verify.sh` exists for.

## 9. Do not bundle

Every deploy this procedure was built from carried something adjacent that was deliberately kept out: a stale line in a project's own instructions, a split-ownership checkout, a dashboard row someone will notice, an out-of-scope durable-path fix.
Each was reported and none was fixed in passing.
An unrelated change riding along inside a deploy is invisible in the rollback, and it makes the deploy's own evidence unreadable.

## 10. Report what you could not establish, out loud

A report that lists only what was proven reads as if everything was proven.
Name each of these explicitly:

- readings you could not take, and why;
- expectations that did not match, with the measured number, not the expected one;
- inferences you did not test;
- decisions the instructions did not answer, and how you resolved them;
- anything you left behind on the host.

A figure that diverged from its prediction is reported as measured and never rounded toward the answer that was wanted.
If you could not determine a cause, write that you could not determine it.

## The tool

`bin/fm-deploy-verify.sh` takes the readings in sections 3 and 5 read-only, and refuses to report confidence it has not earned.
`--help` owns the flags; `bin/fm-deploy-verify.sh` itself owns the exact mechanics.

Its four outcomes each have their own exit status, and the fourth exists because it must be impossible to read "nothing was checked" as "everything agreed":

| exit | verdict | meaning |
| --- | --- | --- |
| 0 | AGREE | at least one pair had both sides read, and every such pair agrees |
| 2 | DRIFT | at least one pair had both sides read, and they differ |
| 3 | INDETERMINATE | a reading this run ASKED FOR could not be taken |
| 4 | NOTHING CHECKED | every requested reading was taken, and no pair had both sides read |
| 1 | refused | a usage error, or `--expect-machine` did not match |

A reading that was never requested is not a reading that failed.
The two are tracked apart, which is why a complete run against an image-baked service with no host checkout can still reach exit 0, and why a run that asked for one reading and nothing to hold it against cannot.

### Running it

A full four-fact run:

```
bin/fm-deploy-verify.sh --host <ssh-target> --expect-machine <hostname-or-machine-id> \
  --container <name> --checkout <dir> \
  --source-remote <url> --source-ref refs/heads/main \
  --serves <url> --serves-path <repo-relative-path> --clone <local-clone>
```

Ask only for the readings that exist for the project in front of you.
Asking for a reading the project cannot provide costs you exit 3 and tells you nothing; asking for none of them costs you exit 4 and tells you nothing either.
Choose `--serves-path` deliberately: it must be a file that CHANGED between the commits you are trying to tell apart, or the reading cannot discriminate and will say so.

### Transcripts

These are the tool's own output, pasted whole: each block is one run reproducing the scenario it illustrates, from the run's first line to its verdict.
Because this file is public, **host aliases, machine identifiers, hostnames, absolute paths, container names, repository URLs and image digests are replaced with neutral stand-ins**.
Nothing else in these blocks is edited: no line is reordered, no reading invented, no verdict reworded, and **no line omitted** - each block is one whole run from its first line to its verdict.
Completeness is not tidiness here.
The lines an editor is most tempted to cut are the ones reporting that a reading could not be taken, and those are the evidence these examples exist to show, not the noise around it.
An unmarked omission would also make this document assert something about itself that a reader can check and find false, in a file whose whole standard is that its examples were really produced.

A healthy readback - three facts, three comparisons, all agreeing.
Note `read-as=sudo` on both host readings, and the compose lines: that is section 1 step 4, the directory the deploy path operates on, read off the running container rather than taken from the command line:

```
fm-deploy-verify.sh - read-only readback, 2026-08-19T23:39:34Z
host:      deploy-host   machine-id <elided>   hostname app-1   MEASURED
source:    ddd574e77bea   <source-repo> refs/heads/main   FROM THE RECORD
checkout:  ddd574e77bea   /opt/app   branch=main   read-as=sudo   MEASURED
container: ddd574e77bea   api   running=true restarts=0 started=2026-08-19T11:21:46.90411194Z   read-as=sudo   MEASURED
           image=sha256:<elided>
           compose working_dir=/opt/app/compose
           compose config_files=/opt/app/compose/docker-compose.yml
           mounts (what this container actually reads from):
             /var/lib/docker/volumes/app-state/_data -> /app/src/state (ro)
served:    NOT REQUESTED - no --serves given

comparisons
  source    vs checkout   AGREE ddd574e77bea
  source    vs container  AGREE ddd574e77bea
  source    vs served     NOT COMPARED - no --serves given, so this run ordered no such reading
  checkout  vs container  AGREE ddd574e77bea
  checkout  vs served     NOT COMPARED - no --serves given, so this run ordered no such reading
  container vs served     NOT COMPARED - no --serves given, so this run ordered no such reading

verdict: AGREE - every requested reading was taken and all 3 comparison(s) with both sides read agree
```

A container that is not running, read against a source that matches its label.
`docker inspect` succeeds on a stopped and on a crash-looping container, so the label is right there to read and it means nothing:

```
fm-deploy-verify.sh - read-only readback, 2026-08-19T23:39:43Z
host:      deploy-host   machine-id <elided>   hostname app-1   MEASURED
source:    ddd574e77bea   <source-repo> refs/heads/main   FROM THE RECORD
checkout:  NOT REQUESTED - no --checkout given
container: UNREAD - container router is not running (state=exited, restarts=15); the image it was created from is not evidence of what is serving
           image=sha256:<elided>
           compose working_dir=/opt/app/compose
           compose config_files=/opt/app/compose/docker-compose.yml
           mounts (what this container actually reads from):
             /opt/app -> /srv/app (ro)
served:    NOT REQUESTED - no --serves given

comparisons
  source    vs checkout   NOT COMPARED - no --checkout given, so this run ordered no such reading
  source    vs container  NOT COMPARED - container was requested and could not be read
  source    vs served     NOT COMPARED - no --serves given, so this run ordered no such reading
  checkout  vs container  NOT COMPARED - no --checkout given, so this run ordered no such reading
  checkout  vs served     NOT COMPARED - no --checkout or --serves given, so this run ordered no such reading
  container vs served     NOT COMPARED - no --serves given, so this run ordered no such reading

stated out loud
  - the running-side reading was requested and could not be taken: container router is not running (state=exited, restarts=15); the image it was created from is not evidence of what is serving

verdict: INDETERMINATE - a requested reading could not be taken; nothing here says the host is current
```

Live drift, found on a first run, with the mount reading and the served-bytes resolution both in play.
The host serves an application by directory mount, the checkout is behind the source ref, and the served bytes confirm the checkout independently:

```
fm-deploy-verify.sh - read-only readback, 2026-08-19T23:39:53Z
host:      deploy-host   machine-id <elided>   hostname app-1   MEASURED
source:    e1ade8f18e13   <source-repo> refs/heads/main   FROM THE RECORD
checkout:  ddd574e77bea   /opt/app   branch=main   read-as=none   MEASURED
           WARNING: 1 uncommitted path(s) in that checkout
container: UNREAD - container web carries no org.opencontainers.image.revision label, so what it is running cannot be read from it
           image=sha256:<elided>
           mounts (what this container actually reads from):
             /opt/app/apps/qmob -> /srv/app/qmob (ro)
             /opt/build/public-parts -> /usr/share/nginx/html/parts (ro)
served:    candidate e1ade8f18e13 is absent from the local clone and was not compared
served:    candidate ddd574e77bea   MATCH
served:    ddd574e77bea   <served-url>   sha256=9f8ba5feb666 bytes=10   MEASURED, resolved against blobs FROM THE RECORD
           the container revision was NOT a candidate for these bytes; pass it with --candidate to have it compared

comparisons
  source    vs checkout   DIFFER e1ade8f18e13 vs ddd574e77bea
  source    vs container  NOT COMPARED - container was requested and could not be read
  source    vs served     DIFFER e1ade8f18e13 vs ddd574e77bea
  checkout  vs container  NOT COMPARED - container was requested and could not be read
  checkout  vs served     AGREE ddd574e77bea
  container vs served     NOT COMPARED - container was requested and could not be read

stated out loud
  - /opt/app has 1 uncommitted path(s), so its HEAD does not describe every file it holds
  - the running-side reading was requested and could not be taken: container web carries no org.opencontainers.image.revision label, so what it is running cannot be read from it

verdict: DRIFT - 2 of 3 compared pair(s) disagree, and a requested reading could not be taken, so what disagrees may not be all of it
```

Note the last line.
A definite disagreement wins the verdict, and the tool still says that a reading failed alongside it, because what disagrees may not be all of it.

### Two readings that refuse rather than guess

**A stopped container yields no running-side commit.**
The image a stopped container was created from is not evidence of what is serving, so the reading renders unread and names the state and the restart count.

**A served-bytes probe that matches more than one candidate resolves to none of them.**
An unchanged probe file is byte-identical at many commits.
Taking the last match would report a confident verdict from a reading that cannot discriminate - either a false DRIFT or, worse, a clean AGREE for a host that could equally be running the older commit.
Choose a probe path that actually changed between the commits you are separating.

### What the tool does not do

- It does not read the artefact and resolve the target for you.
  Section 1 steps 1 to 3 stay manual; the tool covers step 4 only - the machine, the directory the running container names, and the paths it reads from.
- It does not prove a guard refuses (section 6), run a counterfactual (section 7), or know whether something is in flight (section 8).
- It does not know your intent.
  It compares the facts you asked it to compare; asking for nothing comparable returns exit 4 and no reassurance.
- It reads the revision from `org.opencontainers.image.revision`.
  A project that does not stamp that label has no container-side reading at all, and the served-bytes reading is then the only running-side measurement available.
- It compares commits, one probe file at a time.
  A matching served file proves that one file matches; it is not a whole-tree comparison, and a project whose deploy is described by a version or a tag needs that resolved to a commit first.
- It is read-only, and that is a property to keep.
  Nothing here starts, stops, builds, or changes anything.

## Fleet-general and host-specific

**Fleet-general - carry all of this to any vessel:**

- Section 1's target rule and the (command, TARGET) pair.
- Sections 2 to 10 as written: route back read back, the record/measurement split, the sanctioned path whole, reading the commit off the running thing, seeing a refusal refuse, the counterfactual, the unreadable-state rule, not bundling, and reporting what could not be established.
- `bin/fm-deploy-verify.sh` and its four outcomes.

**Specific to these hosts - re-measure before assuming any of it elsewhere:**

- That the deploy hosts are reached over ssh with docker and git present, and that a plain reading may need `sudo -n`; `--sudo` governs both readings and reports which was used.
- That several host aliases can resolve to one machine and say nothing about which, which is why every run reads the machine identity and why `--expect-machine` exists.
- That some checkouts hold no credentials for their own remote, so a pull there is a silent no-op and a commit reaches them by another transport.
- That one production checkout has split ownership - credentials on one account, write access to its refs on another - so every deploy there needs a deliberate bridge.
- The specific container names, service paths, mount layouts, and deploy script names.
- That a build verb whose name says "build" may be a pure readback, and that a bundle's right-hand side must be a ref name.

## Before you say it is live

- The target was resolved from the artefact and stated before the run.
- The route back exists, was read back, and its cost is written down.
- The deployed commit was read off the running thing, not off build output.
- A verifier run agrees, or the disagreement is explained.
- Everything that could not be established is in the report, in its own words.
