# GTD
A cheap copy of Bloons TD 6 using Zig and raylib.

## Motivation
BTD6 is kind of infamous for its bad performance, especially late-game, so basically I want to see if I can build a more performant clone by using a systems programming language (the original is built in Unity). I know absolutely nothing about either games programming or computer graphics so this might end in disaster, but let's see...

## Architecture
### Memory Layout
Allocations are organized in a stack-like fashion (from left to right):

```
[game state] [persistent data] [per-round data] [volatile data]
```

The `game state` is stored on the stack of the game's parent scope. It obviously has to persist throughout the entire duration of the game.

`Persistent data` is allocated by the game's backing allocator at the beginning of the game. It persists over multiple rounds and stores e.g. the mutable states of apes placed by the player and the descriptors of all the effects these apes can apply to goons. The size of this segment is preferably fixed, but it can be extended if necessary.

`Per-round data` is everything that only exists within the bounds of a single round, e.g. goons and projectiles. Its expected size is calculated and allocated at the beginning of every round to avoid mid-round (re-)allocations.

Everything that needs to be allocated mid-round, but doesn't fit into its designated segment anymore becomes `volatile data`. This type of data is spontaneously allocated and freed at the end of every round. If a piece of data requires a longer lifetime/is supposed to be in the `persistent` segment, the entire segment gets reallocated and it is moved there.

### Concurrency Layout
Every game `State` maintains a `ThreadPool` that accepts `Task`s. These tasks can declare dependencies on each other which need to be respected. Dependency loops are detected at comptime.