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

    #def pid
    #  to_s.split(':').second
    #end

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

    def all_workers_in_pid_working
      workers_in_pid.select { |w| (hash = w.processing) && !hash.empty? }
    end



    def status
      job['status']
    end



    def restart
      queues = self.queues_in_pid.join('#')
      quit
      self.class.start(self.ip, queues)
    end

  end




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
