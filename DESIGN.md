# SwarmSweep design

The implemented design of the SwarmSweep website (`web/`, exported to `dist/`). Values below are taken from the source after the final build; where a value is only in one file, that file is named.

## Overview

SwarmSweep is a one-task tool for wallet holders: connect, see which swarm-launched tokens you hold and which can be sold, sell them for $IMD, read the result. The visual character is a quiet, light tool: a warm off-white page, white surfaces with hairline borders, one deep-blue accent reserved for the primary action and the "route found" mark, and green and red used only for Sold and Unsold. Hierarchy comes from two weights and five sizes, not from colour or decoration. Density is moderate: 44px controls, 12px cell padding, 16px panel padding.

System-wide rules: the token file in `web/src/styles.css` (`:root`), the button and pill classes, the sheet pattern, and the responsive table-to-card rule. Page-specific arrangement: the single page's order (header, headline, summary panel, token list, footer note). A future page should reuse the primitives and the order of importance (action near the top), not copy the hero verbatim.

## Colors

All colours are declared in `oklch()` in `web/src/styles.css`. Primitives (`--gray-*`, `--blue-*`, `--green-*`, `--red-*`) are never used in a component; components reference the semantic tokens only.

| Token | Value | Job |
| --- | --- | --- |
| `--color-bg` | `--gray-50` `oklch(97.5% 0.004 80)` | page background |
| `--color-bg-surface` | `oklch(100% 0 0)` | panel, table, sheet, secondary button |
| `--color-bg-muted` | `--gray-100` | "No sell route found" pill, pressed row |
| `--color-bg-hover` | `--gray-100` | hover on secondary controls and sheet rows |
| `--color-text` | `--gray-950` `oklch(17% 0.015 80)` | primary text |
| `--color-text-secondary` | `--gray-600` `oklch(50% 0.012 80)` | labels, notes, hints, footer |
| `--color-text-disabled` | `--gray-400` `oklch(68% 0.01 80)` | greyed rows (`tr.dim`) |
| `--color-border` | `--gray-200` | hairlines: panel, table, rows, secondary button |
| `--color-accent` | `--blue-600` `oklch(42% 0.11 255)` | primary button fill, links, checkbox accent, route pill text |
| `--color-accent-hover` / `-active` | `--blue-700` / `--blue-800` | primary button hover / pressed |
| `--color-accent-soft` | `--blue-100` | route pill background |
| `--color-on-accent` | white | text on the primary button |
| `--color-ok` / `--color-ok-soft` | `--green-700` / `--green-100` | Sold pill |
| `--color-bad` / `--color-bad-soft` | `--red-700` / `--red-100` | Unsold pill |
| `--color-focus` | `--gray-950` | 2px `:focus-visible` ring, offset 2px |
| `--color-backdrop` | `oklch(17% 0.015 80 / 0.45)` | sheet backdrop |

One theme only (`color-scheme: light`); no dark theme is implemented. The probe measured all rendered text pairs at 4.5:1 or better (3:1 large); pairs over the translucent backdrop were not measured (see `artifacts/validation.md`).

## Typography

- Families: `--font-sans` (`ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", sans-serif`) for everything; `--font-mono` (`ui-monospace, "SF Mono", Menlo, Consolas, monospace`) for addresses only (`.mono`, `.addr`). No font files are shipped; the system face renders.
- Weights: 400 body, 600 headings, buttons, token names, values, pills. Nothing lighter or heavier.
- Scale, five sizes: `--text-xs` 13px notes and pills; `--text-sm` 14px table cells, labels, hints, dialog body; `--text-base` 16px body, buttons, token names; `--text-lg` 20px section headings (`.h3`, `.sheet-head h2`), summary values, brand; `--text-xl` 28px the page title.
- Line height 1.5 on the body; 1.1 on `h1`; 1.2 on section headings. `h1` has `letter-spacing: -0.02em` and `text-wrap: balance`; descriptions and notes use `text-wrap: pretty`. Prose is capped at 60ch (`.hero p`) and 70ch (`.foot`).
- Changing numbers (balances, values, totals) use `font-variant-numeric: tabular-nums` (`.num`, `.summary dd`, `.totals dd`).
- Root has `-webkit-font-smoothing: antialiased` and `-moz-osx-font-smoothing: grayscale`.

## Layout

- Content column `--content-width` 960px, centred, 16px inline padding (`#page`).
- Spacing is a 4px scale: `--space-1` 4, `-2` 8, `-3` 12, `-4` 16, `-6` 24, `-8` 32, `-12` 48. Sections in `main` are 24px apart; inside a panel, groups are 16px apart; inside a group, 8px or 4px.
- Alignment edges: everything starts at the column's leading edge; numbers end at the trailing edge (`text-align: end`).
- Header: brand at the leading edge, wallet control at the trailing edge; it wraps to two lines below about 380px (`.top { flex-wrap: wrap }`, `.wallet-state { margin-inline-start: auto }`), and the address never breaks (`.top .btn { white-space: nowrap }`).
- Summary: four columns (`.summary`: tokens held, sellable now, total value, yours after the fee) above 640px; two columns below.
- Actions: inline row above 640px; below, "Sell all" takes the full width and the two secondary buttons share a row.
- Token list: a real `<table>` above 640px (select, token, balance, value, status). Below 640px the `thead` is visually hidden and each row becomes a 3-column grid card (`grid-template-areas: "pick token balance" "pick status value"`) with `data-label` captions for balance and value. The table has `overflow: clip` for its radius; no text is clipped.
- Sheets (`.sheet`): bottom sheet with 48px rows below 640px, a centred 420px dialog above; the confirmation dialog (`.sheet-wide`) is 560px. Both scroll within `100dvh` and pad the bottom safe area.
- Logical properties (`padding-inline`, `margin-inline-start`, `text-align: start/end`) are used throughout, so the layout mirrors for RTL. Checked widths: 320, 390 and 1440 (see `artifacts/validation.md`); 200% zoom was not checked.

