# cookbook-redborder-flow-agent

Installs and configures `redborder-flow-agent` across network interfaces on Redborder proxy/sensor nodes.

## Recipes

- `rb-flow-agent::default`: Calls the resource `rb_flow_agent_config` to configure all network interfaces and manage the systemd services `redborder-flow-agent@<iface>`. The proxy, IPS and intrusion cookbooks call the resource directly.

## Attributes

- `node['redborder']['interfaces']`: Hash of network interfaces containing destination IP/port, protocol, observation ID, CPU cores and affinity, `home_nets`, `split_subnets` (`{subnet, sensor_uuid}` rows, redborder output only) and the agent settings. The config file is always written in full.
- `resources/config.rb`: Defaults used when an interface doesn't set a value (agent settings, output, ports, user, paths).
- `files/default/ja4_signatures.yaml`: JA4 signature database installed to `/etc/redborder-flow-agent/ja4_signatures.yaml` (the agent package doesn't ship it). Update the signatures here.
