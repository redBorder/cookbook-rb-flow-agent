# Cookbook:: rb-flow-agent
# Resource:: config

actions :add, :remove
default_action :add

attribute :config_dir, kind_of: String, default: '/etc/redborder-flow-agent'
attribute :user, kind_of: String, default: 'redborder-flow-agent'
attribute :log_dir, kind_of: String, default: '/var/log/redborder-flow-agent'
attribute :ja4_signatures_file, kind_of: String, default: '/etc/redborder-flow-agent/ja4_signatures.yaml'

# Output (used when the interface doesn't set it)
attribute :protocol_type, kind_of: String, default: 'NetFlow v9'
attribute :flow_mode, kind_of: String, default: 'unidirectional'
attribute :kafka_port, kind_of: Integer, default: 9092
attribute :kafka_topic, kind_of: String, default: 'rb_flow'
attribute :target_host, kind_of: String, default: '127.0.0.1'
attribute :netflow_port, kind_of: Integer, default: 2055
attribute :sflow_port, kind_of: Integer, default: 6343
attribute :sampling_rate, kind_of: Integer, default: 1
attribute :cores, kind_of: Integer, default: 0 # 0 = all cores
# Observation domain without an observation id (agent defaults)
attribute :engine_type, kind_of: Integer, default: 1
attribute :source_id, kind_of: Integer, default: 1001
# Sensor identity with the export output (no flow sensor enrichment)
attribute :sensor_name, kind_of: String, default: 'sensor'
# Druid index enrichment when the flow sensor doesn't set it
attribute :index_partitions, kind_of: Integer, default: 5
attribute :index_replicas, kind_of: Integer, default: 1

# Agent settings per interface (webui Advanced tabs), the interface value wins.
# Same keys as the interface attributes; keep in sync with Sensor::FLOW_AGENT_DEFAULTS (webui).
attribute :promiscuous, kind_of: [TrueClass, FalseClass], default: true
attribute :snaplen, kind_of: Integer, default: 1518
attribute :workers_per_interface, kind_of: Integer, default: 2
attribute :buffer_size_mb, kind_of: Integer, default: 16
attribute :track_open_ports, kind_of: [TrueClass, FalseClass], default: true
attribute :track_tcp_metrics, kind_of: [TrueClass, FalseClass], default: true
attribute :extract_tls_sni, kind_of: [TrueClass, FalseClass], default: true
attribute :extract_tls_version, kind_of: [TrueClass, FalseClass], default: true
attribute :extract_http_host, kind_of: [TrueClass, FalseClass], default: true
attribute :extract_http_details, kind_of: [TrueClass, FalseClass], default: true
attribute :extract_dns_domains, kind_of: [TrueClass, FalseClass], default: true
attribute :dns_cache_size, kind_of: Integer, default: 50000
attribute :active_timeout_sec, kind_of: Integer, default: 30
attribute :inactive_timeout_sec, kind_of: Integer, default: 15
attribute :max_active_flows, kind_of: Integer, default: 500000
attribute :shards, kind_of: Integer, default: 64
attribute :engine_id, kind_of: Integer, default: 0
attribute :template_interval_sec, kind_of: Integer, default: 30
attribute :batch_size, kind_of: Integer, default: 100
attribute :compression, kind_of: String, default: 'snappy'
attribute :stats_socket, kind_of: [TrueClass, FalseClass], default: true # socket for redborder-flow-agent --stats
attribute :stats_http_addr, kind_of: String, default: ''
