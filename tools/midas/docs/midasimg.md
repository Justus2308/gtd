# MIDASIMG file format specification

A lightweight image format that facilitates loading its content right into a GPU buffer. Its content can optionally be losslessly compressed.

> [!IMPORTANT]
> This document specifies version `0x00` of the format. There are no guarantees of backward/forward compatability. \
> If an _invalid_ value or checksum is encountered a parser implementation is allowed to reject the input file.

## Layout:

| **Segment** | HEADER    | DATA            | CHECKSUM |
|:-           |:-:        |:-:              |:-:       |
| **Size**    | 24 bytes | variable length | 8 bytes  |

All numeric values in the `HEADER` and `CHECKSUM` segments which take up more than 1 byte must be interpreted as little endian.

---

# HEADER

| **Field** | Magic Bytes | Version Tag | Flags  | _Reserved_ | Uncompressed Data Length | Actual Data Length |
|:-         |:-:          |:-:          |:-:     |:-:         |:-:                       |:-:                 |
| **Size**  | 4 bytes     | 1 byte      | 1 byte | 2 bytes    | 8 bytes                  | 8 bytes            |

_Reserved_ fields must be all-zeroes.

## Magic Bytes:

```
'm', 'd', 's', 'i'
```

The `Magic Bytes` are always in the same order and must be interpreted one-by-one, regardless of endianness.

## Version Tag:

The `Version Tag` must be the same as the version specified by this document.

## Flags:

| **Bit Nr.** | 7-6  | 5-4   | 3-2      | 1          | 0               |
|:-           |:-:   |:-:    |:-:       |:-:         |:-:              |
| **Field**   | Type | Depth | Channels | _Reserved_ | Data Endianness |

_Reserved_ fields must be all-zeroes.

### Data Endianness:

| **Value**   | 0          | 1             |
|:-           |:-:         |:-:            |
| **Meaning** | big endian | little endian |

All numeric values in the `DATA` section which take up more than 1 byte must respect the endianness specified here.

### Channels:

| **Value**   | 0         | 1                 | 2   | 3    |
|:-           |:-:        |:-:                |:-:  |:-:   |
| **Meaning** | Grayscale | Grayscale + Alpha | RGB | RGBA |

Add 1 to get the effective channel count.

### Depth:

| **Value**   | 0     | 1      | 2      | 3         |
|:-           |:-:    |:-:     |:-:     |:-:        |
| **Meaning** | 8-bit | 16-bit | 32-bit | _invalid_ |

Shift `1` by `Depth` to get the amount of bytes per pixel component.

### Type:

| **Value**   | 0                   | 1                 | 2     | 3         |
|:-           |:-:                  |:-:                |:-:    |:-:        |
| **Meaning** | unsigned normalized | signed normalized | float | _invalid_ |

A `Depth` of 8 bits combined with the `Type` 'float' is _invalid_.

## Header Checksum:

Calculated by 8-bit wrapping addition of the `Version Tag`, the `Name Length` and all non-reserved `Flags`.

Note that the probability that this checksum is spuriously correct is rather high.
The `Checksum` at the end of the file should always be checked for a much stronger guarantee of an uncompromised file.

## Uncompressed Data Length:

The length of `DATA` after decompression in bytes. \
Must be interpreted as an unsigned 64-bit little endian integer.

If the data is uncompressed, this field must have the same value as `Actual Data Length`.
`Uncompressed Data Length` must always be greater than `Actual Data Length` if the data is compressed and must never be smaller than `Actual Data Length`, otherwise the file is considered _invalid_. \
A conformant decoder must infer whether `DATA` is compressed based on these criteria.

## Actual Data Length:

The length of `DATA` in bytes excluding padding. \
Must be interpreted as an unsigned 64-bit little endian integer. \
Must be a multiple of the effective channel count specified in the header.

# DATA

The uncompressed data must be a tightly packed sequence of pixels. Each pixel must consist of one component for each of the `Channels` specified in the header. Each component must consist of the amount of bits specified by `Depth` in the header \
This section may be compressed using [lz4](https://lz4.org/)(hc). The uncompressed data must be interpreted according to the `Data Endianness` specified in `Flags` if the individual values take up more than 1 byte.

The start and the end of this section are always aligned to an 8-byte boundary. If padding is necessary it must consist entirely of zeroes. The amount of padding must be minimal.

# CHECKSUM

An 8-byte [xxHash3](https://xxhash.com/) XXH3_64bits checksum of the entire file content up to this point, including potential padding and using the default seed (0). \
Must be interpreted as an unsigned 64-bit little endian integer. \
An implementation should check whether this checksum is consistent with the actual file content to detect data corruption.
