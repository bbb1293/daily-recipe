# Recipe by Ingredient (`--use`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--use <ingredient>` flag to `generate-recipe.sh` that produces a single ad-hoc recipe centered on the named ingredient(s), printed to stdout and optionally delivered to Discord via the existing webhook.

**Architecture:** Inline branch inside the existing `generate-recipe.sh` (approach A from the spec). Reuses the same ingredient/pantry/recent-recipes parsing and the same `claude` CLI invocation pattern. Does not save to `recipes/`, does not render HTML, does not pop a dialog. A small extension of `notify_discord()` lets the daily flow and the `--use` flow share the same Discord-posting helper.

**Tech Stack:** zsh, `claude` CLI, `jq`, `curl` (for Discord). No test framework — verification is the manual test plan from the spec, run at the end of each task.

**Spec:** `docs/superpowers/specs/2026-06-02-recipe-by-ingredient-design.md`

**Testing note:** This codebase has no automated test framework. Each task ends with manual verification commands and expected output. Introducing bats/shellcheck infra for this single feature would conflict with the project's minimal-diff preference. If a future feature warrants a test framework, that decision belongs in its own spec.

---

## File Structure

Files touched:

- **Modify** `/Users/mac/personal/food/generate-recipe.sh` — add `--use` parsing, exclusion validation, a new branch for `--use` mode, and a small parameter change to `notify_discord()`.
- **Modify** `/Users/mac/personal/food/README.md` — document the `--use` flag in the Usage section.

No new files. The script grows by roughly 80 lines and remains a single-file tool, matching the existing layout.

---

## Task 1: Extend `notify_discord()` to take header text and avoid orange-coloring a single chunk

**Files:**
- Modify: `/Users/mac/personal/food/generate-recipe.sh:94-132` (the `notify_discord` function) and `:164`, `:271` (the two call sites)

**Why:** The function currently builds its header line from a date argument (`**Recipes for $date**`). The `--use` flow wants `**Recipe with chicken, spinach**`. Easiest: take the full header string as an argument. Separately, the existing "last chunk gets orange" rule wrongly fires when there's only one chunk (the `--use` case); restrict it to multi-chunk posts so the single `--use` embed stays green.

- [ ] **Step 1: Read the current `notify_discord` function**

Run: `sed -n '94,132p' /Users/mac/personal/food/generate-recipe.sh`

Confirm signature is `notify_discord(md_file, date)` with the header line built at `idx == 1` using `**Recipes for $date**`, and the orange/green rule at `if (( idx == last_idx ))`.

- [ ] **Step 2: Change the function signature and header construction**

Replace lines 94-132 with the version below. Two changes:
1. Second argument is now `header_text` (the full header string), used as-is when `idx == 1`.
2. Orange color only applies when there are multiple chunks: `if (( idx == last_idx && last_idx > 1 ))`.

```sh
notify_discord() {
  local md_file="$1"
  local header_text="$2"
  if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
    log "DISCORD_WEBHOOK_URL not set — skipping Discord notification."
    return 1
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  # Split on "## " so each recipe becomes its own embed/message.
  awk -v d="$tmpdir" '
    BEGIN { n = 1; f = d "/chunk-1.md" }
    /^## / { f = d "/chunk-" n ".md"; n++ }
    { print >> f }
  ' "$md_file"

  local chunks=("$tmpdir"/chunk-*.md(n))
  local last_idx=${#chunks}
  local idx=0
  local chunk title body color header payload
  for chunk in "${chunks[@]}"; do
    idx=$((idx + 1))
    title=$(grep -m1 '^## ' "$chunk" | sed 's/^## //')
    # Drop the H2 title line and any "# Recipes for ..." or "# Recipe with ..." header from body.
    body=$(sed '/^## /d; /^# Recipe/d' "$chunk")
    # Green for on-hand options, orange for the final chunk only when there are multiple chunks.
    if (( idx == last_idx && last_idx > 1 )); then color=15105570; else color=3066993; fi
    # Discord embed description cap is 4096; truncate defensively.
    (( ${#body} > 4000 )) && body="${body:0:3996}…"
    # Only the first message carries the supplied header line.
    header=""; (( idx == 1 )) && header="$header_text"
    payload=$(jq -n --arg h "$header" --arg t "$title" --arg b "$body" --argjson c "$color" \
      '{content: $h, embeds: [{title: $t, description: $b, color: $c}]}')
    curl -sS -H "Content-Type: application/json" --data "$payload" \
      "$DISCORD_WEBHOOK_URL" >> "$LOG_FILE" 2>&1 || true
  done
  rm -rf "$tmpdir"
}
```

