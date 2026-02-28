# Appliances
OrbitLab's Infrastructure LXC Appliances


## Sector Gateway LXC

The Sector Gateway is a lightweight LXC based on debian/trixie used by OrbitLab to provide the routing logic between a user's Sector and OrbitLab's Backplane. It does this by implementing `frr` and `nftables` to provide routing and NAT-ing, respectively. 

Also, to reduce friction when attaching new instances to the network, the gateway appliance utilizes Dnsmasq for DHCP only, reserving the first 50 and last 5 IP addresses for infrastructure purposes. This is integrated with CoreDNS for actual DNS resolution within the sector, where the leases created by Dnsmasq are served by CoreDNS. 

CoreDNS uses the `/var/local/dnsmasq/sector.hosts` file generated and maintained by Dnsmasq as the authoritative zone file for its designated Sector's `sector.internal` domain. For instance, a VM/LXC created with a hostname of `my-compute`, will get an automatic DNS A record entry of `my-compute.sector.internal` that is resolvable within the Sector. The `/var/local/dnsmasq/sector.hosts` has a reload interval of 5 seconds, so the record will be loaded and served after a max of that interval or earlier. Should a host within the Sector need to resolve external domains (e.g. `example.com`), CoreDNS forwards all non-`sector.internal` domain requests to the [Backplane DNS](https://github.com/OrbitLab-OSS/BackplaneDNS).

Since the Sector network itself is isolated because of the Backplane, user's can use large volume CIDR blocks (as long as there's ZERO overlap with the Backplane network established during bootstrap discovery). Meaning, if the Backplane uses `10.200.0.0/16`, you can set multiple sectors to the same `192.168.0.0/16`, `172.16.0.0/16`, or even `10.0.0.0/10` (which encompasses `10.0.0.0` - `10.63.255.25`). Because the Backplane provides the isolation between each sector and handles traffic routing, you can create as many overlapping networks as desired without fear of collisions and packet drops.


### Architecture

There are 3 `eth` devices created on the LXC at launch:

- **eth0**: Connects to Sector network as its default gateway (FRR and nftables)
- **eth1**: Connects to OrbitLab's Backplane for ingress/egress routing (FRR and nftables)
- **eth2**: Acts as Sector network's DNS (bound by CoreDNS)


Traffic flow:
1. Sector traffic routes through eth0 to the gateway
2. NAT translation occurs for Backplane communication
3. Default route directs traffic via eth1 to Backplane gateway
4. Return traffic is reverse-NAT'd back to sector networks