## Elevation and depth

Flat by default: structure comes from 1px `--color-border` hairlines on the panel, table and secondary controls. The only shadow is `--shadow-sheet` (`0 1px 2px oklch(0 0 0 / 0.06), 0 12px 32px oklch(0 0 0 / 0.14)`) on sheets, which have no border, so no surface carries both. Overlays sit on `--color-backdrop` at `z-index: 10`, and the page behind them is set `inert`.

## Shapes

- `--radius-sm` 6px: brand icon, close button, wallet marks.
- `--radius-md` 10px: buttons, sheet rows.
- `--radius-lg` 16px: panel, table, sheets.
- Pills are fully round (`999px`). Checkboxes are native, 20px, with `accent-color` set to the accent.

## Components

All in `web/src`; none is a published library export, each is a pattern with its source.

- **Button** (`styles.css` `.btn`): `.btn-primary` (accent fill, one per view), `.btn-secondary` (white, hairline), `.btn-small` (32px, inline in a table cell). 44px minimum height, 600 weight. States: hover (gated by `@media (hover: hover)`), pressed (`scale: 0.96`, darker accent), focus-visible ring, disabled at 55% opacity with `cursor: not-allowed`. Transitions name their properties and last 120ms; reduced motion removes them.
- **Connect control and sheet** (`wallet/ConnectSheet.tsx`): the network's connect structure. Disconnected: "Connect wallet". Connected: short address plus "Disconnect"; wrong chain adds "Switch to Ethereum". The sheet lists EIP-6963 wallets with their own icons, then Coinbase Wallet; on a phone browser the "Open in …" links first. It closes by backdrop, Escape and the × (`.x`, 32px); focus moves inside on open and returns to the trigger on close. Marks come from `wallet/wallet-icons.ts`.
- **Summary panel** (`App.tsx` `.panel`, `.summary`, `.actions`): a `<dl>` of four values, the action row and a polite `role="status"` line (`.status-line`) for notices, the unregistered-token count and pricing errors.
- **Owner setup panel** (`components/OwnerSetup.tsx`, `.panel.owner`, `.checks`): shown only when the connected wallet is the contract owner. A checklist of three rows, each a `.pill-ok` "Set" or `.pill-bad` "Missing" followed by what it is and a `.note` with the value to be set; then the action row ("Set up for this wallet (N transactions)" as `.btn-primary`, "Register all …" as `.btn-secondary`) and a live status line naming the transaction in flight.
- **Token list** (`components/TokenList.tsx`, `.tokens`): one row per held token, sellable first. Sellable rows have a checkbox labelled "Select SYMBOL", a route pill (`.pill-route`), USD value and IMD. Unsellable rows get `tr.dim` (disabled text colour) and a `.pill-muted` "No sell route found" with the launch id, the contract's reason and, for an unregistered token, whether its pool would buy it; the value cell shows the pool quote marked "if registered" or "No buyer in the pool". After a sale, `.pill-ok` "Sold" or `.pill-bad` "Unsold" with the explanation; a held refund shows a `.btn-small` "Claim refund". Empty, loading and disconnected states are single full-width rows (`tr.empty`).
- **Confirmation dialog** (`components/ConfirmDialog.tsx`, `.sheet-wide`): the list of tokens to sell (`.plan`), excluded tokens with reasons, totals (`.totals`: gross, 2% fee with the treasury link, "You receive" with its USD value), one explanatory paragraph, a live status line, and "Cancel" / "Sell N tokens". While a step runs the close controls are disabled and the primary reads "Selling…".
- **Pill** (`.pill` with `-route`, `-muted`, `-ok`, `-bad`): 13px, 600 weight, soft background, no border. Never the only cue: each is accompanied by text (route name, reason, amount).

## Do's and don'ts

- Start a new page from `#page` with a `.top` header and a `main` grid; keep the primary action within the first screen at 390px wide.
- One `.btn-primary` per view. Everything else is `.btn-secondary`; use `.btn-small` only inside table cells.
- New colours go through a semantic token in `:root`; do not use a `--gray-*` or `--blue-*` primitive in a component, and do not add a second accent hue. Green and red mean Sold and Unsold only.
- Stay inside the five type sizes and two weights. Addresses are `.mono`; prose is never monospace.
- Status always pairs colour with words (a pill plus a note), never colour alone.
- Overlays use the `.sheet-bg` / `.sheet` pair with `createPortal`, set `inert` on `#page`, and return focus to their trigger.
- Do not change how the site reaches the contracts (`constants.ts`, `config.ts`, `chain.ts`, `abi/`, `lib/sweep.ts`, `lib/launches.ts`, `lib/owner.ts`) for a visual change.
- Recipe for another page: copy `App.tsx`'s frame (header with `ConnectSheet`, a `.hero` with an `h1` of six words or fewer and one plain line, a `.panel` for the action, a `.list` for data), reuse `TokenList`'s table and card rules for any tabular data, and add text under 60 words on the first phone screen.
