# Apache Parquet — File Format Specification

> Compiled from the `File Format` section of the Apache Parquet documentation site
> (`apache/parquet-site`, `production` branch) plus the full underlying specification
> documents from `apache/parquet-format` that those pages embed.
>
> Read this together with the canonical Thrift definition
> ([`parquet.thrift`](https://github.com/apache/parquet-format/blob/master/src/main/thrift/parquet.thrift))
> to fully understand the format. All embedded documents are licensed under the
> Apache License 2.0.

## Table of contents

1. [File Format Overview](#1-file-format-overview)
2. [Metadata](#2-metadata)
3. [Types](#3-types)
4. [Logical Types](#4-logical-types)
5. [Geospatial Types](#5-geospatial-types)
6. [Variant Binary Encoding](#6-variant-binary-encoding)
7. [Variant Shredding](#7-variant-shredding)
8. [Nested Encoding](#8-nested-encoding)
9. [Nulls](#9-nulls)
10. [Data Pages](#10-data-pages)
11. [Column Chunks](#11-column-chunks)
12. [Checksumming](#12-checksumming)
13. [Error Recovery](#13-error-recovery)
14. [Compression](#14-compression)
15. [Encodings](#15-encodings)
16. [Encryption (Modular Encryption)](#16-encryption-modular-encryption)
17. [Bloom Filter](#17-bloom-filter)
18. [Page Index](#18-page-index)
19. [Binary Protocol Extensions](#19-binary-protocol-extensions)
20. [Configurations](#20-configurations)
21. [Extensibility](#21-extensibility)
22. [Implementation Status](#22-implementation-status)
23. [Format Versions (Features and Versions)](#23-format-versions-features-and-versions)

---

## 1. File Format Overview

This file and the thrift definition should be read together to understand the format.

```
    4-byte magic number "PAR1"
    <Column 1 Chunk 1>
    <Column 2 Chunk 1>
    ...
    <Column N Chunk 1>
    <Column 1 Chunk 2>
    <Column 2 Chunk 2>
    ...
    <Column N Chunk 2>
    ...
    <Column 1 Chunk M>
    <Column 2 Chunk M>
    ...
    <Column N Chunk M>
    File Metadata
    4-byte length in bytes of file metadata (little endian)
    4-byte magic number "PAR1"
```

In the above example, there are N columns in this table, split into M row
groups. The file metadata contains the locations of all the column chunk
start locations. More details on what is contained in the metadata can be found
in the Thrift definition.

File metadata is written after the data to allow for single pass writing.

Readers are expected to first read the file metadata to find all the column
chunks they are interested in. The columns chunks should then be read sequentially.

The format is explicitly designed to separate the metadata from the data. This
allows splitting columns into multiple files, as well as having a single metadata
file reference multiple parquet files.

---

## 2. Metadata

There are two types of metadata: file metadata, and page header metadata.

All thrift structures are serialized using the TCompactProtocol. The full
definition of these structures is given in the Parquet
[Thrift definition](https://github.com/apache/parquet-format/blob/master/src/main/thrift/parquet.thrift).

### File metadata

File metadata is described by the `FileMetaData` structure. This file metadata
provides offset and size information useful when navigating the Parquet file.

### Page header

Page header metadata (`PageHeader` and children) is stored in-line with the page
data, and is used in the reading and decoding of data.

---

## 3. Types

The types supported by the file format are intended to be as minimal as possible,
with a focus on how the types effect on disk storage. For example, 16-bit ints
are not explicitly supported in the storage format since they are covered by
32-bit ints with an efficient encoding. This reduces the complexity of implementing
readers and writers for the format. The types are:

```
  - BOOLEAN: 1 bit boolean
  - INT32: 32 bit signed ints
  - INT64: 64 bit signed ints
  - INT96: 96 bit signed ints (deprecated; only used by legacy implementations)
  - FLOAT: IEEE 32-bit floating point values
  - DOUBLE: IEEE 64-bit floating point values
  - BYTE_ARRAY: arbitrarily long byte arrays
  - FIXED_LEN_BYTE_ARRAY: fixed length byte arrays
```

---

## 4. Logical Types

Logical types are used to extend the types that parquet can be used to store,
by specifying how the primitive types should be interpreted. This keeps the set
of primitive types to a minimum and reuses parquet's efficient encodings. For
example, strings are stored with the primitive type `BYTE_ARRAY` with a `STRING`
annotation.

### Metadata

The parquet format's `LogicalType` stores the type annotation. The annotation
may require additional metadata fields, as well as rules for those fields.

There is an older representation of the logical type annotations called `ConvertedType`.
To support backward compatibility with old files, readers should interpret `LogicalTypes`
in the same way as `ConvertedType`, and writers should populate `ConvertedType` in the metadata
according to well defined conversion rules.

### Compatibility

The Thrift definition of the metadata has two fields for logical types: `ConvertedType` and `LogicalType`.
`ConvertedType` is an enum of all available annotations. Since Thrift enums can't have additional type parameters,
it is cumbersome to define additional type parameters, like decimal scale and precision
(which are additional 32 bit integer fields on SchemaElement, and are relevant only for decimals) or time unit
and UTC adjustment flag for Timestamp types. To overcome this problem, a new logical type representation was introduced into
the metadata to replace `ConvertedType`: `LogicalType`. The new representation is a union of structs of logical types,
this way allowing more flexible API, logical types can have type parameters.

`ConvertedType` is deprecated. However, to maintain compatibility with old writers,
Parquet readers should be able to read and interpret `ConvertedType` annotations
in case `LogicalType` annotations are not present. Parquet writers must always write
`LogicalType` annotations where applicable, but must also write the corresponding
`ConvertedType` annotations (if any) to maintain compatibility with old readers.

### String Types

#### STRING

`STRING` may only be used to annotate the `BYTE_ARRAY` primitive type and indicates
that the byte array should be interpreted as a UTF-8 encoded character string.
The sort order used for `STRING` strings is unsigned byte-wise comparison.
`STRING` corresponds to `UTF8` ConvertedType.

#### ENUM

`ENUM` annotates the `BYTE_ARRAY` primitive type and indicates that the value
was converted from an enumerated type in another data model (e.g. Thrift, Avro, Protobuf).
Applications using a data model lacking a native enum type should interpret `ENUM`
annotated field as a UTF-8 encoded string. The sort order is unsigned byte-wise comparison.

#### UUID

`UUID` annotates a 16-byte `FIXED_LEN_BYTE_ARRAY` primitive type. The value is
encoded using big-endian, so that `00112233-4455-6677-8899-aabbccddeeff` is encoded
as the bytes `00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff`. The sort order is
unsigned byte-wise comparison.

### Numeric Types

#### Signed Integers

`INT` annotation can be used to specify the maximum number of bits in the stored value.
The annotation has two parameters: bit width and sign. Allowed bit width values are
`8`, `16`, `32`, `64`, and sign can be `true` or `false`. For signed integers, the
second parameter should be `true`, for example, a signed integer with bit width of 8
is defined as `INT(8, true)`. Implementations may use these annotations to produce
smaller in-memory representations when reading data.

If a stored value is larger than the maximum allowed by the annotation, the behavior
is not defined. Implementations must not write values that are larger than the
annotation allows.

`INT(8, true)`, `INT(16, true)`, and `INT(32, true)` must annotate an `int32`
primitive type and `INT(64, true)` must annotate an `int64` primitive type.
`INT(32, true)` and `INT(64, true)` are implied by the `int32` and `int64` primitive
types if no other annotation is present and should be considered optional. The sort
order used for signed integer types is signed.

#### Unsigned Integers

`INT` annotation can also specify unsigned integer types along with a maximum number
of bits. The second parameter should be `false`, for example `INT(8, false)`.
`INT(8, false)`, `INT(16, false)`, and `INT(32, false)` must annotate an `int32`
primitive type and `INT(64, false)` must annotate an `int64` primitive type. The
sort order used for unsigned integer types is unsigned.

#### Deprecated integer ConvertedType

`INT_8`, `INT_16`, `INT_32`, and `INT_64` annotations specify signed integers with
8, 16, 32, or 64 bit width. `UINT_8`, `UINT_16`, `UINT_32`, and `UINT_64` specify
unsigned integers. `INT_8`/`INT_16`/`INT_32` and `UINT_8`/`UINT_16`/`UINT_32` must
annotate an `int32`; `INT_64`/`UINT_64` must annotate an `int64`.

Backward compatibility mapping:

| ConvertedType | LogicalType |
|---------------|-------------|
| INT_8  | IntType (bitWidth = 8, isSigned = true) |
| INT_16 | IntType (bitWidth = 16, isSigned = true) |
| INT_32 | IntType (bitWidth = 32, isSigned = true) |
| INT_64 | IntType (bitWidth = 64, isSigned = true) |
| UINT_8  | IntType (bitWidth = 8, isSigned = false) |
| UINT_16 | IntType (bitWidth = 16, isSigned = false) |
| UINT_32 | IntType (bitWidth = 32, isSigned = false) |
| UINT_64 | IntType (bitWidth = 64, isSigned = false) |

#### DECIMAL

`DECIMAL` annotation represents arbitrary-precision signed decimal numbers of
the form `unscaledValue * 10^(-scale)`.

The primitive type stores an unscaled integer value. For `BYTE_ARRAY` and
`FIXED_LEN_BYTE_ARRAY`, the unscaled number must be encoded as two's complement using
big-endian byte order (the most significant byte is the zeroth element). The
scale stores the number of digits of that value that are to the right of the
decimal point, and the precision stores the maximum number of digits supported
in the unscaled value.

If not specified, the scale is 0. Scale must be zero or a positive integer less
than or equal to the precision. Precision is required and must be a non-zero positive
integer. A precision too large for the underlying type is an error.

`DECIMAL` can be used to annotate the following types:
* `int32`: for 1 <= precision <= 9
* `int64`: for 1 <= precision <= 18; precision < 10 will produce a warning
* `fixed_len_byte_array`: `precision` is limited by the array size. Length `n`
  can store <= `floor(log_10(2^(8*n - 1) - 1))` base-10 digits
* `byte_array`: `precision` is not limited, but is required. The minimum number of
  bytes to store the unscaled value should be used.

The sort order used for `DECIMAL` values is signed comparison of the represented
value. If the column uses `int32` or `int64` physical types, then signed comparison of
the integer values produces the correct ordering. If the physical type is fixed, then
the correct ordering can be produced by flipping the most-significant bit in the first
byte and then using unsigned byte-wise comparison.

#### FLOAT16

The `FLOAT16` annotation represents half-precision floating-point numbers in the 2-byte
IEEE little-endian format. The primitive type is a 2-byte `FIXED_LEN_BYTE_ARRAY`. Like
`FLOAT` and `DOUBLE`, the sort order for `FLOAT16` is signed with special handling for
NaNs and signed zeros. Writers should use IEEE754TotalOrder for consistent handling of
these edge cases.

### Temporal Types

#### DATE

`DATE` is used for a logical date type, without a time of day. It must annotate an
`int32` that stores the number of days from the Unix epoch, 1 January 1970. The sort
order used for `DATE` is signed.

#### TIME

`TIME` is used for a logical time type without a date with millisecond, microsecond,
or nanosecond precision. The type has two type parameters: UTC adjustment (`true` or
`false`) and unit (`MILLIS`, `MICROS`, or `NANOS`).

`TIME` with unit `MILLIS` must annotate an `int32` storing the number of milliseconds
after midnight. `TIME` with unit `MICROS` must annotate an `int64` storing microseconds
after midnight. `TIME` with unit `NANOS` must annotate an `int64` storing nanoseconds
after midnight. The sort order used for `TIME` is signed.

Deprecated ConvertedType counterparts: `TIME_MILLIS` (UTC normalized, MILLIS,
annotates `int32`) and `TIME_MICROS` (UTC normalized, MICROS, annotates `int64`).
Writers must annotate local time with these legacy annotations too for forward
compatibility.

#### TIMESTAMP

In data annotated with the `TIMESTAMP` logical type, each value is a single `int64`
number decoded into year, month, day, hour, minute, second and subsecond fields. A
value defined this way does not necessarily correspond to a single instant on the
time-line, and such interpretations are allowed on purpose.

The `TIMESTAMP` type has two type parameters:
- `isAdjustedToUTC` must be either `true` or `false`.
- `unit` must be one of `MILLIS`, `MICROS`, or `NANOS` (subject to expansion). Unknown
  units must be handled as unsupported features rather than errors.

**Instant semantics (`isAdjustedToUTC=true`):** the number of milliseconds, microseconds
or nanoseconds elapsed since the Unix epoch, 1970-01-01 00:00:00 UTC. Each value
unambiguously identifies a single instant. Time zone information is lost.

**Local semantics (`isAdjustedToUTC=false`):** represents year/month/day/hour/minute/
second/subsecond fields in a local timezone regardless of which time zone is local.
Such timestamps should always be displayed the same way. They do not identify instants
unambiguously. The encoding treats every day as exactly 86400 seconds, ignoring DST,
relative to the reference local timestamp 1970-01-01 00:00:00.

**Common considerations:** every `int64` represents a valid timestamp, but the year
may fall outside practical limits. Not every field combination can be encoded
(out-of-range fields like hour=25, minute=61, month=13, Feb 29 in a non-leap year).
`NANOS` can only represent 1677-09-21 00:12:43 to 2262-04-11 23:47:16. The sort order
used for `TIMESTAMP` is signed.

Deprecated ConvertedType counterparts: `TIMESTAMP_MILLIS` and `TIMESTAMP_MICROS`
(both UTC normalized, annotate `int64`). Writers must annotate local timestamps with
these legacy annotations too.

#### INTERVAL

`INTERVAL` is used for an interval of time. It must annotate a `fixed_len_byte_array`
of length 12, storing three little-endian unsigned integers: months, days, and
milliseconds. This representation is independent of any particular timezone or date,
and each component is independent of the others. The sort order used for `INTERVAL`
is undefined — no min/max statistics should be saved, and non-compliant statistics
must be ignored on read.

### Embedded Types

Embedded types do not have type-specific orderings unless otherwise specified.

#### JSON

`JSON` is used for an embedded JSON document. It must annotate a `BYTE_ARRAY` primitive
type, interpreted as a UTF-8 encoded string of valid JSON. Sort order: unsigned
byte-wise comparison.

#### BSON

`BSON` is used for an embedded BSON document. It must annotate a `BYTE_ARRAY` primitive
type, interpreted as an encoded BSON document. Sort order: unsigned byte-wise
comparison.

#### VARIANT

`VARIANT` is used for a Variant value. It must annotate a group containing a field named
`metadata` and a field named `value`, both of type `binary` (`BYTE_ARRAY`). It can store
either an unshredded or a shredded Variant value.

* The Variant group must be annotated with the `VARIANT` logical type, with the version
  number included in the declaration.
* The `metadata` field is required and must be a valid Variant metadata component (see
  [Variant Binary Encoding](#6-variant-binary-encoding)).
* When present, the `value` field must be a valid Variant value component.
* The `value` field is required for unshredded Variant values.
* The `value` field is optional and may be null only when parts of the Variant value are
  shredded (see [Variant Shredding](#7-variant-shredding)).

Unshredded representation:
```
optional group variant_unshredded (VARIANT(1)) {
  required binary metadata;
  required binary value;
}
```

Example shredded representation:
```
optional group variant_shredded (VARIANT(1)) {
  required binary metadata;
  optional binary value;
  optional int64 typed_value;
}
```

#### GEOMETRY

`GEOMETRY` is used for geospatial features in the Well-Known Binary (WKB) format with
linear/planar `edges` interpolation. It must annotate a `BYTE_ARRAY` primitive type.
The type has one parameter:
- `crs`: optional CRS string. If unset, defaults to `"OGC:CRS84"` (longitude, latitude
  based on the WGS84 datum).

Sort order is undefined — no min/max statistics, and non-compliant statistics must be
ignored on read.

#### GEOGRAPHY

`GEOGRAPHY` is used for geospatial features in the WKB format with an explicit
(non-linear/non-planar) `edges` interpolation algorithm. It must annotate a `BYTE_ARRAY`
primitive type. Parameters:
- `crs`: optional geographic CRS string where longitudes are bound by [-180, 180] and
  latitudes by [-90, 90]. If unset, defaults to `"OGC:CRS84"`.
- `algorithm`: optional edge interpolation algorithm; one of `SPHERICAL`, `VINCENTY`,
  `THOMAS`, `ANDOYER`, `KARNEY`. If unset, defaults to `SPHERICAL`.

Sort order is undefined — no min/max statistics, and non-compliant statistics must be
ignored on read.

### Nested Types

This section specifies how `LIST` and `MAP` can be used to encode nested types by adding
group levels around repeated fields that are not present in the data.

An unannotated repeated field that is neither contained by a `LIST`/`MAP`-annotated group
nor annotated by `LIST`/`MAP` should be interpreted as a required list of required
elements where the element type is the type of the field.

```
WARNING: writers should not produce list types like these examples! They are
just for the purpose of reading existing data for backward-compatibility.

// List<Integer> (non-null list, non-null elements)
repeated int32 num;

// List<Tuple<Integer, String>> (non-null list, non-null elements)
repeated group my_list {
  required int32 num;
  optional binary str (STRING);
}
```

For all fields in the schema, implementations should use either `LIST`/`MAP` annotations
_or_ unannotated repeated fields, but not both.

#### Lists

`LIST` must always annotate a 3-level structure:

```
<list-repetition> group <name> (LIST) {
  repeated group list {
    <element-repetition> <element-type> element;
  }
}
```

* The outer-most level must be a group annotated with `LIST` containing a single field
  named `list`. Its repetition (`optional`/`required`) determines list nullability.
* The middle level, named `list`, must be a repeated group with a single field named
  `element`.
* The `element` field encodes the list's element type and repetition (`required` or
  `optional`).

Examples:
```
// List<String> (list non-null, elements nullable)
required group my_list (LIST) {
  repeated group list {
    optional binary element (STRING);
  }
}

// List<List<Integer>>
optional group array_of_arrays (LIST) {
  repeated group list {
    required group element (LIST) {
      repeated group list {
        required int32 element;
      }
    }
  }
}
```

**Backward-compatibility rules.** New writers should always produce the 3-level structure.
The repeated group should be named `list` and the element field `element`, but these
names should not be enforced as errors when reading. Some existing data uses a 2-level
structure (no inner element layer). Element types should be determined by:

1. If the repeated field is not a group, then its type is the element type and elements
   are required.
2. If the repeated field is a group with multiple fields, then its type is the element
   type and elements are required.
3. If the repeated field is a group with one field with `repeated` repetition, then its
   type is the element type and elements are required.
4. If the repeated field is a group with one field named either `array` or the
   `LIST`-annotated group's name with `_tuple` appended, then the repeated type is the
   element type and elements are required.
5. Otherwise, the repeated field's type is the element type with the repeated field's
   repetition.

#### Maps

`MAP` must annotate a 3-level structure:

```
<map-repetition> group <name> (MAP) {
  repeated group key_value {
    required <key-type> key;
    <value-repetition> <value-type> value;
  }
}
```

* The outer-most level must be a group annotated with `MAP` containing a single field
  named `key_value`. Its repetition determines map nullability.
* The middle level, named `key_value`, must be a repeated group with a `key` field and,
  optionally, a `value` field, and no other fields.
* The `key` field must have repetition `required` and always be present, and must be the
  first field of the `key_value` group.
* The `value` field encodes value type and repetition (`required`, `optional`, or
  omitted). If present it must be the second field. If omitted, it can represent a map
  with all null values or a set of keys.

Example:
```
// Map<String, Integer>
required group my_map (MAP) {
  repeated group key_value {
    required binary key (STRING);
    optional int32 value;
  }
}
```

If there are multiple key-value pairs for the same key, the final value for that key
must be the last value. The `MAP` annotation should not be used to encode multi-maps
using duplicate keys.

**Backward-compatibility rules.** The repeated group should be named `key_value` with
fields `key` and `value`, but misnaming should be tolerated (identified by position).
Some existing data incorrectly used `MAP_KEY_VALUE` in place of `MAP`; a group annotated
with `MAP_KEY_VALUE` not contained by a `MAP`-annotated group should be handled as a
`MAP`-annotated group.

### UNKNOWN (always null)

When discovering the schema of existing data, values are sometimes always null with no
type information. The `UNKNOWN` type annotates a column that is always null (similar to
the Null type in Avro and Arrow).

---

## 5. Geospatial Types

This section contains the specification of geospatial types and statistics.

### Background

The Geometry and Geography class hierarchy and its Well-Known Text (WKT) and Well-Known
Binary (WKB) serializations (ISO variant supporting XY, XYZ, XYM, XYZM) are defined by
the OpenGIS Implementation Specification for Geographic information — Simple feature
access — Part 1: Common architecture, from OGC (Open Geospatial Consortium). The version
of the OGC standard first used here is 1.2.1, but future versions may also be used if
the WKB representation remains wire-compatible.

### Coordinate Reference System

Coordinate Reference System (CRS) is a mapping of how coordinates refer to locations on
Earth. The default CRS `OGC:CRS84` means features must be stored in longitude/latitude
order based on the WGS84 datum.

Non-default CRS values are specified by any string that uniquely identifies a CRS.
Suggested formats:
* `<projjson>` — a complete CRS definition embedded directly using the PROJJSON
  specification.
* `<authority>:<code>` — e.g. `OGC:CRS84`, `OGC:CRS83`, `EPSG:4326`, `EPSG:3857`,
  `IGNF:ATI`.
* `srid:<identifier>` — a reference using a Spatial reference identifier (SRID), e.g.
  `srid:0`.
* `projjson:<key_name>` — where `<key_name>` refers to a key within the file key-value
  metadata holding a PROJJSON CRS definition.

For geographic CRS, longitudes are bound by [-180, 180] and latitudes by [-90, 90].

### Edge Interpolation Algorithm

An algorithm for interpolating edges, one of:
* `SPHERICAL`: edges interpolated as geodesics on a sphere.
* `VINCENTY`: Vincenty's formulae.
* `THOMAS`: Thomas, Spheroidal geodesics, reference systems, & local geometry (1970).
* `ANDOYER`: Thomas, Mathematical models for navigation systems (1965).
* `KARNEY`: Karney, "Algorithms for geodesics" (2013), and GeographicLib.

### Logical Types

Two geospatial logical type annotations are supported:
* `GEOMETRY`: WKB format with linear/planar edge interpolation.
* `GEOGRAPHY`: WKB format with an explicit (non-linear/non-planar) edge interpolation
  algorithm.

### Statistics

`GeospatialStatistics` is a struct specific to `GEOMETRY` and `GEOGRAPHY` logical types
storing statistics of a column chunk. It is an optional field in the `ColumnMetaData`
and contains a Bounding Box and Geospatial Types.

#### Bounding Box

A geospatial instance has at least X and Y coordinate dimensions (X is
longitude/easting, Y is latitude/northing) and can optionally have Z (height/elevation)
and/or M values (a fourth dimension, e.g. linear reference value, timestamp, etc.).

When calculating a bounding box, null or NaN values in a coordinate dimension are
skipped. If a dimension has only null or NaN values, that dimension is omitted. If
either X or Y is missing, the bounding box itself is not produced.

For X values only, xmin may be greater than xmax; an object matches if it contains an X
such that `x >= xmin` OR `x <= xmax`. This wraparound occurs only when the bounding box
crosses the antimeridian. `xmin`, `xmax`, `ymin`, `ymax` are also known as westernmost,
easternmost, southernmost, northernmost. For `GEOGRAPHY` types, X and Y are restricted
to [-180, 180] and [-90, 90].

```thrift
struct BoundingBox {
  1: required double xmin;
  2: required double xmax;
  3: required double ymin;
  4: required double ymax;
  5: optional double zmin;
  6: optional double zmax;
  7: optional double mmin;
  8: optional double mmax;
}
```

#### Geospatial Types

A list of geospatial types from all instances in the column, or an empty list if not
known. Values are WKB (ISO-variant) integer codes:

| Type               | XY   | XYZ  | XYM  | XYZM |
| :----------------- | :--- | :--- | :--- | :--- |
| Point              | 0001 | 1001 | 2001 | 3001 |
| LineString         | 0002 | 1002 | 2002 | 3002 |
| Polygon            | 0003 | 1003 | 2003 | 3003 |
| MultiPoint         | 0004 | 1004 | 2004 | 3004 |
| MultiLineString    | 0005 | 1005 | 2005 | 3005 |
| MultiPolygon       | 0006 | 1006 | 2006 | 3006 |
| GeometryCollection | 0007 | 1007 | 2007 | 3007 |

A list of multiple values indicates multiple geospatial types are present. An empty
array explicitly signals the types are not known. The types in the list must be unique.

### Coordinate Axis Order

The axis order of coordinates in WKB and bounding box stored in Parquet follows the
de facto standard and is always (x, y) where x is easting/longitude and y is
northing/latitude. This explicitly overrides the axis order specified in the CRS.

---

## 6. Variant Binary Encoding

A Variant represents a type that contains one of:
- Primitive: A type and corresponding value (e.g. INT, STRING)
- Array: An ordered list of Variant values
- Object: An unordered collection of string/Variant pairs. An object may not contain
  duplicate keys.

A Variant is encoded with 2 binary values, the value and the metadata. There are a fixed
number of allowed primitive types (table below). The encoding allows representation of
semi-structured data (e.g. JSON) in a form that can be efficiently queried by path, with
efficient access to nested data even in wide or deep structures. Aside from metadata,
each nested Variant value is contiguous and self-contained.

### Variant in Parquet

A Variant value in Parquet is represented by a group with 2 fields, named `value` and
`metadata`:
* The Variant group must be annotated with the `VARIANT` logical type.
* Both fields must be of type `binary` (`BYTE_ARRAY`).
* `metadata` is `required` and must be valid Variant metadata.
* `value` must be `required` for unshredded values, or `optional` if parts of the value
  are shredded as typed Parquet columns.

Unshredded representation:
```
optional group variant_name (VARIANT(1)) {
  required binary metadata;
  required binary value;
}
```

Example shredded representation:
```
optional group shredded_variant_name (VARIANT(1)) {
  required binary metadata;
  optional binary value;
  optional int64 typed_value;
}
```

### Metadata encoding

The encoded metadata always starts with a header byte:
```
             7     6  5   4  3             0
            +-------+---+---+---------------+
header      |       | R |   |    version    |
            +-------+---+---+---------------+
                ^         ^
                |         +-- sorted_strings
                +-- offset_size_minus_one
```
The `version` is a 4-bit value that must always contain `1`. `sorted_strings` is a
1-bit value indicating whether dictionary strings are sorted and unique.
`offset_size_minus_one` is a 2-bit value; the actual number of bytes, `offset_size`, is
`offset_size_minus_one + 1`. Bit 5 (`R`) is reserved and must be ignored by readers.

The metadata is encoded as the header byte, then `dictionary_size` (unsigned
little-endian, `offset_size` bytes — the number of strings in the dictionary), then an
`offset` list of `dictionary_size + 1` values (each `offset_size` bytes, the starting
byte offset of the i-th string), then `bytes` storing all UTF-8 string values. The first
offset is always `0`; the last is the total length of `bytes`.

#### Metadata encoding grammar

```
metadata: <header> <dictionary_size> <dictionary>
header: 1 byte (<version> | <sorted_strings> << 4 | (<offset_size_minus_one> << 6))
version: a 4-bit version ID. Currently, must always contain the value 1
sorted_strings: a 1-bit value indicating whether dictionary strings are sorted and unique
offset_size_minus_one: 2-bit value providing the number of bytes per dictionary size and offset field.
dictionary_size: `offset_size` bytes. unsigned little-endian value indicating the number of strings in the dictionary
dictionary: <offset>* <bytes>
offset: `offset_size` bytes. unsigned little-endian value indicating the starting position of the ith string in `bytes`. The list should contain `dictionary_size + 1` values, where the last value is the total length of `bytes`.
bytes: UTF-8 encoded dictionary string values
```

Notes: offsets are relative to the start of `bytes`; the length of the ith string is
`offset[i+1] - offset[i]`; the first offset is always 0 (redundant, kept to simplify
in-memory processing). If `sorted_strings` is 1, strings must be unique and sorted in
lexicographic order.

### Value encoding

The entire encoded Variant value includes the `value_metadata` byte and 0+ bytes for
`val`:
```
           7                                  2 1          0
          +------------------------------------+------------+
value     |            value_header            | basic_type |  <-- value_metadata
          +------------------------------------+------------+
          |                                                 |
          :                   value_data                    :  <-- 0 or more bytes
          |                                                 |
          +-------------------------------------------------+
```

**Basic Type.** A 2-bit value representing which basic type the Variant value is.

**Value Header.** A 6-bit value whose format depends on the `basic_type`:
- Primitive (`basic_type`=0): a 6-bit `primitive_header`.
- Short string (`basic_type`=1): a 6-bit `short_string_header` equal to the string
  length.
- Object (`basic_type`=2): `field_offset_size_minus_one` (2 bits),
  `field_id_size_minus_one` (2 bits), and `is_large` (1 bit, bit reserved at top). Actual
  byte counts are the 2-bit values + 1. `is_large`=0 uses 1 byte for the element count,
  `is_large`=1 uses 4 bytes.
- Array (`basic_type`=3): `field_offset_size_minus_one` (2 bits) and `is_large` (1 bit).

**Value Data.** Depends on the type:
- Primitive: depends on the `primitive_header` value (see table).
- Short string: the UTF-8 encoded bytes of the string.
- Object: `num_elements` (1 or 4 bytes), then `num_elements` `field_id` values (indices
  into the metadata dictionary), then `num_elements + 1` `field_offset` values (byte
  offsets relative to the first value), then the `value` list. Field IDs and offsets
  must be in lexicographical order of field names; values themselves may be in any order
  (so offsets may not be monotonically increasing).
- Array: `num_elements` (1 or 4 bytes), then `num_elements + 1` `field_offset` values,
  then `num_elements` `value` entries.

#### Value encoding grammar

```
value: <value_metadata> <value_data>?
value_metadata: 1 byte (<basic_type> | (<value_header> << 2))
basic_type: ID from Basic Type table. <value_header> must be a corresponding variation
value_header: <primitive_header> | <short_string_header> | <object_header> | <array_header>
primitive_header: ID from Primitive Type table. <val> must be a corresponding variation of <primitive_val>
short_string_header: unsigned string length in bytes from 0 to 63
object_header: (is_large << 4 | field_id_size_minus_one << 2 | field_offset_size_minus_one)
array_header: (is_large << 2 | field_offset_size_minus_one)
value_data:  <primitive_val> | <short_string_val> | <object_val> | <array_val>
primitive_val: see table for binary representation
short_string_val: UTF-8 encoded bytes
object_val: <num_elements> <field_id>* <field_offset>* <fields>
array_val: <num_elements> <field_offset>* <fields>
num_elements: a 1- or 4-byte unsigned little-endian value (depending on is_large)
field_id: a 1-, 2-, 3-, or 4-byte unsigned little-endian value, indexing into the dictionary
field_offset: a 1-, 2-, 3-, or 4-byte unsigned little-endian value, offset in bytes within fields
fields: <value>*
```

Boolean and null types have no `value_data`. Each array/object must contain exactly
`num_elements + 1` `field_offset` values; the last is one byte past the last field. When
more than 255 elements are present, `is_large` must be true (implementations may use a
larger value than necessary). The "short string" type is semantically identical to the
"string" primitive type, for strings < 64 bytes. The Decimal type contains a scale but
no precision; implied precision is `floor(log_10(|val|)) + 1` (and `1` when `val` is 0).

> Note: Decimal values in the Variant binary encoding use little-endian byte order for
> the unscaled value. This differs from Parquet's DECIMAL logical type which uses
> big-endian two's complement encoding for `BYTE_ARRAY` and `FIXED_LEN_BYTE_ARRAY`.

### Encoding types

*Variant basic types*

| Basic Type   | ID  | Description                                       |
|--------------|-----|---------------------------------------------------|
| Primitive    | `0` | One of the primitive types                        |
| Short string | `1` | A string with a length less than 64 bytes         |
| Object       | `2` | A collection of (string-key, variant-value) pairs |
| Array        | `3` | An ordered sequence of variant values             |

*Variant primitive types*

| Equivalence Class | Variant Physical Type | Type ID | Equivalent Parquet Type | Binary format |
|----------------------|-----------------------------|---------|-----------------------------|----------|
| NullType  | null | `0` | UNKNOWN | none |
| Boolean | boolean (True) | `1` | BOOLEAN | none |
| Boolean | boolean (False) | `2` | BOOLEAN | none |
| Exact Numeric | int8 | `3` | INT(8, true) | 1-byte |
| Exact Numeric | int16 | `4` | INT(16, true) | 2-byte little-endian |
| Exact Numeric | int32 | `5` | INT(32, true) | 4-byte little-endian |
| Exact Numeric | int64 | `6` | INT(64, true) | 8-byte little-endian |
| Double | double | `7` | DOUBLE | IEEE little-endian |
| Exact Numeric | decimal4 | `8` | DECIMAL(precision, scale) | 1-byte scale [0,38], then little-endian unscaled value |
| Exact Numeric | decimal8 | `9` | DECIMAL(precision, scale) | 1-byte scale [0,38], then little-endian unscaled value |
| Exact Numeric | decimal16 | `10` | DECIMAL(precision, scale) | 1-byte scale [0,38], then little-endian unscaled value |
| Date | date | `11` | DATE | 4-byte little-endian |
| Timestamp | timestamp | `12` | TIMESTAMP(isAdjustedToUTC=true, MICROS) | 8-byte little-endian |
| TimestampNTZ | timestamp without time zone | `13` | TIMESTAMP(isAdjustedToUTC=false, MICROS) | 8-byte little-endian |
| Float | float | `14` | FLOAT | IEEE little-endian |
| Binary | binary | `15` | BYTE_ARRAY | 4-byte little-endian size, then bytes |
| String | string | `16` | STRING | 4-byte little-endian size, then UTF-8 bytes |
| TimeNTZ | time without time zone | `17` | TIME(isAdjustedToUTC=false, MICROS) | 8-byte little-endian |
| Timestamp | timestamp with time zone | `18` | TIMESTAMP(isAdjustedToUTC=true, NANOS) | 8-byte little-endian |
| TimestampNTZ | timestamp without time zone | `19` | TIMESTAMP(isAdjustedToUTC=false, NANOS) | 8-byte little-endian |
| UUID | uuid | `20` | UUID | 16-byte big-endian |

*Decimal table*

| Decimal Precision     | Decimal value type | Variant Physical Type |
|-----------------------|--------------------|-----------------------|
| 1 <= precision <= 9   | int32              | decimal4              |
| 10 <= precision <= 18 | int64              | decimal8              |
| 19 <= precision <= 38 | int128             | decimal16             |
| > 38                  | Not supported      |                       |

### String values, field order, versions

All strings within the Variant binary format must be UTF-8 encoded (dictionary keys,
short strings, and long strings). For objects, field IDs and offsets must be listed in
the order of the corresponding field names, sorted lexicographically (unsigned byte
ordering for UTF-8); field values need not follow this order. An implementation may rely
on this order (e.g. binary search). Field names are case-sensitive and must be unique
per object.

An implementation is not expected to parse a Variant whose metadata version is higher
than it supports. New types may be added without incrementing the version ID; an
implementation should still be able to read the rest of the value.

---

## 7. Variant Shredding

Shredding extracts certain fields of a Variant into separate Parquet columns to improve
performance — enabling columnar encoding, column statistics for data skipping, and
partial projections.

### Variant Metadata

Variant metadata is stored in the top-level Variant group in a binary `metadata` column
regardless of whether the value is shredded. All `value` columns within the Variant must
use the same `metadata`, and all field names (shredded or not) must be present in the
metadata.

### Value Shredding

Each `value` field may have an associated shredded field named `typed_value` storing the
value when it matches a specific type. When `typed_value` is present, readers must
reconstruct shredded values according to this specification. Columns are accessed by
name, not position.

Example shredding `measurement` as `int64`:
```
required group measurement (VARIANT(1)) {
  required binary metadata;
  optional binary value;
  optional int64 typed_value;
}
```

The series `34, null, "n/a", 100` would be stored as:

| Value   | `metadata`       | `value`               | `typed_value` |
|---------|------------------|-----------------------|---------------|
| 34      | `01 00` v1/empty | null                  | `34`          |
| null    | `01 00` v1/empty | `00` (null)           | null          |
| "n/a"   | `01 00` v1/empty | `13 6E 2F 61` (`n/a`) | null          |
| 100     | `01 00` v1/empty | null                  | `100`         |

Interpretation of the two fields:

| `value`  | `typed_value` | Meaning                                                     |
|----------|---------------|-------------------------------------------------------------|
| null     | null          | The value is missing; only valid for shredded object fields |
| non-null | null          | The value is present and may be any type, including null    |
| null     | non-null      | The value is present and is the shredded type               |
| non-null | non-null      | The value is present and is a partially shredded object     |

Writers must not produce data where both `value` and `typed_value` are non-null, unless
the Variant value is an object (a partially shredded object). If a Variant is missing
where a value is required, readers must return a Variant null (`00`).

#### Shredded Value Types

| Variant Type    | Parquet Physical Type             | Parquet Logical Type     |
|-----------------|-----------------------------------|--------------------------|
| boolean         | BOOLEAN                           |                          |
| int8            | INT32                             | INT(8, true)             |
| int16           | INT32                             | INT(16, true)            |
| int32           | INT32                             |                          |
| int64           | INT64                             |                          |
| float           | FLOAT                             |                          |
| double          | DOUBLE                            |                          |
| decimal4        | INT32                             | DECIMAL(P, S)            |
| decimal8        | INT64                             | DECIMAL(P, S)            |
| decimal16       | BYTE_ARRAY / FIXED_LEN_BYTE_ARRAY | DECIMAL(P, S)            |
| date            | INT32                             | DATE                     |
| time            | INT64                             | TIME(false, MICROS)      |
| timestamptz(6)  | INT64                             | TIMESTAMP(true, MICROS)  |
| timestamptz(9)  | INT64                             | TIMESTAMP(true, NANOS)   |
| timestampntz(6) | INT64                             | TIMESTAMP(false, MICROS) |
| timestampntz(9) | INT64                             | TIMESTAMP(false, NANOS)  |
| binary          | BYTE_ARRAY                        |                          |
| string          | BYTE_ARRAY                        | STRING                   |
| uuid            | FIXED_LEN_BYTE_ARRAY[len=16]      | UUID                     |
| array           | GROUP; see Arrays                 | LIST                     |
| object          | GROUP; see Objects                |                          |

#### Arrays

Arrays are shredded using a 3-level Parquet list for `typed_value`. If the value is not
an array, `typed_value` must be null; if it is an array, `value` must be null. The list
`element` must be a required group containing `value` and/or `typed_value` (at least one
present). All elements must be present (the array encoding does not allow missing
elements); null elements are encoded in `value` as Variant null (`00`).

```
optional group tags (VARIANT(1)) {
  required binary metadata;
  optional binary value;
  optional group typed_value (LIST) {   # must be optional to allow a null list
    repeated group list {
      required group element {          # shredded element
        optional binary value;
        optional binary typed_value (STRING);
      }
    }
  }
}
```

#### Objects

Object fields are shredded using a Parquet group for `typed_value` that contains shredded
fields. If the value is an object, `typed_value` must be non-null; otherwise it must be
null. Each shredded field is a required group containing optional `value` and
`typed_value`. The `value` column of a partially shredded object must never contain
fields represented by shredded `typed_value` columns. Field present-but-null is encoded
in `value` as Variant null (`00`); field missing is `value`=null and `typed_value`=null.

```
optional group event (VARIANT(1)) {
  required binary metadata;
  optional binary value;                # a variant, expected to be an object
  optional group typed_value {          # shredded fields for the variant object
    required group event_type {
      optional binary value;
      optional binary typed_value (STRING);
    }
    required group event_ts {
      optional binary value;
      optional int64 typed_value (TIMESTAMP(true, MICROS));
    }
  }
}
```

When both `value` and `typed_value` for a field are non-null, engines should fail; if
they read anyway, the `typed_value` column must be used. Invalid cases must not be
produced by writers.

### Nesting

The `typed_value` associated with any Variant `value` field can be any shredded type,
including nested objects and arrays (e.g. shredding sub-fields `location` as an object
and `tags` as an array).

### Data Skipping

Statistics for `typed_value` columns can be used for file, row group, or page skipping
when `value` is always null (missing). When the corresponding `value` column is all
nulls, all values must be the shredded type, so comparisons with values of that type
(and `IS NULL`/`IS NOT NULL`, `IS NAN`/`IS NOT NAN`) are valid. Comparisons with other
types are not necessarily valid. Casting behavior for Variant is delegated to processing
engines.

### Reconstructing a Shredded Variant

An unshredded Variant can be recovered with a recursive algorithm; the initial call is
`construct_variant` with the top-level Variant group fields:

```python
def construct_variant(metadata: Metadata, value: Variant, typed_value: Any) -> Variant:
    """Constructs a Variant from value and typed_value"""
    if typed_value is not None:
        if isinstance(typed_value, dict):
            # this is a shredded object
            object_fields = {
                name: construct_variant(metadata, field.value, field.typed_value)
                for name, field in typed_value.items()
            }
            if value is not None:
                # this is a partially shredded object
                assert isinstance(value, VariantObject), "partially shredded value must be an object"
                assert typed_value.keys().isdisjoint(value.keys()), "object keys must be disjoint"
                return VariantObject(metadata, object_fields).union(VariantObject(metadata, value))
            else:
                return VariantObject(metadata, object_fields)
        elif isinstance(typed_value, list):
            # this is a shredded array
            assert value is None, "shredded array must not conflict with variant value"
            elements = [
                construct_variant(metadata, elem.value, elem.typed_value)
                for elem in list(typed_value)
            ]
            return VariantArray(metadata, elements)
        else:
            # this is a shredded primitive
            assert value is None, "shredded primitive must not conflict with variant value"
            return primitive_to_variant(typed_value)
    elif value is not None:
        return Variant(metadata, value)
    else:
        # value is missing
        return None
```

### Backward and forward compatibility

Shredding is optional; readers must continue to read a group containing only `value` and
`metadata`. Engines that do not write shredded values must be able to read shredded
values per this spec or must fail. Different files may contain conflicting shredding
schemas (different `typed_value` columns with incompatible types for the same Variant);
it may not be possible to specify a single shredded schema for all files in a table.

---

## 8. Nested Encoding

To encode nested columns, Parquet uses the Dremel encoding with definition and
repetition levels. Definition levels specify how many optional fields in the path for
the column are defined. Repetition levels specify at what repeated field in the path the
value is repeated. The max definition and repetition levels can be computed from the
schema (i.e. how much nesting there is). This defines the maximum number of bits required
to store the levels (levels are defined for all values in the column).

Two encodings for the levels are supported, BIT_PACKED and RLE. Only RLE is now used as
it supersedes BIT_PACKED.

---

## 9. Nulls

Nullity is encoded in the definition levels (which is run-length encoded). NULL values
are not encoded in the data. For example, in a non-nested schema, a column with 1000
NULLs would be encoded with run-length encoding (0, 1000 times) for the definition levels
and nothing else.

---

## 10. Data Pages

For data pages, the 3 pieces of information are encoded back to back, after the page
header. No padding is allowed in the data page. In order:
 1. repetition levels data
 2. definition levels data
 3. encoded values

The value of `uncompressed_page_size` specified in the header is for all 3 pieces
combined.

The encoded values for the data page is always required. The definition and repetition
levels are optional, based on the schema definition. If the column is not nested (i.e.
the path to the column has length 1), repetition levels are not encoded (they would
always be 1). For required data, definition levels are skipped (if encoded, they would
always be the max definition level).

For example, in the case where the column is non-nested and required, the data in the
page is only the encoded values. Supported encodings are described in
[Encodings](#15-encodings); supported compression codecs in [Compression](#14-compression).

---

## 11. Column Chunks

Column chunks are composed of pages written back to back. The pages share a common header
and readers can skip over pages they are not interested in. The data for the page follows
the header and can be compressed and/or encoded. The compression and encoding is
specified in the page metadata.

A column chunk might be partly or completely dictionary encoded. It means that dictionary
indexes are saved in the data pages instead of the actual values. The actual values are
stored in the dictionary page. The dictionary page must be placed at the first position
of the column chunk. At most one dictionary page can be placed in a column chunk.

Additionally, files can contain an optional column index to allow readers to skip pages
more efficiently (see [Page Index](#18-page-index)).

---

## 12. Checksumming

Pages of all kinds can be individually checksummed. This allows disabling of checksums at
the HDFS file level, to better support single row lookups. Checksums are calculated using
the standard CRC32 algorithm — as used in e.g. GZip — on the serialized binary
representation of a page (not including the page header itself).

---

## 13. Error Recovery

If the file metadata is corrupt, the file is lost. If the column metadata is corrupt,
that column chunk is lost (but column chunks for this column in other row groups are
okay). If a page header is corrupt, the remaining pages in that chunk are lost. If the
data within a page is corrupt, that page is lost. The file will be more resilient to
corruption with smaller row groups.

Potential extension: With smaller row groups, the biggest issue is placing the file
metadata at the end. If an error happens while writing the file metadata, all the data
written will be unreadable. This can be fixed by writing the file metadata every Nth row
group. Each file metadata would be cumulative and include all the row groups written so
far. Combining this with the strategy used for rc or avro files using sync markers, a
reader could recover partially written files.

---

## 14. Compression

Parquet allows the data block inside dictionary pages and data pages to be compressed for
better space efficiency. The format supports several compression codecs covering
different areas in the compression ratio / processing cost spectrum. The detailed
specifications of compression codecs are maintained externally by their respective
authors or maintainers.

For all compression codecs except the deprecated `LZ4` codec, the raw data of a page is
fed *as-is* to the underlying compression library, without any additional framing or
padding. The information required for precise allocation of compressed and decompressed
buffers is written in the `PageHeader` struct.

### Codecs

**UNCOMPRESSED** — No-op codec. Data is left uncompressed.

**SNAPPY** — Based on the Snappy compression format. The Snappy library implementation is
authoritative.

**GZIP** — Based on the GZIP format (not zlib/deflate) defined by RFC 1952; the zlib
library is authoritative. Readers should support reading pages containing multiple GZIP
members; however, since this has historically not been supported by all implementations,
writers are recommended not to create such pages by default.

**LZO** — Based on or interoperable with the LZO compression library.

**BROTLI** — Based on the Brotli format defined by RFC 7932; the Brotli library is
authoritative.

**LZ4** (deprecated) — Loosely based on the LZ4 algorithm but with an additional
undocumented framing scheme from the Hadoop compression library. Implementors should
deprecate this in user-facing APIs and advise switching to `LZ4_RAW`.

**ZSTD** — Based on the Zstandard format defined by RFC 8878; the Zstandard library is
authoritative.

**LZ4_RAW** — Based on the LZ4 block format; the LZ4 library is authoritative.

---

## 15. Encodings

This section contains the specification of all supported encodings. Unless otherwise
stated in page or encoding documentation, any encoding can be used with any page type.

### Supported Encodings

| Encoding type | Encoding enum | Supported Types |
| --- | --- | --- |
| Plain | PLAIN = 0 | All Physical Types |
| Dictionary Encoding | PLAIN_DICTIONARY = 2 (Deprecated) / RLE_DICTIONARY = 8 | All Physical Types |
| Run Length Encoding / Bit-Packing Hybrid | RLE = 3 | BOOLEAN, Dictionary Indices |
| Delta Encoding | DELTA_BINARY_PACKED = 5 | INT32, INT64 |
| Delta-length byte array | DELTA_LENGTH_BYTE_ARRAY = 6 | BYTE_ARRAY |
| Delta Strings | DELTA_BYTE_ARRAY = 7 | BYTE_ARRAY, FIXED_LEN_BYTE_ARRAY |
| Byte Stream Split | BYTE_STREAM_SPLIT = 9 | INT32, INT64, FLOAT, DOUBLE, FIXED_LEN_BYTE_ARRAY |

Deprecated: Bit-packed (BIT_PACKED = 4).

### Plain (PLAIN = 0)

The simplest encoding; values are encoded back to back. Used whenever a more efficient
encoding cannot be used.
 - BOOLEAN: bit-packed, LSB first (same packing scheme as the RLE/bit-packing hybrid)
 - INT32: 4 bytes little endian
 - INT64: 8 bytes little endian
 - INT96: 12 bytes little endian (deprecated)
 - FLOAT: 4 bytes IEEE little endian
 - DOUBLE: 8 bytes IEEE little endian
 - BYTE_ARRAY: length in 4 bytes little endian followed by the bytes
 - FIXED_LEN_BYTE_ARRAY: the bytes contained in the array

### Dictionary Encoding (PLAIN_DICTIONARY = 2 and RLE_DICTIONARY = 8)

Builds a dictionary of values encountered in a column, stored in a dictionary page per
column chunk. Values are stored as integers using the RLE/Bit-Packing Hybrid encoding. If
the dictionary grows too big (in size or distinct values), the encoding falls back to
plain. The dictionary page is written first.

Dictionary page format: the entries using the plain encoding. Data page format: the bit
width used to encode the entry ids stored as 1 byte (max bit width = 32), followed by the
values encoded using RLE/Bit-Packing with that bit width.

Using `PLAIN_DICTIONARY` is deprecated; use `RLE_DICTIONARY` in a data page and `PLAIN`
in a dictionary page for new files.

### Run Length Encoding / Bit-Packing Hybrid (RLE = 3)

Combines bit-packing and run length encoding to store repeated values efficiently. Given
a fixed bit-width known in advance:

```
rle-bit-packed-hybrid: <length> <encoded-data>
// length is not always prepended, please check the table below for more detail
length := length of the <encoded-data> in bytes stored as 4 bytes little endian (unsigned int32)
encoded-data := <run>*
run := <bit-packed-run> | <rle-run>
bit-packed-run := <bit-packed-header> <bit-packed-values>
bit-packed-header := varint-encode(<bit-pack-scaled-run-len> << 1 | 1)
// we always bit-pack a multiple of 8 values at a time, so we only store the number of values / 8
bit-pack-scaled-run-len := (bit-packed-run-len) / 8
bit-packed-run-len := *see 3 below*
bit-packed-values := *see 1 below*
rle-run := <rle-header> <repeated-value>
rle-header := varint-encode( (rle-run-len) << 1)
rle-run-len := *see 3 below*
repeated-value := value that is repeated, using a fixed-width of round-up-to-next-byte(bit-width)
```

1. Bit-packing here packs values from the least significant bit of each byte to the most
   significant bit, though the order of the bits in each value remains most significant to
   least significant. For example, the numbers 1 through 7 using bit width 3:
   ```
   dec value: 0   1   2   3   4   5   6   7
   bit value: 000 001 010 011 100 101 110 111
   bit label: ABC DEF GHI JKL MNO PQR STU VWX
   ```
   would be encoded (3 bytes):
   ```
   bit value: 10001000 11000110 11111010
   bit label: HIDEFABC RMNOJKLG VWXSTUPQ
   ```
   This packing order has fewer word-boundaries on little-endian hardware when
   deserializing more than one byte at a time.
2. varint-encode() is ULEB-128 encoding.
3. bit-packed-run-len and rle-run-len must be in the range [1, 2^31 - 1] (always
   storable in a signed 32-bit integer).

RLE is only supported for: repetition and definition levels, dictionary indices, and
boolean values in data pages (as an alternative to PLAIN).

Whether the 4-byte `length` is prepended:
```
+--------------+------------------------+-----------------+
| Page kind    | RLE-encoded data kind  | Prepend length? |
+--------------+------------------------+-----------------+
| Data page v1 | Definition levels      | Y               |
|              | Repetition levels      | Y               |
|              | Dictionary indices     | N               |
|              | Boolean values         | Y               |
+--------------+------------------------+-----------------+
| Data page v2 | Definition levels      | N               |
|              | Repetition levels      | N               |
|              | Dictionary indices     | N               |
|              | Boolean values         | Y               |
+--------------+------------------------+-----------------+
```

### Bit-packed (Deprecated) (BIT_PACKED = 4)

A bit-packed only encoding, deprecated and replaced by the RLE/bit-packing hybrid. Each
value is encoded back to back using a fixed width; no padding between values (except the
last byte, padded with 0s). For compatibility it packs values from the most significant
bit to the least significant bit (unlike the RLE/bit-packing hybrid). Only supported for
encoding repetition and definition levels.

### Delta Encoding (DELTA_BINARY_PACKED = 5)

Supported Types: INT32, INT64. Adapted from the binary packing described in "Decoding
billions of integers per second through vectorization" by Lemire and Boytsov.

Uses variable length integers: ULEB128 for unsigned values, zigzag + ULEB128 for signed.
Consists of a header followed by blocks of delta encoded values binary packed. Each block
is made of miniblocks.

Header:
```
<block size in values> <number of miniblocks in a block> <total value count> <first value>
```
 * block size is a multiple of 128, stored as a ULEB128 int
 * miniblock count per block is a divisor of the block size such that the number of
   values in a miniblock is a multiple of 32, stored as a ULEB128 int
 * total value count stored as a ULEB128 int
 * first value stored as a zigzag ULEB128 int

Each block:
```
<min delta> <list of bitwidths of miniblocks> <miniblocks>
```
 * min delta is a zigzag ULEB128 int
 * the bitwidth of each miniblock is stored as a byte
 * each miniblock is a list of bit-packed ints according to its bit width

Encoding a block: (1) compute differences between consecutive elements (for the first
element use the last element of the previous block, or the header's first value); (2)
compute the min delta and subtract it from all deltas (guaranteeing non-negative values);
(3) encode the min delta as zigzag ULEB128, then bit widths, then the delta values
bit-packed per miniblock.

Padding: if the last miniblock isn't full, pad to the full miniblock length × bit width
(padding bits should be zero but readers must accept arbitrary bits). Unneeded miniblock
bit-width bytes are still present (value should be zero, readers accept arbitrary), but
no padding bytes for their bodies. The reader stops by tracking the number of values
read. Signed arithmetic overflow during subtraction/addition should wrap around in 2's
complement. Writers must not use more bits than required to PLAIN encode the physical
type.

### Delta-length byte array (DELTA_LENGTH_BYTE_ARRAY = 6)

Supported Types: BYTE_ARRAY. Always preferred over PLAIN for byte array columns. All byte
array lengths are encoded using DELTA_BINARY_PACKED; the byte array data follows
concatenated back to back:
```
<Delta Encoded Lengths> <Byte Array Data>
```
Example: "Hello", "World", "Foobar", "ABCDEF" → DeltaEncoding(5, 5, 6, 6) +
"HelloWorldFoobarABCDEF".

### Delta Strings (DELTA_BYTE_ARRAY = 7)

Supported Types: BYTE_ARRAY, FIXED_LEN_BYTE_ARRAY. Also known as incremental encoding or
front compression: for each string, store the prefix length shared with the previous
entry plus the suffix. Stored as delta-encoded prefix lengths (DELTA_BINARY_PACKED)
followed by the suffixes encoded as delta length byte arrays
(DELTA_LENGTH_BYTE_ARRAY). Example: "axis", "axle", "babble", "babyhood" →
DeltaEncoding(0, 2, 0, 3) (prefix lengths) + DeltaEncoding(4, 2, 6, 5) (suffix lengths) +
"axislebabbleyhood". Even for FIXED_LEN_BYTE_ARRAY, all lengths are encoded.

### Byte Stream Split (BYTE_STREAM_SPLIT = 9)

Supported Types: FLOAT, DOUBLE, INT32, INT64, FIXED_LEN_BYTE_ARRAY. Does not reduce data
size but can lead to a significantly better compression ratio and speed when a
compression algorithm is used afterwards.

Creates K byte-streams of length N where K is the size in bytes of the data type and N is
the number of elements. The bytes of each value are scattered to the corresponding
streams (0-th byte to the 0-th stream, etc.). Streams are concatenated in order. Total
length is K × N bytes; the end of the streams is the end of the data page (no padding).

Example — three 32-bit floats:
```
       Element 0      Element 1      Element 2
Bytes  AA BB CC DD    00 11 22 33    A3 B4 C5 D6
```
After transformation:
```
Bytes  AA 00 A3 BB 11 B4 CC 22 C5 DD 33 D6
```

---

## 16. Encryption (Modular Encryption)

Parquet files containing sensitive information can be protected by the modular encryption
mechanism that encrypts and authenticates the file data and metadata — while allowing for
regular Parquet functionality (columnar projection, predicate pushdown, encoding,
compression).

### Goals

1. Protect data and metadata by encryption while enabling selective reads.
2. Implement client-side encryption/decryption; the storage server must not see plaintext
   data, metadata, or keys.
3. Leverage authenticated encryption so clients can check integrity.
4. Enable different keys for different columns and for the footer.
5. Allow partial encryption (encrypt only sensitive columns).
6. Work with all compression and encoding mechanisms.
7. Support multiple encryption algorithms.
8. Enable two modes for metadata protection — full protection, or partial protection that
   allows legacy readers to access unencrypted columns.
9. Minimize overhead.

### Technical Approach

Parquet files comprise separately serialized "modules": pages, page headers, column
indexes, offset indexes, bloom filter headers and bitsets, the footer. Each module is
encrypted separately, making it possible to fetch and decrypt the footer, find offsets,
fetch pages, and decrypt the data. Each column and the footer can be encrypted with the
same key, a different key, or not encrypted at all. For encrypted columns, the following
are always encrypted with the same column key: pages and page headers (data and
dictionary), column indexes, offset indexes, bloom filter headers and bitsets. If the
column key differs from the footer key, the column metadata is serialized separately and
encrypted with the column key.

### Encryption Algorithms and Keys

Based on standard AES ciphers (128/192/256-bit keys). Two algorithms: one based on AES
GCM, the other on a combination of GCM and CTR.

- **AES GCM** — authenticated encryption (confidentiality + integrity), supporting AAD.
- **AES CTR** — a regular (not authenticated) cipher; faster, no integrity verification.
- **Nonces and IVs** — GCM uses a 12-byte (96-bit) nonce per module (RBG-based nonce
  construction per NIST SP 800-38D §8.2.2). CTR uses a 16-byte IV (12-byte nonce + 4-byte
  initial counter).
- **Invocation limit** — one key shall not be used for more than 2^32 total module
  encryptions (per NIST SP 800-38D §8.3). Since each data page requires two module
  encryptions, this is no more than 2^31 pages per key. Writers should keep a local
  invocation counter per key and error if it exceeds 2^32.

**AES_GCM_V1** — encrypts all modules by GCM without padding. Input: key, 12-byte nonce,
plaintext, AAD. Output: ciphertext (same length as plaintext) + 16-byte authentication
tag.

**AES_GCM_CTR_V1** — all modules except pages are encrypted with GCM; pages are encrypted
with CTR without padding (faster bulk data, still verifies metadata integrity). The first
31 bits of the initial counter field are 0, the last bit is 1.

### Key metadata

For each column or footer key, a writer can generate and store an arbitrary
`key_metadata` byte array (e.g. a string ID of a Data key, an encrypted Data key plus a
Master key ID, or a short counter ID). It can also be empty (keys fully managed by the
caller code).

### Additional Authenticated Data (AAD)

A module AAD is built from an optional AAD prefix (a user-provided string identifying the
file) and an AAD suffix (built internally per GCM-encrypted module). The module AAD is the
concatenation of prefix and suffix.

**AAD prefix** — uniquely identifies the file (e.g. "employees_23May2018.part0"),
preventing file swapping. Optionally stored in the `aad_prefix` field (not encrypted); a
writer may request it not be stored, in which case `supply_aad_prefix` is set true and
readers must supply the prefix.

**AAD suffix** — built internally by concatenating: (1) internal file identifier (random
byte array per file); (2) module type (1 byte); (3) row group ordinal (2-byte LE, all
modules except footer); (4) column ordinal (2-byte LE, all modules except footer); (5)
page ordinal (2-byte LE, data page and header only).

Module types: Footer (0), ColumnMetaData (1), Data Page (2), Dictionary Page (3), Data
Page Header (4), Dictionary Page Header (5), ColumnIndex (6), OffsetIndex (7), BloomFilter
Header (8), BloomFilter Bitset (9).

### File Format

**Encrypted module serialization.** For GCM modules, the encryption buffer is nonce +
ciphertext + tag; the 4-byte little-endian length precedes it:
```
|length (4 bytes) | nonce (12 bytes) | ciphertext (length-28 bytes) | tag (16 bytes) |
```
For AES_GCM_CTR_V1, pages use CTR (nonce + ciphertext):
```
|length (4 bytes) | nonce (12 bytes) | ciphertext (length-12 bytes) |
```

**Crypto structures.**
```c
struct AesGcmV1 {
  1: optional binary aad_prefix
  2: optional binary aad_file_unique
  3: optional bool supply_aad_prefix
}
struct AesGcmCtrV1 {
  1: optional binary aad_prefix
  2: optional binary aad_file_unique
  3: optional bool supply_aad_prefix
}
union EncryptionAlgorithm {
  1: AesGcmV1 AES_GCM_V1
  2: AesGcmCtrV1 AES_GCM_CTR_V1
}
```
The row group ordinal for AAD suffix calculation is set in `RowGroup.ordinal` (i16). A
`crypto_metadata` field is set in each encrypted ColumnChunk:
```c
struct EncryptionWithFooterKey {}
struct EncryptionWithColumnKey {
  1: required list<string> path_in_schema
  2: optional binary key_metadata
}
union ColumnCryptoMetaData {
  1: EncryptionWithFooterKey ENCRYPTION_WITH_FOOTER_KEY
  2: EncryptionWithColumnKey ENCRYPTION_WITH_COLUMN_KEY
}
```

**Protection of sensitive metadata.** When column(s) and the footer use different keys,
or columns are encrypted but the footer is not, `ColumnMetaData` is Thrift-serialized
separately, encrypted with the column key, and stored in
`ColumnChunk.encrypted_column_metadata`.

**Encrypted footer mode.** A `FileCryptoMetaData` structure is written before the
encrypted footer, then the combined length (4-byte LE), then the magic string "PARE"
(also at offset 0). This signals readers to find file crypto metadata before the footer
and tells legacy readers (expecting "PAR1") they can't parse the file.
```c
struct FileCryptoMetaData {
  1: required EncryptionAlgorithm encryption_algorithm
  2: optional binary key_metadata
}
```

**Plaintext footer mode.** Allows legacy readers to access unencrypted columns. The
footer is signed (serialized FileMetaData encrypted with AES GCM using a footer signing
key; only the 28-byte nonce+tag is stored after the footer). Magic bytes remain "PAR1".
```c
struct FileMetaData {
  ...
  8: optional EncryptionAlgorithm encryption_algorithm
  9: optional binary footer_signing_key_metadata
}
```
The footer signature layout: `| nonce (12 bytes) | tag (16 bytes) |`.

### Encryption Overhead

Size overhead is negligible (≈1 byte per ~30,000 bytes of original data, comparing the
32-byte page encryption overhead to a default ~1MB page). Throughput overhead depends on
hardware vs software AES; encrypting full pages (~1MB buffers) lets AES run at maximal
speed.

---

## 17. Bloom Filter

### Problem statement

Column statistics (min/max) and dictionaries support predicate pushdown, but with too
many distinct values writers sometimes omit dictionaries, leaving high-cardinality
columns with widely separated min/max unsupported. A Bloom filter is a compact data
structure that overapproximates a set, responding to membership queries with "definitely
no" or "probably yes" (no false negatives). Because Bloom filters are small, they enable
predicate pushdown even for high-cardinality columns.

### Technical Approach — Split Block Bloom Filters

Parquet uses split block Bloom filters (SBBF), the only representation currently
supported.

A **block** is 256 bits, broken into eight contiguous 32-bit "words". When initialized, a
block is empty. It supports `block_insert` and `block_check`, both taking an unsigned
32-bit integer. The operations depend on a `salt` (eight odd unsigned 32-bit constants)
and a `mask` method:
```
unsigned int32 salt[8] = {0x47b6137bU, 0x44974d91U, 0x8824ad5bU,
                          0xa2b7289dU, 0x705495c7U, 0x2df1424bU,
                          0x9efc4947U, 0x5c6bfb31U}

block mask(unsigned int32 x) {
  block result
  for i in [0..7] {
    unsigned int32 y = x * salt[i]
    result.getWord(i).setBit(y >> 27)
  }
  return result
}
```
`mask` multiplies the argument by the nth salt integer (keeping the least significant 32
bits), then shifts right by 27 to get a bit index 0–31 in the nth word. `block_insert`
sets every bit also set in the mask result; `block_check` returns true when every bit set
in the mask result is also set in the block.

A **SBBF** is composed of `z` blocks (1 ≤ z < 2^31). `filter_insert` and `filter_check`
take a 64-bit unsigned integer. They use the most significant 32 bits to select a block,
avoiding the modulo operation:
```c
unsigned int64 h_top_bits = h >> 32;
unsigned int64 z_as_64_bit = z;
unsigned int32 i = (h_top_bits * z_as_64_bit) >> 32;
```
Then the least significant 32 bits of `h` are used as the argument to `block_insert` /
`block_check` on block `i`.
```
void filter_insert(SBBF filter, unsigned int64 x) {
  unsigned int64 i = ((x >> 32) * filter.numberOfBlocks()) >> 32;
  block b = filter.getBlock(i);
  block_insert(b, (unsigned int32)x)
}
boolean filter_check(SBBF filter, unsigned int64 x) {
  unsigned int64 i = ((x >> 32) * filter.numberOfBlocks()) >> 32;
  block b = filter.getBlock(i);
  return block_check(b, (unsigned int32)x)
}
```
To use an SBBF for arbitrary Parquet types, a hash is applied to the value: XXH64
(xxHash) with a seed of 0, following specification version 0.1.1.

### Sizing an SBBF

Sample ratios for false positive rates:

| Bits of space per `insert` | False positive probability |
| -------------------------- | -------------------------- |
| 6.0  | 10 %    |
| 10.5 | 1 %     |
| 16.9 | 0.1 %   |
| 26.4 | 0.01 %  |
| 41   | 0.001 % |

### File Format

Each multi-block Bloom filter works for only one column chunk. The data consists of the
Bloom filter header followed by the bitset. Thrift definitions:
```
struct SplitBlockAlgorithm {}
union BloomFilterAlgorithm {
  1: SplitBlockAlgorithm BLOCK;
}
struct XxHash {}
union BloomFilterHash {
  1: XxHash XXHASH;
}
struct Uncompressed {}
union BloomFilterCompression {
  1: Uncompressed UNCOMPRESSED;
}
struct BloomFilterHeader {
  1: required i32 numBytes;
  2: required BloomFilterAlgorithm algorithm;
  3: required BloomFilterHash hash;
  4: required BloomFilterCompression compression;
}
struct ColumnMetaData {
  ...
  14: optional i64 bloom_filter_offset;
  15: optional i32 bloom_filter_length;  // added in 2.10
}
```
Bloom filters are grouped by row group with data for each column in file schema order.
The data can be stored before the page indexes after all row groups, or between row
groups.

### Encryption

For sensitive columns, the Bloom filter exposes a subset of sensitive information (the
presence of a value), so it should be encrypted with the column key. Bloom filters have
two serializable modules — the header and the bitset. For sensitive columns, each is
encrypted after serialization using AES GCM with the column key but different AAD module
types — "BloomFilter Header" (8) and "BloomFilter Bitset" (9). The length of the
encrypted buffer is written before the buffer.

---

## 18. Page Index

A *page index* is optional metadata for a ColumnChunk, containing statistics for
DataPages used to skip those pages when scanning ordered and unordered columns. It is
stored using the OffsetIndex and ColumnIndex structures.

### Problem Statement

Previously, statistics were stored for ColumnChunks in ColumnMetaData and for individual
pages inside DataPageHeader structs. A reader had to process each page header to determine
whether the page could be skipped, likely reading most of the column data from disk.

### Goals

1. Make both range scans and point lookups I/O efficient by allowing direct access to
   pages based on their min/max values (single-row lookups read one data page per column;
   range scans read only relevant pages; selective scans on non-sorting columns read only
   matching pages).
2. No additional decoding effort for non-selective scans.
3. Index pages for sorted columns use minimal storage (only boundary elements between
   pages).

**Non-goal:** support for secondary indices (an index sorted on key values over
non-sorted data).

### Technical Approach

Two new per-column structures are added to the row group metadata:
* **ColumnIndex** — navigation to the pages of a column based on column values; locates
  data pages that contain matching values for a scan predicate.
* **OffsetIndex** — navigation by row index; retrieves values for rows identified as
  matches via the ColumnIndex. OffsetIndexes for each column in a RowGroup are stored
  together.

These structures are stored separately from RowGroup, near the footer, so a reader does
not pay I/O and deserialization cost when not doing selective scans. Their location and
length are stored in ColumnChunk.

Observations: the row group Statistics provide the lower bound of the first page and the
upper bound of the last page (still included for uniformity). Stored lower/upper bounds
may be the actual min/max or more compact values that do not exist on a page (e.g. min="B",
max="C" instead of "Blart Versenwald III"), allowing writers to truncate large values.
Readers supporting ColumnIndex should not also use page statistics.

For ordered columns, a reader finds matching pages by binary search in `min_values` and
`max_values`; for unordered columns, by sequential reading. `min_values` and `max_values`
are calculated based on the `column_orders` field in the `FileMetaData` footer.

---

## 19. Binary Protocol Extensions

The extension mechanism of the `binary` Thrift field-id `32767` has desirable properties:
existing readers ignore these extensions without modification and with little overhead;
the content is freeform (not restricted to Thrift); extensions can be appended to existing
Thrift serialized structs without requiring Thrift libraries.

Because only one field-id is reserved, the extension bytes themselves require
disambiguation — implementers MUST put enough unique state (e.g. a UUID at the start or
end) so readers can decode extensions safely. The spec deliberately does not specify a
disambiguation mechanism, for flexibility.

Example — extending `FileMetaData` on the wire:
```
    N-1 bytes | Thrift compact protocol encoded FileMetaData (minus \0 thrift stop field)
    4 bytes   | 08 FF FF 01 (long form header for 32767: binary)
    1-5 bytes | ULEB128(M) encoded size of the extension
    M bytes   | extension bytes
    1 byte    | \0 (thrift stop field)
```

Reserving only one field-id creates scarcity in the extension space and disincentivizes
vendors from keeping extensions private, encouraging standardization.

### Appending extensions to thrift

```c++
void AppendUleb(uint32_t x, std::string* out) {
  while (true) {
    uint8_t c = x & 0x7F;
    if (x < 0x80) return out->push_back(c);
    out->push_back(c + 0x80);
    x >>= 7;
  }
};

std::string AppendExtension(std::string thrift, const std::string& ext) {
  assert(thrift.back() == '\x00');   // there was a stop field in the first place
  thrift.back() = '\x08';      // replace stop field with binary type
  AppendUleb(32767, &thrift);  // field-id
  AppendUleb(ext.size(), &thrift);
  thrift += ext;
  thrift += '\x00';  // add the stop field
  return thrift;
}
```

The site documentation also illustrates migration paths to standardization (e.g. a
FlatBuffers-encoded `FileMetaData` footer variant, or a new encoding added via a
`ColumnMetaData` extension), showing how a private extension can evolve into the official
specification.

---

## 20. Configurations

### Row Group Size

Larger row groups allow for larger column chunks which makes it possible to do larger
sequential IO. Larger groups also require more buffering in the write path (or a two-pass
write). Recommended: large row groups (512MB – 1GB). Since an entire row group might need
to be read, it should completely fit on one HDFS block. Therefore HDFS block sizes should
also be larger. An optimized read setup: 1GB row groups, 1GB HDFS block size, 1 HDFS block
per HDFS file.

### Data Page Size

Data pages should be considered indivisible, so smaller data pages allow more fine-grained
reading (e.g. single row lookup). Larger page sizes incur less space overhead (fewer page
headers) and potentially less parsing overhead. For sequential scans, it is not expected
to read a page at a time (this is not the IO chunk). Recommended: 8KB for page sizes.

---

## 21. Extensibility

There are many places in the format for compatible extensions:
- File Version: the file metadata contains a version.
- Encodings: encodings are specified by enum and more can be added in the future.
- Page types: additional page types can be added and safely skipped.

---

## 22. Implementation Status

The Apache Parquet site maintains a feature support matrix across implementations. Legend:
✅ supported (footnote when partial; with release-notes links where available), ❌ not
supported, (R) only read support, (W) only write support, (blank) no data.

Tracked implementations include: arrow (C++), parquet-java (Java), arrow-go (Go), arrow-rs
(Rust), cudf (cuDF C++), hyparquet (JavaScript), duckdb (C++), polars (Rust). The live
matrix is rendered on the site (`https://parquet.apache.org/docs/file-format/implementationstatus/`).

---

## 23. Format Versions (Features and Versions)

This describes how features are added to the Parquet format specification and how they
affect reader/writer compatibility.

### Feature compatibility

Changes are classified by their effect on reader and writer compatibility, differing in
*forward* compatibility (whether an older reader can read files using a newer feature).

**Forward compatible** features remain readable by older readers, possibly with a degraded
experience. Examples: Bloom filters (a reader ignoring them skips pruning metadata but
reads data correctly); logical type annotations such as `VARIANT` (an older reader reads
the underlying physical column as raw bytes).

**Forward incompatible** features make data unreadable to older software. Examples: new
encodings (the `DELTA_*` encodings, `BYTE_STREAM_SPLIT`, `RLE_DICTIONARY`); Data Page V2
headers (a reader that only understands `DataPageHeader` cannot parse `DataPageHeaderV2`).

### `FileMetadata` version field

Each Parquet file has a `version` field in the Thrift `FileMetaData`. This field has
historically been used inconsistently — writers populate `1` or `2` without a consistent
relationship to the features actually used.

### `parquet-format` release versions

The Thrift definition is released independently of implementations, following the Apache
release process. This release version is not recorded in the FileMetaData. Release
numbering does NOT follow semantic versioning: minor releases (e.g. 2.10.0 → 2.11.0)
sometimes contain forward incompatible features.

### Adding new features

New features are added by discussion and voting on the parquet dev mailing list. Once
approved, a feature is added to the spec and ships in the next parquet-format release.

### Forward incompatible features by version

| Feature | Released in | Notes |
| --- | --- | --- |
| BOOLEAN, INT32, INT64, INT96 (deprecated), FLOAT, DOUBLE, BYTE_ARRAY, FIXED_LEN_BYTE_ARRAY | 1.0.0 | |
| Data Page V1 | 1.0.0 | |
| Data Page V2 | 2.0.0 | |
| PLAIN, PLAIN_DICTIONARY, RLE, BIT_PACKED (deprecated) | 1.0.0 | |
| RLE_DICTIONARY | 2.0.0 | |
| DELTA_BINARY_PACKED, DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY | 2.0.0 | |
| BYTE_STREAM_SPLIT | 2.8.0 | Approved 2019-12-03 |
| BYTE_STREAM_SPLIT (Additional Types) | 2.11.0 | Approved 2024-03-18 |
| UNCOMPRESSED, SNAPPY, GZIP, LZO | 1.0.0 | |
| BROTLI, LZ4 (deprecated), ZSTD | 2.4.0 | |
| LZ4_RAW | 2.9.0 | |
| Modular encryption | 2.7.0 | Approved 2019-01-16 |

> Note: Files with an encrypted footer use different magic bytes (`PARE` instead of
> `PAR1`), making it clear readers must support modular encryption; plaintext footer files
> use `PAR1` so legacy readers can still read their unencrypted columns.

### Forward compatible additions

| Feature | Released in | Notes |
| --- | --- | --- |
| xxHash-based bloom filters | 2.7.0 | Approved 2019-09-09 |
| Bloom filter length | 2.10.0 | |
| Page index | 2.4.0 | |
| Page CRC32 checksum | 1.0.0 | |
| Size statistics | 2.10.0 | Approved 2023-11-14 |
| Geospatial statistics | 2.11.0 | Approved 2025-02-09 |
| Binary protocol extensions | 2.11.0 | Approved 2024-09-06 |
| IEEE 754 total order and NaN counts | 2.13.0 | Approved 2026-05-26 |
| LogicalType union | 2.4.0 | Supersedes ConvertedType enum (deprecated in 2.9.0) |
| STRING (BYTE_ARRAY) | 1.0.0 | |
| ENUM (BYTE_ARRAY) | 2.0.0 | |
| UUID (FIXED_LEN_BYTE_ARRAY(16)) | 2.6.0 | |
| Signed and unsigned integer logical types (INT32, INT64) | 2.2.0 | |
| DECIMAL (INT32 / INT64 / BYTE_ARRAY / FIXED_LEN_BYTE_ARRAY) | 2.1.0 | |
| FLOAT16 (FIXED_LEN_BYTE_ARRAY(2)) | 2.10.0 | Approved 2023-10-13 |
| DATE (INT32) | 2.2.0 | |
| TIME (INT32) | 2.2.0 | |
| TIME (INT64) | 2.4.0 | |
| TIMESTAMP (INT64) | 2.2.0 | |
| Nanosecond TIME/TIMESTAMP | 2.6.0 | |
| INTERVAL (FIXED_LEN_BYTE_ARRAY(12)) | 2.2.0 | |
| JSON (BYTE_ARRAY) | 2.2.0 | |
| BSON (BYTE_ARRAY) | 2.2.0 | |
| VARIANT | 2.12.0 | Approved 2025-08-24 |
| Variant shredding | 2.12.0 | Approved 2025-08-24 |
| GEOMETRY (BYTE_ARRAY) | 2.11.0 | Approved 2025-02-09 |
| GEOGRAPHY (BYTE_ARRAY) | 2.11.0 | Approved 2025-02-09 |
| LIST, MAP | 1.0.0 | |
| UNKNOWN (always null) | 2.4.0 | |

---

*End of compiled specification. Source pages and embedded documents are available at
[apache/parquet-site](https://github.com/apache/parquet-site/tree/production/content/en/docs/File%20Format)
and [apache/parquet-format](https://github.com/apache/parquet-format).*
