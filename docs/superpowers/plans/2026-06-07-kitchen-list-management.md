# Kitchen List Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add, remove, list, and toggle the urgent state of items in `ingredients.txt` / `pantry.txt`, exposed identically on the CLI and on Discord.

**Architecture:** A new `kitchen.sh` owns all list mutation and is the single source of truth. The Discord bot shells out to it (just like it already does for `generate-recipe.sh`), translating slash-command input into `kitchen.sh` arguments. No mutation logic lives in JS.

**Tech Stack:** zsh (script + tests), Node.js 25 + discord.js v14 (bot). No new dependencies.

---

## File Structure

- `kitchen.sh` (new) — CLI for `list` / `add` / `remove` / `urgent` / `unurgent`. Reads/writes `ingredients.txt` and `pantry.txt`. Honors `KITCHEN_DATA_DIR` so tests can point it at a temp dir.
- `test/kitchen.test.sh` (new) — dependency-free zsh test suite with its own assertion helpers, each test in an isolated temp data dir.
- `bot/register-commands.js` (modify) — add the `kitchen` slash command with subcommands.
- `bot/index.js` (modify) — generalize `runScript` to take a script path, add `splitItems` helper, add `handleKitchen`, route the `kitchen` command.
- `README.md`, `CLAUDE.md` (modify) — document the new script and commands.

**Conventions baked into the script:**
- One item = one argument. Multi-word items are quoted. The bot splits its comma-separated `items` string into separate args before calling.
- Matching is case-insensitive. `add` uses exact matching for duplicate detection. `remove`, `urgent`, and `unurgent` try exact matching first, then a unique substring match; ambiguous substring matches are reported without changing files. Comment (`#`) and blank lines are never matched.
- Exit `0` when an operation ran (per-item results — added / already present / removed / not found / marked / cleared — are reported in stdout text). Exit `2` for usage errors (unknown subcommand, missing args, bad list name, `--urgent` with `pantry`).
- Mutations rewrite via a temp file + `mv`, preserving comments, blanks, and order.

---

### Task 1: Script skeleton + test harness

**Files:**
- Create: `kitchen.sh`
- Create: `test/kitchen.test.sh`

- [ ] **Step 1: Write the test harness with the first failing tests**

Create `test/kitchen.test.sh`:

```zsh
#!/bin/zsh
# Dependency-free tests for kitchen.sh. Each test runs in its own temp data dir.
set -uo pipefail

SCRIPT="${0:A:h}/../kitchen.sh"
FAILS=0

pass() { print -P "  %F{green}ok%f   $1"; }
fail() { print -P "  %F{red}FAIL%f $1"; FAILS=$((FAILS + 1)); }

assert_eq() {     # desc expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"
  else fail "$1"; print "       expected: [$2]"; print "       actual:   [$3]"; fi
}
assert_contains() {  # desc haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"
  else fail "$1 (missing: $3)"; fi
}
assert_not_contains() {  # desc haystack needle
  if [[ "$2" != *"$3"* ]]; then pass "$1"
  else fail "$1 (unexpected: $3)"; fi
}

new_data_dir() { export KITCHEN_DATA_DIR="$(mktemp -d)"; }

# Run kitchen.sh, capturing combined output in REPLY_OUT and exit code in REPLY_RC.
k() { REPLY_OUT="$("$SCRIPT" "$@" 2>&1)"; REPLY_RC=$?; }

echo "== dispatch & usage =="
new_data_dir
k --help
assert_eq "help exits 0" 0 "$REPLY_RC"
assert_contains "help shows usage" "$REPLY_OUT" "Usage: kitchen"

k
assert_eq "no args exits 2" 2 "$REPLY_RC"

k bogus
assert_eq "unknown command exits 2" 2 "$REPLY_RC"
assert_contains "unknown command message" "$REPLY_OUT" "unknown command"

echo
if (( FAILS > 0 )); then print -P "%F{red}$FAILS failure(s)%f"; exit 1
else print -P "%F{green}all tests passed%f"; fi
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zsh test/kitchen.test.sh`
Expected: FAIL — `kitchen.sh` does not exist yet, so every `k` call errors and assertions fail (or the harness reports a nonzero exit).

