#!/usr/bin/env bash
# Entrypoint for the armada personal-build GitHub Actions runner container.
#
# /runner is a persistent bind mount. On first start it is empty, so seed it
# from the baked distribution at /opt/runner-dist. Once Runner.Listener exists
# the directory is considered initialised and is left untouched, so registered
# credentials in /runner/.runner survive container restarts.
set -euo pipefail

if [[ ! -e /runner/bin/Runner.Listener ]]; then
    echo "==> Seeding /runner from /opt/runner-dist (first start)"
    cp -a /opt/runner-dist/. /runner/
fi

cd /runner

# During registration the operator runs this image with a config command, e.g.
#   docker run --rm -it -v ...:/runner <image> ./config.sh --unattended ...
# so honour whatever command was passed. Default (no args handled by CMD) is
# ./run.sh.
exec "$@"
