require 'socket'

module Resque

  def self.throttle(queue, limit = 10000, sleep_for = 60)
    loop do
      break if Resque.size(queue.to_s) < limit
      sleep sleep_for
    end
  end

  class Worker

    def local_ip
      orig, Socket.do_not_reverse_lookup = Socket.do_not_reverse_lookup, true # turn off reverse DNS resolution temporarily

      UDPSocket.open do |s|
        s.connect '64.233.187.99', 1
        s.addr.last
      end
    ensure
      Socket.do_not_reverse_lookup = orig
    end

    # The string representation is the same as the id for this worker
    # instance. Can be used with `Worker.find`.
    #def to_s
    #  @to_s || "#{hostname}(#{local_ip}):#{Process.pid}:#{Thread.current.object_id}:#{Thread.current[:queues]}"
    #end

    alias_method :id, :to_s

    def pid
      to_s.split(':').second
    end

    def thread
      to_s.split(':').third
    end

    def queue
      to_s.split(':').last
    end

    def workers_in_pid
      Array(redis.smembers(:workers)).select { |id| id =~ /\(#{ip}\):#{pid}/ }.map { |id| Resque::Worker.find(id) }.compact
    end

    def ip
      to_s.split(':').first[/\b(?:\d{1,3}\.){3}\d{1,3}\b/]
    end

    def queues_in_pid
      workers_in_pid.collect { |w| w.queue }
    end

    # Runs all the methods needed when a worker begins its lifecycle.
    #OVERRIDE for multithreaded workers
    def startup
      enable_gc_optimizations
      if Thread.current == Thread.main
        register_signal_handlers
        prune_dead_workers
      end
      run_hook :before_first_fork
      register_worker

      # Fix buffering so we can `rake resque:work > resque.log` and
      # get output from the child in there.
      $stdout.sync = true
    end

    # Schedule this worker for shutdown. Will finish processing the
    # current job.
    #OVERRIDE for multithreaded workers
    def shutdown
      log 'Exiting...'
      Thread.list.each { |t| t[:shutdown] = true }
      @shutdown = true
    end

    # Looks for any workers which should be running on this server
    # and, if they're not, removes them from Redis.
    #
    # This is a form of garbage collection. If a server is killed by a
    # hard shutdown, power failure, or something else beyond our
    # control, the Resque workers will not die gracefully and therefor
    # will leave stale state information in Redis.
    #
    # By checking the current Redis state against the actual
    # environment, we can determine if Redis is old and clean it up a bit.
    def prune_dead_workers
      Worker.all.each do |worker|
        host, pid, thread, queues = worker.id.split(':')
        next unless host.include?(hostname)
        next if worker_pids.include?(pid)
        log! "Pruning dead worker: #{worker}"
        worker.unregister_worker
      end
    end

    def all_workers_in_pid_working
      workers_in_pid.select { |w| (hash = w.processing) && !hash.empty? }
    end

    # Jruby won't allow you to trap the QUIT signal, so we're changing the INT signal to replace it for Jruby.
    def register_signal_handlers
      trap('TERM') { shutdown! }
      trap('INT') { shutdown }

      begin
        s = trap('QUIT') { shutdown }
        warn "Signal QUIT not supported." unless s
        s = trap('USR1') { kill_child }
        warn "Signal USR1 not supported." unless s
        s = trap('USR2') { pause_processing }
        warn "Signal USR2 not supported." unless s
        s = trap('CONT') { unpause_processing }
        warn "Signal CONT not supported." unless s
      rescue ArgumentError
        warn "Signals QUIT, USR1, USR2, and/or CONT not supported."
      end
    end


    # logic for mappged_mget changed where it returns keys with nil values in latest redis gem.
    def self.working
      names = all
      return [] unless names.any?
      names.map! { |name| "worker:#{name}" }
      redis.mapped_mget(*names).map do |key, value|
        find key.sub("worker:", '') unless value.nil?
      end.compact
    end

    # Returns an array of string pids of all the other workers on this
    # machine. Useful when pruning dead workers on startup.
    def worker_pids
      `ps -A -o pid,command | grep [r]esque`.split("\n").map do |line|
        line.split(' ')[0]
      end
    end

    def status=(status)
      data = encode(job.merge('status' => status))
      redis.set("worker:#{self}", data)
    end

    def status
      job['status']
    end


    def quit
      if RAILS_ENV =~ /development|test/
        system("kill -INT  #{self.pid}")
      else
        system("cd #{RAILS_ROOT}; #{ResqueUi::Cap.path} #{RAILS_ENV} resque:quit_worker pid=#{self.pid} host=#{self.ip}")
      end
    end

    def restart
      queues = self.queues_in_pid.join('#')
      quit
      self.class.start(self.ip, queues)
    end

  end


  class Job
    # Attempts to perform the work represented by this job instance.
    # Calls #perform on the class given in the payload with the
    # arguments given in the payload.
    # The worker is passed in so the status can be set for the UI to display.
    def perform
      args ? payload_class.perform(*args) { |status| self.worker.status = status } : payload_class.perform { |status| self.worker.status = status }
    end

  end

  Resque::Server.tabs << 'Statuses'

  module Failure

    # Creates a new failure, which is delegated to the appropriate backend.
    #
    # Expects a hash with the following keys:
    #   :exception - The Exception object
    #   :worker    - The Worker object who is reporting the failure
    #   :queue     - The string name of the queue from which the job was pulled
    #   :payload   - The job's payload
    #   :failed_at - When the job originally failed.  Used when clearing a single failure  <<Optional>>
    def self.create(options = {})
      backend.new(*options.values_at(:exception, :worker, :queue, :payload, :failed_at)).save
    end

    # Requeues all failed jobs of a given class
    def self.requeue(failed_class)
      length = Resque.redis.llen(:failed)
      i = 0
      length.times do
        f = Resque.list_range(:failed, i, 1)
        if failed_class.blank? || (f["payload"]["class"] == failed_class)
          Resque.redis.lrem(:failed, 0, f.to_json)
          args = f["payload"]["args"]
          Resque.enqueue(eval(f["payload"]["class"]), *args)
        else
          i += 1
        end
      end
    end

    class Base
      #When the job originally failed.  Used when clearing a single failure
      attr_accessor :failed_at

      def initialize(exception, worker, queue, payload, failed_at = nil)
        @exception = exception
        @worker    = worker
        @queue     = queue
        @payload   = payload
        @failed_at = failed_at
      end
    end

  end
end
