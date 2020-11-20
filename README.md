# luascope

Lua Scope is for looking into Lua chunk, or IOW, decode lua chunks.
A Lua 5.1/5.2/5.3 binary chunk disassembler.
LuaScope was inspired by Jein-Hong Man's ChunkSpy.
LuaScope attempts to be lua version agnostic.

- Based on ChunkSpy on Lua 5.1
- Works as ChunkSpy on Lua 5.2
- Works also as ChunkSpy on Lua 5.3


Dockerfile and shell scripts are provided for you to run 5.1/5.2/5.3 inside a container.

# Compatibility

This was tested only on Ubuntu, but should work on any Unix-based system.

# Steps to get started

1. Make sure b2b directory has git submodule by running
  either ```git clone --recurse-submodules https://github.com/codervijo/luascope```
  or     ```git submodule update --init```
2. Make sure docker is installed
3. Run ```./lua53dock.sh``` to run luascope with Lua-5.3

# How to use luascope
```
$ ./lua53dock.sh 
Found Lua Version	Lua 5.3
>print "hi"
hi
Pos   Hex Data   Description or Code
------------------------------------------------------------------------
0000                     ** source chunk: (interactive mode)
                         ** global header start **
0000  1B4C7561           header signature: "\27Lua"
0004  53                 version (major:minor hex digits)
0005  00                 format (0=official)
...
....
