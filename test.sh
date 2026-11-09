#!/bin/sh
# Run the kio-web tests and check the example. Needs `kio` on PATH, or KIO=path/to/kio.
set -e
KIO=${KIO:-kio}
cd "$(dirname "$0")"
for dir in tests examples/hello; do cp web.kio "$dir/web.kio"; done
cp json.kio api.kio tests/
trap 'rm -f tests/web.kio tests/json.kio tests/api.kio examples/hello/web.kio' EXIT
for t in web json api; do
    out=$("$KIO" run tests/${t}_test.kio | tail -1)
    [ "$out" = "0" ] || { echo "$t tests failed: check $out"; exit 1; }
done
"$KIO" check examples/hello/app.kio
KIO="$KIO" examples/notes/test.sh
echo ok
