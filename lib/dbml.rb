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

    # ATOM parses true:        'true' => true
    # ATOM parses false:       'false' => false
    # ATOM parses null:        'null' => nil
    # ATOM parses numbers:     '123.45678' => 123.45678
    # ATOM parses strings:     "'string'" => "string"
    # ATOM parses multilines:  "'''long\nstring'''" => "long\nstring"
    # ATOM parses expressions: '`now()`' => DBML::Expression.new('now()')
    BOOLEAN            = 'true'.r.map {|_| true } | 'false'.r.map {|_| false }
    NULL               = 'null'.r.map {|_| nil }
    NUMBER             = prim(:double)
    EXPRESSION         = seq('`'.r, /[^`]+/.r, '`'.r)[1].map {|str| Expression.new str}
    SINGLE_LING_STRING = seq("'".r, /[^']+/.r, "'".r)[1]
    MULTI_LINE_STRING  = seq("'''".r, /([^']|'[^']|''[^'])+/m.r, "'''".r)[1].map do |string|
      # MULTI_LINE_STRING ignores indentation on the first line: "'''  long\n    string'''" => "long\n  string"
      # MULTI_LINE_STRING allows apostrophes: "'''it's a string with '' bunny ears'''" => "it's a string with '' bunny ears"
      indent = string.match(/^\s*/m)[0].size
      string.lines.map do |line|
        raise "Indentation does not match" unless line =~ /\s{#{indent}}/
        line[indent..]
      end.join
    end
    STRING = SINGLE_LING_STRING | MULTI_LINE_STRING
    ATOM = BOOLEAN | NULL | NUMBER | EXPRESSION | STRING

    # Each setting item can take in 2 forms: Key: Value or keyword, similar to that of Python function parameters.
    # Settings are all defined within square brackets: [setting1: value1, setting2: value2, setting3, setting4]
    #
    # SETTINGS parses key value settings: '[default: 123]' => {'default' => 123}
    # SETTINGS parses keyword settings: '[not null]' => {'not null' => nil}
    # SETTINGS parses many settings: "[some setting: 'value', primary key]" => {'some setting' => 'value', 'primary key' => nil}
    SETTING = seq_(/[^,:\[\]\{\}\s][^,:\[\]]+/.r, (':'.r >> ATOM).maybe(&method(:unwrap))) {|(key, value)| {key => value} }
    SETTINGS = ('['.r >> comma_separated(SETTING) << ']'.r).map {|values| values.reduce({}, &:update) }

    # NOTE parses short notes: "Note: 'this is cool'" => 'this is cool'
    # NOTE parses block notes: "Note {\n'still a single line of note'\n}" => 'still a single line of note'
    # NOTE can use multilines:  "Note: '''this is\nnot reassuring'''" => "this is\nnot reassuring"
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
    #           booking_date [type: 'hash']
    #           (`id*2`)
    #           (`id*3`,`getdate()`)
    #           (`id*3`,id)
    #       }
    #     }
    #
    # There are 3 types of index definitions:
    #
    # # Index with single field (with index name): CREATE INDEX on users (created_at)
    # # Index with multiple fields (composite index): CREATE INDEX on users (created_at, country)
    # # Index with an expression: CREATE INDEX ON films ( first_name + last_name )
    # # (bonus) Composite index with expression: CREATE INDEX ON users ( country, (lower(name)) )
    #
    # INDEX parses single fields: 'id' => DBML::Index.new(['id'], {})
    # INDEX parses composite fields: '(id, country)' => DBML::Index.new(['id', 'country'], {})
    # INDEX parses expressions: '(`id*2`)' => DBML::Index.new([DBML::Expression.new('id*2')], {})
    # INDEX parses expressions: '(`id*2`,`id*3`)' => DBML::Index.new([DBML::Expression.new('id*2'), DBML::Expression.new('id*3')], {})
    # INDEX parses naked ids and settings: "test_col [type: 'hash']" => DBML::Index.new(["test_col"], {"type" => "hash"})
    # INDEX parses settings: '(country, booking_date) [unique]' => DBML::Index.new(['country', 'booking_date'], {'unique' => nil})
    # INDEXES parses empty block: 'indexes { }' => []
    # INDEXES parses single index: "indexes {\ncolumn_name\n}" => [DBML::Index.new(['column_name'], {})]
    # INDEXES parses multiple indexes: "indexes {\n(composite) [pk]\ntest_index [unique]\n}" => [DBML::Index.new(['composite'], {'pk'=>nil}), DBML::Index.new(['test_index'], {'unique'=>nil})]

    INDEX_SINGLE = /[^\(\)\,\{\}\s\[\]]+/.r
    INDEX_COMPOSITE = seq_('('.r, comma_separated(EXPRESSION | INDEX_SINGLE), ')'.r).inner.map {|v| unwrap(v) }
    INDEX = seq_(INDEX_SINGLE.map {|field| [field] } | INDEX_COMPOSITE, SETTINGS.maybe).map do |(fields, settings)|
      Index.new fields, unwrap(settings) || {}
    end
    INDEXES = block 'indexes', ''.r, INDEX do |(_, indexes)| indexes end

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
    #
    # ENUM parses empty blocks: "enum empty {\n}" => DBML::Enum.new('empty', [])
    # ENUM parses settings: "enum setting {\none [note: 'something']\n}" => DBML::Enum.new('setting', [DBML::EnumChoice.new('one', {'note' => 'something'})])
    # ENUM parses filled blocks: "enum filled {\none\ntwo}" =? DBML::Enum.new('filled', [DBML::EnumChoice.new('one', {}), DBML::EnumChoice.new('two', {})])

    ENUM_CHOICE = seq_(/[^\{\}\s]+/.r, SETTINGS.maybe).map {|(name, settings)| EnumChoice.new name, unwrap(settings) }
    ENUM = block 'enum', /\S+/.r, ENUM_CHOICE do |(name, choices)|
      Enum.new name, choices
    end

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
    #         //...
    #         address varchar(255) [unique, not null, note: 'to include unit number']
    #         id integer [ pk, unique, default: 123, note: 'Number' ]
    #     }
    #
    # COLUMN parses naked identifiers as names: 'column_name type' => DBML::Column.new('column_name', 'type', {})
    # COLUMN parses quoted identifiers as names: '"column name" type' => DBML::Column.new('column name', 'type', {})
    # COLUMN parses types: 'name string' => DBML::Column.new('name', 'string', {})
    # COLUMN parses settings: 'name string [pk]' => DBML::Column.new('name', 'string', {'pk' => nil})

    QUOTED_COLUMN_NAME = '"'.r >> /[^"]+/.r << '"'.r
    UNQUOTED_COLUMN_NAME = /[^\{\}\s]+/.r
    COLUMN_TYPE = /[^\s\{\}]+/.r
    COLUMN = seq_(
      QUOTED_COLUMN_NAME | UNQUOTED_COLUMN_NAME,
      COLUMN_TYPE,
      SETTINGS.maybe
    ) {|(name, type, settings)| Column.new name, type, unwrap(settings) || {} }

    # Table Definition
    #
    #     Table table_name {
    #       column_name column_type [column_settings]
    #     }
    #
    # * title of database table is listed as table_name
    # * list is wrapped in curly brackets {}, for indexes, constraints and table definitions.
    # * string value is be wrapped in a single quote as 'string'
    #
    # TABLE_NAME parses identifiers: 'table_name' => ['table_name', nil]
    # TABLE_NAME parses aliases: 'table_name as thingy' => ['table_name', 'thingy']
    # TABLE parses empty tables: 'Table empty {}' => DBML::Table.new('empty', nil, [], [], [])
    # TABLE parses notes: "Table with_notes {\nNote: 'this is a note'\n}" => DBML::Table.new('with_notes', nil, ['this is a note'], [], [])

    TABLE_NAME = seq_(/[^\{\}\s]+/.r, ('as'.r >> /\S+/.r).maybe {|v| unwrap(v) })
    TABLE = block 'Table', TABLE_NAME, (INDEXES | NOTE | COLUMN) do |((name, aliaz), objects)|
      Table.new name, aliaz,
        objects.select {|o| o.is_a? String },
        objects.select {|o| o.is_a? Column },
        objects.select {|o| o.is_a? Index }
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
    #
    # TABLE_GROUP parses names: 'TableGroup group1 { }' => DBML::TableGroup.new('group1', [])
    # TABLE_GROUP parses tables: "TableGroup group2 {\ntable1\ntable2\n}" => DBML::TableGroup.new('group2', ['table1', 'table2'])
    TABLE_GROUP = block 'TableGroup', /\S+/.r, /[^\{\}\s]+/.r do |(name, tables)|
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
    #
    # PROJECT_DEFINITION parses names: 'Project my_proj { }' => DBML::ProjectDef.new('my_proj', [], {})
    # PROJECT_DEFINITION parses notes: "Project my_porg { Note: 'porgs are cool!' }" => DBML::ProjectDef.new('my_porg', ['porgs are cool!'], {})
    # PROJECT_DEFINITION parses settings: "Project my_cool {\ndatabase_type: 'PostgreSQL'\n}" => DBML::ProjectDef.new('my_cool', [], {'database_type' => 'PostgreSQL'})
    PROJECT_DEFINITION = block 'Project', /\S+/.r, (NOTE | SETTING).star do |(name, objects)|
      ProjectDef.new name,
        objects.select {|o| o.is_a? String },
        objects.select {|o| o.is_a? Hash }.reduce({}, &:update)
    end

    # PROJECT can be empty: "" => DBML::Project.new(nil, [], {}, [], [], [])
    # PROJECT includes definition info: "Project p { Note: 'hello' }" => DBML::Project.new('p', ['hello'], {}, [], [], [])
    # PROJECT includes tables: "Table t { }" => DBML::Project.new(nil, [], {}, [DBML::Table.new('t', nil, [], [], [])], [], [])
    # PROJECT includes enums: "enum E { }" => DBML::Project.new(nil, [], {}, [], [DBML::Enum.new('E', [])], [])
    # PROJECT includes table groups: "TableGroup TG { }" => DBML::Project.new(nil, [], {}, [], [], [DBML::TableGroup.new('TG', [])])
    PROJECT = space_surrounded(PROJECT_DEFINITION | TABLE | TABLE_GROUP | ENUM).star do |objects|
      definition = objects.find {|o| o.is_a? ProjectDef }
      Project.new definition.nil? ? nil : definition.name,
        definition.nil? ? [] : definition.notes,
        definition.nil? ? {} : definition.settings,
        objects.select {|o| o.is_a? Table },
        objects.select {|o| o.is_a? Enum },
        objects.select {|o| o.is_a? TableGroup }
    end

    def self.parse str
      PROJECT.eof.parse! str.gsub(/\/{2}.*$/, '')
    end
  end
end
