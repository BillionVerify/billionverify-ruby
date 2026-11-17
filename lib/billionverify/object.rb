# frozen_string_literal: true

module BillionVerify
  # A read-only view over a JSON object returned by the API.
  #
  #   result = client.verify("user@example.com")
  #   result.status          # => "valid"
  #   result[:is_deliverable] # => true
  #   result.to_h            # => the original Hash with string keys
  #
  # Fields the SDK does not know about are still readable, so new API fields
  # need no SDK release. A missing field reads as +nil+.
  class Object
    def initialize(hash)
      @hash = hash
    end

    def [](key)
      wrap(@hash[key.to_s])
    end

    def key?(key)
      @hash.key?(key.to_s)
    end
    alias has_key? key?

    def to_h
      @hash
    end
    alias to_hash to_h

    def each(&block)
      @hash.each { |k, v| block.call(k, wrap(v)) }
    end

    def ==(other)
      other.is_a?(Object) && other.to_h == @hash
    end

    def inspect
      "#<BillionVerify::Object #{@hash.inspect}>"
    end

    def respond_to_missing?(name, include_private = false)
      (!name.to_s.end_with?("=") && @hash.key?(name.to_s.delete_suffix("?"))) || super
    end

    def method_missing(name, *args)
      key = name.to_s
      if key.end_with?("?")
        key = key.delete_suffix("?")
        return @hash[key] ? true : false if @hash.key?(key)
      elsif @hash.key?(key) && args.empty?
        return wrap(@hash[key])
      end
      return nil if args.empty? && !key.end_with?("=", "!")

      super
    end

    private

    def wrap(value)
      case value
      when ::Hash then Object.new(value)
      when ::Array then value.map { |item| wrap(item) }
      else value
      end
    end
  end
end
