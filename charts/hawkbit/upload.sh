#!/bin/sh
set -ex

cd "$(dirname "$0")"

VERSION=$(sed -n 's/^version: *\(.*\)$/\1/p' Chart.yaml)
NAME=$(sed -n 's/^name: *\(.*\)$/\1/p' Chart.yaml)
HELMFILE="${NAME}-${VERSION}.tgz"

mkdir -p output
rm -f "output/$HELMFILE"
helm dependency build --skip-refresh .
helm package . --destination output
echo "$JFROG_PASSWORD" | helm registry login -u "$JFROG_USERNAME" --password-stdin lvt.jfrog.io
helm push "output/$HELMFILE" oci://lvt.jfrog.io/helm-lvt
