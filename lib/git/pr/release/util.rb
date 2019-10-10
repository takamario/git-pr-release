# frozen_string_literal: true

require 'erb'
require 'uri'
require 'open3'
require 'optparse'
require 'json'

require 'colorize'
require 'diff/lcs'

class PullRequest
  attr_reader :pr

  def initialize(pr)
    @pr = pr
  end

  def to_checklist_item
    "- [ ] ##{pr.number} #{pr.title}" + mention
  end

  def html_link
    pr.rels[:html].href
  end

  def to_hash
    { data: @pr.to_hash }
  end

  def mention
    mention = case PullRequest.mention_type
              when 'author'
                pr.user ? "@#{pr.user.login}" : nil
              else
                pr.assignee ? "@#{pr.assignee.login}" : pr.user ? "@#{pr.user.login}" : nil
              end

    mention ? " #{mention}" : ''
  end

  def self.mention_type
    @mention_type ||= (git_config('mention') || 'default')
  end
end

class DummyPullRequest
  def initialize
    # nop
  end

  def to_checklist_item
    '- [ ] #??? THIS IS DUMMY PULL REQUEST'
  end

  def html_link
    'http://github.com/DUMMY/DUMMY/issues/?'
  end

  def to_hash
    { data: {} }
  end
end

def host_and_repository_and_scheme
  @host_and_repository_and_scheme ||= begin
    remote = git(:config, 'remote.origin.url').first.chomp
    remote = "ssh://#{remote.sub(':', '/')}" unless %r{^\w+://} === remote

    remote_url = URI.parse(remote)
    repository = remote_url.path.sub(%r{^/}, '').sub(/\.git$/, '')

    host = remote_url.host == 'github.com' ? nil : remote_url.host
    [host, repository, remote_url.scheme === 'http' ? 'http' : 'https']
  end
end

def say(message, level)
  color = case level
          when :trace
            return unless ENV['DEBUG']

            nil
          when :debug
            return unless ENV['DEBUG']

            :blue
          when :info
            :green
          when :notice
            :yellow
          when :warn
            :magenta
          when :error
            :red
    end

  warn message.colorize(color)
end

def git(*command)
  command = ['git', *command.map(&:to_s)]
  say "Executing `#{command.join(' ')}`", :trace
  out, status = Open3.capture2(*command)
  unless status.success?
    raise "Executing `#{command.join(' ')}` failed: #{status}"
  end

  out.each_line
end

def git_config(key)
  host, = host_and_repository_and_scheme

  plain_key = ['pr-release', key].join('.')
  host_aware_key = ['pr-release', host, key].compact.join('.')

  begin
    git(:config, '-f', '.git-pr-release', plain_key).first.chomp
  rescue StandardError
    begin
      git(:config, host_aware_key).first.chomp
    rescue StandardError
      nil
    end
  end
end

def git_config_set(key, value)
  host, = host_and_repository_and_scheme
  host_aware_key = ['pr-release', host, key].compact.join('.')

  git :config, '--global', host_aware_key, value
end

# First line will be the title of the PR
DEFAULT_PR_TEMPLATE = <<~ERB
  Release <%= Time.now %>
  <% pull_requests.each do |pr| -%>
  <%=  pr.to_checklist_item %>
  <% end -%>
ERB

def build_pr_title_and_body(release_pr, merged_prs, changed_files)
  release_pull_request = target_pull_request = release_pr ? PullRequest.new(release_pr) : DummyPullRequest.new
  merged_pull_requests = pull_requests = merged_prs.map { |pr| PullRequest.new(pr) }

  template = DEFAULT_PR_TEMPLATE

  if path = ENV.fetch('GIT_PR_RELEASE_TEMPLATE') { git_config('template') }
    template_path = File.join(git('rev-parse', '--show-toplevel').first.chomp, path)
    template = File.read(template_path)
  end

  erb = ERB.new template, nil, '-'
  content = erb.result binding
  content.split(/\n/, 2)
end

def dump_result_as_json(release_pr, merged_prs, changed_files)
  puts({
    release_pull_request: (release_pr ? PullRequest.new(release_pr) : DummyPullRequest.new).to_hash,
    merged_pull_requests: merged_prs.map { |pr| PullRequest.new(pr).to_hash },
    changed_files: changed_files.map(&:to_hash)
  }.to_json)
end

def merge_pr_body(old_body, new_body)
  # Try to take over checklist statuses
  pr_body_lines = []

  check_status = {}
  old_body.split(/\r?\n/).each do |line|
    line.match(/^- \[(?<check_value>[ x])\] #(?<issue_number>\d+)/) do |m|
      say "Found pull-request checkbox \##{m[:issue_number]} is #{m[:check_value]}.", :trace
      check_status[m[:issue_number]] = m[:check_value]
    end
  end
  old_body_unchecked = old_body.gsub /^- \[[ x]\] \#(\d+)/, '- [ ] #\1'

  Diff::LCS.traverse_balanced(old_body_unchecked.split(/\r?\n/), new_body.split(/\r?\n/)) do |event|
    say "diff: #{event.inspect}", :trace
    action, old, new = *event
    old_nr, old_line = *old
    new_nr, new_line = *new

    case action
    when '=', '+'
      say "Use line as is: #{new_line}", :trace
      pr_body_lines << new_line
    when '-'
      say "Use old line: #{old_line}", :trace
      pr_body_lines << old_line
    when '!'
      if [old_line, new_line].all? { |line| /^- \[ \]/ === line }
        say "Found checklist diff; use old one: #{old_line}", :trace
        pr_body_lines << old_line
      else
        # not a checklist diff, use both line
        say "Use line as is: #{old_line}", :trace
        pr_body_lines << old_line

        say "Use line as is: #{new_line}", :trace
        pr_body_lines << new_line
      end
    else
      say "Unknown diff event: #{event}", :warn
    end
  end

  merged_body = pr_body_lines.join("\n")
  check_status.each do |issue_number, check_value|
    say "Update pull-request checkbox \##{issue_number} to #{check_value}.", :trace
    merged_body.gsub! /^- \[ \] \##{issue_number}/, "- [#{check_value}] \##{issue_number}"
  end

  merged_body
end

def obtain_token!
  token = ENV.fetch('GIT_PR_RELEASE_TOKEN') { git_config('token') }

  unless token
    require 'highline/import'
    warn 'Could not obtain GitHub API token.'
    warn 'Trying to generate token...'

    username = ask('username? ') { |q| q.default = ENV['USER'] }
    password = ask('password? (not saved) ') { |q| q.echo = '*' }

    temporary_client = Octokit::Client.new login: username, password: password

    auth = request_authorization(temporary_client, nil)

    token = auth.token
    git_config_set 'token', token
  end

  token
end

def request_authorization(client, two_factor_code)
  params = { scopes: %w[public_repo repo], note: 'git-pr-release' }
  params[:headers] = { 'X-GitHub-OTP' => two_factor_code } if two_factor_code

  auth = nil
  begin
    auth = client.create_authorization(params)
  rescue Octokit::OneTimePasswordRequired
    two_factor_code = ask('two-factor authentication code? ')
    auth = request_authorization(client, two_factor_code)
  end

  auth
end

# Fetch PR files of specified pull_request
def pull_request_files(client, pull_request)
  return [] if pull_request.nil?

  host, repository, scheme = host_and_repository_and_scheme
  client.pull_request_files repository, pull_request.number
end
