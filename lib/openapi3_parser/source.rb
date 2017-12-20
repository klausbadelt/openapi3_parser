# frozen_string_literal: true

require "openapi3_parser/error"
require "openapi3_parser/source/reference"
require "openapi3_parser/source/reference_resolver"

module Openapi3Parser
  class Source
    attr_reader :source_input, :document, :parent

    def initialize(source_input, document, parent = nil)
      @source_input = source_input
      @document = document
      @parent = parent
    end

    def data
      @data ||= normalize_data(source_input.contents)
    end

    def available?
      source_input.available?
    end

    def resolve_reference(reference)
      if reference[0..1] != "#/"
        raise Error, "Only anchor references are currently supported"
      end

      parts = reference.split("/").drop(1).map do |field|
        CGI.unescape(field.gsub("+", "%20"))
      end

      result = data.dig(*parts)
      raise Error, "Could not resolve reference #{reference}" unless result

      yield(result, parts)
    end

    def register_reference(given_reference, factory, context)
      reference = Reference.new(given_reference)
      ReferenceResolver.new(
        reference, factory, context
      ).tap do |resolver|
        unless resolver.in_root_source?
          # register reference with document
        end
      end
    end

    def resolve_source(reference)
      if reference.only_fragment?
        # I found the spec wasn't fully clear on expected behaviour if a source
        # references a fragment that doesn't exist in it's current document
        # and just the root source. I'm assuming to be consistent with URI a
        # fragment only reference only references current JSON document. This
        # could be incorrect though.
        #
        # @TODO confirm this behaviour
        self
      else
        next_source_input = source_input.resolve_next(reference)
        # @TODO not needed yet
        # source = document.source_for_source_input(next_source_input)
        source = nil
        source || self.class.new(next_source_input, document, self)
      end
    end

    def data_at_pointer(json_pointer)
      return data if json_pointer.empty?
      data.dig(*json_pointer) if data.respond_to?(:dig)
    end

    def has_pointer?(json_pointer) # rubocop:disable Style/PredicateName
      !data_at_pointer(json_pointer).nil?
    end

    private

    def normalize_data(input)
      normalized = if input.respond_to?(:keys)
                     input.each_with_object({}) do |(key, value), memo|
                       memo[key.to_s.freeze] = normalize_data(value)
                     end
                   elsif input.respond_to?(:map)
                     input.map { |v| normalize_data(v) }
                   else
                     input
                   end

      normalized.freeze
    end
  end
end