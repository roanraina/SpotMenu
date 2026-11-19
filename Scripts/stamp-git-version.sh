#!/bin/sh
set -eu

source_root=$1
plist_path=$2

if ! commit=$(git -C "$source_root" rev-parse --short HEAD 2>/dev/null); then
    exit 0
fi

revision=$commit
if [ -n "$(git -C "$source_root" status --porcelain)" ]; then
    revision="$revision-dirty"
fi

/usr/libexec/PlistBuddy -c "Set :SpotMenuGitCommit $revision" "$plist_path" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add :SpotMenuGitCommit string $revision" "$plist_path"

printf '%s\n' "$commit"
