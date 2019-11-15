#!/bin/bash

# Make sure b2b directory exists and is git clone of right project
[ -d ./b2b ] || (echo "B2B GIT repo not found, exiting"; exit 77); [ "$?" -eq 77 ]  && exit 2

CONTAINER=lua53

# Make symlink to docker for this dev environment
ln -sf b2b/apps/${CONTAINER}/Dockerfile .


sudo docker build -t ${CONTAINER} .
sudo docker run -v $PWD:/usr/src/ --rm  -it ${CONTAINER} lua5.3 /usr/src/scope.lua
