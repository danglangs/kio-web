#!/bin/sh
# Run the kio-web tests and check the example. Needs `kio` on PATH, or KIO=path/to/kio.
set -e
KIO=${KIO:-kio}
cd "$(dirname "$0")"
for dir in tests examples/hello; do cp web.kio "$dir/web.kio"; done
cp json.kio tests/json.kio
trap 'rm -f tests/web.kio tests/json.kio examples/hello/web.kio' EXIT
for t in web json; do
    out=$("$KIO" run tests/${t}_test.kio | tail -1)
    [ "$out" = "0" ] || { echo "$t tests failed: check $out"; exit 1; }
done
"$KIO" check examples/hello/app.kio
echo ok
