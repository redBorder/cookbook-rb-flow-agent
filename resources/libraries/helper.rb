module RbFlowAgent
  module Helper
    DEFAULT_HOME_NETS = %w(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16).freeze

    # Same location/organization fields f2k adds to the flows (cookbook-f2k f2k_template_renderer.rb)
    ENRICHMENT_FIELDS = %w(sensor_uuid deployment deployment_uuid namespace namespace_uuid market market_uuid
                           organization organization_uuid service_provider service_provider_uuid campus
                           campus_uuid building building_uuid floor floor_uuid).freeze

    # Flow sensor that receives this exporter's traffic.
    # Same match f2k uses: flow sensor ipaddress == exporter ip and same observation id.
    def flow_agent_flow_sensor(observation_id)
      obs_id = observation_id.to_s.empty? || observation_id.to_s == '0' ? 'default' : observation_id.to_s
      search(:node, 'role:flow-sensor').find do |n|
        n_obs = n.dig('redborder', 'observation_id').to_s
        n_obs = 'default' if n_obs.empty?
        n['ipaddress'] == node['ipaddress'] && n_obs == obs_id
      end
    rescue => e
      Chef::Log.warn("rb-flow-agent: could not load flow sensor: #{e.message}")
      nil
    end

    def flow_agent_home_nets(flow_sensor)
      nets = (flow_sensor && flow_sensor.dig('redborder', 'homenets') || []).map { |h| h['value'] }.compact
      nets.empty? ? DEFAULT_HOME_NETS : nets
    end

    # Fields f2k used to add, now added by the agent itself when it writes to kafka
    def flow_agent_enrichment(flow_sensor)
      redborder = flow_sensor['redborder'] || {}
      enrichment = {
        'index_partitions' => (redborder['index_partitions'] || 5).to_s,
        'index_replicas' => (redborder['index_replicas'] || 1).to_s,
      }
      ENRICHMENT_FIELDS.each do |field|
        enrichment[field] = redborder[field].to_s if redborder[field] && !redborder[field].to_s.empty?
      end
      enrichment
    end
  end
end