Note: the body-stripper regex was changed from `/^# Recipes for /d` to `/^# Recipe/d` so it strips both the daily flow's `# Recipes for $TARGET_DATE` line and the `--use` flow's `# Recipe with ...` line.

- [ ] **Step 3: Update the two existing call sites to pass the header text**

Find the two `notify_discord` call sites:

Run: `grep -n 'notify_discord ' /Users/mac/personal/food/generate-recipe.sh`

Both currently look like `notify_discord "$OUTPUT_FILE" "$TARGET_DATE"`. Change both to:

```sh
notify_discord "$OUTPUT_FILE" "**Recipes for $TARGET_DATE**"
```

There should be one call around line 164 (the "file already exists" branch) and one around line 271 (the "fresh generation" branch).

- [ ] **Step 4: Verify the daily flow still works (manual)**

Pick a date that already has a recipe file under `recipes/`, then:

Run: `cd /Users/mac/personal/food && ./generate-recipe.sh --date $(ls recipes/*.md | head -1 | xargs basename | sed 's/\.md$//') --notify discord`

Expected: log line `Recipes for ... already exist`, plus (if `DISCORD_WEBHOOK_URL` is set) a Discord post arrives with header `**Recipes for YYYY-MM-DD**` — identical to before.

If `DISCORD_WEBHOOK_URL` is not configured, expected log line: `DISCORD_WEBHOOK_URL not set — skipping Discord notification.` and no error.

- [ ] **Step 5: Commit**

```bash
cd /Users/mac/personal/food
git add generate-recipe.sh
git commit -m "Parameterize notify_discord header text; avoid orange for single-chunk posts"
```

---

## Task 2: Add `--use` arg parsing, exclusion validation, and a stub branch

**Files:**
- Modify: `/Users/mac/personal/food/generate-recipe.sh:19-53` (usage + arg parser)
- Modify: `/Users/mac/personal/food/generate-recipe.sh` — insert a new block after the arg parser (around line 54)

**Why:** Land the user-facing surface (flag, help text, exclusion errors) first, with a stub body that exits cleanly. This keeps each commit in a non-broken state.

- [ ] **Step 1: Update `usage()` text**

Open the script and find the `usage()` heredoc (lines 19-37). Add a `--use` line to the Options block and a short example below the existing description.

Replace the body of `usage()` (lines 20-36, between the `cat <<EOF` and `EOF`) with:

```
Usage: recipe [OPTIONS]

Generates three recipe options for a given day using ingredients.txt and pantry.txt.

With --use, generates a single ad-hoc recipe centered on the named ingredient(s)
instead. Output goes to stdout (and Discord with --notify discord). It is not
saved to recipes/ and does not render HTML.

Options:
  --today                 Generate for today (default: tomorrow)
  --date YYYY-MM-DD       Generate for a specific date
  --force                 Regenerate even if the target file exists
  --print                 Print the recipe to stdout instead of opening a dialog
  --notify discord        Post the recipe to a Discord webhook
  --use INGREDIENT        Generate one recipe centered on INGREDIENT.
                          Repeatable: --use chicken --use spinach.
                          Cannot be combined with --date/--today/--force.
  -h, --help              Show this help

When run from a terminal, output prints to stdout by default.
When run headless (e.g. launchd), a dialog pops up with an Open button.
With --notify discord, set DISCORD_WEBHOOK_URL in config.sh (see config.sh.example).
```

- [ ] **Step 2: Add `USE_ITEMS=()` initialization and the `--use` case**

In the arg-parsing block (lines 39-53), add the `USE_ITEMS=()` initializer alongside the other variable defaults, and add a `--use` case to the switch.

Replace lines 39-53 with:

```sh
TARGET_DATE=""
FORCE=false
FORCE_PRINT=false
NOTIFY=""
USE_ITEMS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --today) TARGET_DATE=$(date +%Y-%m-%d); shift ;;
    --date) TARGET_DATE="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --print) FORCE_PRINT=true; shift ;;
    --notify) NOTIFY="$2"; shift 2 ;;
    --use) USE_ITEMS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
```

