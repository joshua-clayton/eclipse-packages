#!/bin/bash
set -ex

cd $(dirname "$0")

helm lint .
mkdir -p output
helm template --debug . > output/blah

# Extract only sections from hawkbit's own templates (not bitnami subcharts)
awk '
  /^---$/ { if (keep && block != "") print block; block = "---"; keep = 0; next }
  /^# Source: hawkbit\/templates\// { keep = 1 }
  { block = block "\n" $0 }
  END { if (keep && block != "") print block }
' output/blah > output/blah_hawkbit

yamllint output/blah_hawkbit | wc -l && yamllint output/blah_hawkbit
