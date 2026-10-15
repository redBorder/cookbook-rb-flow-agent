# cookbook-redborder-flow-agent

Installs and configures `redborder-flow-agent` across network interfaces on Redborder proxy/sensor nodes.

## Recipes

- `redborder-flow-agent::default`: Calls provider `redborder_flow_agent_config` to configure all network interfaces and manage systemd services `redborder-flow-agent@<iface>`.
- `redborder-flow-agent::configure_solo`: For standalone runs.

## Attributes

- `node['redborder']['interfaces']`: Hash of network interfaces containing destination IP/port, protocol, observation ID, observation filters, CPU cores, and CPU affinity.
