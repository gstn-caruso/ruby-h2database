# MVStore reference fixtures

These files were generated from the preserved Java engine at upstream commit `41d021b3e`, version `2.5.259-SNAPSHOT`, using `test/reference/MVStoreOracle.java`. They are test data, not user databases. Native tests only open them read-only; mutation tests use temporary copies or newly generated stores.

- `primitives.tsv`: 50 vectors for variable-length integers, UTF-16 strings, encoded page lengths and Fletcher32 checksums. String inputs are represented as UTF-16 code-unit hex, including isolated surrogates.
- `java-0.mv`: two string/long maps, two commits, without compression.
- `java-1.mv`: the same records with LZF compression.
- `java-2.mv`: the same records with DEFLATE compression.
- `java-sql.mv.db`: a JDBC-created table, primary key, secondary index and one row, used to verify parsing of SQL database map catalogs. Native decoding of SQL rows remains pending.

From the repository root, with a JDK configured:

```sh
mvn -q -f h2/pom.xml -DskipTests package
java -cp h2/target/h2-2.5.259-SNAPSHOT.jar test/reference/MVStoreOracle.java golden > test/fixtures/mvstore/primitives.tsv
```

For each compression level `0`, `1` or `2`, the `create` command takes a fresh output path:

```sh
java -cp h2/target/h2-2.5.259-SNAPSHOT.jar test/reference/MVStoreOracle.java create /tmp/java-0.mv 0
```

Generate a SQL fixture with `sql /tmp/java-sql`; H2 creates `/tmp/java-sql.mv.db`. Copy newly generated files into this directory deliberately, since headers contain creation timestamps and regeneration changes binary bytes. `bundle exec rake test:reference` creates fresh stores in a temporary directory and checks cross-engine reads, writes, compression, locks and recovery without replacing these fixtures.
