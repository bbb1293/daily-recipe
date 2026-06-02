# Recipe by Ingredient (`--use`) — Design

## Summary

Add a `--use <ingredient>` flag to `generate-recipe.sh` that produces a single ad-hoc recipe centered on the named ingredient(s), drawing remaining items from `ingredients.txt` + `pantry.txt`. The recipe is delivered to stdout and, optionally, to Discord via the existing webhook. It is not saved to `recipes/`, does not render HTML, and does not pop a dialog.

This is **Phase 1**. A Discord bot listener that lets the user trigger the same feature from Discord itself is deferred to a separate spec.

## Motivation

The daily flow answers "what should I cook tomorrow given my kitchen?" The user also wants to answer "I want to cook with X right now — what should I make?" The two queries share the same data sources (ingredients, pantry) and the same quality bar, but differ in shape (one recipe vs. three+stretch) and in persistence (transient vs. date-keyed).

## CLI surface

```
recipe --use <ingredient> [--use <ingredient> ...] [--notify discord] [--print]
```

- `--use` is repeatable. Every named item MUST appear in the resulting recipe.
- Composable with `--notify discord` and `--print`.
- **Rejected combinations**: `--use` with `--date`, `--today`, or `--force` exits with code 2 and message `--use cannot be combined with --date/--today/--force`. These flags only make sense for the date-keyed daily plan.

## Behavior

When `--use` is set, the script diverges from the daily flow as follows:

| Behavior | Daily | `--use` mode |
|---|---|---|
| Save markdown to `recipes/YYYY-MM-DD.md` | yes | **no** |
| Render HTML | yes | **no** |
| Pop AppleScript dialog (headless) | yes | **no** |
| Post to Discord | only with `--notify discord` | same |
| Print to stdout | interactive or `--print` | same |
| Feed last 3 recipes as "avoid repeating" | yes | **yes** |
| `!urgent` hard rule (every option must use one) | yes | **softened** — prefer urgent items when natural; the named ingredients are the priority |
| Early-exit if `ingredients.txt` empty | yes | **no** — pantry + named items may still suffice |

Behavior NOT changed: `config.sh` sourcing, log file, exit codes, the `claude` CLI invocation pattern.

## Prompt

Single recipe (not three+stretch). The prompt instructs:

- Build ONE recipe that uses ALL of the named ingredients.
- Draw remaining ingredients from on-hand + pantry.
- Any named ingredient NOT present in either list MUST be tagged `**(MISSING — need to buy)**` in the Ingredients section.
- Same quality bar as the daily prompt: simple (≤30 min active), nutritious/healthy, exact quantities and times/temperatures, inline quantity on first mention in Steps.
- Prefer urgent items when they fit naturally; do not force them.
- Avoid repeating any of the recent recipes provided.

The prompt receives the same `INGREDIENTS`, `PANTRY`, `URGENT`, and `RECENT_RECIPES` material that the daily prompt builds, plus a new `NAMED` list derived from `--use` arguments.

## Output format

```
# Recipe with <named items joined by ", ">

## <Dish Name>
One-line description.
**Prep time**: X min | **Cook time**: X min | **Serves**: X
**Ingredients**
- exact quantities; any item from the named list that wasn't in on-hand/pantry is tagged **(MISSING — need to buy)**
**Steps**
1. Numbered, with exact times & temperatures.
**Why it's healthy**: one short line.
```

The single `## ` header is intentional: it matches the splitter in `notify_discord()`, producing one Discord embed.

## Discord delivery

`notify_discord()` currently builds its header line from the target date. Tweak it to accept the header text as a parameter:

- Daily path passes the existing `**Recipes for $date**` string.
- `--use` path passes `**Recipe with <named items>**`.

Color: the daily path uses green for on-hand chunks and orange for the final "Recommended" chunk. In `--use` mode there is exactly one chunk; use green (it's a cook-now recipe).

Everything else in `notify_discord()` — chunk splitting, body truncation, the `curl` POST — is unchanged.

## Error handling

| Condition | Behavior |
|---|---|
| `--use` with no value | Existing arg-parser error path; exit 2. |
| `--use` combined with `--date`, `--today`, or `--force` | Exit 2 with the rejection message, before any `claude` call. |
| Named item absent from both lists | Proceed; LLM tags it `(MISSING — need to buy)`. No script-level warning. |
| `ingredients.txt` empty | Proceed (the early-exit guard is skipped in `--use` mode). Pantry + named items provide the material. |
| `claude` CLI failure | Existing path: log error, print to stderr, exit 1. No date file to clean up in `--use` mode. |
| Discord post failure | Existing path: `curl` errors land in the log; script does not exit non-zero. |

## Components affected

- `generate-recipe.sh`:
  - Arg-parsing block (add `--use`, validate exclusions).
  - Prompt construction (branch on `--use` to build the single-recipe prompt; reuse `INGREDIENTS`, `PANTRY`, `URGENT`, `RECENT_RECIPES` collection).
  - Output flow (skip date-file write, HTML render, and dialog when `--use` is set).
  - `notify_discord()` signature (add header-text parameter; update both call sites).
- `README.md`: add `--use` to the Usage section, with one example.
- `CLAUDE.md`: no change (the existing description of `generate-recipe.sh` already accommodates "builds a prompt from data files").

## Out of scope (deferred)

- **Discord bot listener** (Phase 2). Triggering `--use` from a Discord message rather than the terminal. Requires a long-running bot process and message-content permissions; warrants its own spec.
- HTML rendering for `--use` output.
- Saving `--use` output to `recipes/` with a tagged filename (e.g. `2026-06-02-use-chicken.md`).
- A "stretch" companion recipe alongside the `--use` recipe.

## Manual test plan

- `recipe --use chicken` — recipe centered on chicken prints to stdout; no file written under `recipes/`.
- `recipe --use chicken --use spinach --notify discord` — both items appear in the recipe; Discord channel receives a single green embed with header `**Recipe with chicken, spinach**`.
- `recipe --use unicornmeat` — `unicornmeat` appears in Ingredients tagged `(MISSING — need to buy)`.
- `recipe --use chicken --date 2026-06-03` — exits 2 with the rejection message; no `claude` call.
- `recipe` (no `--use`) — daily flow unchanged: three on-hand + one stretch, date file written, dialog/Discord as configured.
