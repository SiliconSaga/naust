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

Design of record: [`realm-siliconsaga/docs/plans/2026-10-08-naust-pr-bays-design.md`](https://github.com/SiliconSaga/realm-siliconsaga/blob/main/docs/plans/2026-10-08-naust-pr-bays-design.md).

## Where it runs

Naust is a component of the workspace whose bays it fills: cloned at `components/naust/`, it uses that workspace's `bays/`, its `.env` and its active realm, and nothing outside it. Its command is `components/naust/bin/naust <command>`, from the workspace root or anywhere else, since it finds the workspace from its own path; there is no `ws naust` verb. Put `components/naust/bin` on your PATH beside `scripts/` and it is just `naust`, which is how the rest of this page spells it.

## How it runs

`naust tick` is the whole control loop and it exits. The operating system's scheduler calls it every few minutes; a tick polls GitHub, gates each candidate head against the realm's trust list, queues the ones that may run, posts one Discord notice per PR that needs a maintainer's review, then runs at most one queued job in a free bay. A second tick arriving while a job runs finds the lock and leaves.

What a job does and which commands it uses for a given project is a *profile* in the realm (`realms/<realm>/naust/<profile>.yaml`), beside the trust list (`naust/trust.yaml`); how a component's workspace is provisioned and reset is the adapter's `provision:` block. Naust itself knows only that a bay is a yggdrasil workspace and drives it through `ws bay exec`.

## Setup

1. Put the two secrets in the workspace's `.env`: `NAUST_GITHUB_TOKEN` (the machine account's fine-grained token, pull-requests: write on the watched repository; never a personal token) and `NAUST_DISCORD_WEBHOOK`. Copy `naust.example.yaml` to `bays/.naust/naust.yaml` and list the profiles to watch.
2. `naust bay add bay-1 --profile terasology` (tens of minutes: `ws bay add` clones the workspace, the realm and the component with its module set, then naust warms the shared Gradle cache under `bays/.naust/gradle-home`). Add a second bay so one can hold a finished job for a human while the other works.
3. Schedule `naust tick`. On Windows, as the logged-on user so the game window has a desktop and a GPU:

   ```text
   schtasks /Create /SC MINUTE /MO 5 /TN naust-tick /IT /TR "\"C:\Program Files\Git\bin\bash.exe\" -lc \"/d/Dev/GitWS/yggdrasil/components/naust/bin/naust tick >> /d/Dev/GitWS/yggdrasil/bays/.naust/state/tick.log 2>&1\""
   ```

   On Linux a systemd timer, on macOS a launchd agent, both calling `bin/naust tick`.

## A Terasology walkthrough

Everything below runs from the workspace root, after the setup above, with the scheduled task not yet created so you can watch each step.

1. **Make a bay.** `naust bay add bay-1 --profile terasology`. This clones yggdrasil into `bays/bay-1/`, clones and trusts the realm there, clones the engine with `groovyw module init omega`, builds once to warm `bays/.naust/gradle-home`, compiles every module, then resets the bay to clean. `naust bay list` shows `bay-1  free  terasology`.
2. **Run an engine PR by hand.** `naust run terasology 5400` reads the PR, applies the trust gate and queues it ahead of anything polled; a stranger's PR without a nod is refused here with the reason. Then `naust tick` once: it polls, finds the queued job, claims `bay-1` and runs the nine steps, logging each to the terminal. Expect tens of minutes the first time. When it returns, `naust bay list` shows `bay-1  ready  terasology  MovingBlocks__Terasology-5400-<sha>`.
3. **Review it.** The report is at `bays/bay-1/.outputs/naust/MovingBlocks__Terasology-5400-<sha>/report.md`, with the logs, the JUnit files, the screenshot and the headless log beside it; the same report went to Discord and, as a comment, to the PR. The engine checkout in `bays/bay-1/components/terasology` sits on branch `cr/5400`, built: `cd` there and `gradlew game` to play it, or `ws bay exec bay-1 exec terasology gradlew game` from the root. Decide on GitHub. The bay stays `ready` until `naust bay release bay-1` or `bay.ready_ttl_days` passes.
4. **An engine PR with a module PR.** `naust run terasology 5400 --with terasology/modules/Health#12` checks the module's PR out in the bay beside the engine's, builds and boots the pair, and reports on both; the gate covers the engine PR, and the `--with` target is your own vouch. The target is any nested path the Terasology adapter resolves, with the PR number after `#`.
5. **A module PR on its own.** Not a job in Phase 1: a job starts from a PR on the profile's repository, the engine. For now, in a free bay, `ws bay exec bay-1 checkout terasology/modules/Health --cr 12` fetches it over the base engine for you to build and play by hand; naust writes no report. Running a module PR, or an engine change with several module PRs, as one job is the linked-PR work in the design's Phase 3.
6. **Let it run.** Create the scheduled task. Every five minutes a tick polls; a maintainer's or trusted PR is queued once its head has sat still for the debounce; anyone else's gets one Discord notice asking for a nod, and a maintainer's Approve or an *ok to test* review on that commit admits it. Add `bay-2` so one bay can hold a finished job for you while the other works.

## Day to day

- `naust bay list` — every bay naust knows, its state (`free busy ready held broken`), its profile, its job and the seconds it has been in that state. `ws bay list` is the workspace's own view, the bays as directories with their realm and components, and knows nothing of states.
- `naust run terasology 5400 [--with terasology/modules/Health#12] [--bay bay-2]` — queue a PR by hand, ahead of polled ones. The trust gate still applies to the PR; a `--with` target is your own vouch, fetched and built as given, since only an operator can name one.
- A `ready` bay holds a finished job until you `naust bay release <name>` it or `bay.ready_ttl_days` passes. Open the bay's `.outputs/naust/<job>/report.md`, run the game from the bay's component directory, decide on GitHub.
- `naust bay reset <name>` puts a bay back to base by hand; `--deep` also drops Gradle outputs. A `broken` bay needs that after you fix whatever the tick log names.
- `naust report render <jobdir>` re-renders a report; `naust notify say <text>` tests the webhook.

## Trust

A PR runs on the host the moment Gradle configures it, so nothing runs without trust. The realm's `naust/trust.yaml` lists `maintainers` (their PRs run, and their reviews count) and `trusted` logins or head repositories. Anyone else needs a nod: a maintainer's review on the PR, either an Approve or a review whose text says the nod phrase (`ok to test`). GitHub records which commit a review was given on, and that is the only commit the nod admits; a push after the review needs a new one, and the job itself stops at checkout if the head it fetched is not the one the gate admitted. Labels are not read.

The machine account's token reaches `gh` only in naust's own process and for the report step's two `ws review` calls; the job unsets it before anything the PR controls runs. The filesystem is not a boundary on this tier: a bay sits under the workspace whose `.env` holds the operator's own tokens. The gate is the boundary, and the container tier is the fix.

## Tests

`ws test naust` runs the bats suite with the workspace-vendored bats; `ws lint naust` runs shellcheck. Everything external (`gh`, `curl`, Gradle, the parent's `ws` and the bay's) is a stub in tests; only temporary git repositories are real.
