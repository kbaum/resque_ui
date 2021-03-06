module ResqueHelper
  #include Rack::Utils
  #alias_method :h, :escape_html


  def classes_in_failure
    Resque.list_range(:failed,0,1000).collect{|job| job['payload']['class']}.uniq
  end

  def flash_helper
    [:notice, :warning, :message, :error].collect do |key|
      content_tag(:div, flash[key], :class => "flash #{key}") unless flash[key].blank?
    end.join
  end

  def format_time(t)
    t.strftime("%Y/%m/%d %H:%M:%S %Z")
  end

  def current_section
    request.path_info.sub('/','').split('/')[1].downcase
  end

  def current_page
    url request.path_info.sub('/','').downcase
  end

  def url(*path_parts)
    [ path_prefix, path_parts ].join("/").squeeze('/')
  end
  alias_method :u, :url

  def path_prefix
    request.env['SCRIPT_NAME']
  end

  def class_if_current(page = '')
    'class="current"' if current_page.include? page.to_s
  end

  def tab(name)
    dname = "resque/#{name.to_s.downcase}"
    "<li #{class_if_current(dname)}>#{link_to(name, url(dname))}</li>"
  end

  def find_worker(worker)
    first_part, *rest = worker.split(':')
    first_part.gsub!(/_/,'.')
    Resque::Worker.find("#{first_part}:#{rest.join(':')}")
  end

  def redis_get_size(key)
    case Resque.redis.type(key)
    when 'none'
      []
    when 'list'
      Resque.redis.llen(key)
    when 'set'
      Resque.redis.scard(key)
    when 'string'
      Resque.redis.get(key).length
    end
  end

  def redis_get_value_as_array(key)
    case Resque.redis.type(key)
    when 'none'
      []
    when 'list'
      Resque.list_range(key, 0, 20)
    when 'set'
      Resque.redis.smembers(key)
    when 'string'
      [Resque.redis.get(key)]
    end
  end

  def show_args(args)
    Array(args).map { |a| a.inspect }.join("\n")
  end

  def partial?
    @partial
  end

  def poll
    if @polling
      text = "Last Updated: #{Time.now.strftime("%H:%M:%S")}"
    else
      text = link_to('Live Poll', {:action => 'poll', :page => current_section}, :rel => 'poll')
    end
    "<p class='poll'>#{text}</p>"
  end

  def status_poll(start)
    if @polling
      text = "Last Updated: #{Time.now.strftime("%H:%M:%S")}"
    else
      text = link_to('Live Poll', {:action => 'status_poll', :start => start}, :rel => 'poll')
    end
    "<p class='poll'>#{text}</p>"
  end

  def resque
    Resque
  end
end
