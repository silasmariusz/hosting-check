#!/bin/bash
#
# Hosting (webspace) checker
#
# VERSION       :0.3.1
# DATE          :2014-09-02
# AUTHOR        :Viktor Szépe <viktor@szepe.net>
# LICENSE       :The MIT License (MIT)
# URL           :https://github.com/szepeviktor/hosting-check
# DEPENDS       :apt-get install lftp bind9-host whois
# DEPENDS2      :apt-get install curl bind9-host whois
# EXTRA         :pip install ansi2html
# BASH-VERSION  :4.2+


# SETTINGS
# ========
#
# URL with trailing slash
HC_SITE="http://SITE.URL/"
# FTP access
HC_FTP_HOST="FTPHOST"
HC_FTP_PORT="21"
HC_FTP_WEBROOT="/public_html"
HC_FTP_USER="FTPUSER"
HC_FTP_PASSWORD='FTPPASSWORD'
HC_FTP_ENABLE_TLS="1"
HC_MAILSERVER_IP="MAIN_SMTP_IP"
HC_TIMEZONE="Europe/Budapest"


[ -r .hcrc ] && . .hcrc

#######################

HC_VERSION="0.3"
HC_FTP_USERPASS="${HC_FTP_USER},${HC_FTP_PASSWORD}"
HC_SECRETKEY="$(echo "$RANDOM" | md5sum | cut -d' ' -f1)"
HC_DOMAIN="$(sed -r 's|^.*[./]([^./]+\.[^./]+).*$|\1|' <<< "$HC_SITE")"
HC_HOST="$(sed -r 's|^(([a-z]+:)?//)?([a-z0-9.-]+)/.*$|\3|' <<< "$HC_SITE")"
HC_LOG="hc_${HC_HOST//[^a-z]}.vars.log"
HC_DIR="hosting-check/"
HC_UA='Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:24.0) Gecko/20140419 Firefox/24.0 hosting-check/'"$HC_VERSION"
HC_CABUNDLE="/etc/ssl/certs/ca-certificates.crt"
HC_BENCHMARK_VALUES="$(mktemp)"
HC_LOCK="$(mktemp)"
HC_PROTOCOL="ftp://"
# curl or lftp
HC_CURL="1"
which lftp &> /dev/null && HC_CURL="0"
# for printf decimals
export LC_NUMERIC=C

# prepare as multiplied integer without decimal point
fullint() {
    local A="$1"
    local DECIMALS="$2"
    local A_DEC

    # fixed number of decimals
    printf -v A_DEC "%.${DECIMALS}f" "$A"
    # remove dot
    A_DEC="${A_DEC/./}"
    # trim leading zero
    printf "%.0f" "$A_DEC"
}

add() {
    local A="$1"
    local B="$2"
    local DECIMALS="$3"
    local A_FULL
    local B_FULL
    local SUM_FULL
    local TRIM_END

    [ -z "$DECIMALS" ] && DECIMALS="3"

    A_FULL="$(fullint "$A" "$DECIMALS")"
    B_FULL="$(fullint "$B" "$DECIMALS")"
    # should be at least DECIMALS digits
    printf -v SUM_FULL "%0${DECIMALS}d" $((A_FULL + B_FULL))

    # stripping and .adding this many digits: DECIMALS
    #old bash throws error: printf "%.${DECIMALS}f" "${SUM_FULL:0:(-${DECIMALS})}.${SUM_FULL:(-${DECIMALS})}"
    #slow: printf -v TRIM_END '?%.0s' $(seq 1 ${DECIMALS})
    printf -v TRIM_END "%*s" "$DECIMALS"
    TRIM_END="${TRIM_END// /?}"
    printf "%.${DECIMALS}f" "${SUM_FULL%$TRIM_END}.${SUM_FULL:(-${DECIMALS})}"
}

divide() {
    local A="$1"
    local B="$2"
    local DECIMALS="$3"
    local A_FULL
    local B_FULL
    local SUM_FULL
    local TRIM_END

    [ -z "$DECIMALS" ] && DECIMALS="0"

    A_FULL="$(fullint "$A" "$DECIMALS")"
    # multiply by 10^DECIMALS for precision
    A_FULL="$((A_FULL * $(printf "%.0f" "1e${DECIMALS}") ))"

    B_FULL="$(fullint "$B" "$DECIMALS")"

    # should be at least DECIMALS digits
    printf -v SUM_FULL "%0${DECIMALS}d" $((A_FULL / B_FULL))

    # stripping and .adding this many digits: DECIMALS
    printf -v TRIM_END "%*s" "$DECIMALS"
    TRIM_END="${TRIM_END// /?}"
    printf "%.${DECIMALS}f" "${SUM_FULL%$TRIM_END}.${SUM_FULL:(-${DECIMALS})}"
}

# singleton echo
secho() {
    (
        flock 9
        echo "$*"
    ) 9> "$HC_LOCK"
}
error() {
    secho "$(tput sgr0)$(tput bold)$(tput setaf 7)$(tput setab 1)[hosting-check]$(tput sgr0) $*" >&2
}

fatal() {
    error "$*"
    exit 11
}

msg() {
    secho "$(tput sgr0)$(tput dim)$(tput setaf 0)$(tput setab 2)[hosting-check]$(tput sgr0) $*"
}

codeblock() {
    secho "$(tput sgr0)$(tput bold)$(tput setaf 0)$(tput setab 7)$*$(tput sgr0)"
}

notice() {
    secho "$(tput sgr0)$(tput dim)$(tput setaf 0)$(tput setab 3)[hosting-check]$(tput sgr0) $*"
}

do_ftp() {
    #echo "[DBG] lftp -e $* -u $HC_FTP_USERPASS $HC_FTP_HOST" >&2
    lftp -e "set cmd:interactive off; set net:timeout 5; set net:max-retries 1; set net:reconnect-interval-base 2; set dns:order 'inet inet6'; $*" \
        -u "$HC_FTP_USERPASS" "${HC_PROTOCOL}${HC_FTP_HOST}:${HC_FTP_PORT}" > /dev/null
}

do_curl() {
    [ -r "$HC_CABUNDLE" ] || fatal "can NOT find certificate authority bundle (${HC_CABUNDLE})"

    #echo "[DBG] curl -v --user '${HC_FTP_USERPASS/,/:}' $*" >&2
    curl -sS --cacert "$HC_CABUNDLE" --connect-timeout 5 --retry 1 --retry-delay 2 --ipv4 \
        --user "${HC_FTP_USERPASS/,/:}" "$@"
}

