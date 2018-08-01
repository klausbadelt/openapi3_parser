# frozen_string_literal: true

require "openapi3_parser/array_sentence"
require "openapi3_parser/context"
require "openapi3_parser/node_factory"
require "openapi3_parser/node_factory/type_checker"
require "openapi3_parser/node/map"
require "openapi3_parser/validation/validatable"
require "openapi3_parser/validators/unexpected_fields"

module Openapi3Parser
  module NodeFactory
    class Map
      attr_reader :allow_extensions, :context, :data, :default,
                  :key_input_type, :value_input_type, :value_factory,
                  :validation

      # rubocop:disable Metrics/ParameterLists
      def initialize(
        context,
        allow_extensions: false,
        default: {},
        key_input_type: String,
        value_input_type: nil,
        value_factory: nil,
        validate: nil
      )
        @context = context
        @allow_extensions = allow_extensions
        @default = default
        @key_input_type = key_input_type
        @value_input_type = value_input_type
        @value_factory = value_factory
        @validation = validate
        @data = build_data(context.input)
      end
      # rubocop:enable Metrics/ParameterLists

      def raw_input
        context.input
      end

      def resolved_input
        @resolved_input ||= build_resolved_input
      end

      def nil_input?
        context.input.nil?
      end

      def valid?
        errors.empty?
      end

      def errors
        @errors ||= ValidNodeBuilder.errors(self)
      end

      def node
        @node ||= begin
                    data = ValidNodeBuilder.data(self)
                    data.nil? ? nil : build_node(data)
                  end
      end

      def inspect
        %{#{self.class.name}(#{context.source_location.inspect})}
      end

      private

      def build_data(raw_input)
        use_default = nil_input? || !raw_input.is_a?(::Hash)
        return if use_default && default.nil?
        process_data(use_default ? default : raw_input)
      end

      def process_data(data)
        data.each_with_object({}) do |(key, value), memo|
          memo[key] = if EXTENSION_REGEX =~ key || !value_factory
                        value
                      else
                        next_context = Context.next_field(context, key)
                        initialize_value_factory(next_context)
                      end
        end
      end

      def initialize_value_factory(field_context)
        if value_factory.is_a?(Class)
          value_factory.new(field_context)
        else
          value_factory.call(field_context)
        end
      end

      def build_node(data)
        Node::Map.new(data, context) if data
      end

      def build_resolved_input
        return unless data

        data.each_with_object({}) do |(key, value), memo|
          memo[key] = if value.respond_to?(:resolved_input)
                        value.resolved_input
                      else
                        value
                      end
        end
      end

      class ValidNodeBuilder
        def self.errors(factory)
          new(factory).errors
        end

        def self.data(factory)
          new(factory).data
        end

        def initialize(factory)
          @factory = factory
          @validatable = Validation::Validatable.new(factory)
        end

        def errors
          return validatable.collection if factory.nil_input?
          TypeChecker.validate_type(validatable, type: ::Hash)
          return validatable.collection if validatable.errors.any?
          collate_errors
          validatable.collection
        end

        def data
          return default_value if factory.nil_input?

          TypeChecker.raise_on_invalid_type(factory.context, type: ::Hash)
          check_keys(raise_on_invalid: true)
          check_values(raise_on_invalid: true)
          validate(raise_on_invalid: true)

          factory.data.each_with_object({}) do |(key, value), memo|
            memo[key] = value.respond_to?(:node) ? value.node : value
          end
        end

        private_class_method :new

        private

        attr_reader :factory, :validatable

        def collate_errors
          check_keys(raise_on_invalid: false)
          check_values(raise_on_invalid: false)
          validate(raise_on_invalid: false)

          factory.data.each_value do |value|
            validatable.add_errors(value.errors) if value.respond_to?(:errors)
          end
        end

        def default_value
          if factory.nil_input? && factory.default.nil?
            nil
          else
            factory.data
          end
        end

        def check_keys(raise_on_invalid: false)
          return unless factory.key_input_type

          if raise_on_invalid
            TypeChecker.raise_on_invalid_keys(factory.context,
                                              type: factory.key_input_type)
          else
            TypeChecker.validate_keys(validatable,
                                      type: factory.key_input_type,
                                      context: factory.context)
          end
        end

        def check_values(raise_on_invalid: false)
          return unless factory.value_input_type

          factory.context.input.keys.each do |key|
            check_field_type(
              Context.next_field(factory.context, key), raise_on_invalid
            )
          end
        end

        def check_field_type(context, raise_on_invalid)
          if raise_on_invalid
            TypeChecker.raise_on_invalid_type(context,
                                              type: factory.value_input_type)
          else
            TypeChecker.validate_type(validatable,
                                      type: factory.value_input_type,
                                      context: context)
          end
        end

        def validate(raise_on_invalid: false)
          run_validation

          return if !raise_on_invalid || validatable.errors.empty?

          first_error = validatable.errors.first
          raise Openapi3Parser::Error::InvalidData,
                "Invalid data for #{first_error.context.location_summary}. "\
                "#{first_error.message}"
        end

        def run_validation
          if factory.validation.is_a?(Symbol)
            factory.send(factory.validation, validatable)
          else
            factory.validation&.call(validatable)
          end
        end
      end
    end
  end
end
