import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import org.h2.engine.CastDataProvider;
import org.h2.jdbc.JdbcConnection;
import org.h2.value.ExtTypeInfoEnum;

public class EnumOracle {
    private static String units(String value) {
        if (value == null) return "null";
        StringBuilder result = new StringBuilder();
        for (int i = 0; i < value.length(); i++) {
            result.append(String.format("%04x", (int)value.charAt(i)));
        }
        return result.toString();
    }

    private static void dump(PreparedStatement statement, Object... values) throws Exception {
        try {
            for (int i = 0; i < values.length; i++) statement.setObject(i + 1, values[i]);
            try (ResultSet result = statement.executeQuery()) {
                var metadata = result.getMetaData();
                for (int i = 1; i <= metadata.getColumnCount(); i++) {
                    String type = metadata.getColumnTypeName(i).replace("CHARACTER VARYING","VARCHAR").replace("DOUBLE PRECISION","DOUBLE");
                    System.out.println("M\t" + units(metadata.getColumnLabel(i)) + "\t" + units(type) + "\t"
                            + metadata.getPrecision(i) + "\t" + metadata.getScale(i));
                }
                while (result.next()) {
                    StringBuilder row = new StringBuilder("R");
                    for (int i = 1; i <= metadata.getColumnCount(); i++) {
                        String value = result.getString(i);
                        row.append('\t').append(units(value));
                        if (value != null && (metadata.getColumnTypeName(i).startsWith("ENUM(") && !metadata.getColumnTypeName(i).endsWith(" ARRAY"))) row.append(':').append(result.getInt(i));
                    }
                    System.out.println(row);
                }
            }
        } catch (SQLException error) {
            System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length > 0) {
            file(args);
            return;
        }
        for (boolean zeroBased : new boolean[] {false,true}) {
            try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:enum_" + zeroBased + ";ZERO_BASED_ENUMS=" + zeroBased);
                    Statement commands = connection.createStatement()) {
                var provider = (CastDataProvider)((JdbcConnection)connection).getSession();
                var type = new ExtTypeInfoEnum(new String[] {"z","A","😀"," quote' "});
                Object[] values = {null," z ","a","😀","QUOTE'","1","missing",0,1,2,3,4,5,-1,
                        2147483648L,new BigDecimal("1.5"),new BigDecimal("2.5"),1.0,Double.NaN,true,
                        new byte[] {0x7a},type.getValue("A",provider)};
                String declaration = "ENUM('z','A','😀',' quote'' ')";
                try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS " + declaration + ") AS e")) {
                    for (Object value : values) dump(statement,value);
                }
                for (String target : new String[] {"TINYINT","INT","NUMERIC(8,2)","REAL","DOUBLE","DECFLOAT(8)","VARCHAR","BOOLEAN","JSON"}) {
                    try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(CAST(? AS " + declaration + ") AS " + target + ") AS v")) {
                        for (Object value : new Object[] {null,0,1,2,"a",type.getValue("A",provider)}) dump(statement,value);
                    }
                }
                try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS " + declaration + ")+? AS n")) {
                    for (Object[] pair : new Object[][] {{"a",1},{"a","1"},{"a","1.5"},{null,"bad"},{"a",Integer.MAX_VALUE}}) dump(statement,pair);
                }
                commands.execute("CREATE TABLE t(e " + declaration + " PRIMARY KEY)");
                try (PreparedStatement statement = connection.prepareStatement("INSERT INTO t VALUES(?)")) {
                    for (String value : new String[] {"z","A","😀"," quote' "}) {
                        statement.setString(1,value);
                        statement.execute();
                    }
                }
                try (PreparedStatement statement = connection.prepareStatement("SELECT e,CAST(e AS INT) AS n FROM t WHERE e>=? ORDER BY e")) {
                    for (Object value : new Object[] {"z"," A ","😀",null,"missing"}) dump(statement,value);
                }
                try (PreparedStatement statement = connection.prepareStatement("SELECT MIN(e) AS lo,MAX(e) AS hi,ARRAY_AGG(e ORDER BY e) AS a FROM t")) { dump(statement); }
                try (PreparedStatement statement = connection.prepareStatement("SELECT CAST(? AS ENUM(U&'\\d800','😀')) AS e")) {
                    for (Object value : new Object[] {"\ud800","😀",null}) dump(statement,value);
                }
                for (String sql : new String[] {"SELECT CAST(? AS ENUM('z','a'))","SELECT CAST('bad' AS ENUM('z','a')) WHERE FALSE",
                        "SELECT CAST(NULL AS ENUM('a',' A '))","SELECT CAST(1 AS ENUM('z','a'))=1", "SELECT -CAST(1 AS ENUM('z','a'))"}) {
                    try (PreparedStatement statement = connection.prepareStatement(sql)) { System.out.println("P\tprepared"); }
                    catch (SQLException error) { System.out.println("P\t" + error.getErrorCode() + "\t" + error.getSQLState()); }
                }
            }
        }
    }

    private static void file(String[] args) throws Exception {
        String labels = java.util.stream.IntStream.rangeClosed(1,20).mapToObj(i -> "'e" + i + "'").collect(java.util.stream.Collectors.joining(","));
        String type = "ENUM(" + labels + ")";
        try (Connection connection = DriverManager.getConnection("jdbc:h2:" + args[1] + ";ZERO_BASED_ENUMS=" + args[2],"sa","");
                Statement statement = connection.createStatement()) {
            switch (args[0]) {
            case "create":
                statement.execute("CREATE TABLE items(e " + type + " PRIMARY KEY,a ENUM('a','b') ARRAY,u ENUM(U&'\\d800','😀'))");
                statement.execute("INSERT INTO items VALUES('e1',ARRAY['a','b'],U&'\\d800'),('e15',NULL,'😀'),('e16',ARRAY[],NULL),('e20',ARRAY['b'],U&'\\d800')");
                statement.execute("CREATE TABLE saved(e " + type + " DEFAULT (SELECT MIN(e) FROM items))");
                statement.execute("INSERT INTO saved DEFAULT VALUES");
                break;
            case "append":
                statement.execute("DELETE FROM items WHERE e='e1'");
                statement.execute("UPDATE items SET a=ARRAY[' A '] WHERE e='e15'");
                statement.execute("INSERT INTO items VALUES('e17',ARRAY['B'],U&'\\d800')");
                statement.execute("INSERT INTO saved DEFAULT VALUES");
                break;
            case "dump":
                try (PreparedStatement query = connection.prepareStatement("SELECT e,CAST(e AS INT) AS n,a,u,CAST(u AS INT) AS o FROM items ORDER BY e")) { dump(query); }
                try (PreparedStatement query = connection.prepareStatement("TABLE saved ORDER BY e")) { dump(query); }
                break;
            default: throw new IllegalArgumentException(args[0]);
            }
        }
    }
}
