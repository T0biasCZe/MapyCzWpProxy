Mapy.cz proxy for Windows Phone client, which doesnt support modern HTTPS certificates properly, and thus cant connect directly.

Two options for setup:
1) Through PHP page, that runs on your web server, for example on nginx
2) Powershell script, that can run on any Windows desktop computer.

# PHP setup
1) Download the index.php file
2) Copy it to your webserver, and rename as needed. For example, lets say I copied it to mapyczproxy.php to \www\tools\
3) the proxy will be available on https://yourdomain.eu/tools/mapyczproxy.php
4) Go to the WP client settings, and enter this URL to the textbox at the bottom

# Powershell setup
1) Download the runproxy.ps1 file
2) Right click and click Run with powershell
3) Allow administrator permission. This is needed to be able to start webserver.
4) It will show IP address. Usually it starts with 192.168.x.x for home networks, for example, http://192.168.68.254:8080/
5) Go to WP client settings, and enter this URL to the textbox at the bottom.

***Note:*** This method will work only if the phone is on the same network as the PC.
To be able to use this across the internet, you will need to:
1) port forward the Powershell server on your router, and have a public IPv4 address.
2) Use Cloudflared server
3) find some other public proxy