- [ ] **Step 3: Create the script skeleton**

Create `kitchen.sh`:

```zsh
#!/bin/zsh
set -euo pipefail

# Resolve the real directory of this script (following symlinks).
KITCHEN_DIR="${0:A:h}"
# Tests override the data location via KITCHEN_DATA_DIR.
DATA_DIR="${KITCHEN_DATA_DIR:-$KITCHEN_DIR}"
INGREDIENTS_FILE="$DATA_DIR/ingredients.txt"
PANTRY_FILE="$DATA_DIR/pantry.txt"

usage() {
  cat <<'EOF'
Usage: kitchen <command> [args]

Manage the ingredients and pantry lists used by the recipe generator.

Commands:
  list [ingredients|pantry]              Show a list (default: both)
  add <ingredients|pantry> <item>... [--urgent]
                                         Add items (--urgent: ingredients only)
  remove <ingredients|pantry> <item>...  Remove items
  urgent <item>...                       Mark ingredients as urgent
  unurgent <item>...                     Clear urgent from ingredients
  -h, --help                             Show this help

Items are matched case-insensitively. Mutating commands try exact matches first,
then a unique substring match. Multi-word items must be quoted, e.g.
kitchen add ingredients "chicken thighs".
EOF
}

die_usage() { echo "$1" >&2; exit 2; }

file_for_list() {
  case "$1" in
    ingredients) echo "$INGREDIENTS_FILE" ;;
    pantry) echo "$PANTRY_FILE" ;;
    *) return 1 ;;
  esac
}

# Normalized match key: strip trailing !urgent, trim, lowercase.
norm_key() {
  local s
  s=$(printf '%s' "$1" | sed -E 's/[[:space:]]*!urgent[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')
  printf '%s' "${(L)s}"
}

# Display name: strip trailing !urgent and trim (preserve original case).
disp() {
  printf '%s' "$1" | sed -E 's/[[:space:]]*!urgent[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

# True for comment or blank lines.
is_skip() {
  [[ "$1" =~ '^[[:space:]]*#' ]] && return 0
  [[ -z "${1//[[:space:]]/}" ]] && return 0
  return 1
}

# --- subcommands inserted below by later tasks ---

# --- dispatch ---
cmd="${1:-}"
shift 2>/dev/null || true
case "$cmd" in
  list)     cmd_list "$@" ;;
  add)      cmd_add "$@" ;;
  remove)   cmd_remove "$@" ;;
  urgent)   cmd_urgent "$@" ;;
  unurgent) cmd_unurgent "$@" ;;
  -h|--help) usage; exit 0 ;;
  "")       usage >&2; exit 2 ;;
  *)        die_usage "unknown command: $cmd (try list, add, remove, urgent, unurgent)" ;;
esac
```

- [ ] **Step 4: Make the script executable**

Run: `chmod +x kitchen.sh test/kitchen.test.sh`

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zsh test/kitchen.test.sh`
Expected: PASS — `all tests passed` (the dispatch/usage tests only; `list`/`add`/etc. are added in later tasks).

- [ ] **Step 6: Commit**

```bash
git add kitchen.sh test/kitchen.test.sh
git commit -m "Add kitchen.sh skeleton with dispatch and test harness"
```

---

### Task 2: `list`

**Files:**
- Modify: `kitchen.sh` (insert functions above the dispatch block)
- Modify: `test/kitchen.test.sh`

- [ ] **Step 1: Write the failing tests**

In `test/kitchen.test.sh`, insert this block immediately before the final `echo` / summary block:

```zsh
echo "== list =="
new_data_dir
k list ingredients
assert_contains "empty list shows header" "$REPLY_OUT" "== ingredients =="
assert_contains "empty list shows (none)" "$REPLY_OUT" "(none)"

