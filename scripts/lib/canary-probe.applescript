-- The watcher's contract, replayed end to end (see scripts/canary.sh).
-- argv: 1 = untrusted directory, 2 = launch command.
-- Returns "PASS|<tty>", "FAIL-TRUST|<tty>" or "FAIL-BANNER|<tty>".
--
-- The tab is re-found by tty on every read, and addressed DIRECTLY
-- (`tab i of window id wid`), never through a variable: `contents of x` where
-- x is a variable is AppleScript's dereference operator and yields the tab
-- OBJECT, silently, as the text "tab 1 of window id N". Only a directly typed
-- specifier reads Terminal's `contents` property. This probe caught the
-- production watcher making exactly that mistake (12 Aug).

on tabText(theTTY)
  tell application "Terminal"
    repeat with w in windows
      set wid to id of w
      set n to count of tabs of w
      repeat with i from 1 to n
        if (tty of tab i of window id wid) as text is theTTY then
          return contents of tab i of window id wid
        end if
      end repeat
    end repeat
    return ""
  end tell
end tabText

on pressReturn(theTTY)
  tell application "Terminal"
    repeat with w in windows
      set wid to id of w
      set n to count of tabs of w
      repeat with i from 1 to n
        if (tty of tab i of window id wid) as text is theTTY then
          do script "" in tab i of window id wid
          return
        end if
      end repeat
    end repeat
  end tell
end pressReturn

on run argv
  set dir to item 1 of argv
  set cmd to item 2 of argv
  tell application "Terminal"
    set newTab to do script "cd " & quoted form of dir & " && " & cmd
    set theTTY to (tty of newTab) as text
  end tell
  -- Sentinel 1: the trust prompt renders. Same cadence and needles as the
  -- watcher: "trust this folder" is v2.1.x's "Yes, I trust this folder" row,
  -- "Do you trust" is the pre-2.1 wording, kept for older CLIs.
  set sawTrust to false
  repeat 15 times
    delay 2
    set txt to my tabText(theTTY)
    if (txt contains "trust this folder") or (txt contains "Do you trust") then
      set sawTrust to true
      exit repeat
    end if
  end repeat
  if not sawTrust then return "FAIL-TRUST|" & theTTY
  -- The watcher's answer: one bare Return into the tab.
  my pressReturn(theTTY)
  -- Sentinel 2: the banner word the watcher settles on.
  set sawBanner to false
  repeat 10 times
    delay 2
    set txt to my tabText(theTTY)
    if txt contains "Claude" then
      set sawBanner to true
      exit repeat
    end if
  end repeat
  if not sawBanner then return "FAIL-BANNER|" & theTTY
  return "PASS|" & theTTY
end run
