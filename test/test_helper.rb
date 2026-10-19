# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'

module TestHelpers
  # A Kaishi note hash as AnkiConnect returns it, with fields set by index.
  def note(fields = {}, tags: [])
    array = Array.new(Kaishi::EXPECTED_FIELD_COUNT, '')
    fields.each { |idx, value| array[idx] = value }
    { id: 1, fields: array, tags: tags }
  end
end
