#!/bin/sh
echo $JFROG_PASSWORD | helm registry login -u $JFROG_USERNAME --password-stdin lvt.jfrog.io