- [ ] **Step 3: Insert the exclusion validation and stub branch**

Immediately after the closing `done` of the arg-parsing loop (and before the line `TARGET_DATE="${TARGET_DATE:-$(date -v+1d +%Y-%m-%d)}"`), insert:

```sh
if (( ${#USE_ITEMS[@]} > 0 )); then
  if [[ -n "$TARGET_DATE" || "$FORCE" == "true" ]]; then
    echo "--use cannot be combined with --date/--today/--force" >&2
    exit 2
  fi
  echo "--use is not yet implemented" >&2
  exit 1
fi
```

Note: `TARGET_DATE` is only non-empty here if the user explicitly passed `--today` or `--date` (the default-to-tomorrow assignment is on the next line and runs only when we did NOT take the `--use` branch). So this check correctly rejects only user-supplied dates.

- [ ] **Step 4: Verify the new flag behavior (manual)**

Run each and confirm:

```bash
cd /Users/mac/personal/food

# Help text shows --use
./generate-recipe.sh --help | grep -- '--use'
# Expected: line describing --use INGREDIENT

# Stub fires
./generate-recipe.sh --use chicken
# Expected: prints "--use is not yet implemented" to stderr, exit 1
echo "exit: $?"

# Exclusion with --date
./generate-recipe.sh --use chicken --date 2026-06-10
# Expected: prints "--use cannot be combined with --date/--today/--force", exit 2
echo "exit: $?"

# Exclusion with --today
./generate-recipe.sh --use chicken --today
# Expected: same rejection, exit 2
echo "exit: $?"

# Exclusion with --force
./generate-recipe.sh --use chicken --force
# Expected: same rejection, exit 2
echo "exit: $?"

# Daily flow still works (no --use)
./generate-recipe.sh --date 2099-01-01 --force
# Expected: a recipe is generated for 2099-01-01 as normal (or claude error, but NO regression in arg handling)
# Clean up: rm -f recipes/2099-01-01.md recipes/2099-01-01.html
```

- [ ] **Step 5: Commit**

```bash
cd /Users/mac/personal/food
git add generate-recipe.sh
git commit -m "Add --use flag parsing with exclusion validation (stub body)"
```

---

## Task 3: Implement the `--use` branch

**Files:**
- Modify: `/Users/mac/personal/food/generate-recipe.sh` — replace the stub from Task 2 with the real flow.

**Why:** Complete the feature: collect ingredient/pantry/urgent/recent-recipes data, build the single-recipe prompt, invoke `claude`, print to stdout, optionally post to Discord with the new header.

The data-collection lines (INGREDIENTS, URGENT, PANTRY, RECENT_RECIPES) are duplicated from the daily flow. This is deliberate: it keeps the daily flow untouched and the `--use` branch self-contained. The duplicated lines read the same files in the same way; drift risk is low because any change to the source format would affect both flows simultaneously.

- [ ] **Step 1: Replace the stub branch with the real implementation**

Find the block inserted in Task 2:

```sh
if (( ${#USE_ITEMS[@]} > 0 )); then
  if [[ -n "$TARGET_DATE" || "$FORCE" == "true" ]]; then
    echo "--use cannot be combined with --date/--today/--force" >&2
    exit 2
  fi
  echo "--use is not yet implemented" >&2
  exit 1
fi
```

Replace it with:

