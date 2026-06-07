# Kitchen list management — design

Date: 2026-06-07

## Problem

Editing the on-hand and pantry lists today means hand-editing `ingredients.txt`
and `pantry.txt`. There is no way to add, remove, list, or change the urgent
state of an item from the CLI or from Discord. This adds those operations.

## Goals

- Add and remove items from either the ingredients or pantry list.
- List the current contents of either list (or both).
- Mark and unmark an ingredient's `!urgent` tag.
- Expose all of the above on both the CLI and Discord, with no duplicated logic.

## Non-goals

- Quantities, units, or expiry dates per item. The lists stay free-form, one
  item per line.
- Editing recipe history or any file other than `ingredients.txt` / `pantry.txt`.
- Concurrency control between the bot and the scheduled `launchd` generator
  (collisions are vanishingly unlikely for a single-user tool).

## Architecture

A new `kitchen.sh` in the project root owns all list mutation and is the single
source of truth. The Discord bot shells out to it exactly as it already does for
`generate-recipe.sh`; the bot only translates slash-command input into
`kitchen.sh` arguments and posts the output back. No mutation logic lives in JS.

```
                ┌─────────────┐
   CLI user ───▶│  kitchen.sh │◀─── bot/index.js (/kitchen ...)
                └──────┬──────┘
                       ▼
        ingredients.txt  /  pantry.txt   (comments, blanks, order preserved)
```

## kitchen.sh — CLI

```
kitchen list   [ingredients|pantry]            # default: both
kitchen add    <ingredients|pantry> <item>... [--urgent]
kitchen remove <ingredients|pantry> <item>...
kitchen urgent   <item>...                      # ingredients only
kitchen unurgent <item>...                      # ingredients only
```

### Conventions

- **One item = one argument.** Multi-word items are quoted, e.g.
  `kitchen add ingredients "chicken thighs"`. The bot splits its
  comma-separated `items` string into separate arguments before calling, so
  `kitchen.sh` never parses commas.
- The script resolves its own directory (following symlinks) the same way
  `generate-recipe.sh` does, so it works regardless of where it is invoked from.
- Files are created if missing. The data-file format is unchanged: one item per
  line, `#` comment lines and blank lines ignored, an optional trailing
  ` !urgent` suffix on ingredient lines.

### Behavior by subcommand

**add `<list> <item>... [--urgent]`**
- `<list>` must be `ingredients` or `pantry`; otherwise usage error (exit 2).
- `--urgent` is only valid with the `ingredients` target; using it with
  `pantry` is a usage error (exit 2).
- For each item, case-insensitively compare against existing entries (ignoring
  any `!urgent` suffix and surrounding whitespace). If already present, skip it
  and report `Already in <list>: <item>`. Otherwise append the item (plus
  ` !urgent` when `--urgent` is set) after the existing content, leaving the
  comment header intact. Report `Added to <list>: <item>`.

**remove `<list> <item>...`**
- For each item, resolve a match against non-comment, non-blank lines. Exact
  case-insensitive match wins first. If no exact match exists, a
  case-insensitive substring match may be used only when it resolves to exactly
  one line. Remove the matched line and report the actual stored item, e.g.
  `Removed from ingredients: smoked duck 180g x 6`. If a substring matches
  multiple lines, do not mutate and report the candidates. If nothing matches,
  report `Not found in <list>: <item>`.

**urgent `<item>...` / unurgent `<item>...`**
- Operate only on `ingredients.txt`.
- `urgent`: for each matching ingredient line, ensure it ends with ` !urgent`
  (add if absent). Idempotent. Report `Marked urgent: <item>` or
  `Not found in ingredients: <item>`.
- `unurgent`: for each matching ingredient line, strip a trailing ` !urgent`.
  Idempotent. Report `Cleared urgent: <item>` or
  `Not found in ingredients: <item>`.

**list `[ingredients|pantry]`**
- With no argument, print both lists under headers. With an argument, print just
  that list. Comment and blank lines are omitted from the output; urgent
  ingredients are flagged, e.g. `spinach ⚠ urgent`.

### Matching rule

The item name of a line is the line with any trailing ` !urgent` suffix and
surrounding whitespace removed. Comments and blanks are ignored.

`add` uses case-insensitive exact matching only for duplicate detection.

`remove`, `urgent`, and `unurgent` use case-insensitive exact matching first. If
there is no exact match, they fall back to case-insensitive substring matching.
A unique substring match mutates that stored item and reports the actual stored
item in stdout. Multiple substring matches are treated as ambiguous: the command
exits 0, changes nothing for that query, and prints the matched candidates.

### Edits are atomic

Every mutation writes a temp file and `mv`s it over the original, preserving
comment lines, blank lines, and the order of untouched lines.

### Exit codes

- `0` — the operation ran. Per-item outcomes (added, already present, removed,
  not found, marked, cleared) are reported in stdout text, not via exit code.
  A "not found" item is not a failure.
- `2` — usage error: unknown subcommand, missing required argument, invalid
  list name, or `--urgent` with `pantry`.

This matters because the bot treats any non-zero exit as a failure; expected
per-item results must therefore come back on a `0` exit.

## Discord — /kitchen with subcommands

`register-commands.js` gains one `kitchen` command whose subcommands mirror the
CLI:

- `/kitchen list [which:ingredients|pantry]`
- `/kitchen add list:<ingredients|pantry> items:"a, b" [urgent:bool]`
- `/kitchen remove list:<ingredients|pantry> items:"a, b"`
- `/kitchen urgent items:"a, b"`
- `/kitchen unurgent items:"a, b"`

The `list`/`which` options that name a target list are constrained **choice**
options (`ingredients` / `pantry`), so an invalid target cannot reach the
script.

`index.js` gains a `handleKitchen(interaction)` that:
1. reads the subcommand via `interaction.options.getSubcommand()`,
2. splits the `items` string on commas (trim, drop empties) the same way
   `handleCook` already does,
3. builds the `kitchen.sh` argument array (appending `--urgent` when the
   boolean option is set on `add`),
4. runs the script and posts the (short) stdout via the existing
   `postMarkdown` helper.

`runScript` is generalized to take a script path (default `generate-recipe.sh`)
so both scripts share the spawn/capture logic; a `KITCHEN_SCRIPT` constant
points at `kitchen.sh`.

## Testing

`test/kitchen.test.sh` — a dependency-free shell test that points `kitchen.sh`
at a temporary working directory and asserts behavior:

- add a new item; add a duplicate (case-insensitive) is skipped
- add with `--urgent`; `--urgent` with `pantry` is a usage error (exit 2)
- remove an existing item; remove a missing item reports not-found, exit 0
- `urgent` then `urgent` again (idempotent); `unurgent` clears it
- unique substring match mutates the stored item and reports its full name
- ambiguous substring match lists candidates and leaves files unchanged
- `list` omits comments/blanks and flags urgent items
- comment lines and untouched lines survive every mutation
- unknown subcommand / missing args exit 2

The bot handler is thin glue over the script and is verified manually.

## Documentation

- `CLAUDE.md`: add `kitchen.sh` and `test/kitchen.test.sh` to the layout section.
- `README.md`: add a `/kitchen` section describing the CLI and Discord commands.

## Files touched

- new `kitchen.sh`
- new `test/kitchen.test.sh`
- `bot/index.js` — generalize `runScript`, add `KITCHEN_SCRIPT`, add
  `handleKitchen`, route `kitchen` in the interaction switch
- `bot/register-commands.js` — add the `kitchen` command definition
- `README.md`, `CLAUDE.md` — docs
