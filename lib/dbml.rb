require 'rsec'
include Rsec::Helpers

module DBML
  Column     = Struct.new :name, :type, :settings
  Table      = Struct.new :name, :alias, :notes, :columns, :indexes
  Index      = Struct.new :fields, :settings
  Expression = Struct.new :text
  Enum       = Struct.new :name, :choices
  EnumChoice = Struct.new :name, :settings
  TableGroup = Struct.new :name, :tables
  Project    = Struct.new :name, :notes, :settings, :tables, :enums, :table_groups
  ProjectDef = Struct.new :name, :notes, :settings

  module Parser
    def self.long_or_short p
      (':'.r >> p) | ('{'.r >> p << '}'.r)
    end

    def self.unwrap p, *_
      if p.empty? then nil else p.first end
    end

    def self.comma_separated p
      p.join(/, */.r.map {|_| nil}).star.map {|v| v.first.reject(&:nil?) }
    end

    def self.space_surrounded p
      /\s*/.r >> p << /\s*/.r
    end

    def self.block type, name_parser, content_parser, &block
      seq_(type.r >> name_parser, '{'.r >> space_surrounded(content_parser).star.map {|a| a.flatten(1) } << '}'.r, &block)
    end

    BOOLEAN            = 'true'.r | 'false'.r
    NULL               = 'null'.r
    NUMBER             = prim(:double)
    EXPRESSION         = seq('`'.r, /[^`]+/.r, '`'.r)[1].map {|str| Expression.new str}
    SINGLE_LING_STRING = seq("'".r, /[^']+/.r, "'".r)[1]
    MULTI_LINE_STRING  = seq("'''".r, /([^']|'[^']|''[^'])+/m.r, "'''".r)[1].map do |string|
      # Remove the indentation on the first line from all other lines.
      indent = string.match(/^\s*/m)[0].size
      string.lines.map do |line|
        raise "Indentation does not match" unless line =~ /\s{#{indent}}/
        line[indent..]
      end.join
    end
    STRING = SINGLE_LING_STRING | MULTI_LINE_STRING
    ATOM = BOOLEAN | NULL | NUMBER | EXPRESSION | STRING

    # Each setting item can take in 2 forms: Key: Value or keyword, similar to that of Python function parameters.
    SETTING = seq_(/[^,:\[\]\{\}\s]+/.r, (':'.r >> ATOM).maybe(&method(:unwrap))) {|(key, value)| {key => value} }
    # Settings are all defined within square brackets: [setting1: value1, setting2: value2, setting3, setting4]
    SETTINGS = ('['.r >> comma_separated(SETTING) << ']'.r).map {|values| values.reduce({}, &:update) }

    NOTE = 'Note'.r >> (long_or_short STRING)

    # Index Definition
    #
    # Indexes allow users to quickly locate and access the data. Users can define single or multi-column indexes.
    #
    #     Table bookings {
    #       id integer
    #       country varchar
    #       booking_date date
    #       created_at timestamp
    #
    #       indexes {
    #           (id, country) [pk] // composite primary key
    #           created_at [note: 'Date']
    #           booking_date
    #           (country, booking_date) [unique]
    #           booking_date [type: hash]
    #           (`id*2`)
    #           (`id*3`,`getdate()`)
    #           (`id*3`,id)
    #       }
    #     }
    #
    # There are 3 types of index definitions:
    #
    #     Index with single field (with index name): CREATE INDEX on users (created_at)
    #     Index with multiple fields (composite index): CREATE INDEX on users (created_at, country)
    #     Index with an expression: CREATE INDEX ON films ( first_name + last_name )
    #     (bonus) Composite index with expression: CREATE INDEX ON users ( country, (lower(name)) )

    INDEX_SINGLE = /[^\(\)\,\{\}\s]+/.r
    INDEX_COMPOSITE = seq_('('.r, comma_separated(EXPRESSION | INDEX_SINGLE), ')'.r).inner.map {|v| unwrap(v) }
    INDEX = seq_(INDEX_SINGLE | INDEX_COMPOSITE, SETTINGS.maybe).map do |(fields, settings)|
      Index.new fields, unwrap(settings)
    end
    INDEXES = ('indexes {'.r >> INDEX.star << '}'.r).map{|v| p v; v }

    # Enum Definition
    # ---------------
    #
    # Enum allows users to define different values of a particular column.
    #
    #     enum job_status {
    #         created [note: 'Waiting to be processed']
    #         running
    #         done
    #         failure
    #     }

    ENUM_CHOICE = seq_(/\S+/.r, SETTINGS.maybe).map {|(name, settings)| EnumChoice.new name, unwrap(settings) }
    ENUM = seq_('enum'.r >> /\S+/.r, '{'.r >> ENUM_CHOICE.star << '}'.r).map {|(name, choices)| Enum.new name, choices }

    # Column Definition
    # =================
    # * name of the column is listed as column_name
    # * type of the data in the column listed as column_type
    # * supports all data types, as long as it is a single word (remove all spaces in the data type). Example, JSON, JSONB, decimal(1,2), etc.
    # * column_name can be stated in just plain text, or wrapped in a double quote as "column name"
    #
    # Column Settings
    # ---------------
    # Each column can take have optional settings, defined in square brackets like:
    #
    #     Table buildings {
    #         ...
    #         address varchar(255) [unique, not null, note: 'to include unit number']
    #         id integer [ pk, unique, default: 123, note: 'Number' ]
    #     }

    QUOTED_COLUMN_NAME = '"'.r >> /[^"]+/.r << '"'.r
    UNQUOTED_COLUMN_NAME = /\S+/.r
    COLUMN_TYPE = /\S+/.r
    COLUMN = seq_(
      QUOTED_COLUMN_NAME | UNQUOTED_COLUMN_NAME,
      COLUMN_TYPE,
      SETTINGS.maybe
    ) {|(name, type, settings)| Column.new name, type, unwrap(settings) }

    # Table Definition
    #
    #     Table table_name {
    #       column_name column_type [column_settings]
    #     }
    #
    # * title of database table is listed as table_name
    # * list is wrapped in curly brackets {}, for indexes, constraints and table definitions.
    # * string value is be wrapped in a single quote as 'string'

    TABLE_NAME = seq_ /\S+/.r, ('as'.r >> /\S+/.r).maybe(&method(:unwrap))
    TABLE = seq_('Table'.r >> TABLE_NAME, (long_or_short (/\s*/.r >> (INDEXES | NOTE | COLUMN) << /\s*/.r).star)) do |((name, aliaz), objects)|
      Table.new name, aliaz,
        objects.select {|o| o.is_a? String },
        objects.select {|o| o.is_a? Column },
        objects.select {|o| (o.is_a? Array) && (o.all? {|e| e.is_a? Index })}.flatten
    end

    # TableGroup
    # ==========
    #
    # TableGroup allows users to group the related or associated tables together.
    #
    #     TableGroup tablegroup_name { // tablegroup is case-insensitive.
    #         table1
    #         table2
    #         table3
    #     }
    TABLE_GROUP = seq_('TableGroup'.r >> /\S+/.r, '{'.r >> /\S+/.r.star << '}'.r) do |(name, tables)|
      TableGroup.new name, tables
    end

    # Project Definition
    # ==================
    # You can give overall description of the project.
    #
    #     Project project_name {
    #       database_type: 'PostgreSQL'
    #       Note: 'Description of the project'
    #     }

    PROJECT_DEFINITION = block 'Project', /\S+/.r, (NOTE | SETTING).star do |(name, objects)|
      ProjectDef.new name,
        objects.select {|o| o.is_a? String },
        objects.select {|o| o.is_a? Hash }.reduce({}, &:update)
    end
    PROJECT = space_surrounded(PROJECT_DEFINITION | TABLE | TABLE_GROUP | ENUM).star do |objects|
      definition = objects.find {|o| o.is_a? ProjectDef }
      Project.new definition.nil? ? nil : definition.name,
        definition.nil? ? [] : definition.notes,
        definition.nil? ? [] : definition.settings,
        objects.select {|o| o.is_a? Table },
        objects.select {|o| o.is_a? Enum },
        objects.select {|o| o.is_a? TableGroup }
    end

    def self.parse str
      PROJECT.eof.parse! str.gsub(/\/{2}.*$/, '')
    end
  end
end

if $0 == __FILE__
  p DBML::Parser::PROJECT_DEFINITION.parse! "Project geoff {\n  database_table: 'PostgreSQL'\n}"
  p DBML::Parser::NOTE.parse! "Note { \n'''  Simon is\n  very wicked'''\n}"
  p DBML::Parser::SETTINGS.parse! "[long: 'short', unique, not null, default: 123.45678]"
  p DBML::Parser::INDEX.eof.parse! '(id, `id*3`) [pk]'
  x = DBML::Parser.parse "Project geoff {\n  database_type: 'postgres'\n}\nTable banter {\n  id string [pk]// the id \n// TODO: rest of schema\nNote: 'this is a great table'\nindexes { id\n(id, `id*2`)\n}  }"
  p x.tables
  p x.name
end