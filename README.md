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

The initial subset includes typed literals, component casts, comparisons, ordering, keys, set queries, persisted defaults/rows/indexes, integer-day and fractional-day arithmetic, DATE + TIME, TIME scaling, and calendar/time field extraction. `WITHOUT TIME ZONE` is accepted. Zoned types and text, TIME-to-TIMESTAMP conversion requiring the session date, intervals, remaining date/time functions and full temporal coercion remain pending and fail where unsupported. See [MIGRATION.md](MIGRATION.md) for the precise scope and reference evidence.

`DATEADD(field, count, value)` (also `TIMESTAMPADD`) adds calendar units while clamping month/year changes to the last valid day. For example, `DATEADD(month, 1, DATE '2000-01-31')` returns `2000-02-29`. Subday units preserve nanoseconds, wrap TIME within its day, and promote DATE to TIMESTAMP. `DATEDIFF(field, start, finish)` (also `TIMESTAMPDIFF`) counts crossed unit boundaries and returns BIGINT; it does not measure a fractional duration. Field names are static identifiers or strings, while counts and values can be parameters. ISO weeks start Monday; the initial WEEK calendar starts Sunday. Locale-specific calendars and time-zone fields remain pending.

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

`H2::MVStore::Error#code` exposes MVStore error numbers, separately from SQL errors: 2 for write failures/read-only mutation, 4 for closed handles, 5 for unsupported formats or codecs, 6 for corruption, and 7 for conflicting locks. Remaining SQL lifecycle/transaction behavior, collations, encryption, external LOB content and compaction remain pending. Some typed-key comparisons, including non-ASCII case-insensitive strings and zoned temporal/interval keys, explicitly fail as unsupported. Opened maps currently materialize sorted entries and use binary search; each changed map is rewritten on commit.

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

An invocation uses a fresh in-memory database unless `--database PATH` is supplied. File options include `--read-only`, `--user NAME` and `--password PASSWORD`. Query results use tab-separated columns with escaped control characters; binary columns print hexadecimal `X'...'` literals, and SQL errors exit with status 1. `connection.execute(sql)` accepts one statement; `execute_script(sql)` returns a result for each statement in a script. Script execution is sequential and does not add an implicit transaction.

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
