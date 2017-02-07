#!/bin/sh
cat >> /usr/bin/ping_forever_outside << EOF
  #!/bin/sh

  trap "" 1
  failed=0
  date -Iseconds > /var/log/ping_outside.out

  while [ 1 = 1 ]; do
      if ping @outside_ip@ -W 1 -w 1 > /dev/null ; then
          if [ "\$failed" -gt "0" ]; then
              date -Iseconds >> /var/log/ping_outside.out
              echo "@outside_ip@ not available for: \$failed" >> /var/log/ping_outside.out
              failed=0
          fi
      else
          failed=\$((failed + 1))
      fi
  done
EOF

chmod +x /usr/bin/ping_forever_outside
/usr/bin/ping_forever_outside &

cat >> /usr/bin/ping_forever_neighbour << EOF
  #!/bin/sh

  trap "" 1
  failed=0
  date -Iseconds > /var/log/ping_neighbour.out

  while [ 1 = 1 ]; do
      if ping @neighbour_ip@ -W 1 -w 1 > /dev/null ; then
          if [ "\$failed" -gt "0" ]; then
              date -Iseconds >> /var/log/ping_neighbour.out
              echo "@neighbour_ip@ not available for: \$failed" >> /var/log/ping_neighbour.out
              failed=0
          fi
      else
          failed=\$((failed + 1))
      fi
  done
EOF
chmod +x /usr/bin/ping_forever_neighbour
/usr/bin/ping_forever_neighbour &
