#! /usr/bin/python
import random

# To avoid generation of persistent NIC device names in udev's configuration
# accross reboots let's assign a MAC address out of VMware's range as it's
# known to be ignored by /lib/udev/rules.d/75-persistent-net-generator.rules ->
# ENV{MATCHADDR}=="00:0c:29:*|00:50:56:*", ENV{MATCHADDR}=""

mac = [ 0x00, 0x0c, 0x29,
  random.randint(0x00, 0x7f),
  random.randint(0x00, 0xff),
  random.randint(0x00, 0xff) ]

print ':'.join(map(lambda x: "%02x" % x, mac))
