require "helper"
require "fluent/plugin/parser_avro.rb"

class AvroParserTest < Test::Unit::TestCase
  AVRO_REGISTRY_PORT = 8081

  setup do
    Fluent::Test.setup
  end

  SCHEMA = <<-JSON
    { "namespace": "org.fluentd.parser.avro",
      "type": "record",
      "name": "User",
      "fields" : [
        {"name": "username", "type": "string"},
        {"name": "age", "type": "int"},
        {"name": "verified", "type": ["boolean", "null"], "default": false}
    ]}
    JSON

  READERS_SCHEMA = <<-JSON
    { "namespace": "org.fluentd.parser.avro",
      "type": "record",
      "name": "User",
      "fields" : [
        {"name": "username", "type": "string"},
        {"name": "age", "type": "int"}
    ]}
    JSON

  COMPLEX_SCHEMA = <<-EOC
    {
      "type" : "record",
      "name" : "ComplexClass",
      "namespace" : "org.fluentd.parser.avro.complex.example",
      "fields" : [ {
        "name" : "time",
        "type" : "string"
      }, {
        "name" : "image",
        "type" : {
          "type" : "record",
          "name" : "image",
          "fields" : [ {
            "name" : "src",
            "type" : "string"
          }, {
            "name" : "mime_type",
            "type" : "string"
          }, {
            "name" : "height",
            "type" : "long"
          }, {
            "name" : "width",
            "type" : "long"
          }, {
            "name" : "alignment",
            "type" : "string"
          } ]
        }
      }, {
        "name" : "data",
        "type" : {
          "type" : "record",
          "name" : "data",
          "fields" : [ {
            "name" : "size",
            "type" : "long"
          }, {
            "name" : "hidden",
            "type" : "boolean"
          } ]
        }
      } ]
    }
  EOC

  data("use_confluent_schema" => true,
       "plain"                => false)
  def test_parse(data)
    config = data
    conf = {
      'schema_json' => SCHEMA,
      'use_confluent_schema' => config,
    }
    d = create_driver(conf)
    datum = {"username" => "foo", "age" => 42, "verified" => true}
    encoded = encode_datum(datum, SCHEMA, config)
    d.instance.parse(encoded) do |_time, record|
      assert_equal datum, record
    end

    datum = {"username" => "baz", "age" => 34}
    encoded = encode_datum(datum, SCHEMA, config)
    d.instance.parse(encoded) do |_time, record|
      assert_equal datum.merge("verified" => nil), record
    end
  end

  data("use_confluent_schema" => true,
       "plain"                => false)
  def test_parse_with_avro_schema(data)
    config = data
    conf = {
      'schema_file' => File.join(__dir__, "..", "data", "user.avsc"),
      'use_confluent_schema' => config,
    }
    d = create_driver(conf)
    datum = {"username" => "foo", "age" => 42, "verified" => true}
    encoded = encode_datum(datum, SCHEMA, config)
    d.instance.parse(encoded) do |_time, record|
      assert_equal datum, record
    end

    datum = {"username" => "baz", "age" => 34}
    encoded = encode_datum(datum, SCHEMA, config)
    d.instance.parse(encoded) do |_time, record|
      assert_equal datum.merge("verified" => nil), record
    end
  end

  data("use_confluent_schema" => true,
       "plain"                => false)
  def test_parse_with_readers_and_writers_schema(data)
    config = data
    conf = {
      'writers_schema_json' => SCHEMA,
      'readers_schema_json' => READERS_SCHEMA,
      'use_confluent_schema' => config,
    }
    d = create_driver(conf)
    datum = {"username" => "foo", "age" => 42, "verified" => true}
    encoded = encode_datum(datum, SCHEMA, config)
    d.instance.parse(encoded) do |_time, record|
      datum.delete("verified")
      assert_equal datum, record
    end
  end

  data("use_confluent_schema" => true,
       "plain"                => false)
  def test_parse_with_readers_and_writers_schema_files(data)
    config = data
    conf = {
      'writers_schema_file' => File.join(__dir__, "..", "data", "writer_user.avsc"),
      'readers_schema_file' => File.join(__dir__, "..", "data", "reader_user.avsc"),
      'use_confluent_schema' => config,
    }
    d = create_driver(conf)
    datum = {"username" => "foo", "age" => 42, "verified" => true}
    encoded = encode_datum(datum, SCHEMA, config)
    d.instance.parse(encoded) do |_time, record|
      datum.delete("verified")
      assert_equal datum, record
    end
  end

  data("use_confluent_schema" => true,
       "plain"                => false)
  def test_parse_with_complex_schema(data)
    config = data
    conf = {
      'schema_json' => COMPLEX_SCHEMA,
      'time_key' => 'time',
      'use_confluent_schema' => config,
    }
    d = create_driver(conf)
    time_str = "2020-09-25 15:08:09.082113 +0900"
    datum = {
      "time" => time_str,
      "image" => {
        "src" => "images/avroexam.png",
        "mime_type"=> "image/png",
        "height" => 320,
        "width" => 280,
        "alignment" => "center"
      },
      "data" => {
        "size" => 36,
        "hidden" => false
      }
    }

    encoded = encode_datum(datum, COMPLEX_SCHEMA, config)
    d.instance.parse(encoded) do |time, record|
      assert_equal Time.parse(time_str).to_r, time.to_r
      datum.delete("time")
      assert_equal datum, record
    end
  end

  class SchemaURLTest < self
    teardown do
      @dummy_server_thread.kill
      @dummy_server_thread.join
    end

    setup do
      @got = []
      @dummy_server_thread = Thread.new do
      server = WEBrick::HTTPServer.new({:BindAddress => '127.0.0.1', :Port => AVRO_REGISTRY_PORT})
      begin
        server.mount_proc('/') do |req,res|
          res.status = 200
          res.body = 'running'
        end
        server.mount_proc("/schemas/ids") do |req, res|
          req.path =~ /^\/schemas\/ids\/([^\/]*)$/
          version = $1
          @got.push({
            version: version,
          })
          if version == "1"
            res.body = File.read(File.join(__dir__, "..", "data", "schema-persions-value-1.avsc"))
          elsif version == "21"
            res.body = File.read(File.join(__dir__, "..", "data", "schema-persions-value-21.avsc"))
          elsif version == "41"
            res.body = File.read(File.join(__dir__, "..", "data", "schema-persions-value-41.avsc"))
          elsif version == "42"
            res.body = File.read(File.join(__dir__, "..", "data", "schema-persions-value-42.avsc"))
          end
        end
        server.mount_proc("/subjects") do |req, res|
          req.path =~ /^\/subjects\/([^\/]*)\/([^\/]*)\/(.*)$/
          avro_registered_name = $1
          version = $3
          @got.push({
            registered_name: avro_registered_name,
            version: version,
          })
          res.status = 200
          if version == ""
            res.body = '[1,2,3,4]'
          elsif version == "1"
            res.body = File.read(File.join(__dir__, "..", "data", "persons-avro-value.avsc"))
          elsif version == "2"
            res.body = File.read(File.join(__dir__, "..", "data", "persons-avro-value2.avsc"))
          elsif version == "3"
            res.body = File.read(File.join(__dir__, "..", "data", "persons-avro-value3.avsc"))
          elsif version == "4"
            res.body = File.read(File.join(__dir__, "..", "data", "persons-avro-value4.avsc"))
          elsif version == "latest"
            res.body = File.read(File.join(__dir__, "..", "data", "persons-avro-value4.avsc"))
          end
        end
        server.start
      ensure
        server.shutdown
      end
    end

    # to wait completion of dummy server.start()
    require 'thread'
    condv = ConditionVariable.new
    _watcher = Thread.new {
      connected = false
      while not connected
        begin
          Net::HTTP.start('localhost', AVRO_REGISTRY_PORT){|http|
            http.get("/", {}).body
          }
          connected = true
        rescue Errno::ECONNREFUSED
          sleep 0.1
        rescue StandardError => e
          p e
          sleep 0.1
        end
      end
      condv.signal
    }
    mutex = Mutex.new
    mutex.synchronize {
      condv.wait(mutex)
    }
    end

    REMOTE_SCHEMA = <<-EOC
      {
        "type": "record",
        "name": "Person",
        "namespace": "com.ippontech.kafkatutorials",
        "fields": [
          {
            "name": "firstName",
            "type": "string"
          },
          {
            "name": "lastName",
            "type": "string"
          },
          {
            "name": "birthDate",
            "type": "long"
          }
        ]
      }
    EOC
    REMOTE_SCHEMA2 = <<-EOC
      {
        "type": "record",
        "name": "Person",
        "namespace": "com.ippontech.kafkatutorials",
        "fields": [
          {
            "name": "firstName",
            "type": "string"
          },
          {
            "name": "lastName",
            "type": "string"
          },
          {
            "name": "birthDate",
            "type": "long"
          },
          {
            "name": "verified",
            "type": [
              "boolean",
              "null"
            ],
            "default": false
          }
        ]
      }
    EOC

    def test_dummy_server
      conf = {
        'schema_url' => "http://localhost:8081/subjects/persons-avro-value/versions/1",
        'schema_url_key' => 'schema'
      }
      d = create_driver(conf)
      d.instance.schema_url =~ /^http:\/\/([.:a-z0-9]+)\//
      server = $1
      host = server.split(':')[0]
      port = server.split(':')[1].to_i
      client = Net::HTTP.start(host, port)

      assert_equal '200', client.request_get('/').code

      assert_equal '200', client.request_get('/subjects/persons-avro-value/versions/1').code
      # The first GET request is in #configure.
      assert_equal 2, @got.size
      assert_equal 'persons-avro-value', @got[1][:registered_name]
      assert_equal '1', @got[1][:version]

      assert_equal '200', client.request_get('/subjects/persons-avro-value/versions/').code
      assert_equal 3, @got.size
      assert_equal 'persons-avro-value', @got[2][:registered_name]
      assert_equal '', @got[2][:version]

      assert_equal '200', client.request_get('/subjects/persons-avro-value/versions/3').code
      assert_equal 4, @got.size
      assert_equal 'persons-avro-value', @got[3][:registered_name]
      assert_equal '3', @got[3][:version]

      assert_equal '200', client.request_get('/schemas/ids/1').code
      assert_equal 5, @got.size
      assert_nil @got[4][:registered_name]
      assert_equal '1', @got[4][:version]

      assert_equal '200', client.request_get('/schemas/ids/21').code
      assert_equal 6, @got.size
      assert_nil @got[5][:registered_name]
      assert_equal '21', @got[5][:version]

      assert_equal '200', client.request_get('/schemas/ids/41').code
      assert_equal 7, @got.size
      assert_nil @got[6][:registered_name]
      assert_equal '41', @got[6][:version]

      assert_equal '200', client.request_get('/schemas/ids/42').code
      assert_equal 8, @got.size
      assert_nil @got[7][:registered_name]
      assert_equal '42', @got[7][:version]
    end

    data("use_confluent_schema" => true,
         "plain"                => false)
    def test_schema_url(data)
      config = data
      conf = {
        'schema_url' => "http://localhost:8081/subjects/persons-avro-value/versions/1",
        'schema_url_key' => 'schema',
        'use_confluent_schema' => config,
      }
      d = create_driver(conf)
      datum = {"firstName" => "Aleen","lastName" => "Terry","birthDate" => 159202477258}
      encoded = encode_datum(datum, REMOTE_SCHEMA, config)
      d.instance.parse(encoded) do |_time, record|
        assert_equal datum, record
      end
    end

    data("use_confluent_schema" => true,
         "plain"                => false)
    def test_schema_url_with_version2(data)
      config = data
      conf = {
        'schema_url' => "http://localhost:8081/subjects/persons-avro-value/versions/2",
        'schema_url_key' => 'schema',
        'use_confluent_schema' => config,
      }
      d = create_driver(conf)
      datum = {"firstName" => "Aleen","lastName" => "Terry","birthDate" => 159202477258}
      encoded = encode_datum(datum, REMOTE_SCHEMA2, config)
      d.instance.parse(encoded) do |_time, record|
        assert_equal datum.merge("verified" => false), record
      end
    end

    def test_confluent_registry_with_schema_version
      conf = Fluent::Config::Element.new(
        '', '', {'@type' => 'avro'}, [
          Fluent::Config::Element.new('confluent_registry', '', {
                                        'url' => 'http://localhost:8081',
                                        'subject' => 'persons-avro-value',
                                        'schema_key' => 'schema',
                                        'schema_version' => '1',
                                      }, [])
        ])
      d = create_driver(conf)
      datum = {"firstName" => "Aleen","lastName" => "Terry","birthDate" => 159202477258}
      schema = Yajl.load(File.read(File.join(__dir__, "..", "data", "schema-persions-value-1.avsc")))
      encoded = encode_datum(datum, schema.fetch("schema"), true, 1)
      d.instance.parse(encoded) do |_time, record|
        assert_equal datum, record
      end
    end

    def test_confluent_registry_with_fallback
      conf = Fluent::Config::Element.new(
        '', '', {'@type' => 'avro'}, [
          Fluent::Config::Element.new('confluent_registry', '', {
                                        'url' => 'http://localhost:8081',
                                        'subject' => 'persons-avro-value',
                                        'schema_key' => 'schema',
                                      }, [])
        ])
      d = create_driver(conf)
      datum = {"firstName" => "Aleen","lastName" => "Terry","birthDate" => 159202477258}
      schema = Yajl.load(File.read(File.join(__dir__, "..", "data", "schema-persions-value-1.avsc")))
      encoded = encode_datum(datum, schema.fetch("schema"), true, 1)
      d.instance.parse(encoded) do |_time, record|
        assert_equal datum, record
      end
    end
  end

  class AuthenticationTest < self
    teardown do
      @dummy_server_thread.kill
      @dummy_server_thread.join
    end

    setup do
      @got = []
      @dummy_server_thread = Thread.new do
        server = WEBrick::HTTPServer.new({:BindAddress => '127.0.0.1', :Port => AVRO_REGISTRY_PORT})
        begin
          htpasswd = WEBrick::HTTPAuth::Htpasswd.new('dot.htpasswd')
          htpasswd.set_passwd(nil, "API_KEY", "API_SECRET")
          authenticator = WEBrick::HTTPAuth::BasicAuth.new(:UserDB => htpasswd, :Realm => "")
          server.mount_proc('/') do |req, res|
            authenticator.authenticate(req, res)
            schema = File.read(File.join(__dir__, "..", "data", "schema-persions-value-1.avsc"))
            res.body = schema
          end
          server.start
        ensure
          server.shutdown
        end
      end
    end

    def test_authentication_failure
      conf = Fluent::Config::Element.new(
        '', '', {'@type' => 'avro',
                 'api_key' => 'WRONG_KEY',
                 'api_secret' => 'WRONG_SECRET'
                }, [
          Fluent::Config::Element.new('confluent_registry', '', {
                                        'url' => 'http://localhost:8081',
                                        'subject' => 'persons-avro-value',
                                      }, [])
        ])
      assert_raise(Fluent::Plugin::ConfluentAvroSchemaRegistryUnauthorizedError) do
        d = create_driver(conf)
        d.instance.run
      end
    end

    def test_with_authentication
      conf = Fluent::Config::Element.new(
        '', '', {'@type' => 'avro',
                 'api_key' => 'API_KEY',
                 'api_secret' => 'API_SECRET'
                }, [
          Fluent::Config::Element.new('confluent_registry', '', {
                                        'url' => 'http://localhost:8081',
                                        'subject' => 'persons-avro-value',
                                      }, [])
        ])
      datum = {"firstName" => "Aleen","lastName" => "Terry","birthDate" => 159202477258}
      schema = Yajl.load(File.read(File.join(__dir__, "..", "data", "schema-persions-value-1.avsc")))
      encoded = encode_datum(datum, schema.fetch("schema"), true, 1)
      d = create_driver(conf)
      d.instance.parse(encoded) do |_time, record|
        assert_equal datum, record
      end
    end
  end

  private

  def encode_datum(datum, string_schema, use_confluent_schema = true, schema_id = 1)
    buffer = StringIO.new
    encoder = Avro::IO::BinaryEncoder.new(buffer)
    if use_confluent_schema
      encoder.write(Fluent::Plugin::AvroParser::MAGIC_BYTE)
      encoder.write([schema_id].pack("N"))
    end
    schema = Avro::Schema.parse(string_schema)
    writer = Avro::IO::DatumWriter.new(schema)
    writer.write(datum, encoder)
    buffer.rewind
    buffer.read
  end

  def create_driver(conf)
    Fluent::Test::Driver::Parser.new(Fluent::Plugin::AvroParser).configure(conf)
  end
end