```sh
if (( ${#USE_ITEMS[@]} > 0 )); then
  if [[ -n "$TARGET_DATE" || "$FORCE" == "true" ]]; then
    echo "--use cannot be combined with --date/--today/--force" >&2
    exit 2
  fi

  # zsh-specific: join array elements with ", " for the header line.
  NAMED_JOINED="${(j:, :)USE_ITEMS}"
  # One item per line, for the prompt body.
  NAMED_LIST=$(printf '%s\n' "${USE_ITEMS[@]}")

  # Collect data (parallels the daily flow further below).
  # In --use mode an empty ingredients.txt is OK: the pantry and the named
  # items together can still yield a recipe.
  INGREDIENTS_RAW=$(grep -v '^\s*#' "$INGREDIENTS_FILE" 2>/dev/null | grep -v '^\s*$' || true)
  URGENT=$(echo "$INGREDIENTS_RAW" | grep '!urgent' | sed -E 's/[[:space:]]*!urgent[[:space:]]*$//' || true)
  INGREDIENTS=$(echo "$INGREDIENTS_RAW" | sed -E 's/[[:space:]]*!urgent[[:space:]]*$//')
  URGENT_SECTION=""
  if [[ -n "$URGENT" ]]; then
    URGENT_SECTION="

URGENT — close to expiration, prefer to use when natural (a subset of the on-hand list above):
$URGENT"
  fi

  PANTRY=""
  if [[ -f "$PANTRY_FILE" ]]; then
    PANTRY=$(grep -v '^\s*#' "$PANTRY_FILE" | grep -v '^\s*$' || true)
  fi

  RECENT_RECIPES=""
  setopt NULL_GLOB
  RECIPE_FILES=("$RECIPES_DIR"/*.md(Nom))
  unsetopt NULL_GLOB
  if (( ${#RECIPE_FILES[@]} > 0 )); then
    for f in "${RECIPE_FILES[@]:0:3}"; do
      RECENT_RECIPES+=$'\n--- '"$(basename "$f" .md)"$' ---\n'
      RECENT_RECIPES+="$(cat "$f")"
      RECENT_RECIPES+=$'\n'
    done
  fi

  USE_PROMPT="You are a home cook. Build ONE recipe that uses ALL of these named ingredients (the user specifically wants to cook with them):

Named ingredients (must all appear in the recipe):
$NAMED_LIST

Pull remaining ingredients from the on-hand list and pantry below. Any item in the Named list that is NOT present in either 'Ingredients on hand' or 'Pantry staples' MUST be tagged '**(MISSING — need to buy)**' in the Ingredients section of the output.

The recipe must satisfy:
1. SIMPLE: low cooking time (prefer <= 30 min active) and few steps, minimal equipment.
2. NUTRITIOUS & HEALTHY: balanced protein, veg, whole ingredients. Avoid deep-frying and heavy processed ingredients.
3. DETAILED: exact quantities (grams, tsp, tbsp, cups) and exact times/temperatures (e.g., 'sauté 3–4 min over medium heat', 'bake at 200°C for 12 min'). No vague 'some' or 'a bit'. In the Steps, repeat the measurable quantity inline the first time each ingredient is added.
4. AVOID repeating any of the recent recipes below.
5. Prefer URGENT items below when they fit naturally, but the Named ingredients are the priority.

Ingredients on hand:
$INGREDIENTS$URGENT_SECTION

Pantry staples (always available, do NOT tag as missing):
$PANTRY

Recent recipes (avoid repeating these):
$RECENT_RECIPES

Output format (a single markdown document):

# Recipe with $NAMED_JOINED

## <Dish Name>
One-line description.
**Prep time**: X min | **Cook time**: X min | **Serves**: X
**Ingredients**
- exact quantities; any item from the Named list that wasn't in on-hand/pantry is tagged '**(MISSING — need to buy)**'
**Steps**
1. Numbered with exact times & temperatures.
**Why it's healthy**: one short line.

Output only the markdown, no preamble."

  log "Generating --use recipe for: $NAMED_JOINED"

  if RECIPE_MD=$(printf '%s' "$USE_PROMPT" | perl -e 'alarm 600; exec @ARGV' claude -p --tools "" 2>> "$LOG_FILE"); then
    log "Generated --use recipe."
    printf '%s\n' "$RECIPE_MD"
    if [[ "$NOTIFY" == "discord" ]]; then
      tmpfile=$(mktemp)
      printf '%s' "$RECIPE_MD" > "$tmpfile"
      notify_discord "$tmpfile" "**Recipe with $NAMED_JOINED**"
      rm -f "$tmpfile"
    fi
    exit 0
  else
    log "claude CLI failed for --use, see log above."
    echo "Recipe generation failed. See $LOG_FILE." >&2
    exit 1
  fi
fi
```

- [ ] **Step 2: Sanity-check the file parses**

Run: `zsh -n /Users/mac/personal/food/generate-recipe.sh`

Expected: no output, exit 0. (Syntax-check only.)

If there's an error, the message will point to a line number — most likely a quoting issue from the prompt heredoc or the `claude` call line.

