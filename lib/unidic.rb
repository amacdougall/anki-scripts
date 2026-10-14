# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
require_relative 'progress_reporter'

# The UniDic dictionary MeCab uses for readings, installed on first use into
# data/unidic-lite/ (~250 MB, gitignored).
#
# UniDic replaced the vendored IPADIC (support/mecab/sys.dic), which reads
# number+counter words piecewise (一人 as いち+にん, 何色 as なん+しょく) and
# picks poor defaults for common words (後 as のち). UniDic reads 一人 ひとり,
# 二人 ふたり, 後 あと, 何色 なにいろ, and knows words like 飛び退る.
#
# Source: the unidic-lite Python package (UniDic 2.1.2, compiled for MeCab),
# pinned by version and checksum. Its dicrc sets `output-format-type = unidic`,
# which would override MecabController's --node-format, so install comments it
# out.
module UniDic
  PACKAGE_VERSION = '1.0.8'
  URL    = "https://files.pythonhosted.org/packages/source/u/unidic-lite/unidic-lite-#{PACKAGE_VERSION}.tar.gz"
  SHA256 = 'db9d4572d9fdd4d00a97949d4b0741ec480ee05a7e7e2e32f547500dae27b245'

  DATA_DIR = File.expand_path('../data', __dir__)
  DIR      = File.join(DATA_DIR, 'unidic-lite')

  # Feature index of the orthographic kana reading (e.g. トウキョウ for 東京;
  # f[9] "pron" would give トーキョー). See the feature list in DIR/dicrc.
  KANA_FEATURE = 17

  class Error < StandardError; end

  module_function

  def installed?
    File.exist?(File.join(DIR, 'sys.dic'))
  end

  def ensure_installed!
    return if installed?

    puts "Downloading UniDic (unidic-lite #{PACKAGE_VERSION}, ~47 MB)..."
    tgz = File.join(DATA_DIR, "unidic-lite-#{PACKAGE_VERSION}.tar.gz")
    extract_dir = File.join(DATA_DIR, 'unidic-lite-extract')
    FileUtils.mkdir_p(DATA_DIR)
    begin
      _out, err, status = Open3.capture3('curl', '-fsSL', '-o', tgz, URL)
      raise Error, "Download failed: #{err.strip}" unless status.success?

      actual = Digest::SHA256.file(tgz).hexdigest
      raise Error, "Checksum mismatch for #{File.basename(tgz)} (got #{actual})" unless actual == SHA256

      FileUtils.rm_rf(extract_dir)
      FileUtils.mkdir_p(extract_dir)
      _out, err, status = Open3.capture3('tar', '-xzf', tgz, '-C', extract_dir)
      raise Error, "Failed to extract #{tgz}: #{err}" unless status.success?

      dicdir = File.join(extract_dir, "unidic-lite-#{PACKAGE_VERSION}", 'unidic_lite', 'dicdir')
      raise Error, "dicdir not found in #{File.basename(tgz)}" unless File.exist?(File.join(dicdir, 'sys.dic'))

      dicrc = File.join(dicdir, 'dicrc')
      File.write(dicrc, File.read(dicrc).sub(/^output-format-type\s*=.*$/) { |line| "; #{line}" })

      FileUtils.rm_rf(DIR)
      FileUtils.mv(dicdir, DIR)
      ProgressReporter.success("UniDic installed in #{DIR}")
    ensure
      FileUtils.rm_rf(extract_dir)
      FileUtils.rm_f(tgz)
    end
  end
end
