# Recipe Language Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `RECIPE_LANGUAGE` env var (sourced from `config.sh`) that makes the LLM write the recipe body in a non-English language, while keeping static UI strings and the `(MISSING — need to buy)` token in literal English so downstream tooling continues to work.

**Architecture:** Build a single shared `LANGUAGE_DIRECTIVE` string after `config.sh` is sourced; append it to both `PROMPT` (daily 3+1) and `USE_PROMPT` (`--use`). When `RECIPE_LANGUAGE` is unset or empty, the directive is empty and behavior is byte-identical to today. One sed pattern in `notify_discord` is generalised from `/^# Recipe/d` to `/^# /d` so the Discord splitter keeps stripping the H1 once the LLM translates it.

**Tech Stack:** zsh, `claude` CLI. No new dependencies. No test framework — verification is the end-to-end checklist from the spec, run after the script changes are in.

**Spec:** `docs/superpowers/specs/2026-06-07-recipe-language-design.md`

**Testing note:** This codebase has no automated test framework; the prior `--use` and Discord-bot plans established a convention of manual end-to-end verification at the end of each task. This plan follows that pattern. Introducing bats/shellcheck infra for a ~15-line feature would conflict with the project's minimal-diff preference.

---

## File Structure

Files touched:

- **Modify** `/Users/mac/personal/food/generate-recipe.sh` — one sed pattern change in `notify_discord`; one `LANGUAGE_DIRECTIVE` builder after the config-sourcing block; two one-line appends to the two prompts.
- **Modify** `/Users/mac/personal/food/config.sh.example` — add a commented `RECIPE_LANGUAGE` stanza.
- **Modify** `/Users/mac/personal/food/README.md` — add a short "Recipe language" subsection under Customizing.

No new files. Net diff is roughly 20 added lines across three files.

---

## Task 1: Make the Discord splitter language-neutral

**Files:**
- Modify: `/Users/mac/personal/food/generate-recipe.sh:122` (the sed inside `notify_discord`)

**Why:** `notify_discord` strips the document's H1 line from each Discord chunk via `sed '/^## /d; /^# Recipe/d'`. The `/^# Recipe/` pattern only matches the English titles (`# Recipes for ...`, `# Recipe with ...`). Once Task 2 lets the LLM translate the H1, that regex stops matching and the title leaks into the embed body. Generalising to `/^# /d` makes it language-neutral. Today's English output is unchanged (the H1 still starts with `# ` and still gets dropped). Doing this in its own commit means the rest of the change is a pure addition with no risk to the existing English flow.

- [ ] **Step 1: Confirm the current sed line**

Run: `sed -n '120,124p' /Users/mac/personal/food/generate-recipe.sh`

Expected output includes the line:

```sh
    body=$(sed '/^## /d; /^# Recipe/d' "$chunk")
```

If the line number has drifted, locate it with `rg -n "'/\^# Recipe/d'" /Users/mac/personal/food/generate-recipe.sh` and use that line number for the edit.

- [ ] **Step 2: Replace the sed pattern**

In `/Users/mac/personal/food/generate-recipe.sh`, change:

```sh
    body=$(sed '/^## /d; /^# Recipe/d' "$chunk")
```

to:

```sh
    body=$(sed '/^## /d; /^# /d' "$chunk")
```

Also update the surrounding comment on the line above. Change:

```sh
    # Drop the H2 title line and any "# Recipes for ..." or "# Recipe with ..." header from body.
```

to:

```sh
    # Drop the H2 title line and any top-level H1 header line (language-neutral; the H1 may be translated).
```

- [ ] **Step 3: Verify shell syntax**

Run: `bash -n /Users/mac/personal/food/generate-recipe.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Verify the new pattern still matches the English H1**

Run:

```sh
printf '# Recipes for 2026-06-07\n## Option 1: foo\nbody line\n' \
  | sed '/^## /d; /^# /d'
```

Expected output (only `body line` remains):

```
body line
```

This confirms the existing English flow is unaffected.

- [ ] **Step 5: Commit**

```sh
cd /Users/mac/personal/food
git add generate-recipe.sh
git commit -m "Make notify_discord H1 strip language-neutral