new_data_dir
printf '# comment\n\nspinach !urgent\neggs\n' > "$KITCHEN_DATA_DIR/ingredients.txt"
printf 'salt\nrice\n' > "$KITCHEN_DATA_DIR/pantry.txt"
k list ingredients
assert_contains "list shows plain item" "$REPLY_OUT" "eggs"
assert_contains "list flags urgent item" "$REPLY_OUT" "spinach ⚠ urgent"
assert_not_contains "list omits comments" "$REPLY_OUT" "# comment"

k list
assert_contains "list both shows ingredients header" "$REPLY_OUT" "== ingredients =="
assert_contains "list both shows pantry header" "$REPLY_OUT" "== pantry =="
assert_contains "list both shows pantry item" "$REPLY_OUT" "rice"

k list bogus
assert_eq "list bad target exits 2" 2 "$REPLY_RC"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zsh test/kitchen.test.sh`
Expected: FAIL — `cmd_list: command not found` for the new `list` cases; the summary reports failures.

- [ ] **Step 3: Implement `list`**

In `kitchen.sh`, replace the line `# --- subcommands inserted below by later tasks ---` with:

```zsh
# --- subcommands inserted below by later tasks ---

print_list() {
  local list="$1" file any=false line
  file=$(file_for_list "$list")
  echo "== $list =="
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      is_skip "$line" && continue
      any=true
      if [[ "$line" == *'!urgent'* ]]; then
        echo "$(disp "$line") ⚠ urgent"
      else
        echo "$(disp "$line")"
      fi
    done < "$file"
  fi
  [[ "$any" == true ]] || echo "(none)"
}

cmd_list() {
  if [[ $# -eq 0 ]]; then
    print_list ingredients
    echo
    print_list pantry
    return
  fi
  file_for_list "$1" >/dev/null 2>&1 || die_usage "list: unknown list '$1' (use ingredients or pantry)"
  print_list "$1"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zsh test/kitchen.test.sh`
Expected: PASS — `all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add kitchen.sh test/kitchen.test.sh
git commit -m "Add kitchen list subcommand"
```

---

### Task 3: `add`

**Files:**
- Modify: `kitchen.sh` (insert functions above the dispatch block)
- Modify: `test/kitchen.test.sh`

- [ ] **Step 1: Write the failing tests**

In `test/kitchen.test.sh`, insert before the summary block:

```zsh
echo "== add =="
new_data_dir
printf '# my stuff\neggs\n' > "$KITCHEN_DATA_DIR/ingredients.txt"
k add ingredients "chicken thighs"
assert_eq "add exits 0" 0 "$REPLY_RC"
assert_contains "add reports added" "$REPLY_OUT" "Added to ingredients: chicken thighs"
k list ingredients
assert_contains "added item present" "$REPLY_OUT" "chicken thighs"
assert_contains "add preserves existing item" "$REPLY_OUT" "eggs"
assert_not_contains "add preserves comment (not listed)" "$REPLY_OUT" "my stuff"
assert_contains "comment still in file" "$(cat "$KITCHEN_DATA_DIR/ingredients.txt")" "# my stuff"

k add ingredients "EGGS"
assert_contains "duplicate is skipped (case-insensitive)" "$REPLY_OUT" "Already in ingredients: EGGS"

k add ingredients "kale" --urgent
assert_contains "urgent add reported" "$REPLY_OUT" "Added to ingredients: kale"
k list ingredients
assert_contains "urgent flag applied" "$REPLY_OUT" "kale ⚠ urgent"

new_data_dir
k add pantry "fish sauce"
assert_contains "add to pantry, file created" "$REPLY_OUT" "Added to pantry: fish sauce"
assert_eq "pantry file now exists" "fish sauce" "$(cat "$KITCHEN_DATA_DIR/pantry.txt")"

k add pantry "miso" --urgent
assert_eq "--urgent with pantry exits 2" 2 "$REPLY_RC"
k add bogus "x"
assert_eq "add bad list exits 2" 2 "$REPLY_RC"
k add ingredients
assert_eq "add with no items exits 2" 2 "$REPLY_RC"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zsh test/kitchen.test.sh`
Expected: FAIL — `cmd_add: command not found` for the new cases.

