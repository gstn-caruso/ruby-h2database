# Ruby H2 Database

A native Ruby migration of the [H2 SQL database](https://h2database.com), targeting Ruby 3.4 and 4.0. The Ruby engine runs in-process without Java or another database engine.

**The migration is in progress.** The current Ruby implementation provides an initial SQL engine in memory and a separate, file-backed MVStore API. MVStore reads and writes H2 format 3 maps with string and signed 64-bit integer codecs. SQL tables are not yet connected to this storage, and the port does not replace the complete Java engine. See [MIGRATION.md](MIGRATION.md) for the remaining scope and compatibility evidence.

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

`H2.connect` creates an isolated in-memory database. Use `H2::Database.new` and call `database.connect` for multiple connections sharing a database. Block forms close their connection automatically. Closing the last connection does not discard an explicitly retained `Database` object.

Parameters are positional values supplied after SQL. `prepare(sql)` returns a reusable statement with `execute(*values)` and `parameter_count`. Strings are copied before use, and results expose frozen columns, row arrays and string values. `rows` preserves duplicate column labels; enumeration produces hashes, where the last value for a repeated label wins.

Queries can combine tables with inner, left, right, cross, natural and `USING` joins, or read derived `SELECT`, `VALUES` and `TABLE` queries. Qualified column references retain their source, and ambiguous names raise an error. `result.types` exposes the initial SQL type information used across query boundaries; precision and other metadata still need full H2 compatibility.

Scalar and correlated subqueries work in expressions, `EXISTS`, `IN`/`NOT IN`, inserts, updates and deletes. An empty single-column scalar query returns `nil`; multiple rows raise H2 error 90053. A multi-column scalar query returns an immutable `H2::RowValue`, whose fields are available through `.values`; an empty multi-column query returns a row of `nil` fields. `ROW(...)` constructors, row comparisons and searched/simple `CASE` expressions are also available.

Query preparation validates reachable expressions and inner scopes before scanning rows. As in H2, derived tables, range arguments and pagination expressions cannot refer to an outer query. Defaults containing subqueries read the current data when used and retain any parameters supplied when the table was created.

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

As in H2, the implemented DDL commands commit pending changes. The current concurrency mechanism detects conflicts at table granularity. Row locks, full MVCC and the remaining isolation levels are still pending.

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

Maps support `[]`, `[]=`, `delete`, `size` and sorted enumeration. Keys and values default to `:string`; use `:long` for signed 64-bit integers. Specify the same codecs when reopening a map: H2's raw MVStore catalog does not store these builder choices. String keys follow Java's UTF-16 ordering. Inputs are copied and returned strings are frozen.

`commit` appends a chunk and synchronizes it before publishing the duplicated file headers. `rollback` restores the last commit; handles for maps created after that commit become invalid. Closing a writable store commits pending changes, including the block form. Compression options are `:none`, `:fast` (LZF) and `:high` (DEFLATE). Read-only opens share a lock; a writable open excludes other readers and writers, including Java processes. File locking currently requires 64-bit Linux on x86_64 or aarch64; local and CI verification use x86_64.

`H2::MVStore::Error#code` exposes MVStore error numbers, separately from SQL errors: 2 for write failures/read-only mutation, 4 for closed handles, 5 for unsupported formats or codecs, 6 for corruption, and 7 for conflicting locks. The API can inspect map names in an existing `.mv.db` file, but SQL value serialization, transaction maps, encryption, compaction and SQL database reopening remain pending. Opened maps currently materialize their entries, and each changed map is rewritten on commit.

## SQL and command line

The implemented subset includes table creation and deletion, `CREATE TABLE ... AS`, basic typed columns, defaults, primary and unique keys, `NOT NULL`, parameterized inserts, `INSERT ... SELECT`, updates, deletes, joins, derived tables, projections, filters, expressions, `VALUES`, ordering, pagination, grouping, distinct results and initial scalar and aggregate functions. `SYSTEM_RANGE`/`GENERATE_SERIES` supports ascending and descending ranges; simple counts and limited scans avoid materializing huge ranges. The supported subset is detailed in [MIGRATION.md](MIGRATION.md).

```sh
bundle exec h2 --execute "SELECT 1 + 2 AS answer;"
bundle exec h2 example.sql
cat example.sql | bundle exec h2
```

Each invocation creates a fresh in-memory database and executes a script. Query results use tab-separated columns with escaped control characters, and SQL errors exit with status 1. `connection.execute(sql)` accepts one statement; `execute_script(sql)` returns a result for each statement in a script. Script execution is sequential and does not add an implicit transaction.

## Compare against the Java reference

With a JDK and Maven configured, build the original source and run the differential suite:

```sh
mvn -q -f h2/pom.xml -DskipTests package
bundle exec rake test:reference
```

This checks the relational and subquery SQL fixtures against both engines, including result labels, type names, rows, update counts, errors and SQL states. It also cross-reads and cross-writes MVStore files with all three compression modes, checks B-tree lookups, preserves unopened maps, verifies file locks in both directions, and recovers a commit after process death. Java is used only by this optional reference check; the Ruby runtime and native test suite do not require it. CI runs the reference comparison separately on Ruby 3.4 and 4.0.

## Upstream and license

The Java source, SQL scripts and assets remain under `h2/` as the migration reference. They are not included in the Ruby gem and are not used by the Ruby runtime. Original [H2 documentation](https://h2database.com/html/main.html) describes the complete Java database; it is not a compatibility claim for this port.

The project retains the original [MPL 2.0 / EPL 1.0 licensing](LICENSE.txt).
