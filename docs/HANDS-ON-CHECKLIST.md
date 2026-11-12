# Hands-on checklist

The things most likely to behave differently on a real machine than in Still's automated tests. Each takes a minute
or two. Note anything that feels slow, jumpy or confusing, not only what breaks.

Mark each one ✅ works, ⚠️ works but feels off (say how), or ❌ broken.

## Capture

1. **Area capture, twice in a row.** Take an area screenshot, then another straight away. The overlay should appear
   at once both times, with no flash of black or of the old picture. Move the mouse quickly in circles with the
   magnifier on: the pointer keeps up.
   - Scroll the wheel: the magnifier grows as it zooms in and shrinks as it zooms out, with the zoom (2× to 16×) in
     its corner.
   - Move into each corner of the screen: the magnifier moves to whichever side has room and never sits under the
     pointer.
   - Move over the Capture Bar: the crosshair and magnifier step aside, then come back when you leave it.
   - Window parts (Mac, Windows, Linux): hold Space over a browser and scroll down. The highlight moves from the
     whole window to just the page, without the tabs and toolbar; click captures only that. Scroll up goes back to
     the whole window. Try an app with panes too (a mail app, an editor): scrolling again steps into a pane.
   - The bar's icons and order match the Mac's (Windows/Linux): Area, Window, Screen, Scroll | Text, Record, Timer.
   - Two displays (Mac): open the Capture Bar and move the pointer onto the other display; the bar follows. Click
     Screen, then click the laptop's display: that one is captured. With Record chosen, it is recorded. In Record
     Screen's panel, the full-screen button lists each display by name.
   - Dock icon (Mac): clicking Still in the Dock opens the Capture Bar; right-click it for Settings.
   - Move a selection: start dragging an area, hold Space and keep moving: the box moves without changing size. Let
     go of Space to carry on resizing; release the mouse to capture. Shift still makes it square.
2. **Timer capture.** Start a capture with the 3-second timer. The countdown shows, Esc cancels it, and the
   screenshot taken at zero has no countdown in it.
3. **Move the Capture Bar.** Drag it by the Still icon, take a capture, then start a new one. It should be back in
   its usual place.
4. **Copy colour (C)** in the capture overlay. Paste somewhere: you should get the colour under the pointer.

## Editor

5. **Every tool once** (V A R F O L P H T N B U X S M D E C). Each key selects its tool, and Undo (Ctrl/⌘Z) undoes
   each mark.
6. **Hide Private Info** on a screenshot showing an email address and a card number. Both are covered and nothing
   else is.
7. **Crop to a size.** Pick YouTube Channel Banner in the crop tool (the Size list on Windows, Crop to Size in the
   resize menu on Mac). Drag a crop: it keeps the banner's shape and shows the part every device shows. The result is
   exactly 2560 × 1440, and one undo brings the original back.
- **Save for Size.** From the Floating Preview (Windows/Linux: the resize icon; Mac: right-click) or History's
  right-click menu, choose Save for Size…. Turn on Square, width 500, keep under 500 KB, JPEG, Save. The file is
  500 × 500 and under 500 KB, and the message says its size. Try a very small limit (10 KB): it still saves, smaller,
  and says it couldn't get under. Also in the editor: Save As → Image for Size… (⇧⌘E / Ctrl+Shift+E).
8. **Save, close, reopen.** Edit a capture, close the editor, then open it again from History. The marks are still
   editable.

## Recording

9. **Record 30 seconds with microphone and computer sound.** Talk and play a video. Both sounds are in the file and
   in step with the picture.
10. **Pause, resume and stop from the shortcut** while a full-screen app is in front.
11. **Windows: Cursor effects on.** Record with Settings → Recording → Cursor effects. In the video editor, the
    cursor's Size, Style and Smooth settings change the export.

## Video editor

12. **Opening speed.** Open a recording of a few minutes. Note how long the window takes to become usable and the
    film strip to fill in.
13. **Cut, Fast-Forward (S) and Undo.** Cut a stretch (X at start and end), fast-forward another, then undo both.
    Each undo should say what it undid.
14. **Speed Up Waits** on a recording with a progress bar or a page loading. Only the waiting parts become
    fast-forwards.
15. **Find Chapters** on a recording that switches between apps or pages. Check the chapter names make sense.
16. **Export with everything.** Add a zoom, text, a blur, an arrow, music and a Fade opening, then export at 1080p.
    Play the file: everything is where it was in the preview, and the music dips when you speak.
17. **Export GIF** of a 10-second stretch. Its size and frame count match what the GIF sheet said.
18. **Drag text anywhere.** Add text, drag its pill to a corner of the video, then export. The text is in the same
    place in the file. Choosing Top, Middle or Bottom again puts it back.

## History and sharing

- **Find Similar in a Folder.** Right-click a screenshot in History, choose Find Similar in a Folder…, and pick a
  folder that holds a copy of it (even resized). The copy is listed first; double-click opens it.

18. **A long History.** With 50+ captures, open History and scroll quickly. Nothing should stutter, and recordings
    should show their first frame as they come into view.
19. **A moved file.** Move one capture's file out of Still's folder in Explorer or Finder, then open History. Its
    tile says "File moved or deleted".

21. **Find Similar.** Take three screenshots of the same page (scroll a little between them) and one of something else.
    Right-click one in History and choose Find Similar: the other two show, the different one doesn't.
22. **Search the Web for This Image** on a screenshot of a product or landmark. The search page opens; paste (Ctrl+V or
    ⌘V) and the results are for that picture.

## Things going wrong

23. **Disk nearly full.** Export a long video to a nearly full USB stick or drive. You should get "There isn't enough
    space on the disk", not a long technical error.
24. **Recording with no sound.** Use Tighten Pauses on a recording made without a microphone. It should simply say
    the recording has no sound.

## Claude

- **Still for Claude.** In Settings → Claude, turn on Let Claude use Still and copy the Claude Desktop config (or
  the Claude Code command). Restart Claude, then ask it to “take a screenshot with Still”, “find my screenshot
  with the error message” and “describe it”. Each works, the screenshot appears in History, and turning the switch
  off makes Claude say Still isn’t letting it in.
- **Add to Claude (Mac, Windows).** With Claude Desktop installed, Settings → Claude → Add to Claude. Claude
  Desktop opens with Still ready to install; choose Install. Let Claude use Still is now on, and asking Claude to
  “take a screenshot with Still” works without copying any settings. Without Claude Desktop, Still says to get it.
- **Send to Claude.** Right-click a screenshot in History → Send to Claude. Claude opens; pasting adds the picture.
- **Describe with Claude.** In Settings → AI, choose Claude and save an Anthropic API key, then
  Describe Image on a screenshot.

## After the checklist

Send back the numbers marked ⚠️ or ❌ with a sentence each (and a screenshot where it helps). Those become the next
round of fixes.
