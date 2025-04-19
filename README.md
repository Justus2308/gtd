# Goons TD
A cheap copy of Bloons TD 6 using [Zig](https://ziglang.org) and [sokol](https://github.com/floooh/sokol).

## Motivation
BTD6 is kind of infamous for its bad performance, especially late-game, so basically I want to see if I can build a more performant clone by using a systems programming language (the original is built in Unity). I know absolutely nothing about either games programming or computer graphics so this might end in disaster, but let's see...

## Architecture
Code speaks for itself

<img src="https://external-preview.redd.it/x05HyMe3I3PnNWv82hZnLK3no_oZB9eltPArfALad3M.png?format=pjpg&auto=webp&s=276c4a030ba2d78f17aa7217c4c5cc332a8b283a" width=30%>

## Installation

### Requirements:
- [Zig 0.14.0](https://ziglang.org/download)
- libc*

\*for targets that are not on [this list](https://ziglang.org/learn/overview/#zig-ships-with-libc)

### Build:
```
git clone https://github.com/Justus2308/gtd
cd gtd
zig build --release=fast
```

### Options:
```
-Dpackaging=[enum]           Use a custom packaging format
-Dpack-assets=[bool]         Pack all assets together with the executable
-Dslang=[enum]               Use a custom shader language if possible
-Duse-compute=[bool]         Make use of compute shaders if possible
```

To get a comprehensive overview of all available build options run

```
zig build --help
```

### Supported Build Hosts:
- Linux (x86-64/aarch64)
- macOS (x86-64/aarch64)
- Windows (x86-64)

### Supported Targets:
- Linux (most common desktop architectures)
- macOS (x86-64/aarch64)
- Windows (x86-64/x86/aarch64)
- iOS (aarch64)
- Emscripten (wasm32)
- *soon&#8482;:* Android (aarch64/arm)

## References

A list of resources that really helped me along the way:

- [R. Fabian: Data-Oriented Design](https://www.dataorienteddesign.com/dodbook/) (print version)
- [LearnOpenGL](https://learnopengl.com/)
- [Sokol Samples](https://github.com/floooh/sokol-samples)
- [C. Yuksel et al.: On the Parameterization of Catmull-Rom Curves](https://www.cemyuksel.com/research/catmullrom_param/catmullrom.pdf)
- [Resource efficient Thread Pools with Zig ](https://zig.news/kprotty/resource-efficient-thread-pools-with-zig-3291)