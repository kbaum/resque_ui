require 'resque_overrides'
require 'resque_scheduler_overrides'
require 'resque_ui/cap'
#require 'resque_ui/tasks'
require 'resque/job_with_status'
require 'resque_status_overrides'

module ResqueUi
  require 'resque_ui/engine' if defined?(Rails)
end