- [ ] **Step 3: Implement `add`**

In `kitchen.sh`, immediately after the `cmd_list` function, insert:

```zsh
list_contains() {
  local file="$1" key="$2" line
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    is_skip "$line" && continue
    [[ "$(norm_key "$line")" == "$key" ]] && return 0
  done < "$file"
  return 1
}

cmd_add() {
  local list="${1:-}"
  [[ -n "$list" ]] || die_usage "add: missing list (ingredients or pantry)"
  shift
  local file
  file=$(file_for_list "$list") || die_usage "add: unknown list '$list' (use ingredients or pantry)"
  local urgent=false items=() arg
  for arg in "$@"; do
    if [[ "$arg" == "--urgent" ]]; then urgent=true; else items+=("$arg"); fi
  done
  (( ${#items[@]} > 0 )) || die_usage "add: provide at least one item"
  if [[ "$urgent" == true && "$list" != "ingredients" ]]; then
    die_usage "add: --urgent is only valid for the ingredients list"
  fi
  [[ -f "$file" ]] || : > "$file"
  local item name
  for item in "${items[@]}"; do
    name=$(disp "$item")
    if list_contains "$file" "$(norm_key "$item")"; then
      echo "Already in $list: $name"
    elif [[ "$urgent" == true ]]; then
      printf '%s !urgent\n' "$name" >> "$file"
      echo "Added to $list: $name"
    else
      printf '%s\n' "$name" >> "$file"
      echo "Added to $list: $name"
    fi
  done
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zsh test/kitchen.test.sh`
Expected: PASS — `all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add kitchen.sh test/kitchen.test.sh
git commit -m "Add kitchen add subcommand with dedupe and urgent flag"
```

---

### Task 4: `remove`

**Files:**
- Modify: `kitchen.sh` (insert functions above the dispatch block)
- Modify: `test/kitchen.test.sh`

- [ ] **Step 1: Write the failing tests**

In `test/kitchen.test.sh`, insert before the summary block:

```zsh
echo "== remove =="
new_data_dir
printf '# header\ncherry tomatoes\nspinach !urgent\neggs\n' > "$KITCHEN_DATA_DIR/ingredients.txt"

k remove ingredients "Spinach"
assert_contains "remove reports removed (case-insensitive, urgent line)" "$REPLY_OUT" "Removed from ingredients: Spinach"
k list ingredients
assert_not_contains "removed item gone" "$REPLY_OUT" "spinach"
assert_contains "other items remain" "$REPLY_OUT" "eggs"
assert_contains "comment preserved after remove" "$(cat "$KITCHEN_DATA_DIR/ingredients.txt")" "# header"

k remove ingredients "tom"
assert_eq "remove missing exits 0" 0 "$REPLY_RC"
assert_contains "exact match: substring not removed" "$REPLY_OUT" "Not found in ingredients: tom"
k list ingredients
assert_contains "substring target untouched" "$REPLY_OUT" "cherry tomatoes"

k remove bogus "x"
assert_eq "remove bad list exits 2" 2 "$REPLY_RC"
k remove ingredients
assert_eq "remove with no items exits 2" 2 "$REPLY_RC"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zsh test/kitchen.test.sh`
Expected: FAIL — `cmd_remove: command not found` for the new cases.

- [ ] **Step 3: Implement `remove`**

In `kitchen.sh`, immediately after the `cmd_add` function, insert:

