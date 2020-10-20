#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

#################################
#
# Author: Lord_Alfred
# Blog: https://t.me/lord_Alfred
# Repo: https://github.com/lord-alfred/ProxyTunneler
#
#################################


# (!) Proxy Parameters (!)
PROXY_AUTH_USER='pruser'
PROXY_AUTH_PWD='PasswordHere'
PROXY_LIST_URL='http://Link_To_Proxy_List.com'


# current directory
CURRDIR=$(pwd)
# 3proxy version
PROXY_VER='0.8.13'
# start port for proxy
PORT_START=24000
# restart proxy in cron every X min
RESTART_EVERY_MIN=5
PROXY_COUNT=-1


# print current datetime to log (for debug)
date


# funcs
exit_if_not_equal_0() {
    if [ "$1" -ne '0' ]
    then
        >&2 echo -e "== $2"
        exit 1
    fi
}
exit_if_empty() {
    if [ -z "$1" ]
    then
        >&2 echo -e "== $2"
        exit 1
    fi
}


# prechecks
if [ "x$(id -u)" != 'x0' ]
then
    exit_if_empty '' 'This script can be run executed only by root'
fi


# get server IP
IP_GET_ITER=0
while [ "${IP_GET_ITER}" -le 30 ]
do
    IPV4_ADDR=$(ip -f inet addr | grep 'inet ' | grep -v '127.0.0' | awk '{ print $2}' | cut -d/ -f1 | head -n 1)
    if [ -n "${IPV4_ADDR}" ]
    then
        break
    fi

    echo '== IP address empty, sleep...'
    sleep 2

    ((IP_GET_ITER+=1))
done


# install 3proxy
if [ ! -f /usr/local/3proxy/3proxy ]
then
    echo '== Install 3proxy'

    # install reqs
    apt update
    exit_if_not_equal_0 "$?" 'apt update failed'
    apt install -y curl net-tools gcc make libc6-dev
    exit_if_not_equal_0 "$?" 'apt install failed'

    # install 3proxy
    curl -sSL "https://github.com/z3APA3A/3proxy/archive/${PROXY_VER}.tar.gz" > "${CURRDIR}/${PROXY_VER}.tar.gz"
    exit_if_not_equal_0 "$?" 'curl 3proxy failed'

    tar -zxf "${CURRDIR}/${PROXY_VER}.tar.gz"
    exit_if_not_equal_0 "$?" 'extract 3proxy failed'

    cd "${CURRDIR}/3proxy-${PROXY_VER}/" || exit_if_empty '' 'cd failed'

    make -f Makefile.Linux
    exit_if_not_equal_0 "$?" 'make failed'

    mkdir -p /usr/local/3proxy
    exit_if_not_equal_0 "$?" 'mkdir failed'

    cp "${CURRDIR}/3proxy-${PROXY_VER}/src/3proxy" /usr/local/3proxy/
    exit_if_not_equal_0 "$?" 'copy failed'

    chmod +x /usr/local/3proxy/3proxy
    exit_if_not_equal_0 "$?" 'chmod failed'

    cd "${CURRDIR}" || exit_if_empty '' 'cd to CURRDIR failed'
fi


# TODO: install bind9


# download remote proxy list
echo '== Download remote proxy list'
USER_AGENT='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.130 Safari/537.36'
curl -sSL -H "User-Agent: ${USER_AGENT}" "${PROXY_LIST_URL}" > /tmp/remote_proxies.txt
if [ "$?" -ne '0' ]
then
    if [ -f "${CURRDIR}/remote_proxies.txt" ]
    then
        # FIXME: copy previous proxylist
        cp "${CURRDIR}/remote_proxies.txt" /tmp/remote_proxies.txt
    else
        exit_if_empty '' 'download proxy list failed'
    fi
fi

sort -h < /tmp/remote_proxies.txt > /tmp/remote_proxies_sorted.txt
exit_if_not_equal_0 "$?" 'sort failed'
mv /tmp/remote_proxies_sorted.txt /tmp/remote_proxies.txt
exit_if_not_equal_0 "$?" 'move sorted failed'

PROXY_COUNT=$(wc -l < /tmp/remote_proxies.txt)
if [ "${PROXY_COUNT}" -le '0' ]
then
    exit_if_empty '' 'new proxy list empty'
fi

# check new proxylist is the same as previous
PROC_PID=$(pgrep '3proxy')
if [ -n "${PROC_PID}" ]
then
    MD5_CURR=$(md5sum /tmp/remote_proxies.txt | awk '{ print $1 }')
    MD5_PREV=$(md5sum "${CURRDIR}/remote_proxies.txt" | awk '{ print $1 }')

    if [ "${MD5_CURR}" = "${MD5_PREV}" ]
    then
        rm /tmp/remote_proxies.txt
        echo '== New proxy list are the same, not need to restart 3proxy'
        exit 0
    else
        echo '== New proxies found'
    fi
