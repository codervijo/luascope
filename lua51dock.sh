#!/bin/bash

# Make sure b2b directory exists and is git clone of right project
[ -d ./b2b ] || (echo "B2B GIT repo not found. Please get all GIT submodules. Exiting"; exit 77); [ "$?" -eq 77 ]  && exit 2

CONTAINER=lua51

# Make symlink to docker for this dev environment
ln -sf b2b/apps/${CONTAINER}/Dockerfile .

if [[ "$(sudo docker images -q ${CONTAINER}:latest 2>/dev/null)" == "" ]];
then
	sudo docker build -t ${CONTAINER} .
fi
sudo docker run -v $PWD:/usr/src/ --rm  -it ${CONTAINER} lua /usr/src/scope.lua
