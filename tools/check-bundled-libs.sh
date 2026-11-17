#!/bin/bash
# Fails when a binary in the given folder (or app bundle) still loads a library from outside the
# system and the bundle (Homebrew, /usr/local, a build folder), or carries the builder's home
# folder in its strings: what ships must run on a Mac without Homebrew and name no one.
set -u
dir=${1:?usage: tools/check-bundled-libs.sh FOLDER}
status=0
while IFS= read -r -d '' f; do
    file -b "$f" | grep -q "Mach-O" || continue
    # Linked libraries other than the binary's own install name.
    own=$(otool -D "$f" 2>/dev/null | sed -n 2p)
    bad=$(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v -x -F "${own:-none}" \
        | grep -v -E '^(/System/|/usr/lib/|@executable_path/|@loader_path/|@rpath/)' || true)
    if [ -n "$bad" ]; then
        echo "$f loads a library from outside the bundle:"; echo "$bad" | sed 's/^/    /'; status=1
    fi
    case "$own" in
        /System/*|/usr/lib/*|@*|"") ;;
        *) echo "$f is named by a path outside the bundle: $own"; status=1 ;;
    esac
    if strings -a "$f" | grep -q -F "$HOME"; then
        echo "$f carries the home folder's path ($(strings -a "$f" | grep -c -F "$HOME") times)"; status=1
    fi
done < <(find "$dir" -type f -print0)
[ $status -eq 0 ] && echo "bundled libraries: all inside, no home folder"
exit $status
