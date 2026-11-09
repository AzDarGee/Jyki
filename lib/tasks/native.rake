# frozen_string_literal: true

namespace :native do
  desc "Compile ultra-lean C libraries in ext/"
  task :compile do
    ext_dir = Rails.root.join("ext", "saanskara_dsp")
    puts "🔨 Compiling native C extensions in #{ext_dir}..."
    sh "make -C #{ext_dir}"
  end

  desc "Clean compiled C binaries"
  task :clean do
    ext_dir = Rails.root.join("ext", "saanskara_dsp")
    sh "make -C #{ext_dir} clean"
  end
end

# Automatically hook into `rails assets:precompile` so Kamal/Docker builds it for free!
Rake::Task["assets:precompile"].enhance(["native:compile"]) if Rake::Task.task_defined?("assets:precompile")