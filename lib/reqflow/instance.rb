require 'redis'
require 'yaml'

module Reqflow
  class Instance
    attr_reader :redis, :workflow_id, :name, :actions, :payload
    attr_accessor :auto_queue

    class << self
      def perform(workflow_id, action, pid)
        load(workflow_id,pid).run!(action)
      end
      
      def root
        @root ||= begin
          Rails.root
        rescue
          Pathname.new(File.expand_path('.'))
        end
      end
      
      def root=(path)
        path = Pathname.new(path) if path.is_a?(String)
        @root = path
      end
    end
    
    def initialize(config, payload)
      if config.is_a?(String)
        config = YAML.load(File.read(self.class.root.join('config','workflows',"#{config}.yml")))
      end
      
      @redis = Redis.new redis_config
      @workflow_id = config[:workflow_id]
      @name = config[:name]
      @actions = config[:actions]
      @auto_queue = config[:auto_queue] != false
      @payload = payload
      verify_actions
      reset!
    end
    
    def redis_config
      begin
        YAML.load(File.read(self.class.root.join('config','redis.yml')))
      rescue
        {}
      end
    end

    def verify_actions
      missing = []
      @actions.each_pair do |action, definition|
        if definition[:prereqs]
          missing += definition[:prereqs] - @actions.keys
        end
      end
      if missing.length > 0
        raise UnknownAction, "Unknown prerequisites: #{missing.uniq.inspect}"
      end
    end
    
    def job_key(ext)
      [workflow_id,payload.gsub(/:/,'_'),ext].compact.join(':')
    end

    def set(action, key, value)
      if value.nil?
        redis.hdel(job_key(action),key)
      else
        redis.hset(job_key(action),key,value)
      end
    end
    
    def get(action, key)
      redis.hget(job_key(action),key)
    end
    
    def reset!(force=false)
      @actions.keys.each { |action| status!(action, 'WAITING') if (force or status(action).nil?) }
    end
    
    def purge!
      redis.del(job_key)
    end
    
    def details(action=:all)
      if action == :all
        @actions.keys.inject({}) { |h,a| h[a] = details(a); h }
      else
        redis.hgetall(job_key(action))
      end
    end
    
    def status(action=:all)
      if action == :all
        @actions.keys.inject({}) { |h,a| h[a] = status(a); h }
      else
        raise UnknownAction, "Unknown action: #{action}" unless @actions.keys.include?(action)
        get(action,'status')
      end
    end
    
    def status!(action, new_status, message=nil)
      raise UnknownAction, "Unknown action: #{action}" unless @actions.keys.include?(action)
      set(action, 'status', new_status)
      message! action, message
    end
    
    def message(action)
      get(action, 'message')
    end
    
    def message!(action, message)
      set(action, 'message', message)
    end
    
    def complete!(action, message=nil)
      status! action, 'COMPLETED', message
      queue! if @auto_queue
    end
    
    def skip!(action, message=nil)
      status! action, 'SKIPPED', message
      queue! if @auto_queue
    end

    def fail!(action, message=nil)
      status! action, 'FAILED', message
    end
    
    def run!(action)
      begin
        action_def = @actions[action]
        action_class = action_def[:class].split(/::/).inject(Module) do |mod,sym| 
          mod.const_get(sym.to_sym)
        end
        action_class.new(action_def[:config], payload).do_work
        complete! action
      rescue Reqflow::RetriableError
        status! action, 'WAITING'
      rescue Exception => e
        fail! action, "#{e.class}: #{e.message}"
      end
      status(action)
    end
    
    def queue!(action=:all)
      if action == :all
        ready.collect { |a| queue! a }
      else
        status! action, 'QUEUED'
        Resque.enqueue(self.class, workflow_id, action, payload)
        status(action)
      end
    end

    def completed?(action=:all)
      if action == :all
        @actions.keys.all? { |a| completed?(a) }
      else
        ['COMPLETED','SKIPPED'].include? status(action)
      end
    end
    
    def failed?(action=:any)
      if action == :any
        @actions.keys.any? { |a| failed?(a) }
      else
        status(action) == 'FAILED'
      end
    end
    
    def waiting?(action)
      status(action) == 'WAITING'
    end
    
    def ready(action=:all)
      if action == :all
        @actions.keys.select { |a| ready(a) }
      else
        prereqs = @actions[action][:prereqs] || []
        waiting?(action) && prereqs.all? { |req| completed?(req) }
      end
    end
  end
end
