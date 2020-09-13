# DBML

Ruby library for [Database Markup Language (DBML)](https://www.dbml.org/).

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'dbml'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install dbml

## Usage

```ruby
require 'dbml'
project = DBML::Parser.parse """
  Table users {
    id int64 [pk, unique]
    name varchar [unique]
    Note: 'add some more things in here!'
  }"""
puts project.tables.first.name
# => "users"
```

## Development

After checking out the repo, run `bundle install` to install dependencies. Then, run `rake test` to run the tests.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/simonwo/dbml-ruby.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
