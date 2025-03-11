# Goons TD
A cheap copy of Bloons TD 6 using [Zig](https://ziglang.org), [sokol](https://github.com/floooh/sokol) and [stb](https://github.com/nothings/stb).

## Motivation
BTD6 is kind of infamous for its bad performance, especially late-game, so basically I want to see if I can build a more performant clone by using a systems programming language (the original is built in Unity). I know absolutely nothing about either games programming or computer graphics so this might end in disaster, but let's see...

## Architecture
Code speaks for itself

<img src="https://external-preview.redd.it/x05HyMe3I3PnNWv82hZnLK3no_oZB9eltPArfALad3M.png?format=pjpg&auto=webp&s=276c4a030ba2d78f17aa7217c4c5cc332a8b283a" width=30%>

## Installation

### Requirements:
- [Zig 0.14.0](https://ziglang.org/download)
- libc

### Build:
```
git clone https://github.com/Justus2308/gtd
cd gtd
zig build --release=fast
```

### Options:
```
-Ddata-path=[string]          Absolute path to the desired game data directory
-Dslang=[enum]                Use a custom shader language if possible
```

To get a comprehensive overview of all available build options run

```
zig build --help
```

### Uninstall:
GTD will install some assets and save your gamestate in your default application data directory (or the one you set with `-Ddata-path`).
To cleanly remove everything run

```
zig build uninstall
```

If you've supplied a custom `data-path` to `zig build` you will have to supply it here again.

[This might not totally work yet](https://github.com/ziglang/zig/issues/14943).