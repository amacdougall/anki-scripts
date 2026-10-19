# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class LogTest < Minitest::Test
  Log = Workbench::Log

  def setup
    @io = StringIO.new
    Log.io = @io
  end

  def teardown
    Log.io = nil
    Log.verbose = false
  end

  def test_info_is_timestamped
    Log.info('counting')
    assert_match(/\A\[\d\d:\d\d:\d\d\] counting\n\z/, @io.string)
  end

  def test_debug_only_when_verbose
    Log.debug('GET /')
    assert_empty @io.string
    Log.verbose = true
    Log.debug('GET /')
    assert_includes @io.string, 'GET /'
  end
end