## generate files
generate() {
    local UNPACKDIR

    UNPACKDIR="$(mktemp --directory)"
    if ! mkdir "${UNPACKDIR}/${HC_DIR}"; then
        fatal "hc directory creation failure"
    fi

    echo -n "hc" > "${UNPACKDIR}/${HC_DIR}alive.html"

    cat << CSS > "${UNPACKDIR}/${HC_DIR}text-css.css"
html {
    color: #222;
    font-size: 1em;
    line-height: 1.4;
}
CSS

    cat << HTML > "${UNPACKDIR}/${HC_DIR}text-html.html"
<!doctype html>
<html lang="hu-HU">
    <head>
        <meta charset="utf-8">
        <meta http-equiv="X-UA-Compatible" content="IE=edge">
        <title>hc</title>
    </head>
    <body>
        <p>Hello world! This is HTML5 Boilerplate.</p>
    </body>
</html>
HTML

    cat << PHP > "${UNPACKDIR}/${HC_DIR}wp-settings.php"
<?php
//dump placeholder
PHP

    cat << HTACCESS > "${UNPACKDIR}/${HC_DIR}.htaccess"
## OPcache
#php_value opcache.enable 0
#php_value opcache.validate_timestamps 1
#php_value opcache.revalidate_freq 0
## APC
#php_value apc.cache_by_default 0
## New Relic
#php_value newrelic.enabled 0

<IfModule mod_setenvif.c>
    SetEnvIf Secret-Key ^${HC_SECRETKEY}$ hc_allow

    ## Apache < 2.3
    <IfModule !mod_authz_core.c>
        Order deny,allow
        Deny from all
        Allow from env=hc_allow
    </IfModule>

    ## Apache ≥ 2.3
    <IfModule mod_authz_core.c>
        Require env hc_allow
    </IfModule>
</IfModule>
HTACCESS

    # all mime type files
    mime_type "${UNPACKDIR}/${HC_DIR}"

    # PHP query
    if ! cp ./hc-query.php "${UNPACKDIR}/${HC_DIR}hc-query.php"; then
        rm -r "$UNPACKDIR"
        fatal "please download hc-query.php also"
    fi

    # return temp dir
    echo "$UNPACKDIR"
}

log_vars() {
    local VAR_NAME="$1"
    local VALUE="$2"

    # escape double quotes
    echo "${VAR_NAME}=\"${VALUE//\"/\\\"}\"" >> "$HC_LOG"
}

log_end() {
    echo -e "## --END-- ## $(date -R)\n" >> "$HC_LOG"
}

wgetrc() {
	cat <<-WGETRC
		user_agent=${UA}
		header=Secret-Key: ${HC_SECRETKEY}
		max_redirect=0
		timeout=5
		tries=1
	WGETRC
}

wget_def(){
    WGETRC=<(wgetrc) wget "$@"
}

php_query() {
    local QUERY="$1"

    wget_def -qO- "${HC_SITE}${HC_DIR}hc-query.php?q=${QUERY}"
}

php_long_query() {
    local QUERY="$1"

    wget_def -qO- --timeout 35 "${HC_SITE}${HC_DIR}hc-query.php?q=${QUERY}"
}

## execute CPU stress test
stress_cpu() {
    local ID="$1"
    local BENCHMARKS
    local BM1
    local BM2
    local BM3

    BENCHMARKS="$(php_long_query stresscpu)"

    BM1="$(cut -f 1 <<< "$BENCHMARKS")"
    BM2="$(cut -f 2 <<< "$BENCHMARKS")"
    BM3="$(cut -f 3 <<< "$BENCHMARKS")"

    if [ -z "$BENCHMARKS" ] \
        || [ "$BENCHMARKS" = 0 ] \
        || [ "$BM1" = 0 ] \
        || [ "$BM2" = 0 ] \
        || [ "$BM3" = 0 ]; then
        notice "CPU stress test [${ID}] failed (${BENCHMARKS})"
        return 1
    else
        ## success
        secho "$BENCHMARKS" >> "$HC_BENCHMARK_VALUES"
        return 0
    fi
}

# calculate and display averages
stress_cpu_averages() {
    local -a HC_BENCHMARK=( 0 0 0 )
    local BMV
    local -a VALUES=( 0 0 0 )
    local -i ROUNDS="0"

    # average
    while read BMV; do
        VALUES[0]="$(cut -f 1 <<< "$BMV")"
        VALUES[1]="$(cut -f 2 <<< "$BMV")"
        VALUES[2]="$(cut -f 3 <<< "$BMV")"

        HC_BENCHMARK[0]="$(add "${HC_BENCHMARK[0]}" "${VALUES[0]}" 3)"
        HC_BENCHMARK[1]="$(add "${HC_BENCHMARK[1]}" "${VALUES[1]}" 3)"
        HC_BENCHMARK[2]="$(add "${HC_BENCHMARK[2]}" "${VALUES[2]}" 3)"
        ROUNDS+="1"
    done < "$HC_BENCHMARK_VALUES"

    [ "$ROUNDS" = 0 ] && return 1
    notice "CPU stress averages steps/shuffle/AES $(divide "${HC_BENCHMARK[0]}" "$ROUNDS" 3)/$(divide "${HC_BENCHMARK[1]}" "$ROUNDS" 3)/$(divide "${HC_BENCHMARK[2]}" "$ROUNDS" 3)"
}

## concurrent CPU stress tests
stress_cpu_multi() {
    local CONCURRENCY="$1"
    local I2
    local -a FAILURES

    # initialize output
    echo -n > "$HC_BENCHMARK_VALUES"

    # start
    for (( i = 1; i < CONCURRENCY + 1; i += 1 )); do
        printf -v I2 "%02d" "$i"
        # writes to HC_BENCHMARK_VALUES
        stress_cpu "${I2}/${CONCURRENCY}" &
    done

    # wait
    for (( i = 1; i < CONCURRENCY + 1; i += 1 )); do
        if ! wait %${i}; then
            FAILURES+=( ${i} )
       fi
    done

    stress_cpu_averages

    # evaluate
    if [ -z "${FAILURES[*]}" ]; then
        # all OK
        return 0
    fi

    # kill all jobs
    { jobs -p | xargs kill -9 ;} &> /dev/null
    return 1
}

file_download() {
    local ID="$1"
    local URL="$2"
    local MD5="$3"

    if ! wget_def -q -O- "$URL" 2>&1 \
        | md5sum \
        | grep -q "^${MD5}$"; then
        notice "file download [${ID}] failed"
        return 1
    fi

    return 0
}

