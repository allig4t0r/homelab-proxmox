package config

import (
	"net"
	"list"
)

#Config: {
	node_cidr: net.IPCIDR & !=cluster_pod_cidr & !=cluster_svc_cidr
	node_dns_servers?: [...net.IPv4]
	node_ntp_servers?: [...net.IPv4]
	node_default_gateway?: net.IPv4 & !=""
	node_vlan_tag?: string & !=""

	cluster_pod_cidr: *"10.42.0.0/16" | net.IPCIDR & !=node_cidr & !=cluster_svc_cidr
	cluster_svc_cidr: *"10.43.0.0/16" | net.IPCIDR & !=node_cidr & !=cluster_pod_cidr
	cluster_api_addr: net.IPv4
	cluster_api_tls_sans?: [...net.FQDN]
	cluster_domain: net.FQDN
	cluster_gateway_addr: net.IPv4 & !=cluster_api_addr & !=cluster_dns_gateway_addr
	cluster_dns_gateway_addr: net.IPv4 & !=cluster_api_addr & !=cluster_gateway_addr
	cilium_bgp_router_addr?: net.IPv4 & !=""
	cilium_bgp_router_asn?: string & !=""
	cilium_bgp_node_asn?: string & !=""
	cilium_loadbalancer_mode?: *"dsr" | "snat"

	certmanager_enabled?: bool
	flux_enabled?:        bool
	reloader_enabled?:    bool

	proxmox: {#ProxmoxConfig}
	users: {#UsersConfig}

	nodes: [...#Node]
	_nodes_check: {
		name: list.UniqueItems() & [for item in nodes {item.name}]
		address: list.UniqueItems() & [for item in nodes {item.address}]
		mac_addr?: list.UniqueItems() & [for item in nodes {item.mac_addr}]
	}
}

#ProxmoxConfig: {
	host:                 net.IPv4
	user:                 string
	ssh_private_key_path: string
	ssh_pub_key_path:     string
}

#UsersConfig: {
	default_non_root: string & !=""
	hashed_pw:        string & !=""
}

#Node: {
	name:           =~"^[a-z0-9][a-z0-9\\-]{0,61}[a-z0-9]$|^[a-z0-9]$" & !="global" & !="controller" & !="worker"
	address:        net.IPv4
	controller:     bool
	vm_id?:         number
	disk?:          string
	mac_addr?:      =~"^([0-9a-f]{2}[:]){5}([0-9a-f]{2})$"
	mtu?:            >=1450 & <=9000
	secureboot?:     bool
	encrypt_disk?:   bool
	kernel_modules?: [...string]
}

#Config
