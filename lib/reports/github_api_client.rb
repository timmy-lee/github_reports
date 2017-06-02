require 'faraday'
require 'json'
require 'logger'
require_relative 'middleware/logging'
require_relative 'middleware/authentication'
require_relative 'middleware/status_check'
require_relative 'middleware/json_parsing'
require_relative 'middleware/cache'
# require_relative 'storage/memory'
require_relative 'storage/memcached'
require_relative 'storage/redis'

module Reports
  class Error < StandardError; end
  class NonexistentUser < Error; end
  class RequestFailure < Error; end
  class BadCredentials < Error; end
  class ConfigurationError < Error; end

  VALID_STATUS_CODES = [200, 302, 401, 403, 404, 422]

  User = Struct.new(:name, :location, :public_repos)
  Repo = Struct.new(:full_name, :url)
  Activity = Struct.new(:type, :repo_name)

  class GitHubAPIClient
    # def initialize(token)
    #   @token = token
      # @logger = Logger.new(STDOUT)
      # @logger.formatter = proc { |severity, datetime, program, message| message + "\n" }
    # end

    def user_info(username)
      # headers = { Authorization: "token #{@token}" }
      url = "https://api.github.com/users/#{username}"

      # start_time = Time.now
      response = client.get(url)
      # duration = Time.now - start_time

      # @logger.debug '-> %s %s %d (%.3f s)' % [url, 'GET', response.status, duration]
      # check_errors(JSON.parse(response.body)['message'], response.status, username)
      raise NonexistentUser, "'#{username}' does not exist" if response.status == 404

      response_hash = response.body
      User.new(response_hash['name'], response_hash['location'], response_hash['public_repos'])
    end

    def repositories(username)
      # headers = { Authorization: "token #{@token}" }
      url = "https://api.github.com/users/#{username}/repos"

      # start_time = Time.now
      response = client.get(url)
      # duration = Time.now - start_time

      # @logger.debug '-> %s %s %d (%.4f s)' % [url, 'GET', response.status, duration]
      # check_errors(JSON.parse(response.body)['message'], response.status, username) unless JSON.parse(response.body).kind_of?(Array)
      raise NonexistentUser, "'#{username}' does not exist" if response.status == 404
      response_array = response.body

      link_header = response.headers['link']

      if link_header
        while match_data = link_header.match(/<(.*)>; rel="next"/)
          next_page_url = match_data[1]
          response = client.get(next_page_url)
          link_header = response.headers['link']
          response_array += response.body
        end
      end

      response_array.map! do |response_hash|
        Repo.new(response_hash['full_name'], response_hash['url'])
      end
    end

    def activity(username)
      url = "https://api.github.com/users/#{username}/events/public"

      response = client.get(url)
      raise NonexistentUser, "'#{username}' does not exist" if response.status == 404
      response_array = response.body

      link_header = response.headers['link']

      if link_header
        while match_data = link_header.match(/<(.*)>; rel="next"/)
          next_page_url = match_data[1]
          response = client.get(next_page_url)
          link_header = response.headers['link']
          response_array += response.body
        end
      end

      response_array.map! do |response_hash|
        Activity.new(response_hash['type'], response_hash['repo']['name'])
      end
    end

    def client
      @client ||= Faraday::Connection.new do |builder|
        builder.use Middleware::JSONParsing
        builder.use Middleware::StatusCheck
        builder.use Middleware::Authentication
        builder.use Middleware::Logging
        builder.use Middleware::Cache, Storage::Redis.new
        builder.adapter Faraday.default_adapter
      end
    end

    private

    # def check_errors(message, status, username=nil)
    #   raise RequestFailure, message unless VALID_STATUS_CODES.include?(status)
    #   raise NonexistentUser, "'#{username}' does not exist" if status == 404
    #   raise BadCredentials, message if status == 401
    # end
  end
end
