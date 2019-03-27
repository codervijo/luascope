FROM debian:latest
RUN  apt-get -y update && apt-get -y install lua5.1 lua-socket lua-sec
ADD  . /usr/src/luascope
CMD ["lua", "/usr/src/luascope/scope"]
