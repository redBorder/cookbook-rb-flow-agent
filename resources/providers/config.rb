# Cookbook:: rb-flow-agent
# Provider:: config

include RbFlowAgent::Helper

action :add do
  begin
    config_dir = new_resource.config_dir
    user = new_resource.user
    log_dir = new_resource.log_dir
    ja4_signatures_file = new_resource.ja4_signatures_file
    kafka_brokers = ["kafka.service:#{node.dig('redborder', 'kafka', 'port') || new_resource.kafka_port}"]

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

    # Run the agent as its own user, like f2k. The package unit runs as root, a drop-in overrides it;
    # CAP_NET_RAW/CAP_NET_ADMIN from the package unit are enough to capture.
    execute 'create_redborder-flow-agent_user' do
      command "/usr/sbin/useradd -r -M -s /sbin/nologin #{user}"
      not_if "getent passwd #{user}"
    end

    directory log_dir do
      owner user
      group user
      mode '0750'
    end

    execute 'redborder-flow-agent_daemon_reload' do
      command 'systemctl daemon-reload'
      action :nothing
    end

    execute 'redborder-flow-agent_restart_instances' do
      command "systemctl try-restart 'redborder-flow-agent@*.service'"
      action :nothing
    end

    # JA4 signature database the configs point to. The cookbook owns it, the package doesn't
    # ship it; updated signatures reach the sensors with the cookbook.
    cookbook_file ja4_signatures_file do
      source 'ja4_signatures.yaml'
      cookbook 'rb-flow-agent'
      owner 'root'
      group 'root'
      mode '0644'
      notifies :run, 'execute[redborder-flow-agent_restart_instances]', :delayed
    end

    directory '/etc/systemd/system/redborder-flow-agent@.service.d' do
      mode '0755'
    end

    # Only root can create the stats socket in /var/run, the user gets its own runtime dir.
    # No --stats-socket here: that flag forces stats on, the config (stats.enabled / socket_path) decides.
    file '/etc/systemd/system/redborder-flow-agent@.service.d/10-user.conf' do
      content <<~UNIT
        [Service]
        User=#{user}
        Group=#{user}
        RuntimeDirectory=redborder-flow-agent-%i
        ExecStart=
        ExecStart=/usr/bin/redborder-flow-agent --config #{config_dir}/%i.yaml
      UNIT
      owner 'root'
      group 'root'
      mode '0644'
      notifies :run, 'execute[redborder-flow-agent_daemon_reload]', :immediately
      notifies :run, 'execute[redborder-flow-agent_restart_instances]', :delayed
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
        protocol_raw = (iface['protocol_type'] || new_resource.protocol_type).to_s.downcase
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

          # Collector ip:port (export), the kafka output doesn't use it
          target_host, target_port = iface['dstAddress'].to_s.split(':')
          target_host = new_resource.target_host if target_host.to_s.empty?
          target_port = (exporter_type == 'sflow' ? new_resource.sflow_port : new_resource.netflow_port) if target_port.to_s.empty?

          if kafka
            # Same sensor identity and enrichment f2k gave to the flows
            sensor_name = flow_sensor['rbname'] || flow_sensor.name
            sensor_ip = flow_sensor['ipaddress']
            enrichment = flow_agent_enrichment(flow_sensor)
          else
            sensor_name = node['rbname'] || new_resource.sensor_name
            sensor_ip = node['ipaddress']
            enrichment = {}
          end
          # Split traffic: subnets to other flow sensors, only with kafka (NetFlow / sFlow can't carry a sensor)
          split_sensors, split_nodes = kafka ? flow_agent_split_sensors((iface['split_subnets'] || []).map(&:to_hash), enrichment) : [[], []]

          # Home nets of the interface are added to the flow sensors' ones (main and split); one list in the agent
          home_nets = Array(iface['home_nets']).map(&:to_s).reject(&:empty?)
          ([flow_sensor] + split_nodes).each { |n| home_nets |= flow_agent_home_nets(n) }
          settings = flow_agent_settings(iface)
          # Socket and HTTP are independent: the agent opens each only when its address is set
          stats_socket_path = settings['stats_socket'] ? "/run/redborder-flow-agent-#{iface_key}/stats.sock" : ''

          cores = iface['cores'].to_i.positive? ? iface['cores'].to_i : new_resource.cores
          sampling_rate = iface['sampling_rate'].to_i.positive? ? iface['sampling_rate'].to_i : new_resource.sampling_rate
          # Observation domain f2k maps to the flow sensor. v5 only has the 8 bit engine_type for it,
          # like rb-exporter's nfprobe_engine <id>:0; v9 / IPFIX the source_id. sFlow has no field.
          obs_num = observation_id.to_s =~ /\A\d+\z/ ? observation_id.to_i : nil
          obs_num = nil if obs_num && obs_num > (exporter_type == 'netflow5' ? 255 : 4_294_967_295)
          Chef::Log.warn("rb-flow-agent: observation id #{observation_id} not usable for #{exporter_type} on #{iface_key}") if obs_num.nil? && %w(netflow5 netflow9 ipfix).include?(exporter_type)
          engine_type = obs_num && exporter_type == 'netflow5' ? obs_num : new_resource.engine_type
          source_id = obs_num && %w(netflow9 ipfix).include?(exporter_type) ? obs_num : new_resource.source_id
          # unidirectional = upstream + downstream records like f2k (default); bidirectional only
          # with kafka, NetFlow / IPFIX / sFlow count one direction per record
          flow_mode = kafka && iface['flow_mode'].to_s.casecmp('bidirectional').zero? ? 'bidirectional' : new_resource.flow_mode

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
              home_nets: home_nets,
              split_sensors: split_sensors,
              cores: cores,
              cpu_affinity: iface['cpu_affinity'].to_s.strip,
              iface: iface_key,
              settings: settings,
              stats_socket_path: stats_socket_path,
              ja4_signatures_file: ja4_signatures_file,
              flow_mode: flow_mode,
              exporter_type: exporter_type,
              target_host: target_host,
              target_port: target_port.to_i,
              engine_type: engine_type,
              source_id: source_id,
              sampling_rate: sampling_rate,
              kafka_brokers: kafka_brokers,
              kafka_topic: new_resource.kafka_topic
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
            only_if { ::File.exist?('/usr/lib/systemd/system/redborder-flow-agent@.service') }
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

    directory '/etc/systemd/system/redborder-flow-agent@.service.d' do
      recursive true
      action :delete
      notifies :run, 'execute[redborder-flow-agent_daemon_reload]', :immediately
    end

    execute 'redborder-flow-agent_daemon_reload' do
      command 'systemctl daemon-reload'
      action :nothing
    end

    Chef::Log.info('redborder-flow-agent removed')
  rescue => e
    Chef::Log.error(e.message)
  end
end