## concurrent static file download
static_download_multi() {
    local CONCURRENCY="$1"
    local URL="$2"
    local MD5="$3"
    local I2
    local -a FAILURES
    local i

    # start
    for (( i = 1; i < CONCURRENCY + 1; i += 1 )); do
        printf -v I2 "%02d" "$i"
        file_download "${I2}/${CONCURRENCY}" "$URL" "$MD5" &
    done

    # wait
    for (( i = 1; i < CONCURRENCY + 1; i += 1 )); do
        if ! wait %${i}; then
            FAILURES+=( ${i} )
       fi
    done

    # evaluate
    if [ -z "${FAILURES[*]}" ]; then
        # all OK
        return 0
    fi

    # kill all jobs
    { jobs -p | xargs kill -9 ;} &> /dev/null
    # overload may cause PHP to stop or to ban
    sleep 10
    return 1
}

dnsquery() {
    ## error 1:  empty host
    ## error 2:  invalid answer
    ## error 3:  invalid query type
    ## error 4:  not found

    local TYPE="$1"
    local HOST="$2"
    local ANSWER
    local IP

    # empty host
    [ -z "$HOST" ] && return 1

    # last record only, first may be a CNAME
    IP="$(LC_ALL=C host -t "$TYPE" "$HOST" 2> /dev/null | tail -n 1)"

    # not found
    if [ -z "$IP" ] || ! [ "$IP" = "${IP/ not found:/}" ] || ! [ "$IP" = "${IP/ has no /}" ]; then
        return 4
    fi

    case "$TYPE" in
        A)
            ANSWER="${IP#* has address }"
            ANSWER="${ANSWER#* has IPv4 address }"
            if grep -q "^\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\$" <<< "$ANSWER"; then
                echo "$ANSWER"
            else
                # invalid IP
                return 2
            fi
        ;;
        MX)
            ANSWER="${IP#* mail is handled by *[0-9] }"
            if grep -q "^[a-z0-9A-Z.-]\+\$" <<< "$ANSWER"; then
                echo "$ANSWER"
            else
                # invalid mail exchanger
                return 2
            fi
        ;;
        PTR)
            ANSWER="${IP#* domain name pointer }"
            ANSWER="${ANSWER#* points to }"
            if grep -q "^[a-z0-9A-Z.-]\+\$" <<< "$ANSWER"; then
                echo "$ANSWER"
            else
                # invalid hostname
                return 2
            fi
        ;;
        TXT)
            ANSWER="${IP#* descriptive text }"
            if grep -q "^[a-z0-9A-Z.-]\+\$" <<< "$ANSWER"; then
                echo "$ANSWER"
            else
                # invalid descriptive text
                return 2
            fi
        ;;
        *)
            # unknown type
            return 3
        ;;
    esac
    return 0
}

## check SSL certificate with openssl
## usage: ssl_check "service_name" "port_number" "additional_arguments"
ssl_check() {
    local SSL_NAME="$1"
    local SSL_PORT="$2"
    local SSL_ARGS="$3"
    local NOCERT_REGEX='[A-Za-z0-9+/=]\{64\}'

    notice "${SSL_NAME}:  echo QUIT|openssl s_client -CAfile '${HC_CABUNDLE}' -crlf -connect ${HC_FTP_HOST}:${SSL_PORT} ${SSL_ARGS}|grep -v '${NOCERT_REGEX}'"
}


################################
##       CHECKS               ##
################################

## site URL
siteurl() {
    [ "$HC_SITE" = "http://SITE.URL/" ] && fatal "please fill in the SETTINGS / HC_SITE"
    [ "$HC_FTP_HOST" = "FTPHOST" ] && fatal "please fill in the SETTINGS / HC_FTP_HOST"
    [ "$HC_FTP_USERPASS" = "FTPUSER,FTPPASSWORD" ] && fatal "please fill in the SETTINGS / HC_FTP_USERPASS"
    msg "site URL: ${HC_SITE}"
    log_vars "SITEURL" "$HC_SITE"
}

## DNS servers
dns_servers() {
    local NSS
    local NS1
    local NS2
    local DOMI

    if ! dnsquery A "$HC_DOMAIN" > /dev/null; then
        fatal "NOT a live domain (${HC_DOMAIN})"
    fi

    ## host names
    NSS="$(LC_ALL=C host -t NS "$HC_DOMAIN" 2> /dev/null)"
    if ! [ $? = 0 ] || ! [ "$NSS" = "${NSS/ not found:/}" ]; then
        fatal "no nameservers found"
    fi

    NS1="$(head -n1 <<< "$NSS")"
    NS2="$(head -n2 <<< "$NSS" | tail -n +2)"
    NS1="${NS1#* name server }"
    NS1="${NS1#* nameserver is }"
    NS2="${NS2#* name server }"
    NS2="${NS2#* nameserver is }"
    log_vars "NS1" "$NS1"
    log_vars "NS2" "$NS2"

    ## IP addresses
    NS1="$(dnsquery A "$NS1")"
    if ! [ $? = 0 ]; then
        error "first nameserver problem (${NS1})"
        return
    fi
    NS2="$(dnsquery A "$NS2")"
    if ! [ $? = 0 ]; then
        error "second nameserver problem (${NS2})"
        return
    fi
    notice "first nameserver (${NS1})"
    notice "second nameserver (${NS2})"
    log_vars "NS1IP" "$NS1"
    log_vars "NS2IP" "$NS2"

    ## compare first two octets
    if [ "${NS1%.*.*}" = "${NS2%.*.*}" ]; then
        error "nameservers are in the SAME data center"
    else
        msg "nameservers OK"
        notice "use exclusive (DNS-only) nameservers (with no webservers on them)"
    fi

    ## Hungarian "Domi"
    #changes for Cygwin compatibility DOMI="$(whois --host whois.nic.hu --port 77 "$HC_DOMAIN")"
    DOMI="$(whois -h whois.nic.hu -p 77 "$HC_DOMAIN")"
    if [ $? = 0 ] && ! [ "${DOMI#M-OK }" = "$DOMI" ]; then
        msg "Domi OK (${DOMI})"
    else
        error "Domi ERROR (${DOMI})"
        notice "Domi documentation:  http://www.domain.hu/domain/regcheck/hibak.html"
    fi

    notice "check DNS:  http://dnscheck.pingdom.com/?domain=${HC_DOMAIN}"
    notice "check DNS:  http://www.dnsinspect.com/${HC_DOMAIN}"
    notice "check DNS:  http://intodns.com/${HC_DOMAIN}"
    notice "check DNS:  http://www.solvedns.com/${HC_DOMAIN}"
}

