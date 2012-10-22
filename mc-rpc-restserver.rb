# A very simple demonstration of writing a REST server
# for Simple RPC clients that takes requests over HTTP
# and returns results as JSON structures.

# Inspired with mcollective/ext/mc-rpc-restserver.rb demo
# in the MCollective source code

# Copyright (C) 2011 Marco Mornati (mornatim at gmail.com)
# Copyright (C) 2011 Louis Coilliot (louis.coilliot at gmail.com)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Examples :
# http://<your box>:4567/mcollective/rpcutil/ping/
# JSON Available Values:
#{
# filters: {
#   class: [value,value],
#   identity: [value]
#   fact: [],
#   agent: [],
#   compound: value
# },
# parameters: {
#   name: value,
#   name, value
# },
# schedule: {
#   schedtype: value,
#   schedarg: value
# }
# limit: {
#   targets: value,
#   method: value
# }
#}
#
#
# POST /mcollective/package/status/
# JSON Obj in POST:
# {
#    "filters": {
#        "class": ['retail', 'stores']
#    },
#    "parameters": {
#        "package": "bash"
#    }
# }
#
# POST /mcollective/service/status/
# JSON Obj:
# {"parameters": {"service":"sshd"}, "limit": {"targets":"1"}}
# of with filters
# {"filters":{"identity":["notebook", "el6"]}, "parameters": {"service":"sshd"}, "limit": {"targets":"1"}}
# Returns all the answers as a JSON data block

require 'rubygems'
require 'sinatra'
require 'mcollective'
require 'json'
require 'logger'
require 'inifile'

include MCollective::RPC

def getkey(section, key)
    ini=IniFile.load('/etc/sysconfig/kermit-restmco', :comment => '#')
    params = ini[section]
    params[key]
end

#Read Configuration file
LOG_FILE = getkey('logger', 'LOG_FILE')
LOG_LEVEL = getkey('logger', 'LOG_LEVEL')

#Create log file if does not exists
FileUtils.touch LOG_FILE
FileUtils.chown('nobody', 'nobody', LOG_FILE)

uid = Etc.getpwnam("nobody").uid
Process::Sys.setuid(uid)

#Create Log file
logger = Logger.new(STDERR)
logger = Logger.new(STDOUT)
logger = Logger.new(LOG_FILE, 'daily')
case LOG_LEVEL
    when 'DEBUG'
        logger.level = Logger::DEBUG
    when 'INFO'
        logger.level = Logger::INFO
    when 'WARN'
        logger.level = Logger::WARN
    when 'ERROR'
        logger.level = Logger::ERROR
end

logger.debug "Starting Kermit-RestMCO"

def set_filters(mc, params)
    if params[:filters] then
        logger.info "Applying filters"
        params[:filters].each do |filter_type, filter_values|
            logger.debug "#{filter_type}: #{filter_values}"
            case name
            when 'class'
                puts "Applying class_filter"
                filter_values.each do |value|
                    mc.class_filter "/#{value}/"
                end
            when 'fact'
                puts "Applying fact_filter"
                filter_values.each do |value|
                    mc.fact_filter "#{value}"
                end
            when 'agent'
                puts "Applying agent_filter"
            #when 'limit'
            #    puts "Applying limit_targets"
            #    filter_values.each do |value|
            #        mc.limit_targets = "#{value}"
            #    end
            when 'identity'
                puts "Applying identity_filter"
                filter_values.each do |value|
                    mc.identity_filter "#{value}"
                end
            when 'compound'
                puts "Applying compound_filter"
                filter_values.each do |value|
                    mc.compound "#{value}"
                end
            end
        end
    end
end

def recursive_symbolize_keys(h)
  case h
  when Hash
    Hash[
      h.map do |k, v|
        [ k.respond_to?(:to_sym) ? k.to_sym : k, recursive_symbolize_keys(v) ]
      end
    ]
  when Enumerable
    h.map { |v| recursive_symbolize_keys(v) }
  else
    h
  end
end

get '/' do
    logger.debug "Calling / url"
    "Hello Sinatra"
end

get '/schedstatus/:jobid/:filters' do
    content_type :json
    logger.debug "Calling /schedstatus url"
    jobreq = { :jobid => params[:jobid] }
    sched = rpcclient("scheduler")
    set_filters(sched, params)
    json_response = JSON.dump(sched.query(jobreq).map{|r| r.results})
    logger.info "Command schedstatus #{params[:jobid]} executed on filters #{params[:filters]}"
    logger.debug "Response received: #{json_response}"
    json_response
end

get '/schedoutput/:jobid/:filters' do   
    content_type :json
    logger.debug "Calling /schedoutput url"
    jobreq = { :jobid => params[:jobid], :output => 'yes' }
    sched = rpcclient("scheduler")
    set_filters(sched, params)
    json_response = JSON.dump(sched.query(jobreq).map{|r| r.results})
    logger.info "Command scheoutput #{params[:jobid]} executed on filters: #{params[:filters]}"
    logger.debug "Response received: #{json_response}"
    json_response
end

post '/mcollective/:agent/:action/' do
    content_type :json
    logger.debug "Calling /mcollective url"
    data = JSON.parse(request.body.read)
    data = recursive_symbolize_keys(data)
    logger.debug "JSON Data: #{data}"
    if data[:schedule] then
        logger.info "Executing with backend scheduler"
        scheduler_data=data[:schedule]
        scheduler_data[:schedtype] ||='in'
        scheduler_data[:schedarg]  ||='0s'
        jobreq = { :agentname  => params[:agent],
                   :actionname => params[:action],
                   :schedtype  => scheduler_data[:schedtype],
                   :schedarg   => scheduler_data[:schedarg] }
        sched = rpcclient("scheduler")
        set_filters(sched, params)
        unless arguments.empty?
            jobreq[:params] = data[:parameters].keys.join(",")
            jobreq.merge!(data[:parameters])
        end
        json_response = JSON.dump(sched.schedule(jobreq).map{|r| r.results})
        logger.info "Command Agent: #{params[:agent]} Action: #{params[:action]} executed"
        logger.debug "Response received: #{json_response}"
        json_response
    else
        mc = rpcclient(params[:agent])
        mc.discover
        set_filters(mc, params)
        if data[:parameters]
            data[:parameters].each  { |name,value| puts "#{name}: #{value}" }
        end
        if data[:limit]
            limits = data[:limit]
            if limits[:target]
                mc.limit_targets = "#{limits[:targets]}"
            end
            if limits[:method]
                mc.limit_method = "#{limits[:method]}"
            end
        end
        json_response = JSON.dump(mc.send(params[:action], data[:parameters]).map{|r| r.results})
        logger.info "Command Agent: #{params[:agent]} Action: #{params[:action]} executed"
        logger.debug "Response received: #{json_response}"
        json_response
    end
end

