    Author:        Markus Stenberg <markus.stenberg@iki.fi>, cisco Systems, Inc.
    Created:       Tue Nov  6 16:10:45 2012 mstenber
    Last modified: Wed Nov  7 10:20:17 2012 mstenber
    Edit time:     40 min

hnet (core) package
===================

(c) cisco Systems, Inc., 2012

License: See COPYING - GPLv2.

This package provides implementation of IP routing, prefix assignment and
service discovery for a home network consisting of multiple routers
connected to multiple service providers. Implementation is based upon (but
not limited to) the following IETF Internet Draft documents being discussed
within the IETF Homenet Working Group:

* [draft-arkko-homenet-prefix-assignment-03][D1]
* [draft-acee-ospf-ospfv3-autoconfig-03.txt][D2]

# Features

* Partial duplicate router ID detection (some parts of it have to happen
  elsewhere, as we only handle the LSAs that have been accepted by the
  OSPFv3 implementation; [Bird with external LSA support][P1] has the rest)

* Prefix assignment algorithm (for IPv4, IPv6)

* DHCP, DHCPv6 option propagation

* IPv4 address assignment for routers

* Source routing which works for multihoming

# Contents

* elsa_pa.lua - entry point for the external LSA handling code within
  [Bird with external LSA support][P1]. The contents of this repository
  should be within LUA_PATH for it to work.

* pm.lua - stand-alone prefix manager process, which receives state
  information from within OSPF process, and configures the assorted daemons
  on a system, as well as IPv4 addresses, IPv6 routes, ..

# Requirements on a device

Currently the code depends on Lua 5.1 being available. While some of the
third-party Lua modules required are included within this package under
thirdparty/, some others are also needed:

- [luasocket][L1], which is only C-based hard dependency within Lua code

- [vstruct][L2] 

- [md5][L3] is optional - but makes things much faster

In addition to this package, some other packages are needed: 

* [Bird with external LSA support][P1]

* ISC dhclient
  
* rdisc6 to find next hop

* iproute2 tool (ip)

* ISC DHCPv4 server - if DHCPv4 address assignment on homenet links is
  desired
  
* ISC DHCPv6 server - if stateless/stateful DHCPv6 is desired on homenet
  links

* radvd 

# How to run the unit tests

Only the lua dependencies mentioned earlier, and
[busted testing framework][L4] is needed. To install Lua on typical Debian
derivative:

    apt-get install luarocks liblua5.1-dev

Typically, convenient way of
doing this is on a host is just to use luarocks:


    luarocks install busted
    luarocks install luasocket
    luarocks install md5 # optional
    luarocks install luacov # optional

.. and then just 'make', assuming [state machine compiler][L5] is available
somewhere within PATH.

# How to run on a Linux device

Disclaimer: This repository contains just the source code, and some utility
scripts for hnet. An OpenWrt feed, which makes this easier to install,
exists, but hasn't been published yet (it also packages
[Bird with external LSA support][P1], md5, and other lua dependencies
OpenWrt does not yet provide).

Anyway, here's some notes..

* This package's contents need to be in LUA_PATH, of a
[Bird with external LSA support][P1].

* The pm.lua should be started separately.

* ISC DHCPv6 client with prefix delegation should be started on
all upstream interfaces (e.g. dhclient -nw -P <ifname>). The dhclient
should provide learned prefix information, and next hop router information
to elsa_pa using skvtool.lua stand-alone key-value manipulation tool, like
this:

> skvtool.lua pd-prefix.eth0=2001:db8::/56

> skvtool.lua pd-prefix.nh=aa:bb:cc:dd:ee:ff

Additionally many other DHCPv4/v6 fields can be passed along too; see
elsa_pa.lua for a list.

Credits
-------

* Ole Troan <ot@cisco.com> - a lot of input on how some aspects of the
system should work.

* Mark Townsley <townsley@cisco.com> - for driving ambitious set of goals
  even for the initial release. 

* Dave Tath <dave.tath@gmail.com> - for providing all the input on OpenWrt
  and open source packages to use at the start of this effort, and insights
  on state of Linux.

* Jari Arkko <jari.arkko@piuha.net> - bugfixing help with the
  implementation.

[D1]: http://tools.ietf.org/html/draft-arkko-homenet-prefix-assignment
[D2]: http://tools.ietf.org/html/draft-ietf-ospf-ospfv3-autoconfig-00
[P1]: https://github.com/fingon/bird-ext-lsa
[L1]: http://w3.impa.br/~diego/software/luasocket/
[L2]: https://github.com/ToxicFrog/vstruct
[L3]: https://github.com/keplerproject/md5.git
[L4]: http://olivinelabs.com/busted/
[L5]: http://smc.sourceforge.net
