require 'sinatra/base'
require 'slim'
require 'sprockets'
require 'multi_json'

module Sidekiq
  class SprocketsMiddleware
    def initialize(app, options={})
      @app = app
      @root = options[:root]
      path   =  options[:path] || 'assets'
      @matcher = /^\/#{path}\/*/
      @environment = ::Sprockets::Environment.new(@root)
      @environment.append_path 'assets/javascripts'
      @environment.append_path 'assets/javascripts/vendor'
      @environment.append_path 'assets/stylesheets'
      @environment.append_path 'assets/stylesheets/vendor'
      @environment.append_path 'assets/images'
    end

    def call(env)
      # Solve the problem of people requesting /sidekiq when they need to request /sidekiq/ so
      # that relative links in templates resolve correctly.
      return [301, { 'Location' => "#{env['SCRIPT_NAME']}/", 'Content-Type' => 'text/html' }, ['redirecting']] if env['SCRIPT_NAME'] == env['REQUEST_PATH']

      return @app.call(env) unless @matcher =~ env["PATH_INFO"]
      env['PATH_INFO'].sub!(@matcher,'')
      @environment.call(env)
    end
  end

  class Web < Sinatra::Base
    dir = File.expand_path(File.dirname(__FILE__) + "/../../web")
    set :views,  "#{dir}/views"
    set :root, "#{dir}/public"
    set :slim, :pretty => true
    use SprocketsMiddleware, :root => dir

    helpers do

      def workers
        @workers ||= begin
          Sidekiq.redis do |conn|
            conn.smembers('workers').map do |w|
              msg = conn.get("worker:#{w}")
              msg ? [w, Sidekiq.load_json(msg)] : nil
            end.compact.sort { |x| x[1] ? -1 : 1 }
          end
        end
      end

      def processed
        Sidekiq.redis { |conn| conn.get('stat:processed') } || 0
      end

      def failed
        Sidekiq.redis { |conn| conn.get('stat:failed') } || 0
      end

      def retry_count
        Sidekiq.redis { |conn| conn.zcard('retry') }
      end

      def retries(count=50)
        Sidekiq.redis do |conn|
          results = conn.zrange('retry', 0, count, :withscores => true)
          results.each_slice(2).map { |msg, score| [Sidekiq.load_json(msg), Float(score)] }
        end
      end

      def queues
        @queues ||= Sidekiq.redis do |conn|
          conn.smembers('queues').map do |q|
            [q, conn.llen("queue:#{q}") || 0]
          end.sort { |x,y| x[1] <=> y[1] }
        end
      end

      def backlog
        queues.map {|name, size| size }.inject(0) {|memo, val| memo + val }
      end

      def retries_with_score(score)
        Sidekiq.redis do |conn|
          results = conn.zrangebyscore('retry', score, score)
          results.map { |msg| Sidekiq.load_json(msg) }
        end
      end

      def location
        Sidekiq.redis { |conn| conn.client.location }
      end

      def root_path
        "#{env['SCRIPT_NAME']}/"
      end

      def current_status
        return 'idle' if workers.size == 0
        return 'active'
      end

      def relative_time(time)
        %{<time datetime="#{time.getutc.iso8601}">#{time}</time>}
      end

      def display_args(args, count=100)
        args.map { |arg| a = arg.inspect; a.size > count ? "#{a[0..count]}..." : a }.join(", ")
      end
    end

    get "/" do
      slim :index
    end

    get "/queues/:name" do
      halt 404 unless params[:name]
      count = (params[:count] || 10).to_i
      @name = params[:name]
      @messages = Sidekiq.redis {|conn| conn.lrange("queue:#{@name}", 0, count) }.map { |str| Sidekiq.load_json(str) }
      slim :queue
    end

    post "/queues/:name" do
      Sidekiq.redis do |conn|
        conn.del("queue:#{params[:name]}")
        conn.srem("queues", params[:name])
      end
      redirect root_path
    end

    get "/retries/:score" do
      halt 404 unless params[:score]
      @score = params[:score].to_f
      @retries = retries_with_score(@score)
      redirect "#{root_path}retries" if @retries.empty?
      slim :retry
    end

    get '/retries' do
      @retries = retries
      slim :retries
    end

    post '/retries' do
      halt 404 unless params[:score]
      params[:score].each do |score|
        s = score.to_f
        if params['retry']
          process_score(s, :retry)
        elsif params['delete']
          process_score(s, :delete)
        end
      end
      redirect root_path
    end

    post "/retries/:score" do
      halt 404 unless params[:score]
      score = params[:score].to_f
      if params['retry']
        process_score(score, :retry)
      elsif params['delete']
        process_score(score, :delete)
      end
      redirect root_path
    end

    def process_score(score, operation)
      case operation
      when :retry
        Sidekiq.redis do |conn|
          results = conn.zrangebyscore('retry', score, score)
          conn.zremrangebyscore('retry', score, score)
          results.map do |message|
            msg = Sidekiq.load_json(message)
            conn.rpush("queue:#{msg['queue']}", message)
          end
        end
      when :delete
        Sidekiq.redis do |conn|
          conn.zremrangebyscore('retry', score, score)
        end
      end
    end

  end

end
