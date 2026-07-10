#!/usr/bin/env bash
set -euo pipefail

APP_PROCESS_NAME="${1:-RepoPrompt}"
WAIT_SECONDS="${REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_WAIT:-3}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

osascript - "$APP_PROCESS_NAME" "$WAIT_SECONDS" <<'APPLESCRIPT'
on labelText(elementRef)
    tell application "System Events"
        set parts to {}
        try
            set elementName to name of elementRef
            if elementName is not missing value and elementName is not "" then set end of parts to elementName as text
        end try
        try
            set elementDescription to description of elementRef
            if elementDescription is not missing value and elementDescription is not "" then set end of parts to elementDescription as text
        end try
        try
            set elementValue to value of elementRef
            if elementValue is not missing value and elementValue is not "" then set end of parts to elementValue as text
        end try
        return parts as text
    end tell
end labelText

on containsAnyNeedle(haystack, needles)
    set lowerHaystack to do shell script "printf %s " & quoted form of haystack & " | tr '[:upper:]' '[:lower:]'"
    repeat with needle in needles
        set lowerNeedle to do shell script "printf %s " & quoted form of (needle as text) & " | tr '[:upper:]' '[:lower:]'"
        if lowerHaystack contains lowerNeedle then return true
    end repeat
    return false
end containsAnyNeedle

on firstButtonContaining(containerRef, needles)
    tell application "System Events"
        try
            repeat with candidate in buttons of containerRef
                if my containsAnyNeedle(my labelText(candidate), needles) then return candidate
            end repeat
        end try
        try
            repeat with child in UI elements of containerRef
                set found to my firstButtonContaining(child, needles)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end firstButtonContaining

on clickButtonContaining(processRef, needles, requiredLabel)
    tell application "System Events"
        set targetButton to my firstButtonContaining(processRef, needles)
        if targetButton is missing value then error "Could not find " & requiredLabel
        click targetButton
    end tell
end clickButtonContaining

on run argv
    set appProcessName to item 1 of argv
    set waitSeconds to item 2 of argv as number

    tell application "System Events"
        if not (exists process appProcessName) then error appProcessName & " process is not running"
        tell process appProcessName
            set frontmost to true
            delay 0.5
            repeat 30 times
                if exists window 1 then exit repeat
                delay 0.2
            end repeat
            if not (exists window 1) then error appProcessName & " has no front window"
        end tell
    end tell

    -- Open the execution-location popover from the pill. The visible pill label is usually
    -- "Work locally" before an Agent session is bound to a worktree.
    tell application "System Events"
        set processRef to process appProcessName
        my clickButtonContaining(processRef, {"Work locally", "Workspace checkout", "New worktree"}, "execution-location pill")
    end tell

    delay waitSeconds

    -- Exercise at least one option if it is present, then switch back to local when available.
    tell application "System Events"
        set processRef to process appProcessName
        set newWorktreeButton to my firstButtonContaining(processRef, {"New worktree"})
        if newWorktreeButton is not missing value then
            click newWorktreeButton
            delay 0.5
        end if
        set localButton to my firstButtonContaining(processRef, {"Workspace checkout", "Work locally"})
        if localButton is not missing value then
            click localButton
            delay 0.5
        end if
    end tell

    -- If the app survived the popover open, async load, and option click path, the smoke passes.
    -- Also require the front window still exists so a silent crash-to-dock does not pass.
    tell application "System Events"
        if not (exists process appProcessName) then error appProcessName & " process exited during execution-location UI smoke"
        tell process appProcessName
            if not (exists window 1) then error appProcessName & " lost its front window during execution-location UI smoke"
        end tell
    end tell
end run
APPLESCRIPT

printf 'OK: Agent execution-location UI smoke passed for process %s.\n' "$APP_PROCESS_NAME"
