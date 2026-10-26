# frozen_string_literal: true

module Squishling
  module AppleFM
    # Rewrites a strict output schema into the JSON Schema dialect Apple's on-device model decodes
    # (FoundationModels' GenerationSchema), for AppleFM::Adapter. It keeps only the keywords the model can be
    # guided by and adds the ones Apple's decoder insists on; Squishling's own validation still enforces the rest.
    module GenerationSchema
      # Everything else (pattern, minLength, format, const, ...) is dropped: the model fails to generate with some of
      # them, and none can be guided, so local validation decides.
      KEPT = %w[type enum description properties required items anyOf minimum maximum minItems maxItems].freeze
      SCHEMA_MAPS = %w[properties $defs definitions].freeze
      MAX_REF_DEPTH = 16
      private_constant :KEPT, :SCHEMA_MAPS, :MAX_REF_DEPTH

      module_function

      # name: the title of the root object. Raises ConfigurationError for a schema that refers to itself.
      def call(schema, name: "Response")
        decorate(prune(inline(schema, schema, 0)), name)
      end

      # $ref to a local definition becomes the definition itself; Apple's decoder has no references.
      def inline(node, root, depth)
        case node
        when Array then node.map { |item| inline(item, root, depth) }
        when Hash then inline_hash(node, root, depth)
        else node
        end
      end

      def inline_hash(node, root, depth)
        return inline_ref(node["$ref"], root, depth) if node["$ref"].is_a?(String)

        node.to_h { |key, value| [key, inline_value(key, value, root, depth)] }
      end

      def inline_ref(ref, root, depth)
        if depth > MAX_REF_DEPTH
          raise ConfigurationError,
            "squishling-apple_fm can't use a schema that refers to itself"
        end

        inline(definition(root, ref), root, depth + 1)
      end

      # Property and definition names are data, never keywords or references.
      def inline_value(key, value, root, depth)
        return inline(value, root, depth) unless SCHEMA_MAPS.include?(key) && value.is_a?(Hash)

        value.transform_values { |schema| inline(schema, root, depth) }
      end

      def definition(root, ref)
        return root if ref == "#"

        found = ref.delete_prefix("#/").split("/").reduce(root) { |node, key| node.is_a?(Hash) ? node[key] : nil }
        return found if found.is_a?(Hash)

        raise ConfigurationError, "squishling-apple_fm can't resolve the schema reference #{ref.inspect}"
      end

      # Drops every keyword outside KEPT. Property names are data and stay, so only a schema's keywords are filtered.
      def prune(node)
        return node unless node.is_a?(Hash)
        return prune(split_types(node)) if node["type"].is_a?(Array)

        node.slice(*KEPT).to_h { |key, value| [key, prune_value(key, value)] }
      end

      # type: ["string", "null"] is anyOf: [{ type: "string" }, { type: "null" }], the form Apple's decoder reads.
      def split_types(node)
        shared = node.except("type", "description")
        shared["enum"] = shared["enum"].compact if shared["enum"].is_a?(Array) && node["type"].include?("null")
        branches = node["type"].map { |type| type == "null" ? { "type" => "null" } : shared.merge("type" => type) }
        { "anyOf" => branches }.merge(node.slice("description"))
      end

      def prune_value(key, value)
        case key
        when "properties" then value.transform_values { |schema| prune(schema) }
        when "items" then prune(value)
        when "anyOf" then value.map { |schema| prune(schema) }
        else value
        end
      end

      # Apple's decoder wants a title on every object and anyOf node, the property order, and an explicit
      # additionalProperties. A title on a plain branch would make it a "named type", so branches stay bare.
      def decorate(node, name)
        return node unless node.is_a?(Hash)

        if node["anyOf"] then decorate_union(node, name)
        elsif node["type"] == "object" then decorate_object(node, name)
        elsif node["type"] == "array" then node.merge("items" => decorate(node["items"], "#{name}Item"))
        else node
        end
      end

      def decorate_union(node, name)
        node.merge("title" => name, "anyOf" => node["anyOf"].map { |branch| decorate(branch, name) })
      end

      def decorate_object(node, name)
        properties = (node["properties"] || {}).to_h { |key, schema| [key, decorate(schema, key)] }
        node.merge("title" => name, "properties" => properties, "x-order" => properties.keys,
          "required" => node["required"] || [], "additionalProperties" => false)
      end
    end
  end
end
