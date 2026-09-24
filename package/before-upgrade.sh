#!/bin/sh
# Runs on the controller before an upgrade unpacks the new package. fpm inlines it into a
# maintainer script function, where a failing command does not stop the upgrade

# The configuration is no longer a dpkg conffile and no longer travels inside the package, so
# there is nothing to save here: dpkg has no reason to touch "data/configuration.yaml" at all.

if ! command -v pnpm > /dev/null 2>&1; then
    echo "pnpm is not installed. Install via corepack..."
    corepack enable pnpm
fi
