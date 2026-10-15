module RbFlowAgent
  module Helper
    DEFAULT_HOME_NETS = %w(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16).freeze

    # Home nets of the flow sensor that receives this exporter's traffic.
    # Same match f2k uses: flow sensor ipaddress == exporter ip and same observation id.
    def flow_agent_home_nets(observation_id)
      obs_id = observation_id.to_s.empty? || observation_id.to_s == '0' ? 'default' : observation_id.to_s
      flow_sensor = search(:node, 'role:flow-sensor').find do |n|
        n_obs = n.dig('redborder', 'observation_id').to_s
        n_obs = 'default' if n_obs.empty?
        n['ipaddress'] == node['ipaddress'] && n_obs == obs_id
      end
      nets = (flow_sensor && flow_sensor.dig('redborder', 'homenets') || []).map { |h| h['value'] }.compact
      nets.empty? ? DEFAULT_HOME_NETS : nets
    rescue => e
      Chef::Log.warn("rb-flow-agent: could not load flow sensor home nets: #{e.message}")
      DEFAULT_HOME_NETS
    end
  end
end