## DNS mail exchangers
dns_email(){
    local MXA
    local MXREV
    local MXREVA
    local SPF_RECORDS

    # not local!
    HC_MX="$(dnsquery MX "$HC_DOMAIN")"
    if [ $? = 0 ]; then
        notice "first MX (${HC_MX})"
    else
        error "NO MX record"
        HC_MX=""
        return
    fi

    # IP of MX
    MXA="$(dnsquery A "$HC_MX")"
    if ! [ $? = 0 ]; then
        error "NO IP of first MX"
        return
    fi
    notice "first MX IP (${MXA})"
    notice "valli:  http://multirbl.valli.org/lookup/${MXA}.html"
    notice "anti-abuse:  http://www.anti-abuse.org/multi-rbl-check-results/?host=${MXA}"

    # PTR of IP
    MXREV="$(dnsquery PTR "$MXA")"
    if ! [ $? = 0 ]; then
        error "NO PTR of first MX IP"
        return
    fi
    if [ "$HC_MX" = "$MXREV" ]; then
        msg "MX PTR is the same"
    else
        notice "MX has other PTR / vanity MX (${MXREV})"
    fi

    # IP of PTR
    MXREVA="$(dnsquery A "$MXREV")"
    if ! [ $? = 0 ]; then
        error "NO reverse MX IP"
        return
    fi
    if [ "$MXA" = "$MXREVA" ]; then
        msg "reverse MX IP OK"
    else
        error "MX IP is different from reverse MX IP (${MXREVA})"
    fi

    # SPF, DKIM records
    SPF_RECORDS="$(LC_ALL=C host -t TXT "$HC_DOMAIN" 2> /dev/null)"
    if ! [ $? = 0 ] || ! [ "$SPF_RECORDS" = "${SPF_RECORDS/ has no /}" ]; then
        error "no SPF found"
    fi
    if [ "$SPF_RECORDS" = "${SPF_RECORDS/v=spf/}" ] || [ "$SPF_RECORDS" = "${SPF_RECORDSS/v=DKIM/}" ]; then
        error "SPF record with HARDFAIL: \"v=spf1 mx a ip4:${HC_MAILSERVER_IP} -all\""
        notice "SPF syntax:  http://www.openspf.org/SPF_Record_Syntax"
        notice "SPF check:  http://mxtoolbox.com/spf.aspx"
        notice "DKIM record:  http://domainkeys.sourceforge.net/ http://www.dkim.org/"
        notice "DKIM check:  http://dkimcore.org/tools/"
        notice "email check:  http://www.brandonchecketts.com/emailtest.php"
    else
        msg "SPF, DKIM OK (${SPF_RECORDS})"
    fi
}

## IP address
dns_ip() {
    local REV_HOSTNAME

    ## not local!
    HC_IP="$(dnsquery A "$HC_HOST")"
    if [ $? = 0 ]; then
        notice "IP address (${HC_IP})"
        log_vars "IPADDRESS" "$HC_IP"
    else
        fatal "has NO valid IP address"
    fi

    REV_HOSTNAME="$(dnsquery PTR "$HC_IP")"
    if [ $? = 0 ]; then
        # remove trailing dot for certificate vaildation
        REV_HOSTNAME="${REV_HOSTNAME%.}"
        notice "reverse hostname (${REV_HOSTNAME})"
        log_vars "REVHOSTNAME" "$REV_HOSTNAME"
    else
        error "NO reverse hostname (${REV_HOSTNAME})"
    fi
}

## domain name
domain() {
    local DOT_HU
    local HC_DOMAINNAME="${HC_DOMAIN%.*}"
    local HC_DOMAINTLD="${HC_DOMAIN##*.}"

    if [ "$HC_DOMAINTLD" = hu ]; then
        ## query domain.hu, convert to UTF-8, look for "class=domainnev", trim
        DOTHU="$(wget -qO- "http://www.domain.hu/domain/domainsearch/?domain=${HC_DOMAINNAME}&tld=${HC_DOMAINTLD}" \
            | iconv -c -f LATIN2 -t UTF-8 \
            | sed -n 's|.*<h3>.*class=domainnev>'"$HC_DOMAIN"'<.*domain név \(.\+\)</h3>.*|\1|p' \
            | sed -r -e 's/<[^>]+>|^\s+|\s+$|\.$//g' -e 's/.*/\L&/')"
        if [ -z "$DOTHU" ]; then
            error "domain registration could NOT be found at NIC"
        else
            notice "domain registration status (${DOTHU})"
        fi
    fi
}

## webserver info
webserver() {
    local WEBSERVER
    local APACHE_MODS

    WEBSERVER="$(wget_def -O /dev/null -S "$HC_SITE" 2>&1 | grep -i "^\s*Server:")"
    notice "webserver (${WEBSERVER#"${WEBSERVER%%[![:space:]]*}"})"  #"
    log_vars "WEBSERVER" "${WEBSERVER##*: }"

    grep -iq "apache" <<< "$WEBSERVER" || return

    APACHE_MODS="$(php_query apachemods)"
    if [ -z "$APACHE_MODS" ]; then
        error "Apache webserver but NO Apache modules"
    elif [ "$APACHE_MODS" = 0 ]; then
        notice "Apache module listing is disabled"
    else
        msg "Apache modules: ${APACHE_MODS}"
    fi
    log_vars "APACHEMODS" "$APACHE_MODS"
}

## keep alive response header
keep_alive() {
    local KEEPA

    if KEEPA="$(wget_def -O /dev/null -S "$HC_SITE" 2>&1 \
        | grep -i "^\s*Connection: Keep-Alive\$")"; then
        msg "keep alive OK"
    else
        error "NO keep alive"
        notice "try to set keep alive header in .htaccess:  Header set Connection Keep-Alive"
        notice "and test:  echo -e 'readme.html\nlicense.txt\nrobots.txt'|wget -v -i- -O/dev/null --base='$HC_SITE'|grep '^Reusing existing connection'"
    fi
}


