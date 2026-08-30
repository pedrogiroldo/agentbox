#!/usr/bin/env bash
# ~/.agentbox/provision.sh
#
# Copy this file to provision.sh (drop the .example) and agentbox will run it
# in the background on every boot, as the `dev` user, with passwordless sudo.
#
# This is how you keep changes that live OUTSIDE your home directory — apt
# packages, system tweaks — across a container recreate. Everything inside
# /home/dev is already persistent and does not belong here.
#
# Rules of thumb:
#   * it must be idempotent: it runs again on every boot;
#   * keep it fast, or the box takes forever to become useful again;
#   * anything you would rather not wait for belongs in the Dockerfile.
set -euo pipefail

echo "provisioning..."

# --- system packages -------------------------------------------------------
# sudo apt-get update -qq
# sudo apt-get install -y --no-install-recommends postgresql-client redis-tools

# --- language runtimes -----------------------------------------------------
# uv python install 3.12
# npm install -g pnpm      # goes to ~/.local, so it already persists

# --- anything else ---------------------------------------------------------
# gh extension install github/gh-copilot

echo "provisioning done"
