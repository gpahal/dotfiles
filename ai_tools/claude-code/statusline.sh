#!/bin/bash

# Claude Code status line: model, effort, context used, 5-hour rate limit, and git branch.
# Claude Code pipes session JSON on stdin and shows what this prints. Any field missing from
# the JSON is left out. See https://code.claude.com/docs/en/statusline

# One jq call for every field. The unit separator keeps empty fields in place, which a tab
# wouldn't, since read collapses runs of whitespace separators.
IFS=$'\x1f' read -r model effort context five_hour dir < <(
    jq -r '[
        .model.display_name // "",
        .effort.level // "",
        (.context_window.used_percentage // "" | if . == "" then . else round | tostring end),
        (.rate_limits.five_hour.used_percentage // "" | if . == "" then . else round | tostring end),
        .workspace.current_dir // ""
    ] | join("\u001f")' 2>/dev/null
)

parts=()
[ -n "$model" ] && parts+=("$model")
[ -n "$effort" ] && parts+=("$effort")
[ -n "$context" ] && parts+=("ctx $context%")
[ -n "$five_hour" ] && parts+=("5h $five_hour%")
if [ -n "$dir" ]; then
    branch="$(git -C "$dir" branch --show-current 2>/dev/null)"
    [ -n "$branch" ] && parts+=("$branch")
fi

line=""
for part in "${parts[@]+"${parts[@]}"}"; do
    line="${line:+$line · }$part"
done
echo "$line"
