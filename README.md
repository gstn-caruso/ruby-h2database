# Ruby H2 Database

A native Ruby migration of the [H2 SQL database](https://h2database.com), targeting Ruby 3.4 and 4.0. The Ruby engine runs in-process without Java or another database engine.

**The migration is in progress.** The Ruby SQL engine runs in memory or in native H2 format 3 `.mv.db` files for the implemented schema/type subset. File-backed SQL uses the native MVStore transaction layer, and the low-level map API is also available separately. The port does not replace the complete Java engine. See [MIGRATION.md](MIGRATION.md) for the supported behavior, remaining scope and compatibility evidence.

## Install and test

```sh
bundle install
bundle exec rake test
```

The development version is pinned in `.ruby-version`. Ruby CI is configured for the 3.4 and 4.0 release lines; the original Java workflow remains available for the reference implementation under `h2/`.

## Use from Ruby

```ruby
require "h2"

H2.connect do |connection|
  connection.execute("CREATE TABLE people(id INT PRIMARY KEY, name VARCHAR(100))")
  connection.execute("INSERT INTO people VALUES (?, ?)", 1, "Ada")

  result = connection.execute("SELECT name FROM people WHERE id = ?", 1)
  p result.columns # => ["NAME"]
  p result.rows    # => [["Ada"]]
  p result.to_a    # => [{"NAME" => "Ada"}]
end
```

`H2.connect` creates an isolated in-memory database by default. Use `H2::Database.new` and call `database.connect` for multiple connections sharing a database. Block forms close their connection automatically. Closing the last connection does not discard an explicitly retained `Database` object; call `database.close` when finished. Closing a database invalidates its connections.

Parameters are positional values supplied after SQL. `prepare(sql)` returns a reusable statement with `execute(*values)` and `parameter_count`. Strings are copied before use, and results expose frozen columns, row arrays and string values. `rows` preserves duplicate column labels; enumeration produces hashes, where the last value for a repeated label wins.

Queries can combine tables with inner, left, right, cross, natural and `USING` joins, or read derived `SELECT`, `VALUES` and `TABLE` queries. Qualified column references retain their source, and ambiguous names raise an error. `result.types` exposes the initial SQL type information used across query boundaries; precision and other metadata still need full H2 compatibility.

Scalar and correlated subqueries work in expressions, `EXISTS`, `IN`/`NOT IN`, inserts, updates and deletes. An empty single-column scalar query returns `nil`; multiple rows raise H2 error 90053. A multi-column scalar query returns an immutable `H2::RowValue`, whose fields are available through `.values`; an empty multi-column query returns a row of `nil` fields. `ROW(...)` constructors, row comparisons and searched/simple `CASE` expressions are also available.

Query preparation validates reachable expressions and inner scopes before scanning rows. As in H2, derived tables, range arguments and pagination expressions cannot refer to an outer query. Defaults containing subqueries read the current data when used and retain any parameters supplied when the table was created.

## Combining query results

`UNION` / `UNION DISTINCT`, `UNION ALL`, `INTERSECT` and `EXCEPT` / `MINUS` combine `SELECT`, `TABLE` and `VALUES` queries. `INTERSECT` binds more tightly than the other operators; parentheses control grouping and branch pagination. Output names come from the left query, and each output column uses a common SQL type. Set conversion preserves numeric values and binary lengths without applying column-assignment padding or truncation.

```ruby
H2.connect do |connection|
  result = connection.execute("VALUES 1, 1, 2 UNION VALUES 2, 3 ORDER BY 1 DESC")
  p result.rows # => [[3], [2], [1]]
end
```

`UNION` and `EXCEPT` eliminate duplicate rows, treating corresponding nulls as equal. `UNION ALL` retains duplicates. As in this H2 snapshot, `INTERSECT` can retain duplicate right-side rows when its branch is paginated or when conversion merges distinct source values. `INTERSECT ALL` and `EXCEPT ALL` are not supported by the reference. Outer ordering accepts output names and column positions, including bound position parameters; `ORDER BY (1)` is a constant, unlike `ORDER BY 1`.

Set queries work in derived/scalar/correlated subqueries, membership predicates, CTAS, insert-select, DML expressions and persisted defaults. Constant scalar queries are evaluated during preparation, including their labels, null types and cardinality checks. Both branches currently materialize before the set operation and pagination; lazy unions, external results, complete plan formatting and optimizer behavior remain to port.

## Common table expressions

`WITH` defines query-local tables in declaration order. Later definitions can read earlier ones, and nested `WITH` scopes can replace outer CTE names. Explicit column names replace corresponding output names; omitted names come from the defining query. Real catalog tables take priority when names collide, and `PUBLIC.name` always resolves against the catalog.

```ruby
H2.connect do |connection|
  result = connection.execute(<<~SQL)
    WITH RECURSIVE numbers(n) AS (
      VALUES 1
      UNION ALL
      SELECT n + 1 FROM numbers WHERE n < 4
    )
    SELECT SUM(n) AS total FROM numbers
  SQL
  p result.rows # => [[10]]
end
```

As in this H2 snapshot, `WITH RECURSIVE` requires column lists. Recursion evaluates the seed, then repeatedly evaluates the recursive branch against the previous batch until it returns no rows. It retains duplicates for every root set operator, including `UNION`; outer set ordering/limits inside that recursive definition are ignored by H2's recursive index. Put final ordering and pagination on the main query. Recursive result rows retain their original value representations.

CTEs work in derived/scalar/correlated query bodies, EXISTS/IN, CTAS, insert-select, DML subqueries and persisted defaults. Definitions cannot refer to outer row columns. Parameters are reusable; use explicit casts such as `SELECT CAST(? AS INT)` in recursive seeds when integer metadata is required. Untyped parameters follow H2's initial VARCHAR inference or unknown-column-type errors. CTE tables do not become catalog objects and are unavailable after the statement.

Results currently materialize in memory, and repeated references recompute them. General recursive-anchor references, data-change delta tables, complete optimizer/EXPLAIN output, cancellation and resource limits remain pending. The supported cases and reference evidence are recorded in [MIGRATION.md](MIGRATION.md).

## Binary and UUID values

`BINARY(n)` pads with zero bytes; `VARBINARY(n)` / `BINARY VARYING(n)` preserves length. Assignment rejects oversized values, while explicit casts truncate. SQL hexadecimal literals use `X'00ff'`; binary parameters and results use frozen copies of Ruby strings with `Encoding::BINARY` (`ASCII-8BIT`). Use `.b` when binding bytes. Text-to-binary conversion uses UTF-8. Binary-to-text conversion follows Java's UTF-8 replacement behavior for malformed input.

```ruby
uuid = H2::UUIDValue.parse("01234567-89ab-cdef-0123-456789abcdef")
H2.connect do |connection|
  connection.execute("CREATE TABLE objects(id UUID PRIMARY KEY, bytes VARBINARY)")
  connection.execute("INSERT INTO objects VALUES(?, ?)", uuid, "\x00\xff".b)
  id, bytes = connection.execute("TABLE objects").rows.first
  p id.to_s  # => "01234567-89ab-cdef-0123-456789abcdef"
  p bytes    # => "\x00\xFF"
end
```

`UUID '...'` supplies a typed literal. UUID casts accept H2's textual UUID form or exactly 16 binary bytes. `H2::UUIDValue` is immutable, exposes `.bytes`, and formats canonical lowercase text with `.to_s`. Both types work in defaults, key constraints, comparisons, ordering, initial ROW values and persisted tables/indexes. Integer/binary casts retain signed big-endian widths. `LENGTH` / `CHAR_LENGTH`, `OCTET_LENGTH` and `BIT_LENGTH` distinguish character, binary, integer and UUID representations. Full type metadata, UUID generation functions and remaining binary functions still need migration. Empty binary columns inferred by native CTAS use precision 1 so their saved declarations can reopen; the Java snapshot's zero-precision metadata limitation is recorded in [MIGRATION.md](MIGRATION.md).

## Arrays

Declare an element type followed by `ARRAY` or `ARRAY[n]`; repeated suffixes declare nested arrays. Cardinality defaults to 65,536 and can be zero. SQL constructors use `ARRAY[...]` or `ARRAY(single_column_query)`. A query constructor preserves query ordering and returns a typed empty array when no rows match.

```ruby
H2.connect do |connection|
  connection.execute("CREATE TABLE lists(id INT PRIMARY KEY, items INT ARRAY[3])")
  connection.execute("INSERT INTO lists VALUES(?, ?)", 1, [10, nil, 30])
  value = connection.execute("SELECT items FROM lists WHERE id=1").rows.first.first
  p value.values # => [10, nil, 30]
  p connection.execute("SELECT items[3], CARDINALITY(items) FROM lists").rows # => [[30, 3]]
end
```

Ruby arrays, including nested arrays, become copied immutable `H2::ArrayValue` parameters. Results expose `.values`, `.element_type` and canonical `.to_s` output. SQL array types expose their element type, maximum cardinality in `.precision` and a component-aware `.name`. Elements use a common SQL type; decimal arrays retain their component scale. Assignment rejects an oversized array; a cast converts every element before truncating to the requested cardinality. Use explicit parameter casts such as `ARRAY[CAST(? AS INT)]` when H2 cannot infer a component type.

Indexes start at 1; invalid indexes raise 22034. `||`, `ARRAY_CAT` and `ARRAY_APPEND` concatenate arrays or append/prepend scalars. `CARDINALITY` / `ARRAY_LENGTH`, `ARRAY_MAX_CARDINALITY`, `TRIM_ARRAY`, `ARRAY_CONTAINS`, `ARRAY_SLICE` and `ARRAY_GET` are available. Array equality and ordering retain H2's null semantics; `ARRAY_CONTAINS` uses null-safe element equality. Arrays work in keys, grouping, distinct/set queries, correlated query constructors and persisted defaults/rows/indexes.

`ARRAY_AGG` collects values, including nulls, with optional `DISTINCT`, internal `ORDER BY` and `FILTER(WHERE ...)`. Empty groups return SQL NULL. Filters also work with `COUNT`, `SUM`, `AVG`, `MIN` and `MAX`. `UNNEST` expands one or more arrays, padding shorter inputs with nulls; `WITH ORDINALITY` adds the one-based `NORD` column.

```ruby
H2.connect do |connection|
  result = connection.execute("SELECT ARRAY_AGG(v ORDER BY v DESC) FILTER(WHERE v>1) AS a FROM UNNEST(CAST(? AS INT ARRAY)) t(v)", [1, nil, 3, 2])
  p result.rows.first.first.values # => [3, 2]
  p connection.execute("SELECT * FROM UNNEST(ARRAY[10,20],ARRAY['a']) WITH ORDINALITY").rows
  # => [[10, "a", 1], [20, nil, 2]]
end
```

Cast `UNNEST` parameters explicitly to establish their column types. H2 reports NULL metadata for untyped parameters and other expressions without a statically known array type, even when their runtime values are non-null; aggregation and CTAS retain that behavior.

`ANY` / `SOME` and `ALL` compare against array elements or subquery rows using `=`, `<>`, `<`, `>`, `<=`, `>=`, `IS DISTINCT FROM` or `IS NOT DISTINCT FROM`. `ANY` returns false for an empty input; `ALL` returns true. A NULL array returns NULL. Other nulls follow SQL three-valued logic, with null-safe behavior for the DISTINCT operators. Scalars act as a single array element; a ROW remains one row value. Parameters can bind Ruby arrays directly:

```ruby
H2.connect do |connection|
  p connection.execute("SELECT ?=ANY(?),?>ALL(?)", 2, [1, 2], 3, [1, 2]).rows
  # => [[true, true]]
  p connection.execute("SELECT 3>ALL(VALUES 1,2)").rows # => [[true]]
end
```

Quantified predicates work in filters, joins, grouped queries, DML and saved defaults. Simple CASE accepts predicate branches such as `CASE v WHEN =ANY(a) THEN 1 ELSE 2 END`. Window aggregates, other table functions, compatibility modes and complete component metadata remain pending; [MIGRATION.md](MIGRATION.md) records the verified scope.

## JSON

`JSON` and `JSON(n)` store normalized UTF-8 JSON; `n` limits bytes, up to 1,000,000,000. Values retain object order, duplicate keys and decimal scale. Ruby results use immutable `H2::JsonValue` objects with `.bytes`, `.kind`, `.unique_keys?` and canonical `.to_s`. Bind an explicit value with `H2::JsonValue.parse(text_or_bytes)`.

Numeric scale supports signed 32-bit limits. At the boundary `1e2147483648`, native JSON agrees with Java 25; Java 17 rejects the exponent. This reference-runtime difference is checked separately and documented in [MIGRATION.md](MIGRATION.md).

```ruby
H2.connect do |connection|
  connection.execute("CREATE TABLE documents(id INT PRIMARY KEY, body JSON)")
  connection.execute("INSERT INTO documents VALUES(?, ?)", 1,
    H2::JsonValue.parse('{"a":1,"a":2}'))
  p connection.execute("SELECT body IS JSON WITH UNIQUE KEYS FROM documents").rows # => [[false]]
  value = connection.execute("SELECT JSON_OBJECT('id':id,'body':body) FROM documents").rows.first.first
  p value.to_s # => '{"id":1,"body":{"a":1,"a":2}}'
end
```

`CAST(text AS JSON)` creates a JSON string. `text FORMAT JSON`, binary casts and `JSON '...'` / `JSON X'...'` parse JSON. SQL NULL remains distinct from JSON `null`. `JSON_ARRAY` and `JSON_OBJECT` support `NULL ON NULL` / `ABSENT ON NULL`; objects also support `WITH UNIQUE KEYS`. A single query argument to `JSON_ARRAY` collects its rows in query order. As in H2, constant scalar subqueries still undergo scalar cardinality checks.

`IS [NOT] JSON` accepts VALUE, ARRAY, OBJECT or SCALAR and optional unique-key validation. `IS [NOT] OF(type, ...)` tests SQL type identity. JSON array indexing starts at 1 and returns SQL NULL outside the array; `UNNEST` returns JSON elements, including JSON `null`. JSON keys compare normalized bytes, so `JSON '1'` and `JSON '1.0'` remain distinct. Tables, key indexes, nested SQL arrays, constructors and query defaults reopen through native storage and JDBC.

JSON aggregates, LOB/geometry conversions, compatibility modes and general optimization remain pending; see [MIGRATION.md](MIGRATION.md).

## Decimal floating point

`DECFLOAT(p)` stores decimal floating point with 1–100,000 significant digits; the default precision is 100,000. Scientific literals such as `1.2300E100` infer this type and normalize trailing zeros. Results use immutable `H2::DecfloatValue` objects with `.to_s`, `.precision`, `.finite?` and `.special`; bind explicit values with `H2::DecfloatValue.parse(text)`.

```ruby
H2.connect do |connection|
  result = connection.execute("SELECT CAST(? AS DECFLOAT(5))/CAST(? AS DECFLOAT(3)) AS ratio",
    H2::DecfloatValue.parse("1"), H2::DecfloatValue.parse("6"))
  p result.rows.first.first.to_s # => "0.166667"
end
```

Arithmetic supports `+`, `-`, `*`, `/`, `%`, `ABS`, `SIGN` and `MOD`, including infinities and `NaN`. Division and casts follow H2's precision and rounding rules; division by zero raises 22012, including non-finite dividends. `SUM` and `AVG` support DISTINCT and FILTER; SUM retains non-finite values, while AVG rejects them with 22018. DOUBLE sums and averages also return DECFLOAT. Finite values convert to JSON; non-finite JSON conversion fails with 22018.

Columns, CTAS, key indexes, arrays and dynamic arithmetic/aggregate defaults retain values and operand precision across native/JDBC file reopen. Remaining numeric functions, aliases, conversions and full metadata/optimizer behavior are still migration work.

## Numeric declarations and conversions

`NUMERIC(p,s)`, `DECIMAL` / `DEC`, and `NUMBER(p,s)` support precision 1–100,000 and scale 0–100,000, including scale greater than precision. Bare `NUMBER` means `DECFLOAT(40)`. `FLOAT(p)` chooses REAL for 1–24 binary digits and DOUBLE for 25–53; bare `FLOAT` means DOUBLE. Declarations and defaults survive native/JDBC reopen. Scalar type records expose the physical family with `.name` and the metadata name with `.type_name`, which retains `DECIMAL`.

Character conversions use H2's numeric syntax: integer/decimal text accepts BMP Unicode decimal digits; floating-point text accepts decimal/hexadecimal exponents and Java's `f`/`d` suffixes. Digit separators in character input are rejected. Text integer overflow raises 22018; numeric integer overflow raises 22003. Conversion to REAL rounds directly to 32 bits from exact input, avoiding an intermediate DOUBLE rounding. Numeric-to-character conversion retains decimal scale and REAL width; numeric NaN converts to boolean false.

Native floating-point text follows the modern Java reference. Java 17 prints some values with extra digits; [MIGRATION.md](MIGRATION.md) records separately checked formatting differences and exact-bit comparisons. Compatibility modes, other aliases/conversions and complete metadata remain pending.

## Binary floating-point arithmetic

REAL arithmetic rounds each result to 32 bits; DOUBLE uses 64 bits. Chained operations, overflow to infinity and underflow to zero retain H2's behavior. Zero divisors raise 22012, including NaN/infinite dividends. `MOD` and `%` retain the dividend's sign, calculate in the common numeric type, then convert to the divisor's numeric type.

```ruby
H2.connect do |connection|
  result = connection.execute("SELECT CAST(CAST(? AS REAL)+CAST(? AS REAL) AS DOUBLE)", "0.1", "0.2")
  p result.rows # => [[0.30000001192092896]]
end
```

NaN equals itself and sorts after positive infinity. Zero signs normalize to positive zero; NaN values remain consistent in keys, grouping, DISTINCT and set operations. SUM and AVG of REAL produce DOUBLE, with sequential addition and H2's sorted order for DISTINCT inputs. Arithmetic defaults, CTAS and NaN keys reopen through native storage and JDBC. Other numeric functions and complete parameter inference, composite metadata and optimizer behavior remain migration work.

## Bit functions

`BITAND`, `BITOR`, `BITXOR`, `BITNOT`, `BITNAND`, `BITNOR` and `BITXNOR` accept TINYINT, SMALLINT, INTEGER, BIGINT, BINARY and VARBINARY. Integer results retain their signed width. Binary operands align at the first byte; a fixed BINARY operand determines the result precision when mixed with VARBINARY.

`BITGET` tests a bit and `BITCOUNT` counts set bits. `LSHIFT` / `RSHIFT` retain the sign on integer right shifts; `ULSHIFT` / `URSHIFT` fill with zero. `ROTATELEFT` / `ROTATERIGHT` wrap within the value's width. Negative offsets reverse the direction. Binary shifts use big-endian byte order; BITGET counts from the low bit of each successive byte. H2's BIGINT BITGET masks nonnegative offsets modulo 64, while smaller integers return false beyond their width.

```ruby
H2.connect do |connection|
  p connection.execute("SELECT LSHIFT(CAST(? AS TINYINT),?),BITCOUNT(CAST(? AS TINYINT))", 1, 7, -1).rows
  # => [[-128, 8]]
end
```

The six aggregates `BIT_AND_AGG`, `BIT_OR_AGG`, `BIT_XOR_AGG`, `BIT_NAND_AGG`, `BIT_NOR_AGG` and `BIT_XNOR_AGG` support DISTINCT and FILTER, skip SQL NULL and return NULL for empty groups. Inverse forms negate the final aggregate. Functions, aggregate defaults and captured parameters retain widths and fixed binary operands across native/JDBC reopen and CLI invocations. Window aggregates and general EXPLAIN plans remain pending.

## Enumerated values

`ENUM('low','medium','high')` stores an ordered set of labels. Assignment matches labels after trimming ASCII control/space characters at both ends and converting to uppercase; results retain the spelling in the declaration. Ordering, MIN/MAX, keys, grouping and DISTINCT use the ordinal. Empty and duplicate normalized labels raise 22032 and 22033; a missing label or ordinal raises 22030.

```ruby
H2.connect do |connection|
  connection.execute("CREATE TABLE tasks(priority ENUM('low','medium','high'))")
  connection.execute("INSERT INTO tasks VALUES(?)", " HIGH ")
  value = connection.execute("TABLE tasks").rows.first.first
  p [value.label, value.ordinal] # => ["high", 3]
  p value.type.labels          # => ["low", "medium", "high"]
end
```

Results use immutable `H2::EnumValue` objects. For typed parameters, create a descriptor with `H2::EnumType.new(['low','high'])`, then call `type.value('high')`. Explicit numeric casts use the ordinal; character and JSON casts use the label. Arithmetic produces INTEGER results. Compare directly with labels or other ENUM values; comparisons with numbers require an explicit cast. SUM/AVG reject ENUM arguments.

Ordinals start at one by default. `H2.connect(zero_based_enums: true)` and CLI `--zero-based-enums` start them at zero, matching H2's `ZERO_BASED_ENUMS` setting. This choice is not stored in the file: supply the same option when reopening. For zero-based typed parameters, use `type.value('high', zero_based: true)`. ENUM columns, arrays, keys, CTAS and dynamic defaults survive native/JDBC cross-reading and cross-writing. Precision counts UTF-16 units, including preserved isolated surrogates. Domains, ALTER TYPE, views and complete composite metadata remain migration work.

## Rounding numbers and truncating dates

`ROUND(value[, scale])` rounds decimal ties away from zero. `TRUNC` / `TRUNCATE` discard the fractional part toward zero; `FLOOR` rounds down and `CEIL` / `CEILING` round up. A negative scale selects digits before the decimal point. Scales range from -100,000 to 100,000; invalid scales raise 90008, and integer overflow raises 22003.

```ruby
H2.connect do |connection|
  result = connection.execute("SELECT ROUND(CAST(? AS NUMERIC(8,3)),2) AS rounded", BigDecimal("1.255"))
  p result.rows.first.first.to_s("F") # => "1.26"
end
```

Results retain the numeric family. A constant scale can reduce NUMERIC result scale; a scale read from a column or parameter keeps the input scale and adjusts precision. The CLI formats declared decimal scales and REAL's 32-bit representation. Use an explicit cast for a rounding argument supplied as a parameter, as in the example. SQL NULL propagates; constant scale/type errors are checked during preparation. REAL/DOUBLE `NaN` and infinities survive FLOOR, CEIL and zero-scale TRUNC; decimal rounding of non-finite values fails with 22018. Float parameters accept these specials, and conversion of floating-point NaN to an integer yields zero.

`TRUNC` also resets DATE, TIMESTAMP and TIMESTAMP WITH TIME ZONE values to midnight, retaining a timestamp's offset. DATE results use TIMESTAMP(0). Text is first cast to TIMESTAMP(0), so a fractional second near midnight can round into the following day before truncation. Temporal TRUNC accepts one argument. `ROUNDMAGIC` implements H2's DOUBLE correction for decimal artifacts; it is separate from ordinary ROUND.

## Dates and times

`DATE`, `TIME[(0..9)]` and `TIMESTAMP[(0..9)]` store calendar and wall-clock values without a time zone. Results use immutable `H2::DateValue`, `H2::TimeValue` and `H2::TimestampValue` objects, with canonical text from `.to_s`. Dates cover H2's Gregorian year range from -1,000,000,000 through 1,000,000,000. Times retain nanoseconds; column assignment and casts round to their declared scale, which defaults to 0 for TIME and 6 for TIMESTAMP.

```ruby
require "date"

H2.connect do |connection|
  connection.execute("CREATE TABLE events(d DATE, starts_at TIME(9))")
  connection.execute("INSERT INTO events VALUES(?, ?)",
    Date.new(2024, 2, 29), H2::TimeValue.parse("12:34:56.123456789"))
  p connection.execute("SELECT d + 1, EXTRACT(HOUR FROM starts_at) FROM events").rows.map { |row| row.map(&:to_s) }
  # => [["2024-03-01", "12"]]
end
```

Ruby `Date` parameters become DATE; `Time` and `DateTime` parameters become TIMESTAMP by copying their displayed calendar/time components and nanoseconds. Their UTC offsets are not applied. Load Ruby's `date` library yourself when using Date/DateTime; the engine does not require it. Native temporal objects also work as parameters.

The initial subset includes typed literals, component casts, comparisons, ordering, keys, set queries, persisted defaults/rows/indexes, integer-day and fractional-day arithmetic, DATE + TIME, TIME scaling, and calendar/time field extraction. `WITHOUT TIME ZONE` is accepted. Remaining formats, date/time functions, compatibility modes and complete temporal metadata/optimization remain pending. See [MIGRATION.md](MIGRATION.md) for the precise scope and reference evidence.

`CURRENT_DATE`, `LOCALTIME[(scale)]` and `LOCALTIMESTAMP[(scale)]` use the connection's time zone. `CURDATE()`, `CURTIME([scale])` and `NOW([scale])` are aliases. They share one snapshot within a statement or explicit transaction; commit, rollback, rollback to a savepoint and DDL release it. TIME-to-TIMESTAMP conversion uses that snapshot's date. Defaults containing these functions evaluate at insertion, including after file reopen. Scales range from 0 to 9, with defaults 0 for LOCALTIME and 6 for LOCALTIMESTAMP. Constant expressions may fold at preparation as in H2; [MIGRATION.md](MIGRATION.md) distinguishes those from dynamic casts and defaults.

`TIME[(scale)] WITH TIME ZONE` and `TIMESTAMP[(scale)] WITH TIME ZONE` preserve second-resolution offsets through ±18 hours. Results and parameters use immutable `H2::TimeTimeZoneValue` / `H2::TimestampTimeZoneValue`, with `.offset_seconds`, time/date components and canonical `.to_s` output. Comparisons and keys use their instants; TIME comparisons keep UTC time unwrapped across midnight. `CURRENT_TIME` and `CURRENT_TIMESTAMP` return these zoned types.

```ruby
H2.connect do |connection|
  connection.execute("SET TIME ZONE 'Europe/Paris'")
  value = connection.execute("SELECT TIMESTAMP WITH TIME ZONE '2024-07-01 12:00:00' AT TIME ZONE 'UTC'").rows.first.first
  p value.to_s # => "2024-07-01 10:00:00+00"
end
```

`SET TIME ZONE` accepts a fixed offset, an IANA name or a whole-second day/time interval; `SET TIME ZONE LOCAL` restores the host default. It is local to each connection and survives rollback. `AT TIME ZONE` and `AT LOCAL` preserve the instant while changing its representation. Changing a session zone recompiles prepared statements, and an active transaction's clock keeps its instant. Named zones use system TZif data under `/usr/share/zoneinfo`, including DST gaps, overlaps and future rules, without changing process `TZ`. Data versions can differ from a JDK's bundled tzdb; the observed Casablanca difference is documented and checked separately in [MIGRATION.md](MIGRATION.md).

`DATEADD(field, count, value)` (also `TIMESTAMPADD`) adds calendar units while clamping month/year changes to the last valid day. For example, `DATEADD(month, 1, DATE '2000-01-31')` returns `2000-02-29`. Subday units preserve nanoseconds, wrap TIME within its day, and promote DATE to TIMESTAMP. Zoned arithmetic retains the stored offset. `DATEDIFF(field, start, finish)` (also `TIMESTAMPDIFF`) counts crossed unit boundaries and returns BIGINT; it does not measure a fractional duration. Both functions support timezone fields. Field names are static identifiers or strings, while counts and values can be parameters. ISO weeks start Monday; the initial WEEK calendar starts Sunday. Locale-specific calendars remain pending.

`DATE_TRUNC(field, value)` discards smaller calendar/time fields without rounding; `DATE_TRUNC(month, DATE '2024-02-29')` returns `2024-02-01`. `LAST_DAY(value)` returns the month's final DATE, including leap years. `EXTRACT` also supports ISO week/year fields, signed-year periods and EPOCH, which returns `BigDecimal` seconds with nanosecond fractions. For unzoned timestamps, EPOCH uses calendar days and wall-clock time relative to `1970-01-01` without an offset adjustment. These functions work with parameters, CTAS and saved dynamic defaults; their type, scale and reference-specific behavior are detailed in [MIGRATION.md](MIGRATION.md).

## Intervals

All thirteen SQL interval qualifiers are available, from `INTERVAL YEAR` and `INTERVAL SECOND` through `INTERVAL YEAR TO MONTH` and `INTERVAL DAY TO SECOND`. Year/month intervals and day/time intervals form separate families. Results and parameters use immutable `H2::IntervalValue` objects; `.to_s` returns a canonical SQL interval literal, and `.absolute` returns signed months or nanoseconds according to the family.

```ruby
duration = H2::IntervalValue.parse("DAY TO SECOND", "1 02:03:04.123456789")
H2.connect do |connection|
  connection.execute("CREATE TABLE work(duration INTERVAL DAY(5) TO SECOND(9))")
  connection.execute("INSERT INTO work VALUES(?)", duration)
  p connection.execute("SELECT EXTRACT(HOUR FROM duration) FROM work").rows # => [[2]]
end
```

Declarations default to two leading digits and six fractional-second digits; explicit precision supports 1–18 leading digits and scale 0–9. Literals retain full precision unless specified. Casts, comparisons, set queries, keys, defaults, ROW values, file persistence, interval arithmetic, `ABS`/`SUM`/`AVG` and component/EPOCH extraction have reference coverage. Datetime subtraction returns intervals and accounts for zoned instants where H2 does; `(finish - start) YEAR TO MONTH` selects calendar-month differences, using the session date when one operand is TIME. DATE plus a day/time interval discards partial days, and TIME arithmetic rejects results outside its day. Zoned arithmetic preserves stored offsets. [MIGRATION.md](MIGRATION.md) records the precise limits and preserved Java behavior.

## Persistent SQL databases

Create a new database and reopen it in a later connection or process:

```ruby
H2.connect(path: "people") do |connection|
  connection.execute("CREATE TABLE people(id INT PRIMARY KEY, name VARCHAR(100))")
  connection.execute("INSERT INTO people VALUES (?, ?)", 1, "Ada")
end

H2.connect(path: "people", read_only: true) do |connection|
  p connection.execute("TABLE people").rows # => [[1, "Ada"]]
end
```

`path:` accepts a database base path or a filename ending in `.mv.db`; the example creates `people.mv.db`. File access currently requires 64-bit Linux as described below. An owned connection from `H2.connect(path: ...)` closes its database and releases the file lock on close. For shared connections, use `H2::Database.new(path: ...)` or the block form `H2::Database.open(path) { |database| ... }`, then call `database.connect`. Independent writable database objects for the same file conflict, including opens from Java.

Options include `read_only: true`, `compression: :none/:fast/:high`, and `user:`/`password:` (defaults `sa`/empty). A new file creates that administrator using H2's salted password format; existing files authenticate against their saved user records. SQL file access currently requires an administrator. Full users/roles/permissions, authentication integrations and encryption remain to port.

The catalog, column declarations, defaults, keys, physical indexes and rows use H2's own format. Successful SQL commits synchronize one native transaction containing all changed tables/indexes and catalog records. Integer primary-key row ids and generated row ids are retained across updates. Native SQL can reopen tested Java-created files, and JDBC can reopen tested Ruby-created files. Unsupported catalog statements, schemas, settings and types fail explicitly; this is not general compatibility with every H2 database. Tables currently load into memory, queries scan them, and dirty MVStore maps are rewritten. SQL transaction conflicts still use table versions rather than the storage API's per-key locks.

## Transactions

```ruby
H2.connect do |connection|
  connection.execute("CREATE TABLE people(id INT PRIMARY KEY, name VARCHAR(100))")
  connection.transaction do |session|
    session.execute("INSERT INTO people VALUES (?, ?)", 2, "Grace")
  end
end
```

Transaction blocks commit on normal completion and roll back on exceptions or nonlocal exits. Nested blocks restore a savepoint on failure. SQL `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, `ROLLBACK TO SAVEPOINT` and `SET AUTOCOMMIT` are also available.

As in H2, the implemented DDL commands commit pending changes. File-backed SQL commits use native MVStore undo logs and durable decisions; closing a connection discards its pending SQL changes. A commit interrupted after its durable decision can recover as committed. The SQL executor still detects conflicts at table granularity. Full row-level SQL MVCC, statement snapshots, remaining isolation levels and SQL prepared-transaction commands are pending.

## MVStore files

```ruby
require "h2/mvstore"

H2::MVStore::Store.open("counters.mv", compression: :fast) do |store|
  counters = store.open_map("counters", key_type: :string, value_type: :long)
  counters["visits"] = (counters["visits"] || 0) + 1
  store.commit
end

H2::MVStore::Store.open("counters.mv", read_only: true) do |store|
  counters = store.open_map("counters", key_type: :string, value_type: :long)
  p counters["visits"]
end
```

Maps support `[]`, `[]=`, `delete`, `size` and sorted enumeration. Raw map keys and values default to `:string`; use `:long` for signed 64-bit integers, `:bytes` for binary strings, and `:value` for typed SQL storage values. Specify the same codecs when reopening a raw map: its catalog does not store these builder choices. Maps in H2's transaction store can resolve their codecs from the file's type registry automatically. String keys follow Java's UTF-16 ordering, and typed keys use their storage comparator, including decimal keys with equivalent values but different scales. Inputs are copied and returned strings are frozen.

```ruby
H2::MVStore::Store.open("values.mv") do |store|
  values = store.open_map("values", key_type: :long, value_type: :value)
  values[1] = H2::MVStore::Value.new(:numeric, H2::MVStore::Decimal.new(12500, 4))
end
```

`Value#type` preserves SQL type identity, `#data` exposes its immutable storage representation, and `#to_ruby` converts initial scalars and nested collections. `Decimal` retains both the unscaled integer and scale. The low-level temporal storage values expose H2's packed date/nanosecond/offset fields; the SQL API converts supported DATE/TIME/TIMESTAMP fields into the native objects described above. LOB references retain identifiers and lengths without fetching external content. Storage codecs cover more types than the SQL parser and expression evaluator currently support.

Existing `table.<object_id>` and `index.<object_id>` maps can be opened with inferred registered codecs. Table entries contain `VersionedValue` objects with `current`, `committed`, `operation_id` and `entry_id`; current row fields are in `SearchRow#values`. This is low-level access: callers editing these maps must maintain table/index consistency. The SQL API maintains the supported table/index/catalog relationships itself.

`commit` appends a chunk and synchronizes it before publishing the duplicated file headers. `rollback` restores the last commit; handles for maps created after that commit become invalid. Closing a writable store commits pending changes, including the block form. Compression options are `:none`, `:fast` (LZF) and `:high` (DEFLATE). Read-only opens share a lock; a writable open excludes other readers and writers, including Java processes. File locking currently requires 64-bit Linux on x86_64 or aarch64; local and CI verification use x86_64.

`H2::MVStore::Error#code` exposes MVStore error numbers, separately from SQL errors: 2 for write failures/read-only mutation, 4 for closed handles, 5 for unsupported formats or codecs, 6 for corruption, and 7 for conflicting locks. Remaining SQL lifecycle/transaction behavior, collations, encryption, external LOB content and compaction remain pending. Zoned temporal keys compare by instant. Some other typed-key comparisons, including non-ASCII case-insensitive strings, explicitly fail as unsupported. Opened maps currently materialize sorted entries and use binary search; each changed map is rewritten on commit.

## MVStore transactions

```ruby
require "h2/mvstore"

H2::MVStore::TransactionStore.open("accounts.mv", timeout_ms: 1000) do |store|
  store.transaction do |tx|
    accounts = tx.open_map("accounts", key_type: :string, value_type: :long)
    accounts["Ada"] = 100
    savepoint = tx.savepoint
    accounts["Ada"] = 50
    tx.rollback_to(savepoint)
  end
end
```

This API implements initial READ COMMITTED transactions over versioned maps. Reads see their own writes and committed values from other transactions. Conflicting writes wait up to `timeout_ms`; writes to other keys can proceed. A wait cycle aborts the youngest transaction and releases its rows. Transaction blocks commit on normal completion and roll back on exceptions or nonlocal exits. `begin_transaction` exposes explicit `commit`, `rollback`, numeric savepoints and `prepare(name:)`. Other isolation levels explicitly fail as unsupported.

Transaction maps support enumeration, `put` (returns the old value), `put_if_absent`, `try_put`, `lock`, `delete` and transactional `clear`. New maps default to string keys/values; their codecs are registered in the H2 type registry and inferred on reopen. Transaction creation supports a `max_transactions` limit from 1 through 255. Errors include 100 for corrupt transaction metadata, 101 for lock timeout/conflict, 102 for exhausted slots, 103 for invalid transaction state, and 105 for a deadlock victim.

`commit` synchronizes an H2 undo-log commit marker before rewriting committed values and clearing the log. A failure after that durable decision can recover as committed. `checkpoint` persists open transactions without committing them. Closing the store synchronizes outstanding state; the next writable open rolls back interrupted open transactions and finishes recorded commit decisions. Prepared transactions remain in `in_doubt` for explicit commit/rollback, and read-only opens cannot resolve them. Use the transaction API for updates to coordinated maps; direct raw-map edits bypass its undo and locking rules.

File-backed SQL commits use this storage API internally, while direct map transactions expose its per-key operations. Snapshot/statement isolation, the remaining isolation levels, complete recovery/upgrade behavior and scalable page/cursor handling remain open. The preserved Java snapshot has a reproduced commit-marker recovery bug; native recovery completes that decision. [MIGRATION.md](MIGRATION.md) records the difference and the precise cross-engine evidence.

## SQL and command line

The implemented subset includes table creation and deletion, `CREATE TABLE ... AS`, basic typed columns, defaults, primary and unique keys, `NOT NULL`, parameterized inserts, `INSERT ... SELECT`, updates, deletes, joins, derived tables, set queries, common table expressions, projections, filters, expressions, `VALUES`, ordering, pagination, grouping, distinct results and initial scalar and aggregate functions. `SYSTEM_RANGE`/`GENERATE_SERIES` supports ascending and descending ranges; simple counts and limited scans avoid materializing huge ranges. The supported subset is detailed in [MIGRATION.md](MIGRATION.md).

```sh
bundle exec h2 --execute "SELECT 1 + 2 AS answer;"
bundle exec h2 --database people --read-only --execute "TABLE people;"
bundle exec h2 example.sql
cat example.sql | bundle exec h2
```

An invocation uses a fresh in-memory database unless `--database PATH` is supplied. File options include `--read-only`, `--user NAME` and `--password PASSWORD`; `--zero-based-enums` selects ordinals starting at zero for memory or file databases. Query results use tab-separated columns with escaped control characters; binary columns print hexadecimal `X'...'` literals, and SQL errors exit with status 1. `connection.execute(sql)` accepts one statement; `execute_script(sql)` returns a result for each statement in a script. Script execution is sequential and does not add an implicit transaction.

## Compare against the Java reference

With a JDK and Maven configured, build the original source and run the differential suite:

```sh
mvn -q -f h2/pom.xml -DskipTests package
bundle exec rake test:reference
```

This checks the relational, subquery, binary/UUID, set-query, CTE and temporal SQL fixtures against both engines, including result labels, type names, rows, update counts, errors and SQL states. Generated set/CTE/temporal cases additionally check type families, duplicate/null semantics, precedence, recursive batches, Gregorian boundaries, nanosecond rounding and JDBC prepared parameters. Top-level binary result columns are compared byte-for-byte through JDBC `getBytes`, and a generated UTF-8 comparison covers every byte pair plus multibyte boundaries. It also cross-reads and cross-writes MVStore files with all three compression modes, checks B-tree lookups, preserves unopened maps, verifies file locks in both directions, and recovers commits after process death. Storage tests exercise real SQL rows/indexes and prepared transactions. The persistent SQL suite creates databases with each engine, exchanges SQL changes, reopens through both engines, verifies defaults/keys/row ids/credentials/DDL, and kills writers before commit, after commit and after the durable decision. The reference task reports the Java commit-marker recovery and zero-precision metadata limitations explicitly. Java is used only by this optional reference check; the Ruby runtime and native test suite do not require it. CI runs the reference comparison separately on Ruby 3.4 and 4.0.

## Upstream and license

The Java source, SQL scripts and assets remain under `h2/` as the migration reference. They are not included in the Ruby gem and are not used by the Ruby runtime. Original [H2 documentation](https://h2database.com/html/main.html) describes the complete Java database; it is not a compatibility claim for this port.

The project retains the original [MPL 2.0 / EPL 1.0 licensing](LICENSE.txt).
