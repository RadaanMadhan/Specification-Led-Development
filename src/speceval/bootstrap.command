#!/usr/bin/env bash
# Mac double-click wrapper — delegates to bootstrap.sh
DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$DIR/bootstrap.sh"
