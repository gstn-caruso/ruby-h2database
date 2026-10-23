# frozen_string_literal: true

module H2
  module SQL
    Literal = Data.define(:value)
    Parameter = Data.define(:index)
    ColumnRef = Data.define(:name, :qualifier)
    Star = Data.define(:qualifier)
    Default = Data.define
    Unary = Data.define(:operator, :operand)
    Binary = Data.define(:operator, :left, :right)
    Predicate = Data.define(:operator, :arguments)
    Function = Data.define(:name, :arguments, :distinct)
    Cast = Data.define(:expression, :type)
    Projection = Data.define(:expression, :label)
    Ordering = Data.define(:expression, :descending, :nulls)
    Select = Data.define(:projections, :table, :alias_name, :where, :group, :having, :distinct, :order, :limit, :offset)
    Values = Data.define(:rows, :order, :limit, :offset)
    Explain = Data.define(:statement)
    CreateTable = Data.define(:name, :columns, :keys, :if_not_exists)
    DropTable = Data.define(:name, :if_exists)
    Truncate = Data.define(:name)
    Insert = Data.define(:table, :columns, :rows)
    Update = Data.define(:table, :assignments, :where)
    Delete = Data.define(:table, :where)
    Transaction = Data.define(:operation, :name)
    SetAutocommit = Data.define(:value)
  end
end