```zsh
rewrite_without() {
  # $1 file, $2 key. Returns 0 if a line was removed.
  local file="$1" key="$2" tmp removed=false line
  [[ -f "$file" ]] || return 1
  tmp=$(mktemp)
  while IFS= read -r line || [[ -n "$line" ]]; do
    if is_skip "$line"; then printf '%s\n' "$line" >> "$tmp"; continue; fi
    if [[ "$(norm_key "$line")" == "$key" ]]; then removed=true; continue; fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$file"
  mv "$tmp" "$file"
  [[ "$removed" == true ]]
}

cmd_remove() {
  local list="${1:-}"
  [[ -n "$list" ]] || die_usage "remove: missing list (ingredients or pantry)"
  shift
  local file
  file=$(file_for_list "$list") || die_usage "remove: unknown list '$list' (use ingredients or pantry)"
  (( $# > 0 )) || die_usage "remove: provide at least one item"
  local item
  for item in "$@"; do
    if rewrite_without "$file" "$(norm_key "$item")"; then
      echo "Removed from $list: $(disp "$item")"
    else
      echo "Not found in $list: $(disp "$item")"
    fi
  done
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zsh test/kitchen.test.sh`
Expected: PASS — `all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add kitchen.sh test/kitchen.test.sh
git commit -m "Add kitchen remove subcommand"
```

---

### Task 5: `urgent` / `unurgent`

**Files:**
- Modify: `kitchen.sh` (insert functions above the dispatch block)
- Modify: `test/kitchen.test.sh`

- [ ] **Step 1: Write the failing tests**

In `test/kitchen.test.sh`, insert before the summary block:

```zsh
echo "== urgent / unurgent =="
new_data_dir
printf '# h\nspinach\neggs\n' > "$KITCHEN_DATA_DIR/ingredients.txt"

k urgent "spinach"
assert_contains "urgent marks item" "$REPLY_OUT" "Marked urgent: spinach"
k list ingredients
assert_contains "urgent flag shown" "$REPLY_OUT" "spinach ⚠ urgent"

k urgent "spinach"
assert_contains "urgent is idempotent" "$REPLY_OUT" "Marked urgent: spinach"
assert_eq "no double suffix" "spinach !urgent" "$(grep -i spinach "$KITCHEN_DATA_DIR/ingredients.txt")"

k unurgent "SPINACH"
assert_contains "unurgent clears (case-insensitive)" "$REPLY_OUT" "Cleared urgent: SPINACH"
k list ingredients
assert_not_contains "urgent flag gone" "$REPLY_OUT" "⚠ urgent"

k urgent "kale"
assert_contains "urgent missing item reported" "$REPLY_OUT" "Not found in ingredients: kale"
assert_eq "urgent missing exits 0" 0 "$REPLY_RC"
assert_contains "comment preserved after urgent ops" "$(cat "$KITCHEN_DATA_DIR/ingredients.txt")" "# h"

k urgent
assert_eq "urgent with no items exits 2" 2 "$REPLY_RC"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zsh test/kitchen.test.sh`
Expected: FAIL — `cmd_urgent: command not found` for the new cases.

- [ ] **Step 3: Implement `urgent` / `unurgent`**

In `kitchen.sh`, immediately after the `cmd_remove` function, insert:

```zsh
apply_urgent() {
  # $1 file, $2 key, $3 mode(add|remove). Echoes "found" or "notfound".
  local file="$1" key="$2" mode="$3" tmp found=false line base
  [[ -f "$file" ]] || { echo notfound; return 0; }
  tmp=$(mktemp)
  while IFS= read -r line || [[ -n "$line" ]]; do
    if is_skip "$line"; then printf '%s\n' "$line" >> "$tmp"; continue; fi
    if [[ "$(norm_key "$line")" == "$key" ]]; then
      found=true
      base=$(disp "$line")
      if [[ "$mode" == "add" ]]; then printf '%s !urgent\n' "$base" >> "$tmp"
      else printf '%s\n' "$base" >> "$tmp"; fi
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  mv "$tmp" "$file"
  [[ "$found" == true ]] && echo found || echo notfound
}

set_urgent() {
  local mode="$1"; shift
  local label word
  if [[ "$mode" == "add" ]]; then label="Marked urgent"; word="urgent"
  else label="Cleared urgent"; word="unurgent"; fi
  (( $# > 0 )) || die_usage "$word: provide at least one item"
  local item
  for item in "$@"; do
    if [[ "$(apply_urgent "$INGREDIENTS_FILE" "$(norm_key "$item")" "$mode")" == "found" ]]; then
      echo "$label: $(disp "$item")"
    else
      echo "Not found in ingredients: $(disp "$item")"
    fi
  done
}

cmd_urgent()   { set_urgent add "$@"; }
cmd_unurgent() { set_urgent remove "$@"; }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zsh test/kitchen.test.sh`
Expected: PASS — `all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add kitchen.sh test/kitchen.test.sh
git commit -m "Add kitchen urgent/unurgent subcommands"
```

