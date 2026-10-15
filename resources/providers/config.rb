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
      node['redborder']['interfaces'].each do |iface_key, _orig_iface|
        iface = node['redborder']['interfaces'][iface_key].to_hash.clone
        service_name = "redborder-flow-agent@#{iface_key}"

        # webui stores 'Enable'/'Disable'
        arp_ifaces.push(iface_key) if %w(Enable true).include?(iface['arp'].to_s)

        service service_name do
          supports status: true, restart: true, start: true, stop: true
          action :nothing
        end

        if iface['dstAddress'] && !iface['dstAddress'].empty?
          execute "iface_restart_#{iface_key}" do
            command "ifconfig #{iface_key} down && ifconfig #{iface_key} up"
            ignore_failure false
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

          dst_parts = iface['dstAddress'].to_s.split(':')
          target_host = dst_parts[0]
          protocol_raw = (iface['protocol_type'] || 'NetFlow v9').to_s.downcase

          exporter_type = if protocol_raw.include?('sflow')
                            'sflow'
                          elsif protocol_raw.include?('10') || protocol_raw.include?('ipfix')
                            'ipfix'
                          elsif protocol_raw.include?('5')
                            'netflow5'
                          else
                            'netflow9'
                          end

          default_port = (exporter_type == 'sflow') ? 6343 : 2055
          target_port = dst_parts[1] && !dst_parts[1].empty? ? dst_parts[1].to_i : default_port

          observation_id = iface['observationId'] && !iface['observationId'].empty? ? iface['observationId'] : '0'
          observation_id_filters = iface['observation_id_filters'] || []
          home_nets = flow_agent_home_nets(observation_id)

          template "#{config_dir}/#{iface_key}.yaml" do
            source 'redborder-flow-agent.yaml.erb'
            cookbook 'rb-flow-agent'
            owner 'root'
            group 'root'
            mode '0644'
            variables(
              sensor_name: node['rbname'] || 'sensor',
              sensor_ip: node['ipaddress'] || '127.0.0.1',
              iface: iface_key,
              observation_id: observation_id,
              observation_id_filters: observation_id_filters,
              split_traffic_logstash: split_traffic_logstash,
              cores: iface['cores'],
              cpu_affinity: iface['cpu_affinity'],
              exporter_type: exporter_type,
              target_host: target_host,
              target_port: target_port,
              sampling_rate: iface['sampling_rate'],
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
