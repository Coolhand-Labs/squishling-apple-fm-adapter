# frozen_string_literal: true

RSpec.describe Squishling::AppleFM::GenerationSchema do
  def jsonify(value)
    JSON.parse(JSON.generate(value))
  end

  def convert(schema, **options)
    described_class.call(jsonify(schema), **options)
  end

  def object(properties, **extra)
    { type: "object", properties:, required: properties.keys.map(&:to_s), additionalProperties: false, **extra }
  end

  it "titles the root object, orders its properties, and keeps additionalProperties false" do
    converted = convert(object({ a: { type: "string" }, b: { type: "integer" } }), name: "Review")

    expect(converted).to include("title" => "Review", "x-order" => %w[a b], "required" => %w[a b],
      "additionalProperties" => false)
  end

  it "titles a nullable field's anyOf node but leaves its branches bare" do
    converted = convert(object({ note: { anyOf: [{ type: "string" }, { type: "null" }] } }))

    expect(converted["properties"]["note"]).to eq("title" => "note",
      "anyOf" => [{ "type" => "string" }, { "type" => "null" }])
  end

  it "decorates nested objects, objects inside arrays, and objects inside a nullable" do
    inner = object({ city: { type: "string" } })
    converted = convert(object({ address: inner, stops: { type: "array", items: inner },
                                 maybe: { anyOf: [inner, { type: "null" }] } }))

    nested = converted["properties"]
    expect(nested["address"]).to include("title" => "address", "x-order" => ["city"])
    expect(nested["stops"]["items"]).to include("title" => "stopsItem", "x-order" => ["city"])
    expect(nested["maybe"]["anyOf"].first).to include("title" => "maybe", "x-order" => ["city"])
  end

  it "keeps what can guide the model: enum, numeric ranges, array sizes, descriptions" do
    properties = { kind: { type: "string", enum: %w[a b], description: "which" },
                   n: { type: "integer", minimum: 1, maximum: 5 },
                   list: { type: "array", items: { type: "number" }, minItems: 1, maxItems: 3 } }

    expect(convert(object(properties))["properties"]).to eq(jsonify(properties))
  end

  it "drops the keywords it can't be guided by (local validation still enforces them)" do
    properties = { code: { type: "string", pattern: "^a", minLength: 1, maxLength: 9, format: "email", default: "x",
                           const: "x" },
                   flag: { type: "boolean", title: "ignored" } }

    converted = convert(object(properties).merge(:$schema => "https://json-schema.org/draft/2020-12/schema"))

    expect(converted["properties"]["code"]).to eq("type" => "string")
    expect(converted["properties"]["flag"]).to eq("type" => "boolean")
    expect(converted).not_to have_key("$schema")
  end

  it "doesn't mistake a property named like a keyword for the keyword" do
    converted = convert(object({ pattern: { type: "string" }, format: { type: "string" }, enum: { type: "string" } }))

    expect(converted["properties"].keys).to eq(%w[pattern format enum])
  end

  it "rewrites a nullable type array as the anyOf form, keeping the description on the union" do
    converted = convert(object({ note: { type: %w[string null], description: "d" },
                                 where: { type: %w[object null], properties: { city: { type: "string" } },
                                          required: ["city"], additionalProperties: false } }))

    properties = converted["properties"]
    expect(properties["note"]).to eq("title" => "note", "description" => "d",
      "anyOf" => [{ "type" => "string" }, { "type" => "null" }])
    expect(properties["where"]["anyOf"].first).to include("type" => "object", "title" => "where", "x-order" => ["city"])
    expect(properties["where"]["anyOf"].last).to eq("type" => "null")
  end

  it "keeps null out of the enum of a nullable type array's non-null branch" do
    converted = convert(object({ kind: { type: %w[string null], enum: ["a", "b", nil] } }))

    expect(converted["properties"]["kind"]["anyOf"])
      .to eq([{ "type" => "string", "enum" => %w[a b] }, { "type" => "null" }])
  end

  it "inlines local $ref definitions" do
    schema = object({ home: { :$ref => "#/$defs/place" }, work: { :$ref => "#/$defs/place" } })
      .merge(:$defs => { place: object({ city: { type: "string" } }) })

    converted = convert(schema)

    expect(converted["properties"]["home"]).to include("type" => "object", "x-order" => ["city"], "title" => "home")
    expect(converted["properties"]["work"]).to include("type" => "object", "x-order" => ["city"], "title" => "work")
    expect(converted).not_to have_key("$defs")
  end

  it "raises ConfigurationError for a schema that refers to itself" do
    schema = object({ child: { :$ref => "#" } })

    expect { convert(schema) }.to raise_error(Squishling::ConfigurationError, /refers to itself/)
  end

  it "raises ConfigurationError for a reference it can't resolve" do
    expect { convert(object({ a: { :$ref => "#/$defs/missing" } })) }
      .to raise_error(Squishling::ConfigurationError, %r{can't resolve the schema reference "#/\$defs/missing"})
  end

  it "does not change the schema it is given" do
    schema = jsonify(object({ note: { anyOf: [{ type: "string" }, { type: "null" }] } }))
    before = Marshal.load(Marshal.dump(schema))

    described_class.call(schema)

    expect(schema).to eq(before)
  end

  it "handles the strict schema Squishling sends: every key required, optional ones as anyOf with null" do
    strict = { "$schema" => "https://json-schema.org/draft/2020-12/schema", "title" => "Schema", "type" => "object",
               "properties" => { "name" => { "type" => "string" },
                                 "zip" => { "anyOf" => [{ "type" => "string" }, { "type" => "null" }] },
                                 "tags" => { "type" => "array", "items" => { "type" => "string" } } },
               "required" => %w[name zip tags], "additionalProperties" => false }

    converted = described_class.call(strict)

    expect(converted["x-order"]).to eq(%w[name zip tags])
    expect(converted["properties"]["zip"]["anyOf"]).to eq([{ "type" => "string" }, { "type" => "null" }])
  end
end
