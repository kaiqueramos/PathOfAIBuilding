# PathOfAIBuilding

PathOfAIBuilding is a Path of Building Community fork with an AI build advisor inside
the desktop application. It reads the active PoE 1 build, uses PoB's calculated
numbers as the source of truth, proposes validated changes, and applies them only
after a preview.

## V1.1.4: canonical AI gem actions

Skill and minion questions now include PoB's canonical gem catalog, and the AI is
required to use those exact names in actions. A uniquely resolvable singular/plural
variation is normalized safely before preflight, so `Summon Raging Spirits` reaches
PoB as `Summon Raging Spirit`.

## V1.1.3: resilient AI chat

The AI tab now recovers when an HTTP request cannot start or response handling fails,
shows malformed action proposals instead of silently hiding them, and completes an
animated reply before a fast follow-up starts another stream.

## V1.1.2: replace unapplied AI proposals

When a player asks to correct an AI proposal before applying it, the next request
explicitly states that the earlier proposal was not applied. The current PoB build
state remains authoritative, and the replacement response can open a fresh action batch.

## V1.1.1: provider request options

AI Setup now exposes optional provider request JSON. This keeps the OpenAI-compatible
bridge generic while allowing model-specific fields such as MiniMax M3's
`{"thinking":{"type":"disabled"}}` without another code change.

## V1.1: PoE 3.29 support

The current release syncs the fork with Path of Building Community's 3.29 tree
update. It includes standard and Ruthless 3.29 passive-tree data, makes 3.29 the
latest tree for new builds, and retains support for existing tree versions.

The integrated AI workflow remains unchanged: PoB calculates the character state,
previews proposed changes, and requires user confirmation before applying them.

## V1: improve an existing build

The first release is intentionally narrow: open a build, ask a question, review the
answer and calculated diff, then choose whether to apply the proposed actions.

- Conversational `AI` tab with local history.
- Selective build context, including DPS, EHP, max hits, gear, skills, tree, and
  configuration when relevant.
- 18 typed actions for items, skills, levels, class, ascendancy, bandits, pantheon,
  configuration, passive nodes, masteries, tattoos, and jewels.
- Isolated preflight on a cloned build, real PoB recalculation, and an atomic
  fingerprint check before applying changes.
- Local API configuration with a protected key field, HTTPS validation, a real
  connection test, and request timeouts.

Trade pricing, budget planning, passive-tree optimization, and complete build
generation are not part of V1.

## Welcome to Path of Building, an offline build planner for Path of Exile

<p float="middle">
  <img alt="Tree tab" src="https://github.com/user-attachments/assets/0826b7ab-84ba-440f-be52-2f216f13e75c" width="48%" />
  <img alt="Items tab" src="https://github.com/user-attachments/assets/e5af1326-7e22-43d8-ab12-aa5500da611a" width="48%" />
</p>

### Upstream PoB features
* Comprehensive offence + defence calculations:
  * Calculate your skill DPS, damage over time, life/mana/ES totals and much more!
  * Can factor in auras, buffs, charges, curses, monster resistances and more, to estimate your effective DPS
  * Also calculates life/mana reservations
  * Shows a summary of character stats in the side bar, as well as a detailed calculations breakdown tab which can show you how the stats were derived
  * Supports all skills and support gems, and most passives and item modifiers
    * Throughout the program, supported modifiers will show in blue and unsupported ones in red
  * Full support for minions
  * Support for party play and support builds
* Passive skill tree planner:
  * Support for jewels including most radius/conversion and timeless jewels
  * Features alternate path tracing (mouse over a sequence of nodes while holding shift, then click to allocate them all)
  * Fully integrated with the offence/defence calculations; see exactly how each node will affect your character!
  * Can import PathOfExile.com and PoEPlanner.com passive tree links; links shortened with PoEURL.com also work
* Skill planner:
  * Add any number of main or supporting skills to your build
  * Supporting skills (auras, curses, buffs) can be toggled on and off
  * Automatically applies Socketed Gem modifiers from the item a skill is socketed into
  * Automatically applies support gems granted by items
* Item planner:
  * Add items from in game by copying and pasting them straight into the program!
  * Automatically adds quality to non-corrupted items
  * Search the trade site for the most impactful items
  * Fully integrated with the offence/defence calculations; see exactly how much of an upgrade a given item is!
  * Contains a searchable database of all uniques that are currently in game (and some that aren't yet!)
    * You can choose the modifier rolls when you add a unique to your build
    * Includes all league-specific items and legacy variants
  * Features an item crafting system:
    * You can select from any of the game's base item types
    * You can select prefix/suffix modifiers from lists
    * Custom modifiers can be added, with Master and Essence modifiers available
  * Also contains a database of rare item templates:
    * Allows you to create rare items for your build to approximate the gear you will be using
    * Choose which modifiers appear on each item, and the rolls for each modifier, to suit your needs
    * Has templates that should cover the majority of builds
* Other features:
  * You can import passive tree, items, and skills from existing characters
  * Share builds with other users by generating a share code
  * Automatic updating; most updates will only take a couple of seconds to apply

## Download and first run

1. Download `PathOfAIBuilding-v1.1.4-Windows-Portable.zip` from this fork's
   [Releases](https://github.com/kaiqueramos/PathOfAIBuilding/releases) page.
2. Extract the archive to a writable directory and run `Path of Building.exe`.
   Linux users can run the same executable through Wine or Proton.
3. Click `AI Setup` in the bottom toolbar. Enter an OpenAI-compatible HTTPS
   endpoint, your own API key, and the model identifier.
4. Optionally set provider-specific JSON under `Extra request options`. These
   fields are forwarded in the Chat Completions body without coupling the app to
   a provider; `model`, `messages`, and `stream` remain managed by the app.
5. Click `Test Connection`, save the configuration, open a build, and select the
   `AI` tab.

The portable build stores `ai_config.json` only in the extracted directory.
Installed/development layouts use PoB's normal user-data directory. The file is
never included in releases or sent anywhere except the endpoint you configure.
See [AI_SECURITY.md](AI_SECURITY.md) for the complete security model.

For example, MiniMax M3 can return concise answers instead of its default visible
reasoning trace with:

```json
{"thinking":{"type":"disabled"}}
```

## Changelog

The fork release history is on the [Releases](https://github.com/kaiqueramos/PathOfAIBuilding/releases)
page. The inherited PoB history is in [changelog.txt](changelog.txt).

## Contribute

Open issues and pull requests against the
[PathOfAIBuilding fork](https://github.com/kaiqueramos/PathOfAIBuilding).

## Licence
[MIT](https://opensource.org/licenses/MIT)

For 3rd-party licences, see [LICENSE](LICENSE.md).
The licencing information is considered to be part of the documentation.
