#!/bin/bash
dbs=(/var/lib/pacman/local/*/files)
files=()
for db in "${dbs[@]}"; do
    # pkg="$(basename "$(dirname "$db")")"
    if grep --quiet "%BACKUP%" "$db"; then
        mapfile -t newfiles < <(sed -e '1,/%BACKUP%/d;s/ *[0-9a-f]*$//;/^$/d' "$db")
        # echo "$pkg had ${#newfiles} files"
        files+=("${newfiles[@]}")
    fi
done
for file in "${files[@]}"; do
    if test -e "/usr/local/$file"; then
        # echo "found /usr/local/$file"
        missing=0
    else
        echo "missing $file"
        missing=1
    fi
done
exit $missing
