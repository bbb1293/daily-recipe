# Recipe Language Support — Design

## Summary

Add a `RECIPE_LANGUAGE` environment variable, sourced from `config.sh`, that tells `generate-recipe.sh` to produce the recipe body in a non-English language. Unset/empty means English (the existing behavior). Static UI strings (AppleScript dialog, Discord embed headers, bot replies, HTML page title) stay in English. The load-bearing `**(MISSING — need to buy)**` token is kept literal so the HTML highlighter and Discord splitter continue to work.

The language string is free-form and passed directly to the LLM (e.g. `"Korean"`, `"Japanese"`, `"Italian"`, `"日本語"`). No per-language string tables, no enum, no CLI override.

## Motivation

The recipe output is currently English-only. The user wants the daily plan and `--use` recipes in their preferred language, configured once in `config.sh` rather than per-invocation.

## Config surface

Add one optional variable, sourced via the existing `source "$FOOD_DIR/config.sh"` line:

```sh
# config.sh.example addition

# Output language for generated recipes. Free-form string passed to the LLM.
# Examples: "Korean", "Japanese", "Italian", "日本語".
# Unset or empty → English (default).
# RECIPE_LANGUAGE="Korean"
```

No new file, no new format. The variable lives next to the existing Discord secrets in `config.sh`.

## Prompt-injection layer

A single shared directive is appended to both `PROMPT` (daily 3+1 plan) and `USE_PROMPT` (`--use` ad-hoc recipe) when `RECIPE_LANGUAGE` is non-empty. The directive is built once near the top of the script, right after `config.sh` is sourced.

```sh
LANGUAGE_DIRECTIVE=""
if [[ -n "${RECIPE_LANGUAGE:-}" ]]; then
  LANGUAGE_DIRECTIVE="

LANGUAGE: Write the entire output in $RECIPE_LANGUAGE. Translate all bold labels (e.g. **Prep time**, **Cook time**, **Serves**, **Ingredients**, **Steps**, **Why it's healthy**), dish names, descriptions, and step text. EXCEPTION: keep the literal token **(MISSING — need to buy)** in English, exactly as written — downstream tooling depends on it."
fi
```

Both prompts end with `"$LANGUAGE_DIRECTIVE"` interpolated after the existing `Output only the markdown, no preamble.` line. When `RECIPE_LANGUAGE` is unset, the appended string is empty and the prompt is byte-identical to today's.

Why a single shared directive: the rule is identical in both flows ("respond in X, keep MISSING literal"); duplicating it invites drift.

## Discord splitter fix

`notify_discord` currently strips the document's top-level title line from each chunk via:

```sh
body=$(sed '/^## /d; /^# Recipe/d' "$chunk")
```

The `^# Recipe` pattern matches the English titles `# Recipes for ...` and `# Recipe with ...`. Once the LLM translates the H1 line into the target language, this regex no longer matches and the title leaks into the Discord embed body.

Change it to be language-neutral:

```sh
body=$(sed '/^## /d; /^# /d' "$chunk")
```

Drops any line starting with `# ` (i.e. the H1) regardless of language. Safe because recipe documents only have one H1 (the document title) and it's always stripped from the per-recipe embed bodies anyway.

## Things deliberately NOT changed

| Surface | Stays English | Reason |
|---|---|---|
| `pagetitle="Recipes for $TARGET_DATE"` (HTML browser tab) | yes | Browser-tab string; user chose "static UI stays English" |
| AppleScript dialog text + button labels | yes | Static UI |
| Discord embed header text (`**Recipes for <date>**`, `**Recipe with <items>**`) | yes | Static UI |
| `bot/index.js` reply strings | yes | Static UI |
| `**(MISSING — need to buy)**` token in recipe body | yes (literal) | HTML highlighter + README docs match it literally |
| `CLAUDE.md` project-layout doc | yes | No structural change |

## Behavior matrix

| `RECIPE_LANGUAGE` | Recipe body | MISSING token | Static UI | HTML highlighter |
|---|---|---|---|---|
| unset / empty | English | English | English | works (no change) |
| `"Korean"` etc. | Korean | English (literal) | English | works (token preserved) |

The unset case is byte-identical to today's behavior — a zero-risk default.

## Files touched

- `generate-recipe.sh` — build `LANGUAGE_DIRECTIVE` after config sourcing; append to both prompts; tweak the `notify_discord` sed pattern.
- `config.sh.example` — add the commented `RECIPE_LANGUAGE` stanza.
- `README.md` — add a short "Recipe language" section under config/setup with one example.

Not touched: `bot/`, `recipe.css`, `launchd/`, `CLAUDE.md`, `ingredients.txt`, `pantry.txt`.

## Verification

No unit-test framework; verification is end-to-end on a real recipe run.

1. **Unset baseline.** `RECIPE_LANGUAGE` unset → `recipe --today --print --force`. Output shape and language identical to today's recipes. Confirms zero-risk default.
2. **Daily flow, non-English.** `RECIPE_LANGUAGE="Korean"` → `recipe --today --print --force`. Verify:
   - Recipe body, bold labels, dish names, steps are Korean.
   - The stretch recipe's `**(MISSING — need to buy)**` token is literal English.
   - `recipes/<date>.html` renders; the `<span class="missing">` highlighter still styles the token.
3. **`--use` flow, non-English.** `RECIPE_LANGUAGE="Korean"` → `recipe --use chicken --use spinach --print`. Same checks as (2).
4. **Discord splitter.** `RECIPE_LANGUAGE="Korean"` → `recipe --today --notify discord` against a test webhook (or inspect the chunk loop locally). Verify each chunk's body does not contain the translated H1 title line — confirms the `/^# /d` change works.

## Risk + rollback

- **Risk:** the LLM occasionally fails to translate a label, or translates the MISSING token despite the instruction. Mitigation: the directive is explicit. If it happens, tighten the wording. Worst case is one ugly mixed-language recipe — re-run with `--force`.
- **Rollback:** unset (or comment out) `RECIPE_LANGUAGE` in `config.sh`. Old behavior restored without code revert. The `sed` change in `notify_discord` is language-neutral; no rollback needed for it.
