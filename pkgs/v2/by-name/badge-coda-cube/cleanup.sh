#!/usr/bin/env bash
# After coda-cube: if it did not exit cleanly, its decoder channel and
# soph_drm's colour parameters are as it left them; --destroy puts both right.
set -euo pipefail
PATH=@path@

if [ "${SERVICE_RESULT:-}" = success ]; then
	exit 0
fi
exec coda-cube --destroy
