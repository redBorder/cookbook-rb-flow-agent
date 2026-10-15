# Cookbook:: rb-flow-agent
# Resource:: config

actions :add, :remove
default_action :add

attribute :config_dir, kind_of: String, default: '/etc/redborder-flow-agent'
attribute :split_traffic_logstash, kind_of: [TrueClass, FalseClass], default: false
