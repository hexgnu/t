require 'action_view'
require 'launchy'
require 'oauth'
require 't/core_ext/string'
require 't/delete'
require 't/rcfile'
require 't/set'
require 'thor'
require 'time'
require 'twitter'
require 'yaml'

module T
  class CLI < Thor
    include ActionView::Helpers::DateHelper
    include ActionView::Helpers::NumberHelper

    DEFAULT_HOST = 'api.twitter.com'
    DEFAULT_PROTOCOL = 'https'

    class_option :host, :aliases => "-H", :type => :string, :default => DEFAULT_HOST, :desc => "Twitter API server"
    class_option :no_ssl, :aliases => "-U", :type => :boolean, :default => false, :desc => "Disable SSL"
    class_option :profile, :aliases => "-P", :type => :string, :default => File.join(File.expand_path("~"), RCFile::FILE_NAME), :desc => "Path to RC file", :banner => "FILE"

    check_unknown_options!

    def initialize(*)
      super
      @rcfile = RCFile.instance
    end

    desc "accounts", "List accounts"
    def accounts
      @rcfile.path = options[:profile] if options[:profile]
      @rcfile.profiles.each do |profile|
        say profile[0]
        profile[1].keys.each do |key|
          say "  #{key}#{@rcfile.default_profile[0] == profile[0] && @rcfile.default_profile[1] == key ? " (default)" : nil}"
        end
      end
    end
    map %w(list ls) => :accounts

    desc "authorize", "Allows an application to request user authorization"
    method_option :consumer_key, :aliases => "-c", :required => true
    method_option :consumer_secret, :aliases => "-s", :required => true
    method_option :prompt, :aliases => "-p", :type => :boolean, :default => true
    method_option :dry_run, :type => :boolean
    def authorize
      request_token = consumer.get_request_token
      url = generate_authorize_url(request_token)
      if options[:prompt]
        say "In a moment, your web browser will open to the Twitter app authorization page."
        say "Perform the following steps to complete the authorization process:"
        say "  1. Sign in to Twitter"
        say "  2. Press \"Authorize app\""
        say "  3. Copy or memorize the supplied PIN"
        say "  4. Return to the terminal to enter the PIN"
        say
        ask "Press [Enter] to open the Twitter app authorization page."
      end
      if options[:dry_run]
        Launchy.open(url, :dry_run => true)
      else
        Launchy.open(url)
        pin = ask "\nPaste in the supplied PIN:"
        access_token = request_token.get_access_token(:oauth_verifier => pin.chomp)
        oauth_response = access_token.get('/1/account/verify_credentials.json')
        username = oauth_response.body.match(/"screen_name"\s*:\s*"(.*?)"/).captures.first
        @rcfile.path = options[:profile] if options[:profile]
        @rcfile[username] = {
          options[:consumer_key] => {
            'username' => username,
            'consumer_key' => options[:consumer_key],
            'consumer_secret' => options[:consumer_secret],
            'token' => access_token.token,
            'secret' => access_token.secret,
          }
        }
        @rcfile.default_profile = {'username' => username, 'consumer_key' => options[:consumer_key]}
        say "Authorization successful"
      end
    rescue OAuth::Unauthorized
      raise Thor::Error, "Authorization failed. Check that your consumer key and secret are correct."
    end

    desc "block USERNAME", "Block a user."
    def block(username)
      username = username.strip_at
      user = client.block(username)
      say "@#{@rcfile.default_profile[0]} blocked @#{user.screen_name}"
      say
      say "Run `#{$0} delete block #{user.screen_name}` to unblock."
    end

    desc "direct_messages", "Returns the 20 most recent Direct Messages sent to you."
    def direct_messages
      run_pager
      client.direct_messages.map do |direct_message|
        say "#{direct_message.sender.screen_name.rjust(20)}: #{direct_message.text} (#{time_ago_in_words(direct_message.created_at)} ago)"
      end
    end
    map %w(dms) => :direct_messages

    desc "sent_messages", "Returns the 20 most recent Direct Messages sent to you."
    def sent_messages
      run_pager
      client.direct_messages_sent.map do |direct_message|
        say "#{direct_message.recipient.screen_name.rjust(20)}: #{direct_message.text} (#{time_ago_in_words(direct_message.created_at)} ago)"
      end
    end
    map %w(sms) => :sent_messages

    desc "dm USERNAME MESSAGE", "Sends that person a Direct Message."
    def dm(username, message)
      username = username.strip_at
      direct_message = client.direct_message_create(username, message)
      say "Direct Message sent from @#{@rcfile.default_profile[0]} to @#{direct_message.recipient.screen_name} (#{time_ago_in_words(direct_message.created_at)} ago)"
    end
    map %w(m) => :dm

    desc "favorite USERNAME", "Marks that user's last Tweet as one of your favorites."
    def favorite(username)
      username = username.strip_at
      user = client.user(username)
      if user.status
        client.favorite(user.status.id)
        say "@#{@rcfile.default_profile[0]} favorited @#{user.screen_name}'s latest status: #{user.status.text}"
        say
        say "Run `#{$0} delete favorite` to unfavorite."
      else
        raise Thor::Error, "No status found"
      end
    rescue Twitter::Error::Forbidden => error
      if error.message =~ /You have already favorited this status\./
        say "@#{@rcfile.default_profile[0]} favorited @#{user.screen_name}'s latest status: #{user.status.text}"
      else
        raise
      end
    end
    map %w(fave) => :favorite

    desc "follow USERNAME", "Allows you to start following a specific user."
    def follow(username)
      username = username.strip_at
      user = client.follow(username)
      say "@#{@rcfile.default_profile[0]} is now following @#{user.screen_name}."
      say
      say "Run `#{$0} unfollow #{user.screen_name}` to stop."
    end
    map %w(befriend) => :follow

    desc "get USERNAME", "Retrieves the latest update posted by the user."
    def get(username)
      username = username.strip_at
      user = client.user(username)
      if user.status
        say "#{user.status.text} (#{time_ago_in_words(user.status.created_at)} ago)"
      else
        raise Thor::Error, "No status found"
      end
    end

    desc "mentions", "Returns the 20 most recent Tweets mentioning you."
    method_option :reverse, :aliases => "-r", :type => :boolean, :default => false
    def mentions
      timeline = client.mentions
      timeline.reverse! if options[:reverse]
      run_pager
      timeline.map do |status|
        say "#{status.user.screen_name.rjust(20)}: #{status.text} (#{time_ago_in_words(status.created_at)} ago)"
      end
    end
    map %w(replies) => :mentions

    desc "open USERNAME", "Opens that user's profile in a web browser."
    method_option :dry_run, :type => :boolean
    def open(username)
      username = username.strip_at
      if options[:dry_run]
        Launchy.open("https://twitter.com/#{username}", :dry_run => true)
      else
        Launchy.open("https://twitter.com/#{username}")
      end
    end

    desc "reply USERNAME MESSAGE", "Post your Tweet as a reply directed at another person."
    method_option :location, :aliases => "-l", :type => :boolean, :default => true
    def reply(username, message)
      username = username.strip_at
      hash = {}
      hash.merge!(:lat => location.lat, :long => location.lng) if options[:location]
      user = client.user(username)
      hash.merge!(:in_reply_to_status_id => user.status.id) if user.status
      status = client.update("@#{user.screen_name} #{message}", hash)
      say "Reply created by @#{@rcfile.default_profile[0]} to @#{user.screen_name} (#{time_ago_in_words(status.created_at)} ago)"
      say
      say "Run `#{$0} delete status` to delete."
    end

    desc "retweet USERNAME", "Sends that user's latest Tweet to your followers."
    def retweet(username)
      username = username.strip_at
      user = client.user(username)
      if user.status
        client.retweet(user.status.id)
        say "@#{@rcfile.default_profile[0]} retweeted @#{user.screen_name}'s latest status: #{user.status.text}"
        say
        say "Run `#{$0} delete status` to undo."
      else
        raise Thor::Error, "No status found"
      end
    rescue Twitter::Error::Forbidden => error
      if error.message =~ /sharing is not permissable for this status \(Share validations failed\)/
        say "@#{@rcfile.default_profile[0]} retweeted @#{user.screen_name}'s latest status: #{user.status.text}"
      else
        raise
      end
    end
    map %w(rt) => :retweet

    desc "stats USERNAME", "Retrieves the given user's number of followers and how many people they're following."
    def stats(username)
      username = username.strip_at
      user = client.user(username)
      say "Followers: #{number_with_delimiter(user.followers_count)}"
      say "Following: #{number_with_delimiter(user.friends_count)}"
      say
      say "Run `#{$0} whois #{user.screen_name}` to view profile."
    end

    desc "status MESSAGE", "Post a Tweet."
    method_option :location, :aliases => "-l", :type => :boolean, :default => true
    def status(message)
      hash = {}
      hash.merge!(:lat => location.lat, :long => location.lng) if options[:location]
      status = client.update(message, hash)
      say "Tweet created by @#{@rcfile.default_profile[0]} (#{time_ago_in_words(status.created_at)} ago)"
      say
      say "Run `#{$0} delete status` to delete."
    end
    map %w(post tweet update) => :status

    desc "suggest", "This command returns a listing of Twitter users' accounts we think you might enjoy following."
    def suggest
      recommendation = client.recommendations(:limit => 1).first
      if recommendation
        say "Try following @#{recommendation.screen_name}."
        say
        say "Run `#{$0} follow #{recommendation.screen_name}` to follow."
        say "Run `#{$0} whois #{recommendation.screen_name}` for profile."
        say "Run `#{$0} suggest` for another recommendation."
      end
    end

    desc "timeline", "Returns the 20 most recent Tweets posted by you and the users you follow."
    method_option :reverse, :aliases => "-r", :type => :boolean, :default => false
    def timeline
      timeline = client.home_timeline
      timeline.reverse! if options[:reverse]
      run_pager
      timeline.map do |status|
        say "#{status.user.screen_name.rjust(20)}: #{status.text} (#{time_ago_in_words(status.created_at)} ago)"
      end
    end
    map %w(tl) => :timeline

    desc "unfollow USERNAME", "Allows you to stop following a specific user."
    def unfollow(username)
      username = username.strip_at
      user = client.unfollow(username)
      say "@#{@rcfile.default_profile[0]} is no longer following @#{user.screen_name}."
      say
      say "Run `#{$0} follow #{user.screen_name}` to follow again."
    end
    map %w(defriend) => :unfollow

    desc "version", "Show version"
    def version
      say T::Version
    end
    map %w(-v --version) => :version

    desc "whois USERNAME", "Retrieves profile information for the user."
    def whois(username)
      username = username.strip_at
      user = client.user(username)
      say "#{user.name}, since #{user.created_at.strftime("%b %Y")}."
      say "bio: #{user.description}"
      say "location: #{user.location}"
      say "web: #{user.url}"
    end

    desc "delete SUBCOMMAND ...ARGS", "Delete Tweets, Direct Messages, etc."
    method_option :force, :aliases => "-f", :type => :boolean
    subcommand 'delete', Delete

    desc "set SUBCOMMAND ...ARGS", "Change various account settings."
    subcommand 'set', Set

    no_tasks do

      def base_url
        "#{protocol}://#{host}"
      end

      def client
        return @client if @client
        @rcfile.path = options[:profile] if options[:profile]
        @client = Twitter::Client.new(
          :endpoint => base_url,
          :consumer_key => @rcfile.default_consumer_key,
          :consumer_secret => @rcfile.default_consumer_secret,
          :oauth_token => @rcfile.default_token,
          :oauth_token_secret  => @rcfile.default_secret
        )
      end

      def consumer
        OAuth::Consumer.new(
          options[:consumer_key],
          options[:consumer_secret],
          :site => base_url
        )
      end

      def generate_authorize_url(request_token)
        request = consumer.create_signed_request(:get, consumer.authorize_path, request_token, pin_auth_parameters)
        params = request['Authorization'].sub(/^OAuth\s+/, '').split(/,\s+/).map do |param|
          key, value = param.split('=')
          value =~ /"(.*?)"/
          "#{key}=#{CGI::escape($1)}"
        end.join('&')
        "#{base_url}#{request.path}?#{params}"
      end

      def host
        options[:host] || DEFAULT_HOST
      end

      def location
        require 'geokit'
        require 'open-uri'
        ip_address = Kernel::open("http://checkip.dyndns.org/") do |body|
          /(?:\d{1,3}\.){3}\d{1,3}/.match(body.read)[0]
        end
        Geokit::Geocoders::MultiGeocoder.geocode(ip_address)
      end

      def pin_auth_parameters
        {:oauth_callback => 'oob'}
      end

      def protocol
        options[:no_ssl] ? 'http' : DEFAULT_PROTOCOL
      end

      def run_pager
        return if RUBY_PLATFORM =~ /win32/
        return if ENV["T_ENV"] == "test"
        return unless STDOUT.tty?

        read, write = IO.pipe

        unless Kernel.fork # Child process
          STDOUT.reopen(write)
          STDERR.reopen(write) if STDERR.tty?
          read.close
          write.close
          return
        end

        # Parent process, become pager
        STDIN.reopen(read)
        read.close
        write.close

        ENV['LESS'] = 'FSRX' # Don't page if the input is short enough

        Kernel.select [STDIN] # Wait until we have input before we start the pager
        pager = ENV['PAGER'] || 'less'
        exec pager rescue exec "/bin/sh", "-c", pager
      end

    end
  end
end
