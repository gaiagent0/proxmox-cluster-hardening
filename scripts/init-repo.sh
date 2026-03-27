#!/bin/bash
# Run once to initialise a local git repo and prepare for GitHub push.
# Usage: bash scripts/init-repo.sh
set -euo pipefail
REPO=$(basename "$(pwd)")
git init
git add .
git commit -m "Initial commit: scaffold and documentation"
echo ""
echo "Done. Push to GitHub:"
echo "  git remote add origin https://github.com/YOUR_USER/${REPO}.git"
echo "  git branch -M main"
echo "  git push -u origin main"