- [ ] **Step 3: Manual test — single ingredient, stdout only**

```bash
cd /Users/mac/personal/food
./generate-recipe.sh --use chicken
```

Expected:
- Recipe markdown prints to stdout.
- First line is `# Recipe with chicken`.
- Exactly one `## <Dish Name>` section follows.
- "chicken" appears in the Ingredients list.
- NO file is created in `recipes/`. Verify with `ls recipes/ | grep -v '^[0-9]'` (should be empty, ignoring date-named files).
- Exit code 0.

- [ ] **Step 4: Manual test — multiple ingredients**

```bash
./generate-recipe.sh --use chicken --use spinach
```

Expected:
- First line is `# Recipe with chicken, spinach`.
- Both "chicken" and "spinach" appear in the Ingredients list.

- [ ] **Step 5: Manual test — missing item tagging**

Pick a string that's definitely NOT in `ingredients.txt` or `pantry.txt`, e.g. `unicornmeat`:

```bash
./generate-recipe.sh --use unicornmeat
```

Expected: the Ingredients list contains a line with `unicornmeat` tagged `**(MISSING — need to buy)**`.

If the LLM tags it differently (e.g. omits the bold, or uses a different parenthetical), update the prompt's tagging instruction language and re-test. The Discord HTML highlighter and the daily flow's MISSING styling both depend on the exact `**(MISSING — need to buy)**` form.

- [ ] **Step 6: Manual test — Discord delivery (only if `DISCORD_WEBHOOK_URL` is configured)**

```bash
./generate-recipe.sh --use chicken --use spinach --notify discord
```

Expected (in the Discord channel):
- A single embed (not multiple).
- Green sidebar color.
- Content line above the embed: `**Recipe with chicken, spinach**`.
- Embed title: the dish name.
- Embed body: the recipe details, without the `# Recipe with ...` or `## <Dish Name>` lines (those are stripped).

If `DISCORD_WEBHOOK_URL` is unset, expected log line: `DISCORD_WEBHOOK_URL not set — skipping Discord notification.` The stdout output still prints.

- [ ] **Step 7: Manual test — daily flow regression check**

```bash
./generate-recipe.sh --date 2099-01-02 --force
```

Expected: the daily flow runs unchanged — three on-hand options + one stretch recipe, file written to `recipes/2099-01-02.md`, HTML rendered, dialog popped (if headless) or stdout (if interactive).

Clean up after: `rm -f recipes/2099-01-02.md recipes/2099-01-02.html`

- [ ] **Step 8: Commit**

```bash
cd /Users/mac/personal/food
git add generate-recipe.sh
git commit -m "Implement --use ingredient-driven single-recipe generation"
```

---

## Task 4: Document `--use` in README

**Files:**
- Modify: `/Users/mac/personal/food/README.md` — Usage section (around line 95-114)

- [ ] **Step 1: Add the flag to the command-line usage code block**

Find the code block in README.md that begins with `recipe                           # Generate tomorrow's recipes` (around line 99). Add a new line for `--use`. The updated block should read:

```sh
recipe                           # Generate tomorrow's recipes (skip if already generated)
recipe --today                   # Generate for today
recipe --date 2026-05-01         # Generate for a specific date
recipe --force                   # Regenerate even if the target file exists
recipe --print                   # Force print to stdout (useful inside pipelines)
recipe --notify discord          # Also post the result to a Discord webhook
recipe --use chicken             # Generate one recipe centered on a specific ingredient
recipe --use chicken --use rice  # Repeatable; all named items must appear
recipe --help
```

- [ ] **Step 2: Add a short prose description after the "Behavior differs by how it's invoked" paragraph**

Find the paragraph that ends with `useful for re-reading on your phone, noisy if you trigger the script repeatedly.` (around line 113). Insert a new subsection immediately after it:

```markdown
### Cook with a specific ingredient

If you want a recipe centered on something specific — say you just bought chicken and want ideas — use `--use`:

```sh
recipe --use chicken
recipe --use chicken --use spinach --notify discord
```

This generates a single recipe that must include every named ingredient. Remaining ingredients are drawn from `ingredients.txt` and `pantry.txt`. Any named ingredient that isn't on either list is tagged `(MISSING — need to buy)` in the output. The recipe is printed to stdout (and posted to Discord with `--notify discord`); it is not saved to `recipes/` and does not render HTML. `--use` cannot be combined with `--date`, `--today`, or `--force`.
```