fi

mv /tmp/remote_proxies.txt "${CURRDIR}/remote_proxies.txt"
exit_if_not_equal_0 "$?" 'move new failed'


# generate local proxy list
if [ ! -f "${CURRDIR}/local_proxies.txt" ]
then
    echo '== Generate local proxy list'

    touch "${CURRDIR}/local_proxies.txt"
    exit_if_not_equal_0 "$?" 'create local proxies failed'

    PORT_ITER=${PORT_START}
    PORT_END=$((PORT_START + PROXY_COUNT - 1))
    while [ "${PORT_ITER}" -le "${PORT_END}" ]
    do
        echo "socks5://${PROXY_AUTH_USER}:${PROXY_AUTH_PWD}@${IPV4_ADDR}:${PORT_ITER}" >> "${CURRDIR}/local_proxies.txt"

        ((PORT_ITER+=1))
    done
fi


# fix limits
echo '== Fix limits'

ulimit -n 999999
exit_if_not_equal_0 "$?" 'set ulimit failed'

echo '999999' > /proc/sys/fs/file-max
exit_if_not_equal_0 "$?" 'set max files failed'


# generate 3proxy config
echo '== Generate 3proxy config'

{
    echo 'daemon'
    echo 'stacksize 6553699'
    echo 'nserver 8.8.8.8'
    echo 'nserver 8.8.4.4'
    echo 'nscache 65536'
    echo 'maxconn 10000'
    echo 'timeouts 1 5 30 60 180 1800 15 60'
    echo 'setgid 65535'
    echo 'setuid 65535'
    echo 'flush'
    echo 'auth strong'
    echo "users ${PROXY_AUTH_USER}:CL:${PROXY_AUTH_PWD}"
    echo "allow ${PROXY_AUTH_USER}"
} > "${CURRDIR}/3proxy.cfg"
exit_if_not_equal_0 "$?" 'add global 3proxy config failed'

PORT_ITER=${PORT_START}

while IFS= read -r LINE
do
    REMOTE_IP=$(echo "${LINE}" | cut -d':' -f 1)
    REMOTE_PORT=$(echo "${LINE}" | cut -d':' -f 2)
    # TODO: validate ip/port

    {
        echo 'allow *'
        echo "parent 1000 socks5+ ${REMOTE_IP} ${REMOTE_PORT}"
        echo "socks -a -n -p${PORT_ITER} -i${IPV4_ADDR} -e${IPV4_ADDR}"
        echo 'flush'
    } >> "${CURRDIR}/3proxy.cfg"
    exit_if_not_equal_0 "$?" 'add remote proxy to 3proxy config failed'

    # FIXME: unknown command in `sh` (`bash` ok)
    ((PORT_ITER+=1))
done < "${CURRDIR}/remote_proxies.txt"


# stop 3proxy
PROC_PID=$(pgrep '3proxy')
if [ -n "${PROC_PID}" ]
then
    echo '== Stop 3proxy process'

    kill -9 "${PROC_PID}"
    exit_if_not_equal_0 "$?" 'kill 3proxy failed'
fi


# run 3proxy
echo '== Run 3proxy'
/usr/local/3proxy/3proxy "${CURRDIR}/3proxy.cfg"
exit_if_not_equal_0 "$?" 'run 3proxy failed'


# add crontab tasks
FILE_NAME=$(basename "$0")
# TODO: grep -c for count?
CRON_TASKS_EXISTS=$(grep "${CURRDIR}/${FILE_NAME}" '/var/spool/cron/crontabs/root' -s)

if [ -z "${CRON_TASKS_EXISTS}" ]
then
    echo '== Add cron tasks'

    # run after system reboot
    echo "@reboot         cd '${CURRDIR}' && bash ${CURRDIR}/${FILE_NAME} >> /var/log/proxytunneler.log 2>&1" >> '/var/spool/cron/crontabs/root'
    exit_if_not_equal_0 "$?" 'add reboot command failed'

    # restart every X min (update proxy list)
    echo "*/${RESTART_EVERY_MIN} * * * *    cd '${CURRDIR}' && bash ${CURRDIR}/${FILE_NAME} >> /var/log/proxytunneler.log 2>&1" >> '/var/spool/cron/crontabs/root'
    exit_if_not_equal_0 "$?" 'add restart command failed'

    chown root: '/var/spool/cron/crontabs/root'
    exit_if_not_equal_0 "$?" 'crontab chown failed'

    chmod 600 '/var/spool/cron/crontabs/root'
    exit_if_not_equal_0 "$?" 'crontab chmod failed'
fi


echo "== Done (${SECONDS} seconds)"
