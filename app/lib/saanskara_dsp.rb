# frozen_string_literal: true

require "fiddle"
require "fiddle/import"
require "rbconfig"

module SaanskaraDsp
  extend Fiddle::Importer

  EXT_DIR  = Rails.root.join("ext", "saanskara_dsp")
  LIB_EXT  = RbConfig::CONFIG["SOEXT"] || RbConfig::CONFIG["DLEXT"]
  LIB_PATH = EXT_DIR.join("libfast_math.#{LIB_EXT}")
  SRC_PATH = EXT_DIR.join("fast_math.c")

  # Auto-compile in development/test if missing or if C source was modified!
  if !LIB_PATH.exist? || (Rails.env.local? && SRC_PATH.mtime > LIB_PATH.mtime)
    Rails.logger&.info("⚡ [SaanskaraDsp] Compiling native C library (#{LIB_PATH.basename})...")
    system("make", "-C", EXT_DIR.to_s, exception: true)
  end

  dlload LIB_PATH.to_s

  # C Function Signatures
  extern "double apply_golden_ratio(double, unsigned int)"
end