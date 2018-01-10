# MoonGen-Scripts
This repo contains Lua scripts for the traffic generator and parser: https://github.com/emmericp/MoonGen

Some examples are provided with plenty of in-line comments to aid in learning Lua and libmoon. Production scripts are also provided.

### Todo (in order)
- [RFC2544](https://tools.ietf.org/html/rfc2544) test scripts are currently being written.
- [ITU-T Y.1564](https://en.wikipedia.org/wiki/ITU-T_Y.1564) scripts will follow.
- [RFC5180](https://tools.ietf.org/html/rfc5180) - IPv6 Benchmarking Methodology for Network Interconnect Devices.
- [RFC5695](https://tools.ietf.org/html/rfc5695) - MPLS Forwarding Benchmarking Methodology for IP Flows.

### Examples
[ethType.lua](https://github.com/jwbensley/MoonGen-Scripts/blob/master/ethType.lua) - This scripts sends every possible etherType value from 0x0000 to 0xFFFF.

#### RFC2544 Testing
[latency.lua](https://github.com/jwbensley/MoonGen-Scripts/blob/master/latency.lua) - RFC2544 latency test - Specify packet sizes to test, test duration and transmit rate. ***WORK IN PROGRESS***
[throughput.lua](https://github.com/jwbensley/MoonGen-Scripts/blob/master/throughput.lua) - RFC2544 throughput test - Specify the packet sizes to test, the test duration and transmit rate.  ***WORK IN PROGRESS***