## create list:  wget -qO- https://github.com/h5bp/server-configs-apache/blob/master/dist/.htaccess \
##     | grep AddType | sed 's/^.*AddType\s*\([^ ]*\)\s*\(.*\)$/\1 \2/'
mime_type() {
    local ARG="$1"
    local -a MIMES
    local MTYPE
    local MFILE

    MIMES=( \
        image/jpeg image-jpeg.jpg \
        image/png image-png.png \
        image/gif image-gif.gif \
        audio/mp4 audio-m4a.m4a \
        audio/ogg audio-ogg.ogg \
        application/json app-json.json \
        application/ld+json app-ldjson.jsonld \
        application/javascript app-javascript.js \
        video/mp4 video-mp4.mp4 \
        video/ogg video-ogv.ogv \
        video/webm video-webm.webm \
        video/x-flv video-flv.flv \
        application/font-woff font-woff.woff \
        application/vnd.ms-fontobject font-eot.eot \
        application/x-font-ttf font-ttf.ttf \
        font/opentype font-otf.otf \
        image/svg+xml font-svgz.svgz \
        application/octet-stream app-safari-ext.safariextz \
        application/x-chrome-extension app-chrome-ext.crx \
        application/x-opera-extension app-opera-ext.oex \
        application/x-web-app-manifest+json app-webapp-json.webapp \
        application/x-xpinstall app-firefox-ext.xpi \
        application/xml app-xml.xml \
        image/webp image-webp.webp \
        image/x-icon image-icon.ico \
        image/x-icon image-icon.cur \
        text/cache-manifest text-cache-manifest.appcache \
        text/vtt text-vtt.vtt \
        text/x-component text-htc.htc \
        text/x-vcard text-vcard.vcf \
    )

    # generate files
    if ! [ -z "$ARG" ]; then
        for (( i = 0; i + 1  < ${#MIMES[*]}; i += 2 )); do
            MFILE="${MIMES[$((i + 1))]}"
            echo "$RANDOM" > "${ARG}${MFILE}"
        done
        return
    fi

    for (( i = 0; i + 1  < ${#MIMES[*]}; i += 2 )); do
        MTYPE="${MIMES[$i]}"
        MFILE="${MIMES[$((i + 1))]}"
        if wget_def -O /dev/null -S "${HC_SITE}${HC_DIR}${MFILE}" 2>&1 \
            | grep -qi "^\s*Content-Type: ${MTYPE}\(\$\|;\)"; then
            msg "MIME type ${MTYPE} OK"
        else
            error "INCORRECT MIME type for ${MTYPE}"
        fi
    done
    notice "Apache settings:  https://github.com/h5bp/server-configs-apache/blob/master/dist/.htaccess"
}

## gzip compression
content_compression() {
    local CCOMPR

    if CCOMPR="$(wget_def -O /dev/null -S --header="Accept-Encoding: gzip" "${HC_SITE}${HC_DIR}text-css.css" 2>&1 \
        | grep -i "^\s*Content-Encoding: gzip\$")"; then
        msg "gzip compression OK"
    else
        error "NO gzip compression"
        notice "Apache settings:  https://github.com/h5bp/server-configs-apache/blob/master/dist/.htaccess"
    fi
}

## cache control max-age header 11 days - 3 years
content_cache() {
    local CCACHE

    if CCACHE="$(wget_def -O /dev/null -S "${HC_SITE}${HC_DIR}text-css.css" 2>&1 \
        | grep -i "^\s*Cache-Control:.*max-age=[0-9]\{7,9\}\b")"; then
        msg "cache control header OK"
    else
        error "NO cache control header"
        notice "Apache settings:  https://github.com/h5bp/server-configs-apache/blob/master/dist/.htaccess"
    fi
}

## concurrent file downloads 10/20/50/100/200
http_concurrent() {
    local URL="${HC_SITE}${HC_DIR}text-html.html"
    local MD5="$(wget_def -q -O- "$URL" | md5sum)"
    local C

    for C in 10 20 50 100 200; do
        if static_download_multi "${C}" "$URL" "$MD5"; then
            msg "${C} static files concurrently OK"
        else
            error "${C} static files download test failure"
            return
        fi
    done
}

## min. PHP >= 5.4
php_version() {
    local PHP_VERSION

    PHP_VERSION="$(php_query version)"

    # major * 100 + minor
    if [ "0${PHP_VERSION}" -ge 504 ]; then
        msg "PHP version OK (${PHP_VERSION})"
    else
        error "PHP 5.4 is twice as FAST (${PHP_VERSION})"
        notice "upgrade PHP"
    fi
    log_vars "PHPVERSION" "$PHP_VERSION"
}

## max PHP memory (>= 256MB)
php_memory() {
    local PHP_MEMORY

    PHP_MEMORY="$(php_query memory)"

    if [ "0${PHP_MEMORY}" -lt $((256 * 1024 * 1024)) ]; then
        error "LOW PHP memory limit (${PHP_MEMORY})"
        notice "ini_set('memory_limit', '256M');"
    else
        msg "PHP memory limit OK (${PHP_MEMORY})"
    fi
    log_vars "PHPMEMORY" "$PHP_MEMORY"
}

## max PHP execution time (>= 30)
php_exectime() {
    local PHP_EXECTIME

    PHP_EXECTIME="$(php_query exectime)"

    if [ "0$PHP_EXECTIME" -ge 30 ]; then
        msg "PHP execution time limit OK (${PHP_EXECTIME})"
    else
        error "PHP needs at least 30 seconds (${PHP_EXECTIME})"
        notice "ini_set('max_execution_time', 30);"
    fi
    log_vars "PHPEXECTIME" "$PHP_EXECTIME"
}

## PHP download file
## -----------------
## fopen, gzopen, readfile, file_get_contents - ini_get('allow_url_fopen')
## stream_socket_client function_exists()
## curl_init function_exists()
## function_exists( 'stream_socket_client' )
## function_exists( 'curl_init' ) || ! function_exists( 'curl_exec'
## -----------------
php_http() {
    local PHP_HTTP

    PHP_HTTP="$(php_query http)"

    if [ "$PHP_HTTP" = "OK" ]; then
        msg "PHP HTTP functions OK"
    else
        error "PHP can NOT download files"
    fi
}

## PHP magic quotes + safe mode + register globals
php_safe() {
    local PHP_SAFE

    PHP_SAFE="$(php_query safe)"

    if [ "$PHP_SAFE" = "OK" ]; then
        msg "PHP Safe mode etc. OK"
    else
        error "PHP magic quotes || safe mode || register globals ON"
    fi
}

## PHP user ID + FTP user ID
php_uid() {
    local PHP_UID

    PHP_UID="$(php_query uid)"

    if [ "$PHP_UID" = 0 ]; then
        error "PHP/FTP UID unavailable/mismatch"
    else
        msg "PHP/FTP UID OK (${PHP_UID})"
        log_vars "PHPUID" "$PHP_UID"
    fi
}

## known Server API
php_sapi() {
    local PHP_SAPI

    PHP_SAPI="$(php_query sapi)"

    # complete pattern!
    if grep -q "apache2handler\|cgi-fcgi\|fpm-fcgi\|litespeed" <<< "$PHP_SAPI"; then
        msg "PHP Server API OK (${PHP_SAPI})"
    else
        error "UNKNOWN PHP Server API (${PHP_SAPI})"
    fi
    log_vars "PHPSAPI" "$PHP_SAPI"
}

## must-use and extra PHP extensions
php_extensions() {
    local -a MU_EXTS
    local -a EXTRA_EXTS
    local PHP_EXTS

    MU_EXTS=( \
        pcre "PCRE/preg_match" \
        gd "PHP graphics directly" \
        curl "CURL library" \
        mysqli "MySQL Improved" \
    )

    EXTRA_EXTS=( \
        suhosin "Suhosin advanced protection system" \
        apc "APC opcode cache" \
        xcache "XCacahe" \
        memcache "Memcache (old)" \
        memcached "Memcached" \
        "Zend OPcache" "Zend OPcache" \
        mysql "MySQL (old)" \
        mysqlnd "MySQL Native Driver" \
        pdo_mysql "PHP Data Objects MySQL" \
        imagick "ImageMagick" \
    )

    PHP_EXTS="$(php_query extensions)"

    for (( i = 0; i + 1  < ${#MU_EXTS[*]}; i += 2 )); do
        ENAME="${MU_EXTS[$i]}"
        EDESC="${MU_EXTS[$((i + 1))]}"
            #&& msg "PHP Extension ${EDESC} OK" \
        grep -q "\b${ENAME}\b" <<< "$PHP_EXTS" \
            || error "MISSING PHP extension: ${EDESC}"
    done

    for (( i = 0; i + 1  < ${#EXTRA_EXTS[*]}; i += 2 )); do
        XNAME="${EXTRA_EXTS[$i]}"
        XDESC="${EXTRA_EXTS[$((i + 1))]}"
        grep -q "\b${XNAME}\b" <<< "$PHP_EXTS" \
            && notice "PHP Extension: ${XDESC} OK"
    done

    msg "All PHP Extensions: ${PHP_EXTS}"
    log_vars "PHPEXTENSIONS" "$PHP_EXTS"
}

## timezone
php_timezone() {
    local PHP_TZ

    PHP_TZ="$(php_query timezone)"

    if [ "$PHP_TZ" = "$HC_TIMEZONE" ]; then
        msg "PHP timezone OK (${PHP_TZ})"
        log_vars "PHPTIMEZONE" "$PHP_TZ"
    else
        error "DIFFERENT/missing PHP timezone (${PHP_TZ})"
        notice "date_default_timezone_set('${HC_TIMEZONE}');"
    fi
}

## MySQL server version
php_mysqli() {
    local PHP_SQL

    PHP_SQL="$(php_query mysqli)"

    if [ -z "$PHP_SQL" ] || [ "$PHP_SQL" = 0 ]; then
        error "can NOT determine MySQL server version"
    else
        notice "MySQL server version: ${PHP_SQL}"
        log_vars "MYSQLVERSION" "$PHP_SQL"
    fi
}

## PHP error reporting
php_logfile() {
    local LOGFILE

    LOGFILE="$(php_query logfile)"

    if [ -z "$LOGFILE" ] || [ "$LOGFILE" = 0 ]; then
        error "LOG dir/file creation failure"
        notice "create log dir and file manually, give 0777 permissions"
    else
        msg "error reporting OK"
        notice "copy this snippet to wp-config.php:"
        codeblock "$LOGFILE"
    fi
}

## CPU info
php_cpuinfo() {
    local CPU_INFO

    CPU_INFO="$(php_query cpuinfo)"

    if [ -z "$CPU_INFO" ] || [ "$CPU_INFO" = 0 ]; then
        notice "NO CPU info"
    else
        notice "CPUs: ${CPU_INFO}"
        log_vars "CPU" "$CPU_INFO"
    fi
}

## CPU stress tests 1/3/5/10/20/30
php_cpu() {
    local P

    for P in 1 3 5 10 20 30; do
        if stress_cpu_multi "${P}"; then
            msg "${P}x CPU stress test OK"
        else
            error "${P}x CPU stress test failure"
            return
        fi
    done
}

## disk access time
php_disk() {
    local ACCESSTIME

    ACCESSTIME="$(php_long_query accesstime)"

    if [ -z "$ACCESSTIME" ] || [ "$ACCESSTIME" = 0 ]; then
        error "disk stress test failure/too slow"
    else
        msg "1 GB file creation time/one million disk accesses time: ${ACCESSTIME/	//}"

        # second test
        ACCESSTIME="$(php_long_query accesstime)"

        if [ -z "$ACCESSTIME" ] || [ "$ACCESSTIME" = 0 ]; then
            error "second disk stress test failure/too slow"
        else
            msg "second file creation time/disk access time: ${ACCESSTIME/	//}"
        fi
    fi
}

## size of WordPress autoload options
wordpress() {
    notice "WordPress autoload options ($(php_query wpoptions)) bytes"
}

## test SSL in FTP server: 0 - no SSL, 1 - invalid cert, 2 - valid cert, 3 - SFTP
ftp_ssl() {
    local FTPSSL=""
    local FTP_LIST="recls [^.]*"

    # not local!
    FTPSSL_COMMAND=""

    ## SFTP (file transfer in SSH tunnel)
    if [ "$HC_FTP_ENABLE_TLS" = 3 ]; then
        HC_PROTOCOL="sftp://"

        # lftp
        if [ "$HC_CURL" = 0 ]; then
            if do_ftp "${FTP_LIST}; exit"; then
                FTPSSL="3"
                FTPSSL_COMMAND=""
                msg "SFTP connect OK"
                log_vars "FTPSSL" "$FTPSSL"
                log_vars "FTPSSLCOMMAND" "$FTPSSL_COMMAND"
                notice "SFTP connect level (${FTPSSL})"
                return
            else
                fatal "SFTP can NOT connect"
            fi
        fi
    fi

    # curl
    if [ "$HC_CURL" = 1 ]; then
        # SFTP
        if [ "$HC_FTP_ENABLE_TLS" = 3 ]; then
            FTPSSL="3"
        else
            FTPSSL="0"
        fi
        FTPSSL_COMMAND="curl ${HC_PROTOCOL}"
        log_vars "FTPSSL" "$FTPSSL"
        log_vars "FTPSSLCOMMAND" "$FTPSSL_COMMAND"
        notice "curl: FTP SSL connect level (${FTPSSL})"
        ssl_check "FTPS" "21" "-starttls ftp"
        return
    fi

    ## without SSL
    if do_ftp "set ftp:ssl-allow off; ${FTP_LIST}; exit"; then
        FTPSSL="0"
        FTPSSL_COMMAND="set ftp:ssl-allow off;"
        msg "FTP connect without SSL OK"
    else
        notice "FTP can NOT connect without SSL"
    fi

#FIXME  lftp with gnutls2/3 fails to verify some valid certs

    ## SSL with invalid certificate
    if [ "$HC_FTP_ENABLE_TLS" = 1 ] \
        && do_ftp "set ftp:ssl-force on; set ssl:verify-certificate off; ${FTP_LIST}; exit"; then
        FTPSSL="1"
        FTPSSL_COMMAND="set ssl:verify-certificate off;"
        msg "FTP connect with invalid SSL cert OK"
    else
        notice "FTP can NOT connect with invalid SSL cert"
        ssl_check "FTPS" "21" "-starttls ftp"
    fi

    ## SSL with valid certificate
    if [ "$HC_FTP_ENABLE_TLS" = 1 ] \
        && do_ftp "set ftp:ssl-force on; set ftp:ssl-allow on; ${FTP_LIST}; exit"; then
        FTPSSL="2"
        FTPSSL_COMMAND="set ftp:ssl-allow on;"
        msg "FTP connect with SSL OK"
    else
        notice "FTP can NOT connect with SSL"
        ssl_check "FTPS" "21" "-starttls ftp"
    fi

    if [ -z "$FTPSSL" ]; then
        fatal "FTP connection FAILED"
    else
        log_vars "FTPSSL" "$FTPSSL"
        log_vars "FTPSSLCOMMAND" "$FTPSSL_COMMAND"
        notice "FTP SSL connect level (${FTPSSL})"
    fi
    if [ "$FTPSSL" = 0 ]; then
        notice "ProFTPd  http://www.proftpd.org/docs/contrib/mod_tls.html"
        notice "Pure-FTPd  http://download.pureftpd.org/pure-ftpd/doc/README.TLS"
    fi
}

## upload hosting check files
ftp_upload() {
    local UNPACKDIR
    local FILELIST
    local RET

    UNPACKDIR="$(generate)"
    if ! [ $? = 0 ]; then
        fatal "can NOT create temporary dir (${UNPACKDIR})"
    fi


    if [ "$HC_CURL" = 1 ]; then
        # wp-config.php
        if [ -r ./wp-config.php ]; then
            if ! do_curl -T "{./wp-config.php}" "${HC_PROTOCOL}${HC_FTP_HOST}:${HC_FTP_PORT}${HC_FTP_WEBROOT}/wp-config.php"; then
                fatal "wp-config.php upload failure"
            fi
        fi

        FILELIST="$(find "${UNPACKDIR}/${HC_DIR}" -type f -printf "%p,")"
        do_curl --ftp-create-dirs -T "{${FILELIST%,}}" "${HC_PROTOCOL}${HC_FTP_HOST}:${HC_FTP_PORT}${HC_FTP_WEBROOT}/${HC_DIR}"
        RET="$?"
    else
        # wp-config.php
        if [ -r ./wp-config.php ]; then
            if ! do_ftp "${FTPSSL_COMMAND} cd '${HC_FTP_WEBROOT}'; put ./wp-config.php; exit"; then
                fatal "wp-config.php upload failure"
            fi
        fi

        do_ftp "${FTPSSL_COMMAND} cd '${HC_FTP_WEBROOT}'; mirror -R '${UNPACKDIR}/' .; exit"
        RET="$?"
    fi

    rm -r "$UNPACKDIR" \
        || error "can NOT remove local unpack dir ($?)"

    if [ "$RET" = 0 ]; then
        notice "uploading files OK"
    else
        fatal "can NOT upload hosting check files (${RET})"
    fi
}

## availability of uploaded files
ftp_ping() {
    local PING

    PING="$(wget_def -qO- --tries=1 --timeout=5 --max-redirect=0 "${HC_SITE}${HC_DIR}alive.html" | tr -c -d '[[:print:]]')"

    if [ "$PING" = hc ]; then
        notice "uploaded files are available"
    else
        fatal "could NOT download uploaded files (${PING})"
    fi
}

## delete hosting check files
ftp_destruct() {
    local -a FILES

    rm "$HC_LOCK"

    if [ "$HC_CURL" = 1 ]; then
        while read FILE; do
            [ -z "${FILE//./}" ] && continue
            FILES+=( -Q "-DELE ${FILE}" )
        done <<< "$(do_curl "${HC_PROTOCOL}${HC_FTP_HOST}:${HC_FTP_PORT}${HC_FTP_WEBROOT}/${HC_DIR}" -l 2> /dev/null)"
        if ! [ $? = 0 ]; then
            error "curl: can NOT get file list"
            error "self distruct failed, DELETE '${HC_DIR}' MANUALLY!"
            notice "curl --user '${HC_FTP_USERPASS/,/:}' 'ftp://${HC_FTP_HOST}${HC_FTP_WEBROOT}/'"
            return
        fi

        ## delete all files one-by-one
        do_curl "${HC_PROTOCOL}${HC_FTP_HOST}:${HC_FTP_PORT}${HC_FTP_WEBROOT}/${HC_DIR}" "${FILES[@]}" > /dev/null
        if ! [ $? = 0 ]; then
            error "curl: can NOT delete files"
            error "self distruct failed, DELETE '${HC_DIR}' MANUALLY!"
            notice "curl --user '${HC_FTP_USERPASS/,/:}' 'ftp://${HC_FTP_HOST}${HC_FTP_WEBROOT}/'"
            return
        fi

        ## delete dir
        do_curl "${HC_PROTOCOL}${HC_FTP_HOST}:${HC_FTP_PORT}${HC_FTP_WEBROOT}/" -Q "-RMD ${HC_DIR}" > /dev/null
        if ! [ $? = 0 ]; then
            error "curl: can NOT delete ${HC_DIR} dir"
            error "self distruct failed, DELETE '${HC_DIR}' MANUALLY!"
            notice "curl --user '${HC_FTP_USERPASS/,/:}' 'ftp://${HC_FTP_HOST}${HC_FTP_WEBROOT}/'"
            return
        fi
        msg "self destruct OK"
    else
        # delete .htaccess separately
        if do_ftp "${FTPSSL_COMMAND} cd '${HC_FTP_WEBROOT}'; rm -f '${HC_DIR}.htaccess'; rm -r '${HC_DIR}'; exit"; then
            msg "self destruct OK"
        else
            error "self distruct failed, DELETE '${HC_DIR}' MANUALLY!"
            notice "lftp -e '${FTPSSL_COMMAND} cd ${HC_FTP_WEBROOT}' -u '$HC_FTP_USERPASS' '$HC_FTP_HOST'"
        fi
    fi
}

# todos
manual() {
    if ! [ -z "$HC_MX" ]; then
        ssl_check "SMTPS" "465"
        ssl_check "IMAPS" "993"
        ssl_check "POP3S" "995"
        ssl_check "SMTP-TLS" "25" "-starttls smtp"
        ssl_check "IMAP-TLS" "143" "-starttls imap"
        ssl_check "POP3-TLS" "110" "-starttls pop3"
    fi

    ## email
    notice "register RBLmon:  https://www.rblmon.com/accounts/register/"
    notice "register DNS whitelist:  http://www.dnswl.org/request.pl"
    notice "set up email:  abuse@ postmaster@ webmaster@ spam@ hostmaster@ admin@"

    ## sql
    notice "set up phpmyadmin-cli:  https://github.com/fdev/phpmyadmin-cli"
    notice "check MySQL table engine:  SHOW ENGINES;"
    notice "phpmyadmin-cli -l PMA_URL --password=DB_PASSWORD -u DB_USER -e 'SHOW ENGINES;' DB_NAME|tail -n+2|csvtool cat -u TAB -|cut -f1"

    ## cert
    notice "certificate check: https://www.ssllabs.com/ssltest/analyze.html?d=${HC_HOST}&s=${HC_IP}"

    ## website
    notice "W3C validator:  http://validator.w3.org/check?group=1&uri=${HC_SITE}"
    notice "waterfall:  https://www.webpagetest.org/"
    notice "PageSpeed:  http://developers.google.com/speed/pagespeed/insights/?url=${HC_SITE}"
    notice "check hAtom:  http://www.google.com/webmasters/tools/richsnippets?q=${HC_SITE}"
#TODO  slimerjs + automated glyph detection  http://lists.nongnu.org/archive/html/freetype/2014-06/threads.html
    notice "emulate mod_pagespeed:  https://www.webpagetest.org/compare"
    notice "check included Javascripts"
    notice "check FOUC, image loading on mouse action (e.g. hover, click)"
    notice "check Latin Extended-A characters: font files/webfonts (őűŐŰ€) and overlapping text lines (ÚÚÚ qqq) and !cufon"
    notice "Javascript errors (slimerjs), 404s (slimerjs/gositemap.sh)"
    notice "minify CSS, JS, optimize images (progressive JPEGs)"
    notice "set up WMT:  https://www.google.com/webmasters/tools/home?hl=en"
    notice "set up Google Analytics:  https://www.google.com/analytics/web/?hl=en&pli=1"
    notice "Google Analytics/Universal Analytics: js, demographics, goals, Remarketing Tag"
    notice "set up page cache"
    notice "check main keyword Google SERP snippet:  https://www.google.hu/search?hl=hu&q=site:${HC_SITE}"
    notice "setup WordPress in a subdirectory to prevent easy bot login"
    notice "allow login from your country only (Maxmind GeoIP, ludost)"

    ## monitoring
    notice "no ISP cron, remote WP-cron:  8,38 * * * *  www-data  /usr/bin/wget -qO- ${HC_SITE}wp-cron.php"
    notice "add site URL to serverwatch/PING"
    notice "add site URL to serverwatch/no-page-cache_do-wp-DB"
    notice "add domain name to serverwatch/DNS"
    notice "add domain name to serverwatch/frontpage"
#TODO  frontpage good regex: '</html>'
#TODO  bad regex: 'sql\| error\| notice\|warning\|unknown\|denied\|exception'
    notice "check root files:  ${HC_SITE}robots.txt"
    notice "check root files:  ${HC_SITE}favicon.ico"
    notice "check root files:  ${HC_SITE}apple-touch-icon.png"
    notice "check root files:  ${HC_SITE}apple-touch-icon-precomposed.png"
    notice "check root files:  ${HC_SITE}browserconfig.xml"
    notice "check root files:  ${HC_SITE}crossdomain.xml"
    notice "check root files:  /sitemap*"
    notice "check root files:  /google*.html"

    notice "robots.txt, sitemap*  X-Robots-Tag: noindex, follow"
    notice "set up tripwire:  https://github.com/lucanos/Tripwire"
    notice "register pingdom:  https://www.pingdom.com/free/"
#TODO  can-send-email-test/day
#TODO  download-error-log/hour, rotate-error-log/week

    ## tips from  woorank.com + webcheck.me etc.
}

## a dirty hack
detect_success() {
    [ -r "${HC_LOG}" ] || return

    tail -n 2 "${HC_LOG}" | grep -q "^## --END-- ##" \
        || fatal "fatal error occurred"
}

## convert console output to colored HTML
tohtml() {
    [ -r "${HC_LOG}" ] || return
    which ansi2html &> /dev/null || return

    cat "${HC_LOG}.txt" \
        | ansi2html --title="$HC_DOMAIN" --linkify --font-size=13px --light-background -s xterm \
        | sed 's/\x1B(B\b//g' > "${HC_LOG}.html"
    notice "elinks ${HC_LOG}.html"
}

######################################################

## this { ... } is needed for capturing the output
{
    msg "Hosting checker v${HC_VERSION}  https://github.com/szepeviktor/hosting-check"

    ## site URL
    siteurl

    ## domain
    domain

    ## DNS
    dns_ip
    dns_servers
    dns_email

    ## FTP
    ftp_ssl
    ftp_upload
    ftp_ping

    ## web server
    webserver
    keep_alive
    mime_type
    content_compression
    content_cache
    http_concurrent

    ## PHP
    php_version
    php_memory
    php_exectime
    php_http
    php_safe
    php_uid
    php_sapi
    php_extensions
    php_timezone
    php_mysqli
    php_logfile
    php_cpuinfo
    php_cpu
    php_disk
#TODO mysqli benchmark, db-collation:  SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE schema_name = "$DB_NAME"
#TODO ipv6 support (connect, IP lookup)

    ## manual todos
    manual

    ## WP
    wordpress

    ## self destruct
    ftp_destruct

    ## END of log
    log_end

# duplicate to console
} 2>&1 | tee "${HC_LOG}.txt"

detect_success

## nice HTML output
tohtml