---

### Task 6: Register the `/kitchen` Discord command

**Files:**
- Modify: `bot/register-commands.js:14-35`

- [ ] **Step 1: Add the command definition**

In `bot/register-commands.js`, the `commands` array currently ends with the `tomorrow` entry (lines 27-34). Add a `kitchen` entry to the array, immediately after the `tomorrow` object and before the closing `];`:

```javascript
  {
    name: 'kitchen',
    description: 'Manage your ingredients and pantry lists',
    options: [
      {
        type: 1, // SUB_COMMAND
        name: 'list',
        description: 'Show current ingredients and/or pantry',
        options: [
          {
            type: 3, // STRING
            name: 'which',
            description: 'Which list (default: both)',
            required: false,
            choices: [
              { name: 'ingredients', value: 'ingredients' },
              { name: 'pantry', value: 'pantry' },
            ],
          },
        ],
      },
      {
        type: 1,
        name: 'add',
        description: 'Add items to a list',
        options: [
          {
            type: 3,
            name: 'list',
            description: 'Which list to add to',
            required: true,
            choices: [
              { name: 'ingredients', value: 'ingredients' },
              { name: 'pantry', value: 'pantry' },
            ],
          },
          {
            type: 3,
            name: 'items',
            description: 'Comma-separated, e.g. "chicken thighs, spinach"',
            required: true,
          },
          {
            type: 5, // BOOLEAN
            name: 'urgent',
            description: 'Mark these as urgent (ingredients only)',
            required: false,
          },
        ],
      },
      {
        type: 1,
        name: 'remove',
        description: 'Remove items from a list',
        options: [
          {
            type: 3,
            name: 'list',
            description: 'Which list to remove from',
            required: true,
            choices: [
              { name: 'ingredients', value: 'ingredients' },
              { name: 'pantry', value: 'pantry' },
            ],
          },
          {
            type: 3,
            name: 'items',
            description: 'Comma-separated items to remove',
            required: true,
          },
        ],
      },
      {
        type: 1,
        name: 'urgent',
        description: 'Mark ingredients as urgent',
        options: [
          {
            type: 3,
            name: 'items',
            description: 'Comma-separated ingredients to mark urgent',
            required: true,
          },
        ],
      },
      {
        type: 1,
        name: 'unurgent',
        description: 'Clear urgent from ingredients',
        options: [
          {
            type: 3,
            name: 'items',
            description: 'Comma-separated ingredients to clear',
            required: true,
          },
        ],
      },
    ],
  },
```

- [ ] **Step 2: Verify the file parses**

Run: `node --check bot/register-commands.js`
Expected: no output, exit 0 (syntax OK).

- [ ] **Step 3: Commit**

```bash
git add bot/register-commands.js
git commit -m "Register /kitchen Discord command with subcommands"
```

---

### Task 7: Wire `/kitchen` into the bot handler

**Files:**
- Modify: `bot/index.js`

- [ ] **Step 1: Add a `KITCHEN_SCRIPT` constant**

In `bot/index.js`, the `SCRIPT` constant is defined at line 19. Add a sibling line right after it:

```javascript
const KITCHEN_SCRIPT = path.join(PROJECT_DIR, 'kitchen.sh');
```

- [ ] **Step 2: Generalize `runScript` to take a script path**

In `bot/index.js`, change the `runScript` signature (line 31) and the `spawn` call (line 35).

Replace:

```javascript
function runScript(args) {
  return new Promise((resolve, reject) => {
    let stdout = '';
    let stderr = '';
    const child = spawn(SCRIPT, args, { cwd: PROJECT_DIR });
```

