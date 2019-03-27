#!/bin/bash
sudo docker build -t lua51 .
sudo docker run -v $PWD:/usr/src/ --rm  -it lua51 lua /usr/src/scope.lua
