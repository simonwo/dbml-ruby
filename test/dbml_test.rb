require_relative '../lib/dbml'
require 'test_helper'

PARSERS = DBML::Parser::constants
PARSER_RB = File.read File.join(File.dirname(__FILE__), '../lib/dbml.rb')
TEST_CASE_REGEX = /# (#{PARSERS.join('|')}) ([^:]+): ([^=]+) => (.*)$/
TEST_DOC_REGEX  = /^\s*#     (.*)$/

describe 'Parser' do
  PARSER_RB.scan(TEST_CASE_REGEX).each do |(parser, desc, input, expected)|
    describe parser do
      it desc do
        assert_equal eval(expected), DBML::Parser.const_get(parser).eof.parse!(eval(input))
      end
    end
  end

  describe 'parse' do
    it 'parses all of the inline code as a DBML document' do
      dbml = PARSER_RB.scan(TEST_DOC_REGEX).join("\n")
      proj = DBML::Parser.parse dbml
      assert_kind_of DBML::Project, proj
      assert_equal DBML::Project.new("project_name",
        ["Description of the project"],
        {:"database_type"=>"PostgreSQL"},
        [ # tables
          DBML::Table.new("bookings", nil, [], [
            DBML::Column.new("id", "integer", {}),
            DBML::Column.new("country", "varchar", {}),
            DBML::Column.new("booking_date", "date", {}),
            DBML::Column.new("created_at", "timestamp", {})
          ], [
            DBML::Index.new(["id", "country"], {:"pk" => nil}),
            DBML::Index.new(["created_at"], {:"note" => 'Date'}),
            DBML::Index.new(["booking_date"], {}),
            DBML::Index.new(["country", "booking_date"], {:"unique" => nil}),
            DBML::Index.new(["booking_date"], {:"type" => :"hash"}),
            DBML::Index.new([DBML::Expression.new("id*2")], {}),
            DBML::Index.new([DBML::Expression.new("id*3"), DBML::Expression.new("getdate()")], {}),
            DBML::Index.new([DBML::Expression.new("id*3"), "id"], {})
          ]),
          DBML::Table.new("buildings", nil, [], [
            DBML::Column.new("address", "varchar(255)", {:"unique"=>nil, :"not null"=>nil, :"note"=>"to include unit number"}),
            DBML::Column.new("id", "integer", {:"pk"=>nil, :"unique"=>nil, :"default"=>123.0, :"note"=>"Number"})
          ], []),
          DBML::Table.new("table_name", nil, [], [
            DBML::Column.new("column_name", "column_type", {:"column_settings"=>nil})
          ], []),
          DBML::Table.new("posts", nil, [], [
            DBML::Column.new("id", "integer", {:"primary key" => nil}),
            DBML::Column.new("user_id", "integer", {:ref => [
              DBML::Relationship.new(nil, nil, [], '>', 'users', ['id'], {})
            ]})
          ], []),
          DBML::Table.new("users", nil, [], [
            DBML::Column.new("id", "integer", {:ref => [
              DBML::Relationship.new(nil, nil, [], '<', 'posts', ['user_id'], {}),
              DBML::Relationship.new(nil, nil, [], '<', 'reviews', ['user_id'], {})
            ]})
          ], []),
          DBML::Table.new("posts", nil, [], [
            DBML::Column.new("id", "integer", {}),
            DBML::Column.new("user_id", "integer", {:ref => [
              DBML::Relationship.new(nil, nil, [], '>', 'users', ['id'], {})
            ]})
          ], []),
        ], [ # relationships
          DBML::Relationship.new(nil, 'merchant_periods', ['merchant_id', 'country_code'], '>', 'merchants', ['id', 'country_code'], {}),
          DBML::Relationship.new('name_optional', 'table1', ['column1'], '<', 'table2', ['column2'], {}),
          DBML::Relationship.new('name_optional', 'table1', ['column1'], '<', 'table2', ['column2'], {}),
          DBML::Relationship.new(nil, 'products', ['merchant_id'], '>', 'merchants', ['id'], {delete: :cascade, update: :'no action'})
        ], [ # enums
          DBML::Enum.new("job_status", [
            DBML::EnumChoice.new("created", {:"note"=>"Waiting to be processed"}),
            DBML::EnumChoice.new("running", {}),
            DBML::EnumChoice.new("done", {}),
            DBML::EnumChoice.new("failure", {})
          ])
        ], [ # table groups
          DBML::TableGroup.new("tablegroup_name", [
            "table1",
            "table2",
            "table3"
          ])
        ]), proj
    end
  end
end
