# NPTv6-External-Updater
Shell script used to dynamically update NPTv6 external prefixes in OPNsense

## Disclaimer
This script is provided **as-is**, without any warranties. Use at your own risk.

I am not responsible for any damages, data loss, or issues caused by running this script. 
Test carefully before using in production or on critical systems.

I am bad at coding. This may or may not break things.

## Implementation
This shell script is meant to hook into `/var/etc/dhcp6c_wan_script.sh` to grab the prefix delegation at the point a lease is established.
I place it within this section:
```sh
    if [ ${REASON} != "INFOREQ" -a -n "${PDINFO}" ]; then
        ARGS=
        for PD in ${PDINFO}; do
            ARGS="${ARGS} -a ${PD}"
        done

        if /usr/local/sbin/ifctl -i igc1 -6pu ${ARGS}; then
            /usr/bin/logger -t dhcp6c "dhcp6c_script: ${REASON} on igc1 prefix now ${PDINFO}"

            # Custom NPTv6 update script
            /usr/local/sbin/update_nptv6.sh "$PDINFO"

            if [ -z "${FORCE}" ]; then
                FORCE=${REASON}
            fi
        fi
    fi
```

I want to cleanly subnet working IPv6 on my network, but my ISP (AT&T at time of writing) refuses to give me a prefix delegation other than /64 so I use IPv6 ULA with NPTv6.
Unfortunately there is no option to dynamically track my current prefix delegation to use for NPTv6's External IPv6 Prefix... which is why this script exists.