with:

```javascript
function runScript(args, script = SCRIPT) {
  return new Promise((resolve, reject) => {
    let stdout = '';
    let stderr = '';
    const child = spawn(script, args, { cwd: PROJECT_DIR });
```

Also update the error message on line 44 so it is not hard-coded to the generator. Replace:

```javascript
      else reject(new Error(`generate-recipe.sh exited ${code}\nstderr: ${stderr.slice(-2000)}`));
```

with:

```javascript
      else reject(new Error(`${path.basename(script)} exited ${code}\nstderr: ${stderr.slice(-2000)}`));
```

- [ ] **Step 3: Extract a `splitItems` helper and use it in `handleCook`**

In `bot/index.js`, add this helper just above `handleCook` (which starts at line 83):

```javascript
function splitItems(raw) {
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}
```

Then in `handleCook`, replace the inline split (lines 84-88):

```javascript
  const raw = interaction.options.getString('ingredients', true);
  const items = raw
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
```

with:

```javascript
  const items = splitItems(interaction.options.getString('ingredients', true));
```

- [ ] **Step 4: Add `handleKitchen`**

In `bot/index.js`, add this function just after `handleCook` ends (after line 103, before `handleDaily`):

```javascript
async function handleKitchen(interaction) {
  const sub = interaction.options.getSubcommand();
  const args = [];
  switch (sub) {
    case 'list': {
      args.push('list');
      const which = interaction.options.getString('which');
      if (which) args.push(which);
      break;
    }
    case 'add': {
      const list = interaction.options.getString('list', true);
      const items = splitItems(interaction.options.getString('items', true));
      if (items.length === 0) {
        await interaction.editReply('Please provide at least one item.');
        return;
      }
      args.push('add', list, ...items);
      if (interaction.options.getBoolean('urgent')) args.push('--urgent');
      break;
    }
    case 'remove': {
      const list = interaction.options.getString('list', true);
      const items = splitItems(interaction.options.getString('items', true));
      if (items.length === 0) {
        await interaction.editReply('Please provide at least one item.');
        return;
      }
      args.push('remove', list, ...items);
      break;
    }
    case 'urgent':
    case 'unurgent': {
      const items = splitItems(interaction.options.getString('items', true));
      if (items.length === 0) {
        await interaction.editReply('Please provide at least one item.');
        return;
      }
      args.push(sub, ...items);
      break;
    }
    default:
      await interaction.editReply(`Unknown subcommand: ${sub}`);
      return;
  }
  try {
    const stdout = await runScript(args, KITCHEN_SCRIPT);
    await postMarkdown(interaction, stdout);
  } catch (err) {
    await reportFailure(interaction, err);
  }
}
```

- [ ] **Step 5: Route the `kitchen` command**

In `bot/index.js`, in the `switch (interaction.commandName)` block, add a case after the `cook` case (line 139-141):

```javascript
      case 'kitchen':
        await handleKitchen(interaction);
        break;
```

- [ ] **Step 6: Verify the file parses**

Run: `node --check bot/index.js`
Expected: no output, exit 0 (syntax OK).

- [ ] **Step 7: Manual smoke test (host with bot configured)**

Run: `node bot/register-commands.js` then restart the bot (`launchctl kickstart -k gui/$(id -u)/com.user.daily-recipe.bot`, or `node bot/index.js` in a terminal). In Discord try:
- `/kitchen add list:ingredients items:tofu, kale urgent:true`
- `/kitchen list which:ingredients` (expect tofu and kale flagged urgent)
- `/kitchen unurgent items:kale` then `/kitchen list which:ingredients`
- `/kitchen remove list:ingredients items:tofu`

Expected: each replies with the per-item status lines from `kitchen.sh`.

- [ ] **Step 8: Commit**

```bash
git add bot/index.js
git commit -m "Handle /kitchen in the Discord bot"
```

---

### Task 8: Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Document the layout in `CLAUDE.md`**

In `CLAUDE.md`, under `## Layout`, add two bullets after the `generate-recipe.sh` bullet:

