# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "gcs_put"
require "minitest/autorun"
require "webmock/minitest"
require "zlib"
