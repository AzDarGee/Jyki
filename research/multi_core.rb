# frozen_string_literal: true

require 'fiddle'
require 'etc'

ext = RbConfig::CONFIG['host_os'] =~ /darwin/ ? 'dylib' : 'so'
lib = Fiddle.dlopen(File.expand_path("libparallel.#{ext}", __dir__))

# Bind the C function
parallel_process = Fiddle::Function.new(
  lib['parallel_process_buffer'],
  [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_INT],
  Fiddle::TYPE_VOID
  # Note: In Ruby 3+, Fiddle releases the GVL or you can wrap it in a Ractor
  # so the main UI thread never skips a single frame!
)

num_cores = Etc.nprocessors # Automatically detect your CPU cores (e.g., 8, 12, 16)
elements  = 1_000_000
byte_size = elements * Fiddle::SIZEOF_DOUBLE

# Allocate a zero-copy raw memory buffer (~8MB for 1M doubles)
# Automatically freed when Ruby GCs `buffer_ptr`!
buffer_ptr = Fiddle::Pointer.malloc(byte_size, Fiddle::RUBY_free)

puts "Unleashing #{num_cores} CPU cores on #{elements} elements..."
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# Run across all cores in C!
parallel_process.call(buffer_ptr, elements, num_cores)

elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
puts format("Done in %.2f ms across %d cores!", elapsed, num_cores)

# Read sample values directly from the C memory buffer into Ruby
sample = buffer_ptr[0, 3 * Fiddle::SIZEOF_DOUBLE].unpack('d3')
puts "Sample output: #{sample.map { |v| v.round(2) }.join(', ')}"