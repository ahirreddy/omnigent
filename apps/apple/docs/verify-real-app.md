# Verify in the real app

The playground shows components on sample data. The shipped apps assemble the same components
over the stores, inside real windows, toolbars and navigation bars. Those differ in ways the
playground can't show. Every polish pass ends with this check, in the apps themselves.

## Run it

- Start the integration server (API on `127.0.0.1:6795` with the mock LLM). Use a session whose
  agent declares a terminal, and one with a long transcript.
- Build and run `OmnigentMac`. Then build `OmnigentMacAppStore` and `Omnigent` (iOS); both must
  build too.
- Open the same screens on Mac, on iPad at regular width, and on iPhone. Check light and dark,
  and at least one non-default theme.

## Check

1. **Same as the playground.** Put the change side by side with its playground scenario. Differences
   must come from real data (a harness without approval modes, a session without a host), never
   from missing wiring.
2. **Titlebar row.**
   - The tab strip, New Tab, the overview menu and the trailing cluster sit on one row.
   - Nothing folds into the toolbar's overflow menu at a normal window width.
   - Scrolled text never shows through the row.
   - With the sidebar collapsed, the strip starts after the traffic lights and the sidebar toggle.
3. **Tabs.** Tabs are scoped per session.
   - Selecting another session swaps the whole strip; coming back shows its tabs and the tab
     that was selected (a terminal stays selected, not the chat). The chat tab can't be closed.
   - New Session, Inbox, Canvas, Automations and Usage show full size with no strip.
   - Split view pairs two tabs of the same session; another session goes in another window.
   - Quit and relaunch: the window comes back on its page and each session on its tabs.
   - Dragging a tab reorders it and never moves the window.
   - Dragging the strip's empty space moves the window, and a double-click there zooms it.
   - Overflowing tabs fade at the edge, and the selected tab scrolls into view.
   - On iPhone (and iPad's Show All Tabs), the tab-count button zooms the shown tab out into a
     grid with one card per tab of this session; the chat's card has no close button, and a tap
     zooms back into that tab.
4. **Names.** The server reads as its display name, and "This Mac" for a loopback server. Never
   `127.0.0.1`: check the window title, sidebar switcher, composer context and menu bar.
5. **Shortcuts.** In a browser tab, Command-R reloads the page. Reconnect is Shift-Option-Command-R, and Option-Command-R renames the session. Each
   shortcut appears in exactly one enabled menu item.
6. **Idle CPU.** Open a conversation, wait 15 seconds, then check the app's CPU (`ps -o %cpu= -p <pid>`)
   on Mac and iPad. Anything above a few percent is a layout or focused-value loop. Bisect it
   before shipping.
7. **Emphasis.** Pink appears only on "needs you" and the single primary action, including the
   sign-in flow. No accent-tinted toolbar items.
8. **Theme.** The theme applies at the window root: sidebar, canvas, sheets and popovers all
   follow it, including after a change in Settings without relaunching.
9. **Tests.** Run both editions' hosted tests with a live server (`LiveServerStreamingTests`),
   the remote browser package tests with a live host (`RemoteBrowserViewE2ETests`), and, on an
   idle machine, the Mac UI target (launch smoke, `WindowChromeUITests`). Attach the real-app
   screenshots (Mac light and dark, iPad, iPhone) to the change.
