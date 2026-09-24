# Problem Context & Bug Analysis: BusyBox `ifupdown` Missing DHCPv6 (`udhcpc6`) Support

## 1. Summary of Issue

When configuring dual-stack IPv4/IPv6 networking on Alpine Linux using BusyBox's built-in `ifupdown` applet (`/sbin/ifup`, `/sbin/ifdown`), defining stateful DHCPv6 in `/etc/network/interfaces` via standard notation:

```text
auto eth0
iface eth0 inet dhcp
iface eth0 inet6 dhcp
```

fails because the BusyBox `ifupdown` applet does **not** implement a `dhcp` method under the `inet6` address family. 

As a result, users running minimal cloud images (such as Alpine on Google Cloud Platform, AWS, or Azure) are forced to either:
1. Re-introduce heavyweight external daemons like `dhcpcd` (which runs multiple processes consuming ~5MB RSS).
2. Or resort to ad-hoc workarounds using `post-up` hooks:
   ```text
   auto eth0
   iface eth0 inet dhcp
       post-up udhcpc6 -R -b -p /var/run/udhcpc6.eth0.pid -i eth0 -s /usr/share/udhcpc/default6.script
   ```

BusyBox already implements the DHCPv6 client applet (`CONFIG_UDHCPC6=y`, source: `networking/udhcp/d6_dhcpc.c`), but its `ifupdown` applet (`networking/ifupdown.c`) lacks the binding table entry to invoke it.

---

## 2. Cloud Environment & Empirical Reproduction Findings (Google Compute Engine)

In cloud environments like Google Cloud VPC (and AWS dual-stack subnets):
- **Router Advertisements (NDP)**: GCE virtual routers (`fe80::4001:aff:fe00:201`) send ICMPv6 RAs with the Managed flag set (`M=1`) and Autonomous flag unset (`A=0`).
- **Kernel SLAAC**: The Linux kernel handles RAs automatically, installing link-local `fe80::/64` addresses and the default IPv6 route (`::/0 via fe80::4001:aff:fe00:201`).
- **Stateful Lease Requirement**: Global IPv6 addresses (e.g. `2600:1900:4000:1bec:0:7::/128`) are distributed via stateful DHCPv6 over UDP port 546/547.
- **Empirical Validation**: Live tests running BusyBox `udhcpc6` v1.37.0 demonstrated successful acquisition of the `/128` lease with under 100 KB total private RAM overhead. All network functionality works cleanly once `udhcpc6` is executed; only the `ifupdown` integration is missing.

---

## 3. Suspected Code Location in Upstream BusyBox

Repository: `git://busybox.net/busybox.git` (or mirror `https://github.com/mirror/busybox`)  
Target File: **`networking/ifupdown.c`**

### Current Implementation Details:

1. **IPv4 Method Table (`ext_inet_methods[]`)**:
   Under `inet`, `dhcp` is registered with commands executing `udhcpc`:
   ```c
   #if ENABLE_FEATURE_IFUPDOWN_IPV4
   static const struct method_t ext_inet_methods[] = {
   # if ENABLE_FEATURE_IFUPDOWN_EXTERNAL_DHCP
       ...
   # else
       { "dhcp",
           "udhcpc -R -n -p /var/run/udhcpc.%iface%.pid -i %iface% [[-H %hostname%]] [[-c %client%]] [[-s %script%]]",
           "kill -TERM `cat /var/run/udhcpc.%iface%.pid`",
       },
   # endif
   ```

2. **IPv6 Method Table (`ext_inet6_methods[]`)**:
   Under `inet6`, only `static`, `manual`, and `v4tunnel` methods are declared:
   ```c
   #if ENABLE_FEATURE_IFUPDOWN_IPV6
   static const struct method_t ext_inet6_methods[] = {
       { "static",
           "ip addr add %address%/%netmask% dev %iface%[[ preferred_lft %preferred-lft%]][[ valid_lft %valid-lft%]]",
           "ip addr del %address%/%netmask% dev %iface%",
       },
       { "manual",
           "ip link set %iface% up",
           "ip link set %iface% down",
       },
       { "v4tunnel",
           ...
       },
   };
   ```
   **`dhcp` is completely absent from `ext_inet6_methods[]`.**

---

## 4. Proposed Solution & Patch Guidance

To add native DHCPv6 support when `CONFIG_UDHCPC6` and `CONFIG_FEATURE_IFUPDOWN_IPV6` are enabled:

### A. Add `dhcp` method to `ext_inet6_methods[]`
Under `networking/ifupdown.c`:
```c
#if ENABLE_FEATURE_IFUPDOWN_IPV6
static const struct method_t ext_inet6_methods[] = {
# if ENABLE_UDHCPC6
    { "dhcp",
        "udhcpc6 -R -n -p /var/run/udhcpc6.%iface%.pid -i %iface% [[-s %script%]]",
        "kill -TERM `cat /var/run/udhcpc6.%iface%.pid`",
    },
# endif
    { "static", ... },
...
```

### B. Verify Config Options & Dependencies
- Guard with `#if ENABLE_UDHCPC6` (or appropriate configuration macro).
- Check if default script fallback logic should default to `/usr/share/udhcpc/default6.script` or standard fallback if `[[-s %script%]]` is not provided.

### C. Verify `ifdown` Handling
- Ensure `ifdown` executes the release/termination signal against `/var/run/udhcpc6.%iface%.pid` cleanly without leaving orphaned DHCPv6 client processes.
