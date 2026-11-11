# naust

A boathouse for pull requests. Naust keeps *bays* busy: a bay is a complete yggdrasil workspace under `bays/<name>/` in the workspace naust is cloned into, made and reset by `ws bay`.

Naust then takes care of preparing a pull request for review within the bay workspace for the appropriate components (and potentially nested components). With a specific bay prepared a lot of the usual pre-testing steps will already be completed and the workspace is left "warm" for the user to perform appropriate review ceremony.

A [Terasology](https://github.com/MovingBlocks/Terasology) example:

* fetch the PR
* build
* compile every module
* run the relevant tests on the PR and on its base
* boot the game both headlessly and windowed (if possible and needed)
* take a screenshot if sensible
* check the tree is clean
* leave a report in the bay, on Discord and on the PR

A human then reviews the bay, play-tests the change (if needed) and decides. Naust never merges.

The name is Norse. A *naust* (Old Norse *naust*, still the word in Norwegian and Icelandic) is a boathouse: the shed at the shore where a boat is hauled up between voyages, kept dry and ready to launch again. The bays are its berths, and a pull request is a boat that spends a while in one.

Design of record: [`realm-siliconsaga/docs/plans/2026-10-08-naust-pr-bays-design.md`](https://github.com/SiliconSaga/realm-siliconsaga/blob/main/docs/plans/2026-10-08-naust-pr-bays-design.md).

## Where it runs

Naust is a component of the workspace whose bays it fills: cloned at `components/naust/`, it uses that workspace's `bays/`, its `.env` and its active realm, and nothing outside it. The realm's naust adapter wires `commands.run` to it, so `ws run naust <command>` is the way to call it, from any directory, with no PATH change beyond the one `ws` already has; `ws run naust bay list`, `ws run naust tick`. The script itself is `components/naust/bin/naust`, which the scheduled task calls by full path, and `naust <command>` with `components/naust/bin` on your PATH is the same thing; this page spells it `naust` for brevity. Once it runs, naust finds its workspace from its own location, never from the current directory.

## How it runs

Nothing runs unasked. A job starts because an operator at the keyboard runs `naust dock`, or because someone the realm lists has called the PR into this naust by name, in a review on the PR: *@agent-refr haul it in*. `naust tick` is the whole unattended loop and it exits. The operating system's scheduler calls it every few minutes; a tick lists the watched repository's open PRs, reads the reviews of any that has seen activity since it last looked, queues each one that has been called in, then runs at most one queued job in a free bay. A second tick arriving while a job runs finds the lock and leaves.

What a job does and which commands it uses for a given project is a *profile* in the realm (`realms/<realm>/naust/<profile>.yaml`), beside the list of who may call a PR in (`naust/trust.yaml`); how a component's workspace is provisioned and reset is the adapter's `provision:` block. Naust itself knows only that a bay is a yggdrasil workspace and drives it through `ws bay exec`.

## Setup

1. Put the two secrets in the workspace's `.env`: `NAUST_GITHUB_TOKEN` (the machine account's fine-grained token, pull-requests: write on the watched repository; never a personal token) and `NAUST_DISCORD_WEBHOOK`. Copy `naust.example.yaml` to `bays/.naust/naust.yaml`, list the profiles to watch, and set `account:` to the machine account's login: calls are addressed to it, reports post as it, and a tick refuses a token that belongs to anyone else.
2. `naust bay add bay-1 --profile terasology` (tens of minutes: `ws bay add` clones the workspace, the realm and the component with its module set, then naust warms the shared Gradle cache under `bays/.naust/gradle-home`). Add a second bay so one can hold a finished job for a human while the other works.
3. Schedule `naust tick`. On Windows, as the logged-on user so the game window has a desktop and a GPU:

   ```text
   schtasks /Create /SC MINUTE /MO 5 /TN naust-tick /IT /TR "\"C:\Program Files\Git\bin\bash.exe\" -lc \"/d/Dev/GitWS/yggdrasil/components/naust/bin/naust tick >> /d/Dev/GitWS/yggdrasil/bays/.naust/state/tick.log 2>&1\""
   ```

   On Linux a systemd timer, on macOS a launchd agent, both calling `bin/naust tick`.

## A Terasology walkthrough

Everything below runs from the workspace root, after the setup above, with the scheduled task not yet created so you can watch each step.

1. **Make a bay.** `naust bay add bay-1 --profile terasology`. This clones yggdrasil into `bays/bay-1/`, clones and trusts the realm there, and clones the profile's component, `terasology`, which is the engine; no `--with` is needed, the profile names it. The engine checkout carries `groovyw`, and the adapter's `provision.init` runs `groovyw module init omega` in it to fetch the Omega module set into `modules/` as nested repositories. Every module this workspace's own engine checkout already holds is copied from there instead of fetched, so a parent on the full Omega set makes that step a local copy; the realm's [Terasology helpers](https://github.com/SiliconSaga/realm-siliconsaga/blob/main/terasology/README.md) say how to keep it that way. Then naust builds once to warm `bays/.naust/gradle-home`, compiles every module, and resets the bay to clean. `naust bay list` names the bay as `provisioning` from the first second; the clone, the warm-up and the hooks write to `bays/bay-1/.outputs/bay.log`, so `ws bay log bay-1 --follow` from any other terminal shows where it is. When it is done, `naust bay list` shows `bay-1  free  terasology`.
2. **Dock an engine PR by hand.** `naust dock terasology 5400` reads the PR's head, claims `bay-1` and runs the nine steps there and then, logging each to the terminal and printing the report at the end. Your command is the vouch, so nobody on GitHub is asked, and nothing is posted to the PR unless you add `--comment`; the job stops if the head moves before it runs. Expect tens of minutes the first time. When it returns, `naust bay list` shows `bay-1  ready  terasology  MovingBlocks__Terasology-5400-<sha>`.
3. **Review it.** The report is at `bays/bay-1/.outputs/naust/MovingBlocks__Terasology-5400-<sha>/report.md`, with the logs, the JUnit files, the screenshot and the headless log beside it; that file is the complete report. Its first 1,500 bytes and the screenshot went to Discord, if a webhook is set, and nothing went to the PR, since step 2 did not say `--comment`. The engine checkout in `bays/bay-1/components/terasology` sits on branch `cr/5400`, built: `ws bay exec bay-1 run terasology` from the root plays it with the bay's checkout as the game's home directory, or `cd` there and `gradlew game`. Decide on GitHub. The bay stays `ready` until `naust bay release bay-1` or `bay.ready_ttl_days` passes.
4. **An engine PR with a module PR.** `naust dock terasology 5400 --with terasology/modules/Health#12` checks the module's PR out in the bay beside the engine's, builds and boots the pair, and reports on both; your command vouches for both. `--with` names a change request to read alongside, never a component to add: the modules are already in the bay from provisioning, and the target is any nested path the Terasology adapter resolves, with the PR number after `#`.
5. **A module PR on its own.** Not a job in Phase 1: a job starts from a PR on the profile's repository, the engine. For now, in a free bay, `ws bay exec bay-1 checkout terasology/modules/Health --cr 12` fetches it over the base engine for you to build and play by hand; naust writes no report. Running a module PR, or an engine change with several module PRs, as one job is the linked-PR work in the design's Phase 3.
6. **Let it run.** Create the scheduled task. Every five minutes a tick looks for calls: a review on an open PR saying *@agent-refr haul it in*, from a login the realm's `trust.yaml` lists, brings that PR into a free bay, and the report goes back to the PR as a comment from the same account. The commit the review was given on is the one that runs; a push after it needs a new call. Add `bay-2` so one bay can hold a finished job for you while the other works.

## Day to day

- `naust bay list` — every bay naust knows, its state (`free busy ready held broken`), its profile, its job, the seconds it has been in that state, and the seconds since its log was last written (`-` before any). `ws bay list` is the workspace's own view, the bays as directories with their realm and components, and knows nothing of states.
- `ws bay log <name> [--follow]` — the bay's log, `bays/<name>/.outputs/bay.log`: every `ws bay` add and reset, naust's own step lines, and the output of the warm-up and the hooks. A job's step logs stay beside its report under `.outputs/naust/<job>/`.
- `naust dock terasology 5400 [--with terasology/modules/Health#12] [--bay bay-2] [--comment] [--queue]` — bring a PR into a bay now, ahead of anything queued, and print its report. Your command is the vouch, for the PR and for any `--with` target, since only an operator at the keyboard can give it; the report stays in the bay and on your terminal unless `--comment` sends it to the PR as well. `--queue` leaves the job for the next tick instead, as does a tick already running a job. The head read at dock time is the one that runs, and a head that moved by then stops at checkout.
- A `ready` bay holds a finished job until you `naust bay release <name>` it or `bay.ready_ttl_days` passes. Open the bay's `.outputs/naust/<job>/report.md`, run the game from the bay's component directory, decide on GitHub.
- `naust bay reset <name>` puts a bay back to base by hand; `--deep` also drops Gradle outputs. A `broken` bay needs that after you fix whatever the tick log names. A job whose base branch would not build or test in the bay marks it `broken` and posts nothing, since that is the bay's fault and not the PR's; `baseline.log` in the job directory says what went wrong.
- `naust report render <jobdir>` re-renders a report; `naust notify say <text>` tests the webhook.

## Trust

A PR runs on the host the moment Gradle configures it, so nothing runs unasked. The realm's `naust/trust.yaml` lists under `forges` each GitHub login that may call a PR in, paired with the machine account their own naust posts as. A call is a review on the PR whose text says the realm's phrase addressed to this naust's `account`, `@agent-refr haul it in`; a review aimed at another account is for another boathouse, and the bare phrase is for nobody. GitHub records which commit a review was given on, and that is the only commit the call admits; a push after it needs a new call, and the job itself stops at checkout if the head it fetched is not the one it was given. Approvals are a verdict on the code, not a request to run it, and labels cannot say which commit they meant: neither is read. An operator at the keyboard needs none of this: `naust dock` is its own vouch.

The machine account's token reaches `gh` only in naust's own process and for the report step's two `ws review` calls; the job unsets it before anything the PR controls runs. The filesystem is not a boundary on this tier: a bay sits under the workspace whose `.env` holds the operator's own tokens. The gate is the boundary, and the container tier is the fix.

## Tests

`ws test naust` runs the bats suite with the workspace-vendored bats; `ws lint naust` runs shellcheck. Everything external (`gh`, `curl`, Gradle, the parent's `ws` and the bay's) is a stub in tests; only temporary git repositories are real.
