#!/bin/bash

export MIX_ENV=prod
export PORT=4800

echo "Stopping old copy of app, if any..."

_build/prod/rel/tasks2/bin/tasks2 stop || true

echo "Starting app..."

# Start to run in background from shell.
#_build/prod/rel/memory/bin/memory start

# Foreground for testing and for systemd
_build/prod/rel/tasks2/bin/tasks2 start

# TODO: Add a cron rule or systemd service file
#       to start your app on system boot.

