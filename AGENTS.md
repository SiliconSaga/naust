# naust — agent context

Bash only, `set -euo pipefail`, no jq on the host (shape JSON with `gh --jq`), YAML through `yq`. Tests are bats with PATH stubs; see `tests/helpers/stub.bash` and start every test file with `naust_setup`. Everything a job does inside a bay goes through `bay_ws`, which is the parent's `ws bay exec`; never call Gradle from naust itself and never run a bay's `ws` directly.

Design of record and the reasoning behind each decision: the realm's `docs/plans/2026-10-08-naust-pr-bays-design.md`. The Phase 1 plan beside it lists the files and their contracts.

Secrets live in the workspace's `.env`, read literally by `env_value`; never source it and never pass a token on a command line. Only `gh_auth` (the tick, `naust run`) puts the token in the environment, and `job.sh` unsets it before PR code runs.
