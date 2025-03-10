# Goons TD
A cheap copy of Bloons TD 6 using [Zig](https://ziglang.org), [sokol](https://github.com/floooh/sokol) and [stb](https://github.com/nothings/stb).

## Motivation
BTD6 is kind of infamous for its bad performance, especially late-game, so basically I want to see if I can build a more performant clone by using a systems programming language (the original is built in Unity). I know absolutely nothing about either games programming or computer graphics so this might end in disaster, but let's see...

## Architecture


## Installation

### Requirements:

- [Zig 0.14.0](https://ziglang.org/download)
- libc

### Build:

```
git clone https://github.com/Justus2308/gtd
cd gtd
zig build -Doptimize=ReleaseFast
```

### Options:

```
-Dasset-path=[string]      Absolute path to the game asset directory
-Dslang=[enum]             Use a custom shader language if possible

```

To get a comprehensive overview of all available build options use `zig build --help`.