```markdown
- `kitchen.sh` — manage the data files from the CLI: `kitchen list`, `kitchen add <list> <item>... [--urgent]`, `kitchen remove <list> <item>...`, `kitchen urgent <item>...`, `kitchen unurgent <item>...`. Matches items case-insensitively; mutations try exact first, then unique substring, and report multiple substring matches without changing files. Honors `KITCHEN_DATA_DIR` for testing. Shared by the Discord `/kitchen` command.
- `test/kitchen.test.sh` — dependency-free zsh tests for `kitchen.sh`. Run with `zsh test/kitchen.test.sh`.
```

- [ ] **Step 2: Document the CLI and Discord usage in `README.md`**

In `README.md`, add a section describing `kitchen.sh` (CLI) and the `/kitchen` Discord subcommands. Place it near the existing usage / Discord documentation, following the surrounding style:

```markdown
## Managing your lists

Edit the ingredient and pantry lists without opening the files, from the CLI or Discord.

### CLI (`kitchen.sh`)

```bash
./kitchen.sh list                       # show both lists
./kitchen.sh list ingredients           # show one list (urgent items flagged)
./kitchen.sh add ingredients "chicken thighs" "spinach" --urgent
./kitchen.sh add pantry "fish sauce"
./kitchen.sh remove ingredients "spinach"
./kitchen.sh urgent "spinach"           # mark close-to-expiring
./kitchen.sh unurgent "spinach"
```

Items are matched case-insensitively. `remove`, `urgent`, and `unurgent` try an
exact match first, then a unique substring match. If a substring matches
multiple items, nothing changes and the matching candidates are shown. The
`--urgent` flag applies only to the ingredients list.

### Discord (`/kitchen`)

- `/kitchen list [which]` — show ingredients and/or pantry
- `/kitchen add list:<ingredients|pantry> items:"a, b" [urgent:true]`
- `/kitchen remove list:<ingredients|pantry> items:"a, b"`
- `/kitchen urgent items:"a, b"` / `/kitchen unurgent items:"a, b"`

The `items` field is comma-separated. After changing the command definitions,
re-run `node bot/register-commands.js`.
```

- [ ] **Step 3: Verify docs render sanely**

Run: `git diff --stat README.md CLAUDE.md`
Expected: both files show additions; eyeball the diff for correct markdown.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "Document kitchen list management (CLI and Discord)"
```

---

## Self-Review

**Spec coverage:**
- Inject/eject ingredients & pantry via CLI → Tasks 3, 4 (`add`/`remove`). Via Discord → Tasks 6, 7.
- List current ingredients/pantry via CLI → Task 2. Via Discord → Tasks 6, 7.
- Mark/unmark urgent via CLI → Task 5. Via Discord → Tasks 6, 7.
- Single source of truth (no JS logic duplication) → bot shells out to `kitchen.sh` (Task 7).
- Case-insensitive exact matching with unique substring fallback for mutations → `norm_key` and resolver helpers, exercised in Tasks 3-5.
- Atomic edits, comments/order preserved → `rewrite_without` / `apply_urgent` (Tasks 4-5) and tests asserting comment survival.
- Exit-code contract (0 ran / 2 usage) → dispatch + `die_usage` (Task 1), asserted in Tasks 1-5.
- Tests → Tasks 1-5. Docs → Task 8.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every run step shows the command and expected result.

**Type/name consistency:** Helpers (`norm_key`, `disp`, `is_skip`, `file_for_list`, `die_usage`) are defined in Task 1 and used unchanged thereafter. `cmd_list`/`cmd_add`/`cmd_remove`/`cmd_urgent`/`cmd_unurgent` are referenced by the Task 1 dispatch and defined in Tasks 2-5. `runScript(args, script)`, `KITCHEN_SCRIPT`, `splitItems`, and `handleKitchen` names are consistent across Task 7. Discord option/subcommand names (`list`, `add`, `remove`, `urgent`, `unurgent`, `which`, `items`, `urgent` bool) match between Task 6 (registration) and Task 7 (handling).
