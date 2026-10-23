import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

public class BitFunctionsOracle {
    private static void dump(PreparedStatement statement, Object... values) throws Exception {
        try {
            for (int i = 0; i < values.length; i++) {
                statement.setObject(i + 1, values[i]);
            }
            try (ResultSet result = statement.executeQuery()) {
                var metadata = result.getMetaData();
                for (int i = 1; i <= metadata.getColumnCount(); i++) {
                    String type = metadata.getColumnTypeName(i).replace("BINARY VARYING", "VARBINARY");
                    System.out.println("M\t" + metadata.getColumnLabel(i) + "\t" + type + "\t"
                            + metadata.getPrecision(i) + "\t" + metadata.getScale(i));
                }
                while (result.next()) {
                    StringBuilder row = new StringBuilder("R");
                    for (int i = 1; i <= metadata.getColumnCount(); i++) {
                        String type = metadata.getColumnTypeName(i);
                        String value = result.getString(i);
                        if (value != null && (type.equals("BINARY") || type.equals("BINARY VARYING"))) {
                            value = java.util.HexFormat.of().formatHex(result.getBytes(i));
                        }
                        row.append('\t').append(value);
                    }
                    System.out.println(row);
                }
            }
        } catch (SQLException error) {
            System.out.println("E\t" + error.getErrorCode() + "\t" + error.getSQLState());
        }
    }

    public static void main(String[] arguments) throws Exception {
        try (Connection connection = DriverManager.getConnection("jdbc:h2:mem:bits");
                Statement commands = connection.createStatement()) {
            String[] types = {"TINYINT","SMALLINT","INT","BIGINT","BINARY(2)","VARBINARY(4)"};
            Object[][] pairs = {{"3","6"},{null,"bad"},{"bad",null},{null,null},{-1,127},{128,1},{32768,-1},
                    {2147483648L,1},{Long.MIN_VALUE,Long.MAX_VALUE},{"1_0","2"},
                    {new BigDecimal("1.5"),new BigDecimal("2.5")},{Double.NaN,0},
                    {new byte[] {(byte)0xc5,1},new byte[] {0x63}},{new byte[] {(byte)0xff},new byte[] {0}},
                    {new byte[] {},new byte[] {(byte)0xff,(byte)0xff}}};
            for (String type : types) {
                for (String name : new String[] {"BITAND","BITOR","BITXOR","BITNAND","BITNOR","BITXNOR"}) {
                    try (PreparedStatement statement = connection.prepareStatement("SELECT " + name
                            + "(CAST(? AS " + type + "),CAST(? AS " + type + ")) AS v")) {
                        for (Object[] pair : pairs) {
                            dump(statement,pair);
                        }
                    }
                }
                for (String name : new String[] {"BITGET","LSHIFT","RSHIFT","ULSHIFT","URSHIFT","ROTATELEFT","ROTATERIGHT"}) {
                    try (PreparedStatement statement = connection.prepareStatement("SELECT " + name + "(CAST(? AS " + type + "),?) AS v")) {
                        for (Object value : new Object[] {null,-1,1,new byte[] {(byte)0xc5,1}}) {
                            for (Object offset : new Object[] {-1,0,1,7,8,31,32,63,64,65,Long.MIN_VALUE,Long.MAX_VALUE,"1_0",Double.NaN}) {
                                dump(statement,value,offset);
                            }
                        }
                    }
                }
                for (String name : new String[] {"BITNOT","BITCOUNT"}) {
                    try (PreparedStatement statement = connection.prepareStatement("SELECT " + name + "(CAST(? AS " + type + ")) AS v")) {
                        for (Object value : new Object[] {null,-1,1,"1_0",Double.NaN,new byte[] {(byte)0xff},new byte[] {}}) {
                            dump(statement,value);
                        }
                    }
                }
            }
            for (String name : new String[] {"BITGET","BITCOUNT"}) {
                try (PreparedStatement statement = connection.prepareStatement("SELECT " + name + "(?" + (name.equals("BITGET") ? ",?" : "") + ") AS v")) {
                    for (Object value : new Object[] {null,-1,1,2147483648L,Long.MIN_VALUE,true,"1",1.5,new byte[] {0x10,1}}) {
                        if (name.equals("BITGET")) {
                            for (Object offset : new Object[] {-1,0,8,64,"bad"}) {
                                dump(statement,value,offset);
                            }
                        } else {
                            dump(statement,value);
                        }
                    }
                }
            }
            commands.execute("CREATE TABLE source(a TINYINT,b BIGINT,v VARBINARY)");
            commands.execute("INSERT INTO source VALUES(3,6,X'c501'),(3,6,X'c501'),(1,7,X'63'),(NULL,NULL,NULL)");
            for (String name : new String[] {"BIT_AND_AGG","BIT_OR_AGG","BIT_XOR_AGG","BIT_NAND_AGG","BIT_NOR_AGG","BIT_XNOR_AGG"}) {
                try (PreparedStatement statement = connection.prepareStatement("SELECT " + name + "(a) AS a,"
                        + name + "(DISTINCT a) FILTER(WHERE b>?) AS d," + name + "(v) AS v FROM source")) {
                    for (Object threshold : new Object[] {0,6,7,null}) {
                        dump(statement,threshold);
                    }
                }
            }
            for (String sql : new String[] {"SELECT BITAND(?,1)","SELECT BITNOT(?)","SELECT LSHIFT(?,1)",
                    "SELECT BITCOUNT(?)","SELECT BITGET(?,?)","SELECT BITAND(NULL,X'01')","SELECT BITGET('bad',-1)",
                    "SELECT BITCOUNT('bad') WHERE FALSE","SELECT LSHIFT('bad',0) WHERE FALSE",
                    "SELECT LSHIFT(CAST(? AS INT),?)","SELECT BIT_AND_AGG(?)"}) {
                try (PreparedStatement statement = connection.prepareStatement(sql)) {
                    System.out.println("P\tprepared");
                } catch (SQLException error) {
                    System.out.println("P\t" + error.getErrorCode() + "\t" + error.getSQLState());
                }
            }
        }
    }
}
