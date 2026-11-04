module RbFlowAgent
  module Helper
    # Same location/organization fields f2k adds to the flows (cookbook-f2k f2k_template_renderer.rb)
    ENRICHMENT_FIELDS = %w(sensor_uuid deployment deployment_uuid namespace namespace_uuid market market_uuid
                           organization organization_uuid service_provider service_provider_uuid campus
                           campus_uuid building building_uuid floor floor_uuid).freeze

    # Agent settings the webui can change per interface; their defaults are attributes of resources/config.rb
    SETTINGS = %w(promiscuous snaplen workers_per_interface buffer_size_mb track_open_ports track_tcp_metrics
                  extract_tls_sni extract_tls_version extract_http_host extract_http_details extract_dns_domains
                  dns_cache_size active_timeout_sec inactive_timeout_sec max_active_flows shards engine_id
                  template_interval_sec batch_size compression stats_socket stats_http_addr).freeze

    # Interface value cast to the default's type, the resource default when not set
    def flow_agent_settings(iface)
      SETTINGS.each_with_object({}) do |key, settings|
        default = new_resource.send(key)
        value = iface[key]
        settings[key] = if value.nil? || value.to_s.strip.empty?
                          default
                        elsif [true, false].include?(default)
                          [true, 'true', 'Enable', '1'].include?(value)
                        elsif default.is_a?(Integer)
                          value.to_i.positive? ? value.to_i : default
                        else
                          value.to_s.strip
                        end
      end
    end

    def flow_agent_flow_sensors
      search(:node, 'role:flow-sensor')
    rescue => e
      Chef::Log.warn("rb-flow-agent: could not load flow sensors: #{e.message}")
      []
    end

    # Flow sensor that receives this exporter's traffic.
    # Same match f2k uses: flow sensor ipaddress == exporter ip and same observation id.
    def flow_agent_flow_sensor(observation_id)
      obs_id = observation_id.to_s.empty? || observation_id.to_s == '0' ? 'default' : observation_id.to_s
      flow_agent_flow_sensors.find do |n|
        n_obs = n.dig('redborder', 'observation_id').to_s
        n_obs = 'default' if n_obs.empty?
        n['ipaddress'] == node['ipaddress'] && n_obs == obs_id
      end
    end

    # The agent always treats private ranges (RFC 1918, RFC 6598, ULA) as home, these come on top
    def flow_agent_home_nets(flow_sensor)
      (flow_sensor && flow_sensor.dig('redborder', 'homenets') || []).map { |h| h['value'] }.compact
    end

    # Fields f2k used to add, now added by the agent itself when it writes to kafka
    def flow_agent_enrichment(flow_sensor)
      redborder = flow_sensor['redborder'] || {}
      enrichment = {
        'index_partitions' => (redborder['index_partitions'] || new_resource.index_partitions).to_s,
        'index_replicas' => (redborder['index_replicas'] || new_resource.index_replicas).to_s,
      }
      ENRICHMENT_FIELDS.each do |field|
        enrichment[field] = redborder[field].to_s if redborder[field] && !redborder[field].to_s.empty?
      end
      enrichment
    end

    # Split traffic rows ({subnet, sensor_uuid}) to agent sensors: one entry per flow sensor, its subnets
    # grouped, in the order the rows were added. Rows of a deleted flow sensor stay on the main sensor.
    # Returns [sensors, flow sensor nodes used].
    def flow_agent_split_sensors(rows, main_enrichment)
      flow_sensors = flow_agent_flow_sensors
      subnets = {} # uuid => subnets, insertion order = row order
      nodes = {}
      rows.each do |row|
        uuid = row['sensor_uuid'].to_s
        subnet = row['subnet'].to_s
        next if uuid.empty? || subnet.empty?

        nodes[uuid] ||= flow_sensors.find { |n| n.dig('redborder', 'sensor_uuid') == uuid }
        if nodes[uuid].nil?
          Chef::Log.warn("rb-flow-agent: no flow sensor with uuid #{uuid}, #{subnet} stays on the main flow sensor")
          nodes.delete(uuid)
          next
        end
        (subnets[uuid] ||= []) << subnet
      end

      sensors = subnets.map do |uuid, sensor_subnets|
        flow_sensor = nodes[uuid]
        enrichment = flow_agent_enrichment(flow_sensor)
        # The agent merges these over the main sensor's enrichment, blank what this sensor lacks
        (main_enrichment.keys - enrichment.keys).each { |k| enrichment[k] = '' }
        { 'name' => flow_sensor['rbname'] || flow_sensor.name, 'sensor_ip' => flow_sensor['ipaddress'].to_s,
          'subnets' => sensor_subnets.uniq, 'enrichments' => enrichment }
      end
      [sensors, nodes.values]
    end
  end
end
