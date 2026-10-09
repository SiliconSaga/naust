# Fake executables on PATH so bats can assert how scripts call gh/git/curl.
# Each stub appends its argv to "$STUB_LOG" and runs the provided body.
make_stub() {
  local name="$1"; shift
  local body="${*:-true}"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/$name" <<EOF
#!/usr/bin/env bash
echo "$name \$*" >> "$STUB_LOG"
$body
EOF
  chmod +x "$STUB_BIN/$name"
}

stub_setup() {
  export STUB_BIN="$BATS_TEST_TMPDIR/bin"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$STUB_LOG"
  mkdir -p "$STUB_BIN"
  PATH="$STUB_BIN:$PATH"
}

# A workspace with a recording ws, naust's config under bays/.naust, a realm
# holding one profile, a trust list and a Terasology-shaped adapter, and empty
# state. Every bats file starts here.
#
# The parent's ws is a recorder; `bay exec <name> …` hands off to the bay's own
# scripts/ws when the bay has one, the way the real verb does, so a test can
# put whatever ws it needs inside a bay. WS_EXIT sets the exit status of every
# other call.
naust_setup() {
  stub_setup
  export NAUST_WORKSPACE="$BATS_TEST_TMPDIR/ws"
  export NAUST_DIR="$NAUST_WORKSPACE/bays/.naust"
  export NAUST_CONFIG="$NAUST_DIR/naust.yaml"
  export NAUST_ENV_FILE="$NAUST_WORKSPACE/.env"
  export NAUST_LOG="$BATS_TEST_TMPDIR/naust.log"
  export NAUST_NOW=1760000000
  WORKSPACE="$NAUST_WORKSPACE"
  mkdir -p "$NAUST_DIR" "$WORKSPACE/scripts" "$WORKSPACE/bays" "$WORKSPACE/realms/realm-test/naust" "$WORKSPACE/realms/realm-test/adapters"
  cat > "$WORKSPACE/scripts/ws" <<'EOF'
#!/usr/bin/env bash
echo "ws $*" >> "$STUB_LOG"
case "$1 $2" in
  "bay exec")
    bay="$3"; shift 3
    ws="$NAUST_WORKSPACE/bays/$bay/scripts/ws"
    [ -x "$ws" ] || exit "${WS_EXIT:-0}"
    cd "$NAUST_WORKSPACE/bays/$bay" && exec bash "$ws" "$@" ;;
  "bay add")
    # The shape ws bay add leaves: a workspace with a ws, the realm, and a
    # directory per --with component.
    dir="$NAUST_WORKSPACE/bays/$3"; shift 3
    mkdir -p "$dir/scripts" "$dir/components" "$dir/realms/realm-test"
    printf '#!/usr/bin/env bash\necho "bayws $*" >> "$STUB_LOG"\n' > "$dir/scripts/ws"; chmod +x "$dir/scripts/ws"
    while [ $# -gt 0 ]; do [ "$1" = --with ] && mkdir -p "$dir/components/$2"; shift; done ;;
esac
exit "${WS_EXIT:-0}"
EOF
  chmod +x "$WORKSPACE/scripts/ws"
  printf 'realm: realm-test\n' > "$WORKSPACE/ecosystem.local.yaml"
  cat > "$NAUST_CONFIG" <<'YAML'
profiles: [terasology]
lock_stale_hours: 6
YAML
  cat > "$WORKSPACE/realms/realm-test/naust/terasology.yaml" <<'YAML'
component: terasology
repo: MovingBlocks/Terasology
persona: Gooey
poll:
  debounce_minutes: 10
  skip_drafts: true
bay:
  ready_ttl_days: 7
steps:
  compile_all: "compile-all-stub"
  headless: "headless-stub"
  smoke: "smoke-stub"
hooks:
  after_add: "after-add-stub"
  after_reset: "after-reset-stub"
report:
  comment: on
YAML
  cat > "$WORKSPACE/realms/realm-test/naust/trust.yaml" <<'YAML'
terasology:
  maintainers: [Cervator, jdrueckert]
  trusted: [SiliconSaga/Terasology, trustedbot]
  nod_phrase: "ok to test"
YAML
  cat > "$WORKSPACE/realms/realm-test/adapters/terasology.yaml" <<'YAML'
commands:
  build: "./gradlew :facades:PC:build"
  test: "./gradlew :engine-tests:unitTest"
nested:
  - "modules/*"
provision:
  init: "groovyw-stub module init omega"
  runtime_dirs: [logs, saves, terasology-server]
  known_dirt:
    - "src/test/resources/logback-test.xml"
YAML
  NAUST="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/bin/naust"
}

run_naust() { run bash "$NAUST" "$@"; }

# A real repository on <branch> with one commit. Job tests add a remote.
make_bay_repo() { # <dir> <branch>
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b "$branch"
  git -C "$dir" config core.autocrlf false
  git -C "$dir" config user.email t@example.invalid
  git -C "$dir" config user.name T
  printf 'seed\n' > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -qm seed
}

# A bay the shape ws bay add leaves, with a naust state file: a ws that
# records calls as "bayws …", the realm directory, a real component repo
# holding one real nested module.
make_bay() { # <name> <state>
  local dir="$NAUST_WORKSPACE/bays/$1"
  mkdir -p "$dir/scripts" "$dir/components" "$dir/realms/realm-test" "$NAUST_DIR/state/bays"
  printf '#!/usr/bin/env bash\necho "bayws $*" >> "$STUB_LOG"\n' > "$dir/scripts/ws"
  chmod +x "$dir/scripts/ws"
  printf 'state=%s\nprofile=terasology\njob=\nsince=%s\n' "$2" "$NAUST_NOW" > "$NAUST_DIR/state/bays/$1.state"
  make_bay_repo "$dir/components/terasology" develop
  # Like the engine's own .gitignore: modules are independent repos inside the tree.
  printf '/modules/\nbuild/\n/logs/\n/saves/\n/terasology-server/\n' > "$dir/components/terasology/.gitignore"
  git -C "$dir/components/terasology" add .gitignore
  git -C "$dir/components/terasology" commit -qm gitignore
  make_bay_repo "$dir/components/terasology/modules/Cooking" develop
  BAY_DIR="$dir"
}