Generalise '/^# Recipe/d' to '/^# /d' so the Discord chunk splitter
keeps dropping the document title once the H1 may be translated.
English behaviour is unchanged — '# Recipes for ...' and '# Recipe
with ...' both still start with '# '."
```

---

## Task 2: Build `LANGUAGE_DIRECTIVE` and append to both prompts

**Files:**
- Modify: `/Users/mac/personal/food/generate-recipe.sh` — insert builder after config sourcing (around line 17); add one-line append after each of the two prompt assignments.

**Why:** This is the core of the feature. A single shared directive (built once) is appended to both prompts. When `RECIPE_LANGUAGE` is unset or empty, the directive is the empty string and the prompts are byte-identical to today.

- [ ] **Step 1: Confirm the insertion point after the config-sourcing block**

Run: `sed -n '14,20p' /Users/mac/personal/food/generate-recipe.sh`

Expected output:

```sh
# Optional local config (gitignored). See config.sh.example.
if [[ -f "$FOOD_DIR/config.sh" ]]; then
  source "$FOOD_DIR/config.sh"
fi

usage() {
```

The new builder goes between the closing `fi` (line 17) and the blank line above `usage()`.

- [ ] **Step 2: Insert the `LANGUAGE_DIRECTIVE` builder**

After the `fi` on line 17, insert:

```sh

# Optional output-language directive. RECIPE_LANGUAGE is a free-form string
# (e.g. "Korean", "Japanese", "Italian") sourced from config.sh; unset means
# English. The directive is appended to both prompts further down.
LANGUAGE_DIRECTIVE=""
if [[ -n "${RECIPE_LANGUAGE:-}" ]]; then
  LANGUAGE_DIRECTIVE="

LANGUAGE: Write the entire output in $RECIPE_LANGUAGE. Translate all bold labels (e.g. **Prep time**, **Cook time**, **Serves**, **Ingredients**, **Steps**, **Why it's healthy**), dish names, descriptions, and step text. EXCEPTION: keep the literal token **(MISSING — need to buy)** in English, exactly as written — downstream tooling depends on it."
fi
```

The leading blank line inside the directive value is intentional: it separates the LANGUAGE directive from the preceding `Output only the markdown, no preamble.` line when appended.

- [ ] **Step 3: Locate the daily `PROMPT` assignment's closing line**

Run: `rg -n '^Output only the markdown' /Users/mac/personal/food/generate-recipe.sh`

Expected: two matches, one inside `USE_PROMPT` (smaller line number) and one inside `PROMPT` (larger line number, around 363). Use the second match's line number.

- [ ] **Step 4: Append the directive to `PROMPT`**

Immediately after the line that closes the `PROMPT` assignment (the line `Output only the markdown, no preamble."` near line 363), insert a new line:

```sh
PROMPT="$PROMPT$LANGUAGE_DIRECTIVE"
```

The whole region should now look like:

```sh
Output only the markdown, no preamble."
PROMPT="$PROMPT$LANGUAGE_DIRECTIVE"

log "Generating recipes for $TARGET_DATE..."
```

- [ ] **Step 5: Append the directive to `USE_PROMPT`**

Locate the `USE_PROMPT` closing line (the first match from Step 3, around line 218). Immediately after `Output only the markdown, no preamble."`, insert:

```sh
USE_PROMPT="$USE_PROMPT$LANGUAGE_DIRECTIVE"
```

The whole region should now look like:

```sh
Output only the markdown, no preamble."
USE_PROMPT="$USE_PROMPT$LANGUAGE_DIRECTIVE"

  log "Generating --use recipe for: $NAMED_JOINED"
```

- [ ] **Step 6: Verify shell syntax**

Run: `bash -n /Users/mac/personal/food/generate-recipe.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Verify the directive is empty when `RECIPE_LANGUAGE` is unset**

Run:

```sh
( unset RECIPE_LANGUAGE
  LANGUAGE_DIRECTIVE=""
  if [[ -n "${RECIPE_LANGUAGE:-}" ]]; then LANGUAGE_DIRECTIVE="should not happen"; fi
  echo "[$LANGUAGE_DIRECTIVE]" )
```

Expected output:

```
[]
```

Confirms unset → no-op.

- [ ] **Step 8: Verify the directive is non-empty when `RECIPE_LANGUAGE` is set**

Run:

```sh
( RECIPE_LANGUAGE="Korean"
  LANGUAGE_DIRECTIVE=""
  if [[ -n "${RECIPE_LANGUAGE:-}" ]]; then
    LANGUAGE_DIRECTIVE="

LANGUAGE: Write the entire output in $RECIPE_LANGUAGE. ..."
  fi
  printf '%s\n' "$LANGUAGE_DIRECTIVE" | head -3 )
```

Expected: a blank line, then `LANGUAGE: Write the entire output in Korean. ...`.

- [ ] **Step 9: Commit**

```sh
cd /Users/mac/personal/food
git add generate-recipe.sh
git commit -m "Add RECIPE_LANGUAGE support via shared prompt directive

Build a LANGUAGE_DIRECTIVE once after config.sh is sourced and append
it to both PROMPT (daily 3+1) and USE_PROMPT (--use). When
RECIPE_LANGUAGE is unset or empty, the directive is empty and both
prompts are byte-identical to before. The directive instructs the
LLM to translate everything except the literal
'(MISSING — need to buy)' token, which downstream HTML highlighting
depends on."
```

---

## Task 3: Document `RECIPE_LANGUAGE` in `config.sh.example`

**Files:**
- Modify: `/Users/mac/personal/food/config.sh.example`

- [ ] **Step 1: Read the current example file**

Run: `cat /Users/mac/personal/food/config.sh.example`

Expected: the existing file ends after the `DISCORD_GUILD_ID="..."` line.

- [ ] **Step 2: Append the `RECIPE_LANGUAGE` stanza**

Append the following block to the end of `/Users/mac/personal/food/config.sh.example`:

```sh

# Output language for generated recipes. Free-form string passed to the LLM.
# Examples: "Korean", "Japanese", "Italian", "日本語".
# Unset or empty → English (default).
# RECIPE_LANGUAGE="Korean"
```

- [ ] **Step 3: Verify the file ends cleanly**

Run: `tail -6 /Users/mac/personal/food/config.sh.example`

Expected: the five lines above (blank line + 4 comment lines), with `# RECIPE_LANGUAGE="Korean"` as the final line and no trailing garbage.

- [ ] **Step 4: Commit**

```sh
cd /Users/mac/personal/food
git add config.sh.example
git commit -m "Document RECIPE_LANGUAGE in config.sh.example

Free-form string sourced from config.sh; unset means English."
```

---

## Task 4: Document the feature in `README.md`

**Files:**
- Modify: `/Users/mac/personal/food/README.md` — add a subsection under "Customizing".

**Why:** The README's Customizing section already covers schedule, HTML look, prompt, and Discord toggle. The new env var belongs there as a fifth subsection so users discover it where they look for other config knobs.

- [ ] **Step 1: Locate the insertion point in `README.md`**

Run: `rg -n '^### Disable Discord posting' /Users/mac/personal/food/README.md`

Expected: one match, around line 182.

The new subsection will be inserted **before** "Disable Discord posting" so the language subsection sits between "Change what the LLM is asked for" and "Disable Discord posting".

- [ ] **Step 2: Insert the new subsection**

Immediately before the `### Disable Discord posting` line, insert:

```markdown
### Generate recipes in another language

Set `RECIPE_LANGUAGE` in `config.sh` to a free-form language string and the LLM will write the recipe body — labels, dish names, ingredients, steps — in that language. Static UI strings (the macOS dialog, Discord embed headers, bot replies) and the `(MISSING — need to buy)` tag stay in English so the HTML highlighter keeps working.

```sh
RECIPE_LANGUAGE="Korean"     # or "Japanese", "Italian", "日本語", etc.
```

Unset or empty means English (the default). No restart needed — `config.sh` is sourced on each script run.

```

(The fenced `sh` block uses three backticks; the outer code fence in this plan is four backticks so the inner one renders.)

- [ ] **Step 3: Verify the markdown structure**

Run: `rg -n '^### ' /Users/mac/personal/food/README.md`

Expected: the subsection headings now include `Generate recipes in another language` between `Change what the LLM is asked for` and `Disable Discord posting`.

- [ ] **Step 4: Commit**

```sh
cd /Users/mac/personal/food
git add README.md
git commit -m "Document RECIPE_LANGUAGE in README

Add a Customizing subsection explaining the env var, scope (recipe
body only), and the no-restart-needed semantics."
```

---

## Task 5: End-to-end verification

**Files:** none modified — these are the four checks from the spec, run against the now-merged feature. Treat each step as PASS / FAIL; if any FAIL, stop and diagnose.

These checks require a working `claude` CLI session and populated `ingredients.txt` / `pantry.txt`. Use `--force` so existing date-keyed files don't short-circuit the generation.

- [ ] **Step 1: Baseline — unset `RECIPE_LANGUAGE`**

Ensure `RECIPE_LANGUAGE` is not set in `config.sh` (comment it out if needed). Run:

```sh
cd /Users/mac/personal/food
recipe --today --print --force
```

Expected:
- Recipe body is in English.
- The stretch (Part B) recipe's missing items are tagged `**(MISSING — need to buy)**`.
- HTML file `recipes/<today>.html` exists and renders.

This confirms zero-risk default behavior.

- [ ] **Step 2: Daily flow in target language**

Edit `config.sh` and set `RECIPE_LANGUAGE="Korean"` (or any other language you want to test). Run:

```sh
cd /Users/mac/personal/food
recipe --today --print --force
```

Expected:
- Recipe body, bold labels (`**Prep time**`, `**Ingredients**`, `**Steps**`, `**Why it's healthy**`), dish names, and step text are in the target language.
- The stretch recipe's `**(MISSING — need to buy)**` token is **literal English** (not translated).
- HTML file `recipes/<today>.html` renders. Open it and confirm:
  - Recipe content is in the target language.
  - The `(MISSING — need to buy)` text is styled red (the `.missing` highlighter triggered).

If the MISSING token came out translated, tighten the directive wording in `generate-recipe.sh` (e.g. change "exactly as written" to "exactly as written — DO NOT translate this token") and re-run.

- [ ] **Step 3: `--use` flow in target language**

With `RECIPE_LANGUAGE="Korean"` still set, pick two ingredients you have on hand and run:

```sh
cd /Users/mac/personal/food
recipe --use chicken --use spinach --print
```

Expected:
- Single recipe in the target language.
- Body, labels, dish name, steps are translated.
- Any `--use` ingredient not on either list shows the literal English `**(MISSING — need to buy)**` tag.

- [ ] **Step 4: Discord splitter (only if you use `--notify discord`)**

With `RECIPE_LANGUAGE="Korean"` still set and `DISCORD_WEBHOOK_URL` configured against a test channel, run:

```sh
cd /Users/mac/personal/food
recipe --today --notify discord --force
```

Expected in the Discord channel:
- One header message (`**Recipes for <date>**`, English) followed by four embeds (3 options + 1 recommended).
- Each embed title is the translated H2 dish name.
- Each embed body does **not** contain the document H1 line (e.g. it shouldn't start with `# 2026-06-07 레시피` or the equivalent in your chosen language). This confirms the Task 1 sed generalisation worked.
- The recommended embed (last one) is orange; the three on-hand embeds are green.

If you don't use Discord, you can simulate the chunking locally:

```sh
cd /Users/mac/personal/food
recipe --today --print --force > /tmp/test-recipe.md
awk -v d=/tmp/chunks 'BEGIN { system("mkdir -p " d); n=1; f=d "/chunk-1.md" } /^## / { f=d "/chunk-" n ".md"; n++ } { print >> f }' /tmp/test-recipe.md
for c in /tmp/chunks/chunk-*.md; do
  echo "=== $c ==="
  sed '/^## /d; /^# /d' "$c" | head -5
done
```

Expected: no chunk body starts with `# ` (the H1 is stripped from every chunk, regardless of language).

- [ ] **Step 5: Restore your preferred `RECIPE_LANGUAGE` value**

Set `config.sh` back to whatever you want as the long-term default (commented out for English, or set to your target language).

No commit — verification only.

---

## Self-review

Run after writing the plan (already completed before saving):

1. **Spec coverage:**
   - Config surface (§Config surface) → Task 3.
   - Prompt-injection layer (§Prompt-injection layer) → Task 2.
   - Discord splitter fix (§Discord splitter fix) → Task 1.
   - Things NOT changed (§NOT changed) → no task needed (the tasks only modify the listed files; everything else is untouched by construction).
   - Verification (§Verification) → Task 5.
   - Risk/rollback (§Risk + rollback) → no task; documented in spec, rollback is "unset the env var".
   - README documentation → Task 4 (mentioned in spec under "Files touched").

2. **Placeholder scan:** all steps contain literal code or commands; no "TBD" / "implement later" / "handle edge cases".

3. **Type/identifier consistency:** `LANGUAGE_DIRECTIVE` is defined in Task 2 Step 2 and referenced (same name) in Steps 4–5. `RECIPE_LANGUAGE` is the same env var in Tasks 2, 3, 4, and 5. The sed pattern `/^# /d` introduced in Task 1 matches the verification command in Task 5 Step 4.
