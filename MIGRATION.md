# Migration to modern Ruby

## Objective and completion criteria

Port the H2 database engine in this repository to native modern Ruby. The objective remains the complete project, including its SQL behavior, storage, transactions, tools and network services. A Ruby facade over Java, a replacement backend, or a passing subset of SQL tests does not complete the migration.

The reference is the Java tree at upstream commit `41d021b3e`, version `2.5.259-SNAPSHOT` in `h2/pom.xml`. At migration start, `h2/src/main` contains 843 Java files and `h2/src/test/org/h2/test/scripts` contains 319 SQL scripts. Keep the reference source, fixtures, resources and licensing until their replacement has equivalent evidence.

Target runtimes are MRI Ruby 3.4 and 4.0, using Ruby classes, immutable `Data` nodes, keyword arguments and `Enumerable`. Development uses Ruby 4.0.7, matching the [current stable download](https://www.ruby-lang.org/en/downloads/) at migration start. `Gemfile.lock` records dependencies. Java is only a reference/testing tool, not a runtime dependency of the gem.

Completion requires:

1. The complete SQL script corpus and relevant Java regression scenarios have Ruby equivalents with matching results, update counts, metadata, errors and transactional behavior. Unsupported cases remain explicit gaps; they are not silently skipped or reclassified as supported.
2. A Ruby implementation of MVStore and its dependencies can read, write and reopen existing H2 database files, including recovery, compression, encryption, LOBs and upgrade scenarios. Tests must cross-read and cross-write with the reference engine and exercise interrupted commits and corrupted files.
3. Transaction, locking and isolation scenarios demonstrate H2-equivalent behavior under concurrent connections and processes. Query and index behavior is verified against the reference and benchmarks.
4. Embedded APIs, SQL tools, authentication, server protocols and the web console work in Ruby. Java-specific interfaces need an explicit interoperability or Ruby adaptation decision and tests; they remain pending until resolved.
5. The packaged gem, executable, documentation and CI run on the target Ruby release lines without requiring Java for normal use. Remove obsolete build/runtime paths only when replacement coverage is complete.

## Implemented foundation

The gem loads through `require "h2"`. `H2::Database` owns a catalog of immutable table versions; `H2::Connection` owns uncommitted changes and savepoints. Each successful modifying statement publishes a new table version or adds it to a transaction. Statement failures discard their local copy. Commit checks the original table versions under a database mutex before publishing the entire change set.

The SQL pipeline has a lexer, parser, immutable syntax nodes, expression evaluation and a statement executor. `H2::Result` provides column labels, rows, update counts and hash enumeration. `H2::Error` exposes an H2 error code and SQL state for the implemented errors. There is no SQL `eval`, subprocess-backed engine or alternate database backend.

Current syntax and behavior:

- Unquoted uppercase identifiers, quoted identifiers, string escaping, line and nested block comments; decimal/exponent literals and hexadecimal, octal and binary integers with digit separators.
- `SELECT` against one table or without `FROM`, `TABLE`, scalar and row `VALUES`, `DISTINCT`, projections, aliases, filters, `GROUP BY`, `HAVING`, `ORDER BY`, null ordering, `LIMIT`, `OFFSET`, and `FETCH FIRST/NEXT ... ROW(S) ONLY`.
- Positional `?` parameters with count checks, reusable prepared statements and copied string inputs. Literal default expressions capture their creation-time values, including parameters.
- Integer arithmetic and bounds, decimal arithmetic using `BigDecimal`, comparisons, boolean three-valued logic, concatenation, `IS NULL/TRUE/FALSE`, `IS [NOT] DISTINCT FROM`, `BETWEEN`, `IN`, and `LIKE ... ESCAPE`.
- Initial `CAST` and assignment conversion for `TINYINT`, `SMALLINT`, `INTEGER`/`INT`, `BIGINT`, `NUMERIC`/`DECIMAL`/`DEC`, `REAL`, `DOUBLE`/`FLOAT`, `BOOLEAN`/`BOOL`, `VARCHAR`/`CHARACTER VARYING` and `CHAR`/`CHARACTER`. This is not complete type-system parity; coercion, precision propagation, collations and edge cases remain to port.
- `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`; aggregate `DISTINCT`; initial `UPPER`/`UCASE`, `LOWER`/`LCASE`, `LENGTH`/`CHAR_LENGTH`, `ABS`, `COALESCE`, `NULLIF` and `MOD`. `EXPLAIN` currently only formats plain `VALUES` statements.
- `CREATE TABLE [IF NOT EXISTS]`, typed columns, defaults, inline and composite primary/unique constraints, `NOT NULL`, `DROP TABLE [IF EXISTS]`, and `TRUNCATE TABLE`.
- Multi-row `INSERT ... VALUES` and `INSERT ... DEFAULT VALUES`, column lists and `DEFAULT`; scalar assignments in `UPDATE`; `DELETE ... WHERE`. Statements validate columns even on empty tables and enforce constraints atomically.
- Autocommit, explicit commit/rollback, named savepoints, transaction blocks and nested transaction blocks. DDL commits pending DML as in H2. Changes on untouched tables see later commits; a modified table retains its transaction-local version until commit. Concurrent writes to the same table fail at commit with code 90131. This is a transitional table-level implementation, not H2's row-level MVCC or locking behavior.
- Ruby CLI for inline SQL, SQL files and stdin; gem packaging; Ruby CI matrix alongside the preserved upstream Java CI.

## Compatibility evidence

Run `bundle exec rake test` for native integration tests and original upstream expectations. The upstream adapter reads statements and expected output directly from the checked-in scripts and resolves symbolic expected errors using `h2/src/main/org/h2/api/ErrorCode.java`.

The complete upstream scripts currently executed are:

- `datatypes/int.sql` (11 statements)
- `functions/string/upper.sql` (2 statements)
- `functions/string/lower.sql` (2 statements)
- `functions/system/coalesce.sql` (1 statement)
- `functions/numeric/mod.sql` (1 statement)

Partial coverage is explicit in `test/upstream_test.rb`: the first 6 statements in `dml/insert.sql` and the first 3 in `queries/values.sql`. This is 26 original statements across 5 complete and 2 partial scripts. The remaining corpus is unverified, not passing. The adapter currently covers plain statements and tabular/scalar expectations; upstream directives, prepared-parameter blocks and reconnect scenarios still need implementation.

Native tests additionally exercise parameter safety, defaults, casts, constraints, aggregate types, empty-table binding, rollback after failures and nonlocal exits, savepoints, multi-connection visibility, lost-update rejection and atomic multitable commits. They do not prove MVStore, all SQL behavior, row locks, performance or protocol compatibility.

Local verification passes 67 tests and 292 assertions on both Ruby 3.4.10 and Ruby 4.0.7. The gem is built and installed into a temporary gem directory, then loaded and exercised from outside the checkout; its installed executable is checked too. The 3.4/4.0 CI matrix is configured; a workflow definition alone does not prove those remote jobs have run. Packaging and CLI checks are separate from SQL compatibility.

## Remaining migration work

| Upstream areas | Status and required work |
| --- | --- |
| `command`, `bnf`, `expression` | Initial SQL subset exists. Port the rest of the grammar, joins, subqueries, derived tables, set operations, CTEs, windows, aggregates, functions, expressions, `MERGE`, insert-select, row assignments and explain plans. Run all original SQL scripts and parser regression cases. |
| `value` | Initial scalar types exist. Port full numeric semantics, string/binary variants, dates/times/time zones, intervals, arrays, rows, JSON, UUID, enum, geometry and LOB values; validate conversion, metadata, precision and comparison behavior. |
| `table`, `schema`, `constraint` | Initial tables and key/null checks exist. Port schemas, metadata/INFORMATION_SCHEMA, identity and generated columns, sequences, domains, views, temporary/linked tables, foreign keys, checks, triggers, cascades and remaining DDL. |
| `index`, `result`, query planning | Queries currently scan in-memory rows. Port indexes and cursors, optimizer/costing, lazy/streaming/external results, result metadata and query caching, with matching plans and benchmark evidence. |
| `mvstore`, `store`, `compress` | Pending. Port pages/maps, serialization, file formats, caches, compression, chunk allocation, compaction, LOB storage, locking, recovery and durable commits. Do not substitute another engine or claim `.mv.db` compatibility without cross-engine tests. |
| `engine`, `mvstore/tx` | Initial sessions and table-version transactions exist. Port row-level MVCC, deadlock/timeout handling, all isolation levels, durable/prepared transactions, settings, lifecycle, schema locks and concurrent-process behavior. |
| `mode` | Pending. Port the SQL compatibility modes and their behavior tests. |
| `security`, `security/auth` | Pending. Port users, roles, permissions, authentication, hashing, encryption and credentials integration with regression evidence. |
| `server`, `server/pg`, `server/web` | Pending. Port H2 TCP protocol, PostgreSQL protocol/ODBC interoperability and the browser console, including sessions, errors and authentication. Preserve reusable web assets. |
| `jdbc`, `jdbcx`, `api`, `jmx` | The new Ruby API covers only initial embedded usage. JDBC/JNDI/XA, Java callbacks/UDFs, generated keys, batches, metadata and JMX need explicit Ruby adaptation or interoperability designs and tests. These requirements are still open. |
| `tools`, `fulltext` | A basic SQL CLI exists. Port scripting, backup/restore/recovery, CSV import/export, server tooling and full-text indexing/search. |
| `util`, `message`, `res` | Initial errors and lexer utilities exist. Port required helpers, tracing, diagnostics, locale/resources, geometry/JSON helpers and remaining error semantics as their consumers migrate. |
| Packaging, CI, documentation | Gem/executable and initial Ruby workflows exist. Verify all target runtimes, installed-package use, releases and complete usage documentation. Retire Java build artifacts only after full migration validation. |

The next engine slices should expand the SQL/table model against original fixtures, then port MVStore with the actual H2 file format. Every slice must retain the complete objective and add evidence for the migrated behavior. This document records progress; it is not a declaration of completion.

## Delivery cycle

Deliver coherent migration slices regularly: implement and verify behavior, update the README and this compatibility record, commit the slice, merge it into `master`, then push `master` to `origin`. Check available CI results after publishing and address failures before proceeding with further feature work. Repeat this cycle while preserving the full migration objective and making remaining gaps explicit.
