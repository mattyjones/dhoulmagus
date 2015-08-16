#! /usr/bin/env ruby

require 'sensu-handler'
gem 'mail', '~> 2.5.4'
require 'mail'
require 'timeout'
require 'socket'

# patch to fix Exim delivery_method: https://github.com/mikel/mail/pull/546
module ::Mail
  class Exim < Sendmail
    def self.call(path, arguments, _destinations, encoded_message)
      popen "#{path} #{arguments}" do |io|
        io.puts encoded_message.to_lf
        io.flush
      end
    end
  end
end

class DetailedMailer < Sensu::Handler
  def get_setting(name)
    settings['<%= @config_key %>'][name]
  end

  def short_name
    @event['client']['name'] + '/' + @event['check']['name']
  end

  def action_to_string
    @event['action'].eql?('resolve') ? 'RESOLVED' : 'ALERT'
  end

  def define_status(status)
    case status
    when '0'
      return 'OK'
    when '1'
      return 'WARNING'
    when '2'
      return 'CRITICAL'
    when '3'
      return 'UNKNOWN'
    else
      return 'ERROR'
    end
  end

  def define_sensu_env
    sensu_server = Socket.gethostname
    if sensu_server.match(/^prd/)
      return 'Prod: '
    elsif sensu_server.match(/^dev/)
      return 'Dev: '
    else
      return 'Test: '
    end
  end

  def tempate_vars
    @config = {
      monitored_instance    => @event['client']['name'],
      incident_timestamp    => Time.at(@event['check']['issued']),
      instance_address      => @event['client']['address'],
      check_name            => @event['check']['name'],
      check_command         => @event['check']['command'],
      check_state           => define_status(@event['check']['status']),
      num_occurrences       => @event['occurrences'],
      notification_comment  => '#YELLOW', # the comment added to a check to silence it
      notification_author   => '#YELLOW', # the user that silenced the check
      condition_duration    => "#{@event['check']['duration']}s",
      check_output          => '#YELLOW',
      sensu_env             => define_sensu_env,
      alert_type            => action_to_string,
      notification_type     => alert_type,
      orginator             => 'sensu-monitoring',
      flapping              => '#YELLOW' # is the check flapping
    }
  end

  def acquire_template(input)
    File.read(input)
  end

  def handle
    mail_to                   = get_setting('mail_to')
    mail_from                 = get_setting('mail_from')

    delivery_method           = get_setting('delivery_method') || 'smtp'
    smtp_address              = get_setting('smtp_address') || 'localhost'
    smtp_port                 = get_setting('smtp_port') || '25'
    smtp_domain               = get_setting('smtp_domain') || 'localhost.localdomain'

    smtp_username             = get_setting('smtp_username') || nil
    smtp_password             = get_setting('smtp_password') || nil
    smtp_authentication       = get_setting('smtp_authentication') || :plain
    smtp_enable_starttls_auto = get_setting('smtp_enable_starttls_auto') == 'false' ? false : true

    # subject = "#{action_to_string} - #{short_name}: #{@event['check']['notification']}"

    subject = "#{define_sensu_env} #{action_to_string}  #{@event['check']['name']} on #{@event['client']['name']} is #{@event['check']['status']}"

    Mail.defaults do
      delivery_options = {
        address: smtp_address,
        port: smtp_port,
        domain: smtp_domain,
        openssl_verify_mode: 'none',
        enable_starttls_auto: smtp_enable_starttls_auto
      }

      unless smtp_username.nil?
        auth_options = {
          user_name: smtp_username,
          password: smtp_password,
          authentication: smtp_authentication
        }
        delivery_options.merge! auth_options
      end

      delivery_method delivery_method.intern, delivery_options
    end

    # mail = Mail.deliver do
    #   to mail_to
    #   from mail_from
    #   subject subject
    #
    #   # text_part do
    #   #   body 'This is plain text'
    #   # end
    #
    #   html_part do
    #     content_type 'text/html; charset=UTF-8'
    #     template = 'templates/email.erb'
    #     body = ERB.new(acquire_template(template)).result
    #   end
    # end

    begin
      timeout 10 do
        Mail.deliver do
          to mail_to
          from mail_from
          subject subject
          content_type 'text/html; charset=UTF-8'
          template = 'templates/base_email.erb'
          body ERB.new(acquire_template(template)).result
        end

        puts 'mail -- sent alert for ' + short_name + ' to ' + mail_to.to_s
      end
    rescue Timeout::Error
      puts 'mail -- timed out while attempting to ' + @event['action'] + ' an incident -- ' + short_name
    end
  end
end