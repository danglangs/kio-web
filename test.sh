#!/bin/sh
# Run the kio-web tests and check the example. Needs `kio` on PATH, or KIO=path/to/kio.
set -e
KIO=${KIO:-kio}
cd "$(dirname "$0")"
for dir in tests examples/hello; do cp web.kio "$dir/web.kio"; done
trap 'rm -f tests/web.kio examples/hello/web.kio' EXIT
out=$("$KIO" run tests/web_test.kio | tail -1)
[ "$out" = "Int(0)" ] || { echo "tests failed: check $out"; exit 1; }
"$KIO" check examples/hello/app.kio
echo ok
