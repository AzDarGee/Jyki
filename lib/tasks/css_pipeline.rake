# lib/tasks/css_pipeline.rake
Rake::Task["tailwindcss:build"].clear if Rake::Task.task_defined?("tailwindcss:build")
Rake::Task["dartsass:build"].clear if Rake::Task.task_defined?("dartsass:build")

namespace :tailwindcss do
  desc "Compile SCSS first, then pass through Tailwind CSS"
  task :build do
    sh "bin/css-pipeline"
  end
end

Rake::Task["assets:precompile"].enhance(["tailwindcss:build"])