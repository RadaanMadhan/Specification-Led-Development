#!/usr/bin/env bash
# kill_hung.command — abort any in-flight verify-design or test scripts.
pkill -f "speceval.cli verify-design" 2>/dev/null && echo "killed speceval" || echo "no speceval"
pkill -f "test_m_best_variants" 2>/dev/null && echo "killed test_m_best_variants" || echo "no test_m_best"
echo "Done. Press any key to close."
read -n1 -r
