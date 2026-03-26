#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Default to "plan" or the provided file name
PLAN_FILE="${1:-plan}"

# Check if the plan file exists
if [ ! -f "$PLAN_FILE" ]; then
  echo "Error: Plan file '$PLAN_FILE' not found."
  exit 1
fi

# Run terraform show and parse with jaq
OUTPUT=$(terraform show -no-color -json "$PLAN_FILE" | jaq -r '
  (.resource_changes // [])[] |
  select(.change.actions != ["no-op"] and .change.actions != ["read"]) |
  .change as $c |
  $c.actions as $a |

  # 1. Compare "before" and "after" to find changed fields for updates
  (if $a == ["update"] then
    (($c.after // {}) | to_entries | map(select(.value != ($c.before // {})[.key])) | map("[\(.key)=\(($c.before // {})[.key] | tostring)]->[\(.key)=\(.value | tostring)]") | join(", "))
  else "" end) as $diff |

  # 2. Flag situations where the resource will be replaced
  (if ($a | index("delete") != null) and ($a | index("create") != null) then
    "🚨 RECREATE 🚨 "
  else "" end) as $warn |

  # 3. Format the final output string
  $warn + .address + " [" + ($a | join(", ")) + "]" + (if $diff != "" then " -> changed: " + $diff else "" end)
')

if [ -z "$OUTPUT" ]; then
  echo "✅ No changes to apply. Infrastructure is up-to-date."
  rm -f "$PLAN_FILE"
else
  echo "$OUTPUT"
fi
