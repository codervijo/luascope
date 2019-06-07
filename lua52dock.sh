#!/bin/bash
#sudo docker build -t lua52 .
sudo docker run -v $PWD:/usr/src/ --rm  -it lua52 lua /usr/src/scope.lua
