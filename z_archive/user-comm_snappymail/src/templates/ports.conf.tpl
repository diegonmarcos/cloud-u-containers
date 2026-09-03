# Apache ports.conf override — bind to WG IP only.
# @LISTEN_ADDRESS@ + @PORT@ come from container.bind_host (cloud-data
# resolveBindHost) and buildJson.ports.app — keeps host-net listener off
# 0.0.0.0. Mounted RO into /etc/apache2/ports.conf via compose.nix.
Listen @LISTEN_ADDRESS@:@PORT@
