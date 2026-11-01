# Composer sizing on iPhone and iPad

The bottom of a conversation on a phone is where the user reads, steers and stops. On
2026-11-01 the stack below the transcript (execution-context row, then a composer card with a
two-line text area and two rows of chips) was about 210 pt tall on an iPhone 17 Pro. Most of it
was empty. This note compares that with the ChatGPT, Claude and Gemini iOS apps and records
what we changed.

## What the competitors do

None of the three publishes a spec, so these values are estimates. They come from public
write-ups, a published ChatGPT composer recreation and the shipping apps. Screenshots taken at
@3x were converted at 3 px = 1 pt. No App Store image was downloaded for pixel measurement.

| | ChatGPT | Claude | Gemini |
|---|---|---|---|
| Idle composer | One rounded bar, about 48 pt tall | A rounded card with the text line above one control row, about 90–100 pt | One full-width field ("Ask Gemini"), with no frame until you type |
| Corner radius | About 24 pt (a pill) | About 20–24 pt | Pill in the app, a rounded rectangle once you type |
| Leading | + (attachments and tools, in a sheet) | + (attachments, connectors) | + (camera, gallery, files, tools) |
| Trailing | Mic, then voice mode or Send | Model, mic, Send | Mic, Live |
| While running | Send turns into a filled Stop (a square in a circle) in the same place | Stop in Send's place | Stop in Send's place |
| Extras | Behind + in a bottom sheet. The model is in the navigation bar | Model chip in the control row | Behind + |
| Growth | Grows a line at a time, then scrolls inside after about 5–6 lines | The same | The same |
| Gap above the keyboard | About 8–12 pt | About 8 pt | About 8 pt |

Sources:
- ChatGPT composer recreation, with a 48 pt row, a radius of 24, a 12 pt gutter and a 12 pt
  gap above the keyboard: https://rnmotion.dev/animations/chatgpt-attachments
- ChatGPT release notes (tools folded into a single + sheet; long-press Send for the model):
  https://help.openai.com/en/articles/6825453-chatgpt-release-notes
- Stop takes Send's place while ChatGPT responds (community report):
  https://community.openai.com/t/ios-bug-message-action-bar-can-remain-hidden-at-the-end-of-long-responses/1400050
- Gemini iPhone redesign (the field, mic and Live on the right, + for attachments):
  https://9to5google.com/2025/02/24/gemini-iphone-redesign/ and
  https://9to5google.com/2025/03/20/gemini-app-plus-menu-redesign/
- Claude voice mode and the model picker on mobile:
  https://support.claude.com/en/articles/11101966-use-voice-mode
- Apple HIG: touch targets of at least 44 × 44 pt.

## What we do

These rules apply to iOS and iPadOS. The Mac keeps its card: it has room, and Esc already stops
a run there.

- **Idle and empty, keyboard down.** The composer is one bar: `+`, a single-line field, Mic,
  and Send or Stop. The card is 48 pt tall, the field and buttons sit in a 44 pt row, and the
  corner radius is 24 pt (`Theme.Radius.composer`). There is 6 pt of space above and below
  instead of 12 pt.
- **Focused, or with a draft or attachments.** The bar opens into the two-row form that Claude
  and Gemini use. The text grows from one line up to 6 lines, then scrolls (Expand allows more
  on a wide iPad). Below it is one control row: `+`, the approval mode, the agent and model
  chip, Mic, and Send or Stop. If that row doesn't fit, the model name gives way to the agent
  symbol before the row wraps. The text view keeps its place in the view tree, so focus
  survives the change.
- **New session.** The composer stays open there, because the agent and model are chosen
  before the first send. The page has no transcript to make room for.
- **Execution context.** The `Codex · Mac Studio · repo` row shows only while the composer is
  open, which includes the new-session page. When nothing can run, its warning always
  shows.
- **Approval mode.** It is hidden in the idle bar, except Full access, which stays visible as a
  warning.
- **Stop.** While the agent works, a filled Stop (a square in a primary-color circle, like
  ChatGPT's) sits where Send was, in the thumb zone. If you type while the agent works, both
  show: Send ("Send now · steer" or "Queue", which says what it does) and Stop to its right. We
  chose this over ChatGPT's Stop-only bar because steering is a core Omnigent action.
- **Escape.** Touch never mentions it. The running placeholder is "Steer the agent…" or "Queue
  a follow-up…", and the idle one is "Reply…". The Mac keeps "Esc to stop". A hardware
  keyboard on iPad still stops with Esc or ⌘., without saying so.
- **Sizes.** Send and Stop are 36 pt circles inside a 44 pt hit area. The other buttons in the
  bar have 44 pt targets.

The result on an iPhone 17 Pro: the idle bar in a running session takes about 60 pt including
its margins, down from about 210 pt. The bar is 48 pt and the same height as ChatGPT's. Open
for typing, it is the text plus one 44 pt row.

The playground shows these states under Composer, then "iPhone bar"
(`OMNIGENT_PLAYGROUND_SCENARIO=composer OMNIGENT_PLAYGROUND_COMPOSER=touch`). The Compact Width
scenario uses the touch bar as well.
