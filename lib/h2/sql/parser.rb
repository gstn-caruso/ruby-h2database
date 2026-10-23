# frozen_string_literal: true

module H2
  module SQL
    class Parser
      RESERVED = %w[ALL AND AS ASC BETWEEN BY CASE CAST CHECK CONSTRAINT CREATE CROSS DEFAULT DELETE DESC DISTINCT
        DROP ELSE END EXCEPT EXISTS FALSE FETCH FIRST FOREIGN FROM FULL GROUP HAVING IN INNER INSERT INTERSECT INTO
        IS JOIN KEY LEFT LIKE LIMIT MINUS NATURAL NEXT NOT NULL NULLS OFFSET ON ONLY OR ORDER OUTER PRIMARY REFERENCES
        RIGHT ROW ROWS SELECT SET TABLE THEN TRUE UNION UNIQUE UPDATE USING VALUE VALUES WHEN WHERE WITH].freeze
      PRECEDENCE = {"OR" => 1, "AND" => 2, "=" => 4, "<>" => 4, "!=" => 4, "<" => 4,
        ">" => 4, "<=" => 4, ">=" => 4, "||" => 5, "+" => 6, "-" => 6, "*" => 7, "/" => 7, "%" => 7}.freeze
      TYPE_NAMES = {"INT" => "INTEGER", "DECIMAL" => "NUMERIC", "DEC" => "NUMERIC", "BOOL" => "BOOLEAN",
        "CHARACTER" => "CHAR", "VARCHAR" => "VARCHAR", "FLOAT" => "DOUBLE", "RAW" => "VARBINARY",
        "BYTEA" => "VARBINARY", "LONGVARBINARY" => "VARBINARY"}.freeze

      attr_reader :parameter_count

      def initialize(sql)
        @tokens = Lexer.new(sql).tokens
        @position = 0
        @parameter_count = 0
      end

      def parse
        statement = parse_statement
        accept(";")
        syntax("end of statement") unless current.kind == :eof
        statement
      end

      def parse_script
        statements = []
        until current.kind == :eof
          next if accept(";")

          start = @parameter_count
          statement = parse_statement
          syntax("semicolon") unless current.kind == :eof || accept(";")
          statements << [statement, @parameter_count - start]
        end
        statements
      end

      private

      def current
        @tokens.fetch(@position)
      end

      def take
        token = current
        @position += 1 unless token.kind == :eof
        token
      end

      def keyword?(value)
        [:word, :symbol].include?(current.kind) && current.value == value
      end

      def accept(value)
        return false unless keyword?(value)

        take
        true
      end

      def expect(value)
        syntax(value) unless accept(value)
      end

      def syntax(expected)
        raise Error.new(42000, "Expected #{expected} at byte #{current.position}, got #{current.value.inspect}")
      end

      def identifier
        syntax("identifier") unless current.kind == :identifier || (current.kind == :word && !RESERVED.include?(current.value))
        take.value
      end

      def table_name
        first = identifier
        return first unless accept(".")

        raise Error.new(90079, "Schema #{first} not found") unless first == "PUBLIC"
        identifier
      end

      def list
        values = [yield]
        values << yield while accept(",")
        values
      end

      def parenthesized_identifiers
        expect("(")
        values = list { identifier }
        expect(")")
        values
      end

      def optional_alias
        return identifier if accept("AS")
        return take.value if current.kind == :identifier || (current.kind == :word && !RESERVED.include?(current.value))

        nil
      end

      def parse_statement
        return query if query_start? || keyword?("(")

        case take.value
        when "EXPLAIN" then Explain.new(parse_statement)
        when "CREATE" then create
        when "DROP"
          unsupported unless accept("TABLE")
          exists = accept("IF")
          expect("EXISTS") if exists
          DropTable.new(list { table_name }, exists)
        when "TRUNCATE"
          expect("TABLE")
          Truncate.new(table_name)
        when "INSERT" then insert
        when "UPDATE" then update
        when "DELETE"
          expect("FROM")
          name = table_name
          Delete.new(name, accept("WHERE") ? expression : nil)
        when "BEGIN"
          accept("WORK")
          Transaction.new(:begin, nil)
        when "COMMIT"
          accept("WORK")
          Transaction.new(:commit, nil)
        when "ROLLBACK"
          accept("WORK")
          if accept("TO")
            accept("SAVEPOINT")
            Transaction.new(:rollback_to, identifier)
          else
            Transaction.new(:rollback, nil)
          end
        when "SAVEPOINT" then Transaction.new(:savepoint, identifier)
        when "SET"
          unsupported unless accept("AUTOCOMMIT")
          if accept("TRUE")
            SetAutocommit.new(true)
          else
            expect("FALSE")
            SetAutocommit.new(false)
          end
        else unsupported
        end
      end

      def unsupported
        raise Error.new(50100, "SQL feature not yet ported near byte #{current.position}")
      end

      def create
        unsupported unless accept("TABLE")
        if_not_exists = accept("IF")
        if if_not_exists
          expect("NOT")
          expect("EXISTS")
        end
        name = table_name
        columns, keys = keyword?("(") ? column_definitions : [[], []]
        source_query = accept("AS") ? query : nil
        syntax("column definitions or AS query") if columns.empty? && !source_query
        with_data = true
        if source_query && accept("WITH")
          with_data = !accept("NO")
          expect("DATA")
        end
        CreateTable.new(name, columns, keys, if_not_exists, source_query, with_data)
      end

      def column_definitions
        expect("(")
        columns = []
        keys = []
        loop do
          if accept("PRIMARY")
            expect("KEY")
            keys << Key.new(parenthesized_identifiers, true)
          elsif accept("UNIQUE")
            keys << Key.new(parenthesized_identifiers, false)
          else
            column_name = identifier
            type = parse_type
            nullable = true
            default = nil
            loop do
              if accept("PRIMARY")
                expect("KEY")
                keys << Key.new([column_name], true)
                nullable = false
              elsif accept("UNIQUE")
                keys << Key.new([column_name], false)
              elsif accept("NOT")
                expect("NULL")
                nullable = false
              elsif accept("NULL")
                nullable = true
              elsif accept("DEFAULT")
                default = expression
              else
                break
              end
            end
            columns << Column.new(column_name, type, nullable, default)
          end
          break unless accept(",")
        end
        expect(")")
        [columns, keys]
      end

      def parse_type
        name = take.value
        name = TYPE_NAMES.fetch(name, name)
        if name == "CHAR" && accept("VARYING")
          name = "VARCHAR"
        elsif name == "BINARY" && accept("VARYING")
          name = "VARBINARY"
        elsif name == "LONG" && accept("RAW")
          name = "VARBINARY"
        elsif name == "DOUBLE"
          accept("PRECISION")
        end
        unless %w[TINYINT SMALLINT INTEGER BIGINT NUMERIC REAL DOUBLE BOOLEAN VARCHAR CHAR BINARY VARBINARY UUID].include?(name)
          raise Error.new(50100, "Type #{name.inspect} not yet ported")
        end
        precision = name == "NUMERIC" ? 100_000 : (%w[CHAR BINARY].include?(name) ? 1 : nil)
        scale = name == "NUMERIC" ? 0 : nil
        if accept("(")
          precision = positive_integer
          scale = accept(",") ? positive_integer(allow_zero: true) : 0 if name == "NUMERIC"
          expect(")")
          raise Error.new(50100, "Precision for #{name} not supported") unless %w[NUMERIC VARCHAR CHAR BINARY VARBINARY].include?(name)
          if %w[BINARY VARBINARY].include?(name) && precision > 1_000_000_000
            raise Error.new(90150, "Invalid binary precision")
          end
        end
        Type.new(name, precision, scale)
      end

      def positive_integer(allow_zero: false)
        token = take
        syntax("integer") unless token.kind == :literal && token.value.is_a?(Integer)
        if token.value < (allow_zero ? 0 : 1)
          raise Error.new(90008, "Invalid precision or scale")
        end
        token.value
      end

      def insert
        expect("INTO")
        table = table_name
        columns = keyword?("(") && !query_start? ? parenthesized_identifiers : nil
        if accept("DEFAULT")
          expect("VALUES")
          rows = [nil]
        elsif accept("VALUES")
          rows = value_rows
        else
          source_query = query
        end
        Insert.new(table, columns, rows, source_query)
      end

      def update
        table = table_name
        expect("SET")
        assignments = list do
          name = identifier
          expect("=")
          [name, expression]
        end
        Update.new(table, assignments, accept("WHERE") ? expression : nil)
      end

      def query_start?
        return true if %w[SELECT TABLE VALUES WITH].any? { keyword?(it) }
        return false unless keyword?("(")

        start = @position
        start += 1 while @tokens[start]&.kind == :symbol && @tokens[start].value == "("
        return false unless @tokens[start]&.kind == :word && %w[SELECT TABLE VALUES WITH].include?(@tokens[start].value)

        depth = 0
        @tokens[@position..].each_with_index do |token, index|
          depth += 1 if token.kind == :symbol && token.value == "("
          depth -= 1 if token.kind == :symbol && token.value == ")"
          next unless depth.zero?

          following = @tokens[@position + index + 1]
          return !following || following.kind == :eof ||
            ([:word, :symbol].include?(following.kind) && %w[UNION INTERSECT EXCEPT MINUS ORDER LIMIT OFFSET FETCH ) ;].include?(following.value))
        end
        false
      end

      def query
        return with_query if accept("WITH")

        query_body
      end

      def with_query
        old_recursive = @parsing_recursive_with
        if old_recursive && keyword?("RECURSIVE")
          raise Error.new(42001, "Nested RECURSIVE definition")
        end
        recursive = accept("RECURSIVE")
        @parsing_recursive_with = old_recursive || recursive
        begin
          definitions = list do
            name = identifier
            if recursive && !keyword?("(")
              raise Error.new(42001, "Recursive WITH requires column names")
            end
            columns = keyword?("(") ? parenthesized_identifiers : nil
            expect("AS")
            expect("(")
            definition = query
            expect(")")
            CommonTableDefinition.new(name, columns&.freeze, definition)
          end
        ensure
          @parsing_recursive_with = old_recursive
        end
        WithQuery.new(definitions.freeze, query_body, recursive)
      end

      def query_body
        statement = query_term
        loop do
          operator = if accept("UNION")
            if accept("ALL")
              :union_all
            else
              accept("DISTINCT")
              :union
            end
          elsif accept("EXCEPT") || accept("MINUS")
            :except
          else
            break
          end
          statement = SetQuery.new(statement, query_term, operator, [], nil, nil)
        end
        order, limit, offset = query_tail
        syntax("end of query") if statement.limit && (limit || offset)
        changes = {}
        changes[:order] = order unless order.empty?
        changes[:limit] = limit if limit
        changes[:offset] = offset if offset
        changes.empty? ? statement : statement.with(**changes)
      end

      def query_term
        statement = query_primary
        while accept("INTERSECT")
          statement = SetQuery.new(statement, query_primary, :intersect, [], nil, nil)
        end
        statement
      end

      def query_primary
        statement = if accept("(")
          nested = query
          expect(")")
          nested
        else
          case take.value
          when "SELECT" then select
          when "VALUES" then values
          when "TABLE" then table_query
          else raise Error.new(42001, "Expected query primary")
          end
        end
        statement
      end

      def select
        distinct = accept("DISTINCT")
        accept("ALL") unless distinct
        projections = list do
          node = expression
          Projection.new(node, optional_alias)
        end
        source = from_clause if accept("FROM")
        where = expression if accept("WHERE")
        group = if accept("GROUP")
          expect("BY")
          list { expression }
        else
          []
        end
        having = expression if accept("HAVING")
        Select.new(projections, source, where, group, having, distinct, [], nil, nil)
      end

      def table_query
        source = source_name
        Select.new([Projection.new(Star.new(nil), nil)], source, nil, [], nil, false, [], nil, nil)
      end

      def values
        Values.new(value_rows, [], nil, nil)
      end

      def from_clause
        list { table_reference }.reduce do |left, right|
          JoinSource.new(left, right, :cross, nil, [], false)
        end
      end

      def table_reference
        left = table_primary
        loop do
          kind = case current.value
          when "JOIN" then :inner
          when "INNER" then :inner
          when "LEFT" then :left
          when "RIGHT" then :right
          when "CROSS" then :cross
          when "NATURAL" then :natural
          when "FULL" then syntax("supported join type")
          else break
          end
          token = take.value
          accept("OUTER") if [:left, :right].include?(kind)
          expect("JOIN") unless token == "JOIN"
          right = [:cross, :natural].include?(kind) ? table_primary : table_reference
          condition = nil
          using_columns = []
          unless [:cross, :natural].include?(kind)
            if accept("ON")
              condition = expression
            elsif accept("USING")
              using_columns = parenthesized_identifiers
            end
          end
          left = JoinSource.new(left, right, kind == :natural ? :inner : kind, condition, using_columns, kind == :natural)
        end
        left
      end

      def table_primary
        source = if keyword?("VALUES")
          take
          DerivedSource.new(values)
        elsif accept("(")
          nested = query_start? ? DerivedSource.new(query) : from_clause
          expect(")")
          nested
        else
          reference = source_name
          name = reference.name
          if accept("(")
            arguments = keyword?(")") ? [] : list { expression }
            expect(")")
            RangeSource.new(name, arguments)
          else
            reference
          end
        end
        name = optional_alias
        if !name && source.is_a?(DerivedSource)
          @derived_index ||= 0
          name = "_#{@derived_index}"
          @derived_index += 1
        end
        return source unless name

        columns = keyword?("(") ? parenthesized_identifiers : nil
        AliasedSource.new(source, name, columns)
      end

      def source_name
        first = identifier
        return TableSource.new(first, false) unless accept(".")

        raise Error.new(90079, "Schema #{first} not found") unless first == "PUBLIC"

        TableSource.new(identifier, true)
      end

      def value_rows
        list do
          row_keyword = accept("ROW")
          if accept("(")
            row = list { expression }
            expect(")")
            row
          elsif row_keyword
            syntax("(")
          else
            [expression]
          end
        end
      end

      def query_tail
        order = if accept("ORDER")
          expect("BY")
          list do
            positional = (current.kind == :literal && current.value.is_a?(Integer)) || keyword?("?")
            node = expression
            parameter = node
            parameter = parameter.operand while parameter.is_a?(Unary) && parameter.operator == "+"
            if parameter.is_a?(Parameter)
              node = parameter
              positional = true
            else
              positional &&= node.is_a?(Literal) && node.value.is_a?(Integer)
            end
            descending = accept("DESC")
            accept("ASC") unless descending
            nulls = nil
            if accept("NULLS")
              if accept("FIRST")
                nulls = :first
              else
                expect("LAST")
                nulls = :last
              end
            end
            Ordering.new(node, descending, nulls, positional)
          end
        else
          []
        end
        limit = expression if accept("LIMIT")
        if accept("OFFSET")
          offset = expression
          accept("ROW") || accept("ROWS")
        end
        if accept("FETCH")
          accept("FIRST") || expect("NEXT")
          limit = (keyword?("ROW") || keyword?("ROWS")) ? Literal.new(1) : expression
          accept("ROW") || expect("ROWS")
          expect("ONLY")
        end
        [order, limit, offset]
      end

      def expression(minimum = 0)
        left = prefix
        loop do
          if minimum <= 4 && keyword?("IS")
            take
            negate = accept("NOT")
            if accept("DISTINCT")
              expect("FROM")
              left = Predicate.new(negate ? :not_distinct : :distinct, [left, expression(5)])
            else
              target = take.value
              syntax("NULL, TRUE, or FALSE") unless %w[NULL TRUE FALSE].include?(target)
              left = Predicate.new(negate ? :is_not : :is, [left, Literal.new({"NULL" => nil, "TRUE" => true, "FALSE" => false}.fetch(target))])
            end
          elsif minimum <= 4 && predicate_start?
            negate = accept("NOT")
            operator = take.value
            node = case operator
            when "BETWEEN"
              low = expression(5)
              expect("AND")
              Predicate.new(:between, [left, low, expression(5)])
            when "IN"
              expect("(")
              if query_start?
                predicate = InQuery.new(left, query)
              else
                arguments = keyword?(")") ? [] : list { expression }
                predicate = Predicate.new(:in, [left, *arguments])
              end
              expect(")")
              predicate
            when "LIKE"
              pattern = expression(5)
              escape = accept("ESCAPE") ? expression(5) : Literal.new("\\")
              Predicate.new(:like, [left, pattern, escape])
            end
            left = negate ? Unary.new("NOT", node) : node
          elsif accept("::")
            left = Cast.new(left, parse_type)
          else
            precedence = current.kind == :word || current.kind == :symbol ? PRECEDENCE[current.value] : nil
            break unless precedence && precedence >= minimum

            operator = take.value
            left = Binary.new(operator, left, expression(precedence + 1))
          end
        end
        left
      end

      def predicate_start?
        %w[BETWEEN IN LIKE].any? { keyword?(it) } ||
          (keyword?("NOT") && %w[BETWEEN IN LIKE].include?(@tokens[@position + 1]&.value))
      end

      def prefix
        token = take
        return Literal.new(token.value) if token.kind == :literal
        return column_or_function(token) if token.kind == :identifier

        case token.value
        when "NULL" then Literal.new(nil)
        when "TRUE" then Literal.new(true)
        when "FALSE" then Literal.new(false)
        when "UUID"
          if current.kind == :literal && current.value.is_a?(String) && !BinaryString.binary?(current.value)
            Literal.new(UUIDValue.parse(take.value))
          else
            column_or_function(token)
          end
        when "DEFAULT" then Default.new
        when "CASE"
          operand = keyword?("WHEN") ? nil : expression
          branches = []
          while accept("WHEN")
            condition = expression
            expect("THEN")
            branches << [condition, expression]
          end
          syntax("WHEN") if branches.empty?
          fallback = accept("ELSE") ? expression : Literal.new(nil)
          expect("END")
          CaseExpression.new(operand, branches, fallback)
        when "?"
          node = Parameter.new(@parameter_count)
          @parameter_count += 1
          node
        when "NOT" then Unary.new("NOT", expression(3))
        when "+", "-" then Unary.new(token.value, expression(8))
        when "*" then Star.new(nil)
        when "EXISTS"
          expect("(")
          node = Exists.new(query)
          expect(")")
          node
        when "ROW"
          expect("(")
          expressions = keyword?(")") ? [] : list { expression }
          expect(")")
          RowConstructor.new(expressions)
        when "("
          if query_start?
            node = Subquery.new(query)
          else
            node = expression
            if accept(",")
              node = RowConstructor.new([node, *list { expression }])
            end
          end
          expect(")")
          node
        when "CAST"
          expect("(")
          node = expression
          expect("AS")
          type = parse_type
          expect(")")
          Cast.new(node, type)
        else
          if token.kind == :word && !RESERVED.include?(token.value)
            column_or_function(token)
          else
            syntax("expression")
          end
        end
      end

      def column_or_function(token)
        name = token.value
        if accept("(")
          distinct = accept("DISTINCT")
          arguments = keyword?(")") ? [] : list { expression }
          expect(")")
          Function.new(name, arguments, distinct)
        elsif accept(".")
          accept("*") ? Star.new(name) : ColumnRef.new(identifier, name)
        else
          ColumnRef.new(name, nil)
        end
      end
    end
  end
end
