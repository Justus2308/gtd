# MIDASIMG file format specification

A lightweight image format that facilitates loading its content right into a GPU buffer. Its content can optionally be losslessly compressed.

If an _invalid_ value or checksum is encountered a parser implementation is allowed to reject the input file.

## Layout

| HEADER | DATA | CHECKSUM |
|:-:|:-:|:-:|
| 9+ bytes | | 4 bytes |


## Header

| Magic Bytes | Version Tag | Flags | Name Length | Name |
|:-:|:-:|:-:|:-:|:-:|
| 4 bytes | 1 byte | 1 byte | 2 bytes | 1+ bytes |

### Magic Bytes:

```
'm', 'd', 's', 'i'
```
The magic bytes are always in the same order and must be interpreted one-by-one, regardless of endianness.

### Version Tag:

### Flags:

| 7-6 | 5 | 4 | 3-2 | 1 | 0 |
|:-:|:-:|:-:|:-:|:-:|:-:|
| Header Checksum | _Reserved_ | _Reserved_ | Channels | Endianness | Compression |

**Compression:**
- 0: none
- 1: lz4(hc)

**Endianness:**
- 0: big endian
- 1: little endian

**Channels:**
- 0-2: _invalid_
- 3: RGB
- 4: RGBA

**Header Checksum:**

Calculated by 2-bit wrapping addition of the version tag, the name length and all non-reserved flags (except for the header checksum itself).

Note that the probability that this checksum is spuriously correct is very high.
The checksum at the end of the file should always be checked to guarantee an uncompromised file.

### Name Length:

Must be interpreted as a 16-bit integer with the endianness specified by `flags`. \
A name length of 0 is _invalid_.

## Data

## Checksum
