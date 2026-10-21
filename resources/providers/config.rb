# Cookbook:: rb-flow-agent
# Provider:: config

include RbFlowAgent::Helper

action :add do
  begin
    config_dir = new_resource.config_dir
    split_traffic_logstash = new_resource.split_traffic_logstash

    # nDPI build (static, no libndpi needed). Flavors ship the same files, so drop the others first
    %w(redborder-flow-agent redborder-flow-agent-ndpi).each do |pkg|
      dnf_package pkg do
        action :remove
        ignore_failure true
      end
    end

    dnf_package 'redborder-flow-agent-ndpi-static' do
      action :upgrade
      ignore_failure true
    end

    # Migration: the legacy rb-exporter (pmacct based) is replaced by redborder-flow-agent
    legacy_ifaces = (node['redborder'] && node['redborder']['interfaces'] || {}).keys
    (['rb-exporter'] + legacy_ifaces.map { |i| "rb-exporter@#{i}" }).each do |s|
      service "legacy_#{s}" do
        service_name s
        action [:stop, :disable]
        ignore_failure true
        only_if { ::File.exist?('/usr/lib/systemd/system/rb-exporter@.service') || ::File.exist?('/etc/init.d/rb-exporter') }
      end
    end

    dnf_package 'rb-exporter' do
      action :remove
      ignore_failure true
    end

    # Used to come in as an rb-exporter dependency
    dnf_package 'arpwatch' do
      action :install
      ignore_failure true
    end

    directory '/etc/rb-exporter' do
      recursive true
      action :delete
      only_if { ::Dir.exist?('/etc/rb-exporter') }
    end

    Dir.glob('/etc/logrotate.d/rb-exporter-*').each do |f|
      file f do
        action :delete
      end
    end

    # Only the per interface instances (redborder-flow-agent@<iface>) are used.
    # The package ships an example config.yaml (eth0, stdout exporter) for the plain unit.
    service 'redborder-flow-agent' do
      action [:stop, :disable]
    end

    file "#{config_dir}/config.yaml" do
      action :delete
    end

    directory config_dir do
      owner 'root'
      group 'root'
      mode '0755'
      recursive true
      action :create
    end

    arp_ifaces = []

    # ARP spoofing alerts: arpwatch logs are forwarded to the manager by rsyslog
    template '/etc/rsyslog.d/arp.conf' do
      source 'rsyslog_arp_conf.erb'
      owner 'root'
      group 'root'
      cookbook 'rb-flow-agent'
      mode '0644'
      retries 2
      notifies :restart, 'service[rsyslog]', :delayed
    end

    if node['redborder'] && node['redborder']['interfaces'] && !node['redborder']['interfaces'].empty?
      node['redborder']['interfaces'].each do |iface_key, iface_attrs|
        iface = iface_attrs.to_hash
        service_name = "redborder-flow-agent@#{iface_key}"

        # webui stores 'Enable'/'Disable'
        arp_ifaces.push(iface_key) if %w(Enable true).include?(iface['arp'].to_s)

        service service_name do
          supports status: true, restart: true, start: true, stop: true
          action :nothing
        end

        has_dst = iface['dstAddress'] && !iface['dstAddress'].empty?
        protocol_raw = (iface['protocol_type'] || 'NetFlow v9').to_s.downcase
        kafka = protocol_raw == 'kafka'
        observation_id = iface['observationId'] && !iface['observationId'].empty? ? iface['observationId'] : '0'
        flow_sensor = flow_agent_flow_sensor(observation_id)

        # webui stores 'Enable'/'Disable'. Interfaces saved before the switch existed
        # run when they have a destination address; span ports are enabled by default.
        enabled = case iface['flow_agent'].to_s
                  when 'Enable' then true
                  when 'Disable' then false
                  else has_dst || iface['iface_type'] == 'Span Port'
                  end
        # NetFlow and sFlow need a destination
        enabled &&= kafka || has_dst
        # Kafka flows need the flow sensor enrichment, f2k also drops flows from unknown sensors
        if enabled && kafka && flow_sensor.nil?
          Chef::Log.warn("rb-flow-agent: no flow sensor with ip #{node['ipaddress']} and observation id #{observation_id}, #{service_name} not started")
          enabled = false
        end

        if enabled
          execute "iface_restart_#{iface_key}" do
            command "ifconfig #{iface_key} down && ifconfig #{iface_key} up"
            action :nothing
          end

          template "/etc/sysconfig/network-scripts/ifcfg-#{iface_key}" do
            source 'ifcfg.erb'
            owner 'root'
            group 'root'
            cookbook 'rb-flow-agent'
            mode '0644'
            retries 2
            variables(iface: iface_key, iface_type: iface['iface_type'], iface_ip: iface['iface_ip'], iface_netmask: iface['iface_netmask'], iface_gateway: iface['iface_gateway'])
            notifies :run, "execute[iface_restart_#{iface_key}]", :immediately if iface_key != 'eth0'
          end

          # A dhclient left from when the port was DHCP keeps its IPs and default route,
          # then Ohai reports the span port as default_interface (management and capture swap)
          if iface['iface_type'] == 'Span Port' && iface_key != 'eth0'
            dhclient_pattern = "dhclient .*[[:space:]]#{iface_key}$"

            execute "span_port_stop_dhclient_#{iface_key}" do
              command "pkill -f '#{dhclient_pattern}'"
              only_if "pgrep -f '#{dhclient_pattern}'"
              returns [0, 1]
            end

            execute "span_port_flush_ipv4_#{iface_key}" do
              command "ip -4 addr flush dev #{iface_key}"
              only_if "ip -4 -o addr show dev #{iface_key} | grep -q inet"
            end
          end

          exporter_type = if kafka
                            'kafka'
                          elsif protocol_raw.include?('sflow')
                            'sflow'
                          elsif protocol_raw.include?('10') || protocol_raw.include?('ipfix')
                            'ipfix'
                          elsif protocol_raw.include?('5')
                            'netflow5'
                          else
                            'netflow9'
                          end

          dst_parts = iface['dstAddress'].to_s.split(':')
          target_host = dst_parts[0]
          default_port = (exporter_type == 'sflow') ? 6343 : 2055
          target_port = dst_parts[1] && !dst_parts[1].empty? ? dst_parts[1].to_i : default_port

          if kafka
            # Same sensor identity and enrichment f2k gave to the flows
            sensor_name = flow_sensor['rbname'] || flow_sensor.name
            sensor_ip = flow_sensor['ipaddress']
            enrichment = flow_agent_enrichment(flow_sensor)
          else
            sensor_name = node['rbname'] || 'sensor'
            sensor_ip = node['ipaddress'] || '127.0.0.1'
            enrichment = {}
          end
          home_nets = flow_agent_home_nets(flow_sensor)

          # Subnet to Observation Id: in kafka mode each subnet gets its own flow sensor identity.
          # NetFlow/sFlow only carry tag2, f2k/logstash map it to the flow sensor.
          observation_id_filters = iface['observation_id_filters'] || []
          if kafka && !split_traffic_logstash
            observation_id_filters = observation_id_filters.map(&:to_hash).filter_map do |filter|
              split_sensor = flow_agent_flow_sensor(filter['observation_id'])
              if split_sensor.nil?
                Chef::Log.warn("rb-flow-agent: no flow sensor with ip #{node['ipaddress']} and observation id #{filter['observation_id']}, #{filter['subnet']} stays on the main flow sensor of #{iface_key}")
                next
              end
              split_enrichment = flow_agent_enrichment(split_sensor)
              # The agent merges these over the main sensor's enrichment, blank what this sensor lacks
              (enrichment.keys - split_enrichment.keys).each { |k| split_enrichment[k] = '' }
              # Only one home_nets list in the agent
              home_nets |= flow_agent_home_nets(split_sensor)
              filter.merge('name' => split_sensor['rbname'] || split_sensor.name, 'sensor_ip' => split_sensor['ipaddress'], 'enrichment' => split_enrichment)
            end
          end

          # nil when not set, so the template leaves them out
          cores = iface['cores'].to_i.positive? ? iface['cores'].to_i : nil
          cpu_affinity = iface['cpu_affinity'].to_s.strip.empty? ? nil : iface['cpu_affinity'].to_s.strip
          sampling_rate = iface['sampling_rate'].to_i.positive? ? iface['sampling_rate'].to_i : nil
          # Observation domain f2k maps to the flow sensor (agent default 1001). v5 only has the
          # 8 bit engine_type for it, like rb-exporter's nfprobe_engine <id>:0. sFlow has no field.
          obs_num = observation_id.to_s =~ /\A\d+\z/ ? observation_id.to_i : nil
          obs_num = nil if obs_num && obs_num > (exporter_type == 'netflow5' ? 255 : 4_294_967_295)
          Chef::Log.warn("rb-flow-agent: observation id #{observation_id} not usable for #{exporter_type} on #{iface_key}") if obs_num.nil? && %w(netflow5 netflow9 ipfix).include?(exporter_type)

          template "#{config_dir}/#{iface_key}.yaml" do
            source 'redborder-flow-agent.yaml.erb'
            cookbook 'rb-flow-agent'
            owner 'root'
            group 'root'
            mode '0644'
            variables(
              sensor_name: sensor_name,
              sensor_ip: sensor_ip,
              enrichment: enrichment,
              iface: iface_key,
              observation_id: observation_id,
              observation_id_filters: observation_id_filters,
              split_traffic_logstash: split_traffic_logstash,
              cores: cores,
              cpu_affinity: cpu_affinity,
              exporter_type: exporter_type,
              target_host: target_host,
              target_port: target_port,
              kafka_brokers: ["kafka.service:#{node.dig('redborder', 'kafka', 'port') || 9092}"],
              kafka_topic: 'rb_flow',
              sampling_rate: sampling_rate,
              obs_num: obs_num,
              # unidirectional = upstream + downstream records like f2k (default)
              flow_mode: iface['flow_mode'].to_s.casecmp('bidirectional').zero? ? 'bidirectional' : 'unidirectional',
              home_nets: home_nets
            )
            notifies :restart, "service[#{service_name}]", :delayed
          end

          service "enable_start_#{service_name}" do
            service_name service_name
            action [:enable, :start]
          end
        else
          file "#{config_dir}/#{iface_key}.yaml" do
            action :delete
            only_if { ::File.exist?("#{config_dir}/#{iface_key}.yaml") }
          end

          service "stop_disable_#{service_name}" do
            service_name service_name
            action [:stop, :disable]
            only_if { ::File.exist?("/usr/lib/systemd/system/redborder-flow-agent@.service") }
          end
        end
      end
    end

    template '/etc/sysconfig/arpwatch' do
      source 'arpwatch.erb'
      owner 'root'
      group 'root'
      cookbook 'rb-flow-agent'
      mode '0644'
      retries 2
      variables(arp_ifaces: arp_ifaces)
      notifies :restart, 'service[arpwatch]', :delayed
    end

    service 'rsyslog' do
      supports status: true, reload: true, restart: true, start: true, enable: true
      ignore_failure true
      action [:enable, :start]
    end

    service 'arpwatch' do
      supports status: true, reload: true, restart: true, start: true, enable: true
      ignore_failure true
      action [:enable, :start]
    end

    Chef::Log.info('redborder-flow-agent cookbook has been processed')
  rescue => e
    Chef::Log.error(e.message)
  end
end

action :remove do
  begin
    config_dir = new_resource.config_dir

    (node['redborder'] && node['redborder']['interfaces'] || {}).each_key do |iface_key|
      service "stop_disable_redborder-flow-agent@#{iface_key}" do
        service_name "redborder-flow-agent@#{iface_key}"
        action [:stop, :disable]
        ignore_failure true
      end
    end

    directory config_dir do
      recursive true
      action :delete
      only_if { ::Dir.exist?(config_dir) }
    end

    Chef::Log.info('redborder-flow-agent removed')
  rescue => e
    Chef::Log.error(e.message)
  end
end