- [ ] **Step 3: Verify the README renders cleanly**

Run: `head -150 /Users/mac/personal/food/README.md | tail -60`

Visually confirm: the new code-block lines are formatted consistently, and the new "Cook with a specific ingredient" subsection sits between the Discord-noise note and the existing `## File layout` section.

- [ ] **Step 4: Commit**

```bash
cd /Users/mac/personal/food
git add README.md
git commit -m "Document --use flag in README"
```

---

## Task 5: Final acceptance — run the full spec test plan

**Files:** none (verification only)

**Why:** The spec lists five acceptance scenarios. Run them end-to-end to confirm nothing regressed across the three code-modifying tasks.

- [ ] **Step 1: Scenario 1 — single ingredient prints to stdout**

```bash
cd /Users/mac/personal/food
./generate-recipe.sh --use chicken
ls recipes/ | grep -E '(use|chicken)' || echo "no use-tagged files (good)"
```

Expected: recipe to stdout; no file in `recipes/` named with `use` or `chicken`.

- [ ] **Step 2: Scenario 2 — multiple ingredients to Discord**

```bash
./generate-recipe.sh --use chicken --use spinach --notify discord
```

Expected: both items in the recipe; Discord embed arrives with header `**Recipe with chicken, spinach**` and green color. (Skip if `DISCORD_WEBHOOK_URL` is unset; record that as the reason.)

- [ ] **Step 3: Scenario 3 — missing item tagged**

```bash
./generate-recipe.sh --use unicornmeat
```

Expected: `unicornmeat` appears tagged `**(MISSING — need to buy)**`.

- [ ] **Step 4: Scenario 4 — exclusion error**

```bash
./generate-recipe.sh --use chicken --date 2026-06-03
echo "exit: $?"
```

Expected: prints `--use cannot be combined with --date/--today/--force` to stderr; exit 2; no `claude` call made (check `tail -5 generate-recipe.log` — no new "Generating" line).

- [ ] **Step 5: Scenario 5 — daily flow unchanged**

```bash
./generate-recipe.sh --date 2099-01-03 --force
ls -la recipes/2099-01-03.*
```

Expected: both `.md` and `.html` exist; the markdown contains three `## Option` sections and one `## Recommended:` section.

Clean up: `rm -f recipes/2099-01-03.md recipes/2099-01-03.html`

- [ ] **Step 6: Report**

Summarize the five scenarios as pass/fail. If any failed, do not declare the feature done — re-open the relevant task and fix.

- [ ] **Step 7: Per project CLAUDE.md, ask about release**

After acceptance passes, ask the user:

1. Create a commit? (Already done per-task.)
2. Push to `origin`?
3. Add a semver tag (e.g. `v0.7.0 — add --use ingredient-driven recipe`)?

Run `git tag -l --format='%(refname:short) %(subject)' --sort=-creatordate | head` first to confirm the next version number, per CLAUDE.md.

---

## Self-review notes

Spec coverage check:
- CLI surface (flag, exclusions) → Task 2
- Behavior table (no file save, no HTML, no dialog, no early-exit on empty ingredients, urgent softened) → Task 3 (the `--use` branch contains its own data collection that bypasses the daily flow's date-file and dialog paths entirely; the URGENT_SECTION text was softened from "must be used first" to "prefer to use when natural"; the empty-ingredients early-exit is bypassed because the `--use` branch returns before reaching it)
- Prompt structure (single recipe, MUST-include, MISSING tagging, urgent preference, recent-history avoidance, output format) → Task 3 Step 1 (the `USE_PROMPT` heredoc)
- Discord delivery (header parameter, green color for single chunk) → Task 1
- Error handling (rejection messages, MISSING fall-through, empty ingredients OK, claude failure) → Tasks 2 & 3
- Manual test plan → Task 5

No placeholders found. Type/name consistency: `USE_ITEMS`, `NAMED_JOINED`, `NAMED_LIST`, `USE_PROMPT`, `RECIPE_MD` are defined in Task 3 and referenced only within that same task; `notify_discord`'s new `header_text` parameter is set in Task 1 and matches the call sites in Tasks 1 and 3.
