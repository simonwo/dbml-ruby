require 'rsec'

module DBML
  Column       = Struct.new :name, :type, :settings
  Table        = Struct.new :name, :alias, :notes, :columns, :indexes
  Index        = Struct.new :fields, :settings
  Expression   = Struct.new :text
  Relationship = Struct.new :name, :left_table, :left_fields, :type, :right_table, :right_fields, :settings
  Enum         = Struct.new :name, :choices
  EnumChoice   = Struct.new :name, :settings
  TableGroup   = Struct.new :name, :tables
  Project      = Struct.new :name, :notes, :settings, :tables, :relationships, :enums, :table_groups
  ProjectDef   = Struct.new :name, :notes, :settings

  module Parser
    extend Rsec::Helpers

    def self.long_or_short p
      (':'.r >> p) | ('{'.r >> p << '}'.r)
    end

    def self.unwrap p, *_
      if p.empty? then nil else p.first end
    end

    def self.comma_separated p
      p.join(/, */.r.map {|_| nil}).star.map {|v| (v.first || []).reject(&:nil?) }
    end

    def self.space_surrounded p
      /\s*/.r >> p << /\s*/.r
    end

    def self.block type, name_parser, content_parser, &block
      seq_(type.r >> name_parser, '{'.r >> space_surrounded(content_parser).star.map {|a| a.flatten(1) } << '}'.r, &block)
    end

    RESERVED_PUNCTUATION = %q{`"':\[\]\{\}\(\)\>\<,.}
    NAKED_IDENTIFIER = /[^#{RESERVED_PUNCTUATION}\s]+/.r
    QUOTED_IDENTIFIER = '"'.r >> /[^"]+/.r << '"'.r
    IDENTIFIER = QUOTED_IDENTIFIER | NAKED_IDENTIFIER

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
    EXPRESSION         = seq('`'.r, /[^`]*/.r, '`'.r)[1].map {|str| Expression.new str}
    # KEYWORD parses phrases:   'no action' => :"no action"
    KEYWORD             = /[^#{RESERVED_PUNCTUATION}\s][^#{RESERVED_PUNCTUATION}]*/.r.map {|str| str.to_sym}
    SINGLE_LING_STRING = seq("'".r, /[^']*/.r, "'".r)[1] | seq('"'.r, /[^"]*/.r, '"'.r)[1]
    # MULTI_LINE_STRING ignores indentation on the first line: "'''  long\n    string'''" => "long\n  string"
    # MULTI_LINE_STRING allows apostrophes: "'''it's a string with '' bunny ears'''" => "it's a string with '' bunny ears"
    # MULTI_LINE_STRING allows blanks: "''''''" => ""
    MULTI_LINE_STRING  = seq("'''".r, /([^']|'[^']|''[^'])*/m.r, "'''".r)[1].map do |string|
      indent = string.match(/^\s*/m)[0].size
      string.lines.map do |line|
        raise "Indentation does not match" unless line =~ /\s{#{indent}}/
        line[indent..]
      end.join
    end
    # STRING parses blank strings: "''" => ""
    # STRING parses double quotes: '""' => ""
    STRING = MULTI_LINE_STRING | SINGLE_LING_STRING
    ATOM = BOOLEAN | NULL | NUMBER | EXPRESSION | STRING

    # Each setting item can take in 2 forms: Key: Value or keyword, similar to that of Python function parameters.
    # Settings are all defined within square brackets: [setting1: value1, setting2: value2, setting3, setting4]
    #
    # SETTINGS parses key value settings: '[default: 123]' => {default: 123}
    # SETTINGS parses keyword settings: '[not null]' => {:'not null' => nil}
    # SETTINGS parses many settings: "[some setting: 'value', primary key]" => {:'some setting' => 'value', :'primary key' => nil}
    # SETTINGS parses keyword values: "[delete: cascade]" => {delete: :cascade}
    # SETTINGS parses relationship form: '[ref: > users.id]' => {ref: [DBML::Relationship.new(nil, nil, [], '>', 'users', ['id'], {})]}
    # SETTINGS parses multiple relationships: '[ref: > a.b, ref: < c.d]' => {ref: [DBML::Relationship.new(nil, nil, [], '>', 'a', ['b'], {}), DBML::Relationship.new(nil, nil, [], '<', 'c', ['d'], {})]}
    REF_SETTING = 'ref:'.r >> seq_(lazy { RELATIONSHIP_TYPE }, lazy {RELATIONSHIP_PART}).map do |(type, part)|
      Relationship.new(nil, nil, [], type, *part, {})
    end
    SETTING = seq_(KEYWORD, (':'.r >> (ATOM | KEYWORD)).maybe(&method(:unwrap))) {|(key, value)| {key => value} }
    SETTINGS = ('['.r >> comma_separated(REF_SETTING | SETTING) << ']'.r).map do |values|
      refs, settings = values.partition {|val| val.is_a? Relationship }
      [*settings, *(if refs.any? then [{ref: refs}] else [] end)].reduce({}, &:update)
    end

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
    #           booking_date [type: hash]
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
    # INDEX parses naked ids and settings: "test_col [type: hash]" => DBML::Index.new(["test_col"], {type: :hash})
    # INDEX parses settings: '(country, booking_date) [unique]' => DBML::Index.new(['country', 'booking_date'], {unique: nil})
    # INDEXES parses empty block: 'indexes { }' => []
    # INDEXES parses single index: "indexes {\ncolumn_name\n}" => [DBML::Index.new(['column_name'], {})]
    # INDEXES parses multiple indexes: "indexes {\n(composite) [pk]\ntest_index [unique]\n}" => [DBML::Index.new(['composite'], {pk: nil}), DBML::Index.new(['test_index'], {unique: nil})]

    INDEX_SINGLE = IDENTIFIER
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
    # ENUM parses settings: "enum setting {\none [note: 'something']\n}" => DBML::Enum.new('setting', [DBML::EnumChoice.new('one', {note: 'something'})])
    # ENUM parses filled blocks: "enum filled {\none\ntwo}" => DBML::Enum.new('filled', [DBML::EnumChoice.new('one', {}), DBML::EnumChoice.new('two', {})])

    ENUM_CHOICE = seq_(IDENTIFIER, SETTINGS.maybe).map {|(name, settings)| EnumChoice.new name, unwrap(settings) || {} }
    ENUM = block 'enum', IDENTIFIER, ENUM_CHOICE do |(name, choices)|
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
    # COLUMN parses settings: 'name string [pk]' => DBML::Column.new('name', 'string', {pk: nil})

    COLUMN_NAME = IDENTIFIER
    COLUMN_TYPE = /[^\s\{\}]+/.r
    COLUMN = seq_(COLUMN_NAME, COLUMN_TYPE, SETTINGS.maybe) do |(name, type, settings)|
      Column.new name, type, unwrap(settings) || {}
    end

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

    TABLE_NAME = seq_(IDENTIFIER, ('as'.r >> IDENTIFIER).maybe {|v| unwrap(v) })
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
    TABLE_GROUP = block 'TableGroup', IDENTIFIER, IDENTIFIER do |(name, tables)|
      TableGroup.new name, tables
    end

    # Relationships & Foreign Key Definitions
    #
    # Relationships are used to define foreign key constraints between tables.
    #
    #     Table posts {
    #         id integer [primary key]
    #         user_id integer [ref: > users.id] // many-to-one
    #     }
    #
    #     // or this
    #     Table users {
    #         id integer [ref: < posts.user_id, ref: < reviews.user_id] // one to many
    #     }
    #
    #     // The space after '<' is optional
    #
    # There are 3 types of relationships: one-to-one, one-to-many, and many-to-one
    #
    #  1. <: one-to-many. E.g: users.id < posts.user_id
    #  2. >: many-to-one. E.g: posts.user_id > users.id
    #  3. -: one-to-one. E.g: users.id - user_infos.user_id
    #
    # Composite foreign keys:
    #
    #     Ref: merchant_periods.(merchant_id, country_code) > merchants.(id, country_code)
    #
    # In DBML, there are 3 syntaxes to define relationships:
    #
    #     //Long form
    #     Ref name_optional {
    #       table1.column1 < table2.column2
    #     }
    #
    #     //Short form:
    #     Ref name_optional: table1.column1 < table2.column2
    #
    #     // Inline form
    #     Table posts {
    #         id integer
    #         user_id integer [ref: > users.id]
    #     }
    #
    # Relationship settings
    #
    #     Ref: products.merchant_id > merchants.id [delete: cascade, update: no action]
    #
    # * delete / update: cascade | restrict | set null | set default | no action
    #   Define referential actions. Similar to ON DELETE/UPDATE CASCADE/... in SQL.
    #
    # Relationship settings are not supported for inline form ref.
    #
    # COMPOSITE_COLUMNS parses single column: '(column)' => ['column']
    # COMPOSITE_COLUMNS parses multiple columns: '(col1, col2)' => ['col1', 'col2']
    # RELATIONSHIP_PART parses simple form: 'table.column' => ['table', ['column']]
    # RELATIONSHIP_PART parses composite form: 'table.(a, b)' => ['table', ['a', 'b']]
    # RELATIONSHIP parses long form: "Ref name {\nleft.lcol < right.rcol\n}" => DBML::Relationship.new('name', 'left', ['lcol'], '<', 'right', ['rcol'], {})
    # RELATIONSHIP parses short form: "Ref name: left.lcol > right.rcol" => DBML::Relationship.new('name', 'left', ['lcol'], '>', 'right', ['rcol'], {})
    # RELATIONSHIP parses composite form: 'Ref: left.(a, b) - right.(c, d)' => DBML::Relationship.new(nil, 'left', ['a', 'b'], '-', 'right', ['c', 'd'], {})
    # RELATIONSHIP parses settings: "Ref: L.a > R.b [delete: cascade, update: no action]" => DBML::Relationship.new(nil, 'L', ['a'], '>', 'R', ['b'], {delete: :cascade, update: :'no action'})
    COMPOSITE_COLUMNS = '('.r >> comma_separated(COLUMN_NAME) << ')'
    RELATIONSHIP_TYPE = '>'.r | '<'.r | '-'.r
    RELATIONSHIP_PART = seq(seq(IDENTIFIER, '.'.r)[0], (COLUMN_NAME.map {|c| [c]}) | COMPOSITE_COLUMNS)
    RELATIONSHIP_BODY = seq_(RELATIONSHIP_PART, RELATIONSHIP_TYPE, RELATIONSHIP_PART, SETTINGS.maybe)
    RELATIONSHIP = seq_('Ref'.r >> NAKED_IDENTIFIER.maybe, long_or_short(RELATIONSHIP_BODY)).map do |(name, (left, type, right, settings))|
      Relationship.new unwrap(name), *left, type, *right, unwrap(settings) || {}
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
    # PROJECT_DEFINITION parses settings: "Project my_cool {\ndatabase_type: 'PostgreSQL'\n}" => DBML::ProjectDef.new('my_cool', [], {database_type: 'PostgreSQL'})
    PROJECT_DEFINITION = block 'Project', IDENTIFIER, (NOTE | SETTING).star do |(name, objects)|
      ProjectDef.new name,
        objects.select {|o| o.is_a? String },
        objects.select {|o| o.is_a? Hash }.reduce({}, &:update)
    end

    # PROJECT can be empty: "" => DBML::Project.new(nil, [], {}, [], [], [], [])
    # PROJECT includes definition info: "Project p { Note: 'hello' }" => DBML::Project.new('p', ['hello'], {}, [], [], [], [])
    # PROJECT includes tables: "Table t { }" => DBML::Project.new(nil, [], {}, [DBML::Table.new('t', nil, [], [], [])], [], [], [])
    # PROJECT includes enums: "enum E { }" => DBML::Project.new(nil, [], {}, [], [], [DBML::Enum.new('E', [])], [])
    # PROJECT includes table groups: "TableGroup TG { }" => DBML::Project.new(nil, [], {}, [], [], [], [DBML::TableGroup.new('TG', [])])
    PROJECT = space_surrounded(PROJECT_DEFINITION | RELATIONSHIP | TABLE | TABLE_GROUP | ENUM).star do |objects|
      definition = objects.find {|o| o.is_a? ProjectDef }
      Project.new definition.nil? ? nil : definition.name,
        definition.nil? ? [] : definition.notes,
        definition.nil? ? {} : definition.settings,
        objects.select {|o| o.is_a? Table },
        objects.select {|o| o.is_a? Relationship },
        objects.select {|o| o.is_a? Enum },
        objects.select {|o| o.is_a? TableGroup }
    end

    def self.parse str
      PROJECT.eof.parse! str.gsub(/\/{2}.*$/, '')
    end
  end
end
