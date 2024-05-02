#!/bin/bash -e

cmd="./scripts/update-metadata-yaml.sh"
updates=(
	"splunk-otel-java"
	"splunk-otel-dotnet"
   "splunk-otel-js"
)

for args in "${updates[@]}"; do
  echo "> $cmd $args"
  $cmd $args
  echo
done